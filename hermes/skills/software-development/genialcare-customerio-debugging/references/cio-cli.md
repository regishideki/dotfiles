# Customer.io CLI (`cio`) — inspect/edit campaigns & journeys

Official "agent-first" CLI for Customer.io APIs. Best for: inspecting a campaign/journey definition, verifying whether a domain event actually reaches Customer.io, and (with write ops) editing campaigns programmatically without the UI.

## Install & auth

```bash
npm i -g @customerio/cli          # binary: cio
# Service account token (sa_live_...) from UI:
#   Account Settings → Manage API Credentials → Service Accounts → create token
printf '%s' "$SA_TOKEN" | cio auth login --with-token   # caches to ~/.cio/config.json
cio auth status
```

Token resolution order: `--token` flag → `CIO_TOKEN` env var → `~/.cio/config.json`. The service account token is a DIFFERENT credential from the `CUSTOMER_IO_APP_API_KEY`/`CUSTOMER_IO_API_KEY` the core uses.

## GenialCare workspaces

| environment_id | name            | role          |
|----------------|-----------------|---------------|
| `113537`       | Genial Care     | produção      |
| `114048`       | Genial Care Test| teste/staging |

(account_id = `70619`.)

## Key commands

```bash
# list environments
cio api /v1/accounts/{account_id}/environments

# list campaigns (id + name + type + state)
cio api /v1/environments/{environment_id}/campaigns \
  --params '{"environment_id":"113537"}' --jq '.campaigns[] | {id, name, type, state}'

# full campaign/journey definition (trigger, actions, edges)
cio api /v1/environments/{environment_id}/campaigns/{campaign_id} \
  --params '{"environment_id":"...","campaign_id":"..."}'

# data sources (CDP) — to see how data reaches Customer.io
cio api /cdp/api/workspaces/{workspace_id}/sources --params '{"workspace_id":"..."}'

# introspect endpoints (works without auth; downloads OpenAPI spec)
cio schema | jq '.[] | select(.resource | test("campaign|journey|segment"))'
```

Write ops use `--json '<payload>'`; always `--dry-run` first. `--jq '<expr>'` filters to save context.

## Live cost/volume, object types & stuck subjects

```bash
# LIVE billing/volume (objects/people/messages, high watermark, churn) — authoritative, beats the docs snapshot
cio api /v1/accounts/{account_id}/usage
#   objects_allotted (free=500), objects_total (live), high_watermark_objects_total (what's billed),
#   objects_churn (deleted this period), customers_total/allotted, messages_sent/allotted

# object types (GenialCare has only "Sessions" and "Offers" — no ClinicalCase/Agreement)
cio api /v1/environments/{environment_id}/object_types

# force a person out of a journey (the "stuck subject" escape hatch after a rule change)
cio api /v1/environments/{environment_id}/subjects/{subject_id}/force_exit -X POST
```

Cost-cutting context (2026-09): the team removed **session** objects specifically (the ~20k high-watermark leak), NOT all objects — `Offers` remain and are being consolidated (one Offer per replacement). `usage` is the live source; the feature doc `customer-io-session-objects/doc.md` has a ~23k snapshot that predates the cleanup.

## Inspecting a customer's deliveries & journey enrollment

The naive `/customers/{id}/events` and `/customers/{id}/deliveries` paths are NOT real
endpoints (preflight rejects them). The `events` resource is POST-only (send) — there is
NO read API for a customer's event history. Use two TOP-LEVEL endpoints instead:

**Resolve core `user.id`/email → customer.io `internal_id` first.** The deliveries/subjects
endpoints need the customer.io `internal_id` (short hex like `81f70600f709f809`), NOT the core
UUID. Look it up by the profile's identifier (core keys customer.io by `email`):
`cio api /v1/environments/{env}/customers --params '{"email":"<email>"}' --jq '.customers[0].id'`.
Get the email from core Postgres (`SELECT email FROM users WHERE id='<uuid>'`); if email is blank,
core falls back to `{id: <uuid>}` as the identifier, so search by that UUID text instead.

**Confirming a specific WhatsApp delivery for a `utm_campaign` deep link** (the "did this person
really get the WhatsApp alert" question): (1) resolve `internal_id` as above; (2) list deliveries
`cio api /v1/environments/{env}/deliveries --params '{"customer_id":"<internal_id>"}'`; (3)
`action_type == "twilio_action"` = WhatsApp/SMS (Twilio is the WhatsApp channel); `state ==
"delivered"` = Twilio confirmed handoff to the phone — this is the proof, not `sent`. Filter
`campaign_id` to the right campaign and compare `created` epoch against the click timestamp from
RUM. **The `utm_campaign=X` in a deep link maps to the campaign whose `trigger_event == X`, not
necessarily the campaign's display `name`** — confirm with
`cio api /v1/environments/{env}/campaigns/{id} --jq '.campaign | {name, event}'`. (Worked example:
`utm_campaign=next_session_notification` → campaign 23 "Mensagem lembrete da próxima sessão para o
terapeuta", `event: "next_session_notification"`.) Note the `deliveries` response is paginated
(50/page with a `meta.continuation` token) and newest-first, so the first page IS the most recent
history.

- **Deliveries** — `GET /v1/environments/{env}/deliveries?customer_id=<cio_id>` where `cio_id`
  is the customer.io `internal_id` (e.g. `81f70600d818d918`), NOT the core user UUID. Returns
  full push/email/whatsapp history. Each item: `campaign_id`, `subject`, `state`
  (`sent`/`delivered`/`failed`), `action_type` (`push_action`/`twilio_action`/…), `template_id`,
  `created`/`sent`/`delivered` epoch timestamps. Answer "did this person get a push from campaign
  X?" by filtering `campaign_id` == X (zero matching rows = never fired for them).

- **Subjects (journey enrollment)** — `GET /v1/environments/{env}/subjects?customer_id=<cio_id>`
  OR `?campaign_id=<id>`. Each subject: `campaign_id`, `subject_state` (`active` = still in the
  journey loop, `finished` = exited), `match_time`, `next_wake_up`, `next_action_id`. A future
  `next_wake_up` + `subject_state: active` = a reminder is scheduled. Answer "is this person
  enrolled in journey X?" by checking for a subject with `campaign_id` == X.

- **`cio schema` output shape** — returns a list of `{resource, count, endpoints:[{http_method,
  method, path, summary}]}`. The path lives in `endpoints[].path`, NOT at the top level. Grep the
  resource list for `deliveries`/`subjects`/`events` to find real paths before guessing a URL.

**Verifying "was event E sent to customer.io retroactively"** — three checks, in order:
1. Code: is E `track_event`'d, and is the consumer forward-only (Pub/Sub, no backfill)?
2. Deliveries: does the profile have any delivery with the `campaign_id` of the journey E would
   stop/trigger? Zero = the journey never fired for them.
3. Subjects: any subject with that `campaign_id`? `active` = still stuck; `finished`/absent =
   never enrolled. Worked example (COPM case 1559): agreement completed 27/08, before PR #6713
   shipped the `agreement_completed` track_event on 16/09 — so the completion never reached
   customer.io. But the caregiver had 0 deliveries + no subject on campaign 8, so no spurious push
   occurred. The retroactivity gap is real/systemic, yet per-profile impact is PROVEN via
   deliveries+subjects, never assumed from the gap alone.

## Decoding a journey (campaign) definition

`GET .../campaigns/{id}` returns a `campaign` object plus an `actions[]` array and `edges[]` graph:

- `campaign.event` / `event_type` — trigger (e.g. `agreement_created`, `event_type: "event"`).
- `campaign.restart_mode` — `"rematch"` = re-triggering re-enters the journey (used for loops).
- `campaign.edges` — directed `{from, to, type}`; `type: "branch"` edges carry `index` (branch 0 vs 1).
- `actions[]` nodes:
  - `push_action` — sends push (`template_id`, `name`).
  - `conditional_wait_action` — waits `delay` (seconds) for events in `multi_conditions` (base64-encoded JSON). Branch 0 = condition matched; branch 1 = timeout.
  - `create_event_action` — re-emits an event (static `event_name`) to drive a loop, combined with `restart_mode: rematch`.
  - `exit_action` — ends the journey.

Recurring-reminder loop pattern (seen in "Combinados — Acompanhamento", test id 7):

```
agreement_created → push
  → conditional_wait(agreement_completed OR agreement_deleted, delay)
       ├─ matched?   → exit (stop)
       └─ timeout?   → re-emit agreement_created → push (loop)
```

## Verifying whether a domain event reaches Customer.io

A journey stop/exit condition that waits on a foreign event (e.g. `agreement_completed`) only fires if that event actually reaches Customer.io. Two checks:

1. **Core code:** grep for `track_event` in `app/` and `packs/`. This is the ONLY explicit path. If the core tracks only `agreement_created` but the journey waits for `agreement_completed`, the stop condition never fires (silent bug — reminders continue after completion).
2. **CDP sources:** `cio api /cdp/api/workspaces/{workspace_id}/sources`. If the only sources are "Journeys API" (the Track API the core writes to), "Mobile App", and "Clinical Panel" — there is NO Pub/Sub connector, so domain events not explicitly `track_event`'d never arrive.

## Cost model (quick reference)

- "Monthly push and in-app" is **unlimited** on all plans.
- Billed: profiles (people + objects) by **high watermark** (500 free on Essentials), emails (1M/mo), SMS/WhatsApp (per message).
- → recurring reminders via **event + push** = zero incremental cost. Modeling things as **objects** is what drives overage (the `$450`/40k-objects incident was session objects, not events).
