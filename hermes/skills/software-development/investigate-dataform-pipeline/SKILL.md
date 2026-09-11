---
name: investigate-dataform-pipeline
description: "Investigate GenialCare Dataform projects read-only."
---

# investigate-dataform-pipeline

Read-only investigation of GenialCare's three Dataform/ELT projects that
transform CDC Event Store data into BigQuery tables. This is the Dataform
counterpart to `investigate-core-flow` (Rails) and `investigate-bff-flow`
(Node.js GraphQL).

## When to load this skill

- User asks to "investigar o projeto supervision/data-kernel/operational-data"
- User asks to map territory or understand data flow before implementing a feature
- User asks whether a field or entity exists in the Dataform layer
- User asks "como o supervision acessa dados de X"
- User references `.sqlx` files, `renderEventTable`, or Dataform concepts

## The three projects

| Projeto | BQ Project (dev) | Connection | Focus |
|---|---|---|---|
| `supervision` | `supervision-development-9a7j` | `US.supervision` | Clinical assessments, interventions, PEIs |
| `data-kernel` | `data-kernel-development-8a5x` | `US.data-kernel` | Shared core entities (users, clinical_cases, clinicians) |
| `operational-data` | `ops-data-development-0j9c` | `US.operational-data` | Operations (collaborators, contracts, scheduling, finance) |

All three share the same architecture: PostgreSQL core → Datastream CDC →
GCS JSON → BigQuery external table → Dataform model → Metabase/dashboard.

## Investigation procedure

### 1. Identify project type and config

Read `package.json` (only dep: `@dataform/core`) and `workflow_settings.yaml`
(GCP project, default dataset, env vars for cross-project refs).

### 2. Find relevant tables/models

Search for the feature/domain term across `definitions/`:

```
search_files(pattern="<term>", path="<project>", target="content", limit=30)
```

Also search `includes/` for column metadata and table definitions.

### 3. Trace the data flow (bottom-up)

For each entity found, trace through the table trio:

1. **External table** (`<entity>_events.sqlx`): identifies the GCS URI —
   `gs://genialcare-event-store-<env>/streams/database-events/core/public_<rails_table>/*`
   — this reveals the source Rails table name.
2. **renderEventTable** (`includes/functions.js`): deduplication via
   `ROW_NUMBER() OVER (PARTITION BY payload.id ORDER BY source_timestamp DESC,
   lsn DESC, read_timestamp DESC)` → keeps `rnk = 1`, filters `is_deleted IS FALSE`.
3. **Model** (`<entity>.sqlx`): projects/transforms fields from deduplicated
   events. Check for CAST, regex, JOINs.
4. **Declarations** (`definitions/datasources/*.sqlx`): cross-project refs
   (e.g., `dim_users` → `datakernel.aggregates.dim_users`).

### 4. Check for the target field

Search for the field name across the project. Zero matches = field does NOT
exist in the Dataform layer.

### 5. Identify name/ID resolution patterns

User references are typically stored as UUIDs (`*_by_id`). The established
pattern for resolving to names:

```sql
LEFT JOIN ${ref("aggregates", "dim_users")} users
  ON users.id = <table>.<field>_by_id
```

Used in: `dim_clinicians.sqlx`, `clinician_scores.sqlx`,
`int_clinicians_enriched.sqlx`, `int_vineland_aba_objective_evolution_check.sqlx`.

`dim_users` is a declaration → `datakernel.aggregates.dim_users` (materialized
by the data-kernel project).

### 6. Identify upstream dependencies

- **Core (PostgreSQL)**: source table — check `schema.rb` for column existence
- **Datastream**: CDC pipeline replicating core → GCS JSON
- **data-kernel**: materializes shared dimensions (`dim_users`, `clinical_cases`)
- **Metabase**: consumes the final BigQuery tables (the "painel")

A feature requiring a new field may be blocked upstream: core must persist it
AND Datastream must replicate it before the Dataform layer can pick it up.

## Structured output format

The user often provides their own output format and headers — follow their
specification exactly. When the user does NOT specify a format, use this
default template:

```
## Investigação: <project>
### Tipo de projeto
### Pontos de entrada
### Fluxo principal
### Acesso a dados de <entity>
### Padrões existentes
### Constraints
### Dependências identificadas
### Pontos de atenção
```

The user may also ask to write the summary to a specific file path and
return only a confirmation line (e.g., "Sumário salvo em <caminho>").
Follow that instruction — the file write IS the deliverable in that case.

Do NOT write code or make implementation decisions. The deliverable is the
structured investigation summary (whether returned inline or written to a
file as directed).

## Pitfalls

- **`ignore_unknown_values = TRUE` silently drops new fields.** External
  tables discard any field present in the CDC JSON but not listed in the
  schema definition. A field can be flowing through Datastream from the core
  DB but never reaching BigQuery. When investigating "does field X exist?",
  check BOTH the Dataform code AND the core's `schema.rb`. This is the #1
  gotcha — a field appearing in the core DB does NOT mean it's available in
  BigQuery.

- **Search may return zero matches for a field that exists upstream.** If
  `search_files` finds 0 matches for a field name, the field is not in the
  Dataform layer — but it may still exist in the core DB and be flowing
  through CDC. Always cross-reference with `schema.rb` in the core project.

- **Two config styles coexist.** "Inline" style (config in the `.sqlx` with
  `columns: tables.<name>.columns`) and "spread" style (`...tables.<name>`).
  When investigating, check both the `.sqlx` file and the corresponding
  `includes/<domain>/tables/<name>.js` for column metadata and assertions.

- **Declarations point to other projects.** A `type: "declaration"` `.sqlx`
  file in `definitions/datasources/` doesn't contain data — it's a reference
  to a table materialized by another project (usually data-kernel). Don't
  look for the data in the current project.

- **`updated_at` exists but `last_modified_by` typically doesn't.** Most
  tables have `updated_at` (timestamp) but NOT `last_modified_by` (who
  changed it). Adding this field requires upstream core changes + Dataform
  schema updates + dim_users JOIN for name resolution.

- **`*_by_id` → `*_by` aliasing convention in projections.** When a column
  like `created_by_id` exists in the external table, the curated model
  projects it with the `_id` suffix dropped: `events.created_by_id AS
  created_by`. This pattern is consistent across `notes.sqlx`,
  `targets.sqlx`, `objectives.sqlx`, and `clinical_agreements.sqlx`. When
  investigating whether a "created_by" field exists, search for BOTH
  `created_by` and `created_by_id` — the external table uses the `_id`
  variant, the model uses the bare name.

- **`nonNull` assertions are typically NOT added for audit/actor fields.**
  Fields like `created_by`, `approved_by_id`, `updated_by_id` are excluded
  from `assertions.nonNull` because historical records (created before the
  field was populated) have `NULL`. The invariant is guaranteed upstream
  (core/Rails), not by the Dataform assertion. If investigating whether to
  add an assertion for an actor field, the answer is almost always "no"
  unless every record in the source table has the field as `NOT NULL`.

- **Adding a new column to an existing pipeline touches 4 files.** The
  established pattern (from user stories `20260526-supervision-clinical-
  agreements-created-by` and `20260807-test-orchestrator-created-by-
  workload`) is: (1) `*_events.sqlx` — add field to
  `renderSchemaExternalTable()` array, (2) `*.sqlx` — add to SELECT
  projection, (3) `includes/<domain>/tables/*.js` — add column metadata
  description, (4) `test_*.sqlx` — add to mock inputs and expected output.
  All 4 go in the same PR — none makes sense without the others.

- **Dataform schedules are NOT in the repo — don't confuse them with the deploy `cronjob`.** If a user asks "em que horários roda o job do Dataform?", the schedule is configured in the GCP Dataform console (Workflow Configurations → Schedule), not versioned anywhere in the project. `workflow_settings.yaml` holds only dataset/project/vars/service-accounts — no schedule field. The only `cronjob.schedule` (e.g. `deploy/base/supervision/config/schema.yaml` → `"0 3 * * *"`) is a **Kubernetes CronJob running a Dataflow pipeline** (`intervention_main.py` / `assessment_main.py` via `--runner=DataflowRunner`), a separate job from Dataform. `deploy/base/<name>/manifests/dataform.yaml` only enables the Dataform API + IAM grants — it defines no schedule. To get actual times, read the `WorkflowConfig` via `gcloud`/Dataform API for the env's project id (from `deploy/<env>/<name>/config/data.yaml` → `gcp.id`), or point the user to the console.

- **`ensureTenantField` auto-injects `tenant_id`.** The function
  `renderSchemaExternalTable()` in `includes/functions.js` automatically
  appends `tenant_id` (STRING) to the payload struct if not explicitly
  listed in the field array. When reading an external table schema, note
  that `tenant_id` appears in the rendered BigQuery schema even when absent
  from the `.sqlx` source. Similarly, `fillDefaultTablesAttributes()`
  auto-adds `tenant_id` to column metadata.

## References

- `references/suggested-workload-last-modified-by.md` — Worked example:
  investigating `last_modified_by` in the supervision `suggested_workload`
  table. Includes file inventory, findings, dim_users JOIN pattern, and the
  full implementation dependency chain.
- `references/suggested-workload-created-by.md` — Worked example:
  investigating `created_by` in the supervision `suggested_workload` table.
  Confirms `created_by_id` does not exist in the Rails source table
  (`schema.rb`), documents the `created_by_id` → `created_by` aliasing
  convention, the `nonNull` assertion decision, and the 4-file modification
  pattern with references to prior user stories.

## Cross-references

- **`create_dataform_pipeline`** — The "how to build" counterpart. Covers
  creating new pipelines, the full file trio, config styles, and validation
  queries. Load this when the investigation transitions to implementation.
  Note: this skill is currently user-owned; recommend `hermes curator adopt
  create_dataform_pipeline` to enable consolidation.
- **`investigate-core-flow`** — For investigating the Rails core backend
  (source of CDC data). Load when you need to verify if a field exists in
  the source database.
- **`investigate-bff-flow`** — For investigating the GraphQL BFF layer.
