# Tracing "who did what, when" on objectives (CDC)

When a user asks *when a specific clinician completed/validated/rejected the
objectives (a.k.a. "registros de OC" / Objetivos Clínicos) of a set of cases*,
the source of truth is the CDC stream `supervision-production-8f1v.raw.objectives_events`.

## Payload fields (under `payload.*`)

- `id` — the objective primary key (`objectives.objective_id`). Join on this.
- `description` — objective text.
- `status` — one of `validated`, `completed`, `rejected`, `pending`, `in_maintenance`, `null`.
- `updated_at` — when that status change happened (string, `YYYY-MM-DD HH:MM:SS`).
- `updated_by_id` — the actor who made the change (user id).
- `created_by_id`, `created_at`, `intervention_pei_id`, `protocol_item_id`, `tenant_id`.

## Join path

```
clinical_cases cc → peis (pei.clinical_case_id = cc.id)
  → objectives obj (obj.pei_id = pei.id)
  → objectives_events ev (ev.payload.id = obj.objective_id)
```

Filter `ev.payload.updated_by_id = '<user id>'` to scope to one clinician.

## Two distinct "completion" concepts — do NOT conflate

- `status = 'validated'` → the clinician **finished filling out the record**
  ("preenchimento concluído"). This is what "completou o registro de OC" means.
- `status = 'completed'` → the **objective was achieved** ("objetivo concluído"),
  a later, separate event.

When the ask is "quando X completou os registros", default to `validated`, but
ALSO surface the latest `completed` per case — in practice the most recent action
is sometimes a `completed` (e.g. a case validated months ago but completed last week).
Present both, labeled, rather than guessing.

## Actor id → email

`data-kernel-production-4o7n.datakernel.users` — columns are `id`, `email`,
`first_name`, `last_name`, `created_at`, `updated_at`. **There is NO `name` column**
(querying `name` errors with "Unrecognized name: name"). `first_name`/`last_name`
are often NULL, so look up by `email` and read back `id`.

## Pitfalls

- **CDC rows are duplicated** — the same event (same objective + status + updated_at)
  can appear twice. Use `SELECT DISTINCT` on the payload columns before grouping.
- Timestamps come back as stored (no timezone conversion). If the user needs
  `America/Sao_Paulo`, note the values are as-inserted and offer to convert.

## Compact pattern (most recent validated + completed per case)

```sql
WITH events AS (
  SELECT DISTINCT
    cc.number AS case_number,
    ev.payload.id AS objective_id,
    ev.payload.status AS status,
    ev.payload.updated_at AS updated_at
  FROM `data-kernel-production-4o7n.datakernel.clinical_cases` cc
  JOIN `supervision-production-8f1v.intervention.peis` pei ON pei.clinical_case_id = cc.id
  JOIN `supervision-production-8f1v.intervention.objectives` obj ON obj.pei_id = pei.id
  JOIN `supervision-production-8f1v.raw.objectives_events` ev ON ev.payload.id = obj.objective_id
  WHERE cc.number IN (782, 264, 227, 1166, 567, 676, 490)
    AND ev.payload.updated_by_id = '<clinician user id>'
    AND ev.payload.status IN ('validated','completed')
)
SELECT case_number, status, MAX(updated_at) AS last_at, COUNT(*) AS total_records
FROM events
GROUP BY case_number, status
ORDER BY case_number, status
```
