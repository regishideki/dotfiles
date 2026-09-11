# Session cancellation audit (who cancelled a session)

How to answer "quem cancelou a sessão X?" from BigQuery.

## Tables & fields

`data-kernel-production-4o7n.datakernel.sessions` carries the cancellation audit trail:

- `status` — `'cancelled'` (also `scheduled`, `rescheduled`, `completed`).
- `cancelled_by` — STRING, the `users.id` of whoever performed the cancellation.
- `cancelled_at` — TIMESTAMP of the cancellation action.
- `cancellation` — RECORD with:
  - `reason` — enum, e.g. `schedule_deleted`, `clinical_onsite_issues`, …
  - `requested_by_role` — `'clinician'`, `'caregiver'`, or `'genial'` (internal Genial Care staff).
  - `in_advance` — BOOLEAN.
  - `comment` — free text; often holds the full context (Zoho ticket #, clinical reason).

There is also a deprecated flat `cancellation_reason` STRING — ignore it, use the RECORD.

## Name resolution quirk (important)

`users.first_name` / `users.last_name` are frequently **NULL** for internal staff — so
`JOIN users ON users.id = sessions.cancelled_by` returns null names even when the row exists.
The real human name lives in the ops people table, keyed by email:

```sql
LEFT JOIN `ops-data-production-8fk2.people.collaborators` coll
  ON LOWER(coll.genial_email) = LOWER(u.email)
```

`people.collaborators` has `name`, `genial_email`, `personal_email`, `discipline`. Note it can
return more than one row per email (duplicate display names); dedupe or take MIN(name).

So the robust pattern is: join `sessions.cancelled_by → users.id` to get the email, then join
`users.email → collaborators.genial_email` to get the name.

## Gotchas

- `clinical_cases.number` is **INT64** — filter with `cc.number = 1123`, never `= "1123"`
  (quoting it throws "No matching signature for operator = ... INT64, STRING").
- `start_scheduled_at` is TIMESTAMP; filter a day with `DATE(s.start_scheduled_at) = "YYYY-MM-DD"`.
- A case+date can have MULTIPLE cancelled sessions across disciplines (e.g. TO vs Psico/aba).
  Filter by `discipline` and/or the therapist named in `cancellation.comment` / `s.clinicians`
  to isolate the right one.

## Minimal query

```sql
SELECT
  cc.number, s.discipline, s.start_scheduled_at, s.status,
  s.cancellation.reason, s.cancellation.requested_by_role, s.cancellation.comment,
  s.cancelled_at, u.email AS cancelled_by_email, coll.name AS cancelled_by_name
FROM `data-kernel-production-4o7n.datakernel.clinical_cases` cc
JOIN `data-kernel-production-4o7n.datakernel.sessions` s ON s.clinical_case_id = cc.id
LEFT JOIN `data-kernel-production-4o7n.datakernel.users` u ON u.id = s.cancelled_by
LEFT JOIN `ops-data-production-8fk2.people.collaborators` coll
  ON LOWER(coll.genial_email) = LOWER(u.email)
WHERE cc.number = <case-number> AND s.status = 'cancelled'
ORDER BY s.start_scheduled_at;
```
