# Intervention Schema Reference

Schema details for the `supervision-production-8f1v.intervention` dataset,
discovered via `INFORMATION_SCHEMA.TABLES` and `INFORMATION_SCHEMA.COLUMNS`.

## evolution_check_configurations

Links to `library_objectives` via `library_objective_id`. Stores the
*configuration* (template) of how an objective should be checked — not the
actual check results.

| column | type | notes |
|--------|------|-------|
| `id` | STRING | primary key |
| `library_objective_id` | STRING | FK → `library_objectives.id` |
| `version` | STRING | e.g. `"1"` |
| `configuration_type` | STRING | `"trial_counter"` (1316 rows) or `"checklist"` (84 rows) |
| `completion_threshold` | FLOAT64 | nullable; only set for `checklist` type |
| `unit_of_measurement` | STRING | e.g. `"quantidade"`, `"vezes"` |
| `max_measurements` | INT64 | e.g. 6, 10, 30 |
| `instructions` | STRING | clinician guidance text |
| `prerequisites` | ARRAY<STRUCT<name STRING>> | pré-requisitos (trial_counter) |
| `requisites` | ARRAY<STRUCT<name STRING>> | checklist items (checklist type) |
| `tenant_id` | STRING | |
| `created_by_id` | STRING | |
| `created_at` | TIMESTAMP | |
| `updated_at` | TIMESTAMP | |

### configuration_type distribution (as of 2026-07)

- `trial_counter`: 1316 configurations — counts how many times the child
  performed the target behavior. Has `prerequisites` (skills the child needs
  before this objective can be assessed) but no `requisites`.
- `checklist`: 84 configurations — a list of items (`requisites`) the child
  must demonstrate. Has `completion_threshold` (how many requisites must be
  checked). `prerequisites` is typically empty.

## objectives

| column | type | notes |
|--------|------|-------|
| `objective_id` | STRING | **primary key** (not `id`) |
| `pei_id` | STRING | FK → `peis.id` |
| `skill_id` | STRING | |
| `tenant_id` | STRING | |
| `description` | STRING | |
| `status` | STRING | e.g. `validated`, `completed`, `active` |
| `protocol_item_id` | STRING | |
| `protocol_item_type` | STRING | |
| `vineland_report_subdomain_item_score_id` | STRING | |
| `created_by` | STRING | |
| `updated_by` | STRING | |
| `discarded_by` | STRING | |
| `discarded_at` | TIMESTAMP | null = active |
| `created_at` | TIMESTAMP | |
| `updated_at` | TIMESTAMP | |
| `library_objective_id` | STRING | FK → `library_objectives.id` |

**Gotcha**: PK is `objective_id`, not `id`. Other tables reference it as
`intervention_objective_id` (e.g. `objective_evolution_checks`).

## library_objectives

| column | type | notes |
|--------|------|-------|
| `id` | STRING | primary key |
| `protocol_item_id` | STRING | FK → `protocol_items.id` |
| `skill_id` | STRING | |
| `tenant_id` | STRING | |
| `description` | STRING | |
| `target_category` | STRING | |
| `objective_order` | INT64 | nullable in some rows |
| `session_type` | STRING | e.g. `"playtime_together"` |
| `tags` | ARRAY<STRING> | e.g. `["requires_vocalization"]` |
| `created_at` | TIMESTAMP | |
| `updated_at` | TIMESTAMP | |
| `discarded_at` | TIMESTAMP | |

## Related tables (names only)

Discovered via `INFORMATION_SCHEMA.TABLES LIKE '%evolution%' OR '%check%'`:

- `evolution_check_configurations` — configuration/template (see above)
- `evolution_checks` — actual check sessions (FK to `sessions`)
- `objective_evolution_checks` — junction: objective ↔ evolution_check
- `fct_objective_evolution_check` — fact table (denormalized)
- `int_evolution_check_prerequisite_counts` — intermediate/precomputed
- `int_objective_evolution_check` — intermediate/precomputed
- `int_vineland_aba_objective_evolution_check` — intermediate/precomputed

## Discipline → protocol name mapping

| protocol.name | Discipline |
|---------------|------------|
| `Fonoaudiologia` | Fono |
| `Terapia Ocupacional` | TO |
| `Vineland 3` | Psico |

## Tenant IDs

| tenant_id | name |
|-----------|------|
| `6f8da042-2dd1-4872-a613-84d371bde78c` | GenialCare |
| `a4d02a8c-4c27-41b6-80ac-3401f3964e34` | Care+Mindplace |

Multiple protocols share the same `name` (e.g. two "Fonoaudiologia" protocols, one per tenant). When querying `library_objectives` or `protocols` directly (without the `active_clinical_cases` CTE), always filter by `tenant_id` to avoid duplicate rows.

## How to discover more schema

```sql
-- All tables in intervention dataset
SELECT table_name
FROM `supervision-production-8f1v.intervention.INFORMATION_SCHEMA.TABLES`
ORDER BY table_name;

-- Columns of a specific table
SELECT column_name, data_type
FROM `supervision-production-8f1v.intervention.INFORMATION_SCHEMA.COLUMNS`
WHERE table_name = '<table_name>'
ORDER BY ordinal_position;

-- Sample rows
SELECT * FROM `supervision-production-8f1v.intervention.<table_name>` LIMIT 5;
```
