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

## kubectl contexts
- `development` context → cluster `kubernetes-development`, default namespace
  `clinical-panel-bff`; the `core` namespace's `web`/`solid-queue`/`eventconsumer`
  deployments live there too (use `-n core` explicitly).
- `staging` and `production` contexts point at their respective clusters.

## Known gap at time of writing
- A dev with only `roles/storage.admin` on `core-development-hy78` has NO
  `cloudsql.client`/`cloudsql.admin` — direct `gcloud sql connect` and Cloud SQL
  Auth Proxy fail. The workaround is `kubectl exec` into a pod in the `core`
  namespace that already carries `DATABASE_URL` (private IP path), or requesting
  the missing IAM role from infra.
