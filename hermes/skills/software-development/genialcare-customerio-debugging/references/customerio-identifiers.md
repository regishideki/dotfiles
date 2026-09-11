# customer.io identifier migration — commit trail and mechanism

Real case (Aug 2026): GenialCare switched the customer.io profile identifier from `user.id` (UUID) to `email`. The rollout was done in stages and left environments inconsistent.

## Commit trail (core)

All authored by Lavínia Beghini, all merged only to `development` (NOT `main`):

1. `cca1f7520c` "Usa email como identificador em development e staging" — env-conditional `customer_io_identifier(user)`: email in dev/staging, `user.id` in prod.
2. `cbd5f2afdb` "Usa email em todos os ambientes" — removed the env conditional; email everywhere.
3. `07040f6c84` "Migra identify/track_event/add_device para Track v2 API" — the actual fix.

Mobile: `fa22775b` "fix: identify Customer.io users by email" changed `identify.ts` from `userId: user.id` to `userId: trimmedEmail`. This one IS on mobile `main`.

## The broken mechanism (commits 1 and 2)

Passing `user.email` in the `id` field of the Track v1 API (`customerio-ruby` gem) does NOT make customer.io detect it as an email. That auto-detect behavior is SDK-JS only, not the Track v1 HTTP API.

Result: customer.io creates a NEW profile with `identifiers.id = <email text>` and `identifiers.email = null` (the email attribute set fails silently because the email already belongs to the real profile). The device attaches to this ghost profile.

Confirmed empirically in development: `lavinia.beghini+1@genialcare.com.br` had a `cio_id` with `identifiers.id = email` and `identifiers.email = null`.

## The fix (commit 3)

Migrate to Track v2 (`/api/v2/entity`, the same endpoint already used for `upsert_object` / `add_object_relationship`) with explicit identifiers:

```ruby
def customer_io_identifiers(user)
  return {id: user.id} if user.email.blank?
  {email: user.email}
end
```

`identify`, `add_device`, and `track_event` all route through `track_v2_entity` with `identifiers: customer_io_identifiers(user)`. The `customerio` gem v1 (`Customerio::Client`) was removed entirely.

## Why staging still broke after the fix

The core id→email change (all 3 commits) never reached `main`. Staging deploys from `main`. So:

- core `main` (→ staging) = still `id: user.id` (UUID).
- mobile `main` = `userId: email`.

Staging = mobile identifies by email + core identifies/add_device by UUID = two different profiles = "device não associa". This is a **half-rolled-out migration**, not a ghost-profile bug and not an architecture problem.

## Symptom → cause map

| Symptom | Likely cause |
|---|---|
| "app identifica mas device não associa" | identifier divergence (email vs UUID) between SDK and core |
| ghost profile `id=<email>, email=null` in workspace | Track v1 API with email in `id` field |
| env-specific failure (dev works, staging fails) | change merged to one branch but not `main` |
| data damage persists after code fix | ghost profiles still in customer.io workspace |

## Notes

- The app's SDK `identify` serves in-app/analytics, NOT push delivery. Core's `identify` + `add_device` is what makes push work. They are different responsibilities that happen to write to the same place.
- Backend (core) is the better single writer for device registration than the app: durable retry, Datadog tracing, survives app uninstall. "Move device registration to the app" trades retry robustness for conceptual cleanliness — not recommended unless the SDK is deliberately becoming the canonical mobile integration.
- Core `add_device` has `return true if filtered` (tenant gating via `access_validator.enabled?`). A filtered test tenant silently skips device registration with no identifier bug — an alternative cause of "device não associa" worth ruling out.
