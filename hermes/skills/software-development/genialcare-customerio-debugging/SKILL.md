---
name: genialcare-customerio-debugging
description: Debug GenialCare customer.io identify/device/push flows.
---

# GenialCare customer.io debugging

Use when investigating customer.io identify, device registration, or push delivery across the GenialCare systems (mobile RN app, mobile-bff, core Rails). Trigger phrases: "device não associa", "push não funciona", "identify", "device token", "customer.io", or any dispute about where device/identify responsibility should live.

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

## Recipe

1. Confirm the symptom precisely ("device não associa" vs "identify falha" vs "push não chega").
2. For each system writing to customer.io, find its identifier. Grep for `identify`, `add_device`, `userId`, `identifiers:`.
3. If identifiers differ → that's the bug. Fix by making them agree (prefer email, normalized).
4. If identifiers match, check deploy topology to see whether the code you're reading is even live in the env under test (`git branch --contains` + deploy workflow).
5. Check the customer.io workspace for ghost profiles / leftover divergent data from an earlier broken state — data damage outlives the code fix.
