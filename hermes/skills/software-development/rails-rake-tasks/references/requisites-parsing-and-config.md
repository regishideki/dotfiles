# Speech-therapy objectives import — parsing & config specifics

Session example: `lib/tasks/speech_therapy/import_objectives.rake` (migrating the
Fonoaudiologia catalog of standardized objectives + evolution check configurations).

## Domain model chain

Protocol ("Fonoaudiologia") → ProtocolItem (domain + subdomain) → LibraryObjective
(description) → EvolutionCheckConfiguration (versioned, `configuration_type`).

`EvolutionCheckConfiguration` fields (packs/clinical/.../evolution_check_configuration.rb):
- `version` :integer (immutable — new version instead of in-place edit)
- `configuration_type` :enum — `trial_counter` | `checklist`
- `requisites` :RequisiteList — JSONB array of `{name, checked}` (the checklist items)
- `instructions` :text — free-form prose (DIFFERENT from requisites; do not conflate).
  The DB column is `null: false` (`db/schema.rb`), so it MUST be set — pass `instructions: ""`
  when the checklist data lives in `requisites`. A `nil` raises `PG::NotNullViolation`, which
  aborts the transaction and cascades into `PG::InFailedSqlTransaction` on every later statement
  (symptom, not cause — read the FIRST error, not the cascade).
- `completion_threshold` :float, `unit_of_measurement` :string, `max_measurements` :integer

For a checklist, the three measurement fields are derived from the requisites count:
`completion_threshold = max_measurements = requisites.size`, `unit_of_measurement = "quantidade"`.

`RequisiteList` = `Serializers::JsonbArraySerializer`; `Requisite` has `name` + `checked`.
Pass the PLAIN array of hashes to `create!` (`requisites: [{name: "..."}, ...]`), NOT
`RequisiteList.build(...)`. The JSONB type's `serialize` does `Oj.dump(value, mode: :rails)`,
which cannot serialize the custom `RequisiteList` object — the create fails silently inside
the transaction (the `rescue` then swallows it, see SKILL.md gotcha #5). Factories and specs
(`spec/factories/intervention_library_evolution_check_configuration.rb`,
`evolution_check_configuration_spec.rb`) all pass plain hashes; match them.

## CSV → structured requisites

CSV column "Nova Checagem de Evolução ajustada" is dirty bullet text: bullets on the same
line separated by spaces, leading hyphens, trailing `;`/`.`, lowercase. Normalize with:

```ruby
def parse_requisites(text)
  return [] if text.blank?

  text.strip
    .split(/\r?\n/)                                   # split lines
    .flat_map { |line| line.split(/\s+-\s+/) }        # split bullets on the SAME line
    .map { |part| part.strip.sub(/^-\s*/, "").sub(/[;.]$/, "").strip }  # drop hyphen, ;, .
    .reject(&:blank?)
    .map { |name| {name: name.sub(/^([a-zà-ú])/) { $1.upcase }} }       # capitalize
end
```

Result: `"faz 30 vezes" → "Faz 30 vezes"`, no hyphen, no trailing punctuation.

Note: `blank?` is ActiveSupport — use `nil?`/`empty?` if testing this in a bare `ruby -e`.

## Set reconciliation key

`[domain, subdomain, description]`. discard = DB − CSV; create = CSV − DB;
update = CSV ∩ DB where sorted requisite names differ → new version.

## Per-tenant

Each tenant (genialcare, careplus_mindplace) has a full copy of the protocol. Reconcile
inside `ActsAsTenant.with_tenant(t) { ... }` for EACH tenant, and wrap the whole tenant loop
in one `ActiveRecord::Base.transaction` with `raise ActiveRecord::Rollback` on any error.
