# Agreement reminder lifecycle (customer.io journey + core events)

The "Combinados — Acompanhamento" reminder journey and how the core feeds (or fails to
feed) its stop condition. Load when debugging "lembrete de combinado não para de chegar",
"família recebe lembrete de combinado já concluído", or designing changes to the agreement
reminder flow.

## The journey (campaign id 8, prod env 113537)

- trigger: `agreement_created` event, `restart_mode: rematch`.
- graph: push "agreements available" → `conditional_wait_action` (delay **172800s = 2 days**)
  → matched? exit : `create_event_action` re-emits `agreement_created` (loop).
- stop condition (`multi_conditions`, base64) waits for a **foreign event**
  `agreement_completed` OR `agreement_deleted`, with `attribute_compare` on `agreement_id`
  (foreign-event attribute `agreement_id` == triggering event's `agreement_id`).

## The bug (pre PR #6713)

Core tracked `agreement_created` to customer.io (`NotifyAgreementCreated` →
`customer_io.track_event`), but `agreement_completed` / `agreement_deleted` /
`agreement_uncompleted` were **only emitted as Pub/Sub domain events** (topic
`parental_orientation.agreement.v1`) via `Events::Trailblazer::EmitEvent.call` — never
`customer_io.track_event`. So the stop condition never fired → reminders looped every
2 days even after completion. This is the "journey waits for a foreign event the core
never sends" silent bug (see `cio-cli.md` § verifying domain events).

## The fix (PR #6713, Lavínia Beghini, merged 16/set/2026)

New consumer `CustomerIo::UseCases::ConsumeAgreementLifecycleChanged` registered in
`event_consumer_start.rb` for the 4 lifecycle events (`agreement_created`,
`agreement_completed`, `agreement_deleted`, `agreement_uncompleted`). It enriches each
with child/family data and `track_event`s with `name = lifecycle_event` (so the event
name matches the journey's stop condition) and
`resource_id = "{agreement_id}--{lifecycle_event}--{occurred_at}"` (dedup per occurrence).
The domain events gained extra attributes (title, description, type, category_label,
due_date, native_form_type).

## Retroactivity gap (forward-only, NO backfill)

The consumer is **Pub/Sub-based** → it only processes events emitted **after** deploy.
`agreement_completed` emitted before the deploy is gone (Pub/Sub retention + no consumer
running at the time). The PR has **no rake/backfill task**. Consequence: agreements
completed before the deploy stay stuck in the reminder loop. Same gap applies to
`agreement_created` for agreements created before the old `NotifyAgreementCreated`
consumer existed. When sizing blast radius or planning remediation, assume a manual
backfill is required for anything completed/created before the deploy date.

## `cio` CLI snippets used to inspect this

```bash
# list campaigns
cio api /v1/environments/113537/campaigns --params '{"environment_id":"113537"}' \
  --jq '.campaigns[] | {id,name,type,state}'

# full campaign (actions[] + edges[])
cio api /v1/environments/113537/campaigns/8 --params '{"environment_id":"113537","campaign_id":"8"}'
```

Decode `conditional_wait_action.multi_conditions` (base64 → URL-decode → JSON):

```python
import base64, urllib.parse, json
mc = action["multi_conditions"]  # list of base64 strings
for b in mc:
    print(json.loads(urllib.parse.unquote(base64.b64decode(b).decode())))
```

Look up a profile **by user UUID** (the `id` identifier), not by email — email lookup 404s:

```bash
cio api "/v1/environments/113537/customers/<user_uuid>" \
  --params '{"environment_id":"113537","customer_id":"<user_uuid>"}'
```
