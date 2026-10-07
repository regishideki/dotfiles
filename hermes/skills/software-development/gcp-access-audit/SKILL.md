---
name: gcp-access-audit
description: Use when auditing GCP/IAM access before proposing DB dumps.
---

# GCP Access Audit

Trigger: before proposing anything that requires reaching a GCP resource directly
(dump a Cloud SQL DB, export Firestore, read a bucket, connect to a remote service)
— audit what you can ACTUALLY reach first. Don't assume IAM gaps block you; don't
assume personal IAM absence means "no path exists" — check the indirect path via
already-running workloads before concluding access is blocked.

## Auth mechanism first (before anything else)

If a `gcloud`/`kubectl`/`gsutil` command fails with `Reauthentication failed`
(or `invalid_rapt`), that is Google's Workspace session policy forcing a
password re-auth — NOT the ~1h access token just expiring. Don't tell the user
to "just log in again" as the fix; the durable fix is a **service-account key**.

Three flavours, three behaviours: `gcloud auth login` (reauth, expires fast),
ADC (silent refresh — but **kubectl does NOT use ADC**; it uses
`gke-gcloud-auth-plugin` → `gcloud config config-helper`), and SA key (durable,
works for everything once `gcloud auth activate-service-account --key-file=`).

A `Forbidden ... requires ["container.pods.list"]` error means auth SUCCEEDED
but IAM/RBAC is missing — a permission problem, not an auth one.

Full taxonomy, diagnostic signatures, and the durable read-only SA setup live in
`references/gcloud-auth-mechanisms.md`. Read it before diagnosing any
gcloud/kubectl auth failure.

## Steps

1. **Identify active account/project**: `gcloud config list`. Confirm which project
   you're aimed at (GenialCare has many similarly-named projects per env, see
   `references/genialcare-gcp-projects.md`).

2. **Inventory the target resource**:
   - Cloud SQL: `gcloud sql instances list` then `describe <instance>` for
     `settings.tier`, `settings.dataDiskSizeGb`, `settings.ipConfiguration.ipv4Enabled`,
     `settings.ipConfiguration.authorizedNetworks`, `settings.backupConfiguration.enabled`
     and `.pointInTimeRecoveryEnabled`. No backups/PITR = an in-place operation
     (bulk UPDATE, anonymization) on that instance is riskier — recommend a clone
     or snapshot first, don't just run it.
   - **`dataDiskSizeGb` is the ALLOCATED disk, not actual usage** — a 10GB instance
     can be using <1GB. `gcloud sql` has no `time-series` subcommand for actual
     usage; query Cloud Monitoring REST directly:
     ```
     TOKEN=$(gcloud auth print-access-token)
     curl -s -H "Authorization: Bearer $TOKEN" \
       "https://monitoring.googleapis.com/v3/projects/<project>/timeSeries?filter=metric.type%3D%22cloudsql.googleapis.com%2Fdatabase%2Fdisk%2Fbytes_used%22&interval.startTime=<ISO>&interval.endTime=<ISO>"
     ```
     Report actual bytes_used, not the allocation, when sizing a dump/restore plan.
   - Firestore: `gcloud firestore databases list --project=<project>`.
   - Buckets: `gsutil ls -p <project>`.

3. **Check YOUR IAM standing** before assuming a direct-access path is viable:
   ```
   gcloud projects get-iam-policy <project> --format=json | python3 -c "
   import json,sys
   d=json.load(sys.stdin)
   for b in d['bindings']:
       if any('you@example.com' in m for m in b['members']):
           print(b['role'])
   "
   ```
   Look specifically for `roles/cloudsql.client`, `roles/cloudsql.admin`,
   `roles/owner`/`editor`. Their absence means `gcloud sql connect` and the
   Cloud SQL Auth Proxy will fail for you personally — this is a real, current
   constraint to report, not evidence the whole approach is impossible (see next step).

4. **Check the indirect path via workloads that already have access**:
   `kubectl config get-contexts` to see which clusters/namespaces you can reach,
   then `kubectl exec -n <ns> deploy/<name> -- env | grep -i DATABASE` (redact the
   password before showing it to the user) to see the DB connection string a
   running pod already uses. A pod having `DATABASE_URL` with a private IP means
   there IS a way to reach that DB (via `kubectl exec` + `pg_dump` inside the pod,
   or by requesting the missing personal IAM role) even when your own IAM is bare.
   Report both the current personal-IAM gap AND the workload-level path that exists.

5. **Authorized networks / connectivity**: if the instance has a public IP, check
   `settings.ipConfiguration.authorizedNetworks` against your current egress IP
   (`curl -s ifconfig.me`) before concluding a proxy/direct connection will work.

## Pitfalls

- Don't conflate "I lack IAM for direct connect" with "this data is unreachable" —
  always check the kubectl/workload path in step 4 before reporting a hard blocker.
- Cloud SQL instances used for shared dev/staging environments often have backups
  and PITR **disabled** (cost-saving on small tiers) — always verify before
  suggesting any operation that mutates data in place there.
- When the target data MIGHT include PII (patient/clinical data, CPF, health
  info), don't assume a dev/staging environment does or doesn't have it —
  **ask the user directly** ("does this env contain real customer/patient
  data?") before recommending or blocking a dump-to-local plan on that basis.
  GenialCare's `core-development` Cloud SQL instance, for example, holds only
  synthetic/test data (confirmed by user, 2026-08) — a blanket "always
  anonymize before dumping locally" pitfall produced a wrong, unnecessary
  blocker in that case. Treat PII risk as environment-specific and
  user-confirmed, not something to infer from schema/table names alone.
- `gcloud sql connect` fails hard on IPv6 client addresses with a confusing
  "doesn't support IPv6 networks" error — this is a client-side network quirk,
  not proof the instance is unreachable; re-check via IPv4 egress or the proxy.

## Executing the dump once access is confirmed (kubectl-exec path, no cloudsql.client needed)

When step 4 finds a workload with a usable `DATABASE_URL`, the full remote-dump
→ local-restore flow (validated end-to-end against a real Cloud SQL dev
instance, ~33MB dump, <1 min total) is:

1. `kubectl exec -n <ns> -c <container> <pod> -- sh -c 'pg_dump "$DATABASE_URL" -Fc --no-owner --no-privileges -f /tmp/dump.pgdump'`
   (use `-Fc` custom format so `pg_restore -j N` can parallelize; run inside
   `sh -c '...'` so `$DATABASE_URL` expands in the pod's shell, not locally).
2. `kubectl cp -n <ns> -c <container> <pod>:/tmp/dump.pgdump ./local_dump.pgdump`
   then `kubectl exec ... -- rm -f /tmp/dump.pgdump` to clean up the pod.
3. `docker compose cp ./local_dump.pgdump db:/tmp/dump.pgdump` to stage it inside
   the local Postgres container (works even though the host has no direct
   network path to the container's internal socket).
4. Recreate the target DB (`DROP DATABASE IF EXISTS` + `CREATE DATABASE`) via
   `docker compose exec -T db psql -U root -h localhost -d postgres -c ...`,
   then `docker compose exec -T db pg_restore -U root -h localhost -d <db> --no-owner --no-privileges -j 4 /tmp/dump.pgdump`.
5. Expect `pg_restore` to report a handful of ignored FK-constraint errors from
   orphaned rows that already exist in the remote DB — this is normal remote-data
   noise, not a restore failure; `pg_restore` still exits 0 and the schema/data
   land fine. Don't treat "errors ignored on restore: N" as a blocker.

This whole flow needs **zero extra IAM** beyond what already runs the pod —
package it as a `bin/custom/<name>.sh` script (mirror the retry/kctl-wrapper
style of existing `bin/custom/*.sh` scripts in the repo) plus a `make <target>`
entry. Default to always DROP/recreate the target DB without a confirmation
prompt and always delete the downloaded dump afterwards — only add a confirm
or dump-retention toggle if the user explicitly asks for one; don't add these
"safety" gates preemptively (a user pushed back on both when offered unasked).
**If more than one non-production source environment exists (development AND
staging), support both via an allowlisted `SOURCE_ENV` variable and hard-block
production redundantly across every variable that picks the target — see the
`local-dev-db-sync` skill for the full pattern and a ready-to-copy template.**

See `references/genialcare-gcp-projects.md` for known GenialCare project IDs,
Cloud SQL instance names, and kubectl contexts (saves rediscovery next time).

See `references/verifying-non-ruby-changes-in-rails-repo.md` for how to verify
a shell/Makefile change in a standardrb-linted Rails repo without producing
false-positive Ruby syntax noise.
