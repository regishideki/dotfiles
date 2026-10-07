# GenialCare GCP inventory (core repo)

Discovered during a session investigating local-dev-data strategy for `core`.
Re-verify before relying on it long-term — infra changes.

## Projects (per env, `<service>-<env>-<suffix>`)
- `core-development-hy78`, `core-staging-j2s1`, `core-production-0c64`
- `clinical-panel-dev`, `clinical-panel-staging`, `clinical-panel` (production)
- `clinical-llm-development-96e1` / `-staging-375c` / `-production-df79`
- `allocation-development-7dh2` / `-staging-f9u8` / `-production-42o9`

## Cloud SQL (core, dev)
- Instance: `core-pg-instance-development1` (Postgres 14, `db-g1-small`, 10GB
  **allocated** disk, zonal, **backups disabled, no PITR**). DB name:
  `core-pg-db-development1`.
- Actual usage is much smaller than the allocation: confirmed via Cloud
  Monitoring `disk/bytes_used` at ~950MB (dump came out ~33MB compressed,
  restores in under a minute). Don't assume `dataDiskSizeGb` reflects real size.
- **Contains no real patient/customer data — synthetic/test data only**
  (confirmed by user, 2026-08). No LGPD/PII blocker for dumping this specific
  instance to a local machine. This does NOT generalize to other GenialCare
  Cloud SQL instances (staging/production) — always ask the user per-environment.
- Private IP `10.20.0.3` (used by in-cluster workloads via `DATABASE_URL`),
  public IP `34.73.171.45` (authorized-networks only allow Datastream IPs by
  default — a dev's personal IP is NOT allowlisted unless added).
- Separate `event-store-instance-development1` exists but was `FAILED` state
  at last check — don't assume it's usable without re-checking.

## Firestore (dev)
- Project `clinical-panel-dev`, database `central-de-acolhimento` (native mode,
  PITR disabled, `nam5`).

## GKE clusters / kubectl contexts (exact names)
- Context aliases `production` / `staging` / `development` map to full names:
  - `gke_kubernetes-production-cd91_us-east1_kubernetes-production` → project `kubernetes-production-cd91` (projectNumber 1066000100260)
  - `gke_kubernetes-staging-9ce9_us-east1_kubernetes-staging` → `kubernetes-staging-9ce9`
  - `gke_kubernetes-development-9b05_us-east1-c_kubernetes-development` → `kubernetes-development-9b05`
- The `core` namespace (web/solid-queue/eventconsumer) lives on these clusters; use `-n core` explicitly.

## BigQuery (production datasets)
- `data-kernel-production-4o7n.datakernel` — clinical cases, sessions, clinicians.
- `supervision-production-8f1v` — assessment, PEI, protocols, intervention; used as the billing project for cross-project queries.

## GCS
- Bucket `genial-apps-tools-production` lives in project `kubernetes-production-cd91` (projectNumber 1066000100260) — NOT a project literally named `genial-apps-tools-production`. To find any bucket's owning project:
  `curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" "https://storage.googleapis.com/storage/v1/b/<bucket>?fields=projectNumber"`

## Known gap at time of writing
- A dev with only `roles/storage.admin` on `core-development-hy78` has NO
  `cloudsql.client`/`cloudsql.admin` — direct `gcloud sql connect` and Cloud SQL
  Auth Proxy fail. The workaround is `kubectl exec` into a pod in the `core`
  namespace that already carries `DATABASE_URL` (private IP path), or requesting
  the missing IAM role from infra.
