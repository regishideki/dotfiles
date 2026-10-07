---
name: genialcare-customerio-debugging
description: Debug & design GenialCare customer.io identify/device/push flows (cost model, idempotency, push path).
---

# GenialCare customer.io debugging

Use when investigating customer.io identify, device registration, or push delivery across the GenialCare systems (mobile RN app, mobile-bff, core Rails) — OR when designing/planning a new customer.io notification (reminders, campaigns, journeys) where cost and idempotency matter. Trigger phrases: "device não associa", "push não funciona", "identify", "device token", "customer.io", or any dispute about where device/identify responsibility should live.

## The one fact that resolves most disputes

**Profiles in customer.io are keyed by a single identifier. Every system that writes to customer.io MUST use the same identifier, or they silently create different profiles.**

The identifier is either:
- `email` (normalized, e.g. `userId: trimmedEmail` in mobile, `identifiers: {email: user.email}` in core), or
- `id` (the core `user.id` UUID).

A "device não associa" / "identifica mas o device não aparece" symptom is almost always **identifier divergence between two systems**, NOT an architectural/responsibility problem. Diagnose the identifier before debating architecture.

## Where each system writes

- **Mobile** (`mobile/src/integrations/customerio/`): the customer.io SDK (`customerio-reactnative`).
  - `identify.ts` — `CustomerIO.identify({userId, traits})`. Identifies the USER only; does NOT register the device token.
  - `initialize.ts` / `config.ts` — SDK init, `cdpApiKey` + `migrationSiteId`, `push` config.
  - iOS `MyAppPushNotificationsHandler.swift` — `MessagingPush.shared.messaging(_, didReceiveRegistrationToken:)` registers the device token via SDK (iOS only).
  - Android — NO SDK-side device registration. Device token flows only via core.
- **mobile-bff** (`src/data-sources/core/users-api.ts`): `createOrUpdateUserDevice` → `PUT /users/devices/:id.json` on core.
- **Core** (`core/app/infra/customer_io/client.rb`): the Track v2 API (`/api/v2/entity`), NOT the SDK.
  - `identify` / `add_device` / `track_event` all go through `customer_io_identifiers(user)` = `{email: user.email}` (fallback `{id: user.id}` when email blank).
  - `CreateOrUpdate` use case (`packs/clinical/app/concepts/user_devices/use_cases/create_or_update.rb`) does its OWN `identify` then `add_device` — it does NOT depend on the app's identify.

## Ghost-profile pitfall (Track v1 vs v2)

Passing `email` in the `id` field of the **Track v1 API** does NOT auto-detect it as an email (that auto-detect is SDK-JS behavior only). It creates a **ghost profile**: `identifiers.id = <email text>`, `identifiers.email = null` — because the real email already belongs to another profile. The device then attaches to the ghost, not the real profile.

The fix is the Track v2 API with explicit identifiers. See `references/customerio-identifiers.md` for the full commit trail and mechanism.

## Deploy topology (what code is live in which env)

Core (`core/.github/workflows/`):
- push to `development` → auto-deploy to **development** env (`deploy-development.yaml`).
- push to `main` → deploy to **staging** then **production** (`deploy.yaml`).

So a commit merged only to `development` is live in development but NOT staging/prod. A change merged to mobile `main` but not core `main` = divergence in staging/prod even when development looks consistent.

## "Half-rolled-out migration" diagnosis pattern

A migration (e.g. switching the customer.io identifier from UUID to email) that lands in one repo/branch but not the other produces env-specific divergence:

1. Check which branches contain the change: `git branch -a --contains <commit>` in each repo.
2. Map branches to environments via the deploy workflows (above).
3. Conclude: e.g. "mobile main = email, core main = UUID → staging is inconsistent; core change never reached main."

The fix is usually "complete the rollout" (merge the lagging side), not a rewrite.

## Cost, idempotency & push path (design-time constraints)

Use this skill not just to debug, but to DESIGN any new customer.io notification. Three durable facts govern every decision — full detail in `references/cost-idempotency-push-path.md`:

1. **Cost = objects, not events.** Billing is High Watermark over People+Objects (500 free, ~$0,009/object over). Events are cheap and never count as objects. Prefer `event + campaign`; only model an `object` when there's real state/lifecycle to orchestrate (ADR 0013). A recurring reminder "until completed" needs NO objects.
2. **`track_event` is idempotent** on `infra_push_notifications` with key `(tenant_id, user_id, event_id, event_name)` and `event_id = resource_id`. Re-emitting the same event name+id won't resend — recurring reminders need a NEW event name + per-period id, or `check_idempotency: false`.
3. **Mobile system push = customer.io only.** `Notification::NotifyUsers` writes Firestore (in-app bell) + FCM for BROWSER devices only. The phone gets a lock-screen push exclusively through customer.io (device token registered via `add_device`).

For **recurring/conditional** notifications, there's also a design fork over *where the loop lives* (job no core vs. jornada vs. objetos+segmento) whose deciding criterion is who holds state — full three-option comparison + cost math in `references/loop-placement.md`.

## Inspecting campaigns/journeys via the `cio` CLI

To read or edit Customer.io campaigns/journeys programmatically — trigger, waits, loops, stop conditions — or to verify whether a journey's exit condition (a foreign event like `agreement_completed`) can actually fire, use the official `cio` CLI (`npm i -g @customerio/cli`). Install/auth, the GenialCare workspace IDs (prod `113537`, test `114048`), how to decode a journey graph (`conditional_wait_action` + `create_event_action` + `restart_mode: rematch`), and the two-step recipe for verifying an event actually reaches Customer.io (grep `track_event` in core + check CDP sources for a Pub/Sub connector) are in `references/cio-cli.md`.

## Pitfall — a journey stop-condition waits on a foreign event that core only emits as a Pub/Sub domain event, never `track_event`'d

Confirmed case (2026-09): "Combinados — Acompanhamento" (campaign `8`, prod `113537`) triggers on `agreement_created`, pushes, then `conditional_wait` (172800s) for `agreement_completed` OR `agreement_deleted` matched on `agreement_id`, else `create_event_action` re-emits `agreement_created` (`restart_mode: rematch` → infinite loop).

Core `track_event`s ONLY `agreement_created` (`NotifyAgreementCreated`). Completion (`MakeComplete`, called by `SubmitCopmForm`) builds `Agreements::Events::AgreementCompleted` and emits it via `Events::Trailblazer::EmitEvent.call` → Pub/Sub `parental_orientation.agreement.v1` — a **domain event, not a customer.io event**. There is no `NotifyAgreementCompleted`/`track_event` for it anywhere.

Net effect: the "incomplete agreement" reminder fires every 2 days forever, even after the caregiver completed the COPM. `build_<event>` + `EmitEvent.call` (Pub/Sub) is NOT the same as `customer_io.track_event` — grep for the LATTER specifically. (Decode the stop events via `conditional_wait_action.multi_conditions`: base64 → url-decode → JSON.)

**The fix (PR #6713, Lavínia) is forward-only — no retroactive backfill.** It adds `CustomerIo::UseCases::ConsumeAgreementLifecycleChanged` (a Pub/Sub consumer on the 4 lifecycle events) that `track_event`s `name = lifecycle_event` to customer.io. But a Pub/Sub consumer only processes events emitted AFTER its deploy; `agreement_completed` emitted before the deploy is gone, and the PR ships no rake/backfill. So agreements completed before the deploy remain stuck in the reminder loop — assume a manual backfill is required for anything completed/created before the deploy date. Full journey decode, the fix, and the retroactivity caveat are in `references/agreement-reminder-lifecycle.md`.

## Recipe

1. Confirm the symptom precisely ("device não associa" vs "identify falha" vs "push não chega").
2. For each system writing to customer.io, find its identifier. Grep for `identify`, `add_device`, `userId`, `identifiers:`.
3. If identifiers differ → that's the bug. Fix by making them agree (prefer email, normalized).
4. If identifiers match, check deploy topology to see whether the code you're reading is even live in the env under test (`git branch --contains` + deploy workflow).
5. Check the customer.io workspace for ghost profiles / leftover divergent data from an earlier broken state — data damage outlives the code fix.
