# Direct-assessment session with NULL registry — investigation trail (refuted hypotheses + reproduction recipes)

Bug: therapist clicks "Preencher formulário" on a concluded direct-assessment
session → white screen, because the frontend does `registry!.id` but
`assessment_occupational_therapy_registry_id` (or speech equivalent) is `NULL`.
Blast radius: ~1-4%/month of direct_assessment sessions (TO + Fono), steady-state.

## Conclusion reached (after reproduction)

The conversion subprocess `UpdateInterventionSessionToAssessment` **does NOT fail**
in production. The registry is created and linked correctly, then **deleted afterward**
(which nullifies the `assessment_session` link via `dependent: :nullify`).

- Evidence: production data has `session_type = direct_assessment` (persisted) + a
  `assessment_sessions` row (persisted), but `assessment_*_registry_id = NULL`.
- A forced-fail reproduction proved the subprocess rolls back EVERYTHING on any step
  failure (see below) — so `session_type` surviving means the subprocess succeeded.
- Therefore the registry was created then deleted. Delete path:
  `Assessments::UseCases::Delete<Speech|Occupational>TherapyAssessmentsRegistry`
  (`registry.destroy`, refuses when `completed?`), reached via
  `*_assessments_registries_controller.rb` DELETE endpoints.
- RESOLVED (16/09/2026): the DELETE is REAL and **intentional**, not a race/retry bug. Datadog APM span search
  `service:core resource_name:*Delete*AssessmentsRegistry*` over a 30-day window returned 28 spans, all `status: ok`,
  including two on the incident day ~7–30 min after the conversion (each span's `custom.params.registry_id` names the
  deleted registry). The frontend fires it deliberately: `DirectAssessments/Home` → `RegistryCard` →
  `DeleteRegistryButton` (only rendered for `status === 'started'` AND `canDelete`) →
  `DeleteAssessmentRegistryConfirmationModal` (2-click confirm). So the root cause is a **design gap**: deleting the
  registry nullifies the `assessment_session` link (`dependent: :nullify`) but does NOT revert the conversion — the
  session stays `direct_assessment` with a NULL registry.

- Consequence that must drive the fix decision: a `direct_assessment` session whose registry was deleted is
  **UNRECOVERABLE via the normal flow**. The conversion subprocess's `validate_session` step returns `false` unless
  `session.intervention?`, so a session that is ALREADY `direct_assessment` cannot be re-converted to mint a fresh
  registry. "Skip the crashing screen" is also NOT a clean fix: the `registry!.id` non-null assertion lives in EVERY
  assessment screen (the summary AND each of the 6 TO / 5 Fono sub-assessment pages), all feeding `registryId` to the
  provider — skipping one step just crashes the next. Realistic fix options:
  (a) frontend null-guard with a "recreate assessment" path (requires a backend way to create a registry for an
      already-converted session),
  (b) `Delete*AssessmentsRegistry` reverts the conversion (delete `assessment_session` + restore `intervention_session`
      + `session_type` back to `intervention`),
  (c) refuse the DELETE when an open `direct_assessment` session points at that registry.

## Reproduction recipes (Docker, core)

Run a `rails runner` script inside the core container. The container's `init.sh`
ENTRYPOINT mangles multi-word commands, so override it:

```
docker compose run --rm --entrypoint bundle -e DISABLE_SPRING=1 -e RAILS_ENV=test \
  app exec rails runner /app/<script>.rb
```

Test DB needs creating once (schema-only; does NOT seed — factory enums like
`:speech_therapy` discipline need the tenant factory's `after(:create)` which seeds
`Configuration::DictionaryRecord` automatically):

```
docker compose run --rm --entrypoint bundle -e DISABLE_SPRING=1 -e RAILS_ENV=test \
  app exec rails db:create db:schema:load
```

Script skeleton (factories handle tenant + dictionary seeding):

```ruby
require "./config/environment"
require "./spec/support/factory_bot"
include FactoryBot::Syntax::Methods

tenant = FactoryBot.create(:tenant, name: "repro_#{SecureRandom.hex(6)}")  # unique name — sequences reset each run and collide
ActsAsTenant.with_tenant(tenant) do
  session = create(:general_session_with_mandatory_dependencies,
                   :speech_therapy, :intervention, :with_intervention_sessionable)
  # a completed NON-editable registry (matches the real bug: editable_until in the past)
  create(:assessment_speech_therapy_registry, :completed,
         clinical_case: session.clinical_case, tenant: tenant,
         completed_at: 11.days.ago, editable_until: 1.day.ago)
  result = General::Sessions::UseCases::Subprocess::UpdateInterventionSessionToAssessment
    .call({ params: { session_id: session.id } })
  puts result.success?.inspect, result[:errors].inspect
end
```

Key gotchas hit while building these scripts:
- The registry factory declares `association :tenant` / `association :clinical_case`;
  pass `tenant: tenant` explicitly or it creates a colliding default-named tenant.
- The tenant factory uses `sequence(:name)` which resets to `tenant_1` each process —
  use a random name, or you get `Validation failed: Name has already been taken`.
- `ActsAsTenant.current_tenant` is thread-local; the factory's collaborator/discipline
  validation needs the tenant set — wrap everything in `ActsAsTenant.with_tenant`.

### Forced-fail test (proves total rollback)

Stub the model's `create` to return `nil`, then observe the FULL rollback:

```ruby
Assessments::SpeechTherapy::Registry.define_singleton_method(:create) { |**| nil }
result = ...UpdateInterventionSessionToAssessment.call({ params: { session_id: session.id } })
# result.success? == false
# session_type reverts to "intervention"
# assessment_session row NOT created
# intervention_session still exists
```

## Refuted hypotheses (do NOT re-investigate)

1. **Race condition** on `find_or_create_assessment_registry` — REFUTED by
   `scripts/verify_unique_index_blocking.py`: Postgres unique-index *speculative
   insertion* blocks the loser's INSERT until the winner commits, so the loser's
   `rescue RecordNotUnique → find_by(status: STARTED)` sees and REUSES the winner's
   committed row (never returns `nil`).
2. **`updated_by` nil → `NotNullViolation`** — there IS a real model/schema mismatch
   (`PhonologicalAssessment` has `belongs_to :updated_by, optional: true` but schema
   has `updated_by_id NOT NULL`), but it's UNREACHABLE: `updated_by =
   session.updated_by || session.created_by`, and `general_sessions.created_by_id`
   is `NOT NULL` with an FK to `users`, so `created_by` is never nil. Worth a
   defensive fix separately, but NOT this bug's cause.
3. **Partial commit / savepoint-swallowed-exception** — REFUTED by the forced-fail
   test: `Wrap(TrailblazerTransactionWrap)` rolls back everything when a step returns
   falsy (the fail track triggers the outer Rollback too). No partial commit exists.
