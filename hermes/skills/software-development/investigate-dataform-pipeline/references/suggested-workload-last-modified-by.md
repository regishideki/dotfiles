# Worked Example: last_modified_by in suggested_workload (supervision)

Session: August 2026 — read-only investigation of the supervision project
for the feature "Exibir campo last_modified_by nos workloads do clinical case
no painel de supervisão."

## What was searched

1. `package.json` → only dep `@dataform/core` → confirmed Dataform project
2. `workflow_settings.yaml` → GCP project `supervision-development-9a7j`,
   default dataset `intervention`, cross-project vars (`datakernel`,
   `operational`, `guidance`)
3. Content search for `workload` → 24 matches, all in `suggested_workload`
   domain under `definitions/assessment/suggested_workload/`
4. Content search for `clinical_case` → 30 matches across multiple domains
5. Content search for `last_modified` → **0 matches** — field does not exist
6. Content search for `approved_by|reproved_by|dim_users|last_modified` →
   found the `dim_users` JOIN pattern in 4 models

## Key files examined

| File | Purpose |
|---|---|
| `definitions/assessment/suggested_workload/suggested_workload_events.sqlx` | External table reading CDC JSON from GCS |
| `definitions/assessment/suggested_workload/suggested_workload.sqlx` | Materialized model (final table) |
| `definitions/assessment/suggested_workload/test_suggested_workload.sqlx` | Unit test |
| `includes/assessments/tables/suggested_workload.js` | Column metadata + assertions |
| `includes/assessments/index.js` | Domain table registry |
| `includes/functions.js` | `renderEventTable()` dedup logic |
| `definitions/datasources/dim_users.sqlx` | Declaration → `datakernel.aggregates.dim_users` |
| `definitions/datasources/clinical_cases.sqlx` | Declaration → `datakernel.datakernel.clinical_cases` |
| `definitions/clinicians/int_clinicians_enriched.sqlx` | Example of dim_users JOIN pattern |

## Findings

- `suggested_workload` is the only workload entity (domain: `assessment`)
- `last_modified_by` / `last_modified_by_id` does NOT exist anywhere in the
  supervision project (0 content matches)
- `updated_at` exists (timestamp of last modification, non-null)
- `approved_by_id` and `reproved_by_id` exist as UUIDs but are NOT resolved
  to names in the `suggested_workload` model
- `ignore_unknown_values = TRUE` on the external table means even if the core
  started emitting `last_modified_by`, it would be silently discarded
- Source GCS path: `gs://genialcare-event-store-<env>/streams/database-events/core/public_assessments_suggested_workloads/*`
  → Rails table: `public_assessments_suggested_workloads`

## Implementation would require

1. Core: persist `last_modified_by` (or `last_modified_by_id`) in
   `public_assessments_suggested_workloads` table
2. Datastream: automatically replicates new columns (no action needed)
3. External table (`suggested_workload_events.sqlx`): add field to schema
4. Model (`suggested_workload.sqlx`): add field to SELECT projection
5. Includes (`suggested_workload.js`): add column metadata
6. Test (`test_suggested_workload.sqlx`): add field to mocks and expected output
7. For name display: JOIN with `dim_users` on `last_modified_by_id = users.id`

## dim_users JOIN pattern (from existing models)

```sql
-- Pattern used in int_clinicians_enriched.sqlx, dim_clinicians.sqlx, etc.
LEFT JOIN ${ref("aggregates", "dim_users")} users
  ON users.id = <table>.<field>_by_id
```

`dim_users` is materialized by the data-kernel project (not supervision).
It's declared in `definitions/datasources/dim_users.sqlx` as:
```sql
config {
  type: "declaration",
  database: dataform.projectConfig.vars.datakernel,
  schema: "aggregates",
  name: "dim_users",
}
```
