---
name: genialcare-bigquery-queries
description: Write and validate BigQuery SQL for GenialCare data.
---

# GenialCare BigQuery Queries

Author and validate BigQuery SQL queries in the `code-snippets` repository.

The `code-snippets` repo itself is summarized in the product-engineer-agent wiki at
`documentations/wiki/data/components/code-snippets.md` (structure, `bq-run.sh` environment mapping,
the `create-bq-query` skill, and the `queries/<domain>/` vs `queries/specific/<domain>/` split).
The repo is also in `config.default.yml` of product-engineer-agent, so `sync.sh` links it as
`projects/code-snippets`. Point to that wiki doc when the user asks "what is this repo / where do
queries live" rather than re-explaining from scratch.

## When to use

- Reconciling a CSV/sheet against production data, or debugging why a record/field seems absent — see `references/bq-cli-and-csv-reconciliation.md` (bq `--max_rows` silent truncation, dataset location mismatch, CSV malformation/residue detection, fix-source-not-derived workflow).
- User asks for a new SQL query or to modify an existing one
- User wants to explore what tables/columns exist in BigQuery
- User needs to join data across the GenialCare GCP projects (data-kernel, supervision, ops-data, guidance)
- User asks to test or validate a query in a specific environment
- User asks who/when a clinician completed/validated objectives ("registros de OC") — see `references/objective-actor-events.md`
- User asks why a record/objective/field seems absent from production data, or to reconcile a CSV/sheet against the system — check `documentations/initiatives/*/data/*.json` for pre-migration snapshots ("absent" often means "dropped in a migration") — see `references/migration-snapshots.md`
- A query returns a suspiciously round/truncated count, or a cross-project join errors out — see `references/bq-cli-and-cross-project-pitfalls.md`
- A BigQuery table name doesn't match the source table in `core`, or you need the de-para between them — see `references/table-provenance.md`

## Output style preferences

The user prefers lean, readable query output. When writing SELECT columns:

- **Backtick-quote every fully-qualified table name (`\`project.dataset.table\`).** GenialCare project IDs contain hyphens (`supervision-production-8f1v`, `data-kernel-production-4o7n`), so an unquoted fully-qualified name fails to parse. The user copy-pastes queries straight into `bq`, which only recognizes backticked table references — the user explicitly asked for this ("sempre mandar as queries com as tabelas entre ``"). Wrap the whole `project.dataset.table` path in backticks in every query you hand back, not just the examples in this skill.
- **No alias prefixes** — use `code`, `domain`, `subdomain`, not `pi_code`, `pi_domain`, `pi_subdomain`. The user explicitly asked to remove `pi_` prefixes.
- **No IDs** — don't include internal IDs (`library_objective_id`, `objective_id`, `ecc.id`, etc.) unless the user specifically asks for them.
- **No `objective_order`** — not needed unless explicitly requested.
- **Minimal columns** — only include what the user asked for. Don't add extra columns "just in case."
- **Use the active-clinical-cases CTE only when clinical-case-level data is needed.** If the user wants library-level / protocol-level data only (not per-case), skip `active_clinical_cases` and query `library_objectives` directly — but remember the tenant filter (see Multi-tenant duplication pitfall).

## Workflow

1. **Gather context first.** Read `queries/README.md` for the repo's example-vs-specific convention, then read existing queries under `queries/<domain>/` (generic examples) and `queries/specific/<domain>/` (one-off queries with real case numbers/emails) to understand established patterns, table names, and join chains before writing anything new. Read `queries/<domain>/CLAUDE.md` if present — it carries domain-specific schema notes and pitfalls the general skill below doesn't repeat. Use `search_files` to find queries referencing relevant tables or domains.

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

4. **Filter by discipline via protocol name.** Disciplines are identified by the `protocols.name` column, but the mapping is **discipline → multiple protocols**, not 1:1:
   - `Fonoaudiologia` → Fono
   - **TO (occupational_therapy) → TWO protocols: `Ocupacional` AND `Integração Sensorial`.** Filtering only `p.name = 'Ocupacional'` silently undercounts — most "validated"/"in_maintenance" TO objectives in production live in `Integração Sensorial`, not `Ocupacional`. Note: NOT "Terapia Ocupacional" — that string doesn't exist in the `protocols` table at all (it's the discipline's display label elsewhere in `core`).
   - `Vineland 3` → Psico (also the PEI Track's base protocol — appears for other disciplines too, don't treat "Vineland 3" as Psico-exclusive without checking).

   Add `AND p.name IN (...)` (plural!) to the join/filter on `protocols` — never assume a discipline maps to a single protocol name without checking.

   **Don't guess the protocol list from a name pattern.** Confirm it two ways before writing the filter: (a) grep `core` for the discipline's `evolution_check_rule` / specialization mapping (e.g. `core/packs/clinical/app/concepts/intervention/pei/use_cases/get_objectives.rb`), which lists ALL protocol names Rails considers part of that discipline; (b) cross-check against the `support_objective_id` side of any curated mapper table for that discipline (e.g. `pei_track_to_occupational_therapy_objectives`) — every mapped objective's protocol should be in your filter list, and nothing outside it. If the Rails-code list mentions a protocol name that doesn't exist in `protocols` (e.g. "Terapia Ocupacional", "Vineland 3" as a TO-exclusive concept), drop it — trust what's actually in the table.

5. **Write the query file** under the right location — decide per `queries/README.md`:
   - Generic, reusable pattern (no hardcoded case number/email/date) → `queries/<domain>/<descriptive-name>.sql`. This is the copy-paste reference for future asks — keep it clean of business-specific values.
   - Specific, one-off request (real case number, real clinician email/name, a literal date range) → `queries/specific/<domain>/<descriptive-name-with-identifier>.sql`, with the identifying detail in the filename (e.g. `sessions-by-clinician-case-919-clinician-2025-07.sql`).
   - If a specific request reveals a pattern with no generic example yet, save BOTH: the specific version under `specific/`, and a generalized version (hardcoded values replaced with a commented placeholder) under the domain root — so the next similar ask has something to copy.
   - If a generic example already exists but is stale (schema changed, missing a column, outdated active-cases filter), update it as part of the task rather than only saving the specific version.
   Match the style of neighboring files (header comment, CTE structure, column aliases, ORDER BY). Use `write_file`. **If the domain has a `CLAUDE.md` and this task surfaced a new pitfall, a schema fact it got wrong, or a business rule it didn't cover, updating that `CLAUDE.md` is part of the task, not optional** — the same standard as the "Pitfalls" section below: undocumented traps get rediscovered by the next agent at full cost.

6. **Validate by running.** Always run the query with `bq query` before considering the task done:
   ```sh
   bq query --use_legacy_sql=false --format=prettyjson < queries/<domain>/<file>.sql
   ```
   For a specific environment, use `bq-run.sh`:
   ```sh
   ./bq-run.sh --env staging queries/<domain>/<file>.sql
   ```
   If `bq-run.sh` itself misbehaves while running this step (wrong flag parsing, a missing/renamed GCP project ID substitution, a new environment not covered) — that's a real bug in shared infrastructure, not a query problem. Fix `bq-run.sh` directly and tell the user what changed; don't route around it with a one-off `sed`/manual substitution that hides the gap for the next person.

7. **Feed the skill back.** If this task revealed something this skill got wrong, missed, or a step that would have saved rework had it been here — patch this SKILL.md before finishing, per the standing Hermes rule (skills found stale during use get corrected immediately, not deferred). This applies whether the gap was in the workflow steps, a join chain, or a pitfall.

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

### Evolution checks without objective detail — join straight to sessions

If the ask only needs "was there an evolution check on this session/day" (not
which objective was assessed), skip the `objectives → objective_evolution_checks`
hop entirely — `evolution_checks.intervention_session_id` already joins directly
to `sessions.id`:

```sql
FROM clinical_cases cc
JOIN sessions s ON s.clinical_case_id = cc.id
LEFT JOIN evolution_checks ec ON ec.intervention_session_id = s.id
LEFT JOIN users u ON u.id = ec.assessed_by_id
```

Going through the full objective chain (`peis → objectives → objective_evolution_checks
→ evolution_checks`) for a question like "did clinician X register a checagem on date Y"
multiplies one row per objective assessed in the session — correct but noisy, and easy
to mistake for "5 separate checks happened" when it was one `evolution_checks` row
covering 5 objectives. Use the direct `sessions → evolution_checks` join whenever the
per-objective breakdown isn't part of the ask; only pull in `objectives`/`library_objectives`
when the user needs to know *which* objective was (or wasn't) assessed.

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

**Both `library_objectives` and `protocols`** have one row per tenant. There are 9 tenants in `datakernel.tenants`, but **only 2 have a `library_objectives` catalog** (`genialcare` and `careplus_mindplace`), so every description/protocol-name appears exactly twice.

This causes **multiplicative row explosion** when JOINing on non-tenant-keyed columns like `description`. Example: joining `library_objectives` ON `description` without a tenant filter matches BOTH tenant rows for the same description text — each source row doubles. Two such JOINs (e.g., `to_obj` and `pei_track_obj`) multiplies by 4×.

The `library_objectives` table has **497 non-discarded objectives per tenant** (994 rows total for 497 distinct descriptions, exactly 2×, one per tenant — confirmed 2026-09-01; earlier docs cited 426 distinct / 852 rows, the catalog has since grown). Same description, different `tenant_id`, different `id`, different `protocol_item_id`.

Tenant IDs (filter on `tenants.name`, which is snake_case, not the display name):
- `6f8da042-2dd1-4872-a613-84d371bde78c` → name `genialcare`, display "Genial Care"
- `a4d02a8c-4c27-41b6-80ac-3401f3964e34` → name `careplus_mindplace`, display "CarePlus MindPlace"

The other 7 tenants (`volarum`, `ser_especial`, `amanda_lemos_lopes`, `beatriz_aguilar_pena`, `dayane_de_freitas_brito`, `istefani_fernanda_brasil`, `victor_mario_facciola`) have NO `library_objectives` catalog — so a catalog-level or de-para query is effectively a 2-tenant problem even though 9 tenants exist. Note the tenant `name` for Mindplace is **`careplus_mindplace`** (NOT `mindplace`) — that's the value to pass to `WHERE t.name = ...`.

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

**Catalog-level alternative: `SELECT DISTINCT`.** When the question is about the library catalog itself (e.g. "list the objectives of protocol X"), the descriptions are identical across tenants — only the surrogate `id`/`protocol_item_id` differ. So `SELECT DISTINCT domain, subdomain, code, description` cleanly collapses the 2× tenant duplication without any tenant join. This is simpler than the tenant filter and is correct whenever you select only tenant-invariant columns. Use the explicit `tenant_id` filter instead when you need the canonical row for further JOINs or when selecting tenant-scoped columns.

### Extending a single-tenant de-para mapper (TO↔PEI Track) to a second tenant

The `occupational-therapy-mapper` pipeline (`external-table.sql` → `mapper-objective-pairs.sql`) is hardcoded to `WHERE t.name = "genialcare"`, so the output table `pei_track_to_occupational_therapy_objectives` (~7000 pairs) covers only genialcare. To produce pairs for another tenant:

1. **Reuse the same Google Sheet** — objective descriptions are identical across tenants (only the surrogate `id`/`protocol_item_id` differ), so the de-para text maps to both. No new sheet needed unless the target tenant has a genuinely different catalog.
2. **Don't just swap the tenant name** to build a second, separate table — that forks the pipeline. Generalize the final query to emit pairs for BOTH tenants at once: drop the single-tenant filter and, critically, guard the two library joins against cross-tenant pairs:
   ```sql
   INNER JOIN all_library_objectives pei_track_obj
     ON mapper_norm.pei_obj_norm = pei_track_obj.description_norm
   INNER JOIN all_library_objectives to_obj
     ON mapper_norm.to_obj_norm = to_obj.description_norm
    AND pei_track_obj.tenant_id = to_obj.tenant_id   -- prevents genialcare-PEI x mindplace-TO pairs
   ```
   Without `pei_track_obj.tenant_id = to_obj.tenant_id`, identical description text matches rows from BOTH tenants and produces cross-tenant pairs (a genialcare PEI objective paired with a mindplace TO objective).
3. The output table already carries `tenant_id`, so a single multi-tenant table (both tenants) is the natural shape — no schema change. In practice "all tenants" == exactly the 2 tenants that have a `library_objectives` catalog (see Multi-tenant duplication pitfall).
4. **Validate coverage per tenant before trusting it:** run the `missing-objectives-in-mapper.sql` diagnostic scoped to the target tenant — do NOT assume the second tenant's catalog is a superset/subset of genialcare's. A tenant missing objectives silently drops those rows in the INNER JOIN (fewer pairs, no error).
5. The `_raw` external table can't be read from the `bq` CLI without Drive scope (see Federated-tables pitfall); only the `mapper-objective-pairs.sql` step (reading the already-created `_raw`) is needed to rebuild the final table, and that still requires the Drive-credentialed account that created the `_raw`. **Verify the multi-tenant join without Drive access** by simulating the sheet source: derive the DISTINCT `(main_desc, support_desc)` text pairs from the ALREADY-materialized final table (JOIN its `main_objective_id`/`support_objective_id` back to `library_objectives.id` for the descriptions), feed those pairs into the exact new join, and assert `COUNT(*)` is 2× the single-tenant pair count with `cross_tenant_pairs = 0` per tenant (see the `SUM(IF(tenant_id != main_tenant_id, 1, 0))` probe). This proves the join logic against real data without ever reading `_raw`.

### Ad-hoc CSV-to-`library_objectives` de-para: exact match rate first, fuzzy diff second, before building a mapper table

When a user hands you a CSV meant to map external content (a spreadsheet of therapeutic
objectives, an assessment de-para, etc.) against `library_objectives`, don't jump straight
to building a BigQuery mapper table (external table + normalize UDF, see the TO mapper
pattern in `occupational-therapy-mapper/`) — first do a cheap Python-side reconnaissance
pass to characterize the gap:

1. Export the relevant `library_objectives` slice to a local CSV via `bq query --format=csv
   > /tmp/x.csv` (filtered by protocol name + `tenant.name = 'genialcare'` +
   `discarded_at IS NULL` — see the Multi-tenant duplication pitfall above).
2. Load both CSVs with Python's `csv` module (via `execute_code`, not `terminal` — you need
   real control flow) and normalize both sides identically: `' '.join(s.strip().lower().split())`.
3. Report the **exact-match rate** first (e.g. "88/107 = 82%"). This number alone tells you
   whether the mismatch is a text-normalization problem (near-100% match expected after
   fixing quotes/whitespace) or a **real content gap** (the source CSV references objectives
   that don't exist in the system's library yet — a product/data problem, not a matching bug).
4. For the unmatched rows, run `difflib.get_close_matches(target, candidates, cutoff=0.55)`
   to separate "same objective, minor wording diff" (worth normalizing) from "genuinely
   absent from the system" (worth flagging as a gap to the user, not silently mapping to the
   nearest-looking-but-wrong objective). A `difflib` score above ~0.55 on phoneme/config
   drill patterns (e.g. "Produz o fonema /b/ ... Monossílabos") can still be a **false
   friend** — a different phoneme entirely, not a near-match — so eyeball every suggestion
   before trusting it, don't auto-accept anything above a threshold.

   **Sharper trap confirmed (2026-08-24): plain top-N fuzzy match can hide the correct
   candidate entirely, not just rank it wrong.** On a drill-pattern catalog (same sentence
   template, one token varying — e.g. "Produz o fonema /X/ em ... Monossílabos ..."),
   dozens of wrong-phoneme candidates all score ~0.99 similarity because only 1-2 characters
   differ from the target, while the actual near-duplicate (same phoneme, minor punctuation
   difference — e.g. system has `"Monossílabos (CV, VCV)"` missing the `"VV, "` the CSV has)
   scores identically or even lower and gets pushed out of `get_close_matches(n=3)`'s
   top-3 window by unrelated same-score matches. Two "unmatched" objectives were actually
   present, just correctly-phonemed near-duplicates buried by false friends.
   **Fix: don't trust top-N fuzzy ranking alone on drill-pattern text.** Extract the
   invariant token (phoneme, code, ID — via regex) from the target, filter system
   candidates to that SAME token first, then compare only within that filtered set:
   ```python
   import re
   def extract_phoneme(text):
       m = re.search(r'/[^/]+/(?:, /[^/]+/)?', text)
       return m.group(0) if m else None
   phon = extract_phoneme(target)
   same_phoneme_candidates = [c for c in candidates if phon and phon in c]
   ```
   Only fall back to whole-corpus fuzzy ranking when the token-filtered set is empty —
   that's the signal the row is genuinely absent, not just poorly ranked.
5. Only after this reconnaissance confirms the CSV is a genuine mapper source (not just a
   few normalization issues) is it worth building the full BigQuery external-table + UDF
   pipeline from the TO mapper pattern.

### `JSON`-typed columns don't need `TO_JSON_STRING()` before `JSON_VALUE()` — check `INFORMATION_SCHEMA.COLUMNS`, don't infer from the Rails `jsonb` declaration

Assessment sub-tables with checkbox/array-ish fields (e.g. `harmful_oral_habits`, `clinical_referrals` on `orofacial_myology_assessments`; the six `uses_*` fields on `expressive_communication_features`) are declared `attribute :foo, :jsonb` in Rails. That doesn't guarantee the BigQuery replica column is `STRING` (serialized JSON needing `TO_JSON_STRING(col)` before `JSON_VALUE(..., '$.path')`) — confirmed twice (2026-08-24) that these land as native BigQuery `JSON` type, so `JSON_VALUE(col, '$.checked')` works directly. Wrapping in `TO_JSON_STRING()` first still runs (harmless, redundant) — the mistake doesn't surface as a syntax error, only as unnecessary complexity a reviewer has to untangle.

**Rule:** before writing any `JSON_VALUE`/`JSON_QUERY` extraction on a Rails-jsonb-backed field, run `SELECT column_name, data_type FROM \`<dataset>.INFORMATION_SCHEMA.COLUMNS\` WHERE table_name = '<table>'` to confirm the actual BigQuery type instead of assuming from the ActiveRecord type.

### Resolving assessment field semantics — cross-reference `core` Rails models with `clinical-panel` i18n JSON, not schema alone

BigQuery/schema column names for assessment sub-tables (e.g.
`assessment_speech_therapy_general_speech_motor_controls.limited_speech_movement_range`)
are enum keys, not the clinical language a CSV or a clinician uses (e.g. "Uma variedade
limitada de movimentos da fala"). To build a de-para between free-text clinical items and
real DB fields, you need BOTH:

1. **`core`** (`packs/clinical/app/models/assessments/**/*.rb`) for the actual model/column
   names, `belongs_to`/`has_one` relationships, and any enum class under
   `packs/clinical/app/models/assessments/enum/*.rb` (e.g.
   `PhonologicalAtypicalProcessNames` — short codes like `rs`, `hc`, `pf` with a
   `MAX_OCCURRENCES` reference map).
2. **`clinical-panel`** i18n JSON (`src/i18n/locales/<domain>/pt-br.json`) for the
   human-readable label/description of each field and enum value — this is the text that
   actually appears in the CSV or that a clinician would type. Also check
   `src/constants/*.tsx` for hardcoded lookup tables the JSON doesn't cover (e.g.
   `atypicalProcesses.tsx` has the `fullname` for each phonological process code, and the
   JSON's own label can differ slightly from it — e.g. "Harmonia Consonantal" in a CSV vs
   "Harmonização Consonantal" in `atypicalProcesses.tsx`, same concept, different wording).

Search order that works: grep `core` for the model/enum first (to know what fields exist
at all), then grep `clinical-panel` i18n JSON for the same key names to get the label text,
then cross-check `constants/*.tsx` for any enum whose canonical labels live outside i18n.
Skipping the i18n/constants step and trying to guess field meaning from column names alone
will misattribute items whenever the DB enum value (`sfv`) doesn't visually resemble the
clinical term ("Simplificação da Fricativa Velar").

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

### Session change history — query CDC `sessions_events`, not the sessions tables

`datakernel.sessions` and `scheduling.sessions` are **full-load snapshots** (current state
only) — you cannot see that a session was "cancelled then reactivated" from them. To trace
the change history of a session (cancellation / re-creation / reactivation), query the CDC
table `data-kernel-production-4o7n.raw.sessions_events` (one row per change:
`payload.record` + `source_metadata.change_type` = `INSERT`/`UPDATE`/`DELETE` +
`source_timestamp`; order by `source_timestamp`).

Critical gotchas (see `references/session-change-history.md` for the full worked example):

- **`events.session_cancelled` is stale** — it stopped being populated after 2025-04-07,
  so an empty result for a recent cancellation does NOT mean "no cancellation happened".
  Use the CDC table instead. `events.session_scheduled` IS still current.
- **Two different session ids**: `datakernel.sessions.id` (domain id) ≠
  `scheduling.sessions.id` (operational id), linked by `sessions.scheduling_session_id`.
  In CDC, `payload.id` = datakernel id, `payload.operational_scheduling_session_id` =
  scheduling id. Querying `scheduling.sessions` with a datakernel id returns `[]`.
- **"Was the clinician consulted?"** → `scheduling.sessions.confirmations` (repeated
  record: `role`, `user_id`, `confirmed_at`, `source`). A `role='therapist'` entry with
  `source='whatsapp'` proves they replied to a WhatsApp confirmation — which weakens a
  "sem me consultarem" claim.
- **Who cancelled?** → `payload.cancellation.requested_by_role` (`caregiver` vs
  `clinician`) and `in_advance` (`true`/`false`). `in_advance=false` is the
  "cancelamento sem aviso" flag that penalizes the clinician in the panel.
- **Actor names** come from `datakernel.users` (`email`, `first_name`, `last_name` — no
  `name` column) or `datakernel.clinicians` (`user_email`, `name`, `user_id` — no `email`
  column).
- **Timestamps are UTC**; Brazil is UTC-3. A `cancelled_at` of `2026-08-31 00:04` UTC is
  `2026-08-30 ~21:04` BRT — so a "cancelled Sunday 30/08" claim is correct. But
  `start_scheduled_at` is wall-clock (17:00 = 5pm local) — don't shift it.

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

For quick inline queries, use the `python3 -c` one-liner pattern (faster than `<< 'PYEOF'` heredocs, avoids issues with `&` and other shell-special characters in output):

```sh
python3 -c "
from google.cloud import bigquery
client = bigquery.Client(project='supervision-production-8f1v')
for row in client.query('''SELECT ... FROM ... LIMIT 10'''):
    print(f'{row.col1}, {row.col2}')
"
```

For multi-line queries with complex formatting, pipe from a file:
```sh
python3 -c "
from google.cloud import bigquery
client = bigquery.Client(project='supervision-production-8f1v')
with open('queries/my-query.sql') as f:
    for row in client.query(f.read()):
        print(f'{row.col1}, {row.col2}')
"
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

### BigQuery table names drop Rails model prefixes

Rails models declare `self.table_name` with prefixes (e.g. `intervention_library_evolution_check_configurations`), but BigQuery table names in the `intervention` dataset strip these prefixes. Examples:

| Rails `table_name` | BQ table |
|---|---|
| `intervention_library_evolution_check_configurations` | `evolution_check_configurations` |
| `intervention_library_objectives` | `library_objectives` |
| `intervention_protocol_items` | `protocol_items` |
| `intervention_protocols` | `protocols` |
| `intervention_evolution_checks` | `evolution_checks` |
| `intervention_objective_evolution_checks` | `objective_evolution_checks` |

**Pattern:** the `intervention_` prefix is always dropped. The `library_` sub-prefix (for library-level config tables) is also dropped. When in doubt, list tables with `INFORMATION_SCHEMA` rather than guessing.

### `bq-run.sh` flag syntax — space-separated, not `=` syntax

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

### `bq query --format=table` is NOT a valid value

The `bq query` CLI accepts only these `--format` values: `none|json|prettyjson|csv|sparse|pretty`. There is **no `table`** — passing `--format=table` fails with:

```
FATAL Flags parsing error: flag --format=table: value should be one of <none|json|prettyjson|csv|sparse|pretty>
```

Table output is the **default**: to get a table, just omit `--format` entirely (`bq query --use_legacy_sql=false '<sql>'`). Reserve `--format` only for `json`/`prettyjson`/`csv` when you actually need those shapes.

### `agreement_id` is a dead-end FK in BigQuery

Some assessment tables (e.g. `copm_forms`) have an `agreement_id` column that references the Rails `Agreement` model. **There is no `agreements` table in any GenialCare GCP project.** The UUID does not match `clinical_cases.id`, `clinical_case_disciplines.id`, or any other known table. To link assessment data back to a clinical case, use indirect paths: `tenant_id` + `submitted_by_id` → `users`, or time-window correlation with sessions. See `references/assessment-schema.md` for the COPM example.

### Validate a RAW/analysis query against real production data before trusting it

When building a "RAW data" query meant to feed multiple derived metrics (e.g. a Metabase Model), don't stop at "it runs without error" — an empty or suspiciously-small result set from a JOIN/filter chain that "looks right" is a real signal, not noise. Steps that catch wrong assumptions early:

1. Run a `COUNT(*)` / `COUNTIF(...)` summary CTE wrapped around the RAW query (`WITH raw_query AS (<the whole query>) SELECT COUNT(*), COUNTIF(<flag>), ...`) instead of eyeballing raw rows.
2. If a filter (protocol name, status, discipline) returns zero rows where you expected many, that's the strongest signal you have the wrong literal values — go re-derive them from `core` business logic (grep the Rails use case / enum that defines the mapping) rather than adjusting the filter by trial and error.
3. Pick ONE concrete entity (a clinical case number, a user id) that the query touches, and manually trace it end-to-end — group the RAW rows for that one entity and check the aggregation logic produces the expected classification by hand. This is cheap and catches both "empty result" bugs and subtler "wrong boolean logic" bugs that a COUNT alone won't reveal.
4. Re-run the same COUNT/invariant check after any edit to the query file to confirm you haven't introduced a regression — compare against the previously recorded numbers.

### Bulk dry-run validation of many SQL files — run in background, not a foreground loop

When auditing/reorganizing a whole `queries/` tree (e.g. after a repo-wide reorg), validating every file's syntax with `sed 's/--.*//' file.sql | bq query --dry_run` is the right check, but each `bq` CLI invocation takes ~5-8s (auth + startup), so a loop over 80+ files exceeds the foreground command timeout even though each individual call succeeds. Run the loop via `terminal(background=true, notify_on_complete=true)` with a per-file `timeout` guard inside the script, then poll/wait in multiple rounds instead of expecting one foreground call to finish. A `zsh` login-shell prompt-theme banner (`stty: stdin isn't a terminal`, `Usage: prompt <options>`) printed at the start of background output is a harmless side effect of shell init, not a script failure — check the tail of the log for the actual `FAIL:`/`total=`/`fail=` lines.

### `specific/` queries contain PII (emails, names) — gitignore only covers new files

`queries/specific/<domain>/` files routinely hardcode real emails/names (that's
the point — they're per-request investigations). The user raised this as a PII
concern; the resolution adopted was to add `queries/specific/**` to `.gitignore`
so *future* specific queries aren't committed, while leaving already-tracked
`specific/` files alone (`.gitignore` has no effect on files already tracked by
git — it doesn't remove them from the working tree, the index, or history).
This was a deliberate compromise, not a full redaction: the repo's `README.md`
documents `specific/` as an intentional audit trail, and un-tracking 26
already-committed files (`git rm --cached`) or scrubbing history was explicitly
NOT what the user asked for. If a future request wants to also stop tracking
already-committed files or scrub PII from history, treat that as a separate,
explicit ask — don't assume the `.gitignore` addition covers it.

### `queries/` repo structure: generic examples vs one-off specific queries

The `code-snippets` repo's `queries/` tree follows an examples-vs-specific split (documented in `queries/README.md`): `queries/<domain>/` holds generic, reusable queries with NO hardcoded business values (case numbers, emails, literal dates) — this is the copy-paste reference future agents use. `queries/specific/<domain>/` holds one-off queries with real values hardcoded for a single past request, named with the identifying detail in the filename (e.g. `sessions-by-clinician-case-919-clinician-2025-07.sql`). When resolving a new specific request: (1) check if a generic example already covers the pattern and adapt it; (2) if not, solve the request, then also generalize it into `queries/<domain>/` so the pattern isn't lost; (3) if an existing generic example is stale (schema changed, missing a column, outdated active-cases filter), fix it in place rather than only saving a new specific variant. Many domain folders also carry a `queries/<domain>/CLAUDE.md` with schema notes/pitfalls too narrow for this skill — read it before writing a new query in that domain, and consider adding to it when a new pitfall surfaces.

### `bq` row cap defaults to 100 — looks like "no data" but isn't

`bq query --format=csv` (and other formats) silently caps output at 100 rows by default (`--max_rows` / `-n`, default `'100'`). A query that actually returns 900+ rows will print only 100 with no warning, easily misread as "the join returned almost nothing." Always pass `--max_rows=<big number>` when counting/inspecting row volume, or better, wrap the query in a `COUNT(*)` summary query so row-cap truncation can't hide the real total.

**Sharper trap: the truncation can look like a *plausible* dataset, not an obviously-cut one.** Confirmed 2026-08-24: a library-objectives-by-protocol query returned exactly 100 rows (the cap) with an `ORDER BY subdomain, code` — the missing 11 rows were a contiguous block sorted to the end, silently dropped. The visible 100 rows still spanned multiple real subdomains and looked like a complete, reasonable catalog (not a suspiciously round "too clean" number in context) — nothing about the output screamed "truncated." This led to a false "objective X doesn't exist in the system" conclusion (a whole subdomain, `system_communication`, was entirely missing from the visible rows), which was only caught because the user asked "how many objectives are there, exactly?" and a plain `SELECT COUNT(*)` disagreed with the row count actually printed.

**Rule: before using a row-limited `bq query` result to draw any negative/completeness conclusion** ("this objective doesn't exist", "this table has no matching rows", "here's the full list of X") — run `SELECT COUNT(*)` first (wrapping the query if needed: `SELECT COUNT(*) FROM (<query>)`) and confirm it matches the number of rows you actually got back. Do this even when the visible result "looks complete" — a truncated result with an `ORDER BY` can look exactly like a smaller-but-real dataset.

### `bq query` positional SQL argument breaks on multi-line queries

Passing the whole query as `bq query "$(cat file.sql)"` or as a positional string argument fails with `FATAL Flags parsing error: Unknown command line flag ' '` when the SQL has newlines/leading whitespace after shell expansion. Always redirect from a file instead: `bq query --use_legacy_sql=false --format=csv < file.sql`. (This is on top of the existing `--` comment-stripping pitfall below — both apply to inline/positional SQL.)

### Metabase MCP tools only load in a session started AFTER `hermes mcp login`

If `hermes mcp test metabase` (or any MCP server) reports "Connected" with N tools discovered, but `tool_search`/`tool_call` in the CURRENT session can't find them, the tools were registered after this session's tool index was built. Logging in mid-session does not hot-reload the tool list. Fix: finish current investigation work, then continue Metabase-dependent steps (creating questions/dashboards) in a fresh Hermes session — don't waste retries calling `tool_search` again in the same session expecting it to appear.

### Metabase BQ service account sees different row counts than `gcloud` CLI

The Metabase BigQuery connection (database 4 = `supervision-production-big-query`) uses a service account with project `meta-production-2a6b` as the billing project. This service account can see **fewer rows** than the user's `gcloud` CLI auth in certain tables — confirmed on `ops-data-production-8fk2.aggregates.children` (Metabase: 1564 rows, bq CLI: 1734 rows) and `data-kernel-production-4o7n.datakernel.clinical_cases` (Metabase: 985 active OT cases, bq CLI: 1149).

This is NOT a row limit, NOT a query bug, and NOT a filter difference. It's a **data access permission gap** between the service account and the user's personal gcloud credentials. The numbers are non-round (743 vs 842), which rules out a Metabase row cap.

**Detection pattern:** when a query returns fewer rows in Metabase than via `bq` CLI with the exact same SQL:
1. Strip the query down to a single table `COUNT(*)` (no JOINs) and compare bq CLI vs Metabase `/api/dataset`.
2. If the counts differ on a bare table, it's a service account permission issue, not your SQL.
3. **Confirm tenant scoping:** run `SELECT cc.tenant_id, COUNT(DISTINCT cc.id) FROM ... GROUP BY cc.tenant_id` via both bq CLI and Metabase — if Metabase returns only one tenant_id while bq CLI returns multiple, the service account is tenant-scoped.
4. If the counts match on every individual table but differ after a JOIN, it's the implicit INNER JOIN pattern (next pitfall).

**Confirmed root cause (2026-08-13):** the Metabase service account is **tenant-scoped to `genialcare` only**. The user's `gcloud` CLI sees all 6 tenants (genialcare, volarum, ser_especial, careplus_mindplace, + 2 small ones). Confirmed by comparing `SELECT cc.tenant_id, COUNT(DISTINCT cc.id)` — Metabase returns only `6f8da042-...` (genialcare, 985 cases) while bq CLI returns all 6 tenant_ids (1149 total). This is NOT a bug — it's the intended permission boundary.

When this is the cause, the numbers will be non-round and consistent across queries (e.g. 743 vs 842 active OT cases after children join). The user may already know about this scoping — confirm with them before investigating further.

**Fix options:**
- Accept the tenant-scoped count as correct for the Metabase dashboard (the user confirmed this is fine).
- Ask the user to grant the service account cross-tenant access in GCP if multi-tenant dashboards are needed.
- Move filters that depend on the restricted table from `WHERE` to the `JOIN ON` condition, so cases missing from the service account's view still appear (may include stale/churned cases — document the tradeoff).
- Accept the lower count and document it as a known limitation in the dashboard.

### `children` table has multiple rows per `clinical_case_id` — deduplicate in GROUP BY

The `ops-data-production-8fk2.aggregates.children` table has **multiple rows per `clinical_case_id`** (different owners, locations, or historical records over time). When you JOIN on it and then GROUP BY in a derived CTE, including owner_name/location_name in the GROUP BY creates **duplicate case rows** — e.g. case 26 appeared 4 times (4 different owner/location combinations), inflating 842 distinct cases to 900 rows.

**Fix:** in any CTE that aggregates to case level, GROUP BY only `clinical_case_number` (or `clinical_case_id`), and use `ANY_VALUE()` for dimension columns (owner_name, location_name, tenant_name) that you want to keep but don't need to deduplicate on:

```sql
-- WRONG — duplicates cases when children has multiple rows per case
case_level AS (
  SELECT clinical_case_number, clinical_case_owner_name, location_name, ...
  FROM objective_level
  GROUP BY clinical_case_number, clinical_case_owner_name, location_name
)

-- CORRECT — one row per case, pick any value for dimensions
case_level AS (
  SELECT
    clinical_case_number,
    ANY_VALUE(clinical_case_owner_name) AS clinical_case_owner_name,
    ANY_VALUE(location_name) AS location_name,
    MAX(has_active_to_objectives) AS has_active_to_objectives,
    ...
  FROM objective_level
  GROUP BY clinical_case_number
)
```

**Detection:** if `COUNT(*)` > `COUNT(DISTINCT clinical_case_number)` in your result, you have this bug. Run `SELECT clinical_case_number, COUNT(*) ... GROUP BY ... HAVING COUNT(*) > 1` to see the duplicated cases.

### LEFT JOIN + WHERE on joined table = implicit INNER JOIN

When you `LEFT JOIN` table B and then filter `WHERE b.col IS NULL` or `WHERE b.col = <value>`, the LEFT JOIN effectively becomes an INNER JOIN: rows from table A without a match in B are excluded (because `NULL IS NULL` passes, but `NULL = <value>` fails, and even `NULL IS NULL` filters out non-null mismatches). This silently drops cases.

**Pattern that bites:**
```sql
-- WRONG — cases without a children record are silently excluded
LEFT JOIN children_data ch ON ch.clinical_case_id = cc.id
WHERE ...
  AND ch.churned_at IS NULL       -- filters out cases with no children row
  AND ch.on_hold IS NOT TRUE      -- same
```

**Fix — move the filter to the JOIN condition:**
```sql
-- CORRECT — cases without a children record still appear (ch.* columns are NULL)
LEFT JOIN children_data ch ON ch.clinical_case_id = cc.id
  AND ch.churned_at IS NULL
  AND ch.on_hold IS NOT TRUE
WHERE ...
  -- no ch. filters here
```

This is especially dangerous when combined with the service account permission gap above: cases that the service account can't see in `children` are silently excluded, making the row count difference look like a filter issue rather than a data access issue.

**Debugging checklist when Metabase row count < bq CLI row count:**
1. Run the same SQL via both `bq` CLI and Metabase `/api/dataset` — confirm they differ.
2. Strip JOINs one by one, comparing counts at each step.
3. For each JOIN, check if any `WHERE` clause references the joined table's columns.
4. Move those conditions to the `ON` clause and re-test.

### Metabase MCP tools are READ-ONLY — use REST API for creating artifacts

The Metabase MCP OAuth scopes are: `agent:table:read`, `agent:metric:read`, `agent:search`, `agent:query:construct`, `agent:query`, `agent:query:execute`. There are **no write scopes** — you cannot create cards, models, dashboards, or collections via MCP. The 8 MCP tools (`search`, `query`, `execute_query`, `construct_query`, `get_table`, `get_metric`, `get_table_field_values`, `get_metric_field_values`) are all read-only.

**To create Metabase artifacts (cards/questions, dashboards, models):** use the Metabase REST API with an API Key:

```sh
# Auth via x-api-key header (NOT Bearer, NOT X-Metabase-Key)
curl -s -H "x-api-key: mb_YOUR_KEY" \
  -X POST -H "Content-Type: application/json" \
  -d '{"name":"My Question","display":"table","dataset_query":{...},"database":4,"collection_id":766,"visualization_settings":{}}' \
  "https://analytics-panel.genialcare.com.br/api/card"
```

**API Key permissions pitfall:** the API Key inherits the permissions of the user/group it belongs to. A key created by a non-admin user will get `403 "Você não tem permissão para fazer isso."` on collections that user can't access. Before creating artifacts, check which collections the key can write to:

```sh
curl -s -H "x-api-key: mb_YOUR_KEY" \
  "https://analytics-panel.genialcare.com.br/api/collection" -o /tmp/mb_cols.json
# Then parse for can_write=true
```

If the target collection (e.g. 773) is not writable, either: (a) ask the user to grant the API Key's group access to that collection in Metabase Admin > Permissions, or (b) create artifacts in a writable collection and ask the user to move them.

**Hermes security scan blocks `curl | python3`:** piping `curl` output directly into `python3 -c` triggers a HIGH severity block. Save to a temp file first, then parse:

```sh
# WRONG — blocked by security scan
curl -s -H "x-api-key: $KEY" "$URL" | python3 -c "import sys,json; ..."

# CORRECT — save then parse
curl -s -H "x-api-key: $KEY" "$URL" -o /tmp/mb_result.json
python3 -c "import json; d=json.load(open('/tmp/mb_result.json')); ..."
```

**Metabase REST API endpoints for dashboard creation:**
- `POST /api/card` — create a question (Native Query or GUI query)
- `POST /api/dashboard` — create a dashboard
- `PUT /api/dashboard/:id` — add cards/parameters to a dashboard
- `POST /api/card/:id/query` — execute a card's query (test results)
- `GET /api/collection/:id/items` — list items in a collection
- `GET /api/database` — list available databases (need database_id for Native Queries)

**Adding cards to a dashboard via PUT /api/dashboard/:id:**
The `PUT` replaces the entire `dashcards` array, so you must send ALL cards in one call. Each new card needs a **unique negative ID** (`-1`, `-2`, `-3`, ...) — using the same negative ID for multiple cards causes `400 "nullable valor deve ser uma sequência de mapas nos quais ids são únicos"`:

```json
{
  "dashcards": [
    {"id": -1, "card_id": 123, "size_x": 12, "size_y": 8, "row": 0, "col": 0, "parameter_mappings": [], "visualization_settings": {}},
    {"id": -2, "card_id": 124, "size_x": 6, "size_y": 5, "row": 8, "col": 0, "parameter_mappings": [], "visualization_settings": {}}
  ]
}
```

The `POST /api/dashboard/:id/dashcards` endpoint does NOT exist in Metabase v0.60 (returns 404 "O endpoint da API não existe"). Use `PUT /api/dashboard/:id` with the `dashcards` key (not `ordered_cards`).

**MBQL cards referencing a RAW via `source-card` (single-source-of-truth pattern):**

The user explicitly corrected this: "Eu tinha pedido para que todas as questions do dash fossem baseadas na mesma RAW Data. Ou seja, dado o raw data, eu o referencio para criar as questions." Instead of duplicating SQL across multiple Native Query cards, create ONE Native Query (the RAW) and derive all other cards as MBQL (`query_type: "query"`) cards that reference it via `source-card` in the stage. This way, if the SQL needs to change, you change it in ONE place and all derived questions reflect the change. This is the pattern used in the Psico dashboard (261): card 7140 is the only Native SQL, and cards 7148, 7146, 7210 are all `query_type: "query"` with `"source-card": 7140`.

**Creating MBQL cards via REST API:**

MBQL cards need a different JSON structure than Native Query cards. Key differences:
- `"query_type": "query"` at the card level (not `"native"`)
- `"database_id": 4` at the CARD level (not just inside `dataset_query`)
- `"lib/type": "mbql/query"` at the `dataset_query` level
- `"lib/type": "mbql.stage/mbql"` at the stage level
- `"source-card": <RAW_CARD_ID>` in the stage (references the RAW)
- **Do NOT include `"filters": []`** — an empty filters array causes `should have at least 1 elements`. Omit the key entirely if there are no filters.
- `"aggregation"` and `"breakout"` use MBQL field references: `["field", {"base-type": "type/Text", "lib/uuid": "<uuid>"}, "column_name"]`

```json
{
  "name": "My Derived Card",
  "display": "table",
  "collection_id": 773,
  "query_type": "query",
  "database_id": 4,
  "dataset_query": {
    "lib/type": "mbql/query",
    "database": 4,
    "stages": [{
      "lib/type": "mbql.stage/mbql",
      "source-card": 8137,
      "aggregation": [["count", {"lib/uuid": "<uuid>"}]],
      "breakout": [
        ["field", {"base-type": "type/Integer", "lib/uuid": "<uuid>"}, "clinical_case_number"],
        ["field", {"base-type": "type/Text", "lib/uuid": "<uuid>"}, "aderencia_status"]
      ],
      "limit": 10000
    }]
  },
  "visualization_settings": {}
}
```

The RAW card must include all columns the derived cards need (including computed columns like `aderencia_status`). If the RAW uses window functions or subqueries to compute case-level columns, see the window function pitfall below.

**Adding computed case-level columns to a RAW for MBQL consumption:**

When MBQL cards need case-level aggregations (e.g. `aderencia_status` computed from objective-level rows), add them to the RAW SQL. Window functions in the same SELECT can't reference other SELECT aliases (see pitfall below), so wrap the RAW in an outer query:

```sql
WITH raw_data AS (
  <original RAW query with all columns including is_pair_adherent, has_active_to_objectives>
),
case_adherence AS (
  SELECT
    clinical_case_number,
    MAX(has_active_to_objectives) AS has_active_to_objectives,
    CASE
      WHEN MAX(has_active_to_objectives) IS NOT TRUE THEN NULL
      WHEN LOGICAL_AND(COALESCE(objective_adherent, FALSE)) THEN TRUE
      ELSE FALSE
    END AS is_case_adherent,
    CASE
      WHEN MAX(has_active_to_objectives) IS NOT TRUE THEN 'Sem objetivos ativos de TO'
      WHEN LOGICAL_AND(COALESCE(objective_adherent, FALSE)) THEN 'Aderente'
      ELSE 'Não Aderente'
    END AS aderencia_status
  FROM (
    SELECT
      clinical_case_number,
      to_objective_id,
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
SELECT r.*,
  ca.is_case_adherent,
  ca.aderencia_status
FROM raw_data r
LEFT JOIN case_adherence ca ON ca.clinical_case_number = r.clinical_case_number
WHERE 1=1
  [[AND r.clinical_case_number = {{caso}}]]
  [[AND r.og_to_name = {{og_to}}]]
  [[AND r.location_name = {{unidade}}]]
ORDER BY r.clinical_case_number, r.to_objective_description, r.pei_track_module_name
```

The two-level aggregation (objective → case) is required because `LOGICAL_AND` over raw rows with fan-out (multiple pei_track_items per objective) produces wrong results — it treats each item row as a separate objective.

**Cross-project BigQuery queries work in Metabase:** a Native Query running on database 4 (`supervision-production-big-query`) can access tables in other GCP projects (`data-kernel-production-4o7n`, `ops-data-production-8fk2`) via fully-qualified table names, as long as the service account has access. Confirmed working in Metabase v0.60.3.

**Metabase Native Query template-tags for dashboard filters (drill-down):**

Creating working filter connections between dashboard parameters and Native SQL questions requires a specific combination of SQL syntax, template-tag type, and parameter_mapping target. The wrong combination silently returns all rows (filter ignored) or errors.

1. **SQL syntax — `[[AND column = {{tag}}]]` (optional clauses):**
   ```sql
   -- In the Native Query's final SELECT:
   WHERE 1=1
     [[AND clinical_case_number = {{caso}}]]
     [[AND owner = {{terapeuta}}]]
   ```
   The `[[ ]]` makes the clause optional — included only when the dashboard parameter has a value. Without `[[ ]]`, Metabase requires all parameters on every API call.

2. **Template-tag type — `number` or `text` (NOT `dimension`, NOT `string`):**
   ```json
   {"caso": {"id": "caso", "name": "caso", "display-name": "Caso", "type": "number", "required": false},
    "terapeuta": {"id": "terapeuta", "name": "terapeuta", "display-name": "Terapeuta", "type": "text", "required": false}}
   ```
   - `type: "string"` → **ERROR**: `should be either :snippet, :card, :dimension, :number, :text, :date, :boolean`
   - `type: "dimension"` → generates `column = column` SQL instead of `column = value` → **Postgres type mismatch error** (Metabase pre-processes dimension filters differently from simple parameters)
   - `type: "number"` / `type: "text"` → correct for simple value substitution

3. **Parameter_mapping target — `["variable", ["template-tag", "tag_name"]]` (NOT `["dimension", ...]`):**
   ```json
   {"parameter_id": "caso", "card_id": 8138, "target": ["variable", ["template-tag", "caso"]]}
   ```
   - `["dimension", ["template-tag", "caso"]]` → **filter silently ignored** (returns all rows)
   - `["variable", ["template-tag", "caso"]]` → **filter applied correctly**

4. **Dashboard parameter type — `number/=` for numbers, `string/=` for text:**
   ```json
   {"id": "caso", "slug": "caso", "name": "Caso", "type": "number/=", "sectionId": "number", "isMultiSelect": false},
   {"id": "terapeuta", "slug": "terapeuta", "name": "Terapeuta", "type": "string/=", "sectionId": "string", "isMultiSelect": false}
   ```

**Testing drill-down via API:** run the card via the dashboard endpoint with a parameter:
```sh
curl -s -X POST -H "x-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"parameters":[{"id":"caso","slug":"caso","value":"537","type":"number/=","target":["variable",["template-tag","caso"]]}]}' \
  "$MB_URL/api/dashboard/$DASH_ID/dashcard/$DASHCARD_ID/card/$CARD_ID/query"
```
Or test a card directly:
```sh
curl -s -X POST -H "x-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"parameters":[{"type":"number","target":["variable",["template-tag","caso"]],"value":537}]}' \
  "$MB_URL/api/card/$CARD_ID/query"
```

**Text cards (markdown) in dashboards:** to add explanatory text sections (like the Psico dashboard), create a dashcard with `card_id: null` and `visualization_settings.text`:
```json
{"id": -1, "card_id": null, "size_x": 24, "size_y": 3, "row": 0, "col": 0,
 "parameter_mappings": [],
 "visualization_settings": {"text": "## Title\n\nExplanation in Portuguese..."}}
```

**Column display names in Portuguese:** set via `visualization_settings.column_settings`:
```json
{"column_settings": {
  "[\"name\",\"clinical_case_number\"]": {"column_title": "Caso"},
  "[\"name\",\"owner\"]": {"column_title": "Terapeuta"}
}}
```

**Dashboard layout best practices (learned from comparing with Psico dashboard 261):**
- Use width 24 (full width) for tables and text, 12 for side-by-side charts
- Order: text intro → aggregated charts → text → summary table → text → detail/raw table
- Aggregated views on top, granular details on bottom
- All cards in a single `PUT /api/dashboard/:id` call with unique negative IDs (`-1`, `-2`, `-3`, ...)

**Dashboard full-width setting:** by default dashboards are `width: "fixed"` (centered, narrow). To make the dashboard use the full browser width (like the Psico dashboard 261), set `width: "full"`:
```sh
curl -s -X PUT -H "x-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"width":"full"}' "$MB_URL/api/dashboard/$DASH_ID"
```

**Series colors matching Psico dashboard palette:** the Psico dashboard (261) uses `series_settings` (not `graph.colors`) to color series by metric name. The canonical colors are:
- Adherent/positive: `#88BF4D` (green)
- Non-adherent/negative: `#E75454` (red) or `#EF8C8C` (lighter red)
- "Maybe"/warning: `#F9D45C` (yellow)
- Average line: `#ED8535` (orange, display: "line")
```json
{"visualization_settings": {
  "series_settings": {
    "aderentes": {"color": "#88BF4D", "display": "bar", "title": "Aderentes"},
    "nao_aderentes": {"color": "#E75454", "display": "bar", "title": "Não Aderentes"}
  },
  "graph.series_order": [
    {"key": "aderentes", "color": "#88BF4D", "enabled": true, "name": "Aderentes"},
    {"key": "nao_aderentes", "color": "#E75454", "enabled": true, "name": "Não Aderentes"}
  ]
}}
```

**Crossfilter click_behavior for drill-down (critical — filters alone don't enable drill-down):**

Dashboard filter parameters + parameter_mappings enable filtering via the filter bar at the top. But **drill-down** (clicking a bar in a chart or a row in a table to filter other cards) requires `click_behavior` on the dashcard's `visualization_settings`. This is what the Psico dashboard (261) does — the user explicitly corrected this: "não consegui fazer o drill-down... eu tive que fazer um esqueminha com click-behavior + filtro."

The `click_behavior` type is `"crossfilter"`. When a user clicks a data point, Metabase takes the clicked column value and sets it as the parameter value, which then propagates to all cards connected to that parameter via `parameter_mappings`:

```json
{
  "visualization_settings": {
    "click_behavior": {
      "type": "crossfilter",
      "parameterMapping": {
        "og_to": {
          "source": {"type": "column", "id": "og_to", "name": "og_to"},
          "target": {"type": "parameter", "id": "og_to"},
          "id": "og_to"
        }
      }
    }
  }
}
```

- `source.id` = the column name in the card's result set that provides the value
- `target.id` = the dashboard parameter ID that gets set
- The parameter must also be connected to the target cards via `parameter_mappings`

**Pattern:** chart card (click_behavior crossfilter → sets parameter) → summary table (parameter_mapping → receives filter) → raw detail table (parameter_mapping → receives filter). This creates the drill-down chain: click a bar → table below filters → raw details filter.

**Adding click_behavior via PUT /api/dashboard/:id:** the `click_behavior` goes inside each dashcard's `visualization_settings` in the `dashcards` array. It must be sent in the same PUT call that sets all dashcards (PUT replaces the entire array).

### BigQuery SELECT aliases are NOT visible in WHERE clause of the same query level

BigQuery (like standard SQL) resolves `WHERE` before `SELECT`, so you **cannot** reference a SELECT alias in the WHERE clause of the same query. This bites when Metabase template-tags filter on an aliased column:

```sql
-- WRONG — "Unrecognized name: owner at [N:M]"
SELECT
  clinical_case_owner_name AS owner,
  ...
FROM case_level
WHERE 1=1
  [[AND owner = {{terapeuta}}]]   -- can't see the "owner" alias here!

-- CORRECT — use the original column name in WHERE
WHERE 1=1
  [[AND clinical_case_owner_name = {{terapeuta}}]]
```

This is especially easy to miss when the SQL has nested subqueries (CTE → subquery → outer SELECT) — the alias exists at the outer level but the WHERE is at the same level. Always use the **original column name** from the source table/CTE in WHERE clauses, not the alias you assign in SELECT.

### Window functions can't reference SELECT aliases in the same level

When adding computed columns (like `aderencia_status`) to a RAW query using window functions (`OVER (PARTITION BY ...)`), the window function **cannot reference other SELECT aliases** like `has_active_to_objectives` — it can only reference columns from the `FROM` clause. This produces `"Unrecognized name: has_active_to_objectives"` even though the alias is defined a few lines above in the same SELECT.

**Fix:** wrap the query in an outer SELECT that adds the window function columns, or use a CTE chain. The CTE approach (see the `case_adherence` pattern above) is more reliable because each CTE level has access to the previous level's columns.

### CTE forward declaration — CTEs must be defined BEFORE they're referenced

BigQuery requires CTEs to be defined BEFORE any CTE that references them. If `active_ot_cases` JOINs `og_to`, the `og_to` CTE must appear **before** `active_ot_cases` in the `WITH` clause. Defining `og_to` after `active_ot_cases` produces `"Table 'og_to' must be qualified with a dataset"`.

### Adding a column to a multi-level nested query — update ALL levels

When a RAW query has multiple nesting levels (CTE → subquery → outer SELECT → wrapper SELECT), adding a new column (e.g. `og_to_name`) requires updating **every level**:

1. The CTE that produces the column (e.g. `og_to`)
2. The CTE that JOINs it (e.g. `active_ot_cases` — SELECT + LEFT JOIN)
3. The `raw` subquery's outer SELECT (the `WITH raw AS (SELECT ... FROM (...))` wrapper)
4. The `objective_level` CTE (both SELECT and GROUP BY must include it — missing GROUP BY produces `"neither grouped nor aggregated"`)
5. The `case_level` CTE (SELECT with `ANY_VALUE()` + GROUP BY only `clinical_case_number`)
6. The final SELECT
7. The ORDER BY (if it references the column, use the outer-level name, not `table.column` prefix)

Missing the column at any level produces errors like `"Unrecognized name: og_to_name"` or `"SELECT list expression references column X which is neither grouped nor aggregated"` that are hard to trace because the error line number points to a different nesting level than where the column is actually missing.

### OG TO (occupational_therapy OG) — clinical_cases_clinicians + clinicians join

The **OG TO** (specialty consultant for occupational therapy) is NOT the same as the clinical case owner (OG Psico). The OG TO is stored in `clinical_cases_clinicians` (note: table name is `clinical_cases_clinicians`, NOT `clinical_case_clinicians`):

```sql
og_to AS (
  SELECT
    ccc.clinical_case_id,
    c.name AS og_to_name
  FROM `data-kernel-production-4o7n.datakernel.clinical_cases_clinicians` ccc
  INNER JOIN `data-kernel-production-4o7n.datakernel.clinicians` c ON c.id = ccc.clinician_id
  WHERE ccc.clinician_role = 'occupational_therapy_specialty_consultant'
  QUALIFY ROW_NUMBER() OVER(PARTITION BY ccc.clinical_case_id ORDER BY ccc.created_at DESC) = 1
)
```

- Table: `data-kernel-production-4o7n.datakernel.clinical_cases_clinicians` (plural "cases")
- Role for OG TO: `'occupational_therapy_specialty_consultant'`
- Role for OG Psico (speech): `'speech_specialty_consultant'` (NOT `speech_therapy_specialty_consultant`)
- Name comes from `clinicians.name` (properly capitalized), NOT `clinicians.user_full_name` (often NULL)
- A case can have multiple OG TOs over time — use `QUALIFY ROW_NUMBER() ... ORDER BY created_at DESC = 1` to pick the latest
- The OG Psico (case owner) comes from `ops-data-production-8fk2.aggregates.children.clinical_case_owner.name` and is stored in **lowercase** — this is a different person from the OG TO

**When adding a new CTE to a multi-level nested query:** the CTE must be defined BEFORE any CTE that references it (BigQuery requires forward declaration). And the new column must be added at EVERY nesting level:
1. The CTE that produces the column (e.g. `og_to`)
2. The `active_ot_cases` CTE that JOINs it (SELECT + LEFT JOIN)
3. The `raw` subquery's outer SELECT (the `WITH raw AS (SELECT ... FROM (...))` wrapper)
4. The `objective_level` CTE (SELECT + GROUP BY — both must include the column)
5. The `case_level` CTE (SELECT with `ANY_VALUE()` + GROUP BY only `clinical_case_number`)
6. The final SELECT

Missing the column at any level produces "Unrecognized name" or "neither grouped nor aggregated" errors that are hard to trace because the line numbers in the error point to a different level than where the column is missing.

- `references/domain-subdomain-i18n.md` — Portuguese ↔ English domain/subdomain mapping from core i18n (for CSV imports, de-para)
- `references/intervention-schema.md` — intervention dataset tables (objectives, evolution checks, etc.)
- `references/assessment-schema.md` — assessment dataset tables (COPM hierarchy, vineland, OT direct assessment, etc.)
- `references/mapper-missing-objectives.md` — pattern for finding descriptions in N×N mappers that don't match `library_objectives`
- `references/migration-cross-match.md` — cross-match CSV import against production DB (create/update/discard analysis for data migration planning)
- `references/debug-missing-case.md` — diagnostic query pattern for investigating why a case doesn't appear in a complex CTE query
- `references/session-change-history.md` — CDC `sessions_events` pattern for tracing session cancellation/reactivation history (with actor + confirmation forensics)

### Validating a frontend/backend bug hypothesis with a quick BQ existence check

Before proposing a fix for a suspected "missing/null optional field crashes the UI" bug, confirm the hypothesis against production data with a single `COUNTIF` query rather than assuming from code reading alone. Pattern: group by the relevant dimension (protocol, discipline, subdomain) and count total vs `COUNTIF(<column> IS NULL)`:

```sql
select
  p.name as protocol,
  count(*) as total,
  countif(lobj.skill_id is null) as without_skill
from
  `supervision-production-8f1v.intervention.protocols` p
  inner join `supervision-production-8f1v.intervention.protocol_items` pi on p.id = pi.protocol_id
  inner join `supervision-production-8f1v.intervention.library_objectives` lobj on lobj.protocol_item_id = pi.id
where pi.discarded_at is null and lobj.discarded_at is null
group by protocol
order by protocol
```

This confirmed (2026-08-17) that 206/222 (93%) of `Fonoaudiologia` library objectives have `skill_id IS NULL` in production, which was the root cause of a clinical-panel white-screen crash (`useSpeechTherapyForm.ts` did `libraryObjective?.skill.name` without a null guard on `skill` itself — only the objective was optional-chained, not the nested `.skill`). If the count comes back non-zero/significant, the hypothesis is confirmed and the fix should handle the null case (optional chaining) rather than assuming the data will eventually be backfilled — 93% missing means it's the common case, not an edge case. Drill down further by grouping on a finer dimension (e.g. `pi.subdomain`) to see if the gap is protocol-wide or isolated to specific subdomains (in this case `sound_acquisition` was 100% null while `articulation`/`breathing` were fully populated — suggesting a newer subdomain that predates the skill field, not systemic data corruption).

### Investigating a Slack-reported "panel shows wrong data" complaint — check the source tables for the specific entities first

When a user reports a discrepancy in an external dashboard/panel (e.g. "Painel Operacional aba OCs shows case X as pending but it was completed"), don't just relay the report or assume which side (source system vs. downstream panel) is wrong. Query the actual source-of-truth tables in BigQuery for the specific entity IDs (case numbers) named in the report:

1. Find the domain-appropriate table/query (e.g. `queries/clinical_guidance/light-registry.sql` for "Orientação Clínica" (OC) — dataset `guidance-data-production-l38y.guidance.registries`, joined to `observable_light_form_registrations`/`form_registrations` for the "light" observation).
2. Filter to the exact case numbers from the report (`AND cc.number IN (245, 320, ...)`) and inspect `registry_status`, `created_at`/`updated_at` timestamps, and any related sub-record (e.g. light score) to see whether the record is actually complete in the source system.
3. Compare timestamps against when the user says the work was done — a `finished` registry with a light record created/updated on the reported date confirms the source data is correct, which means the complaint is real and the bug is downstream (sync/ETL/aggregation into the panel), not a process gap on the clinician's side.
4. Watch for exceptions: not every case in the batch will match the pattern. One case out of five may genuinely be missing the sub-record (e.g. registry `finished` but no light created) — call that out separately as a real data gap, not sync lag, since lumping it in with the others would misdirect the fix.
5. This validates or refutes the report with production evidence before it's escalated further in Slack — much stronger than accepting either "user says it's broken" or a bot's generic "please re-check your process" reply at face value.

This generalizes beyond OC/light: any "user says panel X is wrong for case/entity Y" complaint should be checked directly against the relevant domain's source tables (see the dataset table at the end of this skill) before concluding whether it's a real bug and on which side of the pipeline.

### Debugging missing cases from complex CTE queries

When a case should appear in a query but doesn't (or appears with wrong status), run a parallel diagnostic battery to isolate which CTE/JOIN/condition excludes it. The pattern: run N independent queries — one per filter gate — against the specific case. See `references/debug-missing-case.md` for the template and real-world examples.

### OT assessment devolutive query pitfalls

Two systematic issues in queries that join `occupational_therapy_registries` with `feedback_assessment` sessions:

1. **`status_devolutiva` false-negative with multiple registries.** When a case has 2+ registries, `QUALIFY ROW_NUMBER() ... ORDER BY started_at DESC` picks the most recent one. If the devolutive belongs to an older registry (its date >= older `started_at` but < newer `started_at`), the condition fails and shows "Pendente" despite a completed devolutive existing. Fix: compare against ALL registries, not just the most recent.

2. `>= sas.started_at` is semantically wrong. The devolutive date condition should use `>= sas.completed_at`, not `>= sas.started_at`. Using `started_at` allows a devolutive to be counted even if the assessment hasn't finished yet. Same pitfalls apply to speech therapy queries.

### "Score"/"desfecho ideal" requests on structured clinical assessments — don't confuse `status = completed` with a positive clinical outcome

When a user asks to calculate a "score" or define what an "ideal"/"desfecho positivo"
result looks like for a structured clinical assessment (speech therapy, OT, Vineland,
any multi-domain protocol with a `registry` + N sub-assessments), the assessment's
`status` enum (`not_started`/`started`/`completed`) measures **completude de
preenchimento** — did the clinician fill in what the protocol requires — not **desfecho
clínico** — does the content of the answers indicate typical development or a clinical
alert. These are independent variables; a `completed` sub-assessment can represent either
a healthy child or one with significant findings, and confusing the two produces a "score"
that's actually just a completion percentage.

**Technique that generalizes across assessment types:**

1. Read every sub-assessment's `completely_filled?`/`fulfilled?` method in the `core`
   Ruby models first — that tells you what's REQUIRED to reach `completed`, which is
   often not "all fields have a specific value", just "all fields are `.present?`".
   This matters because enums that include a `not_observed`/`notObserved` sentinel value
   count as "present" for completion purposes but should NOT count as a confirmed
   clinical finding — always emit a separate `is_fully_observed` boolean (true only when
   no field is the sentinel) alongside any `outcome_score`, and never trust
   `outcome_score` without checking it.
2. For each sub-assessment/domain, identify from the enum + i18n what value(s)
   represent the clinically "adequate"/"typical"/"absent-of-alert" answer — this is
   NOT always obvious from BigQuery column names (e.g. `dental_occlusion = 'adequate'` is
   clear, but a field like `jaw_posture` with only `elevated`/`lowered`/`notObserved` has
   NO neutral/adequate option at all in the enum — flag those fields as descriptive-only,
   don't force them into a binary score).
3. Watch for domains that are triage checklists where "presence of the signal" is the
   BAD outcome, not the good one (e.g. speech therapy's Bandeiras Vermelhas: `yes` on any
   of the 13 signs = alert, `no` = healthy) — this inverts the usual "more `yes` = better"
   assumption and is easy to get backwards if you don't read the UI's own label logic
   (`clinical-panel` i18n often already computes an equivalent indicator client-side,
   e.g. a "TOTAL DE sim" counter + ALERT/NO-ALERT label — grep the i18n JSON and any
   `*Score*`/`*Count*` component under `clinical-panel/src/pages/**/components/` for
   precedent before inventing your own threshold).
4. Some domains have NO valid "typical" concept at all — e.g. AAC/CAA assessments are
   gated by a boolean (`is_needed`) and are about successful *configuration*, not
   development milestones. Don't force every sub-assessment into the same "closer to
   healthy" scoring frame; say explicitly when a domain needs a different kind of score
   (triage rate vs. implementation-success rate) and keep it out of any consolidated
   average.
5. When one domain's gabarito depends on the child's age (e.g. phonological processes
   have a documented "age of expected disappearance" — present before that age is
   normal, after is an alert), you need `clinical_cases.birth_date` +
   `registry.started_at`/`completed_at` to compute age at assessment before you can
   classify a raw occurrence as clinically relevant. Don't score presence/absence alone
   without the age gate when the protocol defines one.
6. Compose a consolidated multi-domain score (e.g. one number per Registry across 5
   sub-assessments) only as a plain average unless a real weighting source exists
   (clinical protocol doc, ADR, existing UI weighting) — say explicitly that unweighted
   average is a default, not a validated clinical formula, so downstream dashboards don't
   over-trust it.

6b. When more than one domain has a `not_observed`/sentinel enum value, apply the SAME
   missing-data policy to all of them — don't let each domain's pass through the analysis
   independently decide "exclude from denominator" vs "count against the score". Both
   naive choices have an opposite bias (excluding inflates small-sample scores; keeping a
   fixed denominator penalizes honestly-incomplete assessments). See
   `references/assessment-outcome-scoring.md` § "not_observed/missing-data handling" for
   the unified `outcome_score` + `observed_fraction` + `is_score_reliable` pattern.

7. When this analysis is written up as a doc series (one file per domain), order the
   files to match the domain order in the product UI (grep the relevant
   `*Provider.tsx`/registries-home list in `clinical-panel`, don't assume alphabetical
   or FK order), and mark the whole series — overview + every per-domain doc — with an
   explicit "⚠️ preliminary analysis, not a validated clinical rule" banner, since the
   criteria come from reverse-engineering code/enums, not from the clinical specialty
   team. See `references/assessment-outcome-scoring.md` § "Doc-writing conventions" for
   the specifics (learned from user correction 2026-08-26).

See `references/assessment-outcome-scoring.md` for a worked example (speech therapy's 5
sub-assessments) with the full SQL pattern (per-domain `outcome_score` +
`is_fully_observed`, then Registry-level average) — reusable as a template for the same
question on OT or Vineland assessments. That reference also has a dedicated section on
handling `not_observed`/missing-data sentinels **consistently across every domain**
(exclude from both numerator and denominator, report `observed_fraction` alongside the
score, gate reliability on a coverage threshold) — apply the SAME policy to every domain
in a doc series; don't let different domains drift to different ad-hoc treatments of
"not observed" across separate writing passes. It also covers: quantifying mapping-
coverage claims with a real count before labeling a domain "weak"/"not recommended"
(especially when a domain expert authored the mapping — a qualitative read can be
flatly wrong), and producing a separate plain-language validation document (no SQL/
schema jargon, one closed question per open assumption) when a technical analysis needs
sign-off from a non-technical specialist.

### Before extending a "use Objetivos as proxy for reavaliação" pattern from one discipline to another, check whether the correspondence is BY CONSTRUCTION or RECONCILED BY MATCHING

A pattern that works for one clinical discipline (e.g. Vineland/Psico: completed
Objetivos already predict the indirect assessment result) does NOT automatically
transfer to a structurally similar-looking discipline (e.g. Fono) just because both have
"a registry with sub-assessments" and "a library of Objetivos". The transferability test
is: **is the Objetivo the SAME row as the assessment item (1:1 by construction), or are
the two taxonomies independent and reconciled after the fact via text/fuzzy matching
(N:N approximate)?**

- Vineland: the protocol "Vineland 3" IS the source of the Objetivos library for that
  discipline — completing the objective literally means answering the item. No
  reconciliation step exists or is needed.
- Fono: the "Fonoaudiologia" Objetivos library and the 5 direct-assessment sub-protocols
  (Imitação/Wertzner, MMGBR, Bandeiras Vermelhas, CAA, Comunicação Expressiva) were built
  independently. Confirming this required reading an existing de-para investigation that
  needed fuzzy text matching, regex-based disambiguation, and still left real gaps (7
  objectives with no system match) — that reconciliation effort is itself the evidence
  the two are not the same taxonomy.

**Consequence when the correspondence is reconciled, not by-construction:** viability is
NOT a single yes/no for the whole discipline — it varies per sub-domain based on (a) how
much of that sub-domain's fields even have a mapped Objetivo in the de-para, and (b)
whether the field is a *trainable skill* (objectives can drive it) or an *anatomical/
physiological exam finding* (no amount of objective completion changes it — e.g. frenulum
length, dental occlusion). Grep the discipline's own outcome-scoring docs (or run the
mapping-coverage check) per sub-domain before answering "can we do for X what we do for
Vineland" with a single global answer — a domain-by-domain viability table is the correct
shape of answer, not "yes" or "no". See `references/assessment-outcome-scoring.md` §
"Cross-discipline proxy-viability analysis" for the worked example and the recommendation
to NOT collapse per-domain viability into one consolidated feasibility score (same
reasoning as never collapsing `outcome_score` across domains without flagging it's a
simplification).

### Freeze external mapping sources (CSVs, spreadsheets) used as analysis input, with hash + date

When an analysis or de-para depends on an external CSV/spreadsheet that lives in a
mutable location (a discovery folder, a Google Sheet, anything the business team can
still edit), and the conclusion could change if that source changes, copy a frozen
snapshot into the analysis's own directory alongside a short README recording: original
path, SHA-256 hash, capture date, row count, and — critically — a short "how to re-check"
procedure naming the SPECIFIC prior findings (e.g. "if these N previously-unmapped items
now have a match, re-run the coverage table; if this ambiguity was resolved, it doesn't
change conclusion Y because Y's limitation is structural, not a mapping gap"). This lets
a future reader tell, without redoing the whole investigation, whether an update to the
source data invalidates the conclusion or is a non-event. Don't just say "sourced from
`<path>`" — that gives no way to detect drift.

### Speech therapy sub-assessment FK pattern is inverted vs OT

The speech therapy registry JOIN pattern is the **opposite** of OT. For OT, sub-assessment tables have a `registry_id` FK pointing to the registry. For speech therapy, the **registry** holds foreign keys (`phonological_assessment_id`, `expressive_communication_assessment_id`, etc.) pointing to each sub-assessment table's `id`. Join `sub_table.id = registry.<type>_assessment_id`, not the other way around.

Additionally, AAC has no `status` column — use `CASE WHEN aac_clinical_decisions.id IS NOT NULL THEN 'completed' END` as a proxy. See `references/assessment-schema.md` for the full schema.

### `clinical_case_id` in assessment tables is a STRING UUID, not the INT64 `number`

Assessment tables (`speech_therapy_registries`, `occupational_therapy_registries`, etc.)
store `clinical_case_id` as a **STRING UUID** (e.g.
`'46011d02-7304-4089-b927-bed9350ccaa1'`), not the user-facing case `number` (INT64).
Querying `WHERE str.clinical_case_id = 855` fails with
`No matching signature for operator = for argument types: STRING, INT64`.

**Fix:** always resolve `clinical_cases.number` → `clinical_cases.id` (UUID) first,
then filter assessment tables by the UUID string:

```sql
-- Step 1: find the UUID from the case number
SELECT id, number, name, status
FROM `data-kernel-production-4o7n.datakernel.clinical_cases`
WHERE number = 855

-- Step 2: use the UUID string in the assessment table
WHERE str.clinical_case_id = '46011d02-7304-4089-b927-bed9350ccaa1'
```

This applies to ALL assessment tables that reference `clinical_case_id` — they all
use the UUID string, never the INT64 number.

### Investigating a "therapist can't start new assessment / reavaliação" Slack complaint

When a therapist reports they can't start a new assessment cycle (reavaliação)
because the panel only shows the old completed assessment, investigate the
`speech_therapy_registries` (or `occupational_therapy_registries`) table for the
specific case:

1. Resolve the case number to UUID (see pitfall above).
2. Query ALL registries for the case, ordered by `started_at DESC`:
   ```sql
   SELECT
     str.id AS registry_id,
     str.status AS registry_status,
     str.started_at,
     str.completed_at,
     str.editable_until,
     pa.status  AS phonological_status,
     eca.status AS expressive_communication_status,
     -- ... other sub-assessment statuses
   FROM `supervision-production-8f1v.assessment.speech_therapy_registries` str
   LEFT JOIN ... -- sub-assessment joins per the FK pattern above
   WHERE str.clinical_case_id = '<UUID>'
   ORDER BY str.started_at DESC
   ```
3. Check the `assessment_sessions` table to see if new assessment sessions were
   linked to the old (completed) registry instead of opening a new one:
   ```sql
   SELECT
     s.id, s.session_type, s.status, s.start_scheduled_at,
     ases.assessment_speech_therapy_registry_id AS registry_id
   FROM `data-kernel-production-4o7n.datakernel.sessions` s
   JOIN `supervision-production-8f1v.assessment.assessment_sessions` ases ON ases.id = s.id
   WHERE s.clinical_case_id = '<UUID>'
     AND s.discipline = 'speech_therapy'
     AND s.session_type = 'direct_assessment'
   ORDER BY s.start_scheduled_at DESC
   ```
4. Diagnosis: if only ONE registry exists and it's `completed` with
   `editable_until` in the past, the system has no open registry to link new
   assessment sessions to — so new sessions get attached to the completed one,
   and the panel shows only the old protocols (already filled). The
   `editable_until` field defines the post-completion window during which the
   registry can still be edited; after it expires, the assessment is fully
   locked.

This is a data-level diagnosis — the fix (creating a new registry or fixing the
panel's "new assessment" flow) is a code/product action, not a data query fix.

### Evolution check business rule — one checagem per case per week, not per session

Confirmed via production data (2026-08-24, Slack thread investigation): a therapist's
`evolution_checks` are only expected on the FIRST session of a given clinical case in a
given week. Subsequent sessions of the SAME case in the SAME week legitimately have no
`evolution_checks` row — this is expected system behavior, not a bug. When a therapist
reports "clicking Checagem redirects me to Anotações and the session already shows
Concluída", check whether an earlier session that week for the same case already has an
evolution check before escalating as a platform bug.

Query pattern to test this hypothesis — window function ranking sessions per case per
week, LEFT JOIN straight to `evolution_checks` (no need for the full objective chain
since the question is "was there a check on this session", not "which objective"):

```sql
SELECT
  cc.number AS clinical_case_number,
  s.id AS session_id,
  s.start_scheduled_at,
  s.status AS session_status,
  ec.id AS evolution_check_id,
  ROW_NUMBER() OVER (
    PARTITION BY cc.number
    ORDER BY s.start_scheduled_at
  ) AS session_order_in_week_for_case
FROM `data-kernel-production-4o7n.datakernel.clinical_cases` cc
JOIN `data-kernel-production-4o7n.datakernel.sessions` s ON cc.id = s.clinical_case_id
JOIN UNNEST(s.clinicians) AS clinician
JOIN `data-kernel-production-4o7n.datakernel.clinicians` c ON c.id = clinician.clinician_id
LEFT JOIN `supervision-production-8f1v.intervention.evolution_checks` ec
  ON ec.intervention_session_id = s.id
WHERE cc.number IN (<case numbers>)
  AND LOWER(c.user_email) = '<clinician email>'
  AND DATE(s.start_scheduled_at) BETWEEN DATE('<week start Mon>') AND DATE('<week end Sun>')
ORDER BY cc.number, s.start_scheduled_at
```

Read the result as: `session_order_in_week_for_case = 1` with a check present, followed
by `= 2, 3, ...` with `evolution_check_id IS NULL` on the SAME case — that pattern
confirms the "already checked this week" rule rather than a bug. If session 1 has NO
check and later sessions also have none, that's a real gap worth escalating.

See `queries/specific/session/sessions-evolution-check-yara-cases-702-10-3-2026-08-17.sql`
for a full worked example (includes `session_status` to also flag cancelled sessions).

### Resolving a Slack-reported ticket that starts as a thread URL

When the user pastes a Slack thread URL (e.g.
`https://workspace.slack.com/archives/C0B24BST335/p1787233669464439`), extract
`channel_id` = the segment after `/archives/` (`C0B24BST335`) and `message_ts` = the `p`
segment with a decimal point inserted 6 digits from the end (`p1787233669464439` →
`1787233669.464439`). Call `mcp__slack__slack_read_thread` with those two values
directly — no need for `slack_search_public` first when you already have the URL. Then
follow the existing "Investigating a Slack-reported panel/data complaint" pitfall
workflow below: identify the clinician/case from the thread, confirm today's date context
(the user's hypothesis referenced "since today is Monday, the complaint is about last
week" — always sanity-check relative date language like this against the actual current
date via `date`), then validate the hypothesis against source tables before answering.

### Speech therapy clinician role for OG

The specialty consultant (OG) role for speech therapy is `speech_specialty_consultant`, **not** `speech_therapy_specialty_consultant`. Verify `clinician_role` values with `SELECT DISTINCT clinician_role FROM clinical_cases_clinicians WHERE clinician_role LIKE '%speech%'` before writing queries.

| Project | Dataset prefix | Content |
|---------|---------------|---------|
| `data-kernel-production-4o7n` | `datakernel` | clinical_cases, clinical_cases_clinicians (OG roles), clinicians, sessions, users, tenants |
| `supervision-production-8f1v` | `intervention` | peis, objectives, library_objectives, protocols, evolution_checks, evolution_check_configurations, targets, programs |
| `supervision-production-8f1v` | `assessment` | speech_therapy_registries, speech_motor_control_assessments, etc. |
| `supervision-production-8f1v` | `raw` | event source tables (objectives_events, etc.) |
| `ops-data-production-8fk2` | `aggregates` | denormalized children (churn, on_hold, owner) |
| `ops-data-production-8fk2` | `people` | source-aligned tables (children with churned_at, on_hold) |
| `guidance-data-production-l38y` | `guidance` | registries, discussions, plannings, subjects, tasks, demands |

For staging/development environments, use `bq-run.sh --env <env>`.
