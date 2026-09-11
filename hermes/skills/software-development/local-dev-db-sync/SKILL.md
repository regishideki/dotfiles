---
name: local-dev-db-sync
description: Use when dev seeds are synthetic; sync real Cloud SQL data.
---

# Local dev DB sync (Cloud SQL → local docker-compose)

## When to use
- A team's local dev/seed data is too synthetic (hand-written FactoryBot fixtures) to catch real bugs, and the "fix" the team actually does is point local BFF/frontend at a shared remote dev environment instead of running fully local.
- You need a realistic Postgres dataset locally but `gcloud sql connect` / Cloud SQL Auth Proxy fail because your IAM user lacks `roles/cloudsql.client` (common — most devs only get `storage.admin` or similar, not SQL Admin).
- Any Rails/Postgres app deployed on GKE where an app pod already has a `DATABASE_URL` env var pointing at the Cloud SQL private/public IP.

## Core technique: dump via the app pod, not the Cloud SQL Proxy
Cloud SQL Auth Proxy and `gcloud sql connect` both require `cloudsql.client` IAM, which is frequently not granted to individual devs. But the **already-running app pod in the cluster has network access and the connection string** — use that instead. No new IAM permission needed.

```bash
# 1. Find the running pod (adjust namespace/deployment name)
kubectl config use-context <cluster-context>
POD=$(kubectl get pods -n <namespace> --no-headers | awk '$1 ~ /^web-/ && $3=="Running" {print $1; exit}')

# 2. Dump remotely (custom format = compressed + parallel-restorable)
kubectl exec -n <namespace> -c <container> "$POD" -- \
  sh -c 'pg_dump "$DATABASE_URL" -Fc --no-owner --no-privileges -f /tmp/dump.pgdump'

# 3. Bring it to your machine
kubectl cp -n <namespace> -c <container> "$POD:/tmp/dump.pgdump" ./dump.pgdump
kubectl exec -n <namespace> -c <container> "$POD" -- rm -f /tmp/dump.pgdump   # clean up remote tmp

# 4. Load into local docker-compose Postgres
docker compose cp ./dump.pgdump db:/tmp/dump.pgdump
docker compose exec -T db psql -U root -h localhost -d postgres -c "DROP DATABASE IF EXISTS core_development;"
docker compose exec -T db psql -U root -h localhost -d postgres -c "CREATE DATABASE core_development;"
docker compose exec -T db pg_restore -U root -h localhost -d core_development --no-owner --no-privileges -j 4 /tmp/dump.pgdump || true
```

A full round-trip (dump + copy + restore) on a ~1GB dev database took well under a minute in practice.

## Downstream symptom: SSO auto-login + empty local DB = confusing "access denied"
If the app uses a real (non-emulated) Auth0/OIDC provider even in local dev, a browser with an existing
SSO session will log in **silently** — no username/password prompt — using whatever corporate identity
is already authenticated with that provider. This is expected, not a bug, and can confuse a user who
expects a login form (they'll report "it just logs me in and I don't know which user, then I get access
denied"). The real cause is usually NOT auth — it's that `current_user = User.find_by_email(email)` (or
equivalent) returns nil because the local database is empty or missing that specific user, so every
Pundit/authorization check that requires a user fails downstream. Diagnose with a quick row count before
chasing the auth flow itself:
```bash
docker compose exec -T db psql -U root -h localhost -d core_development -c "SELECT count(*) FROM users;"
docker compose exec -T db psql -U root -h localhost -d core_development -c \
  "SELECT email FROM users WHERE email = 'the-sso-email@company.com';"
```
If the count is 0 or the SSO email isn't present, the fix is exactly this skill's dump/restore flow — not
a `db:seed` re-run (synthetic seeds create only one hardcoded dev user, e.g. `dev@company.com`, which
won't match whatever real corporate email the SSO session hands back).

## Pitfalls
- **`DROP DATABASE` fails with "is being accessed by other users" if the app container is running.** The
  Rails server / background worker container (`docker compose` service `app`) holds open connections to
  the target database. `DROP DATABASE` will error with `ERROR: database "X" is being accessed by other
  users / DETAIL: There are N other sessions using the database.` Stop the app service before dropping,
  restore, then start it back up — and always restore it even if the restore step fails partway. Combine
  this with any other exit-time cleanup (e.g. deleting a downloaded dump file) into ONE function and ONE
  `trap ... EXIT` call — see the dedicated pitfall below about `trap` only keeping the last registration.
  ```bash
  APP_WAS_RUNNING="false"
  cleanup() {
    [[ "$APP_WAS_RUNNING" == "true" ]] && docker compose start app
  }
  trap cleanup EXIT
  if docker compose ps app --status running --format json 2>/dev/null | grep -q .; then
    APP_WAS_RUNNING="true"
    docker compose stop app
  fi
  # optional extra safety net — terminate any leftover connections before DROP DATABASE:
  docker compose exec -T db psql -U root -h localhost -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='core_development' AND pid<>pg_backend_pid();"
  ```
  A `trap ... EXIT` guarantees the app comes back up even if `pg_restore` or an earlier step fails —
  don't just stop/start inline without the trap, or a mid-script failure leaves the app down.
- **A test/throwaway target database (not the real `core_development`) does NOT prove the fix worked for
  the user.** If you validate the dump/restore flow by restoring into a scratch database name (e.g.
  `core_dev_import_test`) to avoid touching the user's real data without confirmation, say so explicitly
  when reporting results — "I validated the mechanism, but your actual `core_development` is still empty/
  unchanged" — instead of letting the success report imply the user's real database was updated. This
  caused real confusion in one session: the mechanism was proven correct, but the user's app still had an
  empty `core_development` because the validated run was scoped to a separate test database, and the
  distinction wasn't called out clearly enough at the time.
- **`pg_restore` FK errors are often expected, not bugs.** If the remote database already has orphan foreign keys (pre-existing data inconsistencies), `pg_restore` will print `ERROR: insert or update ... violates foreign key constraint` for those rows and finish with `errors ignored on restore: N`. That's fine — verify success by querying row counts afterward, not by demanding a clean exit code. Use `|| true` after `pg_restore` so the script doesn't abort on this expected condition.
- **Don't confuse allocated disk size with actual data volume.** `gcloud sql instances describe --format="value(settings.dataDiskSizeGb)"` reports the *allocated* disk (e.g. 10GB), not usage. To get real usage, query Cloud Monitoring: `metric.type="cloudsql.googleapis.com/database/disk/bytes_used"` via the REST API (`gcloud monitoring` CLI doesn't have a `time-series list` command — use `curl` against `monitoring.googleapis.com/v3/.../timeSeries` with a bearer token from `gcloud auth print-access-token`). This matters before assuming a dump/restore will be slow or expensive.
- **Verify with real row counts, not just "the restore command didn't crash".** After restoring, run a quick `SELECT count(*)` sanity check across a few key tables (and total DB size via `pg_size_pretty(pg_database_size(...))`) to confirm the data actually landed, then drop any throwaway test database you created for validation.
- **`standardrb`/Ruby linters do not apply to `.sh` files.** If a repo's `make lint` only runs `bundle exec standardrb`, that's correct behavior — it silently skips non-`.rb` files. Do NOT force a Ruby linter onto a shell script by passing it explicitly as an argument; it will parse the shell script as Ruby and emit hundreds of nonsensical `Lint/Syntax` errors. Use `shellcheck` + `bash -n` for `.sh` files instead, and treat that as the real linter for that file type.
- **Watch for LGPD/PII before assuming a remote dump is safe to pull locally.** Ask explicitly whether the source database contains real user data. If it does, dumping it wholesale to a laptop is a compliance risk — prefer a scoped/anonymized subset. Only skip this concern once the user confirms the environment has no real PII (e.g., a true "development" env seeded synthetically, as opposed to "staging" which may mirror production).
- **Follow the repo's existing `bin/custom/*.sh` conventions if present** (e.g. a `kctl()` wrapper that respects `kubectl config use-context` failures by falling back to `--context`, `log()`/`warn()` helpers with timestamps, retry loops with backoff for `kubectl cp`). Match the house style instead of inventing a new one — check sibling scripts first.
- **Code/comments/log strings go in English even when chat with the user is in another language.** Many orgs (e.g. AGENTS.md-governed Rails monorepos) mandate English in all code artifacts including shell script comments and `echo`/log output, while conversational replies stay in the user's language. Don't assume comments can match the chat language.

## PR for this kind of change often needs no test run
If the resulting script/Makefile change is the only diff (no `.rb`, spec, or `db/schema.rb` touched),
the repo's test-impact system usually supports a full-skip shortcut — e.g. in GenialCare's `core` repo,
create `.test-impact/impact-<branch-slug>.txt` with a first line of `SKIP_TESTS` plus a `# reason:` comment,
instead of running the full test-impact analysis. Confirm with `git diff --name-only origin/main...HEAD`
that the diff really is Ruby/spec/schema-free before doing this — see the `pr-open` skill (user-owned,
not curator-editable) for the exact file format.

## Preferred technique: dump from an ephemeral pod, not `kubectl exec` on a shared pod
`kubectl exec` into an existing `web-*` pod is exposed to that pod being killed mid-dump by a deploy
rollout — a real risk on environments that deploy often (shared `development`/`staging`). A retry loop
that re-resolves the pod name on each attempt (see below) works, but a simpler and more robust fix is to
never touch a pod that could be rolled out from under you in the first place:

```bash
# 1. Read image + env (envFrom/env) straight off the existing Deployment — no new
#    manifest to maintain, and it always matches whatever's actually deployed.
DEPLOYMENT_JSON=$(kubectl get deployment web -n core -o json)
IMAGE=$(echo "$DEPLOYMENT_JSON" | jq -r '.spec.template.spec.containers[0].image')

# 2. Build a pod override that runs pg_dump, drops a marker file on completion,
#    then sleeps — kubectl run pods are NOT part of any Deployment/ReplicaSet,
#    so a rollout of "web" can never touch them.
OVERRIDES=$(echo "$DEPLOYMENT_JSON" | jq -c --arg name "core-dump-$(date +%s)" \
  '{spec:{containers:[{name:$name, image:.spec.template.spec.containers[0].image,
    command:["/bin/sh","-c","pg_dump \"$DATABASE_URL\" -Fc --no-owner --no-privileges -f /tmp/dump.pgdump && touch /tmp/dump_done || (touch /tmp/dump_done.failed; exit 1); sleep 1800"],
    envFrom:(.spec.template.spec.containers[0].envFrom // []), env:(.spec.template.spec.containers[0].env // [])}],
    restartPolicy:"Never"}}')

kubectl run "$POD_NAME" -n core --image="$IMAGE" --restart=Never --overrides="$OVERRIDES"
kubectl wait --for=condition=Ready "pod/$POD_NAME" -n core --timeout=180s

# 3. Poll for the marker file instead of waiting on pod phase — the pod stays
#    Running (sleeping) after the dump finishes, it never exits on its own.
while ! kubectl exec -n core "$POD_NAME" -- test -f /tmp/dump_done 2>/dev/null; do
  kubectl exec -n core "$POD_NAME" -- test -f /tmp/dump_done.failed 2>/dev/null && { kubectl logs "$POD_NAME" -n core; exit 1; }
  sleep 3
done

# 4. kubectl cp the result out, then ALWAYS delete the ephemeral pod (put this in
#    the same cleanup trap that handles the local dump file / app restart).
kubectl delete pod "$POD_NAME" -n core --ignore-not-found
```

This eliminates the need for a retry-and-reresolve loop around the dump step entirely — there's no shared
pod to lose. Requires `jq` locally (already common; check with `command -v jq`) and that your kubectl
identity can `create`/`delete` pods and `get` the deployment in that namespace (`kubectl auth can-i create
pods -n <ns>` to check ahead of time).

**Pitfalls specific to the ephemeral-pod approach, verified in practice:**
- If `kubectl wait --for=condition=Ready` times out (e.g. large image not yet cached on the node — the
  first pull can take minutes), the pod may still be mid-`ContainerCreating`/image-pull when you decide to
  bail. `kubectl delete pod` on a pod that's still pulling an image can leave it in `Terminating` for a
  couple of minutes until kubelet finishes the pull and can actually tear it down — this is normal
  Kubernetes behavior, not a stuck/broken cleanup; don't add extra force-delete logic for it, just let it
  finish (a background terminal check on a delayed loop is enough to confirm it eventually clears).
- Always put the ephemeral-pod delete in the SAME single `trap cleanup EXIT` as the local dump-file removal
  and app-service restart — see the "single trap" pitfall elsewhere in this skill. Splitting pod cleanup
  into a second `trap ... EXIT` will silently disable one of the two.

## Fallback: retry the dump itself if staying on the shared pod approach
If you keep using `kubectl exec` on an existing `web-*` pod rather than the ephemeral-pod approach above,
add a retry loop around the `pg_dump` step (the download step commonly already has one, the dump step
often doesn't) and **re-resolve the target pod on each retry** (re-run whatever `find_target_pod` function
you used initially) rather than reusing the stale pod name — a deploy replaces the pod, so the old name is
gone. Verified with a forced-failure test (pointing `POD_NAME` at a nonexistent pod for attempt 1): the
retry correctly re-resolved to a real running pod on attempt 2 and completed successfully.

## Known scope limitation: dumps include every tenant, unfiltered
A full `pg_dump` of a multi-tenant database (tenant_id spread across most tables) pulls ALL tenants
present in that environment — including any partner/client sandboxes that might exist there, not just
the org's own tenant. Filtering to one tenant is NOT a small script tweak: it would need a dedicated
post-restore cleanup task that walks FK dependency order, not a `WHERE tenant_id = ...` on `pg_dump`
itself. When this is raised as a concern (e.g. in PR review), the right move is: (1) don't scope-creep the
script to solve it now, (2) document the limitation explicitly in the script's own header comment so it's
a stated trade-off, not a silent gap, and (3) suggest a follow-up issue if the concern is about org-level
data-access policy rather than compliance/PII (compliance/PII should already have been ruled out before
doing any dump at all — see the LGPD/PII pitfall above).

## Making it repeatable
Wrap the above into a script (e.g. `bin/custom/import_remote_database_locally.sh`) with env-var overrides for context/namespace/pod-regex/target-database, and a Makefile target (e.g. `make import-remote-db: up-dependencies`) so the whole flow is one command for the team. See `templates/import_remote_db_locally.sh` for a generic starting point.

- **Default to NO interactive confirmation and NO dump-retention option, unless the user explicitly asks for them.** An earlier iteration of this script had an interactive `y/N` prompt (skippable via `SKIP_CONFIRM=true`) before `DROP DATABASE`, plus a `KEEP_DUMP_FILE=true` flag to keep the downloaded `.pgdump` around. When asked directly, the user rejected both: overwriting a local/scratch dev database is cheap and expected — no prompt needed, just always drop/recreate — and keeping downloaded dumps around risks silently accumulating disk usage for no real benefit (re-running the remote dump step is an acceptable cost if the data is needed again). Don't add "safety" toggles like these preemptively; ask first, or default to the simpler always-overwrite / always-clean-up behavior and only add a gate if the user actually wants one.
- **A single `trap ... EXIT` per script, not several.** Bash only keeps the LAST `trap` registered for a given signal — a second `trap foo EXIT` silently replaces an earlier `trap bar EXIT`, so `bar` never runs. If the script needs to both restart a stopped `app` service AND always delete a downloaded dump file on exit, combine both actions into ONE cleanup function and register it with a single `trap cleanup EXIT`. This is easy to introduce when adding a new cleanup concern incrementally (e.g. adding dump-file cleanup to a script that already had an app-restart trap) — always grep for existing `trap` calls before adding a new one, and merge instead of stacking.
- **Don't hardcode "dev" into the script name, variable names, or comments if more than one source environment is plausible (development AND staging, say).** A user who first asked for "dev database" may later ask "can this also pull from staging?" — naming everything `*_dev_*` forces an awkward rename later. Default to a neutral name (`import_remote_database_locally.sh`, a `SOURCE_ENV` variable) from the start whenever more than one non-production environment exists in the target infra, even if the first request only mentions "dev".
- **When multiple source environments are supported, hard-allowlist them and hard-block production — redundantly, not just via one gate.** Don't rely on a single "not literally the string production" check; check EVERY variable that influences which cluster/DB gets touched (both a `SOURCE_ENV`-style var AND the derived `KUBE_CONTEXT`), and reject not just an exact match but any substring match (`*prod*`) to catch context names like `core-production` or typos. Validate against an explicit allowlist (`development`, `staging`) rather than a denylist — an allowlist fails safe if a new environment name is added later without updating the script; a denylist doesn't. Test the block with several inputs before calling it done: exact match, only-one-of-two-vars set, and a sneaky substring variant.
- **Put runnable usage examples directly in the Makefile as comments above the target**, not just in the script's own header comment — the Makefile is often the first (and only) place a teammate looks before running `make <target> VAR=value`. Recipe-line variables set on the `make` command (`make target VAR=value`) ARE exported to the recipe's environment automatically (verified: `make target VAR=value` sets `$VAR` inside the shell command running for that target) — so `SOURCE_ENV=staging`, `TARGET_DATABASE=...`, etc. all flow through cleanly from `make` invocation to the underlying script without extra plumbing.
