# Worked Example: created_by in suggested_workload (supervision)

Session: August 2026 — read-only investigation of the supervision project
for the feature "Expor o campo created_by do workload no painel de
supervisão (Dataform/ELT)."

## Investigation scope

The user asked to map the territory for exposing `created_by` on the
`suggested_workload` table. Custom output format with these sections:
Tipo de projeto, Pontos de entrada, Fluxo principal (CDC), Schema do
external table, Projection do model, Metadados, Resolução de nomes de
usuário, Constraints, Dependências identificadas, Pontos de atenção.

Output was written to a file at the user's specified path (not returned
inline).

## What was searched

1. `package.json` → only dep `@dataform/core` → confirmed Dataform project
2. Found project at `/Users/regishattori/workspace/genial/supervision/`
3. `definitions/assessment/suggested_workload/` → 3 files:
   `suggested_workload_events.sqlx`, `suggested_workload.sqlx`,
   `test_suggested_workload.sqlx`
4. Content search for `created_by` across all `definitions/` → 30 matches,
   all in OTHER tables (notes, targets, objectives, evolution_check
   configurations). Zero matches in `suggested_workload`.
5. Read `includes/assessments/tables/suggested_workload.js` for metadata
6. Read `includes/functions.js` for `renderEventTable()` and
   `renderSchemaExternalTable()` implementations
7. Cross-referenced Rails source: `core/db/schema.rb` → table
   `assessments_suggested_workloads` has NO `created_by_id` column
8. Read Rails model `assessments/suggested_workload.rb` → no
   `belongs_to :created_by` association
9. Read migration `20250814200000_create_assessments_suggested_workloads.rb`
   → no `created_by_id` in original table creation
10. Read prior user story analysis (`20260526-supervision-clinical-
    agreements-created-by/analysis.md`) for the 4-file pattern precedent

## Key findings

### External table schema (suggested_workload_events.sqlx)

Fields declared: `id`, `clinical_case_id`, `status`, `discipline`, `hours`,
`limit_date_to_approve`, `reason`, `approved_at`, `approved_by_id`,
`reproved_at`, `reproved_by_id`, `created_at`, `updated_at`.

- `tenant_id` auto-injected by `ensureTenantField()` (not in explicit list)
- `created_by_id` NOT present
- `ignore_unknown_values = TRUE` (standard pattern, 20+ external tables)

### Model projection (suggested_workload.sqlx)

Projects: `id`, `clinical_case_id`, `status`, `discipline`, `tenant_id`,
`hours` (regex-extracted from ISO 8601 interval), `limit_date_to_approve`,
`reason`, `approved_at`, `approved_by_id`, `reproved_at`, `reproved_by_id`,
`created_at`, `updated_at`.

- `created_by` NOT projected
- `approved_by_id` and `reproved_by_id` projected as raw UUIDs (STRING)
- No JOIN with `dim_users` for name resolution

### Metadata (suggested_workload.js)

- `zone: "bronze"` — enrichment (name resolution) belongs in higher layers
- Assertions: uniqueKey `["id"]`, nonNull on 9 columns (NOT including any
  `*_by_id` fields), rowCondition `created_at <= updated_at`

### Rails source (core)

- Table `assessments_suggested_workloads` in `schema.rb`: no `created_by_id`
- Model `Assessments::SuggestedWorkload`: no `belongs_to :created_by`
- Migration history: 4 migrations, none add `created_by_id`
- Controller: no reference to `created_by`
- **BLOCKER: the field does not exist in the source database.**

## The `created_by_id` → `created_by` aliasing convention

Multiple models in the supervision project follow this pattern:

```sql
-- External table declares: created_by_id (STRING)
-- Model projects: events.created_by_id AS created_by
```

Confirmed in:
- `notes.sqlx`: `events.created_by_id AS created_by`
- `targets.sqlx`: `events.created_by_id AS created_by`
- `objectives.sqlx`: `events.created_by_id AS created_by`

The `_id` suffix is dropped in the curated model. Metadata documents the
field as `created_by` (without `_id`).

## The `nonNull` assertion decision

Prior user story (`20260526-supervision-clinical-agreements-created-by`)
explicitly decided NOT to add `created_by_id` to `assertions.nonNull`
because:
- Historical records created before the field was populated have `NULL`
- The assertion would break the pipeline on next execution
- The invariant (COPMs always have `created_by_id`) is guaranteed by
  upstream Rails logic, not by the Dataform assertion

This pattern applies to `suggested_workload` as well: if `created_by_id`
is added, existing records would have `NULL` until the Rails layer
backfills them.

## The 4-file modification pattern

When the source (Rails) is ready, the Dataform change touches 4 files in
one PR:

1. `suggested_workload_events.sqlx` — add `{ name: 'created_by_id', type:
   'STRING' }` to `renderSchemaExternalTable()` array
2. `suggested_workload.sqlx` — add `events.created_by_id AS created_by`
   to SELECT projection
3. `includes/assessments/tables/suggested_workload.js` — add
   `created_by: "..."` to columns dict
4. `test_suggested_workload.sqlx` — add `created_by_id` to mock event
   payloads and `created_by` to expected output

Precedent: user stories `20260526-supervision-clinical-agreements-created-by`
and `20260807-test-orchestrator-created-by-workload`.

## dim_users JOIN pattern (for reference, not used by this model)

```sql
LEFT JOIN ${ref("aggregates", "dim_users")} users
  ON users.id = <table>.created_by_id
```

Not applied in `suggested_workload.sqlx` — the model is `zone: "bronze"`
and name resolution belongs in higher layers (silver/gold models or
Metabase SQL).
