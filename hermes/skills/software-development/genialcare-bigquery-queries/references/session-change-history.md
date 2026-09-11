# Tracing session change history (cancellation / reactivation)

`datakernel.sessions` and `scheduling.sessions` are **full-load snapshots** — they only
show the CURRENT state of a session (`status`, `cancelled_at`, `cancellation.*`). To see
the HISTORY of changes to a session (e.g. "was this session cancelled then re-created /
reactivated?"), query the CDC event tables, not the sessions tables.

## The CDC table (source of truth for history)

`data-kernel-production-4o7n.raw.sessions_events` — one row per change, shape:

```
payload.record
  id                       -- the datakernel session id (domain id)
  status                   -- scheduled | cancelled | waiting_replacement | completed | ...
  clinical_case_id
  discipline               -- aba | occupational_therapy | speech_therapy | ...
  start_scheduled_at / end_scheduled_at
  created_by_id / updated_by_id
  cancellation.record (reason, requested_by_role, in_advance, comment)
  cancelled_at / created_at / updated_at
  operational_scheduling_session_id   -- the scheduling.sessions id (different from id!)
source_metadata.change_type  -- INSERT | UPDATE | DELETE
source_timestamp             -- when the change happened (use this for ordering)
```

Trace a session's lifecycle by `WHERE payload.id = '<session id>' ORDER BY source_timestamp`:
- `INSERT` = created
- `UPDATE` with `status` flipping to `cancelled` = cancellation (payload.cancellation.*
  populated, `cancelled_at` set)
- a *later* `INSERT` with a **different** `payload.id` at the same `start_scheduled_at`
  = a **new** session re-created in the same slot (NOT a reactivation of the same row)

## Business event tables — partial, and one is stale

`data-kernel-production-4o7n.events.session_{scheduled,cancelled,rescheduled,completed}`
are pub/sub-style domain events, but **`session_cancelled` stopped being populated after
2025-04-07** (`MAX(metadata_publish_time)` = that date). So for any cancellation in the
current year, `events.session_cancelled` will return nothing — the only reliable source is
the CDC `sessions_events` table. Do not conclude "no cancellation happened" from an empty
`session_cancelled` query.

`events.session_scheduled` IS still current and is a convenient way to list created
sessions (it carries `created_by`, `created_at`). But for cancellation/reactivation
forensics, always fall back to the CDC table.

## Two different session ids — don't mix them

- `datakernel.sessions.id` = domain session id (e.g. `a19b4919-...`)
- `scheduling.sessions.id` = operational id (e.g. `951a994d-...`)

They are linked by `datakernel.sessions.scheduling_session_id = scheduling.sessions.id`.
In the CDC payload, `payload.id` is the datakernel id and
`payload.operational_scheduling_session_id` is the scheduling id. If you query
`scheduling.sessions` with a datakernel id, you get `[]` — resolve via the
`scheduling_session_id` column first.

## "Was the clinician consulted?" → `scheduling.sessions.confirmations`

The `scheduling.sessions` table has a repeated `confirmations` record
(`role`, `user_id`, `confirmed_at`, `source`, `reason`, `context_date`). `source='whatsapp'`
is the automated confirmation bot. This is the evidence for/against "nobody asked me":
if there's a `confirmations` entry with `role='therapist'` and the clinician's `user_id`,
they DID respond to a confirmation (often via WhatsApp bot) — which weakens a "sem me
consultarem" claim. `role` values seen: `caregiver`, `therapist`.

## Actor resolution

- `datakernel.users` → `id`, `email`, `first_name`, `last_name` (NO `name` column).
- `datakernel.clinicians` → `id`, `name`, `specialization`, `status`, `user_id`,
  `user_email`, `user_full_name` (NO `email` column — that's on `users`).

Map `created_by_id` / `updated_by_id` / `cancelled_by` to `users.id` (or
`clinicians.user_id`). A `@genialcare.com.br` email (non-clinician) is typically a
scheduling/operations team member; a `caregiver` role cancellation is the family.

## Timestamps are UTC — convert for "which day" claims

`cancelled_at` / `source_timestamp` are UTC. Brazil is UTC-3, so a `cancelled_at` of
`2026-08-31 00:04:06` = `2026-08-30 ~21:04` BRT. A requester saying "cancelled Sunday
30/08" for that timestamp is correct in local time. `start_scheduled_at` is a wall-clock
value (e.g. `17:00` = 5pm local), so don't apply the -3h shift to scheduled times.

## Worked example (case 1147, session 2026-09-01 17:00)

Reconstructing "was a session cancelled then reactivated without notice":

```sql
SELECT
  payload.id AS session_id,
  source_metadata.change_type AS op,
  payload.status,
  payload.start_scheduled_at,
  payload.cancelled_at,
  payload.cancellation.reason,
  payload.cancellation.requested_by_role,
  payload.cancellation.in_advance,
  payload.created_by_id,
  payload.updated_by_id,
  source_timestamp
FROM `data-kernel-production-4o7n.raw.sessions_events`
WHERE payload.clinical_case_id = '<case uuid>'
  AND payload.start_scheduled_at >= TIMESTAMP('<range start>')
  AND payload.discipline = 'speech_therapy'
ORDER BY payload.start_scheduled_at, source_timestamp
```

Result pattern (this actual case):
1. `INSERT` session `a19b...` 05/08 — original scheduled (created_by dev account).
2. `UPDATE` `a19b...` → `cancelled` 31/08 00:04 UTC, reason `personal_appointment`,
   `requested_by_role='caregiver'`, `in_advance=true` — the FAMILY cancelled (school trip).
3. `INSERT` session `e211...` 31/08 12:37 — **new** session, same 17:00 slot, created by a
   `@genialcare.com.br` scheduling-team user (the "reactivation").
4. `UPDATE` `e211...` → `waiting_replacement` then → `cancelled` 01/09 18:00,
   `requested_by_role='clinician'`, `in_advance=false` — the therapist cancelled at the
   last minute, which is what counts against her as "cancelamento sem aviso".

Verdict: the "cancelled Sunday → reactivated → I had to cancel without notice" narrative
was accurate, EXCEPT the `confirmations` record showed the therapist had replied to a
WhatsApp confirmation at 31/08 23:18 — so "nobody consulted me" was only partially true.

Key read: `in_advance` (`true`/`false`) is the field that drives the "cancelled with/without
advance notice" panel metric. `requested_by_role` (`caregiver` vs `clinician`) tells you
WHO triggered the cancellation — this matters when a clinician is worried about being
penalized for a cancellation the family actually caused.
