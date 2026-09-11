# Customer.io identifier & device registration flow (core ↔ mobile)

Investigation of the push-notification device-registration path and the
Customer.io user identifier strategy. Covers `CustomerIo::Client` in core,
the mobile SDK integration, and the divergence that broke device association.

## The device registration flow (mobile → bff → core)

1. **mobile** `src/screens/Home/components/DeviceInfoCollector.tsx` — on every
   Home mount AND on `onTokenRefresh`, fetches the FCM token
   (`getToken()` from `@react-native-firebase/messaging`) and calls the
   GraphQL mutation `createOrUpdateUserDevice(device: {deviceId, devicePlatform,
   deviceToken, accessToken})`. Token is per-installation and stable in normal
   operation — it does NOT change on logout/login on the same device, nor when
   a *different* user logs in. It only changes on reinstall, clear-data,
   device restore, or rare Firebase rotation. The Home-mount effect means
   there is a natural retry on every app entry, so transient bff/core failures
   self-heal.
2. **mobile-bff** `src/data-sources/core/users-api.ts` →
   `createOrUpdateUserDevice` PUTs `/users/devices/{id}.json` with
   `{device_token, device_platform}`.
3. **core** `packs/clinical/app/controllers/users/devices_controller.rb` →
   `UserDevices::UseCases::CreateOrUpdate` →
   `packs/clinical/app/concepts/user_devices/use_cases/create_or_update.rb`.
   The use case: saves `UserDevice` (find_or_initialize by `device_id` +
   `user_id`), emits `UserDeviceChanged` (topic `global.user.v1`), then — only
   when `device_platform != "browser"` — runs `identify_user` +
   `add_device` against Customer.io. Browser/web push (clinical-panel) only
   persists the `UserDevice` row and does NOT touch Customer.io here.

`UserDevice` model: `user_id`, `device_id`, `device_token`, `device_platform`
(enum `ios`/`android`/`browser`, `Enum::UserDevices`). Uniqueness on
`[tenant_id, user_id, device_id]`.

## Identifier strategy (`CustomerIo::Client`)

`app/infra/customer_io/client.rb`. `identify`, `add_device`, `track_event`
all go through the **Track v2 API** (`POST /api/v2/entity`, same client as
`upsert_object`) with an explicit identifier map:

```ruby
def customer_io_identifiers(user)
  return {id: user.id} if user.email.blank?
  {email: user.email}
end
```

So the Customer.io profile is keyed by **email**, with `{id: user.id}` as a
fallback only when the user has no email. This replaced the old code that
passed `id: user.id` (UUID) everywhere.

Mobile `src/integrations/customerio/identify.ts` identifies with
`CustomerIO.identify({ userId: trimmedEmail, ... })` — also email-keyed, and
**unconditional** (no env check). The mobile SDK auto-detects an email passed
as `userId` (that auto-detect is JS-SDK behavior).

## The "ghost profile" gotcha (Track v1 vs v2) — the key non-obvious fact

Passing `user.email` in the `id` field of the **Track v1 API** (the
`customerio` gem, `Customerio::Client`) does **NOT** make Customer.io treat it
as an email identifier. That auto-detection is a **JS-SDK** behavior only.
On Track v1, if the value had never been seen as an `id`, Customer.io creates
a brand-new "ghost" profile with `identifiers.id = <the email text>` and
`identifiers.email = null` — because the real email already belongs to the
existing profile, and the implicit email-attribute write fails silently.

Symptom of ghost profiles: the user is identified (real profile exists) but
device/events land on the empty ghost profile → "device não associa".

The fix (commit `07040f6c84` "Migra identify/track_event/add_device para Track
v2 API") moves identify/add_device/track_event to Track v2 with explicit
`identifiers: {email: user.email}`. This was confirmed against a real ghost
profile in development (`lavinia.beghini+1@genialcare.com.br`).

## Commit sequence that produced the current state (all merged to `development`)

Author Lavínia Beghini, Aug 28–29 2026:

1. `cca1f7520c` — "email como id em development/staging" (env-conditional:
   `customer_io_identifier` returned email only when `Rails.env.development? ||
   Rails.env.staging?`, else `user.id`). This is the BROKEN approach.
2. `cbd5f2afdb` — removed the env conditional (email in all envs). Still broken.
3. `07040f6c84` — the actual fix: Track v2 + explicit `identifiers: {email}`.

Because commits 1–2 were live (merged) before 3 landed, the Customer.io Test
workspace may still contain **ghost profiles** (id = email text, email = null)
created during that window. The code is now consistent (both sides email-keyed),
but stale ghost data can still cause "device não associa" until cleaned up in
the Customer.io dashboard — don't reach for a code fix when the divergence is
leftover data.

## Cross-service identifier divergence (the "two paths" pattern)

This is the classic failure mode behind the whole discussion: the same
logical identity (`identify` the user + register their device) was split
across two systems with **different keys**:

- mobile SDK identify → keyed by **email**
- core `CustomerIo::Client#identify`/`add_device` → historically keyed by
  **user.id (UUID)**

Two different `customer_id`s → two profiles → device attached to the wrong
one. Retry/refresh does not fix a *deterministic* key mismatch (unlike a
transient failure). When chasing "identifies but doesn't associate", the first
question is: are both sides using the SAME identifier for the same profile?

## iOS vs Android device registration asymmetry (critical nuance)

SDK-side device registration is NOT symmetric across platforms:

- **iOS**: `ios/MyAppPushNotificationsHandler.swift` wires
  `MessagingPush.shared.messaging(_:didReceiveRegistrationToken:)` (from
  `CioMessagingPushFCM`), which registers the device token with Customer.io via
  the SDK — in parallel to core's `add_device`. So on iOS there are genuinely
  TWO device writers (SDK MessagingPush + core Track v2 `add_device`).
- **Android**: NO SDK-side device registration. `MainApplication.kt` /
  `MainActivity.kt` are stock RN; the manifest has no MessagingPush /
  FirebaseMessagingService entry; no `registerDeviceToken` anywhere in JS. On
  Android the token flows only `getToken()` → GraphQL → core `add_device`.

Consequences: "move device registration to the app" is *already true* on iOS and
would require NEW work on Android. And the "two parallel writers" concern only
actually exists on iOS — on Android core is the sole writer.

## identify (SDK) vs identify+add_device (core) are DIFFERENT responsibilities

What looks like "duplication" is two features writing to the same store:

- **App SDK identify** (`CustomerIO.identify({userId: email})`) → client-side
  context for **in-app messaging** (and iOS MessagingPush association). In-app
  is inherently client-side — core cannot display in-app messages.
- **Core identify + add_device** (Track v2) → **push delivery** (person + device)
  plus `track_event` for server-driven events (session scheduled, agreement
  created, …). Server-side, with durable retry/traceability.

They key by the same identifier (email), so they converge. The only contract
that matters is the SAME key. Core cannot drop its Customer.io integration
entirely (it owns server-driven `track_event`s), so there is no "single
app-side integration" to centralize onto — the right framing is "separate
responsibilities, one identifier key", not "app vs core".

At investigation time, in-app messaging was configured-but-unused in the app:
`inApp: {siteId}` present in `config.ts` and `MessagingInApp` in the pod, but
zero `CustomerIOInApp` / `track` / `screen` usage in `src/`. So the SDK identify
is vestigial for push delivery and only becomes load-bearing if in-app ships.
