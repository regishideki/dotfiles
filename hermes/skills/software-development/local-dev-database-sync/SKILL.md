---
name: local-dev-database-sync
description: "Sync real dev/staging DB data locally via kubectl."
version: 1.0.0
---

# Local Dev Database Sync

## When to use
- Local seeds (`db/seeds.rb` or similar) are synthetic and don't reflect real volume/edge cases, and testing locally needs realistic data.
- You have `kubectl` access to an app pod in the target k8s namespace, but NOT direct Cloud SQL IAM (`cloudsql.client`) or a working Cloud SQL Auth Proxy.
- Goal: restore a remote Postgres dump into a local docker-compose Postgres.

## Core technique — no IAM/proxy needed
The app pod already has `DATABASE_URL` as an env var and `pg_dump`/`psql` installed. Use that instead of provisioning new access:

1. Find a running app pod: `kubectl --context <env> get pods -n <ns> --no-headers | awk '$1 ~ /^web-/ && $3=="Running"{print $1; exit}'`
2. Dump inside the pod using its own connection string: `kubectl exec -n <ns> -c <container> <pod> -- sh -c 'pg_dump "$DATABASE_URL" -Fc --no-owner --no-privileges -f /tmp/dump.pgdump'`
3. Bring it local: `kubectl cp <ns>/<pod>:/tmp/dump.pgdump ./dump.pgdump`
4. Copy into the local Postgres container: `docker compose cp dump.pgdump db:/tmp/dump.pgdump`
5. **Stop the local `app` service before DROP/CREATE DATABASE.** It holds open connections that make `DROP DATABASE` fail ("being accessed by other users"). Restart it unconditionally in a cleanup trap so it comes back even on failure.
6. `pg_restore -j 4 --no-owner --no-privileges` into the target DB. Orphan FK constraint errors from the remote DB's own inconsistent data are common and expected — don't treat them as fatal.

## Critical pitfall: pg_restore's exit code is not reliable
Empirically verified on the Postgres 14 client (`pg_restore (PostgreSQL) 14.x`): it returns exit code `1` for BOTH expected non-fatal warnings (orphan FK constraints) AND genuinely fatal errors (corrupted or missing dump file). **The exit code alone cannot distinguish the two** — do not gate success on `$? -le 1` (a plausible-looking fix suggested by an automated code reviewer once; it silently never would have triggered). Instead verify functionally after restore: query a core table's row count (e.g. `SELECT count(*) FROM users`) and fail loudly if it's empty or unreachable.

## Safety: hard-block production, defense in depth
When a script like this supports multiple source environments:
- Allowlist only non-production values explicitly.
- ALSO add a redundant substring check (`*prod*`) against every variable that could select the environment (both the "source env" var and the underlying `kubectl` context var) — a single allowlist check can be bypassed if only one of the two vars is validated.
- Test the block every way it could be set: the primary var directly, a partial/sneaky value (`core-production`), and through any wrapper (e.g. `make target VAR=production`).

## Script design defaults for this kind of tooling
- No interactive confirmation prompt for operations that only overwrite LOCAL, cheap-to-redo state — run straight through by default.
- Always delete downloaded dump files at the end, success or failure, via ONE `trap cleanup EXIT` handler covering every cleanup concern (temp file removal, remote temp file removal, restarting a stopped service). Registering a second `trap ... EXIT` silently replaces the first in bash — only the last one wins.
- Don't bake a specific environment name into a parameterized script's filename (e.g. don't call it `import_dev_database_locally.sh` if it also supports staging) — name it generically (`import_remote_database_locally.sh`) and expose the environment as a variable (`SOURCE_ENV`).
- `shellcheck` + `bash -n` are the correct lint tools for `.sh` files. In a Ruby repo, `standardrb`/`make lint` only scans `.rb` by default — forcing it onto a shell script produces meaningless `Lint/Syntax` parse noise, not a real signal.

## Verification workflow
- Test end-to-end against a throwaway target database first (`TARGET_DATABASE=scratch_db`), confirm row counts, then drop it — don't point a first test run at the user's main local database.
- **Never push a fix to an open PR — including one based on an automated reviewer's suggestion — without re-running the real end-to-end test locally and confirming it still passes.** A plausible-sounding suggestion (like the pg_restore exit-code one above) can be wrong for the actual tool version in use; only empirical testing catches that.
