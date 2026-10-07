# Seeding minimal data to test a core feature end-to-end (no remote DB import)

The full remote DB import (`bin/custom/import_remote_database_locally.sh`) is heavy and needs
`gcloud auth login`. For testing a single backend feature you can seed a minimal domain-data
chain directly via `rails runner` instead — enough to exercise a use case against the dev DB.

## Chain to build (all inside `ActsAsTenant.with_tenant(tenant)`)

1. Tenant → 2. Protocol "Fonoaudiologia" → 3. ProtocolItems → 4. LibraryObjectives
→ 5. ClinicalCase → 6. PEI → 7. PEI Objectives → 8. Assessment Registry.

Run it as:

```bash
docker compose exec -T -e DISABLE_SPRING=1 app sh -c 'cat > /tmp/seed.rb' < tmp/seed.rb
docker compose exec -T -e DISABLE_SPRING=1 app bundle exec rails runner /tmp/seed.rb
```

## Gotchas (each one cost a retry)

- `User` has `first_name` + `last_name`, NOT `name`. `User.create!(email:, first_name:, last_name:)`.
- `ClinicalCase.create!` fails with "Preferences can't be blank". Build it as:
  `cc = ClinicalCase.new(name: ...); cc.preferences = Preferences::ClinicalCasePreferences.create_default(cc, user); cc.save!`
  (FactoryBot `:clinical_case` also trips on the `create_default` helper inside `rails runner`.)
- `Intervention::Protocol::ProtocolItem` `domain`/`subdomain` take string enum values from
  `Enum::Domains.to_h` / `Enum::Subdomains.to_h` (e.g. `"speech"`, `"tongue_control"`). Print both
  hashes first — the v2 de-para CSV has subdomains ("Controle Lingual", "Prosódia", …) that are
  NOT in the older `import_objectives.rake` map, so a hand-copied map silently yields 0 rows.
- `Library::Objective.create!(description:, protocol_item:)` is enough. The seed rake
  (`assessment:import_objective_mappings`) matches objectives by *normalized description*
  (strip + downcase + collapse whitespace), so the `description` must equal the CSV's
  "Objetivo Terapêutico" text verbatim.

## Verify the endpoint without HTTP/auth

Call the use case directly — bypasses routing + Pundit:

```ruby
result = Assessments::UseCases::ResolveRelatedObjectives.call(
  params: { registry_id: registry.id, assessment_type: "speech_motor_control" },
  current_user: user
)
result.success?            # true
result[:related_objectives] # [{ item_identifier:, objectives: [{ id:, description:, status: }] }]
```

`UseCase.call` takes `params:` + `current_user:` kwargs — NOT a positional hash (a positional
call fails the Dry contract with `{registry_id: ["is missing"]}`).

## Note on the browser screenshot

Even with this seed, a live panel screenshot still needs a real Auth0 user in the DB (a synthetic
`seed@...` user won't match the Auth0 token email). For that, use the remote DB import — see
`local-dev-db-sync`. The endpoint-level verification above is enough to prove the data + core
layer without the browser.
