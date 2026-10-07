---
name: metabase-dashboard
description: "Build Metabase dashboards via REST API. Build pitfalls: references/dashboard-build-pitfalls.md"
---

# Metabase Dashboard Creation via REST API

Create dashboards programmatically using the Metabase REST API (`x-api-key` header). The user maintains multiple clinical dashboards (PEI Aderente Psico/TO) and expects a specific architecture.

Read-only cross-checking ("ver no Metabase") é pela MCP do Metabase (`mcp__metabase__*`), que tem topologia de databases própria (db 4 vs db 18 com UUIDs diferentes), é mono-tabela (sem JOINs) e não executa card nativa — ver `references/metabase-mcp-access.md`.

## Replicating logic changes across tenant copies

The PEI Aderente dashboards exist as per-tenant copies (Genial 296 / MindPlace 300) that were assumed to differ only in DB connection. ⚠️ Verify this: the RAW cards may be byte-identical AND multi-tenant (no `tenant_id` filter) — see `references/tenant-leak-in-native-cards.md` — in which case the tenant scoping is missing entirely and every copy leaks all tenants. When you change business logic in the RAW model, replicate the IDENTICAL change to every tenant's copy. The `is_pair_adherent` CASE is the single point: it drives both the case-level `aderencia_status` and the per-objective flag, so edit once per tenant (extra `WHEN` clauses inserted before the mapper fallback).

Workflow: (1) change Genial first and verify end-to-end, (2) GET the other tenant's model and confirm the "before" CASE block is byte-identical, (3) apply the same string replacement and PUT `{"dataset_query": dq}` back, (4) invalidate that tenant's derived cards, (5) verify via `/api/dataset` with a `{{#card_id}}` card tag + that tenant's `database` id. Card/table/db-id map + full verification query: `references/tenant-logic-replication.md`.

## Architecture: Single RAW Source (MANDATORY)

The user's #1 requirement: **one Native SQL card (RAW) feeds all other questions via MBQL `source-card`**. Never duplicate SQL across questions — if the logic changes, update only the RAW.

### Structure

```
RAW Card (Native SQL, type=native)
  ↓ source-card reference
Derived Card 1 (MBQL, query_type=query) — e.g. table grouped by case
Derived Card 2 (MBQL, query_type=query) — e.g. bar chart grouped by OG
Derived Card 3 (MBQL, query_type=query) — e.g. bar chart grouped by unit
```

### Creating a RAW Card (Native SQL)

```python
payload = {
    "name": "Dashboard Name - RAW",
    "display": "table",
    "collection_id": COLLECTION_ID,
    "query_type": "native",
    "database_id": DATABASE_ID,
    "dataset_query": {
        "type": "native",
        "native": {
            "query": sql_string,
            "template-tags": template_tags
        },
        "database": DATABASE_ID
    },
    "visualization_settings": {
        "table.columns": [...],
        "column_settings": {
            '["name","column_name"]': {"column_title": "Título em Português"}
        }
    }
}
# POST /api/card
```

### Creating MBQL Derived Cards (referencing RAW)

```python
import uuid

payload = {
    "name": "Dashboard Name - Por Dimensão",
    "display": "bar",
    "collection_id": COLLECTION_ID,
    "query_type": "query",       # NOT "native"
    "database_id": DATABASE_ID,
    "dataset_query": {
        "lib/type": "mbql/query",
        "database": DATABASE_ID,
        "stages": [{
            "lib/type": "mbql.stage/mbql",
            "source-card": RAW_CARD_ID,
            "aggregation": [["count", {"lib/uuid": str(uuid.uuid4())}]],
            "breakout": [
                ["field", {"base-type": "type/Text", "lib/uuid": str(uuid.uuid4())}, "column_name"],
            ],
            # DO NOT include "filters": [] — empty array causes validation error
            "limit": 10000
        }]
    }
}
```

### Adding aderencia_status to the RAW

If the RAW has fan-out (multiple rows per case), add a case-level `aderencia_status` column via a `case_adherence` CTE in the outer query:

```sql
WITH raw_data AS (
  <original SQL with all columns>
),
case_adherence AS (
  SELECT clinical_case_number,
    CASE
      WHEN MAX(has_active_to_objectives) IS NOT TRUE THEN 'Sem objetivos ativos de TO'
      WHEN LOGICAL_AND(COALESCE(objective_adherent, FALSE)) THEN 'Aderente'
      ELSE 'Não Aderente'
    END AS aderencia_status
  FROM (
    SELECT clinical_case_number, to_objective_id,
      MAX(has_active_to_objectives) AS has_active_to_objectives,
      CASE
        WHEN to_objective_id IS NULL THEN NULL
        WHEN MAX(is_pair_adherent) IS NULL THEN FALSE
        ELSE MAX(is_pair_adherent)
      END AS objective_adherent
    FROM raw_data
    GROUP BY clinical_case_number, to_objective_id
  )
  GROUP BY clinical_case_number
)
SELECT r.*, ca.aderencia_status
FROM raw_data r
LEFT JOIN case_adherence ca ON ca.clinical_case_number = r.clinical_case_number
WHERE 1=1
  [[AND r.clinical_case_number = {{caso}}]]
```

## Changing Adherence Rules: Fix at `is_pair_adherent`, Not `objective_adherent`

The "PEIs Aderentes TO" dashboard computes adherence as a 3-level cascade inside the RAW model
(8137), and WHERE you edit it matters:

- `is_pair_adherent` (row level, in `raw_data`) — one row per (objective × mapper pair × PEI track
  item). This column is BOTH (a) exposed in the RAW output and consumed directly by the "Objetivos
  TO" derived card (8159) via `max(is_pair_adherent)` as the per-objective "Aderente?" flag, AND
  (b) rolled up into `objective_adherent` via `MAX(is_pair_adherent)`.
- `objective_adherent` (objective level, `case_adherence` inner subquery) — `MAX(is_pair_adherent)`.
- `aderencia_status` / `is_case_adherent` (case level, `case_adherence`) — `LOGICAL_AND` of all objectives.

So when the user asks "change which objectives count as adherent" (e.g. "protocol X is always
adherent", "protocol Y is adherent if its status = Z"), apply the override in the `is_pair_adherent`
CASE in `raw_data` — NOT in `objective_adherent`. The protocol/status columns (`to_protocol_name`,
`to_objective_status`) are already in `raw_data`, so the override sits naturally right after the
placeholder NULL check and before the mapper-pair check:

```sql
  CASE
    WHEN ato.objective_id IS NULL THEN NULL                 -- placeholder row
    WHEN ato.protocol_name = 'Ocupacional' THEN TRUE        -- always adherent
    WHEN ato.protocol_name = 'Integração Sensorial'
         AND ato.objective_status = 'in_maintenance' THEN TRUE
    WHEN mapper.main_objective_id IS NULL THEN FALSE        -- no mapper pair
    ELSE COALESCE(pti.module_progress_item_status IN ('validated','in_maintenance'), FALSE)
  END AS is_pair_adherent
```

If you fix only `objective_adherent`, the case-level status flips but the "Objetivos TO" card keeps
showing the old per-objective flag — a visible inconsistency the user will flag. Fixing
`is_pair_adherent` keeps both consistent in one edit (same single-RAW principle: the override
belongs at the lowest exposed level so every derived card inherits it). Note the objective's OWN
status (`objective_status`, the `objectives` table enum) is distinct from the PEI-track item's
status (`module_progress_item_status`) — "status in_maintenance" in a rule about the objective
refers to `objective_status`.

## Before/After Analysis of a Single Case (don't query the model)

To show "what did case N look like before vs after a rule change", do NOT query the model — it has
no filter template-tags and returns all ~200k rows (display capped at ~2000). Instead run a
targeted `POST /api/dataset` native query against the same database that replicates the RAW's
objective-level logic filtered to that one case:

```sql
... WHERE pei.clinical_case_id = (SELECT id FROM `...datakernel.clinical_cases` WHERE number = {{N}} LIMIT 1)
```

Group by objective and use
`MAX(CASE WHEN mapper.main_objective_id IS NULL THEN FALSE ELSE COALESCE(pti.status IN ('validated','in_maintenance'), FALSE) END)`
to reproduce the exact `is_pair_adherent` computation, so the "before" numbers match the RAW
byte-for-byte. Re-run the same query after the edit and diff per-objective — this is how you give
the user a grounded before/after ("3 objetivos Integração Sensorial in_maintenance + 1 Ocupacional,
todos antes não-aderentes → depois todos aderentes → caso flips Não Aderente → Aderente").

## Pitfalls (Hard-Won)

1. **Window functions can't reference SELECT aliases** at the same query level. Use CTE subqueries, not `OVER (PARTITION BY)` in the same SELECT.
2. **Python f-strings eat `{{ }}`**. Use string concatenation or `.replace()` for Metabase template tags.
3. **Template tag type `"string"` is invalid** in Metabase v0.60. Use `"text"`.
4. **Parameter target for simple tags is `["variable", ...]`**, not `["dimension", ...]`.
5. **Empty `"filters": []` on MBQL stages** causes validation error. Omit the key entirely.
6. **Dashcard IDs must be unique negatives**: -1, -2, -3 (not all -1).
7. **`database_id` at card level** is required for MBQL cards, not just inside `dataset_query`.
8. **BigQuery aliases not visible in WHERE** at same query level. Use original column names.
9. **CTEs must be defined BEFORE use** — BigQuery requires forward declaration.
10. **Metabase caches card query results** — use `/api/dataset` for fresh runs, check `cached` field.
11. **RAW with `[[ ]]` template-tags CANNOT be converted to type="model"** — Metabase error: "Um modelo feito a partir de uma pergunta SQL nativa não pode ter um filtro de variável ou campo." To use the RAW as a model (enabling MBQL pushdown), strip all `[[ ]]` clauses and template-tags from the SQL. Filters should be applied on the MBQL derived cards via dashboard `parameter_mappings` with `["dimension", ["field", col_name, {base-type}], {stage-number: 0}]` targets — NOT on the RAW itself.
12. **MBQL cards with `source-card` CANNOT be filtered via `/api/card/:id/query` endpoint** — the filter is silently ignored (returns 0 rows or all rows). Filters ONLY work via the **dashboard endpoint**: `POST /api/dashboard/:dash_id/dashcard/:dashcard_id/card/:card_id/query` with `{"parameters": [{"id": "caso", "value": "537", "type": "number/="}]}`. The dashboard's `parameter_mappings` route the filter to the correct field. This is the #1 reason why "the filter doesn't work" on MBQL derived cards.
13. **MBQL pushdown requires the RAW to be a model (type="model")** — when the RAW is a plain question (type="question"), MBQL aggregations operate on the first N rows returned by the source card (capped at `max-results-bare-rows: 2000`), not the full result set. Converting to model enables Metabase to push the aggregation into the source SQL, processing all rows. Without pushdown, MBQL cards that need to see all cases (e.g. summary with 736 rows) will only see the first ~8 cases.
14. **MBQL breakout fan-out hits the 10000 row limit** — if the breakout fields create too many unique combinations (e.g. breaking out by `to_objective_description` + `pei_track_objective_description` when the mapper creates N:M fan-out), the MBQL result is capped at 10000 rows and only covers a subset of cases. Fix: reduce the breakout to fewer fields (e.g. just `clinical_case_number` + `to_objective_description`) and use aggregation (`max`, `count`) for the rest.
15. **Two filter formats for two card types**: Native SQL cards use `["variable", ["template-tag", "tag_name"]]` as the parameter_mapping target. MBQL cards (query_type="query" with source-card) use `["dimension", ["field", "col_name", {"base-type": "type/..."}], {"stage-number": 0}]` as the target. Using the wrong format silently breaks filtering.
16. **`required: true` template-tag with no `default` breaks the card the moment the dashboard loads with that filter empty** — shows "There was a problem displaying this chart" to the end user (confirmed root cause on the "Sugestões de Objetivos" card, dash 296 PEIs Aderentes TO, when opened via a URL with `?caso=` blank). This affects any Native SQL card whose only required tag is a dashboard filter the user hasn't set yet. Fixing it takes TWO steps, not one — a bare `default` just swaps the error for wrong/noisy data:
    1. Give the tag a sentinel `default` (e.g. `"default": "-1"` for a numeric ID tag) so Metabase can always substitute a value.
    2. Add a guard clause early in the SQL using that sentinel (e.g. `WHERE {{caso}} > 0 AND ...`) so the sentinel naturally yields zero rows (clean empty state) instead of an unfiltered/garbage result — e.g. a `NOT IN (SELECT ... WHERE x = -1)` subquery with no guard can silently return every row in the table the instant no case is selected.
    Verify by testing all three states via the dashboard endpoint — no `parameters` at all, the sentinel/empty state, and a real filter value — and confirm the row counts differ correctly, not just that no error is thrown.

## Template Tags (Dashboard Filters)

### Type Mapping

| Tag Purpose | tag `type` | Dashboard param `type` |
|---|---|---|
| Number | `"number"` | `"number/="` |
| Text | `"text"` | `"string/="` |
| Boolean | `"boolean"` | `"boolean/="` |

### Optional Filters with `[[ ]]`

```
[[AND column_name = {{tag_name}}]]
```

Column name must be the actual column name (not a SELECT alias).

### Running Cards with Filters

```json
{"type": "number/=", "target": ["variable", ["template-tag", "caso"]], "value": 537}
```

## Dashboard Assembly

### Full-width

```python
payload = {"width": "full"}  # PUT /api/dashboard/{id}
```

### Text Cards (Markdown) — REQUIRES `virtual_card`, not just `text`

**Critical, easy to get wrong silently:** a text/heading dashcard is NOT recognized by the
Metabase frontend just because `visualization_settings.text` is set. It ALSO requires
`visualization_settings.virtual_card` — an object that tells the UI "this is a virtual
(non-query) card of display type text", not a real question. Without it, `POST`/`PUT`
succeeds with no error, a subsequent `GET` on the dashboard echoes the `text` back
correctly (so re-reading the API makes it LOOK like everything is fine), but the card
renders **completely empty** in the actual dashboard UI. This is the #1 cause of "why is
my text card blank" — confirmed against Metabase's own source
(`frontend/src/metabase/common/utils/dashboard.ts`, function `createVirtualCard`):

```python
VIRTUAL_CARD = {"name": None, "display": "text", "visualization_settings": {}, "archived": False}

{
    "id": -1, "card_id": None, "size_x": 24, "size_y": 3,
    "visualization_settings": {
        "text": "## Título\n\nExplicação em português...",
        "virtual_card": VIRTUAL_CARD,   # <-- MANDATORY, do not omit
    },
    "parameter_mappings": []
}
```

**Verification is NOT optional and must go beyond `GET` + text match.** Because the API
echoes `text` back regardless of whether `virtual_card` is present, the only ways to catch
this bug are: (a) check `"virtual_card" in dashcard["visualization_settings"]` explicitly
in your own script after every text-card write, not just that `text` round-tripped: or
(b) actually look at the rendered dashboard (browser/computer_use screenshot) before
telling the user text cards were added. A user hit this exact bug repeatedly across
multiple dashboards before it was root-caused — text cards had silently been rendering
empty the whole time despite the API always reporting success.

**Also watch `size_y` on short text cards** (e.g. section subtitles): `size_y: 1` can be
too short to render a heading at all even WITH `virtual_card` present — use `size_y: 2`
minimum for a `###` subtitle line, more for multi-line text/markdown.

### Two virtual_card display types: "text" vs "heading"

`virtual_card.display` has (at least) two variants, confirmed by inspecting a live
reference dashboard (296):

- `"text"` — free-form markdown paragraph, left-aligned by default. Use for explanatory
  copy, instructions, multi-line content. Add `"text.align_vertical": "middle"` in
  `visualization_settings` (sibling of `text`, not inside `virtual_card`) to vertically
  center short text inside a taller card — confirmed working value is `"middle"` (also
  `"text.align_horizontal": "left"/"center"/"right"` is available).
- `"heading"` — dedicated section-title type, renders like an `<h2>`/`<h3>`, no markdown
  prefix needed (don't prepend `###` — pass the plain title text). This is what a
  reference dashboard actually uses for section separators between groups of cards (e.g.
  "Sugestões", "Objetivos do Caso") — prefer this over a generic "text" card with a `###`
  prefix when the ask is "add a section title/divider" rather than "add explanatory copy".

```python
# Section heading (preferred for dividers)
HEADING_VCARD = {"name": None, "display": "heading", "visualization_settings": {}, "archived": False}
{"id": -1, "card_id": None, "row": 10, "size_x": 24, "size_y": 2,
 "visualization_settings": {"text": "Comunicação Expressiva", "virtual_card": HEADING_VCARD}}

# Explanatory paragraph, vertically centered
TEXT_VCARD = {"name": None, "display": "text", "visualization_settings": {}, "archived": False}
{"id": -2, "card_id": None, "row": 0, "size_x": 24, "size_y": 2,
 "visualization_settings": {
     "text": "Clique numa barra para filtrar...",
     "virtual_card": TEXT_VCARD,
     "text.align_vertical": "middle",
 }}
```

### Crossfilter (Click-behavior Drill-down)

```python
dashcard["visualization_settings"]["click_behavior"] = {
    "type": "crossfilter",
    "parameterMapping": {
        "param_id": {
            "source": {"type": "column", "id": "column_name", "name": "column_name"},
            "target": {"type": "parameter", "id": "param_id"},
            "id": "param_id"
        }
    }
}
```

### Parameter Mappings

```python
{"parameter_id": "og_to", "card_id": CARD_ID, "target": ["variable", ["template-tag", "og_to"]]}
```

## Colors (GenialCare Psico Palette)

| Status | Color | Hex |
|---|---|---|
| Aderente | Green | `#88BF4D` |
| Não Aderente | Red | `#E75454` |
| Talvez / Sem objetivos | Yellow | `#F9D45C` |

## Column Display Names (Portuguese)

```python
'["name","clinical_case_number"]': {"column_title": "Caso"}
'["name","og_to_name"]': {"column_title": "OG TO"}
'["name","location_name"]': {"column_title": "Unidade"}
```

## Troubleshooting: Count Discrepancies

1. **Stale cache**: Force fresh run via `/api/dataset`. Check `cached` field.
2. **Implicit INNER JOIN**: `LEFT JOIN ... WHERE ch.col IS NULL` excludes unmatched rows.
3. **Service account tenant scope**: Metabase BQ connection may only see `genialcare` tenant.
4. **Fan-out duplication**: Use `ANY_VALUE()` and `GROUP BY clinical_case_number` only.

## Layout Pattern (top-down)

```
Row 0-2:   Text card (introduction in Portuguese)
Row 3-8:   Bar chart Por OG TO (12 cols) | Bar chart Por Unidade (12 cols)
Row 9-10:  Text card ("Resumo por Caso" explanation)
Row 11-18: Table - Resumo por Caso (24 cols, crossfilter -> caso)
Row 19-20: Text card ("Objetivos do Caso" explanation)
Row 21-28: Table - Objetivos do Caso (24 cols, MBQL source-card, filtered by caso)
Row 29-30: Text card ("Detalhes" explanation)
Row 31-40: Table - RAW detalhado (24 cols, filtered by caso/og_to/unidade)
```

### Intermediary table pattern (Objetivos do Caso)

Between the case-level summary and the full RAW, add an MBQL card that shows one row per (case × TO objective) with `max(is_pair_adherent)` as the "Aderente?" column. This gives users an easy-to-consume view of which objectives are adherent without the full fan-out of the RAW.

- Breakout: `clinical_case_number` + `to_objective_description` (keep tight to avoid 10000 row limit)
- Aggregation: `count` (number of PEI Track items per objective) + `max(is_pair_adherent)` (whether any item is active)
- Filtered by the same dashboard parameters (caso, og_to, unidade)
- The `count` column is hidden from display; the `max` column is shown as "Aderente?"

### Additional status values

Beyond "Aderente" / "Não Aderente" / "Sem objetivos ativos de TO", the user may request more nuanced statuses. Example: "Sem PEI" for cases where NO objective has a mapper pair (the PEI Track doesn't cover these TO objectives). Add to the `case_adherence` CTE:

```sql
WHEN MAX(has_mapper_pair) = FALSE THEN 'Sem PEI'
```

Where `has_mapper_pair = MAX(pei_track_library_objective_id IS NOT NULL)` per objective.

**CRITICAL follow-up — a new status does NOT auto-propagate to count-where bar charts.** The
"Por OG TO" / "Por CG" bar charts enumerate a FIXED set of `count-where` series (`aderente`,
`nao_aderente`, `sem_objetivos`); adding a branch to the `case_adherence` CTE does not add a
series to those charts. Native SQL cards that `GROUP BY aderencia_status` (the pie) pick the new
value up automatically; count-where cards do NOT. Consequences, confirmed on a MindPlace tenant
copy whose mapper was empty (10/24 cases = "Sem PEI"):
- The new status's cases are **invisible** in the bar charts (silently dropped from totals).
- Filtering the bar chart to the missing status (e.g. crossfilter from the pie's "Sem PEI" slice
  → `status_aderencia = "Sem PEI"`) makes every `count-where` series evaluate to 0, so Metabase
  renders **"No results!"** — while clicking into the card (which drops the dashboard filter)
  shows rows. **"No results! on dashboard, results on click" is the signature of a missing
  count-where series, NOT a broken join or a copy bug.** Confirm via the dashboard endpoint:
  `status_aderencia = '<missing status>'` returns all-zero rows today.

Fix: add a matching `count-where` aggregation plus `series_settings`/`series_order`/`graph.metrics`
entry for the new status to every affected bar chart (see the count-where section), using the same
color as its `table.column_formatting` entry.

**Domain note:** the mapper `pei_track_to_occupational_therapy_objectives` has a `tenant_id`
column and is per-tenant (genial ~7000 rows; a fresh/unconfigured tenant 0 rows). "Sem PEI" is
therefore a TENANT-SPECIFIC status — ~0 for one tenant and the majority status for another with an
empty mapper. When a tenant's charts look "empty" / "all Sem PEI / Sem Objetivos", check the mapper
row count for that tenant FIRST — it's usually a data gap (mapper never configured), not a query bug.

**The mapper is a GENERATED table, not manually populated.** It is rebuilt by a manual SQL pipeline
in `../code-snippets/queries/occupational-therapy-mapper/` (NOT Dataform):
`external-table.sql` creates the `_raw` external table (backed by a Google Sheet of human-readable
de-para descriptions — GLOBAL, no `tenant_id`), then `mapper-objective-pairs.sql` runs a
`CREATE OR REPLACE TABLE` that normalizes the `_raw` text against `library_objectives` and emits one
row PER TENANT (filter `t.name IN ('genialcare','careplus_mindplace')`, cross-tenant pairs blocked by
`pei_track_obj.tenant_id = to_obj.tenant_id`). So a tenant with 0 mapper rows means the script was
updated to multi-tenant but never re-run for that tenant — the fix is RE-RUNNING
`mapper-objective-pairs.sql`, which needs BigQuery WRITE access (`bq` CLI / console / the user's GCP
account), NOT the read-only Metabase API key. A user "populating the mapper" manually is the wrong
move — the table is fully regenerated from the sheet, so manual inserts get overwritten. Confirm the
gap first before any fix:
`SELECT tenant_id, COUNT(*) FROM ...pei_track_to_occupational_therapy_objectives GROUP BY tenant_id`
via each connection — mindplace = 0 rows while genial = ~7000 confirms the pipeline simply hasn't
been run for that tenant. (Also: `_raw` is only readable by the genial service account — the
mindplace one gets 403 "Permission denied while getting Drive credentials" — another reason to run
the pipeline with the user's own GCP account, not a Metabase service account.)

**Side effect to flag: the `CREATE OR REPLACE TABLE` DROPS the mapper's row access policy (RLS).**
RLS on the mapper (and every `supervision` table with a `tenant_id` column) is applied by a SEPARATE
Dataform job — `projects/supervision/definitions/jobs/apply_rls.sqlx` (tag `rls`) — that iterates
`INFORMATION_SCHEMA` and creates `filter_genial` / `filter_mindplace` / `filter_admin` row access
policies per tenant. Running `mapper-objective-pairs.sql` by hand recreates the table WITHOUT those
policies, so afterward BOTH service accounts see BOTH tenants' mapper rows (~14000 instead of ~7000
each). This does NOT break the dashboard — `library_objective` IDs are tenant-unique, so the UUID
join still matches only within-tenant — but it IS an isolation/security gap. Recommend re-running
`dataform run --tags rls` (or the team's equivalent) after any manual `CREATE OR REPLACE TABLE` on a
`tenant_id`-bearing supervision table. Detect it by `GROUP BY tenant_id` on the mapper via one
connection: seeing both tenants' ids from a single (supposedly tenant-scoped) connection means RLS
is gone.

## GenialCare Domain: OG TO vs OG Psico

**OG TO** = `occupational_therapy_specialty_consultant` from `clinical_cases_clinicians`:

```sql
og_to AS (
  SELECT ccc.clinical_case_id, c.name AS og_to_name
  FROM `data-kernel-production-4o7n.datakernel.clinical_cases_clinicians` ccc
  INNER JOIN `data-kernel-production-4o7n.datakernel.clinicians` c ON c.id = ccc.clinician_id
  WHERE ccc.clinician_role = 'occupational_therapy_specialty_consultant'
  QUALIFY ROW_NUMBER() OVER(PARTITION BY ccc.clinical_case_id ORDER BY ccc.created_at DESC) = 1
)
```

**OG Psico** = `clinical_case_owner.name` from `ops-data-production-8fk2.aggregates.children` (names are lowercase).

## MBQL Filtering Architecture (Critical)

The #1 source of "filters don't work" bugs: **MBQL derived cards (source-card) and Native SQL cards use completely different filter mechanisms.**

### Native SQL cards (the RAW)
- Use `[[AND column = {{tag}}]]` in SQL + template-tags + `["variable", ["template-tag", "tag"]]` parameter_mappings
- Can be filtered via `/api/card/:id/query` with `{"parameters": [{"type": "number/=", "target": ["variable", ["template-tag", "caso"]], "value": 537}]}`
- **CANNOT be converted to type="model" if they have `[[ ]]` clauses** — strip template-tags first

### MBQL derived cards (source-card = RAW)
- Use `["dimension", ["field", "col_name", {"base-type": "type/..."}], {"stage-number": 0}]` parameter_mappings
- **CANNOT be filtered via `/api/card/:id/query`** — the filter is silently ignored
- **CAN be filtered via `/api/dashboard/:dash_id/dashcard/:dashcard_id/card/:card_id/query`** with `{"parameters": [{"id": "caso", "value": "537", "type": "number/="}]}`
- Require the RAW to be type="model" for pushdown (aggregation pushed into source SQL). Without model conversion, MBQL only sees the first ~2000 rows from the source card.

### Testing filters
Always test via the **dashboard endpoint**, not the card endpoint:
```sh
curl -s -X POST -H "x-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"parameters":[{"id":"caso","value":"537","type":"number/="}]}' \
  "$MB_URL/api/dashboard/$DASH_ID/dashcard/$DASHCARD_ID/card/$CARD_ID/query"
```

### Converting RAW to model (for pushdown)
1. Strip ALL `[[ ]]` clauses and template-tags from the RAW SQL
2. `PUT /api/card/:id` with `{"type": "model"}`
3. Filters move to the MBQL derived cards via dashboard parameter_mappings

## Chart Aggregation: Case Counts vs Row Counts (Critical)

When the RAW has fan-out (multiple rows per case due to mapper joins), a simple `count` aggregation on an MBQL card counts RAW rows, not cases. A chart showing "75" for an OG means 75 RAW rows, not 75 cases.

### Fix: 2-stage MBQL for case counts

```
Stage 1: source-card → group by (dim, status, clinical_case_number) → count
         (one row per case, collapses fan-out)
Stage 2: group by (dim, status) → count
         (counts cases per dimension × status)
```

Without stage 1, the `count` in stage 2 sums RAW rows (with fan-out) instead of counting distinct cases.

### Sorting stacked bars by a specific series (count-where pattern)

YES, you CAN sort by a specific series in Metabase v0.60. The pattern (confirmed from the Psico dashboard card 7210) uses **named `count-where` aggregations** in stage 2, with `order-by` referencing the UUID of the target aggregation.

**Stage 0**: source-card → group by (dim, status, case) → count (collapses fan-out to 1 row per case)
**Stage 1**: group by (dim) only, with multiple `count-where` aggregations:

```python
nao_aderente_uuid = str(uuid.uuid4())
aderente_uuid = str(uuid.uuid4())
sem_obj_uuid = str(uuid.uuid4())

stages[1] = {
    "lib/type": "mbql.stage/mbql",
    "aggregation": [
        # Each count-where has a name that becomes the series key
        ["count-where",
         {"lib/uuid": nao_aderente_uuid, "name": "nao_aderente", "display-name": "Não Aderente"},
         ["=", {"lib/uuid": str(uuid.uuid4())}, field_ref("aderencia_status", "type/Text"), "Não Aderente"]
        ],
        ["count-where",
         {"lib/uuid": aderente_uuid, "name": "aderente", "display-name": "Aderente"},
         ["=", {"lib/uuid": str(uuid.uuid4())}, field_ref("aderencia_status", "type/Text"), "Aderente"]
        ],
        ["count-where",
         {"lib/uuid": sem_obj_uuid, "name": "sem_objetivos", "display-name": "Sem objetivos ativos de TO"},
         ["=", {"lib/uuid": str(uuid.uuid4())}, field_ref("aderencia_status", "type/Text"), "Sem objetivos ativos de TO"]
        ],
    ],
    "breakout": [field_ref(dim_col, dim_type)],  # dim ONLY, no aderencia_status
    "order-by": [["desc", {"lib/uuid": str(uuid.uuid4())},
                  ["aggregation", {"base-type": "type/Integer", "lib/uuid": str(uuid.uuid4())},
                   nao_aderente_uuid]  # reference the UUID of the aggregation to sort by
                 ]]
}
```

**Critical viz settings for this pattern**:
- `graph.dimensions`: `[dim_col]` only (NOT `[dim_col, "aderencia_status"]` — the series come from the named metrics)
- `graph.metrics`: `["nao_aderente", "aderente", "sem_objetivos"]` (the `name` values from the aggregations)
- `series_settings` keys must match the metric names: `{"nao_aderente": {...}, "aderente": {...}, ...}`
- `series_order` keys must also match: `[{"key": "aderente", ...}, {"key": "sem_objetivos", ...}, {"key": "nao_aderente", ...}]`
- **`graph.series_order_dimension` must be ABSENT.** It is a leftover from the old (dim, status) breakout and breaks the chart when present. If `"graph.series_order_dimension": "aderencia_status"` is set, the chart builder looks for a column named `aderencia_status` that does NOT exist in the count-where result (the status was replaced by named metric columns), and renders **"No results!" even though the card returns rows** via both `/api/card/:id/query` and the dashboard endpoint — and even though clicking into the card shows the data. Confirmed root cause on the "Status por OG TO" / "Status por CG" cards (dash 296 Genial + 300 MindPlace); the Psico reference card 7210 works precisely because it lacks this field. Fix: `PUT /api/card/:id` with the field removed from `visualization_settings`. **CORRECTION (later session): this attribution is WRONG.** The working Genial cards (8156/8157) ALSO carry `graph.series_order_dimension`, so its presence does NOT break the chart — removing it from the card changed nothing. The ACTUAL root cause of "No results!" on the copied MindPlace bars was a stale dashcard `columnValuesMapping[].sourceId` (see the multi-tenant copy recipe below). This field is harmless clutter at most. Watch for it in any count-where card copied from an older chart that once used the (dim, status) breakout — a MindPlace copy will inherit the bug from its Genial source, so check the ORIGINAL card too.

**Key difference from the old (dim, status) breakout approach**: The old approach has `aderencia_status` as a second breakout dimension, which creates one row per (dim, status) and lets the chart pivot. The `count-where` approach has only `dim` in the breakout, with each status as a separate named aggregation column. The latter allows `order-by` to target a specific series.

## Intermediary Tables (User-Facing Detail Views)

### Objetivos da Jornada (PEI Track items)

MBQL card referencing the RAW, showing active PEI Track items for the selected case:
- Breakout: `clinical_case_number` + `pei_track_objective_description` + `pei_track_module_name`
- Aggregation: `max(is_pei_track_item_active)`
- **Filter: `is_pei_track_item_active = True`** — without this, the card shows 248+ inactive items per case (noise). With the filter, only ~4 active items appear.
- The fan-out from the mapper creates many rows per (case, pei_track_objective); the `max` aggregation collapses them.

### Sugestões de Objetivos (Native SQL, NOT source-card)

Shows library objectives for TO protocols that are NOT yet in the case's PEI. This data does NOT exist in the RAW (the RAW only has objectives already in the PEI). Requires a separate Native SQL card:

```sql
SELECT lobj.description AS objetivo_sugerido, p.name AS protocolo, pi.domain, pi.subdomain
FROM `supervision-production-8f1v.intervention.library_objectives` lobj
INNER JOIN protocol_items pi ON pi.id = lobj.protocol_item_id
INNER JOIN protocols p ON p.id = pi.protocol_id
WHERE p.name IN ('Ocupacional', 'Integração Sensorial')
  AND lobj.id NOT IN (
    SELECT obj.library_objective_id FROM objectives obj
    INNER JOIN peis pei ON pei.id = obj.pei_id
    WHERE pei.clinical_case_id = (SELECT id FROM clinical_cases WHERE number = {{caso}} LIMIT 1)
      AND obj.discarded_at IS NULL
  )
  AND lobj.id IN (SELECT support_objective_id FROM pei_track_to_occupational_therapy_objectives)
ORDER BY p.name, pi.domain, pi.subdomain
```

Template-tag: `caso` (type: number, required: true). Parameter mapping: `["variable", ["template-tag", "caso"]]`.

## User Preferences (GenialCare Dashboards)

- **Series colors must match metric names**: When using the `count-where` pattern (named aggregations), `series_settings` and `series_order` keys must match the aggregation `name` values (e.g. `"nao_aderente"`, not `"Não Aderente"`). Mismatched keys cause colors to break — the chart falls back to default colors. The `display-name` field on the aggregation controls what the user sees in the legend, but the internal key is the `name`.
- **Text cards**: Keep minimal. The user removed text explanation cards they found unnecessary. Don't add text cards unless the content adds real value the user can't infer.
- **Series order in stacked bars**: Aderente (bottom, green), Sem objetivos/Sem PEI (middle, yellow), Não Aderente (top, red). This is a human-feeling preference — the user wants the "bad" status most visible at the top of the stack.
- **Column visibility**: Disable internal IDs and technical columns. The user removed `tenant_name`, `owner_email`, `owner_id`, various `_id` columns. Keep only human-readable business columns.
- **Full-width**: Always set `"width": "full"` on dashboards.
- **Portuguese column titles**: All display names must be in Portuguese (e.g. "Caso", "Objetivo de TO", "Aderente?").

## Conditional Row Formatting

Highlight table rows by status using `table.column_formatting` in visualization_settings (same pattern as Psico dashboard card 7148):

```python
viz['table.column_formatting'] = [
    {"columns": ["aderencia_status"], "type": "single", "operator": "=",
     "value": "Aderente", "color": "#88BF4D", "highlight_row": True},
    {"columns": ["aderencia_status"], "type": "single", "operator": "=",
     "value": "Não Aderente", "color": "#EF8C8C", "highlight_row": True},
    {"columns": ["aderencia_status"], "type": "single", "operator": "=",
     "value": "Sem objetivos ativos de TO", "color": "#F9D45C", "highlight_row": True},
    {"columns": ["aderencia_status"], "type": "single", "operator": "=",
     "value": "Sem PEI", "color": "#8857BF", "highlight_row": True},
]
```

`highlight_row: true` colors the entire row, not just the status cell.

## Crossfilter Between Intermediary Tables (Drill-down Chain)

The dashboard supports multi-level drill-down: clicking a row in one table filters the next table below.

### Pattern: Jornada → Sugestões

When the user clicks a PEI Track objective in the "Objetivos da Jornada" table, the "Sugestões de Objetivos" table filters to show only TO objectives related to that PEI Track item (via the mapper).

**Requirements**:
1. The Jornada card must include `pei_track_library_objective_id` in its breakout (can be hidden from display via `table.columns` with `enabled: False`)
2. A dashboard parameter `objetivo_jornada` (type `string/=`)
3. The Sugestões Native SQL card has an optional `[[AND lobj.id IN (SELECT support_objective_id FROM mapper WHERE main_objective_id = {{objetivo_jornada}})]]` clause — **but if the goal is "the table must show NOTHING until the user has clicked a Jornada item" (not just optionally narrow an already-populated table), the optional `[[ ]]` clause is the wrong tool: without a click, it's simply omitted and the table falls back to showing an unfiltered dump of every eligible objective across all cases.** Use the sentinel-default + mandatory-clause pattern from "Gating a Card on a Required Selection" above instead: make `objetivo_jornada` `required: true` with a default sentinel (e.g. a nil UUID `"00000000-0000-0000-0000-000000000000"`), and change the SQL to an unconditional `AND lobj.id IN (SELECT support_objective_id FROM mapper WHERE main_objective_id = {{objetivo_jornada}})` — the sentinel then naturally matches zero rows until a real click sets it. This can be chained with the `caso` gate (also required+sentinel) so the table needs BOTH selections before showing anything — each gate is independent and additive (`AND` clauses), so verify all 2^n combinations via the dashboard query endpoint (nothing selected / only caso / only objetivo_jornada / both) rather than assuming the second gate composes correctly with the first.
4. Click behavior on the Jornada dashcard:
```python
dc['visualization_settings']['click_behavior'] = {
    "type": "crossfilter",
    "parameterMapping": {
        "objetivo_jornada": {
            "source": {"type": "column", "id": "pei_track_library_objective_id", "name": "pei_track_library_objective_id"},
            "target": {"type": "parameter", "id": "objetivo_jornada"},
            "id": "objetivo_jornada"
        }
    }
}
```
5. Parameter mapping on the Sugestões dashcard:
```python
{"parameter_id": "objetivo_jornada", "card_id": SUG_CARD_ID,
 "target": ["variable", ["template-tag", "objetivo_jornada"]]}
```

**Full drill-down chain**: Resumo por Caso (click case) → Objetivos do Caso + Objetivos da Jornada + Sugestões (all filtered by case) → Objetivos da Jornada (click item) → Sugestões (further filtered by PEI Track objective via mapper).

## Adding KPI / Big Number Cards Referencing the RAW (Native SQL via `{{#card_id}}`)

To add scalar KPI cards (totals, percentages) without duplicating RAW logic, use a Native SQL
card whose FROM clause is a **card template tag** pointing at the RAW (or any existing card) —
this is a third valid pattern alongside RAW/MBQL-derived, for when you want a single scalar
aggregate (not a breakout table/chart) that should still respect the same optional dashboard
filters (og_to, unidade, etc.) as the rest of the dashboard:

```python
tag_name = "#8137"  # "#" + RAW card id
sql = f"SELECT ROUND(100.0 * COUNT(DISTINCT CASE WHEN aderencia_status = 'Aderente' THEN clinical_case_number END) " \
      f"/ NULLIF(COUNT(DISTINCT clinical_case_number), 0), 1) AS pct_aderente FROM {{{{{tag_name}}}}} " \
      f"WHERE 1=1 [[AND og_to_name = {{{{og_to}}}}]] [[AND location_name = {{{{unidade}}}}]]"

template_tags = {
    tag_name: {"id": str(uuid.uuid4()), "name": tag_name, "display-name": tag_name,
               "type": "card", "card-id": RAW_CARD_ID},
    "og_to": {"id": str(uuid.uuid4()), "name": "og_to", "display-name": "OG TO", "type": "text", "required": False},
    "unidade": {"id": str(uuid.uuid4()), "name": "unidade", "display-name": "Unidade", "type": "text", "required": False},
}
payload = {
    "name": "Dashboard - KPI % Aderente", "display": "scalar", "collection_id": COLLECTION_ID,
    "query_type": "native", "database_id": DATABASE_ID,
    "dataset_query": {"type": "native", "native": {"query": sql, "template-tags": template_tags}, "database": DATABASE_ID},
    "visualization_settings": {"column_settings": {'["name","pct_aderente"]': {"number_style": "decimal", "decimals": 1, "suffix": "%"}}}
}
# POST /api/card
```

Give each KPI card `parameter_mappings` of type `["variable", ["template-tag", "og_to"]]` on the
dashboard (same as any Native SQL card — see "Two filter formats" pitfall above). Validate the
SQL first via `POST /api/dataset` before creating the card, and sanity-check the number against
an independent count from `/api/card/:id/query` on the base data before trusting it.

### Design choice: separate KPI scalars vs. one pie/donut

If 3+ of the KPI numbers are mutually-exclusive categories that sum to a meaningful whole (e.g.
Aderente / Não Aderente / Sem Objetivos, which together are 100% of cases), prefer ONE pie/donut
card over N separate scalar cards. A user explicitly pushed back on a 4-scalar-card KPI row for
this reason: 3 of the 4 numbers were parts of the same whole and the reviewer immediately read it
as "this should be one chart showing proportions, not 3 numbers I have to add up in my head" —
and the 4th ("Total de Casos") added little value once removed from the KPI row (it's inferable
from hovering the donut or from the row count in the tables below).

```python
viz = {
    "pie.dimension": "status_column", "pie.metric": "count_column",
    "pie.show_legend": True, "pie.show_total": True, "pie.percent_visibility": "inside",
    "pie.colors": {"Aderente": "#88BF4D", "Não Aderente": "#E75454", "Sem objetivos ativos de TO": "#F9D45C"},
}
# display: "pie" (renders as donut when pie.show_total causes a center hole in v0.60)
```

Rule of thumb: scalar KPI cards are right for independent/non-summing metrics (e.g. a total
alongside an average handling time); a pie/donut is right the moment 2+ of the numbers are
mutually-exclusive partitions of one total — don't default to "one card per metric" without
checking whether the metrics actually sum to something.

## Gating Requires Native SQL — MBQL Derived Cards CANNOT Be Gated on a Required Selection

The sentinel-default + mandatory-clause gating pattern (pitfall 16 above, and the Jornada→Sugestões
section) only works on **Native SQL cards** with template-tags. It does NOT work on MBQL cards
that use `source-card` + `parameter_mappings` of type `["dimension", ...]` — that mechanism has no
equivalent of "required tag with a default sentinel"; when the dashboard filter is empty, Metabase
just omits the filter and the MBQL card shows ALL rows from the source-card, unfiltered.

If a user asks "make this MBQL table show nothing until a case/objective is selected" and the card
is MBQL against the RAW (not Native SQL), there is no way to do it while keeping the card as MBQL.
The only fix is converting that specific card to Native SQL referencing the RAW via a `{{#RAW_ID}}`
card-tag (same technique as the KPI/donut cards above), which still avoids duplicating SQL logic
(the RAW stays single-source), but changes the card's technical type. **Ask the user first** —
they may prefer to leave an MBQL card showing an unfiltered dump rather than convert it, especially
if the RAW-single-source-via-MBQL architecture is a hard requirement for them. Don't convert
unilaterally; present the tradeoff and let them choose (a user in this situation chose to keep it
as MBQL/unfiltered rather than convert).

## Null Category Values in Bar/Pie Charts — COALESCE in the RAW

A dimension that's sometimes NULL (e.g. `og_to_name` when a case has no OG TO assigned) renders as
a blank/unlabeled bar or slice in charts built from it — confusing, looks broken. Fix at the RAW
level with `COALESCE(column, 'Sem <Label>') AS column` so every derived MBQL/chart card
automatically inherits the readable label without per-card changes (this is the whole point of the
single-RAW architecture — fix null-handling once, upstream). Verify the row count is unchanged and
that the new label's count matches the old null count before/after:
```sql
COALESCE(cc.og_to_name, 'Sem OG TO') AS og_to_name,
```

## Showing "Active Filters" State on a Dashboard (Text Card Variables)

Metabase v0.60+ text cards support inline `{{parameter_slug}}` variables that render the current
value of a dashboard filter live, via the dashcard's `inline_parameters` list:
```python
{
    "id": -301, "card_id": None, "row": 3, "col": 0, "size_x": 24, "size_y": 1,
    "visualization_settings": {"text": "🔎 **Filtros ativos:** Caso: {{caso}} · OG TO: {{og_to}} · Status: {{status_aderencia}}"},
    "parameter_mappings": [],
    "inline_parameters": ["caso", "og_to", "status_aderencia"]  # MUST list every {{slug}} used in the text
}
```
Use this to close the "user clicked a crossfilter but has no visual confirmation of what's now
filtered" UX gap — cheap, no new card/query needed, just a text dashcard. Every parameter
referenced via `{{slug}}` in the text MUST also appear in that dashcard's `inline_parameters`
array or it won't resolve.

## Overriding a Dashcard's Displayed Title Without Renaming the Card

Users often want cards named with a collection-organizing prefix (e.g. "PEIs Aderentes TO - Por
OG TO") so they're easy to find/group in the collection browser, but want that prefix GONE from
the dashboard itself — don't rename the card (breaks collection organization), override the
per-dashcard display title instead. There are TWO different settings paths depending on how the
card was built, and you must check which one a given dashcard uses:

- **Older/simple cards** (table, scalar, pie): set `visualization_settings["card.title"]` directly
  at the top level of the dashcard object.
- **Newer "chart builder v2" cards** (seen on bar charts built/edited via the newer Metabase chart
  UI): the settings live nested one level deeper, at
  `visualization_settings["visualization"]["settings"]["card.title"]` — setting the top-level key
  alone does nothing for these.

Always GET the dashboard first and check which shape a given dashcard already uses (look for
`isinstance(vs.get('visualization'), dict)`) before writing, then write to the SAME shape it
already has — don't assume top-level. Verify after the PUT by re-reading both possible paths.

## Don't Place a Status/Indicator Text Card Immediately Below the Native Filter Bar

A text card meant to show contextual info (e.g. "active filters" via `{{param}}` variables)
placed directly under Metabase's own filter-widget bar at the top of a dashboard reads to the user
as a SECOND row of filters, not as an indicator — even though it's non-interactive text. A user
rejected this exact placement ("ficou parecendo como se os filtros tivessem ficado um pouco mais
embaixo, só isso"). If asked for a filter-state indicator again, don't default to a top-of-page
text card; consider instead: a dynamic subtitle/description on the specific chart the filter
affects, a badge inside the chart's own title area, or ask the user where they'd want it before
placing it adjacent to the filter bar.

## Mirroring a Product Panel's Structure Is Opt-In, Not Default

Don't assume the goal is to replicate a clinical-panel (or any product UI) screen's layout,
grouping, or grain unless the user explicitly asks for that comparison/mirroring. A user
who asks you to investigate panel structure once, or corrects a grain mismatch against the
panel, is not thereby asking you to always chase panel-fidelity going forward — confirmed
directly: "nem sempre vou querer replicar o painel... só quando eu pedir!" When the ask is
just "build a dashboard for X", build the best dashboard for the data/question at hand;
only reach for the panel's frontend source (see grain-verification section below) when the
user names the panel as the reference to match, or is actively comparing your dashboard
against it.

## Enumerate ALL Source-Table Columns Before Finalizing a RAW — Don't Stop at the Obvious Enum Fields

When building a RAW from an assessment/registry table, it's easy to pull every structured
enum/status column (the ones that map cleanly to dashboard filters and chart dimensions)
and forget free-text columns like `observations`/`notes` — they don't fit neatly into
breakouts so they're easy to skip when scanning a model file quickly. A user caught this
after the dashboard was already built and reviewed: 2 of 5 sub-assessment RAWs were missing
their `observations` column entirely, while 3 others already had it — an inconsistency a
systematic column check would have caught immediately.

**Fix / habit:** after drafting a RAW's SELECT list from a source table, diff it against
`SELECT column_name FROM INFORMATION_SCHEMA.COLUMNS WHERE table_name = '<source>'` (or the
Rails model's full attribute list) — every column should be either included, or
deliberately excluded with a one-line reason in a comment (e.g. "internal id, not
business-relevant"). Free-text notes/observations fields are exactly the kind of column
that's easy to silently drop this way.

**Placement matters once you add it back:** a free-text field that's constant per case
(e.g. one `observations` per assessment) must NOT be added as a column on a fan-out table
(one row per feature/word/process) — it will repeat verbatim on every fan-out row, the same
duplication bug covered by "Splitting One RAW's Question Into Multiple by Cardinality"
below. Add it to whichever Question is already `SELECT DISTINCT`/one-row-per-case for that
sub-assessment, or create a small dedicated one-row-per-case Question for it if none exists
yet — don't force it onto the nearest fan-out table just because it's convenient.

## Pattern: Pivoting a Wide Checklist Table into Vertical Item/Resposta Rows

When an assessment RAW has many boolean/enum columns representing individual checklist
items (e.g. 13-30 columns like `limited_lip_retraction`, `breathing_mode`,
`gaze_at_board_static`) and either (a) the source product renders them as a vertical
"Item | Resposta" table, or (b) the user flags the wide table as unwieldy/too horizontal,
reproduce it with a `UNION ALL` of one `SELECT` per column against the same source-card,
each branch literal-labeling its own `item` name and casting its value to `resposta`, plus
a numeric `item_order` to control display order (UNION ALL does not preserve column-order
semantics across branches, so always wrap in a subquery and `ORDER BY item_order`):

```sql
SELECT item, resposta
FROM (
  SELECT 1 AS item_order, 'Retração de Lábios Limitada' AS item, limited_lip_retraction AS resposta
  FROM {{#8214}}
  WHERE clinical_case_number = {{caso}}
    [[AND location_name = {{unidade}}]]
    [[AND fono_og_name = {{og_fono}}]]

  UNION ALL

  SELECT 2 AS item_order, 'Protrusão de Lábios Limitada' AS item, limited_lip_protrusion AS resposta
  FROM {{#8214}}
  WHERE clinical_case_number = {{caso}}
    [[AND location_name = {{unidade}}]]
    [[AND fono_og_name = {{og_fono}}]]
  -- ...one branch per column, same filters repeated verbatim on every branch
)
ORDER BY item_order
```

If the source screen groups items under sub-headers (e.g. "Respiração" / "Mastigação" /
"Deglutição" for orofacial functions, or "Controle Motor de Fala Geral" / "Características
Segmentais" for speech motor control), add that grouping as its own literal column (e.g.
`funcao` or `secao`) in every branch — one extra display column, not a separate card,
producing a two-level table from one flat SQL result.

**Don't default to pivoting speculatively.** Only apply this when (a) the source product's
screen demonstrably renders vertical item rows (verify by reading the frontend, per "Verify
the Real Screen Grain" above), or (b) the user directly says the wide table is too wide/hard
to read. A plain wide table is fine when there's no product screen to match and no width
complaint. Applied this pattern three times in one session (Bandeiras Vermelhas → then, on
request, Motricidade Orofacial and CAA) after the user first flagged one table as "muito
longo horizontalmente" — the ask generalized to sibling sub-assessments with the same shape.

**Constant-per-case fields mixed into the checklist (e.g. a free-text `observations` field)
do NOT belong pivoted into the same item/resposta rows** — split them into their own
`SELECT DISTINCT` card (1 row per case), same as the fan-out/constant-field split used for
Comunicação Expressiva features vs. skills (see "Splitting One RAW's Question Into Multiple
by Cardinality" below). A sub-assessment with N structural blocks in the source UI (e.g.
CAA's Necessidade / Observações Clínicas / Decisão Clínica) typically decomposes into N+1
Questions off the one shared RAW: one per structural block (pivoted vertical if it's a
checklist, scalar if it's a single field) plus one for the assessment-level observations.

## Check for a Canonical Reference SQL Repo Before Assuming a Filter Is Missing

## Verify the Real Screen Grain Before Modeling a RAW (Don't Infer Grain from Column Names Alone)

When mirroring a clinical assessment / form's structure into a dashboard, don't assume a
table's grain from its column names or from an ORM-level `has_many`/aggregation you
happened to write first — go read the ACTUAL frontend component (React table columns, or
the equivalent form renderer) that produces the screen the user is comparing against, and
match its grain exactly before writing the RAW SQL.

**Concrete case that went wrong:** a "Fonológica (Imitação)" assessment RAW was built with
`SUM(quantity) GROUP BY atypical_process_name` — a per-process aggregate across all words.
This looked reasonable but had NO row for `word` or `transcription` at all. The real
clinical-panel screen (`PhonologicalWordsAssessment/Table.tsx`) renders a table with grain
**1 row per (case, dictionary word)** — columns Word | Transcription | Atypical Process(es)
for that word | Was Assessed — a completely different shape. The user caught this only by
comparing the dashboard to the live product screen ("não vi nenhuma tabela com essa
coluna" — transcription was nowhere to be found because it never existed in the wrong-grain
model).

**Process to avoid this:**
1. Before writing a RAW for "assessment X", find and read the frontend Table/Form component
   for that exact screen (search for the assessment name in the frontend repo, e.g.
   `search_files` for `PhonologicalWordsAssessment`, `ExpressiveCommunicationFeaturesAssessment`).
2. Note every column the UI actually renders and the entity each row represents (what does
   ONE row of that on-screen table correspond to in the DB — a word? a feature? a fixed
   enum item?).
3. Check the underlying Rails model/migration for that entity's real columns (e.g.
   `phonological_words` has `word`, `transcription`, `was_assessed` — a genuinely different
   table from `phonological_atypical_processes`, which is a child with `name`+`quantity`).
4. Only THEN decide the RAW's grain. If a derived/aggregated view is also useful (e.g. "total
   occurrences per process across all words"), build it as an ADDITIONAL row-type or
   separate Question, clearly labelled as a derived analysis — never as a replacement for
   the screen-accurate table, and never silently combining two different grains in one
   `LEFT JOIN` (that creates a cartesian-product fan-out across unrelated grains — use
   `UNION ALL` with a discriminator column like `row_type` instead when a single RAW needs
   to carry two structurally different result shapes for two different dashboard tables).
5. When the user says "this doesn't look like what I see in `<product-panel>`", the correct
   response is to go re-read that panel's source, not to tweak column labels/formatting —
   the mismatch is almost always a wrong grain, not a cosmetic issue.

Before adding a new exclusion filter a user asks for (e.g. "filter out paused/on-hold cases"),
check whether a sibling reference-snippets repo already documents the canonical business-logic
pattern and whether the dashboard's RAW already implements it. In this codebase that repo is
`../code-snippets/queries/` (e.g. `queries/utils/active-ot-cases.sql` documents the standard
"active cases" CTE pattern, including `AND ch.on_hold IS NOT TRUE`). Search there first
(`search_files` for the business term, e.g. "on_hold") — the fix may already be baked into the
RAW's WHERE clause from when it was originally built against that same reference pattern, in which
case the right answer is "already handled" backed by a live data check (count how many rows the
exclusion actually removes, e.g. via a scratch `/api/dataset` query), not a code change.

## Archiving Orphaned Cards

When a card is removed from a dashboard (e.g. replaced by a different viz) but might be wanted
back, soft-delete rather than hard-delete: `PUT /api/card/:id` with `{"archived": true}`. Keeps it
recoverable without cluttering the collection's active card list.

## Boolean Column Formatting (not just string)

`table.column_formatting` also works on boolean columns (e.g. a `max(is_pair_adherent)` column),
not only string status columns. Use `"type": "single"` with `"operator": "="` and
`"value": true` / `"value": false` (JSON booleans, not strings):

```python
vs['table.column_formatting'] = [
    {"columns": ["max"], "type": "single", "operator": "=", "value": True, "color": "#88BF4D", "highlight_row": True},
    {"columns": ["max"], "type": "single", "operator": "=", "value": False, "color": "#EF8C8C", "highlight_row": True},
]
```
Apply the SAME color scheme used elsewhere on the dashboard (e.g. the case-level summary table)
to any other table showing an adherence-like boolean — inconsistent coloring across tables that
represent the same concept is a UX gap the user will flag in a review.

## Pitfall: Dashboard Filter Silently Doesn't Affect a Card (Missing parameter_mapping)

If a dashboard filter (e.g. `status_aderencia`) is wired to some cards but not others, those other
cards simply ignore the filter with NO error — looks like "the filter doesn't work" but is
actually an incomplete `parameter_mappings` list on a subset of dashcards. When auditing OR
building a dashboard, check EVERY dashcard's `parameter_mappings` against every dashboard filter
that logically should apply to it, not just the ones wired when the card was first created. Fix
by PUT `/api/dashboard/:id` with the missing mapping appended to that dashcard's
`parameter_mappings`:
```python
pm.append({"parameter_id": "status_aderencia", "card_id": dc['card_id'],
           "target": ["dimension", ["field", "aderencia_status", {"base-type": "type/Text"}], {"stage-number": 0}]})
```
**Always verify the fix** by calling the dashboard query endpoint with and without the filter and
diffing the rows — don't just trust that adding the mapping worked.

## CRITICAL: `PUT /api/dashboard/:id` With Only `{"dashcards": [...]}` Wipes `parameters`

`PUT /api/dashboard/:id` treats the request body as a **partial replace on whichever top-level
keys you send** — but for the `parameters` array specifically, omitting it from the payload does
NOT mean "leave unchanged": it gets reset to `[]`, silently deleting every dashboard-level filter
(the filter widgets the end user sees and clicks at the top of the dashboard). This is easy to
trigger by accident: any workflow that GETs the dashboard, mutates `dashcards`, and PUTs back
`{"dashcards": new_dashcards}` alone will wipe filters — confirmed by a user report ("você removeu
todos os filtros") after a dashcards-only PUT on dash 296.

**Rule: whenever you PUT to `/api/dashboard/:id` to change layout/dashcards, ALSO include the
dashboard's current `parameters` array in the same payload** (fetch it via GET first if you don't
already have it in this session):

```python
d = api('GET', f'/api/dashboard/{DASH_ID}')
payload = {
    "dashcards": new_dashcards,
    "parameters": d['parameters']   # MUST re-include, even if unchanged, or filters vanish
}
api('PUT', f'/api/dashboard/{DASH_ID}', payload)
```

To recover after the fact, re-PUT the previously-known `parameters` array (each entry needs
`id`, `slug`, `name`, `type`, `sectionId`, `isMultiSelect`) — grab it from an earlier GET response
saved in this session, or reconstruct from the dashcards' `parameter_mappings` (parameter_id +
inferred type) if no earlier snapshot exists.

**After ANY dashboard PUT, always GET it back and diff `parameters`, dashcard `click_behavior`,
and `parameter_mappings` against what you expect** — don't just check that `dashcards` count
matches; the response schema doesn't scream when it silently dropped a top-level field you didn't
send.

## Inserting New Dashcards Into an Existing Layout (Full Dashboard Rewrite)

`PUT /api/dashboard/:id` with a `dashcards` array replaces the ENTIRE layout — there's no
"insert card at position" endpoint. To add cards to a specific spot in an existing dashboard:
1. GET the full dashboard, take its `dashcards` array.
2. For every dashcard with `row >= <insertion point>`, add the height of what you're inserting to `row` (push everything down).
3. Append new dashcard objects with unique **negative** `id`s (e.g. -101, -102) and real `card_id`s from cards already created via `POST /api/card`.
4. Strip `card`, `created_at`, `updated_at` keys from every dashcard object (read-only, rejected/ignored on write).
5. PUT the full `{"dashcards": [...]}` back. Response echoes real (positive) ids assigned to your negative placeholders — re-GET the dashboard to confirm final ids/rows if you need to reference them again in the same session.

## API Quirks

### Native SQL card format in Metabase v0.60 (stages format)

Metabase v0.60 stores native queries in the **stages** format, not the old `native.query` format. When updating a Native SQL card's SQL via PUT `/api/card/:id`, you MUST use the stages format or the SQL will be wiped:

```python
# CORRECT (v0.60):
payload = {
    "dataset_query": {
        "lib/type": "mbql/query",
        "database": DATABASE_ID,
        "stages": [{
            "lib/type": "mbql.stage/native",
            "native": sql_string,
            "template-tags": tags_dict
        }]
    }
}

# WRONG (will wipe the SQL):
payload = {
    "dataset_query": {
        "type": "native",
        "native": {"query": sql_string, "template-tags": tags_dict},
        "database": DATABASE_ID
    }
}
```

After a PUT, always verify by re-reading the card: check `stages[0].native` has the SQL and `stages[0].template-tags` has the tags. If `stages[0].native` is empty, the update used the wrong format.

### PUT /api/card/:id may not update dataset_query

Sending the full card object (read-modify-write) sometimes doesn't update `dataset_query`. If the card's query doesn't change after a PUT:
1. Try sending ONLY `{"dataset_query": new_dq}` (not the full card).
2. Verify by re-reading the card and checking the stages.
3. Metabase may convert/reformat the query on save — the response might show `stages: []` even though the update succeeded.

### Card query caching

Metabase caches card query results aggressively (hours). To verify a change:
1. Use `/api/dataset` with the card's SQL directly (bypasses card cache).
2. Check the `cached` field in the response — if it has a timestamp, the result is stale.
3. The dashboard endpoint may also cache — wait or use cache-busting parameters.
4. **To force a refresh NOW, re-save the card** — `PUT /api/card/:id` (even a no-op like appending a space to `description`) returns `cache_invalidated_at` in the response and invalidates that card's cache. **Each card has its OWN cache**: busting the RAW model does NOT refresh the derived MBQL cards or the native cards that reference it via `{{#raw_id}}` — you must re-PUT EVERY card on the dashboard (model + all derived + all native). This is the #1 reason "the dashboard still shows old data" after a data fix: the fix is correct at the source, but only the model's cache was cleared, so every downstream card keeps serving stale rows. Verify each card reports `cached: null` on its next `/api/card/:id/query` (or dashboard-endpoint query) after the re-PUT.

## Auditing a Dashboard's Filter Wiring (Read-Only UX/Critique Review)

When the ask is "analyze/critique this dashboard" (UX review, "find improvements", not build/edit), prefer the REST API over browser screenshots when an API key is available — it's more reliable and lets you cross-reference structure against actual data:

1. `GET /api/dashboard/:id` → gives `parameters` (the declared filters) and `dashcards[]` (each with `card_id`, `parameter_mappings`, `visualization_settings.click_behavior`, and text-card content in `visualization_settings.text`).
2. For each unique `card_id` in dashcards, `GET /api/card/:id` → gives `dataset_query.stages` (native SQL or MBQL breakout/aggregation/filter), `visualization_settings` (column_settings/titles, column_formatting, series_settings, graph.dimensions/metrics), and `type` (question vs model).
3. **Cross-reference `parameter_mappings` per dashcard against the full list of dashboard `parameters`.** This is the single highest-value check: build a table of `dashcard -> which parameter_ids it actually receives`. Any dashboard filter that is NOT mapped to a dashcard the user would expect it to affect (e.g. a status filter that only touches the summary table but not the charts built from the same data) is a real UX bug, not a style nitpick — flag it as priority 1, not as a "nice to have".
4. Pull a real data sample via `POST /api/card/:id/query` on the base/summary card and compute quick stats in `execute_code` (status distribution, null rates on key dimensions, distinct value counts) — ground every critique point in actual numbers instead of guessing from a screenshot. This also surfaces things like "N% of rows have a null dimension that will render as a blank/ugly bar in charts."
5. Read every text-card's `visualization_settings.text` verbatim — dashboards accumulate stale/cut-off draft text ("Ainda não entendi o motivo") that looks like a placeholder note left in production; these are embarrassing and cheap to flag.
6. This API-first path does NOT require `computer_use`/browser screenshots at all when a working `MB_API_KEY` is available — only fall back to the browser capture (see below) when no API key can be sourced.

This is a read-only review — do not create/update any card or dashboard as part of an "analyze"/"critique" ask; only produce written recommendations, per the Safety Rule below.

## Reading/Analyzing a Live Dashboard via Browser (no API key needed)

Sometimes the ask is "analyze this dashboard" (a URL with filters), not "build/edit a dashboard". Don't assume you need `MB_API_KEY` or MCP access first — check whether the dashboard is already open in the user's browser:

1. `computer_use(action='list_apps')` to see if Chrome/Safari is running, then `computer_use(action='capture', app='Google Chrome', mode='som')`. If the user's session is already logged into Metabase, you get the live, filtered dashboard for free — no credentials needed.
2. **SOM capture output can be huge (100-200KB)** and gets written to a temp file (`/var/folders/.../hermes-results/<id>.txt`) instead of returned inline. Don't try to `read_file` the whole thing — parse it programmatically instead:
   ```python
   import json
   with open(path) as f:
       data = json.load(f)
   texts = [e['label'] for e in data['elements'] if e['role'] == 'AXStaticText']
   ```
   This pulls all visible text (card titles, table cell values, axis category labels, filter values) in one pass — much cheaper than reading the raw JSON with `read_file`/`search_files`.
3. **`vision_analyze` / `mode='vision'` can fail with a guardrail/policy 404** ("No endpoints available matching your guardrail restrictions") depending on the routed vision provider. When this happens, fall back to the AX-tree text extraction above — it recovers table/label data even though it can't read pixel-only content.
4. **Known limitation: bar/stacked-chart numeric values are usually NOT exposed in the AX tree** — only axis category labels (e.g. therapist names, unit names) and the Y-axis scale come through as `AXStaticText`. If exact segment values are needed, either pull them from the underlying MBQL query via the REST API (see below) or say explicitly that the values could not be confirmed — do not estimate them from bar heights.
5. If exact numbers ARE needed and no API key is available in the environment, ask the user directly where `MB_API_KEY` lives rather than searching broadly across the filesystem/keychain — it is typically not exported as a shell env var and searching for it wastes turns.
6. Never assume clicking/editing the open dashboard is wanted — if you see an "editing this dashboard" banner in the capture, that state pre-existed; don't click Save/Cancel on the user's behalf without asking.

## Multi-Tenant Architecture: Genial vs Mindplace Careplus (MANDATORY)

Metabase has **two separate database connections** for the same underlying data model:
one that only surfaces rows for the `genialcare` tenant (the default/standard connection),
and one that only surfaces rows for the `mindplace_careplus` tenant (identifiable by
something in the connection name — check `GET /api/database` and look for
"mindplace"/"careplus" in the `name` field before assuming which `database_id` is which).
Always confirm the `database_id` for each tenant via `GET /api/database` rather than
hardcoding — the IDs are environment-specific.

**Confirmed naming convention (GenialCare env, checked via `GET /api/database`)**: Genial
connections use the bare name (`data-kernel-production-big-query`,
`supervision-production-big-query`, `operational-data-big-query`, `clinical-panel-big-query`,
`clinical-guidance-production-big-query`, `clinical-llm-data-production-big-query`,
`mobile-big-query`); every one of those has a `mindplace-`-prefixed sibling
(`mindplace-data-kernel-production-big-query`, `mindplace-supervision-production-big-query`,
`mindplace-operational-data-big-query`, `mindplace-clinical-guidance-production-big-query`).
Don't rely on name alone if it looks ambiguous — cross-check the BigQuery project via
`GET /api/database/:id`. Note: `details.project-id` is often `None`/empty on the
`mindplace-*` connections; the ACTUAL project is in `details.project-id-from-credentials`,
which the API masks to a `prefix…suffix` form (e.g. `data-k...4o7n`). In this env the
`mindplace-*` connections point at the SAME GCP projects as their Genial counterparts
(`data-kernel-production-4o7n`, `supervision-production-8f1v`, `ops-data-production-8fk2`) —
tenant separation is done by the (masked) service-account credentials via row-level
scoping, NOT by distinct projects. So the tenant swap is a pure `database_id` change; the
SQL/MBQL body (including fully-qualified `project.dataset.table` names) stays identical.

```bash
curl -s -H "x-api-key: $MB_API_KEY" "$MB_URL/api/database" | python3 -c "
import json,sys
for db in json.load(sys.stdin):
    print(db['id'], db['name'], db.get('engine'))
"
```

### Collection layout

When the user gives a target collection (e.g. `"Dashes de Produto: Exp Clínica/PEI"`),
that path is the **parent**, not the final destination:

1. **Always build the Genial version first**, inside a subcollection named exactly
   `Tenant Genial` under the given parent:
   `Dashes de Produto: Exp Clínica/PEI/Tenant Genial`. Create this subcollection via
   `POST /api/collection` (`{"name": "Tenant Genial", "parent_id": PARENT_COLLECTION_ID}`)
   if it doesn't exist yet, then put every RAW/derived card + the dashboard itself inside it.
2. **Only when explicitly asked**, create a sibling subcollection
   `Dashes de Produto: Exp Clínica/PEI/Tenant Careplus Mindplace` with the exact same set of
   questions and dashboard layout, but:
   - Every card's `database_id` points at the Mindplace Careplus connection instead of the
     Genial one (same SQL/MBQL logic otherwise — this is a straight tenant-connection swap,
     not a redesign).
   - Every card name AND the dashboard name get the prefix `"Mindplace - "` (e.g.
     `"Mindplace - Dashboard Name - RAW"`, `"Mindplace - Dashboard Name - Por Dimensão"`,
     `"Mindplace - Dashboard Name"`) so they're visually distinguishable from the Genial
     versions when browsing the collection tree or search results.
3. Do NOT create the Mindplace Careplus copy proactively — it's built on request, after the
   Genial version is done and validated. Treat it as a distinct, later step.
4. When copying, don't just change `database_id` in isolation — MBQL derived cards carry a
   `source-card` reference to the RAW's card ID. The Mindplace copy needs its OWN RAW card
   (new `POST /api/card`, Mindplace `database_id`) and its derived cards must `source-card`
   that new RAW id, not the Genial RAW id. Re-verify every `source-card`/`{{#card_id}}`
   reference after duplicating — a leftover reference to the Genial RAW would silently pull
   Genial data into a "Mindplace" dashboard.

5. **There is a THIRD card-id reference that is easy to miss: the dashcard's
   `visualization_settings.visualization.columnValuesMapping[].sourceId`.** Chart-builder-v2
   dashcards (bar/combo) store a column mapping INSIDE the dashcard (not the card) with
   `"sourceId": "card:<id>"` strings pointing back at the original card. When copying a
   dashboard, these MUST be re-pointed to the new card ids (e.g. `"card:8156"` →
   `"card:8317"`), or the chart renders "No results!" on the dashboard while still showing
   data when you click into the card (the card's own query is fine). Confirmed on dash
   296→300 (the "Por OG TO" / "Por CG" bar charts). The dashcard's `visualization_settings`
   (nested under `visualization.settings`) OVERRIDES the card's own
   `visualization_settings`, so editing the card's settings alone has NO effect on dashboard
   rendering — you must edit the dashcard. Fix by recursively rewriting every
   `"card:<old_id>"` → `"card:<new_id>"` inside each dashcard's `visualization_settings`,
   then `PUT /api/dashboard/:id` with `{dashcards, parameters, width}` (remember the
   PUT-wipes-`parameters` pitfall — always re-include the `parameters` array).

### Verify the tenant swap BEFORE the full copy

Cheap one-shot probe before creating anything: run the target connection against a
tenant-keyed table and confirm it surfaces a DIFFERENT tenant than the source connection
(same GCP project, different service-account scope). This is the fastest way to confirm
"only the connection changes" is actually true, rather than discovering a missing project
mid-copy:

```bash
# against the target (mindplace) connection, e.g. database_id 18
curl -s -X POST -H "x-api-key: $MB_API_KEY" -H "Content-Type: application/json" \
  -d '{"database":18,"type":"native","native":{"query":"SELECT tenant_id, COUNT(*) c FROM `data-kernel-production-4o7n.datakernel.clinical_cases` GROUP BY tenant_id"},"parameters":[]}' \
  "$MB_URL/api/dataset"
```
Expect one tenant_id with a small case count vs. the source connection's (different) tenant_id
with a larger count. Note the `tenants` table itself may return EMPTY via both connections
(service account has no read on it) — so `tenant_name` comes out NULL in the RAW for both
tenants; that's pre-existing and identical on both sides, not a copy defect.

### Copy recipe details (verified end-to-end on the PEIs Aderentes TO → Mindplace copy)

- **Copy order matters**: create the model/RAW first, then derived cards (they reference the
  new RAW id), then the dashboard.
- **Preserve `result_metadata` on a native model copy.** The MBQL derived cards reference the
  RAW's output columns by name + `base-type` (`type/Integer`, `type/Text`, `type/Boolean`).
  If you let Metabase re-derive the model's field types by running the SQL, the base-types may
  drift (e.g. a numeric-looking string becomes Decimal) and the MBQL `field` refs break. Copy
  the source model's `result_metadata` verbatim into the `POST /api/card` payload.
- **Re-point `{{#card_id}}` in THREE places** on a Native SQL card that references the RAW
  (e.g. the pie/KPI card): the SQL text (`{{#OLD_ID}}` → `{{#NEW_ID}}`), the template-tag
  key/`name`/`display-name` (`#OLD_ID` → `#NEW_ID`), and the tag's `card-id` field.
- **Rebuild the dashboard** with unique negative dashcard `id`s and, crucially, remap each
  `parameter_mappings[].card_id` from the old card id to the new one — the target
  `["dimension", ["field", ...]]` / `["variable", ["template-tag", ...]]` bodies are
  card-id-independent and copy as-is, but the `card_id` key itself must follow the id map.
  `click_behavior` and text-card `virtual_card`/`text` copy verbatim.
- **Verify via the dashboard endpoint, not the card endpoint** (MBQL cards ignore card-endpoint
  filters — pitfall 12). Confirm: model returns N distinct cases via `/api/card/:id/query`, a
  derived card returns the case-level count (pushdown working), and a gated native card returns
  0 rows with its sentinel default.

- **Re-point the dashcard's `columnValuesMapping[].sourceId` too (bar/combo cards) — the #1 "No results!" cause when copying.** Chart-builder-v2 bar/combo dashcards carry `visualization_settings.visualization.columnValuesMapping[].sourceId` strings of the form `"card:<id>"`. Copying a dashboard verbatim leaves these pointing at the OLD card ids, and a stale `sourceId` makes the chart render **"No results!"** on the dashboard even though `/api/card/:id/query` returns rows (the chart builder resolves its columns against the wrong source card). This was the ACTUAL root cause on the MindPlace "Por OG TO"/"Por CG" bars — NOT `graph.series_order_dimension`, which is a harmless leftover (the working Genial cards 8156/8157 have it too). Fix: recursively rewrite every `"card:<old_id>"` → `"card:<new_id>"` string inside each dashcard's `visualization_settings` before the dashboard PUT. Only bar/combo charts use `columnValuesMapping`; tables/pies don't. **Card-vs-dashcard settings split:** a dashcard's `visualization_settings` OVERRIDE the card's own for dashboard rendering (v2 cards nest them under `visualization`), so fixing a field on the CARD (`PUT /api/card/:id`) does NOT fix the dashboard — you must also `PUT /api/dashboard/:id` with the corrected dashcard settings.

See `references/tenant-copy-recipe.md` for a full worked script.

## Safety Rule (MANDATORY)

**Never update, modify, or delete any card, dashboard, or artifact you did not create during the current session** — unless the user explicitly asks you to. This includes reference dashboards (e.g. PEI Aderente Psico, ID 261) and any pre-existing cards. Reading/inspecting for reference is fine; writing is not. If you need to understand how something works, read it — don't change it.

## Deciding: One RAW, or Multiple RAWs?

The Single-RAW mandate above is the DEFAULT, not an absolute. When a user pushes back
("I'm not sure a single RAW makes sense here, don't force it") the right response is to
actually evaluate grain compatibility before defaulting to one RAW:

- **One RAW is right** when every sub-metric you need lives at the SAME grain and doesn't
  fan out relative to each other. Example: "last assessment status per case" — even though
  the underlying Registry has 5 sub-assessments, at the *status* level (not the internal
  fields of each sub-assessment) they're all still 1-value-per-case, so they collapse into
  one row per case with zero fan-out. One RAW, one row per entity, no fan-out = correct call.
- **Split into multiple RAWs** when sub-domains have genuinely different internal
  structures/grains that would force an artificial join or duplicate rows to combine (e.g.
  one sub-assessment stores data per-word/per-occurrence with its own child table, another
  stores one JSONB flag per feature-name row, another is a simple scalar). Forcing these into
  one RAW "at all costs" produces either heavy fan-out (row count explodes, aggregations on
  unrelated columns silently double-count) or a RAW so wide with sparse/irrelevant NULLs that
  it stops being a readable single source of truth.
- **How to check before deciding**: identify the grain each piece of data naturally lives at
  (1 row per case? per case×word? per case×feature?). If two pieces share the exact same
  grain, they merge into one RAW/CTE without fan-out. If they don't, either keep them as
  separate RAWs (each feeding its own derived cards) or, only if truly needed on the same
  dashboard row, accept and explicitly document the fan-out with a downstream aggregation
  step (COUNT DISTINCT / MAX per real entity) — don't silently let it fan out.
- Validate the grain call with real data, not by inspection alone: run the candidate RAW via
  `POST /api/dataset`, then check `len(rows) == len(set(entity_id for row in rows))` (e.g.
  distinct case numbers == row count) to confirm no unintended fan-out crept in before
  creating the card.

## "Avaliação Completa" vs "Criança Consegue Fazer Isso" — Status Fields Are a Trap

A recurring GenialCare pattern: a sub-assessment/registry has a `status` field (e.g.
`'completed'`, `'started'`) that means **"this form was filled out"** — a data-collection
signal — which is completely different from the clinical signal the dashboard is
actually meant to show: **"can the child do this."** A user caught this exact confusion
mid-build: a RAW exposing `registry_status` + 5 sub-assessment `status` columns as
display columns looked like it was answering "is the child able to do X" when it was
really just answering "was this form completed."

Rule: when a table/registry has a completion-tracking `status` column,
1. Use it ONLY internally, in a `WHERE status = 'completed'` filter to pick which
   row/registry is valid to read from — e.g. `WHERE str.status = 'completed' QUALIFY
   ROW_NUMBER() OVER (PARTITION BY clinical_case_id ORDER BY completed_at DESC) = 1`
   picks the last COMPLETE registry, never one still in progress.
2. Do NOT expose that status column (or sub-statuses, or a `completion_percentage`) as a
   dashboard/table column — it reads to the end user as a clinical finding, not a
   data-collection state.
3. The real "can the child do this" signal comes from the actual answer/field values in
   the sub-assessment record (e.g. `physical_conditions.jaw_posture`, library objective
   completion) — those are what should be surfaced as columns, not the status.

Before building any RAW that touches an "avaliação"/assessment registry, ask whether each
status-like column is a collection-progress marker or a clinical-capability signal — don't
assume completion status is dashboard-worthy just because it exists on the table.

## Splitting One RAW's Question Into Multiple by Cardinality (SELECT DISTINCT Trick)

Beyond trimming noisy columns (Question-Wraps-RAW above), sometimes a RAW mixes a genuine
fan-out block (many rows per case, e.g. one row per list item/feature) with a block that is
CONSTANT per case (same value repeated on every fan-out row, e.g. a profile/skill that doesn't
vary per item). Displaying both in one Question makes the constant block visibly repeat once per
fan-out row — reads as a bug to the user even though the data is correct (a user flagged exactly
this: a "general communication skills" block repeating 9x once per communicative-feature row).
Fix: keep ONE RAW (don't fork the source-of-truth), but split the display Question in two:

```sql
-- Fan-out block Question: keep as-is, one row per item
SELECT feature_name, performed_frequency, uses_vocalizations, ...
FROM {{#8216}}
WHERE clinical_case_number = {{caso}} AND feature_name IS NOT NULL

-- Constant block Question: SELECT DISTINCT collapses the repeated rows back to 1 per case
SELECT DISTINCT echolalia_profile_frequency, communicative_intent_frequency, ...
FROM {{#8216}}
WHERE clinical_case_number = {{caso}}
```

`SELECT DISTINCT` is the whole trick — since the constant columns are identical across every
fan-out row for a given case, deduplication collapses them to exactly one row with no new GROUP
BY logic needed. Verify with a real `caso` value via `/api/dataset`: fan-out Question's row count
should match the pre-split combined RAW; constant Question should drop to exactly 1 row. Applies
this same pattern to any sub-entity with multiple naturally-separate blocks at different
cardinalities (e.g. a "words tested" list + a separate "vocalizations produced" free-text summary
+ a separate "atypical processes tally" fan-out — three Questions off one RAW, not one wide table).

## Reading the Frontend's Own Form Components to Decide Table/Section Boundaries

Before deciding how many display tables a sub-entity needs, check whether the SOURCE PRODUCT UI
already draws a boundary there — its component breakdown IS the product's mental model of "what
is one logical block," which is a better signal than eyeballing the BigQuery schema or even the
Rails model relations alone:

1. Find the `*Form.tsx` / `<Entity>Assessment/index.tsx` in the frontend repo (e.g.
   `clinical-panel/src/pages/.../Assessments/<Name>/...Form.tsx`) that renders the entity. Its
   JSX body lists sibling sub-components in the exact order the user sees them, e.g.
   `<ExpressiveCommunicationFeaturesAssessment /><CommunicationSkillsAssessment />` = two
   distinct screens, so two distinct dashboard tables — not one merged table.
2. A sub-component boundary in the frontend usually lines up with either a different DB
   relation (`has_many` vs `belongs_to`, see the Rails-model grain check below) or a different
   **cardinality** (per-item list vs one fixed profile) — cross-check both signals, they should
   agree; if they don't, trust the frontend's grouping for what the user considers "one topic."
3. Replicate the frontend's screen order in the dashboard layout when asked to match the source
   UI (see "Match Source-System UI Ordering" below) — grep the `use<Entity>Navigation` hook
   (e.g. `useSpeechTherapyAssessmentsNavigation`) for the canonical `urlBuilder` key order if the
   Form files alone don't make the cross-entity order obvious.

## Checking Grain via Rails Model Relations (belongs_to vs has_many) Before Writing the JOIN

To decide 1:1-no-fanout vs has-many-needs-own-RAW (see "Deciding: One RAW, or Multiple RAWs?"
below) with certainty instead of guessing from column names, read the Rails model file for the
sub-assessment in `core/packs/clinical/app/models/assessments/**/*.rb` before writing SQL:
- `belongs_to :physical_conditions, foreign_key: "physical_conditions_id"` on the parent
  assessment → exactly one child row per parent, safe to LEFT JOIN directly with no fan-out.
- `has_many :phonological_words` (or similar) → many child rows per parent; that sub-assessment
  needs its own RAW at the case×child grain, or an aggregation step, not a bare JOIN.
This is faster and more reliable than inferring cardinality from BigQuery alone, and the i18n
labels for each enum/field usually sit in the matching `clinical-panel/src/i18n/locales/
speechTherapyAssessments/pt-br.json` (or sibling per-discipline file) for column-title lookup.

## Reusing Canonical "Active Cases" Filters from the Reference Query Repo

Before hand-writing an "active cases" / "excludes discharged/paused/churned" filter from
scratch, check whether the sibling reference-snippets repo (see "Check for a Canonical
Reference SQL Repo" pitfall above) already has a discipline-specific canonical CTE. In the
GenialCare codebase this lives at `../code-snippets/queries/utils/active-<discipline>-cases.sql`
(e.g. `active-fono-cases.sql`, `active-ot-cases.sql`) and already encodes the full business
rule for "ongoing, not discarded, target discipline active (excludes discharge — discharge
flips the discipline status to `completed`), not churned, not on hold" — copy it verbatim
into the RAW rather than re-deriving the same joins/filters. If asked to build a RAW for a new
discipline with no existing `active-<discipline>-cases.sql`, build the specific version first,
then generalize it back into `utils/` per that repo's own promotion convention (specific →
generalize once the pattern will be reused) so the next dashboard build gets a ready-made CTE.

## Verifying True Row Count When `/api/dataset` Caps Display

`POST /api/dataset` (and the ad-hoc card query it powers) silently caps the rows actually returned
in the response (observed capping at 2000) without flagging truncation in an obvious field —
trusting `len(data['rows'])` as "the total" after a fan-out JOIN will undercount. Before believing
a row/case count from an ad-hoc query, wrap the whole query as a subquery and ask BigQuery
directly:

```sql
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT clinical_case_number) AS distinct_cases
FROM (<full RAW query text, no trailing semicolon>)
```

Run that through `/api/dataset` and compare against the raw row list length — if they differ, the
display was capped, not the true result. Do this any time a RAW is expected to fan out (multiple
rows per case) — for flat 1-row-per-case RAWs the discrepancy won't show up until you cross the
2000-row case count, so it's easy to miss until a bigger dataset trips it.

## Retrofitting Dashboard Filters Onto an Already-Written RAW (Non-Destructive Wrap)

When a RAW's CTEs are already written and validated, and you need to bolt on optional dashboard
filters (`[[AND ...]]` + template-tags) without touching the internals, wrap the whole existing
query as a named CTE and filter in an outer SELECT rather than threading `[[ ]]` clauses into each
inner CTE:

```sql
WITH base_query AS (
  <the entire existing query, unmodified, including its own WITH chain, MINUS its own final ORDER BY>
)
SELECT * FROM base_query
WHERE 1=1
  [[AND clinical_case_number = {{caso}}]]
  [[AND location_name = {{unidade}}]]
  [[AND fono_og_name = {{og_fono}}]]
ORDER BY clinical_case_number
```

This is safe because BigQuery allows a `WITH` block as the first CTE of another `WITH` chain
transparently — you're not nesting the keyword, just wrapping the whole prior SELECT as one CTE
named `base_query`. Advantages: zero risk of breaking working join logic, one filter block reused
verbatim across every RAW that needs the same dashboard filters, and the diff against the
pre-filter version is trivial to review (just the added wrapper + WHERE block). Validate by running
the SAME outer query with no `parameters` (must return the original unfiltered count) and again
with a `parameters` array supplying one tag (must return the narrowed count) via `/api/dataset`
before wiring it into the dashboard's `parameter_mappings`.

## Question-Wraps-RAW: Curated Dashboard-Facing Views Without Duplicating Logic

Don't put a RAW directly on a dashboard. RAWs intentionally carry every column (internal IDs,
emails, org-role columns like "OG ABA" that aren't relevant to this specific dashboard) for
downstream reuse — but end users shouldn't see that noise. A user explicitly asked for this
after seeing `registry_id`, an email column, and an unrelated OG role column on a dashboard
table. Fix: wrap the RAW in a Native SQL "Question" card that selects only the useful column
subset, using the same `{{#raw_card_id}}` card-tag technique as the KPI/scalar cards elsewhere
in this doc:

```sql
SELECT
  clinical_case_number, clinical_case_name, location_name, fono_og_name,
  assessment_completed_at, days_since_last_assessment
  -- omitted on purpose: registry_id, fono_og_email, og_aba_name (noise for this audience)
FROM {{#8211}}
WHERE 1=1
  [[AND clinical_case_number = {{caso}}]]
  [[AND location_name = {{unidade}}]]
```

This keeps the RAW as the single source of truth (fix logic once, every Question inherits it)
while each dashboard-facing card curates its own columns and re-declares its own template-tags
for dashboard filters. One Question per RAW — when a dashboard has N sub-entity RAWs, build N
matching Question wrappers, don't merge multiple RAWs into one mega-Question.

## Master-Click Gates Many Detail Tables (Scaling the Sentinel Pattern)

The sentinel-default gating pattern (pitfall 16 + "Jornada→Sugestões" section) scales cleanly
to "1 summary table + N detail tables, all hidden until a row is picked in the summary" — a
common ask once a dashboard has one detail card per sub-entity (e.g. one per sub-assessment).

1. Give the summary/master table a `click_behavior` of type `crossfilter` that sets ONE
   dashboard parameter (e.g. `caso`) from the clicked row's key column.
2. Every one of the N detail Questions gets the IDENTICAL required+sentinel template-tag
   (`caso`, `required: true`, `default: "-1"`) and the IDENTICAL unconditional gate clause
   (`WHERE clinical_case_number = {{caso}}`) — copy the gate verbatim into all N cards, don't
   vary the mechanism per card even if the rest of the SQL differs.
3. Verify EACH detail card independently: 0 rows with no `caso` parameter, correct rows with a
   real value. Don't assume "it worked on card 1 so it works on all N" — a copy-paste typo in
   one of N cards (e.g. wrong column name in the gate) is easy to miss without testing each one
   via `/api/dashboard/:id/dashcard/:dashcard_id/card/:card_id/query`.
4. Independent bar/pie charts elsewhere on the same dashboard can set OTHER dashboard
   parameters (e.g. Unidade, OG) via their own `click_behavior`, targeting a different
   parameter id than the master-detail chain — multiple crossfilter chains coexist fine on one
   dashboard as long as each targets a distinct parameter id and every affected card's
   `parameter_mappings` includes it (see the "Missing parameter_mapping" pitfall above).

## Match Source-System UI Ordering for Multi-Section Dashboards

When a dashboard has multiple detail tables that mirror a form/panel that already exists in the
product UI (e.g. a clinical assessment with several sub-sections shown in order in the "Painel
Clínico"), order the dashboard's tables to match that UI's section order — not creation order,
not alphabetical order. A user asked for exactly this after the tables were built in investigation
order rather than the order clinicians see them in the product. Ask the user for the canonical
order if it's not obvious from context; don't assume build order reflects the source UI's order.

Reordering dashcards is a pure `row` reassignment via `PUT /api/dashboard/:id` with the full
dashcards array — no changes needed to `parameter_mappings`, `click_behavior`, or SQL:

```python
d = api('GET', f'/api/dashboard/{DASH_ID}')
by_card_id = {dc['card_id']: dc for dc in d['dashcards']}
new_order = [id_a, id_b, id_c]  # desired card_id order for the detail section
row = START_ROW
reordered = []
for card_id in new_order:
    dc = {k: v for k, v in by_card_id[card_id].items()
          if k not in ('card', 'created_at', 'updated_at', 'entity_id', 'dashboard_id')}
    dc['row'] = row
    reordered.append(dc)
    row += dc['size_y']
others = [dc for dc in d['dashcards'] if dc['card_id'] not in new_order]
api('PUT', f'/api/dashboard/{DASH_ID}', {"dashcards": others + reordered, "parameters": d['parameters']})
```

Remember the "PUT wipes parameters" pitfall above — always re-include `parameters` in this same
payload. Verify by re-GETting and checking `row` values sorted ascending match the intended order.

## `terminal` Env Exports Do Not Reach `execute_code`

`terminal(command="export MB_API_KEY=...")` only persists for later `terminal()` calls in the
same session — `execute_code` runs in a separate sandbox process and raises `KeyError` on
`os.environ['MB_API_KEY']` even immediately after a successful export in `terminal`. When
scripting Metabase API calls end-to-end: either (a) do the whole curl+parse chain inside
`terminal()` (re-export the var in the same call if it looks like a fresh shell), writing
intermediate JSON payloads to files and piping through `python3 -c "..."` for parsing, or
(b) use `execute_code` only for pure data-shaping (building payload JSON, diffing column lists,
computing which columns to keep/drop) and hand the resulting file off to a `terminal` curl call
for the actual HTTP request. Don't assume `execute_code` inherits shell state set up earlier via
`terminal`.

## API Authentication

```bash
curl -H "x-api-key: $MB_API_KEY" "https://analytics-panel.genialcare.com.br/api/..."
```

MCP metabase tools are read-only. For creating cards/dashboards, use REST API with an API key. API key permissions are per-collection — check `can_write` on target collection.

## Read-Only Domain Investigation via the Metabase MCP (not the REST API)

When the ask is "what does <business term> mean in our data" (e.g. "what counts as a caregiver
advance-notice cancellation"), use the `mcp__metabase__*` tools for exploration — they answer
"which table/field holds this, what are its values, what does a sample look like", NOT "how do I
build a dashboard" (that's the REST API above).

### Tool parameter names — easy to get wrong (cost real rework this session)

- `search`: takes `term_queries` and/or `semantic_queries` (each an ARRAY of strings). There is
  NO `query` parameter — passing `{"query": "..."}` silently returns `{"data":[],"total_count":0}`
  every time. `term_queries` is keyword match on table/column names (reliable); `semantic_queries`
  is natural-language and often returns empty.
- `get_table`: takes `id` (integer) + flags `with-fields`, `with-related-tables`, `with-metrics`,
  etc. Returns `fields[]` whose `field_id` strings look like `"t4030-33"` (prefix `t` + table id +
  dash + index) — you need these exact strings for `query` and `get_table_field_values`.
- `get_table_field_values`: takes BOTH `id` (integer) AND `field-id` (string like `"t4030-4"`).
  The param is `field-id` (hyphenated), NOT `field_id`. Returns
  `value_metadata.field_values` (distinct values + `statistics.distinct-count`) — this is how you
  enumerate a role/enum column's possible values.
- `query`: for a table query pass `table_id` + `fields` (`[{"field_id": "t4030-1"}, ...]`) +
  `filters` (`[{"field_id": "t4030-33", "operation": "equals", "value": "caregiver"}]`) + `limit`.
  Returns `data.rows` + `cols` with `display_name`/`base_type`.

### The "computed boolean flag" trap — definitions live in core code, not Metabase

A boolean column like `cancellation_in_advance` / `in_advance` in an `fct_*` table is COMPUTED in
the backend and materialized into BigQuery — the Metabase schema carries NO threshold or rule for
it. To learn what "in advance" MEANS (the hour rule), trace into the `core` repo, not the Metabase
schema:

- `get_table_field_values` on the role column reveals the "who" enum (`caregiver`/`clinician`/
  `external_professional`/`genial`/`genial_automation`). Note `curated_requested_by_role`
  translates these to pt-BR (`caregiver` → "Família").
- The boolean's definition lives in backend config code — e.g.
  `Scheduling::Config::AdvanceCancellationConfig` → `Dto#in_advance?` with modes `day_before`
  (default: cancel date < session date) vs `hours_before` (`now <= start - N.hours`), configurable
  per location/discipline/IHP. Search `core` for the field name (`in_advance`,
  `cancellation_in_advance`) to find the use case + config class.
- A reason enum like `caregiver_did_not_attend` correlates with `in_advance=false` (absence
  recorded AFTER the session) — enumerate via `get_table_field_values` on `cancellation_reason`
  and cross-check the Rails `Enum::Scheduling::CancellationReasons` file for which reasons are
  enabled per role.

Metabase gives the WHAT (field names, role enum, boolean flag, reason enum, sample rows); the core
code gives the WHY/HOW (the threshold rule). For "what does X mean" questions, do both. Worked
example: `references/metabase-mcp-querying.md`.
