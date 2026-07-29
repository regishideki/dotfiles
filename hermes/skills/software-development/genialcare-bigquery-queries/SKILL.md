---
name: genialcare-bigquery-queries
description: Write and validate BigQuery SQL for GenialCare data.
---

# GenialCare BigQuery Queries

Author and validate BigQuery SQL queries in the `code-snippets` repository.

## When to use

- User asks for a new SQL query or to modify an existing one
- User wants to explore what tables/columns exist in BigQuery
- User needs to join data across the GenialCare GCP projects (data-kernel, supervision, ops-data, guidance)
- User asks to test or validate a query in a specific environment

## Output style preferences

The user prefers lean, readable query output. When writing SELECT columns:

- **No alias prefixes** — use `code`, `domain`, `subdomain`, not `pi_code`, `pi_domain`, `pi_subdomain`. The user explicitly asked to remove `pi_` prefixes.
- **No IDs** — don't include internal IDs (`library_objective_id`, `objective_id`, `ecc.id`, etc.) unless the user specifically asks for them.
- **No `objective_order`** — not needed unless explicitly requested.
- **Minimal columns** — only include what the user asked for. Don't add extra columns "just in case."
- **Use the active-clinical-cases CTE only when clinical-case-level data is needed.** If the user wants library-level / protocol-level data only (not per-case), skip `active_clinical_cases` and query `library_objectives` directly — but remember the tenant filter (see Multi-tenant duplication pitfall).

## Workflow

1. **Gather context first.** Read existing queries under `queries/<domain>/` to understand established patterns, table names, and join chains before writing anything new. Use `search_files` to find queries referencing relevant tables or domains.

2. **Discover schema when needed.** If the target table or column is not referenced in any existing query, use `INFORMATION_SCHEMA` to inspect it:
   ```sql
   -- List tables matching a pattern
   SELECT table_name
   FROM `supervision-production-8f1v.intervention.INFORMATION_SCHEMA.TABLES`
   WHERE table_name LIKE '%evolution%'
   ORDER BY table_name;

   -- Inspect columns of a table
   SELECT column_name, data_type
   FROM `supervision-production-8f1v.intervention.INFORMATION_SCHEMA.COLUMNS`
   WHERE table_name = 'evolution_check_configurations'
   ORDER BY ordinal_position;
   ```
   Always run `bq query --use_legacy_sql=false --format=prettyjson "<sql>"` directly — don't just show the SQL.

3. **Use the active-clinical-cases CTE pattern.** Copy the `children_data` and `active_clinical_cases` CTEs from `queries/utils/active-clinical-cases.sql` as the base for any query that needs to filter to valid, active cases. Do NOT replicate the filter conditions manually.

4. **Filter by discipline via protocol name.** Disciplines are identified by the `protocols.name` column:
   - `Fonoaudiologia` → Fono
   - `Terapia Ocupacional` → TO
   - `Vineland 3` → Psico

   Add `AND p.name = 'Fonoaudiologia'` to the join/filter on `protocols`.

5. **Write the query file** under `queries/<domain>/<descriptive-name>.sql`. Match the style of neighboring files (header comment, CTE structure, column aliases, ORDER BY). Use `write_file`.

6. **Validate by running.** Always run the query with `bq query` before considering the task done:
   ```sh
   bq query --use_legacy_sql=false --format=prettyjson < queries/<domain>/<file>.sql
   ```
   For a specific environment, use `bq-run.sh`:
   ```sh
   ./bq-run.sh --env staging queries/<domain>/<file>.sql
   ```

## Standard join chains

### Objectives chain (clinical_case → PEI → objectives → library_objectives → protocol_items → protocols)

```
clinical_cases
  → peis (pei.clinical_case_id = cc.id)
  → objectives (obj.pei_id = pei.id)
  → library_objectives (lobj.id = obj.library_objective_id)
  → protocol_items (pi.id = lobj.protocol_item_id)
  → protocols (p.id = pi.protocol_id)
```

### Evolution check configuration

`evolution_check_configurations` links to `library_objectives` via `library_objective_id`. It contains:
- `configuration_type` — `trial_counter` or `checklist`
- `completion_threshold` — FLOAT64 (nullable; only for checklist)
- `unit_of_measurement` — e.g. `quantidade`, `vezes`
- `max_measurements` — INT64
- `instructions` — text guidance for the clinician
- `prerequisites` — `ARRAY<STRUCT<name STRING>>` (pré-requisitos para a checagem)
- `requisites` — `ARRAY<STRUCT<name STRING>>` (itens do checklist)

See `queries/evolution-check/fono-objectives-with-evolution-check-configurations.sql` for a working example.

### Evolution checks (actual assessments)

For actual evolution check records (not configuration), the chain is:
```
objectives
  → objective_evolution_checks (oec.intervention_objective_id = obj.objective_id)
  → evolution_checks (ec.id = oec.intervention_evolution_check_id)
  → sessions (session.id = ec.intervention_session_id)
```
Key fields in `objective_evolution_checks`: `was_assessed`, `all_prerequisites_checked`, `evolution_scale`, `observations`.

See `queries/utils/objective-evolution-chain.sql` for a reusable CTE.

## Pitfalls

### BigQuery Array ordering — use WITH OFFSET

When extracting array elements in order, you MUST use `WITH OFFSET`:
```sql
-- WRONG — "Unrecognized name: OFFSET"
ARRAY(
  SELECT prereq.name FROM UNNEST(ecc.prerequisites) AS prereq
  ORDER BY OFFSET
)

-- CORRECT
ARRAY(
  SELECT prereq.name FROM UNNEST(ecc.prerequisites) AS prereq WITH OFFSET
  ORDER BY OFFSET
)
```

### CSV format cannot export repeated fields

`bq query --format=csv` fails with `Cannot print repeated field` when the query returns ARRAY columns. Use `--format=prettyjson` or `--format=json` instead. If CSV is needed, wrap ARRAY columns in `STRING_AGG` or `TO_JSON_STRING`.

### LEFT JOIN for optional configuration

Not all library objectives have an evolution check configuration. Use `LEFT JOIN` on `evolution_check_configurations` to include objectives without configuration (the config columns will be NULL).

### Multi-tenant duplication — filter by tenant_id

There are **two protocols named "Fonoaudiologia"** (and likewise for other disciplines) — one per tenant. When querying `library_objectives` joined to `protocols` by name **without** going through `active_clinical_cases` (which already filters by tenant), every row appears duplicated.

Tenant IDs:
- `6f8da042-2dd1-4872-a613-84d371bde78c` → GenialCare
- `a4d02a8c-4c27-41b6-80ac-3401f3964e34` → Care+Mindplace

**Fix:** filter `protocols.tenant_id` (or `library_objectives.tenant_id`) when querying the library/protocol layer directly:
```sql
INNER JOIN `supervision-production-8f1v.intervention.protocols` p
  ON p.id = pi.protocol_id
  AND p.name = 'Fonoaudiologia'
  AND p.tenant_id = '6f8da042-2dd1-4872-a613-84d371bde78c'  -- GenialCare
```
This is NOT needed when joining through `active_clinical_cases` — that CTE already scopes to a single tenant via the `tenants` table join.

### Formatting arrays as text lists with STRING_AGG

When the user wants `ARRAY<STRUCT<name STRING>>` columns (like `prerequisites`/`requisites`) rendered as a readable text list rather than a JSON array, use `STRING_AGG` inside a scalar subquery:
```sql
(
  SELECT STRING_AGG('- ' || prereq.name, '\n' ORDER BY OFFSET) || '\n'
  FROM UNNEST(ecc.prerequisites) AS prereq WITH OFFSET
) AS prerequisites
```
This produces:
```
- Intenção comunicativa
- Associar desejo/necessidade ao uso do recurso.
- Ação motora de deslocamento em direção ao dispositivo
```
The trailing `|| '\n'` ensures a final newline. If the array is empty, the subquery returns NULL.

### objectives table primary key is `objective_id`, not `id`

The `objectives` table uses `objective_id` as its primary key. Other tables (e.g. `objective_evolution_checks`) reference it as `intervention_objective_id`.

### Sessions clinicians ARRAY — UNNEST to filter by clinician

The `sessions` table stores clinicians as a repeated field (`s.clinicians`). To filter sessions by clinician email, you must `UNNEST` the array and join back to `clinicians`:

```sql
FROM `data-kernel-production-4o7n.datakernel.sessions` s
JOIN UNNEST(s.clinicians) AS clinician
JOIN `data-kernel-production-4o7n.datakernel.clinicians` c ON c.id = clinician.clinician_id
WHERE LOWER(c.user_email) = 'someone@gmail.com'
```

The `clinicians` array element has a `clinician_id` field (not `id`). The `clinicians` table column for email is `user_email` (not `email` — that's on the `users` table).

### bq-run.sh flag syntax — space-separated, not `=` syntax

`bq-run.sh` uses a manual argument parser that does NOT accept `--flag=value` syntax. Always use space-separated flags:

```sh
# WRONG — "Flag desconhecida: --format=prettyjson"
./bq-run.sh --env=staging --format=prettyjson queries/foo.sql

# CORRECT — space-separated
./bq-run.sh --env staging --format prettyjson queries/foo.sql
```

This applies to `--env` and `--format` alike.

## GCP project reference

| Project | Dataset prefix | Content |
|---------|---------------|---------|
| `data-kernel-production-4o7n` | `datakernel` | clinical_cases, sessions, users, clinicians, tenants |
| `supervision-production-8f1v` | `intervention` | peis, objectives, library_objectives, protocols, evolution_checks, evolution_check_configurations, targets, programs |
| `supervision-production-8f1v` | `assessment` | speech_therapy_registries, speech_motor_control_assessments, etc. |
| `supervision-production-8f1v` | `raw` | event source tables (objectives_events, etc.) |
| `ops-data-production-8fk2` | `aggregates` | denormalized children (churn, on_hold, owner) |
| `ops-data-production-8fk2` | `people` | source-aligned tables (children with churned_at, on_hold) |
| `guidance-data-production-l38y` | `guidance` | registries, discussions, plannings, subjects, tasks, demands |

For staging/development environments, use `bq-run.sh --env <env>`.
