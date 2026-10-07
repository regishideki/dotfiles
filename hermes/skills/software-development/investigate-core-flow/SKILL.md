---
name: investigate-core-flow
description: "Investigate GenialCare Rails core backend flows."
---

# investigate-core-flow

The GenialCare **core** is a Rails monolith at `projects/core/` using
Packswerk, Trailblazer use cases, Dry::Validation contracts, and
multi-tenant architecture (`ApplicationRecordTenant`). All business logic,
validations, and state rules live here — the BFF is a thin proxy.

This skill is the Rails-core counterpart to `investigate-bff-flow` (which
covers the Node.js GraphQL BFF layer). When the user asks to investigate a
flow "no core", "no Rails", or "no backend", load this skill.

## When to load this skill

- User asks to "investigar o fluxo de X no core"
- User asks about models, use cases, endpoints, or validations in the Rails backend
- User needs to understand why an error occurs in the core (not the BFF)
- User references `projects/core/` or files within it
- User asks about DB-level constraints, unique indexes, or idempotency patterns
- User asks about Trailblazer use case flows or Dry::Validation contracts

## Architecture: where things live

```
projects/core/
  config/routes.rb                    # Route definitions
  db/schema.rb                        # DB schema (ground truth for indexes, columns)
  db/migrate/                         # Migrations
  packs/
    clinical/                         # Clinical domain (interventions, evolution, assessments)
      app/
        models/                       # ActiveRecord models (namespaced: Intervention::Evolution::EvolutionCheck)
        concepts/<domain>/use_cases/  # Trailblazer use cases (the business logic)
        controllers/                  # Rails controllers
        views/                        # Jbuilder JSON views
        admin/                        # ActiveAdmin pages
        jobs/                         # Background jobs
        spec/                         # Tests (models, concepts, requests)
    operational/                      # Operational domain (scheduling, checkin/checkout, finance)
      app/                            # Same structure as clinical
    reports/                          # Reports domain
    domain_configuration/             # Domain configuration
  lib/                                # Shared utilities, tasks, tenant_schema_audit
  event_consumer_start.rb             # Pub/Sub subscriber registry (see trace-event-flows skill)
```

### Key architectural patterns

1. **Packswerk**: The monolith is divided into packs (`clinical`, `operational`,
   `reports`, etc.). Each pack is self-contained with its own models, controllers,
   use cases, and specs. Cross-pack references go through public interfaces.
   Each pack has a `package.yml` with `enforce_dependencies: true` and
   `enforce_privacy: true`, and the dependency graph is one-directional:
   `operational → clinical → app, domain_configuration`. `operational/package.yml`
   declares `packs/clinical` as a dependency, but `clinical/package.yml` does NOT
   depend on `operational` — adding that would create a cycle, which packwerk
   rejects. **Consequence:** a clinical-pack use case/endpoint CANNOT cleanly read
   operational data (e.g. `Child#scheduled_hours_by_discipline`, which queries
   `Scheduling::Schedule`). When a calculation needs to combine clinical and
   operational inputs, the BFF is the composition layer — see the pitfall
   "Where to place a calculation that crosses pack domains" below. Note that
   packwerk enforces *lexical* constant references, so a string association
   (`has_one :child, class_name: "People::Child"` — already on `ClinicalCase` in
   the shared `app` pack) or a duck-typed call
   (`clinical_case.child.scheduled_hours_by_discipline(...)`) is NOT flagged, even
   though it hides the same cross-domain coupling.

2. **Trailblazer Use Cases**: Business logic lives in use case classes under
   `app/concepts/<domain>/use_cases/`. They extend `UseCase::Base` and use a
   step-based flow with `step`, `fail`, `Output(...) => End(...)` syntax.
   - Each use case typically has a nested `Dry::Validation::Contract` class
     defining parameter validation rules.
   - Steps are wrapped with `Wrap(TrailblazerUseCaseMonitoringWrap)` for
     observability and `Wrap(TrailblazerTransactionWrap)` for DB transactions.
   - Use cases are called with `.call(params:, current_user:)` and return a
     context object (`ctx`) with `.success?`/`.failure?` and `ctx[:errors]`.

3. **Multi-tenant**: All models extend `ApplicationRecordTenant` (not
   `ApplicationRecord`). Tables have a `tenant_id` column with indexes.
   Most queries are automatically scoped to the current tenant.

4. **Idempotency via DB unique indexes + correlation_id**: Many entities
   use a `correlation_id` (UUID) with a unique index. The pattern is:
   ```ruby
   rescue ActiveRecord::RecordNotUnique
     existing = Model.find_by(correlation_id: params[:correlation_id])
     return false if existing.nil?  # different correlation_id = genuinely new request
     # same correlation_id = retried request → return existing record
     ctx[:record] = existing
     true
   end
   ```
   This means: same `correlation_id` = idempotent success; different
   `correlation_id` for same parent = error.

5. **ActiveAdmin**: Some endpoints (especially operational/scheduling) are
   exposed via ActiveAdmin member actions rather than dedicated controllers.
   Check `app/admin/` for member_action definitions.

6. **Enums**: Defined in `app/models/enum/<domain>/<name>.rb` as classes
   extending `Enum::Base` with string constants and `self.all` method.
   Used in models via `enum :status, Enum::Module.to_h`.

7. **Audit fields (`created_by` / `updated_by`)**: Many models track who
   created and/or last modified a record via FK references to `users`:
   - **`TrackCreationBy` concern** (`app/models/concerns/track_creation_by.rb`):
     auto-assigns `created_by` (on create, non-overridable) and `updated_by`
     (on every save, overridable) from `Current.user`. Some models use this;
     others define the associations manually.
   - **Manual pattern**: `belongs_to :created_by, class_name: "User",
     optional: true` set explicitly in use cases via
     `current_user: current_user` param. `ClinicalCaseWorkload` follows this
     pattern (does NOT use the concern).
   - **`updated_by` pattern**: Used in 10+ clinical models
     (intervention/note, session_activity, PEI program/target/strategy,
     Documents::ClinicalCaseFile). Always `belongs_to :updated_by,
     class_name: "User"` — set explicitly in the use case's update step
     (e.g. `record.update(updated_by: current_user)`).
   - **`Current`** (`app/models/current.rb`):
     `ActiveSupport::CurrentAttributes` with `attribute :user,
     :authenticated_user`. This is the canonical source of the current user
     across the request cycle. `TrackCreationBy` reads from it; use cases
     receive `current_user` as an explicit parameter.

8. **Immutable resource pattern (create/discard)**: Some resources have no
   update action — routes use `except: [:edit, :update]`. The lifecycle is
   create → soft-delete (via `Discard`). "Modifying" a record means creating
   a new one with a new `in_effect_since` and discarding the old one.
   `ClinicalCaseWorkload` is the canonical example. When a feature asks for
   "last modified by" on such a resource, clarify whether it means the
   creator of the current record, the person who discarded the previous one,
   or a new field to be populated on both create and discard.

9. **BFF layer**: The Node.js GraphQL BFF (`projects/clinical-panel-bff/`)
   proxies to core's JSON endpoints. When investigating a full-stack flow,
   check `src/datasources/core/<domain>-api.js` for the HTTP calls and
   `src/schema/<domain>/resolvers.js` for the GraphQL resolvers. The BFF
   maps camelCase GraphQL fields to snake_case Rails params.

10. **Supervision data warehouse**: The `supervision` project
    (`projects/supervision/`) is a Dataform/BigQuery pipeline that
    consumes CDC via **Google Cloud Datastream** — NOT PubSub events.
    Datastream replicates PostgreSQL table changes to GCS, and BigQuery
    external tables in Dataform read from GCS. When a feature asks to
    "expose a field in CDC for supervision," check if the DB column
    already exists — if so, Datastream already replicates it. The work
    is in the supervision project's Dataform definitions, not in event
    payloads. See
    `references/clinical-case-workload-investigation.md` (section
    "Supervision CDC") for the full pattern with example files.

11. **CDC event tables (`raw.<table>_events`) as row-level forensic history — use for "who did what when" investigations, not just Dataform pipelines.** Every core Postgres table replicated via Datastream has a matching external table `raw.<table_name>_events` containing every INSERT/UPDATE row-version, not just current state — but the CDC tables are SPLIT ACROSS TWO PROJECTS by domain: case/session/user tables (e.g. `sessions_events`, `clinical_cases_events`, `users_events`) live under `data-kernel-production-4o7n.raw`, while ASSESSMENT/clinical-domain tables (e.g. `occupational_therapy_registries_events`, `speech_therapy_registries_events`) live under `supervision-production-8f1v.raw`. If a `raw.<table>_events` lookup returns zero rows or the table is missing under the first project, list tables in the other project's `raw` dataset before concluding there is no CDC for that table:
   ```sql
   SELECT table_name FROM `supervision-production-8f1v`.raw.INFORMATION_SCHEMA.TABLES WHERE table_name LIKE '%registr%'
   ```
   **DELETE events only carry the primary key** — on a `source_metadata.change_type='DELETE'` row, `payload` fields other than `id` are empty (Datastream's delete event does not replicate the full row), so `updated_by_id`/`deleted_by` is NOT available from CDC. To attribute a delete to a person, use the Datadog trace's `browser.request` span `usr.email`/`usr.id` (see the `genialcare-datadog-investigation` skill), not the CDC table. Schema: `payload` (STRUCT mirroring the table's columns, including `created_by_id`/`updated_by_id`/timestamps), `source_metadata.change_type` (INSERT/UPDATE/DELETE), `source_timestamp`. This is the fastest way to answer "who created this record and with what values", "what changed and when", or "who triggered this specific field flip":
    ```sql
    SELECT source_timestamp, source_metadata.change_type, payload.<field1>, payload.<field2>
    FROM `data-kernel-production-4o7n.raw.<table>_events`
    WHERE payload.id = '<record-id>'
    ORDER BY source_timestamp ASC
    ```
    Keep the SELECT column list narrow — these are external tables and a broad struct-field select can push even a single-record lookup past the 60s foreground `terminal` timeout (a wide select on one row hung 60s+; the same query trimmed to ~8 needed columns returned in seconds). Resolve `created_by_id`/`updated_by_id` UUIDs to human emails via `datakernel.users` in a follow-up query. Cross-reference the resulting timestamp against `service:core` Datadog logs (`search_datadog_logs` with the record id as the query string) to see the exact use-case/event emission that produced that row-version — logs commonly show the `EmitEventJob`/`SessionUpdated` payload with the same `created_by`/`updated_by`, confirming which UseCase ran.

12. **Quantifying the blast radius of a suspected data-integrity bug: JOIN + COUNTIF across BQ tables, right after root-causing a single record.** Once one broken record is understood (e.g. a foreign key that a use case should have populated but is NULL), immediately check how many other records share the same gap — a one-record report reads very differently from a systemic one:
    ```sql
    SELECT s.discipline, COUNT(*) AS total,
           COUNTIF(a.<expected_fk> IS NULL) AS missing
    FROM `data-kernel-production-4o7n.datakernel.sessions` s
    LEFT JOIN `supervision-production-8f1v.assessment.assessment_sessions` a ON a.id = s.id
    WHERE s.session_type = 'direct_assessment'
    GROUP BY s.discipline
    ```
    This turned a "one therapist hit a bug" investigation into "53-61% of ALL direct_assessment sessions across two disciplines are missing their registry" — a materially different severity/priority conversation. Always run this cross-check before closing out a root-cause investigation that started from a single user report.\n\n    **Caveat — segment the missing rate by time before quoting an "all-time" number.** An all-time missing rate is routinely dominated by *legacy rows that predate the feature/column itself*, not the live bug. In the `direct_assessment` example above, the 53-61% "all-time" figure was almost entirely pre-feature: the registry-creation logic was only added in Mar-Apr 2026, so sessions from Jan-Feb 2026 are *legitimately* 100% missing. Grouping the same JOIN by `FORMAT_TIMESTAMP("%Y-%m", s.created_at)` showed 100% missing in Jan-Feb, dropping to a steady-state **~1-4%/month** once the feature was live — that steady-state number is the true active-bug severity, an order of magnitude smaller. Whenever the "how many records are broken" number looks alarming, break it down by month (or by a feature-rollout date) and separate "the feature didn't exist yet" from "the feature is broken now" before reporting severity.

13. **Feature flags (Split.io) in core — NOT the same as clinical-panel's React flags.** Core uses Split.io (`splitclient-rb`), so the `remove-feature-flag` skill (which greps `constants/flags.ts` + `useFeatureFlag` in the TypeScript repo) does NOT apply here. Where flags live in the Rails core:
    - `app/services/feature_flag.rb` — the catalog: one `UPPER_SNAKE` constant per flag pointing at its string `split_name`, plus the `FeatureFlag.on?(key:, split_name:, attributes:, model:)` helper. `on?` calls `client.get_treatment(key, split_name, attributes)`, logs `[FeatureFlag] split_name=... treatment=...`, and — when a `model:` is passed — `find_or_create_by`/`destroy_by` on `FeatureFlagableModel` to record/clear which record currently has the flag "on".
    - `config/initializers/split_client.rb` — builds `Rails.configuration.split_client` from `ENV["SPLIT_IO_KEY"]` (prod/staging); in `test` it reads local `config/split.yaml` with a 10s reload.
    - `config/split.yaml` — local split definitions consumed by tests.
    - `app/models/feature_flagable_model.rb` — polymorphic `FeatureFlagableModel < ApplicationRecordTenant` (`key`, `flag_name`, `flagable` polymorphic) tracking flag-on state per record.
    - The `key` (Split.io bucketing key) has NO convention — each call site picks one. Precedents: per-case (`clinical_case.id` — `enable_hardlock_bradesco_workload`), per-report (`vineland_report_id` — `enable_create_suggested_workload`), per-tenant (`clinical_case.tenant_id` — COPM flags; `tenant.external_id` — new authorization). An undefined split returns treatment `"control"` (≠ "on" → flag off), and `model:` has no production call site (marketplace specs only).
    - Splits are created in the **Split.io dashboard** — there is NO rake/task in core that creates them. For tests, add the split to `config/split.yaml`. Specs stub globally: `allow(FeatureFlag).to receive(:on?).and_return(true/false)` (the pattern in every workload spec).

## Investigation procedure

1. **Start with search_files for the domain term.** Search content across
   `projects/core/` for the feature name (e.g. "evolution_check", "checkin",
   "checkout"). Use `output_mode="files_only"` first to get a file inventory.

2. **Find the models.** Look in `packs/<pack>/app/models/` for model files.
   Models are namespaced (e.g. `Intervention::Evolution::EvolutionCheck`).
   Check `self.table_name`, `belongs_to`, `has_many`, and `attribute` declarations.

3. **Find the use cases.** Look in `packs/<pack>/app/concepts/<domain>/use_cases/`.
   Read the main use case — it orchestrates the flow. Look for:
   - The Dry::Validation contract (nested class) for input validation
   - The step sequence for the processing flow
   - `rescue ActiveRecord::RecordNotUnique` for idempotency patterns
   - `handle_errors` / `fail` steps for error message generation

4. **Find the controllers.** Look in `packs/<pack>/app/controllers/`. Controllers
   are thin — they call use cases and render results. Check `params.permit` for
   the accepted parameters. If not in controllers, check `app/admin/` for
   ActiveAdmin member actions.

5. **Check routes.** `config/routes.rb` maps endpoints to controllers. Search
   for the resource name. Note that ActiveAdmin routes are auto-generated
   (member_action :checkin → POST /resource/:id/checkin).

6. **Check DB schema.** `db/schema.rb` is the ground truth for columns,
   indexes, and unique constraints. **Always check for unique indexes** — they
   are often the real validation, not model-level validations. Use `terminal`
   with `grep -n "table_name" projects/core/db/schema.rb` — the file is too
   large for `search_files` content search.

7. **Check migrations.** `db/migrate/` contains the history. Search for
   migration files matching the table or feature name to understand when and
   why constraints were added.

8. **Check specs.** `packs/<pack>/spec/` has model specs, concept specs (use
   case tests), and request specs. Use case specs often document the exact
   error messages and edge cases. Request specs show the HTTP-level behavior.

9. **Check Jbuilder views.** `app/views/` has `.json.jbuilder` files that
   define the JSON response shape. These show what fields are returned.

10. **For data inspection tasks, prefer creating a snippet.** When the user asks
    to query or look up data (e.g. "busque o último evolution check do caso X"),
    load the `create-rails-snippet` skill and build a reusable snippet instead of
    running queries directly via `rails runner`. The snippet is the deliverable;
    local execution is secondary. **Destination matters:** reusable/committed
    snippets go in the `code-snippets` repo (`rails-console/<domain>/`, shared and
    versioned — see that repo's `rails-console/CLAUDE.md`); `core/custom_gitignore/snippets/`
    is gitignored/local-only/throwaway. The user explicitly prefers durable snippets
    live in `code-snippets`, not the gitignored core dir.

11. **For pre-implementation territory mapping, return a structured report.**
    When the user asks to "investigar" or "mapear o território" for a feature
    (read-only, no code changes), return ONLY a structured summary with these
    sections:
    ```
    ## Investigação: core
    ### Tipo de projeto
    ### Pontos de entrada
    ### Fluxo principal
    ### Modelo <ModelName>
    ### Padrões existentes
    ### Constraints
    ### Dependências identificadas
    ### Dados disponíveis
    ### Pontos de atenção
    ```
    Do NOT write code, make implementation decisions, or propose solutions.
    Map the territory: what exists, where it lives, what patterns are used,
    what constraints apply, and what edge cases need clarification. The
    "Pontos de atenção" section is where ambiguous requirements (e.g.
    "last modified by" on an immutable resource) get flagged for product
    clarification.

## Pitfalls

- **Unique indexes are the real validation.** Models in this codebase often
  have NO model-level uniqueness validations — the DB unique index is the
  enforcement. Always check `db/schema.rb` for `unique: true` indexes.

- **Don't forget ActiveAdmin.** Some endpoints (checkin, checkout, session
  completion) are ActiveAdmin member actions in `app/admin/`, not in
  `app/controllers/`. If you can't find a controller, check admin.

- **A narrow "feature X stopped working" report can actually be a whole-app boot
  failure — check `git status`/`git diff` and syntax BEFORE diving into
  feature-specific investigation.** When core is a Docker container that's been
  running for days (`docker ps` shows `Up N days`) and a specific feature (e.g.
  a mobile device-registration endpoint) suddenly stops working with no code
  changes to that feature, a Ruby `SyntaxError` anywhere in an eager-loaded path
  (Zeitwerk autoload) can crash Rails app boot entirely — every controller,
  every use case, every endpoint returns 500, and the FIRST feature a user
  happens to exercise looks like "the bug," even though it's collateral damage.
  Symptom: `curl .../health_check` returns 500 with an HTML "SyntaxError" page
  naming an unrelated file deep in the Zeitwerk eager-load trace
  (`zeitwerk/loader/eager_load.rb`), not the feature's own file. **Procedure**:
  (1) `curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/health_check`
  first — if it's not 200, the whole app is down, not just the reported
  feature; (2) `git status` / `git diff` in `core` for uncommitted changes
  BEFORE assuming the reported feature's code is the culprit — an accidental
  bad edit/paste in a completely unrelated pack can break Zeitwerk eager load
  for everything; (3) `ruby -c <file>` on any file `git diff` shows as modified
  to confirm/rule out a syntax error; (4) after fixing, `docker restart
  core-app-1` and re-check `/health_check` → 200 before re-testing the
  originally-reported feature. Worked example: a stray uncommitted edit had
  merged two `step` calls onto one line
  (`), id: :find_discipline step Wrap(TrailblazerTransactionWrap) { step
  :update_discipline`) in
  `clinical_case_disciplines/use_cases/update_clinical_case_discipline.rb` —
  totally unrelated to the reported "UserDevice not registering" bug — but it
  crashed Zeitwerk eager load and took the whole app down, so nothing
  registered.

- **Running `rspec` inside the `core-app-1` container needs BOTH
  `DISABLE_SPRING=1` AND `RAILS_ENV=test` set explicitly, or you can hit a
  flaky `NameError: uninitialized constant VCR` even right after `bundle
  install` fixed the gem.** `spec/rails_helper.rb` does
  `ENV["RAILS_ENV"] ||= "test"`, but if Spring already has a preloaded process
  cached under `RAILS_ENV=development` (the container's default), a fresh
  `bundle exec rspec <spec>` can fork off that stale preload before the test
  env — and gems only available in the `:test` Gemfile group (like `vcr`)
  aren't loaded. `DISABLE_SPRING=1` alone was NOT sufficient to reproduce a
  clean run every time in this session; forcing both flags together
  (`DISABLE_SPRING=1 RAILS_ENV=test bundle exec rspec ...`) gave a consistent
  green run. If you still see `uninitialized constant VCR` after confirming
  the gem is installed (`bundle list | grep vcr`), also try `bundle exec
  spring stop` before retrying.

- **The core container's `init.sh` ENTRYPOINT mangles multi-word commands — override it with `--entrypoint bundle` to run anything other than the built-in verbs.** `Dockerfile` sets `ENTRYPOINT ["sh", "init.sh"]`; its fallthrough `*)` case is `exec sh -c "$@"`, and `sh -c "$@"` treats only the FIRST word as the command string. So `docker compose run --rm app bundle exec rspec <path>` silently runs just `bundle` (→ `bundle install`) and never reaches rspec — symptom: output ends at "Bundle complete! ... N gems now installed" with no test output. Fix: `docker compose run --rm --entrypoint bundle -e DISABLE_SPRING=1 -e RAILS_ENV=test app exec rspec <path>`. For a fresh checkout the test DB also needs `--entrypoint bundle ... app exec rails db:create db:schema:load` first (`db:schema:load` does NOT seed; a factory that depends on a seeded enum like `:speech_therapy`/discipline may still fail with "Discipline must be one of: ").

- **Namespaced models.** Models are deeply namespaced
  (`Intervention::Evolution::EvolutionCheck`). The file path mirrors the
  namespace: `app/models/intervention/evolution/evolution_check.rb`.
  The table name is explicit (`self.table_name = "intervention_evolution_checks"`).

- **Use cases delegate to sub-use-cases.** A parent use case (like
  `CreateEvolutionCheck`) often delegates to child use cases based on a
  `configuration_type` or similar discriminator. Read the parent first to
  understand the dispatch, then read the relevant child. When the
  discriminator is a `configuration_type` enum (trial_counter, checklist,
  etc.), each child use case has its own `Dry::Validation::Contract` with
  type-specific required/optional fields. To determine which attributes are
  actually required vs optional in practice (especially for logical STI
  where there's no `type` column), query BigQuery for NULL fill rates per
  type — see `references/evolution-check-types-and-disciplines.md` for a
  worked example.

- **Logical STI (no `type` column) needs BQ to determine required fields.**
  When a model has sub-types determined by an enum on a related record
  (not an ActiveRecord STI `type` column), the schema.rb won't tell you
  which fields are required per sub-type — the columns are all nullable.
  The Dry::Validation contracts define the rules, but to verify what's
  actually filled in production, query BigQuery:
  `SUM(CASE WHEN col IS NOT NULL THEN 1 ELSE 0 END) AS has_col` grouped by
  `configuration_type` and `was_assessed`. This reveals the de-facto
  required/optional split per type. The `code-snippets` project has `bq`
  CLI access — use `bq query --use_legacy_sql=false --format=pretty`.

- **Feature docs for non-technical audiences.** When the user asks for a
  feature analysis document that non-devs can understand ("menos técnico",
  "para uma pessoa que não é dev"), shift the output from code-level to
  product-level: describe what appears on screen (static data vs what the
  user fills in), the layout order of UI elements top-to-bottom, real-world
  examples of configurations, and a comparative table across types/variants.
  The `/analyze-feature` command template is technical by default — the user
  will explicitly say when they want the non-technical version. Useful
  sources for product-level detail: `src/i18n/locales/<feature>/pt-br.json`
  in the frontend project for Portuguese labels shown to users; the
  `getProgramType` utility (e.g. in `EvolutionCheck/utils.ts` for
  clinical-panel) maps disciplines to UI components; `Tooltip` and `Alert`
  components often carry user-facing explanatory text.

- **Verify behavioral claims before stating them in feature docs.** When
  writing a feature analysis, claims like "this is mandatory" or "the system
  checks if X exists for this case" are easy to get wrong by reading only
  one layer. Trace the full chain: frontend navigation hook (e.g.
  `useCheckinCheckoutFlowNavigation` — `isSkippable` tells you if it's
  optional) → BFF resolver (which `dataSources` method is called, and on
  which GraphQL type — `User` vs `ClinicalCase` matters for scoping) → core
  controller (what filters are applied — `by_session_clinician` means
  per-clinician, not per-case). Stating "obrigatória" when the page is
  `isSkippable: true`, or "per-case" when the controller filters by
  `clinician_id`, are exactly the kinds of errors the user will catch.
  When in doubt, read the navigation hook AND the controller, not just one.

- **Error messages are in `handle_errors` / `fail` steps.** The exact error
  message and code are typically constructed in a `fail` handler step, not
  in the main processing step. Look for `ctx[:errors] <<` or
  `ctx[:errors] =` in the fail handlers.

- **`correlation_id` idempotency can mask the real error.** When a
  `RecordNotUnique` is rescued and `find_by(correlation_id:)` returns nil
  (different correlation_id), the use case falls through to a generic error
  handler. The real constraint (unique index on a foreign key) is not
  mentioned in the error message — you need to check the DB schema.

- **STI type migration needs `update_column` for both columns at once.**
  When changing a record's STI type (e.g. `Clinical::Agreements::Embedded`
  → `Clinical::Agreements::NativeForm`), the target subtype may validate
  columns that the source didn't have (`NativeForm` validates
  `native_form_type` presence). Use `update_column` (not `update`) for each
  column to bypass validations, and set **both** the `specific_type`
  (inheritance column) and the subtype-specific column
  (`native_form_type`) — a single-column update would temporarily violate
  the target subtype's validations. See
  `references/agreement-sti-copm-migration.md` for the full pattern.

- **Packs have their own spec directories.** Don't look for specs in the
  root `spec/` — they're in `packs/<pack>/spec/` with subdirectories for
  `models/`, `concepts/`, `requests/`, etc.

- **Snippet errors are usually the snippet, not the repo.** When a user
  reports an error from a Rails console snippet or ad-hoc script, read the
  relevant spec file and compare how the spec calls the same use case or
  model before touching repo code. The error is frequently in the caller's
  usage (wrong argument type, `.to_i` stripping a Duration into an Integer,
  wrong enum value, missing tenant scope). Fix the snippet, not the repo.
  Example: `ClinicalCaseWorkload` has `attribute :hours, :interval` and a
  `before_save` callback calling `hours.in_minutes`. Passing `4.hours.to_i`
  (Integer) breaks it; passing `4.hours` (ActiveSupport::Duration) works —
  which is exactly what every spec does.

- **schema.rb is too large for search_files.** Use `terminal` with `grep -n`
  to search `db/schema.rb` instead of `search_files` — the file is enormous
  and content search may not match reliably.

- **search_files on symlinked projects returns empty silently.** `projects/core/`
  (and all repos under `projects/`) are symlinks created by `sync.sh`.
  `search_files` with `path=projects/core` may silently return 0 results
  even when the files exist on disk. Always verify with `ls projects/core/`
  first. Fall back to `terminal` with `find packs -name "*.rb" | xargs grep -l`
  when you get empty results from a symlinked path.

- **Models live in `packs/`, not `app/models/`.** The core is a pack-based
  Rails monolith (Packswerk). Only a handful of top-level models live in
  `app/models/` — everything else is under `packs/<pack>/app/models/` with
  deep namespacing. To find a model by class name, use `find packs -name
  "*.rb" | xargs grep -l "ClassName"`. A directory listing of `app/models/`
  will miss 90%+ of the models. (`Documents::ClinicalCaseFile` is one of the
  top-level exceptions: it lives in `app/models/documents/clinical_case_file.rb`,
  NOT in a pack, with `self.table_name = "documents_clinical_case_files"`.)

- **CDC table names in BQ do NOT always match the Postgres table name — always
  confirm the `raw.*_events` name before assuming it.** `documents_clinical_case_files`
  (Postgres) is replicated to BQ as **`raw.clinical_case_documents_events`** (plus a
  `clinical_case_documents_events_v1` variant and a `datakernel.clinical_case_documents`
  view) — there is NO `documents_clinical_case_files_events` table. The user's heuristic
  when a CDC lookup comes up empty: the BQ table is often renamed to a *broader/older*
  concept (here "file" → "document"), so search Metabase/BQ for the model's domain term
  (e.g. "clinical_case_documents") rather than the literal Postgres table name. To list
  candidates: Metabase `search(term_queries=["clinical_case_documents"])` or
  `bq query "SELECT table_name FROM <proj>.raw.INFORMATION_SCHEMA.TABLES WHERE table_name LIKE '%document%'"`.
  The `raw.*_events` payload fields mirror the Postgres columns (`payload.id`,
  `payload.document_type`, `payload.name`, `payload.clinical_case_id`, `payload.created_by_id`,
  `payload.updated_by_id`, `payload.created_at`), plus `source_metadata.change_type`
  (INSERT/UPDATE/DELETE), `source_metadata.is_deleted`, and `source_timestamp`.

- **When the `bq` CLI auth has expired (\"Reauthentication failed\"), the Metabase MCP
  (`mcp__metabase__*`) is a read-only fallback for querying the `raw` CDC tables — the
  external tables are exposed there with `payload.*` / `source_metadata.*` field_ids.** Path:
  `search(term_queries=[...])` → `get_table(id=..., with-fields=true)` to map field_ids
  (`t<id>-N`) → `query(table_id=..., filters=[{field_id,operation:"equals",value}],
  order_by=[{field_id, direction}])`. Filter on `payload.id` + read `source_metadata.change_type`
  ordered by `source_timestamp` to reconstruct INSERT/UPDATE/DELETE history for one record.
  The Metabase result echoes the generated SQL in `native_form.query` — useful to copy the
  exact BQ SQL for a later `bq` run. DELETE rows only carry `payload.id` (other payload
  fields NULL, `is_deleted=true`) — same Datastream limitation as the raw SQL path.

- **search_files can fail on patterns with dots/special chars.** When
  searching for topic strings like `clinical_case.workload` (containing
  dots), `search_files` with `output_mode="content"` may raise a JSON
  parse error. Fall back to `terminal` with `grep -rn 'pattern' --include='*.rb'`
  instead. The `files_only` output mode is more resilient but still
  occasionally fails — `grep` via `terminal` is the reliable fallback.

- **Keep snippet output concise.** When writing investigation or migration
  snippets that process many records, print summary counts and only anomalies
  (duplicates, missing cases, errors) — not a full dump of every record.
  The user said "ficou confuso de analisar pois tem muitos dados" when a
  snippet listed all 284 agreements with full details. One line per record
  with a `#number` prefix for easy scan; end with a summary line.

- **Backfill rake tasks need a permanent mechanism for new tenants.**
  When reviewing or creating a backfill rake (e.g.
  `backfill_missing_clinical_case_file_type_configs.rake`), always check
  whether there is a callback, job, or hook that creates the same data for
  NEW tenants. If the only call site is `db/seeds.rb` (dev/test only), the
  rake solves the existing data gap but the bug will recur for every new
  tenant. Surface this to the user — the fix needs either an `after_create`
  on `Tenant`, a provisioning job, or a scope that degrades gracefully when
  configs are missing. The user's exact concern: "ao criar a rake, a gente
  vai ficar refém de sempre precisar rodar ela para novos tenants".

- **`by_config_scopes` scope hides files when configs are missing.**
  `Documents::ClinicalCaseFile.by_config_scopes` filters by document types
  that have a `ClinicalCaseFileTypeConfig` matching the requested scope. If
  a tenant has no generic config (insurance_health_plan=nil, discipline=nil)
  for a document type, files of that type become invisible — the scope
  returns an empty set, not a fallback. The `DocumentTypeConfigResolver`
  has a fallback chain (plan-specific → generic → enum), but the scope does
  NOT — it only uses the DB. This asymmetry is the root cause of "documentos
  invisíveis" bugs. When investigating document visibility issues, check
  both the scope (DB-only, no fallback) and the resolver (has enum fallback).

- **`DocumentTypeConfigResolver` fallback chain.** The resolver tries in
  order: (1) config matching document_type + plan + discipline, (2) config
  matching document_type + plan, (3) config matching document_type only,
  (4) `payload_from_enum` (computed from enum constants, no DB record).
  This means the resolver always returns a value — but the
  `ClinicalCaseFileTypesPresenter` and the `by_config_scopes` scope only
  look at DB records, so they can return empty when the resolver would
  return data. When debugging "document appears in one place but not
  another", check which path each consumer uses.

- **`ClinicalCaseFileTypeConfigBackfill` has two entry points.**
  `call(tenant:)` — the original method, uses `find_or_initialize_by` +
  `save!` (bang method, used in seeds). `build_generic_config(tenant:,
  document_type:)` — added for the backfill rake, returns an unsaved
  config with defaults assigned via `assign_defaults`. The rake calls
  `build_generic_config` + `config.save` (non-bang, per AGENTS.md rule).
  When extending the backfill, use `build_generic_config` for the rake
  pattern (dry-run friendly) and keep `call` for seeds.

- **`DictionaryRecord::Configuration#metadata_for` always returns a Hash (never nil).** The method has a `|| {}` guard in `dto.rb:25`. Calling `.dig(...)` on its return value can never raise `NoMethodError` — if you see `Hash#dig` in a stack trace involving this chain, the error is NOT in the `dig` call itself. It's either a downstream issue (the `nil` result breaks a later validation) or the `metadata` JSONB blob has an unexpected shape (e.g. `specialization_to_map` is a string instead of a hash, which would show as `String#dig`, not `Hash#dig`). Start by checking what `params[:discipline]` actually resolves to and what the DB record's `metadata` column contains.

- **Before shipping a frontend null-guard fix, verify the null is safe across the WHOLE stack, not just at the DB.** When the bug is "frontend crashes / blank screen when field X is null/missing" and the fix on the table is a simple optional-chaining patch, don't apply it on hypothesis alone — confirm the null is an *intentional, already-supported* state at every layer, not a symptom of a deeper contract violation:
  1. **Core model** — is the association/column actually nullable? `belongs_to :skill, ..., optional: true` (or `change_column_null ..., true` in a migration) confirms the DB genuinely allows it, not just "happens to be null for old data".
  2. **Core serializer (jbuilder)** — does it guard the nested object? `if library_objective.skill.present? ... end` means core deliberately *omits* the key rather than emitting `null` — the API contract already treats absence as normal, not an oversight.
  3. **Dry::Validation contract** (create/update use case) — `optional(:skill).maybe(:hash)` confirms *writes* with no value are accepted too, not just reads of legacy data.
  4. **BFF GraphQL schema** — field declared without `!` (e.g. `skill: Skill`, not `skill: Skill!`) confirms the BFF's own contract already promises nullability downstream; no resolver/mapper assumes non-null.
  Only when all four hold is the frontend fix a pure bug fix (missing `?.`) rather than a papering-over of a broken upstream contract. This is a ~10-tool-call cross-repo check (grep the model, jbuilder view, contract file, and BFF type-defs) that's cheap compared to shipping a fix that masks a real backend gap. Worked example: `useSpeechTherapyForm.ts` crashed on `libraryObjective?.skill.name` (missing `?.` after `.skill`) for the 93% of Fono library objectives with `skill_id IS NULL` in production — confirmed safe via `Intervention::Pei::Library::Objective#belongs_to :skill, optional: true`, the `_protocol_item.json.jbuilder` guard, the `create_objective_contract.rb` `optional(:skill).maybe(:hash)`, and the BFF's `skill: Skill` (no `!`) in `type-defs.graphql` — all four already treated missing skill as normal before the frontend fix was applied.

- **Compare sibling use cases when debugging.** When `create_collaborator.rb` and `update_collaborator.rb` implement similar logic, differences are diagnostic signals. Example: `create_collaborator.rb:47` uses `.dig("specialization_to_map", "name")` directly, while `update_collaborator.rb:230` uses `&.dig("specialization_to_map", "name")` with safe navigation. The `&.` was likely added as a defensive fix after a production issue — the missing `&.` in the create path may be the bug.

- **After finding one missing safe-navigation bug, check every sibling
  use case for the same missing guard — don't stop at the one that crashed.**
  When a Trailblazer parent use case dispatches to N per-discipline/type
  children (e.g. `CreateProgram` → `CreateAbaProgram` /
  `CreateSpeechTherapyProgram` / `CreateSimpleProgram` /
  `CreateOccupationalTherapyProgram` keyed by `program_type`), and one child
  crashes on `record.optional_assoc.name` (no `&.`), grep the sibling files
  for the exact same association access. Some siblings will already have the
  defensive pattern (`objective.skill&.name`,
  `library_objective.skill&.name || library_objective.protocol_item&.protocol&.name`)
  — that's evidence of a prior undocumented fix for the same class of bug,
  and any sibling still using bare `.name` is a live landmine even if it
  hasn't been reported yet. Report ALL affected siblings and their fix in
  the same pass, not just the one the user hit. Worked example: `create_speech_therapy_program.rb:38`
  (`library_objective.skill.name`, unguarded) crashed after a rake
  (`speech_therapy:import_objectives`) created `Library::Objective` rows
  with `skill_id: nil`; `create_simple_program.rb:47` had the identical
  unguarded pattern and was flagged as equally at-risk even though it hadn't
  crashed yet, while `create_aba_program.rb` and
  `create_occupational_therapy_program.rb` already used `&.` + fallback.

- **Extracting the real Rails error from an embedded 500 HTML page.** When a
  GraphQL/BFF error response wraps a full Rails "Action Controller: Exception
  caught" HTML page as an escaped string (huge — can be 250KB+ and blow past
  normal read limits), don't try to read it top-to-bottom. Search directly for
  the diagnostic markers: `NoMethodError` / `ArgumentError` (exception class,
  appears in the `<h1>`), `"exception-message"` (wraps the human message, e.g.
  "undefined method 'name' for nil"), and `"line active"` (the highlighted
  source line in the backtrace with an `error_highlight` span pinpointing the
  exact expression that failed, e.g. `library_objective.skill<span
  class="error_highlight">.name</span>`). Use `execute_code` to load the
  large tool-output file and `str.find(...)` for these markers instead of
  reading megabytes of CSS/HTML — this took under 5 tool calls to go from
  "500 Internal Server Error, no other info" to the exact file, line, and
  broken expression.

- **Prefer use cases over raw updates for data mutation.** When a snippet
  mutates records, always check if a Trailblazer use case exists for the
  action (e.g. `Agreements::UseCases::MakeComplete` for completing agreements).
  Use cases encapsulate validations, event emission (`AgreementCompleted`,
  etc.), and business rules that `update_column` bypasses. Only use
  `update_column` when you deliberately need to skip callbacks/validations
  (e.g. STI type migration where the target subtype validates a column the
  source didn't have). The user explicitly asked to "sempre usar UseCase
  quando possível pois lá pode conter validações, envio de eventos e tal".

- **Verify file paths in prior analysis/user-story docs — packs get reorganized
  over time.** A decorator/model path documented weeks ago may have moved
  between packs since. Example: `People::ChildDecorator` was documented at
  `packs/clinical/app/decorators/people/child_decorator.rb` in an August
  analysis doc, but by the time the story was resumed it had moved to
  `packs/operational/app/decorators/people/child_decorator.rb`. Always
  re-`search_files`/grep for the class name to confirm the current path before
  trusting an old doc, especially when resuming a paused user story after
  weeks of other work landed.

- **Where to place a calculation that crosses pack domains (Core vs BFF): the packwerk dependency direction is a HARD constraint, not a style preference.** When a feature computes a value from inputs in two packs whose dependency direction runs the wrong way, "move it into Core" is often *blocked by the pack graph*, not merely discouraged. Concretely: the "Ideal Genial" HBJ calc (`CalculateSharedScheduleHoursWorkload`) is purely clinical (`clinical_case_workloads` + `pei_track.current_module`), so it lives cleanly in `packs/clinical`; but the "practical" HBJ needs `Child#scheduled_hours_by_discipline(status: :official)["aba"]`, which is operational (`Scheduling::Schedule`). Putting that in the clinical pack requires `clinical → operational`, a cycle packwerk forbids. Options, in rising cost: (a) keep both raw inputs exposed and compose in the BFF — the intended layer for crossing domains (it speaks HTTP, not pack-internally), and usually right for a single-consumer derived value; (b) compute in the pack that *already* depends on the other (`operational` depends on `clinical`, so it *can* read `PeiModule#percent_of_playtime_together_sessions`) — but that splits one business concept (HBJ) across two packs, itself an architectural smell; (c) refactor to break the cycle or extract a shared pack — a domain refactor disproportionate for a display value. Heuristic: with a SINGLE consumer (one UI card), compose in the BFF and centralize only the residual *business rule* (percentages, rounding) into a persisted column/endpoint both sides read; revisit centralizing in Core only when a SECOND consumer needs the same computed number. Worked example in `references/clinical-case-workload-investigation.md` (§ "Practical HBJ hours").

- **When comparing Core/BFF/Frontend options for where to calculate something,
  decompose EVERY distinct piece of business logic separately when assessing
  duplication — don't treat "the calculation" as one blob.** A "middle
  ground" option (e.g. Core exposes one derived value, BFF does the final
  arithmetic) can eliminate duplication of a COMPLEX derived value while
  still silently duplicating a SIMPLE constant table that a reviewer will
  immediately spot. List each business rule involved and check it against
  each candidate option individually. Worked example in
  `references/clinical-case-workload-investigation.md` (§ "Practical HBJ
  hours"): comparing where to calculate a module-based percentage of
  scheduled hours, "which module is current" is a non-trivial derived value
  already computed and persisted by `PeiTrack#calculate_progress` — exposing
  it avoids re-deriving it elsewhere — but the percentage-per-module constant
  table (`{module_1: 0.15, module_2: 0.40, module_3: 0.60}`) is a separate,
  simpler piece of business logic that can still end up duplicated in the
  BFF/frontend even in an option that avoids the first duplication.
  Mitigation: have Core expose the already-resolved percentage for the
  current module too, not just the module's name/alias, so nothing outside
  Core needs to know the constant table at all.

- **A new persisted `workload_type` (or similarly-scoped persisted record
  type) needs a backfill rake, mirroring the existing
  `create_shared_schedule_workloads.rake` pattern, if the value should exist
  for cases that already existed before the feature shipped.** Persisting a
  new derived value as a new row/type on an existing model (e.g. a new
  `ClinicalCaseWorkload.workload_type`) only populates going forward, driven
  by whatever events already trigger the calculation use case. Existing
  clinical cases will show "—" until one of those events fires again for
  them (e.g. next PEI module change). Decide explicitly with the user
  whether to (a) backfill via a rake styled after
  `core/lib/tasks/create_shared_schedule_workloads.rake` (dry-run first,
  scoped to eligible cases, wraps the per-case use case call in a
  transaction with rollback on any failure) or (b) accept the value staying
  empty until the natural trigger events recompute it — don't assume either
  without asking, since it changes what day-one looks like for the feature.

- **`Wrap(TrailblazerTransactionWrap)` reverts EVERY statement inside it via `raise
  ActiveRecord::Rollback` the instant one internal step returns falsy — and this produces
  ZERO error signal: no exception, no error log, no error-tagged APM span.** The wrapper
  (`app/infra/trailblazer_transaction_wrap.rb`) does
  `ActiveRecord::Base.transaction { signal, ... = yield; raise ActiveRecord::Rollback unless
  success }`. A Datadog APM trace captures every `postgres.query`/`pg.exec.params` span as it's
  *emitted* to Postgres — including ones inside a transaction that gets rolled back seconds
  later. **A trace showing `INSERT INTO some_table ...` succeeding is NOT proof the row
  exists** — always cross-check against the actual current DB/BigQuery state before concluding
  a write persisted. Symptom: a business action appears to "half-work" (e.g. a session's
  `session_type` field changes permanently because that UPDATE ran in an EARLIER, separate
  transaction, but a downstream registry/child record that should have been created in the
  SAME later transaction never exists) with no error anywhere in logs or error tracking —
  because the whole transaction (registry creation, child inserts, deletes, everything) was
  inside one `Wrap(TrailblazerTransactionWrap)` block that later rolled back as a unit when
  one internal step silently returned `false` (e.g. a `.valid?` check, a `.destroyed?` check).
  To find the real culprit step, reproduce locally with `rails runner`/console and check each
  step's return value directly — trace inspection alone will mislead you into thinking the
  writes succeeded. Worked example: `UpdateInterventionSessionToAssessment`'s wrap showed a
  full successful-looking trace (registry INSERT, ~40 child assessment INSERTs, the linking
  UPDATE, the intervention-session DELETE) for a session whose
  `assessment_occupational_therapy_registry_id` is `NULL` in BigQuery both on the day of the
  incident and today — proving the transaction rolled back despite the trace showing every
  query executing cleanly.

- **A model's own `self.create` can hide a SECOND, inner transaction (`transaction(requires_new:
  true)`, i.e. a Postgres SAVEPOINT) that swallows `RecordNotUnique`/`RecordInvalid` internally —
  this can explain a `TrailblazerTransactionWrap` write that "half-persists" even when you've
  already ruled out the outer-wrap-rollback explanation above.** Some models define their own
  `self.create(...)` wrapping a `transaction(requires_new: true) { create!(...) ... }` with a
  `rescue ActiveRecord::RecordNotUnique` / `rescue ActiveRecord::RecordInvalid` that returns `nil`
  on failure (grep `requires_new: true` repo-wide to check). Because `requires_new: true` opens a
  **new SAVEPOINT nested inside** whatever `Wrap(TrailblazerTransactionWrap)` transactions are
  already open (checkout → complete → clinical use case → subprocess can be 4 levels deep), a
  failure inside that model method rolls back ONLY its own savepoint — the outer transactions stay
  open, valid, and go on to commit their own separate writes normally. This is a MORE precise
  failure mode than "the whole Wrap rolled back": some fields persist (e.g. `session_type`,
  `status: completed`) while a specific nested record (e.g. a `Registry`) never exists, with no
  exception anywhere in logs/APM because the model's own `rescue` ate it.
  - **When this savepoint-swallowed-exception pattern is live, check for a PARTIAL UNIQUE INDEX
    (`WHERE status = '...'`) on the table** (`grep -n "unique: true" db/schema.rb` for that table).
    If one exists, the `RecordNotUnique` path is not hypothetical — it's the schema-enforced
    consequence of two concurrent requests racing to create the "one active row per parent" record
    (e.g. two near-simultaneous checkout submissions, or a frontend retry-on-timeout). CDC evidence
    of this race: two UPDATEs on the exact same row landing in the exact same source timestamp
    (down to the second) in `raw.<table>_events` — a strong tell that two requests, not one, touched
    the record.
  - **CORRECTION — this bullet was REFUTED by a direct two-connection Postgres test (2026-09; run `scripts/verify_unique_index_blocking.py`). PostgreSQL's unique index uses *speculative insertion*: the loser's `INSERT` BLOCKS on the winner's uncommitted row, so `create!` does not raise `RecordNotUnique` until the winner COMMITS — by then the winner's row is committed and visible, so `find_by` RETURNS it and the loser REUSES it (never `nil`). Consequence: this race does NOT explain a "missing registry / FK NULL" bug — the loser always ends up with a registry (its own or the winner's). Do not treat it as confirmed root cause; re-open the investigation (candidates: a step returning `false` that IS logged but out of log-retention, an exception from a `!` method like `mark_as_started!` that bypasses the fail-track, or two sequential requests where an earlier request commits `session_type` and a later one fails).** Original (incorrect) text below: the `rescue RecordNotUnique` reload for the "losing" request can still return the wrong
    result under Postgres `READ COMMITTED` (the default): a `find_by(status: 'started')` running
    inside the loser's own still-open outer transaction/savepoint cannot see rows created by the
    winner's transaction until the winner COMMITS.** If the winner's outer `Wrap` chain hasn't
    committed yet (still several levels up the call stack), the loser's reload finds `nil`, the
    step fails "for no visible reason," and its own transaction chain rolls back — while the
    winner's commit later succeeds normally. This reproduces as a genuine race only with two
    concurrent connections; a single-threaded Rails console reproduction will NOT surface it. To
    prove it, either drive two real concurrent requests (threads/processes with separate DB
    connections) or reason from the schema constraint + CDC double-update evidence when a live
    concurrency repro isn't available (e.g. Docker/tooling blocked) — state the confidence level
    state the confidence level explicitly rather than presenting a plausible read as a confirmed root cause.\n  - **When you find this race on a partial unique index, check SIBLING methods for an already-applied lock fix before proposing one.** The same class of race often exists in two methods of the same model/flow — one may already have the fix, which tells you (a) the fix pattern that was accepted here and (b) exactly which method still needs it. Worked example: `Assessments::OccupationalTherapy::Registry` had a race fixed in `recalculate_status!` (the *completion* path) via `with_lock` in June 2026 (commits `9eb155d9d7` / `c56a7e8497`, PR #6011), but the *creation* path `find_or_create_assessment_registry` (in `UpdateInterventionSessionToAssessment`) still has no lock and is the live bug. One `git log --oneline -- <registry>.rb` plus `grep -n 'with_lock\\|lock!' <registry>.rb` surfaces both the sibling fix and its absence; the recommended fix is usually the same `with_lock` / `SELECT ... FOR UPDATE` on the offending read.

- **The \"savepoint-swallowed-exception → partial commit\" hypothesis is ALSO REFUTED — a `Wrap(TrailblazerTransactionWrap)` rolls back EVERYTHING when any inner step returns falsy, even a step whose model method swallowed its own exception.** Reproduced directly (2026-09) by stubbing `Assessments::SpeechTherapy::Registry.create` to return `nil` and calling `UpdateInterventionSessionToAssessment.call`: the result was `success=false` AND `session_type` reverted to `intervention`, the `assessment_session` row was NOT created, and the intervention session was NOT deleted — a **full** rollback, not a partial commit. The chain is: model `self.create` returns `nil` (its own `requires_new` savepoint rolled back) → the step does `return false unless registry` → that falsy return triggers the step's `fail` handler (`fail_fast: true`) → the outer `Wrap(TrailblazerTransactionWrap)` sees the fail terminus and `raise ActiveRecord::Rollback` → the WHOLE transaction (including the EARLIER `session.update(session_type: DIRECT_ASSESSMENT)` step) rolls back. **So \"session_type persists while the registry doesn't\" is IMPOSSIBLE when both live in the same Wrap.** If production data shows `session_type = direct_assessment` (persisted) but `assessment_*_registry_id = NULL`, the subprocess SUCCEEDED — the registry was created and linked, then **DELETED afterward**, and the link nullified by `has_many :assessment_sessions, dependent: :nullify` on the registry model. The delete path is `Assessments::UseCases::Delete<Speech|Occupational>TherapyAssessmentsRegistry` (called by `*_assessments_registries_controller.rb` DELETE endpoints, `registry.destroy`; they refuse when the registry is already `completed?`). RESOLVED (16/09/2026): the delete is a real, user-initiated action (frontend `DeleteRegistryButton` + confirmation modal), confirmed via APM span search `resource_name:*Delete*AssessmentsRegistry*` (28 spans/30d, all `ok`). It's a design gap: the delete nullifies the registry link but does NOT revert `session_type`, and the resulting `direct_assessment`-with-NULL-registry session is UNRECOVERABLE (`validate_session` only accepts `intervention`). Do NOT re-investigate rollback/race/partial-commit. See `references/direct-assessment-registry-null-investigation.md` for the full trail and reproduction recipes.

- **When confirming a suspected race condition via sibling-record data, distinguish the CREATION timestamp from the BUSINESS-ACTION timestamp — comparing the wrong column produces a false concurrency signal.** In the sessions domain, `sessions.created_at` is when the session was *scheduled* (the operational panel batch-creates several sessions for one case in the same second), while the conversion to `direct_assessment` — where the registry is actually created and the race would occur — is a LATER, separate write. The correct proxy for conversion time is `assessment_sessions.created_at`: the `AssessmentSession` row is created by the conversion subprocess's `create_assessment_session` step, so its `created_at` marks the conversion. Querying "another session of the same case+discipline saved at nearly the same time" on `sessions.created_at` returns a pile of 0-second "twins" that are just batch scheduling (a red herring); the same query on `assessment_sessions.created_at` (conversion time) returned ZERO siblings within 120s — correctly ruling out a two-different-sessions race and pointing instead at a single-session double-conversion (frontend retry / double-click) or a deterministic failure. Before concluding "it's a race", confirm which timestamp column actually represents the business action being raced on, and re-check whether the "near-simultaneous" pattern survives when you switch to that column.

- **Trailblazer `.call` takes a positional Hash, not keyword args.**
  Use cases extend `Trailblazer::Activity::Railway` whose `.call` expects
  a single positional hash (the ctx), not Ruby keyword arguments. Write
  `MakeComplete.call({id: agreement.id, user: user})` — with the explicit
  `{}` — NOT `MakeComplete.call(id: agreement.id, user: user)`. Bare
  keyword args produce `ArgumentError: wrong number of arguments (given 0,
  expected 1)`, which is non-obvious because the error doesn't mention
  kwargs vs hash. The return value is a tuple `status, (ctx, signal)` —
  destructure with `_, (ctx, _) = UseCase.call({...})` and check
  `ctx[:clinical_agreement]&.completed_at` or `ctx.success?` (depending on
  the activity type). Always check how the controller or spec calls the
  same use case before writing a snippet — controllers are the canonical
  calling pattern (e.g. `clinical_agreements_controller.rb`).

- **Use case business-rule guards can refuse an operation.** Some use
  cases have validation steps that reject the operation before touching
  the DB (e.g. `DeleteOccupationalTherapyAssessmentsRegistry` refuses if
  the registry `completed?` — returns `invalid_deletion` end with
  "occupational_therapy_assessments_registry is already completed"). When
  a snippet mutates via a use case, check `ctx.success?` and surface
  `ctx.errors` (`e[:message]`, `e[:code]`) on failure — do NOT fall back
  to raw `destroy` / `update_column` when the use case refuses. The
  refusal IS the business rule working correctly.

- **`current_user` for snippets.** Use cases that mutate data require
  `current_user:`. For snippets, obtain it via
  `User.find_by(email: "dev@genialcare.com.br")` or `User.system_user`.

- **`Style/StringLiteralsInInterpolation`: use double quotes inside
  interpolation.** standardrb flags single-quoted strings inside `#{...}`
  in a double-quoted string. Write
  `strftime("%d/%m/%Y %H:%M")` not `strftime('%d/%m/%Y %H:%M')` when
  inside a `"..."` string. Run `bundle exec standardrb` (direct, no Docker)
  after writing snippets to catch this and other style issues.

- **Don't over-invest in local snippet execution.** Snippets are designed
  for `rails console` in staging/production. If local execution fails due
  to missing environment data (tenant "genialcare" not in dev DB, Spring
  fork errors, etc.), verify syntax with `bundle exec standardrb` and stop.
  Do not spend multiple attempts troubleshooting quoting, Spring, or
  missing DB records just to run locally.

- **Querying Core data directly via `rails runner` to verify a surprising BFF value — handle multi-tenancy explicitly, and check the INPUT before blaming the BFF calculation.** When a BFF-computed GraphQL value looks wrong, don't fight HTTP auth to the Core; query the DB directly with
  `docker compose exec -T -e DISABLE_SPRING=1 app bundle exec rails runner`.
  Gotchas that cost multiple attempts this session:
  1. `ApplicationRecordTenant` models raise `ActsAsTenant::Errors::NoTenantSet` when queried outside a tenant scope. To find a record when you DON'T yet know its tenant: `ActsAsTenant.without_tenant { ClinicalCase.find_by(id: "...") }` → read `record.tenant_id`, then `Tenant.find(tenant_id)` and wrap the real query in `ActsAsTenant.with_tenant(tenant) { ... }`.
  2. Inline multi-line scripts through `docker compose exec` get mangled ("Please specify a valid ruby command"). Write the script to a file in the repo root and run `rails runner /app/<file>.rb` (the repo is mounted at `/app`) — confirmed working this session.
  3. Association names are **singular for `has_one`** — `cc.child` (not `cc.children`), `cc.pei_track` (not `cc.pei_tracks`).
  4. Decorator-only methods are NOT on the model. `calculated_official_scheduled_hours_by_discipline` lives on `People::ChildDecorator`; the model equivalent is `scheduled_hours_by_discipline(status: :official)` (returns `{ "aba" => Float, "speech_therapy" => ..., "occupational_therapy" => ... }`).
  Worked example: a user reported `feasiblePlaytimeTogetherHours = 1` "with 0 scheduled hours" and suspected a BFF bug — querying the Core showed `aba = 2.0` (two active official schedules), so the surprising "1h" came from `2.0 * 0.15 = 0.3` flooring to 1 via the rounding rule, not a BFF error. **The input was not what the user assumed — verify it before re-reading the resolver.**

- **Querying PRODUCTION core data read-only: `kubectl exec` + `bin/rails runner` + `safe_unscoped_with_tenant` (NOT the local-Docker path above).** For "does this data actually exist in prod?" — verifying a claim in an analysis/user-story doc against live data — the authoritative path is the real pod, not BigQuery: the prod BQ mirror (`supervision-production-8f1v.intervention.objectives`) can return **0 rows for the service account** (row-level access policy) while `bq show` still reports non-zero metadata, so only a live Postgres scan is ground truth. Steps:
  1. Re-auth the gcloud service account (tokens expire ~daily): `gcloud auth activate-service-account --key-file=~/.config/gcloud/regis-automation-sa-key.json`, then `rm -f ~/.kube/gke_gcloud_auth_plugin_cache` (kubectl otherwise reads a stale auth cache and fails with "Reauthentication failed").
  2. `kubectl get pods -n core` → pick a `web-*` pod.
  3. `kubectl exec -n core <web-pod> -c web -- bash -c 'cd /app && bin/rails runner "<ruby>"'` — the app lives at `/app`; keep the Ruby single-line inside double quotes (the outer `bash -c '...'` makes the nesting survive). **For multi-line Ruby, prefer the stdin pipe instead** — write the script to a local file and pipe it: `kubectl exec -n core <web-pod> -c web -i -- bash -c 'cd /app && bin/rails runner -' < /tmp/script.rb`. This avoids the quoting hell of nesting multi-line Ruby inside `bash -c '...'` / double quotes (SQL string literals with single quotes, `"`-delimited Ruby, etc. all collide), and `rails runner -` reads the program from stdin.
  4. For a GLOBAL count across tenants use `.safe_unscoped_with_tenant` — **never `unscoped`** (AGENTS.md rule). A bare `.count` under acts_as_tenant with no current tenant silently returns 0; `Model.safe_unscoped_with_tenant.where(...)` is the correct read-only global form.
  Worked example: verified `Intervention::Pei::Objective` rows without `library_objective_id` (274 live, 204 → `ProtocolItem` + 70 → `Protocol`) via this path — see `references/speech-therapy-assessments-and-objectives.md` (§ "Verified in production").

- **"Discarded item still showing in UI" bugs: compare sibling components
  before assuming a backend problem.** When the user reports that a
  soft-deleted/discarded record still appears somewhere in the UI, and they
  mention "I think this was already fixed for other cases/forms/flows,"
  that's a strong signal to find the sibling implementations FIRST — don't
  start by re-verifying the backend discard logic. Backend soft-delete
  (`Discard::Model`, `.kept` scopes) and jbuilder/GraphQL exposure of
  `discarded_at` are usually correct and shared; the bug is typically a
  client-side filter that exists in N-1 of N parallel components that all
  consume the same data shape. Procedure: (1) confirm the DB-level discard
  actually happened (rake/migration/console log), (2) confirm the field is
  exposed end-to-end (jbuilder → BFF type-defs → frontend type/query — see
  `references/cross-stack-field-tracing.md`), (3) find every sibling
  component/hook that renders the same entity type (e.g. multiple
  `use<X>Form.ts` hooks under a shared `Form/components/` directory, one
  per discipline/variant), (4) diff them for the missing
  `.filter((item) => !item.discardedAt)` guard. `git log -S"discardedAt" --
  <dir>` across the sibling files quickly shows which ones received the fix
  and which didn't. See `references/cross-stack-field-tracing.md` for a
  worked example (clinical-panel PEI objective forms).

- **"Participants" is an overloaded term — don't conflate the free-text list with the clinician/collaborator roster.** Several session-completion flows expose a field literally named `participants` (`General::Sessions::Session#participants`, `Scheduling::SessionCheckout#participants`) that is a small fixed set of free-text categories ("Cuidador(a)", "Outro(a) responsável", "Outro(a) profissional clínico", "Funcionário(a)") — who else was in the room, NOT which therapists ran the session. The actual therapist roster is a separate concept: `collaborators`/`collaborator_ids` (Scheduling::Session) or `clinicians`/`clinician_ids` (General::Sessions::Session, CompleteSession use case). When a user asks "can I add/remove people from the session", clarify which concept they mean and grep for both — `participants` and `clinician_ids`/`collaborator_ids` — before concluding a capability does or doesn't exist.

- **Two divergent "complete this session" paths can exist with different capabilities — always check whether one silently closes the door to the other.** In the operational/scheduling domain, some session types can be completed either through (a) checkin → checkout (`Scheduling::UseCases::CheckoutSession` → `CompleteSession`, which always reuses the session's *existing* `collaborator_ids` unchanged) or (b) a separate manual "Formulário de conclusão" screen that lets the user edit the clinician roster before submitting. The manual-edit screen is only reachable while the session is still open (`isMissingCompleteForm = isOpen && ...` on the frontend) — once checkout completes the session, that menu item disappears and the roster can never be edited again. When investigating "why can't I do X at step N", check every alternate route/screen that also reaches "completed" state and compare their input contracts (GraphQL input types, Dry::Validation contracts) — the capability may exist in one path only, not the shared use case shape you expect.

- **Same user-facing label, different destination — when the user says "I couldn't reproduce that", check for a second render site with the identical label before re-explaining the first one.** Frontend apps frequently have two components that render the exact same button/card text but wire to different routes, because a newer flow was added without updating an older entry point. Grep the WHOLE frontend for every occurrence of the literal label (not just the first hit) and open each render site's `onClick`/`navigate(buildURL...)` — do not assume the first one you found is the only one. Worked example (clinical-panel): "Formulário de conclusão" is rendered by both `SessionArtifacts/CompletedSessionFormCard.tsx` (on the session **details** page — its button navigates to `toCheckoutSession`, i.e. the checkin/checkout flow with no clinician-roster editing) and `Session/SessionCardMenu.tsx` (the **card menu** on the session list — its item navigates to `toCompleteSession` / `/complete`, which DOES expose an editable `clinicians` field). Confirming a capability by tracing only one of these and telling the user "yes this works" is exactly the kind of claim they will come back unable to reproduce — always check whether the label/feature has more than one entry point before answering.

- **A GitHub PR marked `CLOSED` (not merged) can still have its commits live in `development`/`staging`/`production` — never conclude "not deployed" from PR state alone, and always re-`git fetch` before trusting ancestry checks.** GenialCare's workflow sometimes applies a PR's commits to `development` via a path other than clicking "Merge" (cherry-pick, direct push, squash into another branch) and then closes the original PR as redundant. `gh pr view <n> --json mergedAt,state` showing `state: CLOSED, mergedAt: null` only tells you what happened to *that PR object* — it says nothing about whether the same commit SHA exists on `development`. The user caught this mistake directly: an initial "PR #6595 is unrelated, it's closed" answer was wrong because the local `origin/development` ref was stale. To check the real deployment state:
  1. `git fetch origin <branch>` (e.g. `development`) FIRST, in the same investigation — a stale local `origin/development` ref makes `git merge-base --is-ancestor <sha> origin/development` falsely report "NOT an ancestor" even when the commit is actually there.
  2. `git merge-base --is-ancestor <commit-sha> origin/<branch>` after the fresh fetch is the ground truth, not the PR's `state`/`merged` fields.
  3. Cross-check against what's *actually running*: `kubectl --context <env> -n <service> get deployment <name> -o jsonpath='{.spec.template.spec.containers[0].image}'` gives the deployed image tag (often embeds a commit SHA or short SHA suffix like `core:development-3981297`), then `git log --oneline -1 <that-sha-or-suffix>` confirms which commit is live.
  4. To verify a specific code path actually behaves correctly in that live environment (not just "is present"), `kubectl exec` into the real pod and drive the exact method via `bin/rails runner` (wrap DB/tenant-scoped calls in `ActsAsTenant.with_tenant(tenant) do ... end`, using a real `User`/`Tenant` fetched in the same runner call) rather than inferring from log absence or a local Docker container — a local container can be on a stale branch/uncommitted edit unrelated to what's actually deployed.
  5. Absence of log lines for the code path under investigation (via `kubectl logs <pod> --since=<window>`) does not by itself prove the deployed code is broken — it may simply mean the path was never hit in that window (e.g. no client is calling the endpoint at all). Combine "is the commit deployed" + "does invoking it succeed when driven directly" before concluding cause or innocence — don't stop at either check alone.
  6. `kubectl describe pod <pod>` → `Last State` / `Reason` (e.g. `OOMKilled`, `Exit Code: 137`) tells you the REAL reason for a restart — don't assume a restarted/unhealthy-looking pod crashed from the bug you're chasing without checking this first.

- **The checked-out branch may be stale relative to `development` — don't read a file on the wrong branch and report it as current behavior.** The local `core` repo can be sitting on an unrelated feature branch (e.g. `feat/hbj-...`) whose `client.rb` predates a fix that is already merged to `development`. Reading `app/infra/customer_io/client.rb` in that checkout shows the OLD code (`id: user.id`) while the deployed code on `development` uses email identifiers. To reconstruct what a teammate actually shipped and read the real code:\n  1. `git log --all --oneline --author="<name>" -- <path>` to find their commit sequence for that file/area (this surfaces an *iterative* fix — e.g. three commits where the first two were a broken intermediate approach and the third was the real fix).\n  2. `git branch -a --contains <sha>` to see which branches (and whether `development`) actually have each commit.\n  3. `git show <branch>:<path>` to read the file AS IT EXISTS on `development`, not on the stale checkout — this is the ground truth for \"what's live\".\n  This is the git-archaeology sibling of the CLOSED-PR pitfall above: one addresses \"is the commit deployed\", the other \"is the file I'm reading the deployed version\". A divergent identifier / half-migrated integration (email vs id, Track v1 vs v2) is exactly the kind of bug where the stale checkout hides a fix that already landed — and where an intermediate broken commit may have already left bad data behind (see `references/customer-io-identifier-and-device-flow.md`).

- **Which environment a commit is deployed to: development auto-deploys from the
  `development` branch, staging + production deploy from `main`.** The core repo's
  GitHub Actions encode this: `.github/workflows/deploy-development.yaml` (on
  push to `development` → development env) and `.github/workflows/deploy.yaml`
  (on push to `main` → staging, then production). So "is this on staging?" =
  "is this commit reachable from `origin/main`?" — NOT from `origin/development`.
  A fix merged only to `development` reaches the development env but NOT staging
  until it's promoted to `main`. Combined with rebase-merge rewriting SHAs
  (trace content via `git log -S "<string>"`, not SHA ancestry — see the
  `git-lost-commit-forensics` skill), this is the fast way to answer "was the
  fix live when they tested?" without kubectl access.

- **"What changed recently in file X?" / "Which PRs merged on date Y?" — a two-part git/gh archaeology recipe that answers both in minutes.** This is the fastest way to answer "did anything touch the UsersController?" or "what landed in core on Aug 26?" without cloning context:\n  1. **PRs merged on a date** — `gh pr list --repo GenialCare/core --state merged --limit 200 --search \"merged:YYYY-MM-DD\" --json number,title,author,mergedAt,baseRefName`. The `merged:` search filter works (it's not just a local filter), and `mergedAt` comes back in **UTC** — subtract 3h for BRT if the user wants wall-clock order. To find which of those PRs touched a given file/controller, loop the numbers: `for n in <nums...>; do gh pr view $n --repo GenialCare/core --json files --jq '.files[].path' | grep -iE '<pattern>'; done`, then `gh pr diff <n> | grep -A 60 '<path>'` for the actual hunk. Note: a request spec under `spec/requests/<thing>_spec.rb` can change without the controller itself changing — the controller may be `app/controllers/users_controller.rb` (top-level `app/`, NOT a pack) while its spec lives in root `spec/requests/`.\n  2. **File history with dates/authors** — `git log --pretty=format:'%h|%ad|%an|%s' --date=format:'%Y-%m-%d %H:%M' -15 -- <path>` gives a compact one-line-per-commit history (hash, date, author, subject) that instantly shows the last N changes and their spacing. Follow with `git show <sha> -- <path>` to read a specific commit's diff to that file only (add `config/routes.rb` as a second path when the change touched routing too). `git show <sha> --stat` first lists every file in the commit so you know whether the controller edit came bundled with a use case, route, and specs. This is the same git-archaeology family as the CLOSED-PR and stale-checkout pitfalls above, but scoped to \"what changed\" rather than \"is it deployed\".

- **Health-plan/operator identification in the clinical pack is by NAME STRING, not `integration_alias` — and grandfathering cutoffs compare frozen Date constants against BUSINESS dates, never `created_at`.** `General::InsuranceHealthPlan` (clinical pack) carries only `name`, `cnpj`, `finance_insurance_health_plan_id`; the finance plan's `integration_alias` is NOT synced across, because `packs/clinical` cannot reference `Finance::InsuranceHealthPlan` (pack direction is operational → clinical). Identification predicates are hardcoded name matches (`bradesco_group?` → `name.in?([...])`, `porto_seguro?` → `name == \"Porto Seguro Seguro Saúde\"`), consumed by `CalculateWorkload#workload_class`; `amil?` exists ONLY on the finance side (20+ call sites). For cutoff/grandfathering decisions, the two core precedents (`TAX_RESPONSIBILITY_BENEFICIARY_CUTOFF_DATE` in `fiscal_invoice.rb`, `REPLACEMENT_INCENTIVE_START_DATE` in `replacement_session_incentive_factory.rb`) use a frozen `Date.new(...).freeze` constant + `>=` against a business date (`issued_at`, `started_at`) — never `created_at`. Full map in `references/feature-flags-cutoffs-and-health-plan-identification.md`: FeatureFlag key-resolution precedents, the Split.io dashboard workflow, the contract → default workload chain (`in_effect_since = contract.start_date`, `default_value: true`), why `MIN(workloads.created_at)` is NOT a reliable \"contract default\" proxy (8 other `CreateWorkload` call sites; cases without \"Aplicar prescrição padrão?\" get their first workload only at the first Vineland), and the `clinical_case_workloads` index gaps (no index on `created_at`/`in_effect_since`).

## Cross-references

- **`genialcare-datadog-investigation`** — Full RUM→APM→BigQuery triangulation methodology
  for production incident reports. Load this FIRST when the user reports a live production
  bug ("terapeuta relatou erro X") rather than asking to investigate code territory — it
  covers the outside-in flow (BQ identifiers → RUM error → APM trace → blast radius) that
  this skill's CDC/rollback pitfalls (#11, #12, and the `TrailblazerTransactionWrap` pitfall
  above) support.
- **`investigate-bff-flow`** — The BFF (Node.js GraphQL) layer that proxies
  to this core backend. If the user is investigating a full-stack flow, load
  both skills.
- **`trace-event-flows`** — For tracing event-driven cascades across packs
  via Pub/Sub. Also documents the distinction between PubSub events and
  Datastream CDC (supervision data warehouse). Load when the user asks
  about automated/side-effect behavior or CDC/data warehouse flows.
- **`solid-queue-failures`** / **`solid-queue-inspect`** — For debugging
  background job failures in the core.
- **`create-user-story` skill → `references/cross-repo-analysis.md`** — Worked
  example of a full-stack investigation (frontend → BFF → core) for the HBJ
  Painel Clínico feature, including the event trigger chain and the pitfall of
  assuming replacement when the user wanted addition.

## References

- `references/core-checkin-checkout-evolution.md` — Detailed findings from the
  checkin/checkout + evolution check investigation in the Rails core (models,
  use cases, controllers, DB schema, error flow, idempotency patterns).
- `references/agreement-sti-copm-migration.md` — Clinical::Agreement STI
  hierarchy (Embedded, NativeForm, Content, Manual), COPM phase 1→2 migration
  pattern, CreateCopm use case flow, and how to migrate legacy Embedded COPM
  agreements to NativeForm.
- `references/evolution-check-types-and-disciplines.md` — The three
  evolution-check types (trial_counter, checklist, without_configuration),
  their validation rules, discipline-to-type mapping, frontend rendering
  decision tree, BQ attribute fill-rate analysis, and useful queries.
- `references/evolution-check-ui-components.md` — Frontend UI layer for
  evolution checks in clinical-panel: component decision tree, i18n labels
  (pt-br), tag colors by discipline, screen layout top-to-bottom per type,
  scale calculation formulas, auto-save, and checkout flow.
- `references/clinical-case-workload-investigation.md` — Full investigation
  of `ClinicalCaseWorkload`: model fields, use cases (create/discard),
  events, BFF resolvers, JSON output, audit field patterns, and the
  ambiguity of "last modified by" on an immutable (create/discard only)
  resource.
- `references/workload-limits-by-health-plan-and-delay-level.md` — How the
  workload hour dropdown is dynamically populated from backend limits:
  `Services::WorkloadLimits` branches on health plan (Porto Seguro vs
  default) and `delay_level` (SEVERE→NO_DELAY). Why a user can see 4h ABA
  at creation but only 1-3h when editing later (delay_level changed, or
  different user role). Full stack trace from frontend dropdown → BFF →
  core service → Porto workload limits table.
- `references/workload-calculation-and-limits.md` — Full architecture of HOW
  `recommended_hours` is *calculated* (not just validated): the
  `vineland_report_created` → `CalculateWorkload` trigger, `VinelandDelayLevelCalculation`
  (delay_level score mapping + `first_assessment?`), the plan dispatch (`workload_class`
  → Porto/Bradesco/Default services with their `define_workload` + `limits` tables), the
  first-assessment-vs-reassessment split (auto-create vs `SuggestedWorkload` pending approval),
  the "reassessment only reduces" min-rule, the Bradesco weekday-availability hardlock, the
  three-layer limits, the `clinical_case_reference` bypass (per-user per-case; owner does NOT
  bypass), and the "OG" = owner+reference role-group terminology.
- `references/allocation-limiting-operational.md` — "Limiting" is OVERLOADED:
  the operational `People::AllocationLimiting` (per-child ceiling, daily 1AM job,
  `weekly_workload` vs `max_workload_per_day*5` vs child availability slots,
  consumed in admin) is a DIFFERENT mechanism from the `WorkloadLimits` dropdown.
  Disambiguate before answering any "limiting" question.
- `references/enum-migration-checklist.md` — Which files to change when
  adding a new enum value (domain, subdomain, etc.): 3 files across core +
  clinical-panel. Also covers the CSV→i18n→BQ→enum discovery pattern for
  mapping Portuguese values to English enum constants.
- `references/pei-objective-program-model.md` — PEI Objective↔Program data model:
  the legacy `objective.program` (singular, ABA-only `has_one`) vs `objective.programs`
  (plural, join table, current); the 3-era evolution (1→N→1 program); BFF singular-field
  stays ABA-only; prod counts (99% single-program, 0.95% legacy multi-program residue).
- `references/speech-therapy-assessments-and-objectives.md` — Domain map of
  the Fono (speech therapy) assessment → PEI objective data model: Library
  Objective vs PEI Objective models, the DUAL link (library_objective_id AND
  protocol_item_id, both optional), the clinical_case → pei → objectives join
  path, tenant/PEI/clinical_case scoping (clinical_case has_one pei), the
  fact that the 5 Fono sub-assessments have NO link to objectives/protocol_items
  (only Vineland does), and the assessment enum locations.
- `references/clinical-case-discipline-alta-graduation.md` — "Alta"/"graduation" of a
  discipline = `ClinicalCaseDiscipline.status == "completed"`; the completion side effects
  (zero workload + reprove pending suggested + `DisciplineCompleted` event) vs the safe
  `status: "active"` reactivation path (NO side effects); `ClinicalCase.number` is the human
  case number (unique per tenant); fono = `speech_therapy`; the "horas zeradas" root cause
  and how to verify/remove an alta in production.
- `references/documents-config-visibility.md` — How `ClinicalCaseFileTypeConfig`,
  `by_config_scopes`, `DocumentTypeConfigResolver`, and the backfill rake
  interact. Why documents go invisible when tenants lack generic configs,
  and the gap in new-tenant provisioning.
- `references/clinical-case-file-deleted-before-job.md` — The
  `ExtractSensoryProcessingMeasureReportInfoJob` NOT_FOUND case: event wiring
  (`clinical_case_file_created` → `ExecuteUseCaseJob`), the "file created then deleted
  before the delayed job ran" benign-error pattern, and the CDC
  (`raw.clinical_case_documents_events`) create→delete timeline proof.
- `references/signing-envelope-cancel-gap.md` — Digital signature envelope
  domain (TCLE/informed-consent-form): event→job→envelope chain, per-clinician
  idempotency, the absence of any cancel/void capability (no `cancelled`
  status, no `void` in Zoho/Autentique clients, no envelope-cancelling consumer
  on `clinician_removed_from_clinical_case`), and the two-part manual
  remediation (delete `ClinicalCaseFile` + void in the provider dashboard).
- `references/direct-assessment-registry-null-investigation.md` — Full trail of the
  "direct_assessment session has NULL registry" bug: reproduction recipes (Docker
  `rails runner` + `--entrypoint bundle`), the forced-fail test that proved
  `Wrap(TrailblazerTransactionWrap)` rolls back EVERYTHING, the conclusion that the
  registry is created-then-deleted (via `Delete<X>TherapyAssessmentsRegistry` +
  `dependent: :nullify`), and the three refuted hypotheses (race, `updated_by` nil,
  partial commit) so they are not re-investigated.
- `references/registry-status-revert-investigation.md` — DISTINCT bug from the
  NULL-registry one: a Fono/TO registry stuck `status='started'` with ALL
  sub-assessments `completed` (therapists: "preenchi tudo mas não completou"). Root
  cause = `DirectAssessmentRegistry#recalculate_status!` `else → mark_as_started!`
  downgrades completed→started; Fono registry NEVER got the `with_lock` (only TO did,
  commit `c56a7e8497`), `reopen`/`mark_as_started!` is unlocked, and the recalc runs in
  a SEPARATE transaction from the sub-assessment save. CDC proves a `completed → started`
  revert (TO reverted even AFTER the June lock), plus a two-different-`updated_by_id`-in-
  the-same-second concurrency confirmation. Includes BQ/CDC table names, the "registry
  `updated_by` = creator only" attribution gotcha, and fix recommendations.
- `references/customer-io-identifier-and-device-flow.md` — Customer.io
  identifier strategy (email vs id), the Track v1 "ghost profile" gotcha
  (email in `id` field is NOT auto-detected — only the JS SDK does that), the
  Track v2 fix (`identifiers: {email}`), and the mobile→bff→core
  device-registration flow. Load when investigating push notifications, device
  registration, or "identifies but device doesn't associate".
- `references/feature-flags-cutoffs-and-health-plan-identification.md` — FeatureFlag
  key-resolution precedents (per-case/per-report/per-tenant) and the Split.io
  dashboard workflow; the two grandfathering cutoff precedents (frozen
  `Date.new(...).freeze` + `>=` vs business dates); the contract → clinical case
  → default workload chain (`in_effect_since = contract.start_date`,
  `default_value: true`, "Aplicar prescrição padrão?" checkbox) and why
  `MIN(workloads.created_at)` is not a reliable "contract default" proxy;
  `clinical_case_workloads` index gaps; name-based operator identification on
  the clinical side (Amil/Bradesco/Porto, `integration_alias` not propagated,
  pack-graph root cause) with the seeds inventory and spec-territory count for
  workload rules.
- `references/contract-inventory-sync-churn-and-health-plan-data.md` — Full
  contract column inventory; the `category_type` enum (Amil sub-plans incl.
  `amil_one_amil`) as a robust discriminator vs fragile name matching;
  `SetInsuranceHealthPlan` update-in-place semantics (find_or_create_by, delete
  on `private_contracting`, no unique index); the fact that churn NEVER touches
  clinical data (3 operational-only consumers, no churn signal in the clinical
  pack); backflow/plan-change = NEW contract (start_date unique, no reopen);
  `ClinicalCaseWorkload` has no `contract_id` and no discard on churn. Load for
  any grandfathering / plan-identification / "anchor workload to current
  contract" work.
