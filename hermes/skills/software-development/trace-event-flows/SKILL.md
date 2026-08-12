---
name: trace-event-flows
description: Use when tracing event cascades across packs.
---

# trace-event-flows

The GenialCare monolith is event-driven. Domain events flow across pack
boundaries (operational → clinical, clinical → operational, etc.) via
Google Cloud Pub/Sub topics. Understanding "does the system do X when Y
happens?" requires tracing the full event chain: who emits, who listens,
what job runs, what use case executes, and what side effects cascade.

Guessing from memory or reading only one pack produces wrong answers.
Always trace the full chain.

## When to load this skill

- The user asks whether the system does something automatically
  ("existe alguma parte que remove clínicos?").
- You need to understand a cascade ("does churn trigger X which triggers Y?").
- You are debugging why an event-driven side effect did or didn't fire.
- You are adding a new event subscriber and need to see existing patterns.
- You need to find all consumers of a domain event.

## Architecture: where things live

1. **Event definitions** — `packs/<pack>/app/concepts/<domain>/events/<event_name>.rb`
   Each event class `include BaseEvent`, declares `attribute`s, defines
   `topic_id` and `name` (or `resource_id`). This is the source of truth
   for the topic string and event name string.

2. **Event emission** — inside use cases, typically in a `build_events`
   step: `ctx[:events] << EventClass.build_from(...)`. The
   `Events::Trailblazer::EmitEvent` step publishes them.

3. **Subscriber registries (TWO locations — check both):**
   - `event_consumer_start.rb` at the REPOSITORY ROOT — the main registry,
     contains most `config.add(topic:, event:, subscription:, job:, mapper:)`
     entries.
   - `packs/<pack>/app/infra/subscribers/<domain>/<name>_subscriber.rb` —
     pack-local subscriber classes with a `self.configure(config)` method.
     These are loaded alongside the root registry. Do NOT miss these.

4. **Jobs** — `packs/<pack>/app/jobs/...` — the subscriber's `job:` field
   points here. Jobs either call a use case directly or dispatch via
   `ExecuteUseCaseJob` with a `use_case` class and `data` hash.

5. **Recurring jobs** — `config/recurring.yml` — scheduled jobs that run
   on a cron. Check here when a side effect has a time delay (e.g.
   "removal happens at 6AM the next day").

## Tracing procedure

### A. Forward trace (from an event to its consequences)

1. Find the event class definition. `search_files` for the event name
   string or class name.
2. Note `topic_id` and `name` (event name string) from the class.
3. Search BOTH registries for that topic + event name:
   - `search_files pattern="people.children.v1" target=content path=config`
   - `search_files pattern="people.children.v1" target=content path=packs`
   - Also search `event_consumer_start.rb` (root) — it is NOT under
     `config/` or `packs/`.
4. For each subscriber found, read the `job:` class and the `mapper:`
   lambda to see what data is passed.
5. Read the job → read the use case it calls → repeat from step 1 if
   the use case emits new events.

### B. Backward trace (from a side effect to its trigger)

1. Find the use case or model method that produces the side effect
   (e.g. `RemoveClinician` destroys a `ClinicalCaseClinician`).
2. Find who calls that use case — search for the class name.
3. If it's called by a job, find who enqueues the job — search for
   `perform_later` with the job class name.
4. If the job is triggered by a subscriber, search for the job class
   name in both subscriber registries.
5. Note the event name → find the event class → find `build_from` call
   sites → that's the emitter.

### C. Chain trace (full cascade verification)

When the user proposes a multi-step hypothesis ("A causes B causes C"),
trace each link independently and verify the connecting event. Common
pattern: the intermediate event has a conditional emission — e.g.
`AllSchedulingForCollaboratorInClinicalCaseDiscarded` is only emitted
when `schedule.official? && schedule.intervention?`. Check these
conditions; they are silent failure points where the chain breaks.

## Key patterns in this codebase

- **Topic naming**: `<domain>.<entity>.v1` (e.g. `people.children.v1`,
  `scheduling.schedule.v1`, `general.clinical_cases.v1`).
- **Subscription naming**: `core-<event-name>-<purpose>-sub` or
  `<domain>-<event-name>-<purpose>-sub`.
- **Delayed side effects**: some chains have time delays. The
  `ScheduleClinicianDeallocation` use case sets `to_be_removed_at` to
  `Date.current + 14.days`, and a daily recurring job at 6AM
  (`config/recurring.yml` → `schedule_deallocate_clinical_case_clinicians`)
  picks up expired entries. When a user says "it didn't happen," check
  for delayed execution.
- **Conditional emission**: events are often emitted only under specific
  conditions (official schedules, intervention type, churned contract).
  These conditions are the most common reason a chain "doesn't fire."
- **Cross-pack events**: operational emits `child_churned`, clinical
  consumes nothing from it — but scheduling (also operational) consumes
  it and emits `scheduling` events that clinical then consumes. The
  chain crosses packs through event topics, not direct calls.

## Datastream CDC vs PubSub: two distinct data flow mechanisms

The GenialCare platform has **two independent** mechanisms for flowing
data to downstream systems. They are NOT the same and do NOT share
payloads:

1. **PubSub events** (covered above) — domain events emitted by use
   cases via `Events::Trailblazer::EmitEvent`. The event payload
   contains only the attributes declared in the event class. Consumers
   are in `event_consumer_start.rb` and pack-local subscribers.

2. **Google Cloud Datastream CDC** — replicates PostgreSQL table changes
   directly to GCS
   (`gs://genialcare-event-store-{env}/streams/database-events/core/public_{table_name}/*`),
   which BigQuery external tables (in the **supervision** project, a
   Dataform pipeline) read. This is how data reaches the data warehouse.
   Datastream replicates **all DB columns** automatically — it does NOT
   depend on event payloads.

**Implication**: When a feature asks to "expose a field in CDC for
supervision," check whether the column already exists in the DB table.
If it does, Datastream already replicates it — the work is in the
supervision project's Dataform definitions (creating the `_events.sqlx`
external table and `.sqlx` transformation), NOT in the core's event
payload. Changing PubSub event payloads only affects PubSub subscribers
(finance, agenda, marketplace), not the supervision data warehouse.

For a worked example of the supervision CDC pattern, see
`investigate-core-flow` → `references/clinical-case-workload-investigation.md`
(section "Supervision CDC: how data flows to the data warehouse").

## Pitfalls

- **Don't search only `config/`.** The main registry is
  `event_consumer_start.rb` at the repository root — it is not under
  `config/`. Searching `config/` alone misses it.
- **Don't forget pack-local subscribers.** `packs/*/app/infra/subscribers/`
  contain additional `config.add` calls. Search both locations.
- **Don't assume a chain is unbroken.** Each event emission has
  conditions. Verify each condition holds or the chain stops silently
  with no error, no log, no side effect.
- **Don't conflate "event emitted" with "side effect happened."** An
  event being emitted only means a message was published. The subscriber
  job must run successfully for the side effect to occur. If debugging
  "it didn't happen," check SolidQueue for failed jobs (see
  `solid-queue-failures` skill).
- **Don't trust memory for topic strings.** Always read the event class
  definition for the exact `topic_id` and `name` — they are the
  ground truth.
- **Don't conflate PubSub events with Datastream CDC.** They are
  independent. Adding a field to a PubSub event payload does NOT make
  it appear in the supervision data warehouse. Conversely, a DB column
  added to a table is automatically replicated by Datastream without
  any event change. See the section above for details.

## References

- `references/churn-to-clinician-removal-chain.md` — full traced chain
  from contract churn to clinician removal, with file paths and line
  numbers. Example of a 5-link event cascade.
