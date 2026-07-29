# Agreement STI and COPM Native Form Migration

## Clinical::Agreement STI hierarchy

`Clinical::Agreement < ApplicationRecordTenant` uses `self.inheritance_column = :specific_type`.

| Class | specific_type | type method | Notes |
|---|---|---|---|
| `Clinical::Agreements::Embedded` | `Clinical::Agreements::Embedded` | `"EMBEDDED"` | Renders Typeform/Google Forms via `embed_url` |
| `Clinical::Agreements::NativeForm` | `Clinical::Agreements::NativeForm` | `"NATIVE_FORM"` | Renders native mobile form; `enum :native_form_type`; validates `native_form_type` presence |
| `Clinical::Agreements::Content` | `Clinical::Agreements::Content` | `"CONTENT"` | Audio/video/summary content |
| `Clinical::Agreements::Manual` | `Clinical::Agreements::Manual` | `"MANUAL"` | Manual agreement |

## COPM feature phases

- **Phase 1**: COPM created as `Clinical::Agreements::Embedded` with `internal_title: "Formulário/COPM"` and a Typeform `embed_url`.
- **Phase 2**: COPM created as `Clinical::Agreements::NativeForm` with `native_form_type: "copm"` (`Enum::Clinical::NativeFormTypes::COPM`). Gated by `FeatureFlag::CLINICAL_COPM_NATIVE_FORM_ENABLED` per tenant.

## CreateCopm use case (`packs/clinical/app/concepts/agreements/use_cases/create_copm.rb`)

- `check_no_pending_copm` blocks if any agreement with `internal_title: "Formulário/COPM"` and `completed_at: nil` exists — **no `specific_type` filter**. Migrated agreements still block new COPM creation (expected: user should respond to the open one).
- `find_copm_template` picks the template based on the feature flag:
  - ON → `PanelConfiguration::AgreementTemplate` with `specific_type: NativeForm`, `native_form_type: COPM`
  - OFF → template with `specific_type: "Clinical::Agreements::Embedded"`, `internal_title: "Formulário/COPM"`

## API serialization (mobile)

`index.json.jbuilder` returns `type` (from `agreement.type` method) and `native_form_type` (nil for legacy types). Mobile uses these fields to decide rendering:
- `type: "EMBEDDED"` → opens Typeform/Google Forms via `embed_url`
- `type: "NATIVE_FORM"`, `native_form_type: "copm"` → renders native COPM form

## Migrating legacy Embedded COPM → NativeForm

To make old incomplete Embedded COPM agreements render the native form:

```ruby
ActsAsTenant.current_tenant = Tenant.find_genial_tenant

# Use update_column to bypass validations (NativeForm validates native_form_type presence)
agreement.update_column(:specific_type, "Clinical::Agreements::NativeForm")
agreement.update_column(:native_form_type, ::Enum::Clinical::NativeFormTypes::COPM)
```

Key points:
- Must set **both** columns — `specific_type` for STI class, `native_form_type` for the NativeForm validation.
- Use `update_column` (not `update`) because the NativeForm model validates `native_form_type` presence, and a single-column update would temporarily violate it.
- The old `embed_url` stays in the DB but is ignored by the mobile app when `type` is `NATIVE_FORM`.
- `has_one :copm_form` is on the base `Clinical::Agreement` class, so it works regardless of subtype.

## Completing agreements via MakeComplete use case

`Agreements::UseCases::MakeComplete` (`packs/clinical/app/concepts/agreements/use_cases/make_complete.rb`) sets `completed_at` and emits `AgreementCompleted` event. Call signature:

```ruby
_, (ctx, _) = Agreements::UseCases::MakeComplete.call(id: agreement.id, user: user)
ctx[:clinical_agreement].completed_at  # verify success
```

Always prefer this over raw `update_column(:completed_at, ...)` — the use case emits the `AgreementCompleted` domain event, which `update_column` would bypass.

## Batch data-fix snippet archetype

Both migration and completion tasks follow the same shape. Use this template:

```ruby
# <Purpose comment — pt-BR or English, match existing file style>
# Regras:
#   - <condition 1> → <action/skip>
#   - <condition 2> → <action/skip>
ActsAsTenant.current_tenant = Tenant.find_genial_tenant

CASE_NUMBERS = [156, 204, ...]  # unique case numbers

clinical_cases = ClinicalCase.where(number: CASE_NUMBERS)
puts "Esperados: #{CASE_NUMBERS.size} | Encontrados: #{clinical_cases.count}"

missing_numbers = CASE_NUMBERS - clinical_cases.pluck(:number).sort
puts "CASOS NÃO ENCONTRADOS (#{missing_numbers.size}): #{missing_numbers}" if missing_numbers.any?

user = User.system_user
acted = 0
skipped = 0

clinical_cases.find_each do |clinical_case|
  # Query per-case to keep logic simple
  copm_agreements = clinical_case.clinical_agreements
    .where(internal_title: "Formulário/COPM", completed_at: nil)
    .order(created_at: :desc)

  if copm_agreements.count > 1
    # Skip rule: multiple — list types for manual decision
    types = copm_agreements.map { |a| "##{a.id}=#{a.specific_type}" }.join(", ")
    puts "  ##{clinical_case.number} — PULADO: #{copm_agreements.count} agreements (#{types})"
    skipped += 1
    next
  end

  if copm_agreements.none?
    puts "  ##{clinical_case.number} — PULADO: nenhum agreement COPM incompleto"
    skipped += 1
    next
  end

  agreement = copm_agreements.first

  # Skip rule: already in target format
  if agreement.is_a?(Clinical::Agreements::NativeForm)
    puts "  ##{clinical_case.number} — PULADO: já está no formato NativeForm"
    skipped += 1
    next
  end

  # Action: migrate OR complete via use case
  # For type migration (STI): use update_column on both columns
  agreement.update_column(:specific_type, "Clinical::Agreements::NativeForm")
  agreement.update_column(:native_form_type, ::Enum::Clinical::NativeFormTypes::COPM)
  puts "  ##{clinical_case.number} — MIGRADO: agreement_id=#{agreement.id}"

  # For completion: use the MakeComplete use case (emits events)
  # _, (ctx, _) = Agreements::UseCases::MakeComplete.call(id: agreement.id, user: user)
  # if ctx[:clinical_agreement]&.completed_at
  #   puts "  ##{clinical_case.number} — COMPLETADO: agreement_id=#{agreement.id}"
  #   acted += 1
  # else
  #   puts "  ##{clinical_case.number} — ERRO: falha ao completar"
  #   skipped += 1
  # end

  acted += 1
end

puts "\nResumo: #{acted} processados, #{skipped} pulados"
```

Key points:
- Use `find_each` (not `.each`) to avoid loading all cases into memory.
- Query per-case (`clinical_case.clinical_agreements`) — simpler logic, avoids classification N+1.
- Print one line per case with `#number` prefix and status tag (MIGRADO/COMPLETADO/PULADO/ERRO) for easy grep.
- End with a summary line (`acted` vs `skipped`) for at-a-glance verification.
- Deduplicate the input list before processing — the user's list may contain duplicates (e.g. case 1404 appeared twice).
- When case count ≠ agreement count, check for cases with duplicate COPM agreements using `group_by(&:clinical_case_id)`.
- After writing, verify with `standardrb` on the snippet file: `docker compose exec app bundle exec standardrb custom_gitignore/snippets/clinical_cases/cases.rb`.
