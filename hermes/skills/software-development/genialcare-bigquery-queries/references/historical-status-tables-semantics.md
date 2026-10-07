# Supervision "historical" tables are NOT append-only logs

When reconciling two BQ tables and finding a "divergence", understand the table
semantics BEFORE concluding it's an app bug. GenialCare's `supervision` dataform
pipeline builds `*_status_*` "historical" tables (e.g. `intervention.historical_status_objectives`,
`.../targets/historical/historical_status_targets`) that are **deduped by
`(id, status)`** — they keep only the FIRST transition into each status, not
every transition.

## The mechanism (supervision/includes/functions.js → `renderHistoricalEventTable`)

```sql
ROW_NUMBER() OVER (
  PARTITION BY id, ${group_by_field}   -- group_by_field defaults to "status"
  ORDER BY source_timestamp ASC, lsn ASC, read_timestamp ASC
) AS rnk
...
WHERE rnk = 1
```

Plus the table config asserts `uniqueKeys: [["id", "status"]]` (see
`supervision/includes/intervention/tables/historical_status_objectives.js`),
which confirms the dedup is intentional design, not a bug.

Source is the Datastream CDC raw table `objectives_events` (external table over
`gs://genialcare-event-store-*/streams/database-events/core/public_intervention_objectives/*`).

## Consequence: "re-open" transitions are silently dropped

Clinical workflows re-open objectives constantly: `completed → validated`,
`validated → pending`, `completed → in_maintenance`, etc. When an objective
returns to a status it already had, that return is NOT recorded — the
`(id, status)` pair already exists at `rnk = 1`.

## Signature of a false "divergence" (real case, 2026-09)

Reported as "objectives.status disagrees with historical_status_objectives".
Investigation on `supervision-production-8f1v` found ~3.5% of non-discarded
objectives "divergent" — but 100% of them had:

1. current `objectives.status` already present in the log at an EARLIER
   `occurred_at` (i.e. the objective left that status and came back); and
2. `objectives.updated_at > last log occurred_at` (the return happened after the
   last logged transition).

Both are the re-open pattern, not data corruption.

## Rules

- **`objectives.status` is the source of truth for CURRENT state.** The
  `historical_status_objectives` table is for dwell-time analysis
  (`change_duration_in_seconds` = time since the previous different status),
  NOT for deriving current status.
- Do NOT compare `objectives.status` against the latest
  `historical_status_objectives` row to "detect divergence" — it produces false
  positives on every re-opened objective.
- If a dashboard/metric derives "current status" or "aderência" from the LATEST
  row of a `historical_*` table instead of the base table's `status`, THAT is the
  real bug to fix.

## Reuse

The same `renderHistoricalEventTable` pattern (with `group_by_field`) drives the
targets/objectives "historical" tables — the first-occurrence-per-status gotcha
applies to all of them, not just objectives.
