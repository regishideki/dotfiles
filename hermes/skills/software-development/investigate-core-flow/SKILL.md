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
    local execution is secondary.

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
  will miss 90%+ of the models.

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

- **`DictionaryRecord::Configuration#metadata_for` always returns a Hash (never nil).** The method has a `|| {}` guard in `dto.rb:25`. Calling `.dig(...)` on its return value can never raise `NoMethodError` — if you see `Hash#dig` in a stack trace involving this chain, the error is NOT in the `dig` call itself. It's either a downstream issue (the `nil` result breaks a later validation) or the `metadata` JSONB blob has an unexpected shape (e.g. `specialization_to_map` is a string instead of a hash, which would show as `String#dig`, not `Hash#dig`). Start by checking what `params[:discipline]` actually resolves to and what the DB record's `metadata` column contains.

- **Compare sibling use cases when debugging.** When `create_collaborator.rb` and `update_collaborator.rb` implement similar logic, differences are diagnostic signals. Example: `create_collaborator.rb:47` uses `.dig("specialization_to_map", "name")` directly, while `update_collaborator.rb:230` uses `&.dig("specialization_to_map", "name")` with safe navigation. The `&.` was likely added as a defensive fix after a production issue — the missing `&.` in the create path may be the bug.

- **Prefer use cases over raw updates for data mutation.** When a snippet
  mutates records, always check if a Trailblazer use case exists for the
  action (e.g. `Agreements::UseCases::MakeComplete` for completing agreements).
  Use cases encapsulate validations, event emission (`AgreementCompleted`,
  etc.), and business rules that `update_column` bypasses. Only use
  `update_column` when you deliberately need to skip callbacks/validations
  (e.g. STI type migration where the target subtype validates a column the
  source didn't have). The user explicitly asked to "sempre usar UseCase
  quando possível pois lá pode conter validações, envio de eventos e tal".

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

## Cross-references

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
- `references/enum-migration-checklist.md` — Which files to change when
  adding a new enum value (domain, subdomain, etc.): 3 files across core +
  clinical-panel. Also covers the CSV→i18n→BQ→enum discovery pattern for
  mapping Portuguese values to English enum constants.
