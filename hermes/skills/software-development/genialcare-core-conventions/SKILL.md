---
name: genialcare-core-conventions
description: Use when coding in the GenialCare core repo (Rails).
---

# GenialCare Core Repo — Code Conventions

The core repo ships its own class-level skill set (`.claude/skills/`) that IS the source of truth for
how to write code there. **Read these before writing anything** — violating them triggers user correction:

- `test-rails` — RSpec conventions (no `let`, AAA, coverage table).
- `model` — ActiveRecord model patterns (attributes, facade, multi-tenant, JSONB serializers).
- `migration` — schema evolution (tenant indexes, naming, rollback).
- `use_case` — Trailblazer use cases (Model.Find, transaction wrap, error propagation).
- `rake` — rake task conventions (ENV vars, TENANT_NAMES, progress).
- `endpoint` — controller/route/policy/spec patterns.
- `query-object` — Query Objects for listings (Ransack, filters/sort, OpenAPI).
- `enum`, `skill-comment`, `backfill`, `external-endpoint`, `ar-performance`.

The rest of this skill records the highest-value pitfalls that are easy to miss even after a skim.

## Specs (`test-rails`)

- **No `let`, `before`, `after`.** Explicit setup inside each `it` (AAA: Arrange/Act/Assert, blank
  lines between). Exception: `let_it_be_with_tenant` for heavy immutable fixtures.
- Every spec starts with `# frozen_string_literal: true`.
- Use `type: :use_case` / `type: :request` / `type: :model` explicitly.
- **Use `create(:user)` or a local `user` var — NOT `$current_user`.** The skill's example text shows
  `$current_user`, but actual repo specs use `create(:user)`; `$current_user` trips standardrb's
  `Style/GlobalVars`. (The tenant IS auto-set globally — never `create(:tenant)` and never wrap in
  `ActsAsTenant.with_tenant` inside a spec.)
- Explicit data in assertions — never rely on factory defaults to satisfy an `expect`.
- **`factory :operational_people_child` auto-creates a contract when `insurance_health_plan` is present.** Its `after :build` hook (`spec/factories/operational/people/child.rb`) builds a `People::Contract` with the `sequence(:start_date) { 10.years.ago + n.days }` whenever `child.contracts.blank? && child.insurance_health_plan.present?`. That phantom contract then wins/loses `child.current_contract` (`contracts.max_by(&:start_date)`) in ways that surprise you. When a spec needs a specific `current_contract`, either (a) create the child WITHOUT `insurance_health_plan` and add the contract explicitly, or (b) stub it the way `create_or_update_family_spec.rb` already does: `contract = build(:operational_people_contract, ..., start_date: ...); allow(child).to receive(:current_contract).and_return(contract)`.
- Model specs: cover validations, scopes, intra/cross-tenant uniqueness, enums, domain methods.
- Request specs: 401 → 403 → 200 (errors first), `mock_valid_auth_headers(user)`, `.json` in path.
- **When adding request specs for new behavior, never overwrite an existing request-spec file.** First check `git show origin/main:<path>` — if the endpoint already has a spec (GET / DELETE / POST cases), restore that content and APPEND your new cases inside the relevant `context`, don't replace the whole file. Overwriting silently deletes existing coverage (a reviewer bot flags it HIGH: "existing request specs deleted"), and you lose the regression tests for the 403/404/201 paths you didn't touch.
- To verify a DB-level unique index (bypassing the Rails validation), use
  `expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)` — but ONLY with
  a non-null value in every scope column. A nullable scope column (e.g. `feature_name`) makes the PG 14
  unique index skip NULL rows, so the save won't raise. (See the `nulls_not_distinct` note under Migration.)

- **Test doubles:** prefer `instance_double`/`instance_spy` over anonymous `double` — they verify the
  stubbed method exists on the real class, so a rename/removal of `identify`/`track_event` fails loudly.
  For `BaseEvent`-derived event classes, use the REAL event class (e.g.
  `MessageCreatedNotificationEvent.build_from(params)` is literally `build(data_params)`) instead of an
  anonymous `Class.new { include BaseEvent; ... }` fake — it's equally cheap and verifies the real
  `attributes`/`name`/`tenant_id` contract instead of drifting from it.
- **VCR cassettes match on method+URI, not body.** `spec/rails_helper.rb` sets `hook_into :webmock`
  with no `match_requests_on` override, so the default `[:method, :uri]` applies. A PR that changes an
  outbound request body (e.g. Customer.io `identify` dropping `is_caregiver`/`is_clinician` for `roles`)
  does NOT break existing cassettes — they silently go stale (recorded body keeps the old payload).
  Don't flag a body change as a CI breaker; note it only as a stale fixture to re-record.

## Model (`model`)

- **Declare every non-association column explicitly with `attribute :name, :type`** — even when Rails could infer it.
- **FK columns are declared by `belongs_to`, NOT a separate `attribute`** — `belongs_to :obj, foreign_key: "obj_id"` already infers the FK column and its UUID type. An explicit `attribute :obj_id, :string` is redundant *and* wrong-type (the FK is `:uuid`, not `:string`); a reviewer bot will correctly flag it for removal. Only plain (non-association) columns get an `attribute` line.
- `belongs_to :tenant` is already provided by `ApplicationRecordTenant` → `acts_as_tenant :tenant`;
  do NOT add `association :tenant` to the factory (tenant is auto-set from `ActsAsTenant.current_tenant`).
- **`:interval` columns are `ActiveSupport::Duration` — read hours with `(duration / 1.hour).to_i`, NOT `duration.to_i / 3600`.** `attribute :hours, :interval` (e.g. `ClinicalCaseWorkload#hours`) maps to a Duration on read; `Duration#to_i` returns **seconds**, so `hours.to_i / 3600` is an opaque way to get integer hours (magic 3600). The codebase's own clean idiom — already in `calculate_workload.rb`'s `apply_minimum_workload_rule` — is `(current_workload.hours / 1.hour).to_i` ("how many 1-hour units fit in this duration?"). For a derived column the model pattern is `before_save { self.minutes = hours.in_minutes }`. Prefer `(hours / 1.hour).to_i` (or a model helper like `hours_quantity`) everywhere the integer-hours value is needed; don't introduce `to_i / 3600`.
- Add presence validations for required columns; scope uniqueness by `:tenant_id`.
- Tenant-scoped tables inherit `ApplicationRecordTenant`; globals (`User`, `Tenant`, `Role`) use `ApplicationRecord`.

## Migration (`migration`)

- Tenant column MUST be `t.references :tenant, null: false, type: :uuid, foreign_key: {to_table: :tenants}, index: false`
  (note: `to_table: :tenants` explicit + `index: false`).
- Every tenant-scoped table needs BOTH `[:tenant_id, :id]` and `[:tenant_id, :fk_col]` composite
  indexes — enforced by `spec/lib/tenant_index_coverage_reporter_spec.rb` (run it after any migration
  that creates a table / FK / index). Composite unique index starts with `tenant_id`.
- Recent migrations use `ActiveRecord::Migration[8.1]` (match `db/schema.rb`'s `ActiveRecord::Schema[8.1]` header and the newest `db/migrate/*` files — this was 8.0 once but has moved; always confirm against the latest migration in the repo rather than trusting this note).
- **PostgreSQL is 14** (14.24) — so `nulls_not_distinct: true` (a PG 15+ option) is NOT available. A
  unique index that includes a nullable column (e.g. `feature_name`) does NOT prevent duplicate rows
  where that column is NULL (`NULL <> NULL` in standard SQL). If a reviewer bot suggests
  `nulls_not_distinct`, decline it for this repo. Mitigate instead with a model-level uniqueness
  validation (Rails emits `IS NULL` for nil scope values, so it DOES catch NULL duplicates at the app
  layer) plus an idempotent full-rebuild seed; only reach for a partial index if DB-level enforcement
  of NULL rows is truly required.
- **Never edit an already-applied migration.** If you must (uncommitted only): `DROP TABLE ... CASCADE;
  DELETE FROM schema_migrations WHERE version = '...'`, then re-`db:migrate`. Otherwise create a new migration.

## Enum (`enum`)

- **Two `SessionTypes` enums coexist and have DIVERGED.** `Enum::Scheduling::SessionTypes`
  (packs/operational — used by `Scheduling::Session`) vs `General::Sessions::Enums::SessionTypes`
  (packs/clinical — used by `General::Sessions::Session`). Both define a `groups` hash, but only the
  clinical one has an extra `assessment` group whose members **overlap** `intervention`:
  ```
  # operational:   intervention: [intervention, baseline, direct_assessment, indirect_assessment,
  #                               feedback_assessment, reassessment]   (1:1 type→group)
  # clinical:      intervention: [...same...]  AND
  #                assessment:   [indirect_assessment, direct_assessment, feedback_assessment]
  ```
  Before writing logic that indexes into `.groups`, confirm WHICH enum the model actually uses (the
  `enum :session_type, ...` line in the model), and know the group membership is NOT identical across
  packs. Code that does `groups.values.find { |types| types.include?(type) }` returns the FIRST matching
  group, so overlapping membership is silently order-dependent in the clinical enum.
- **`Enum::Base#to_h` maps `value => value` (string → string)** — `app/models/enum/base.rb:42` is
  `all.map { |a| [a, a] }.to_h`. So a Rails `enum :foo, SomeEnum.to_h` getter always returns a **String**
  (e.g. `"intervention"`), and the group arrays are already string constants. `.to_s` / `.map(&:to_s)`
  on enum values is redundant — `types.include?(session_type)` and `[session_type]` are correct as-is.



- Call signature: `UseCase.call(params: {...}, current_user: user)` — **kwargs, NOT a positional hash**.
- Use `CustomMacros::Model.Find(retrieve_id:, model_class:, model_key:)` — **never `Model.find`/`find_by`
  inline**. On not-found it sets `ctx[:errors] = {code: "NOT_FOUND", message: "<model_key> not found"}`
  and emits `End(:not_found)`; the `Wrap` boundary needs `Output(:not_found) => End(:not_found)`.
- `# standard:disable Lint/UnreachableCode` … `# standard:enable` around the file **only when a `fail`
  step exists** (not `# rubocop:disable`; and `fail_fast: true` on a macro is not a `fail` step).
- Contract step: `step ::CustomMacros::Contract::Build(contract_class: Contract), fail_fast: true`.
- Use case is orchestrator only — domain rules live on the model (ADR 0012).
- **Trailblazer step/fail IDs must be unique within one activity.** Reusing a method as a second
  `step`/`fail` (e.g. two `fail :handle_limit_error, fail_fast: true` for two validation steps)
  raises at boot/eager-load: `RuntimeError: ID handle_limit_error is already taken. Please specify
  an :id.` Give the second one a distinct `id:` — the method name stays the same, only the sequence
  id differs: `fail :handle_limit_error, fail_fast: true, id: :handle_total_limit_error`.
- **Detect use-case failure in a controller via `ctx.success?`, NEVER `ctx[:workload].valid?`.**
  `handle_*_error` steps flag failure with `model.errors.add(:base, message)`, but
  `ActiveRecord#valid?` **clears** `errors` and re-runs only model-level validations before returning
  a boolean — so a record that failed a use-case (non-model) validation reads `valid? == true`, and
  the controller renders 201 instead of 422. Render the error with the standard shape via
  `format_errors(ctx)` (ApplicationController helper → `HttpErrorFormat`), which yields
  `{details:[{name:"custom_error", errors:[{code, message}]}]}`; the panel's
  `build-error-message` reads `body.details[0].errors[0].message`. When a controller action calls a
  use case, branch on the result (`ctx.success?` / `ctx[:errors]`), not on the model's `valid?`.
- **Fixed-date cutoffs in specs need `travel_to`.** When a use case compares a record `created_at`
  (factory default `Time.now`) against a frozen constant cutoff (e.g.
  `NEW_AMIL_WORKLOAD_RULE_CUTOFF = Date.new(2026,10,6)`), a setup record created "now" may land before
  the cutoff depending on when the test runs. Wrap the `it` body in
  `travel_to(Time.zone.local(<year>, <month>, <day>)) do ... end` (ActiveSupport TimeHelpers, already
  included via `spec/rails_helper.rb`) so `created_at` deterministically exceeds the cutoff.

### AR query optimization in use cases (avoid association loading)

Reviewer bots (gemini-code-assist) will flag these; apply them, they're real wins:

- When a use case only needs the FK id (not the associated record), don't `.includes(:assoc)` +
  `.map(&:assoc)` — the `.includes` eagerly loads full AR objects you never use. Switch to
  `.map(&:assoc_id)` directly and DROP the `.includes` (dropping it alone, keeping `.map(&:assoc)`,
  reintroduces N+1). `.compact`/`.uniq` on the FK ids is equivalent to doing it on the loaded objects.
- `.pluck(:a, :b).to_h` keeps the **LAST** `:b` per duplicate `:a` (Ruby `Hash#[]=` semantics). The
  idiomatic `each_with_object({}) { |r, m| m[r.a] ||= r.b }` keeps the **FIRST**. When you convert the
  latter to `.pluck`, preserve the original "first wins" behavior with `.pluck(:a, :b).reverse.to_h` —
  otherwise a child with two PEI objectives for the same `library_objective_id` silently flips to the
  newest instead of the oldest. Add a one-line comment explaining the `.reverse`.
- To fetch only some columns, prefer `.pluck` over loading records and `.map`-ping in Ruby (fewer AR
  object instantiations, less memory).

## Rake (`rake`)

- `TENANT_NAMES` is **required with no default** (`ENV.fetch("TENANT_NAMES") do ... exit 1 end`).
- Args via ENV vars (never inline rake args); `ActsAsTenant.with_tenant(tenant)` per tenant; STARTED/FINISHED banners.
- **Rake task specs (`spec/tasks/`) are the EXCEPTION to "never `create(:tenant)` / never wrap in `ActsAsTenant.with_tenant`".** A multi-tenant rake (one that iterates `Tenant.find_each` + `ActsAsTenant.with_tenant` internally) needs its spec to seed data in a second tenant and assert it got processed. Pattern (see `spec/tasks/backfill_current_contract_start_date_spec.rb`):
  ```ruby
  require "rails_helper"
  require "rake"
  Rails.application.load_tasks unless Rake::Task.task_defined?("backfill:...:task")
  task = Rake::Task["backfill:...:task"]
  # ... seed under the auto-set default tenant ...
  other_tenant = create(:tenant)
  ActsAsTenant.with_tenant(other_tenant) do
    # ... seed other-tenant records ...
  end
  task.reenable
  task.invoke
  ```
  **Gotcha:** `record.reload` on a tenant-scoped model is itself tenant-scoped (acts_as_tenant default_scope), so reloading a record that lives in `other_tenant` while the ambient tenant is the default one raises `RecordNotFound`. Wrap that assertion in `ActsAsTenant.with_tenant(other_tenant) { expect(other_plan.reload...) }`. `task.reenable` is required before re-`invoke` (Rake disables a task after one run) — important for the idempotency test.

## Tenant / acts_as_tenant in `rails runner` scripts

Specs auto-set the tenant globally, but a `bin/rails runner` script does **not** — calling
`SomeTenantScopedModel.find(...)` before setting the tenant raises
`ActsAsTenant::Errors::NoTenantSet`. Set it first, then query:
```ruby
ActsAsTenant.current_tenant = Tenant.find("<tenant-uuid>")
```

- **Tenant lookup field trap:** `TENANT_NAMES=genialcare` (rake) and `Tenant.where(name: ...)` resolve
  by the `name` column, but `Tenant.find_by(external_id: "genialcare")` returns **nil** — `external_id`
  is a separate column (e.g. `org_tiWWPpuGf2Mrve6E`), not the friendly name. In scripts prefer
  `Tenant.find("<uuid>")` or `Tenant.find_by(name: "genialcare")`; grab the UUID off a record you
  already have (e.g. `registry.tenant_id`) instead of guessing it from the tenant's display name.

## Prod read-only queries (kubectl + rails runner)

Read-only counts/lookups against production from the core repo:

```bash
gcloud auth activate-service-account --key-file=$HOME/.config/gcloud/regis-automation-sa-key.json
rm -f ~/.kube/gke_gcloud_auth_plugin_cache
kubectl --context production get pods -n core -o custom-columns=":metadata.name" | grep web
kubectl --context production exec -n core <WEB_POD> -i -- bin/rails runner - 2>/dev/null <<'RUBY'
puts "total=#{User.count}"
RUBY
```

Pitfalls:
- **`bin/rails runner` boots slowly in prod** (~30s, floods stderr with enum `not_*` warnings and Datadog/SplitIO init). Give the terminal call `timeout=180` (or more), NOT the 60s default — 60s times out before the query runs. `2>/dev/null` keeps the boot noise out of the captured output.
- **`~` does NOT expand after `=`** in `--key-file=~/.config/...` — bash only expands `~` at the start of a word. Use `$HOME/...` or the absolute path, otherwise gcloud fails with `Unable to read file [~/.config/...]`.
- If kubectl fails with `Reauthentication failed / cannot prompt during non-interactive execution`, the gcloud creds expired — re-activate the SA key (line above). Don't run `gcloud auth login` (needs an interactive browser).

## Endpoint (`endpoint`)

- Custom routes need `as: :route_name` (no helper is generated otherwise).
- Prefer `resources`; nest only when the child doesn't make sense outside the parent.
- Controller delegates to a use case; authorize via `authorize record, :action?, policy_class:`.

## Feature flags (Split.io)

- `FeatureFlag.on?(key:, split_name:, attributes: {}, model: nil)` — **`key:` is a mandatory kwarg** (no default). It is Split.io's *traffic key*: it names the entity being evaluated and only matters for **targeting** (per-tenant / per-entity rollout, percentage rollout). For a **global** on/off kill-switch flag the key value does NOT change the outcome (every entity gets the same treatment), but it still cannot be empty/nil (the SDK needs a non-nil string; nil errors or yields the "control" treatment).
- Convention for global flags (e.g. `CLINICAL_COPM_AGREEMENT_ENABLED`): pass a stable id — `key: clinical_case.tenant_id`. Do NOT use `ActsAsTenant.current_tenant&.external_id || clinical_case.tenant_id`: the `clinical_case` always has `tenant_id`, and `external_id` is a different column than `name` (see the "Tenant lookup field trap" note). A fixed string key also works but is inconsistent with the codebase. Per-entity flags instead pass `key: clinical_case.id` / `key: <report>.id` etc.

## Local test overrides that must NOT be committed

When testing a feature locally you may need temporary **uncommitted** overrides that must never land in the PR, and get reverted before finishing:
- `config/split.yaml` — flag flipped to `treatment: 'on'` (the committed default is `'off'`).
- `config/initializers/split_client.rb` — a local flag-client override (e.g. an `AMIL_LOCAL_FLAG` env guard that forces `localhost` mode instead of the remote Split.io, so you don't depend on the dashboard).
- A **TEMP cutoff-date** change (e.g. `NEW_AMIL_WORKLOAD_RULE_CUTOFF = Date.new(2026,10,1)` instead of the committed future date, with a `# TEMP (teste local)` comment) — needed when "today" is before the committed future cutoff, so the first saved workload would otherwise fall back to the legacy rule.

If a **real** change lands in the SAME file as one of these temp overrides (e.g. simplifying the flag `key:` in `new_amil_regime.rb`, which also carries the temp cutoff), stage selectively — commit only the real hunk and leave the override working-tree-local:

```bash
printf 'n\ny\n' | git add -p <file>   # answer 'n' to the temp hunk, 'y' to the real one
git diff --cached                      # confirm only the real change is staged
```

Then verify nothing temp slipped through: `git diff HEAD -- <file>` must show only the override line(s), not the change you committed.

## CI / `.test-impact`

Each branch/PR needs `.test-impact/impact-<branch-slug>.txt` (branch `/`→`-`, non-alphanumerics
stripped). List the impacted `*_spec.rb` paths, or `SKIP_TESTS` for rake-only changes. Missing file →
CI fails.

## Splitting a feature into stacked PRs (per task)

When the user asks to split a feature into N PRs (one per task), use **stacked branches**, each PR
targeting the previous one so diffs stay clean and dependent code still compiles:
- `git reset --soft HEAD~1` to un-bundle, then commit per task group (T1 migration+model, T2 rake,
  T3 endpoint+specs).
- Branch T1 off `main`; T2 off T1; T3 off T2. `gh pr create --base <prev-branch> --head <this>`.
- Each branch gets its own `.test-impact` file (T1 lists model+tenant-coverage specs; T2 `SKIP_TESTS`;
  T3 lists the cumulative specs).
- **Manual deploy gate between two stacked PRs ⇒ do NOT auto-merge the gated downstream PR.** If the
  stack has a required production step between PR N and PR N+1 (e.g. a backfill rake that must run in
  prod after the migration PR merges and before the consumer PR merges), auto-merge only the pre-gate
  PRs; merge the gated PR by hand after the rake completes. Record the gate explicitly in the PR
  descriptions (⚠️ "gate crítico") and in `status.md` so the automation (and reviewers) don't squash
  the downstream PR early.

## Stacked PR branch got force-pushed (rebased) on remote → reconcile with reset + cherry-pick

GenialCare stacked branches (e.g. core `feat/PEC-4229-...`) get **rebased/force-pushed** on the remote
as dependent PRs merge and the base moves. Your local branch then diverges: `git status -sb` shows
`[ahead N, behind M]`, and `git push` is rejected non-fast-forward with a "to the same ref" hint.

Don't `git pull` (it merges the rewritten history) and don't rebase your whole local branch (the
pre-rebase commits duplicate the remote's rebased versions and cause conflicts). Reconcile cleanly:

```bash
git fetch origin <branch>
git reset --hard origin/<branch>          # adopt the remote's rewritten history
git cherry-pick <your-commit-sha>          # replay only YOUR commit(s) on top
# run the affected specs, then:
git push
```

The cherry-pick applies cleanly when your commit only touched files the remote rewrite didn't change.
Your commit SHA is safe through the reset (it stays in the reflog, and you grabbed it from `git log`
beforehand). Verify the remote's rewritten version of the same base commit has matching content first
(`git diff <old-sha> <new-sha> --stat`) — if the rewrite was purely a rebase, it does.

## Keeping a stacked PR updated / resolving rebase conflicts onto main

When you rebase a core branch onto a moved `main`, `db/schema.rb` conflicts on the
`ActiveRecord::Schema[8.1].define(version: ...)` line (both sides added migrations). Resolve by
picking the **MAX version timestamp** — the table definitions auto-merge (independent additions), but
verify the new table + its composite indexes are still present after the merge.

After the rebase, if `Gemfile.lock` moved (e.g. a rails/datadog bump pulled from main), every
`bundle exec` in the docker container fails with `Bundler::GemNotFound (Could not find rails-8.x ...)`.
Fix once: `docker compose exec -e DISABLE_SPRING=1 app bundle install`.

Then regenerate the canonical schema and verify zero drift:

```bash
docker compose exec -e DISABLE_SPRING=1 app bundle exec rails db:migrate     # apply pending migrations
docker compose exec -e DISABLE_SPRING=1 app bundle exec rails db:schema:dump # regenerate
git diff db/schema.rb   # MUST be empty — no drift from the DB's real state
```

Pitfall (cosmetic): a Rails minor upgrade (from the rebased `Gemfile.lock`) makes `db:schema:dump`
reorder columns across the WHOLE schema — a multi-thousand-line diff that is purely cosmetic.

Pitfall (DANGEROUS — drops indexes): `db:schema:dump` regenerates from the **DEV DB**, not from the
migrations. If the dev DB is stale (created before `main` advanced, so it's missing recent main
migrations' indexes), the dump silently DROPS those indexes from `schema.rb`. Symptom: CI fails
`tenant_index_coverage_reporter_spec.rb` with "Tables missing tenant_id + PK index" listing tables you
never touched (they're main's, and main has those indexes). The **auto-merged `schema.rb` from the
rebase already HAS main's indexes** — prefer it over a fresh dump. Do NOT commit a `db:schema:dump`
from a stale dev DB; keep the auto-merged file + your version-line fix. To verify the final schema is
correct, load it into a FRESH test DB and run the tenant-coverage spec (this is exactly what CI does):
`RAILS_ENV=test db:drop db:create db:schema:load` then `rspec spec/lib/tenant_index_coverage_reporter_spec.rb`.
Spot-check that a main table you didn't touch still lists its `tenant_id, id` index vs `git show
origin/main:db/schema.rb` before pushing.

Push with `git push --force-with-lease origin <branch>` (safer than `--force`). After the base PR of a
stack merges, each downstream PR (whose `base` is the previous branch) flips to
`mergeable: CONFLICTING` / `mergeStateStatus: DIRTY` and needs the same rebase onto the new base.
Check state with `gh pr view <n> --json mergeable,mergeStateStatus,reviewDecision`; the required CI
checks (branch protection) show via `gh api repos/<owner>/<repo>/branches/main/protection`.
`BLOCKED` + `MERGEABLE` + `APPROVED` usually means CI is just still running — watch it with
`gh pr checks <n> --watch --interval 90`.

**Merging the base PR of a stack needs the async-merge endpoint.** `gh pr merge` and
`gh pr edit --base main` both refuse a stacked PR ("part of a stack and must be merged using the
asynchronous merge REST API" / "Cannot change the base branch because the pull request is part of a
stack"). Use `PUT /repos/GenialCare/<repo>/pulls/<n>/merge-async -f merge_method=squash` — it returns a
`uuid` (status `pending`, "Merge request enqueued"), then poll
`GET .../pulls/<n>/merge-async/<uuid>` until `merged`/`failed`. If it fails with "N of N required
status checks are expected" and `mergeStateStatus` is `BEHIND`, `main` moved again mid-flight — rebase
onto latest `main`, force-push, then re-enqueue (the old uuid is dead). While `main` is busy this is a
loop: rebase → push → CI green → enqueue → (`main` moved) → repeat.

## PR descriptions

The user wants every PR description to carry the **problem being solved**, not just "what changed" —
for history and for reviewers who lack context. Structure each body:

- **Contexto** — the problem (why), in pt-BR, tied to the product/domain (not just code).
- **O que este PR faz** — the change, scoped to THIS PR/task (not the whole feature).
- **Decisões** — the non-obvious choices + trade-offs.
- **Testes** — what was verified.

For multi-layer features (core → bff → panel), cross-reference the sibling PRs so a reviewer can
follow the chain. UI screenshots can be committed to the branch (`docs/screenshots/`) and referenced
with a relative `![](docs/screenshots/foo.png)` in the body — GitHub renders repo-relative images.

## Jira PR links

The user wants each PR linked on its Jira sub-task: `addCommentToJiraIssue` (Atlassian MCP) with body
`PR: https://github.com/GenialCare/<repo>/pull/<n>`. Do this as each PR opens.
