---
name: rails-rake-tasks
description: Use when writing or running a Rails rake task.
---

# rails-rake-tasks

Rake tasks are the standard vehicle for one-off data migrations and imports in this
multi-tenant Rails monolith (e.g. importing a new clinical catalog, backfilling,
reconciling DB vs CSV). A task is usually delivered together with a shell snippet in
`custom_gitignore/snippets/snippets.sh` that runs it inside a `web` pod via `kubectl`.

The project also has Claude Code skills (`.claude/skills/rake`, `.claude/skills/backfill`)
for authoring conventions; this skill captures the cross-cutting Ruby/Rails gotchas and
the operational kubectl runbook that recur every time.

## Authoring gotchas (all bit in real sessions)

0. **A new persisted enum/type value on an existing model needs a backfill
   rake if historical records should get it too.** When a feature adds a
   new discriminator value (e.g. a new `workload_type` on
   `ClinicalCaseWorkload`) that's populated by an existing event-driven
   calculation use case, the use case only fires for records going forward
   — existing records stay empty until one of the trigger events happens
   to recompute them. `core/lib/tasks/create_shared_schedule_workloads.rake`
   is the canonical precedent: dry-run by default, scoped `WHERE` filter to
   eligible records, calls the use case per record inside one transaction
   with rollback-all-on-any-failure. See
   `investigate-core-flow` skill → `references/clinical-case-workload-investigation.md`
   (§ "Practical HBJ hours") for a worked comparison of what the new rake's
   eligibility filter needs to differ on. Always ask the user explicitly
   whether they want a retroactive backfill or are fine letting the value
   populate naturally as the trigger events fire again — don't assume either.

1. **A rake task body is a BLOCK, not a method.** `return` inside `task ... do ... end`
   raises `LocalJumpError: unexpected return`. To exit early (e.g. after a dry-run), use
   `next`, not `return`.

2. **Constants at namespace/file level are evaluated at LOAD time** — before Rails
   finishes booting and before the autoloader can resolve app constants. This raises
   `NameError: uninitialized constant Enum` (or any app constant). BUT a constant inside
   the `task` block trips `Lint/ConstantDefinitionInBlock`. The correct fix is a lowercase
   local variable with `.freeze` inside the task (evaluated at run time, not load time):
   `domain_map = { "Fala" => Enum::Domains::SPEECH }.freeze`.

3. **`blank?` is ActiveSupport.** Fine inside a rake task (Rails is loaded), but not in a
   bare `ruby -e` test harness — use `nil?`/`empty?` there when validating parsing logic
   outside the app.

4. **Multi-tenant rakes: compute the diff PER TENANT, never aggregated cross-tenant.**
   Each tenant owns a full copy of shared data (protocols, catalogs). Aggregating across
   tenants hides gaps: "the protocol item already exists somewhere" is wrong if tenant B
   lacks it. Loop tenants, run `ActsAsTenant.with_tenant(t) { ... }`, and reconcile inside.

5. **Wrap execution in ONE transaction over all tenants — but do NOT `raise
   ActiveRecord::Rollback` inside the per-record/per-tenant `rescue`.** Doing so aborts the
   method before it returns its accumulated `errors` array, so the caller never sees them:
   the tenant loop stops early and the final summary prints `Errors: 0` with zeros — a
   silent, total rollback with no visible cause. Correct pattern:
   - per-record `rescue` → `errors << msg` AND `puts msg`, do NOT raise;
   - return `[created, updated, discarded, errors]` normally from the worker method;
   - rollback exactly ONCE, at the END of the transaction and OUTSIDE the loop:
     `ActiveRecord::Base.transaction { tenants.find_each { ... collect ... }; raise ActiveRecord::Rollback if total_errors.any? }`.
   This is all-or-nothing AND surfaces every error.

6. **Dry-run first, then execute.** Read a `DRY_RUN` env flag; when true, print what would
   change (create/update/discard + counts) and `next`. Show the actual configuration that
   will be saved (requisites, thresholds), not just objective descriptions — the user wants
   to verify what lands in the DB by reading the output.

7. **Reconcile by set operations** on a stable key. For catalog migrations the key is
   `[domain, subdomain, description]`:
   - discard = `DB − CSV`
   - create  = `CSV − DB`
   - update  = `CSV ∩ DB` where the payload (e.g. requisites) differs → bump the version.

## Running in production (kubectl snippet)

Append to the top-level `custom_gitignore/snippets/snippets.sh` (it already has 50+ working
examples — read the tail and copy the dominant pattern). Canonical shape:

```sh
feature_name="<slug>"
local_directory="custom_gitignore/migrations/${feature_name}"
mkdir -p "${local_directory}"

## local (dry-run)
FILE_PATH="${local_directory}/<data>.csv" TENANT_NAMES="genialcare,careplus_mindplace" DRY_RUN=true bundle exec rake <ns>:<task> | tee "${local_directory}/output-local.txt"

## dry-run (production)
env="production"
kubectl config use-context ${env}
podId=$(kubectl get pods --no-headers -n core -o custom-columns=":metadata.name" --field-selector=status.phase=Running | grep web | head -n 1)

kubectl exec -it "${podId}" -n core -- mkdir -p lib/tasks/<subdir>
kubectl cp "${rake_file}" "core/${podId}:${rake_file}" -n core
kubectl cp "${local_directory}/<data>.csv" "core/${podId}:<data>.csv" -n core

kubectl exec -it "${podId}" -n core -- bash -c '
  FILE_PATH=<data>.csv \
  TENANT_NAMES=genialcare,careplus_mindplace \
  DRY_RUN=true \
  bundle exec rake <ns>:<task>
' | tee "${local_directory}/output-${env}.txt"
```

Pitfalls:

- **`kubectl cp` does NOT create parent directories at the destination.** For rakes in a
  subdir, run `kubectl exec ... -- mkdir -p lib/tasks/<subdir>` BEFORE the `cp`, or copy to
  a flat `lib/tasks/` path. Symptom: `tar: <dir>: Cannot open: No such file or directory`.
- **Source file must exist on the host.** `cp` the CSV into `${local_directory}` first and
  `ls` it before `kubectl cp`. Symptom: `cp: ...: No such file or directory` (often just a
  wrong cwd — run from repo root).
- **Match the rake's argument style.** Read the task signature: positional args
  (`rake "ns:task[a,b]"`) vs ENV vars (`bash -c 'FILE_PATH=... DRY_RUN=... rake ns:task'`).
  The user has caught wrong style, wrong rake name, and wrong rake path repeatedly.
- **Bare relative filenames** for files copied into the pod (match the container working
  directory); pass the same relative name as `FILE_PATH`. Absolute paths like `/app/...`
  can mismatch the container's actual working directory.

- **Validate in the SAME environment you ran the rake in.** After a run, users often
  validate by opening a `rails c` somewhere else and finding "no data" — only to discover
  the pod/context kubectl resolved was a different env than the console's. Before
  debugging the rake, confirm which environment each side is actually in: the `[dotenv]
  Loaded .env.<env>` line and the datadog `env:` tag in the rake's output tell you the
  pod's real env (the console prompt like `core(prod)` reflects the Rails profile, not the
  env). Check `ENV["SERVER_ENV"]` in the console and compare. `kubectl config use-context`
  can silently point at a different cluster than the `env=` variable suggests.

## Output legibility

When the rake prints a dry-run report, the user wants a scannable, indented tree, not a wall
of raw text. Prefer:

```
- Objetivo: <description>
  - requisites:
    - <item 1>
    - <item 2>
```

Show a per-tenant summary with counts (protocol items to create, objectives to
discard/create/update) after each tenant's lists. See
`references/requisites-parsing-and-config.md` for the speech-therapy specifics.

## Verification and CI

- **Lint without Docker.** `make lint` runs `standardrb` inside the Docker app container;
  when the daemon is off, run it directly via the project's rvm gemset (`rvm use` often
  no-ops in non-interactive shells — export the paths directly):
  ```sh
  export PATH="$HOME/.rvm/rubies/ruby-3.4.5/bin:$PATH"
  export GEM_HOME="$HOME/.rvm/gems/ruby-3.4.5@core"
  export GEM_PATH="$GEM_HOME:$HOME/.rvm/gems/ruby-3.4.5@global:$HOME/.rvm/rubies/ruby-3.4.5/lib/ruby/gems/3.4.0"
  standardrb lib/tasks/<subdir>/<task>.rake
  ```
- **Rake tasks have no spec** → the CI test-impact file (`.test-impact/impact-<branch>.txt`,
  required or CI fails) should say `SKIP_TESTS`, not list specs. Copy the header block from
  `.test-impact/impact-add-rake-to-import-typeform-responses.txt`.

## Explaining the diff / updating the PR afterward

After the rake lands you're often asked to explain the feature diff (e.g. via an
explain-diff HTML) or update the PR description. Two recurring gotchas:

- **A stale local `main` inflates the branch-vs-main diff.** `git diff main...HEAD` can
  report hundreds of unrelated files when local `main` is months behind and the branch
  has merged it repeatedly. Find the feature's OWN commits with
  `git log main..HEAD --oneline`, then `git show --stat <sha>` per commit to list the real
  files touched. That small set — not the multi-hundred-file stat — is the feature's diff.
- **Update the PR body via `gh pr edit <n> --body-file <file>`.** Write the markdown to a
  temp file first (avoids `--body` shell-escaping). Correct the stale parts (old rake
  name, old arg style) and fold in what the explanation surfaced: model hierarchy, derived
  config fields, per-tenant vs aggregate, normalization rules.
