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

### Federated tables (Google Sheets) — \"Permission denied while getting Drive credentials\"

Some BigQuery tables are backed by Google Sheets on Drive (external/federated data sources). Both `bq` CLI and Python `google-cloud-bigquery` will fail with:

```
Access Denied: BigQuery BigQuery: Permission denied while getting Drive credentials.
```

This happens even when `gcloud auth login` succeeds — the BigQuery OAuth scope is present, but the token lacks the **Drive scope** required to access the underlying Sheet. The query works fine in the BigQuery Console UI (which uses browser-based OAuth with full scopes), but fails from CLI/ADC.

**Fix:** The user must re-authenticate with Drive scope:

```sh
# For bq CLI
gcloud auth login --enable-gdrive-access

# For ADC / Python library
gcloud auth application-default login \
  --scopes=https://www.googleapis.com/auth/drive,https://www.googleapis.com/auth/cloud-platform
```

**Detection:** If `bq query` fails with "Permission denied while getting Drive credentials" on a table you've queried before, the table is likely federated. Check in the BigQuery Console → table details → "External data configuration" for the Drive URI.

**Workaround:** If the user can't/won't add Drive scope, ask them to run the query directly in the BigQuery Console and share results. Do NOT keep retrying from CLI — the error is deterministic.

**Dry-run still works on federated tables.** `bq query --dry_run` validates syntax successfully even for federated sources — only actual execution (data access) fails. Use `sed 's/--.*//' file.sql | bq query --dry_run` for a fast syntax check before asking the user to run in the Console.

### `normalize` is a reserved BigQuery function name

`CREATE TEMP FUNCTION normalize(...)` fails with `User-defined function name 'normalize' conflicts with a reserved built-in function name`. Use `normalize_obj` or any non-reserved name instead. This is a silent trap — the dry-run passes; only execution reveals the error.

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

**Both `library_objectives` and `protocols`** have one row per tenant. There are exactly 2 tenants (GenialCare and Care+Mindplace), so every description/protocol-name appears twice.

This causes **multiplicative row explosion** when JOINing on non-tenant-keyed columns like `description`. Example: joining `library_objectives` ON `description` without a tenant filter matches BOTH tenant rows for the same description text — each source row doubles. Two such JOINs (e.g., `to_obj` and `pei_track_obj`) multiplies by 4×.

The `library_objectives` table has **852 total rows for 426 distinct descriptions** (exactly 2×, one per tenant). Same description, different `tenant_id`, different `id`, different `protocol_item_id`.

Tenant IDs:
- `6f8da042-2dd1-4872-a613-84d371bde78c` → GenialCare
- `a4d02a8c-4c27-41b6-80ac-3401f3964e34` → Care+Mindplace

**Fix — filter by tenant_id on the library/protocol table itself.** The GenialCare tenant is the canonical choice unless the user specifies otherwise:

```sql
-- Filtering library_objectives by tenant (JOIN approach)
INNER JOIN `supervision-production-8f1v.intervention.library_objectives` lo
  ON lo.description = mapper.occupational_therapy_objective
  AND lo.discarded_at IS NULL
  AND lo.tenant_id = '6f8da042-2dd1-4872-a613-84d371bde78c'  -- GenialCare

-- Or via a pre-filtered CTE
WITH genial_library_objectives AS (
  SELECT lo.*
  FROM `supervision-production-8f1v.intervention.library_objectives` lo
  INNER JOIN `data-kernel-production-4o7n.datakernel.tenants` t ON t.id = lo.tenant_id
  WHERE t.name = "genialcare"
    AND lo.discarded_at IS NULL
)
```

Same for protocols:
```sql
INNER JOIN `supervision-production-8f1v.intervention.protocols` p
  ON p.id = pi.protocol_id
  AND p.name = 'Fonoaudiologia'
  AND p.tenant_id = '6f8da042-2dd1-4872-a613-84d371bde78c'  -- GenialCare
```

This is NOT needed when joining through `active_clinical_cases` — that CTE already scopes to a single tenant via the `tenants` table join.

### Text matching on `description` — normalize before comparing

When joining or LEFT JOIN/IS NULL on `description` text between a mapper table and `library_objectives`, `TRIM(LOWER(...))` alone misses many trivial mismatches. `library_objectives` descriptions use curly quotes (`""`), ellipsis (`...`), and trailing periods that mapper text often lacks. Apply normalization (strip `[.,;]`, replace `...`, normalize `\u201c`/`\u201d` → `"`, collapse whitespace) to both sides. See `references/mapper-missing-objectives.md` for the full regex chain and mismatch categories.

**Accent caveat:** the normalization UDF preserves Unicode accents (`LOWER()` doesn't strip them). When providing library text for copy-paste into a mapper, always include the exact accents from the library — the user may paste without accents ("posicao"), which won't match the accented library version ("posição").

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

### BigQuery auth fallback — ADC when `bq` CLI is expired

When `bq query` fails with `Reauthentication failed. cannot prompt during non-interactive execution`, user credentials are stale. Application Default Credentials (ADC) often still work even when the `bq` CLI doesn't.

**Preferred: `google-cloud-bigquery` Python library** — runs actual queries with full results (not just dry-run). Install once, then use as a `bq` replacement:

```sh
python3 -m pip install --quiet google-cloud-bigquery
```

```python
from google.cloud import bigquery

client = bigquery.Client(project="supervision-production-8f1v")
sql = open("queries/assessment/copm.sql").read()
rows = list(client.query(sql))
for row in rows:
    print(dict(row))
```

The Python library uses ADC automatically (`~/.config/gcloud/legacy_credentials/<account>/adc.json`). It can also inspect schemas:

```python
tbl = client.get_table("supervision-production-8f1v.assessment.copm_forms")
for f in tbl.schema:
    print(f"  {f.name}  {f.field_type}")
```

And list datasets/tables:
```python
for ds in client.list_datasets(project="data-kernel-production-4o7n"):
    print(ds.dataset_id)
```

**Alternative: REST API via `curl`** — for dry-run validation only (no results):

```sh
TOKEN=$(gcloud auth application-default print-access-token)
curl -s -X POST "https://bigquery.googleapis.com/bigquery/v2/projects/supervision-production-8f1v/queries" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -Rs '{query: ., dryRun: true, useLegacySql: false}' queries/og/some-query.sql)" \
  | jq '.'
```

**Key takeaway:** prefer the Python library — it gets real results, not just dry-runs. Reserve `curl` for environments where you can't install packages.

### Inferring required vs optional fields per sub-type via NULL fill rates

When a table has logical sub-types (e.g. `configuration_type` on a related
record, not an ActiveRecord STI `type` column), all columns are nullable in
schema.rb. To determine which fields are actually required/optional per
sub-type in production, query the NULL fill rate grouped by the discriminator:

```sql
SELECT
  IFNULL(ecc.configuration_type, "without_config") AS config_type,
  oec.was_assessed,
  COUNT(*) AS total,
  SUM(CASE WHEN oec.evolution_scale IS NOT NULL THEN 1 ELSE 0 END) AS evolution_scale,
  SUM(CASE WHEN oec.prerequisites IS NOT NULL AND ARRAY_LENGTH(oec.prerequisites) > 0 THEN 1 ELSE 0 END) AS prerequisites,
  SUM(CASE WHEN oec.pros IS NOT NULL AND oec.pros != "" THEN 1 ELSE 0 END) AS pros
  -- ... repeat for each attribute
FROM `supervision-production-8f1v.intervention.objective_evolution_checks` oec
LEFT JOIN `supervision-production-8f1v.intervention.evolution_check_configurations` ecc
  ON oec.configuration_id = ecc.id
GROUP BY config_type, oec.was_assessed
ORDER BY config_type, oec.was_assessed
```

When `has_col` == `total` (100%) for a type+assessed combination, the field is
de-facto required. When it's 0%, the field is never used for that type. This
complements reading the Dry::Validation contracts in the core — use BQ to
verify what actually happens in production, not just what the code enforces.

### Pivoting rows into columns — conditional aggregation with SUM(IF)

When the user wants category/count data pivoted into columns (e.g. "document count per type, one column per type"), use conditional aggregation instead of BigQuery's `PIVOT` clause or dynamic SQL:

```sql
SELECT
  acc.number,
  acc.name,
  COALESCE(SUM(IF(d.document_type = 'medical_report', 1, 0)), 0) AS medical_report,
  COALESCE(SUM(IF(d.document_type = 'contract', 1, 0)), 0) AS contract,
  COUNT(d.document_type) AS total_documents
FROM active_clinical_cases acc
LEFT JOIN docs d ON d.clinical_case_id = acc.id
GROUP BY acc.number, acc.name
ORDER BY acc.number
```

Key points:
- `SUM(IF(category = 'value', 1, 0))` turns rows into columns — one expression per distinct value.
- Wrap with `COALESCE(..., 0)` so cases with zero of a type show `0` instead of `NULL` (important when using LEFT JOIN).
- Use `LEFT JOIN` so cases with zero documents still appear.
- Add a `COUNT(...)` or `SUM(...)` total column for quick verification.
- Discover the distinct values beforehand: `SELECT category_col, COUNT(*) FROM ... GROUP BY category_col ORDER BY 2 DESC`.
- This approach is verbose when there are many distinct values (16+ columns), but it's explicit, readable, and works in all BigQuery contexts. For truly dynamic pivot needs, consider `EXECUTE IMMEDIATE` with a generated query string.

See `queries/documents/documents-by-clinical-case.sql` for a working example.

### bq-run.sh flag syntax — space-separated, not `=` syntax

`bq-run.sh` uses a manual argument parser that does NOT accept `--flag=value` syntax. Always use space-separated flags:

```sh
# WRONG — "Flag desconhecida: --format=prettyjson"
./bq-run.sh --env=staging --format=prettyjson queries/foo.sql

# CORRECT — space-separated
./bq-run.sh --env staging --format prettyjson queries/foo.sql
```

This applies to `--env` and `--format` alike.

### `bq query` CLI treats `--` in SQL comments as command-line flags

The `bq query` command parses its arguments before passing the query string to BigQuery. SQL line comments (`--`) in the query text are interpreted as `bq` flag markers, causing `FATAL Flags parsing error: Unknown command line flag '...'`. This happens both with inline `bq query 'SELECT ...'` and with `$(cat file.sql)`.

**Fix — strip comments before passing to `bq`:**

```sh
# Dry-run validation with comment stripping
sed 's/--.*//' queries/pei/my-query.sql | bq query --use_legacy_sql=false --dry_run

# Full execution (into a temp file, then pipe)
sed 's/--.*//' queries/pei/my-query.sql > /tmp/query_no_comments.sql
bq query --use_legacy_sql=false --format=prettyjson < /tmp/query_no_comments.sql
```

Alternatively, use `< file.sql` instead of `$(cat file.sql)` — but `--` in the file still triggers the parser. The `sed` strip is the reliable approach.

This does NOT apply to the Python library (`google-cloud-bigquery`), which sends the raw SQL string directly.

### `agreement_id` is a dead-end FK in BigQuery

Some assessment tables (e.g. `copm_forms`) have an `agreement_id` column that references the Rails `Agreement` model. **There is no `agreements` table in any GenialCare GCP project.** The UUID does not match `clinical_cases.id`, `clinical_case_disciplines.id`, or any other known table. To link assessment data back to a clinical case, use indirect paths: `tenant_id` + `submitted_by_id` → `users`, or time-window correlation with sessions. See `references/assessment-schema.md` for the COPM example.

## Schema references

- `references/intervention-schema.md` — intervention dataset tables (objectives, evolution checks, etc.)
- `references/assessment-schema.md` — assessment dataset tables (COPM hierarchy, vineland, OT direct assessment, etc.)
- `references/mapper-missing-objectives.md` — pattern for finding descriptions in N×N mappers that don't match `library_objectives`

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
