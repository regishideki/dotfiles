---
name: genialcare-mobile-debugging
description: "Debug GenialCare mobile RN auth/LogBox errors."
---

# GenialCare Mobile (React Native) Debugging

Use this skill when debugging runtime errors in the `mobile` repo (React Native, iOS/Android) — especially auth failures, LogBox/redbox console errors, and cases where the logged error payload looks empty or unhelpful.

## Key files

- `src/services/logger.ts` — wraps `console.info/warn/error/debug` in dev (`Config.ENVIRONMENT === 'development'`), or Datadog's `DdLogs` in non-dev builds.
- `src/services/authentication.ts` — `signInAuthentication`/`fetchRefreshedAccessToken`, each wrapped in a promise chain with a `.catch(error => logger.error(...))` that rethrows.
- `src/integrations/auth0/auth.tsx` — `authorizeWithAuth0`/`refreshAuth0Token`, thin wrapper around `react-native-auth0`'s `Auth0` client (`Config.AUTH0_DOMAIN`, `Config.AUTH0_CLIENT_ID`, `Config.AUTH0_AUDIENCE` from `react-native-config`).

## Pitfall: `Error` objects serialize to `{}` in logs — the payload is not actually empty

When a caught `error` is logged as `{service, error}` and then JSON-serialized (LogBox's console viewer, Datadog, `JSON.stringify`), a plain JS `Error` (or most SDK error classes, including `react-native-auth0`'s `AuthError`/`WebAuthError`) shows as `{}` — `message`, `name`, `stack` are non-enumerable or live on the prototype chain, so they get dropped. Seeing `"error":{}` in a LogBox screenshot does NOT mean the error is actually empty; it means only the serialization is lossy. Do not conclude "no error info was captured" from this — the real message/code exists on the object at throw time.

**Fix (temporary instrumentation, revert before opening a PR):** in the relevant `.catch(error => ...)`, spread out likely fields explicitly so they survive serialization:
```ts
logger.error('Auth signInAuthentication failed', {
  service: 'AuthenticationService',
  error,
  errorName: error?.name,
  errorMessage: error?.message,
  errorCode: error?.code,      // react-native-auth0 WebAuthError has .code (e.g. 'a0.session.user_cancelled')
  errorJson: error?.json,      // react-native-auth0 sometimes carries the raw Auth0 JSON error body here
  errorStack: error?.stack,
});
```
Apply this at both the call site closest to the SDK (`auth.tsx`'s `authorizeWithAuth0`/`refreshAuth0Token`) and the outer wrapper (`authentication.ts`) — the inner one usually has the more specific SDK error shape.

## Pitfall: Android's `developmentDebug`/`stagingDebug`/`productionDebug` naming has no iOS equivalent — don't hunt for it there

`android:dev`/`android:staging`/`android:prod` run Gradle variants named `<flavor>Debug` (flavorDimensions "default" × productFlavors `production`/`staging`/`development`, in `android/app/build.gradle`). iOS has no matching concept: `ios:dev`/`ios:staging`/`ios:prod` just select a different Xcode **scheme** (`mobileDevelopment`/`mobileStaging`/`mobileProduction`) that all build the *same* target with the *same* `Debug` build configuration — the only per-scheme difference is a `PreAction` shell script that copies the matching `.env.<env>` to `.env` before building (see `ios/mobile.xcodeproj/xcshareddata/xcschemes/mobileDevelopment.xcscheme`). If something behaves differently between `android:dev` and `ios:dev` (e.g. Metro logs not showing), it is NOT because iOS is "missing" a debug variant equivalent to `developmentDebug` — both platforms build in debug/dev mode the same way; look elsewhere (Metro not running, `--no-packager`, device vs simulator networking) for the actual cause.

## Pitfall: `--no-packager` means no Metro, so `console.error` prints nowhere visible

The `ios:dev`/`android:dev` yarn scripts run with `--no-packager` (`npx react-native run-ios --scheme 'mobileDevelopment' --no-packager`). Without Metro attached, `console.error`/`console.info` calls in dev mode still fire (the JS still executes), but there is no Metro terminal to display them — they don't appear "nowhere" due to a bug, they appear only in the native OS console (Xcode > Window > Devices and Simulators, or `xcrun simctl spawn booted log stream`) or in the in-app LogBox screen itself. If the user says "no Metro output for this error", don't assume logging broke — check whether Metro was even attached, and prefer the LogBox screen (or an explicit field spread, per pitfall above) over hunting for Metro.

### Reading full console.error output from the simulator without Metro (exact recipe)

When there's no Metro terminal, pull the JS console output straight from the simulator's unified log instead of relying on the (truncated) LogBox screenshot. `log show --style compact` truncates each multi-line RN log entry to its first line — use `--style json` and parse `eventMessage` in Python to get the full multi-line payload (including nested error objects):

```bash
xcrun simctl list devices | grep Booted   # get the booted device UDID
xcrun simctl spawn <UDID> log show --last 15m \
  --predicate 'process == "mobile" AND eventMessage CONTAINS "signInAuthentication failed"' \
  --style json > /tmp/log.json
python3 -c "
import json
data = json.load(open('/tmp/log.json'))
for e in data:
    print(e.get('timestamp'))
    print(e.get('eventMessage'))
    print('---')
"
```
`console.error`/`console.info` calls from the JS layer show up tagged `[com.facebook.react.log:javascript]`. This is how the real underlying error message (e.g. `Error: Email not verified`, or a native AsyncStorage error) gets recovered even when the LogBox screen only showed `{}` or a truncated line. Filter `--predicate` by a distinctive substring of the log message to avoid wading through UIKit/network noise.

## Pitfall: `email_verified` is per-Auth0-tenant — "I verified my email" doesn't mean every environment agrees

`dev`, `staging`, and `production` are three **separate Auth0 tenants** with independent user databases (check `AUTH0_DOMAIN` in `.env.development` / `.env.staging` / `.env.production` — they're different hostnames, e.g. `dev-xxxx.us.auth0.com` vs `staging-genialcare.us.auth0.com` vs `auth.genialcare.com.br`). A user verifying their email in one tenant does not verify it in another. If `signInAuthentication` throws `Error: Email not verified` (thrown explicitly in `authentication.ts` when the decoded ID token's `email_verified` claim is falsy), don't just trust "the account is verified" — confirm in the Auth0 Dashboard for the **specific tenant matching the running scheme's `.env.*`** (Auth0 authorize success in the log, followed immediately by signInAuthentication failed with this message, means the JWT decoded is what's being rejected — log the decoded claims (`sub`, `email`, `email_verified`, `org_id`) temporarily if unsure which account/tenant is actually being hit).

## Pitfall: AsyncStorage `manifest.json` write failure looks like an auth bug but is a corrupted simulator container

A separate failure mode that surfaces through the *same* `signInAuthentication failed` log line: `Error: Failed to write manifest file. ... "A pasta "manifest.json" não existe." ... NSUnderlyingError=... "No such file or directory"`, pointing at `.../Application Support/<bundle-id>/RCTAsyncLocalStorage_V1/manifest.json`. This means `@react-native-async-storage/async-storage` can't create its own storage directory inside the app's simulator container — almost always because the app's data container got corrupted or left in an inconsistent state across repeated installs/builds (mixing debug/release builds, killing a build mid-install, etc.). This is unrelated to Auth0/email-verification even though it surfaces through the same catch block and log message prefix — read the actual error text, don't assume it's the same root cause as a previous run just because the outer log line matches.

**Fix**: uninstall the app from the simulator (don't erase the whole simulator unless this doesn't work) and reinstall via a fresh build:
```bash
xcrun simctl list devices | grep Booted        # get UDID
xcrun simctl uninstall <UDID> br.com.genialcare.app
# then rebuild: yarn ios:dev (or the relevant scheme script)
```
This clears the app's Application Support container without touching the rest of the simulator (other apps, other data). Only fall back to a full "Erase All Content and Settings" if uninstall/reinstall doesn't clear it.

## Pitfall: don't assume the app itself is broken when auth fails only for one developer locally

If a teammate/prod build authenticates fine but the current dev's local build fails at Auth0 sign-in, treat it as an environment/config issue first, not an app code bug:
1. Confirm `AUTH0_DOMAIN`, `AUTH0_CLIENT_ID`, `AUTH0_AUDIENCE` are actually set (non-empty) in the `.env*` file matching the running scheme — do NOT `read_file`/cat these files (they're credential-bearing), just `grep -E '^(AUTH0_DOMAIN|AUTH0_CLIENT_ID|AUTH0_AUDIENCE)=' .env.<env>` and confirm presence, never print the value.
2. Confirm the running scheme's bundle id / `CFBundleURLSchemes` matches what's registered as an Allowed Callback URL in the Auth0 tenant (`ios/*.xcodeproj/xcshareddata/xcschemes/<Scheme>.xcscheme` → `BlueprintName`/bundle id; `ios/<Target>/Info.plist` → `CFBundleURLSchemes`).
3. Only after ruling out (1) and (2) should you suspect app logic — check for recent changes in `authentication.ts`/`auth.tsx`.
This mirrors the general local-dev instinct in `genialcare-local-dev`: prefer diagnosing the environment before touching app code, especially when other users are unaffected.

## Verification after any change here

`yarn lint`/`yarn test` in this repo require the project's own Node (`.nvmrc`), not the system default — the plain `yarn run lint`/`yarn run test` may fail with `The engine "node" is incompatible`. Use:
```bash
source ~/.nvm/nvm.sh && nvm use && npx eslint <changed files>
source ~/.nvm/nvm.sh && nvm use && yarn run test
```
(`yarn run test` itself works fine once the right Node is active; it's `yarn run lint`'s engine check via the system-default `yarn` binary that trips over the wrong Node — running `npx eslint` directly after `nvm use` sidesteps it.)

## Pitfall: Customer.io push notifications not delivering, but in-app/track/identify all work

If a user reports "Customer.io sees my clicks and shows in-app modals, but push notifications never arrive", suspect a missing **device token registration** before touching push permissions, FCM config, or native delegate code. In-app messaging and event tracking work off the *profile identify* alone (`CustomerIO.identify({userId, traits})` in `src/integrations/customerio/identify.ts`, called from `IdentificationContext.tsx`) — that's a websocket/API-level link and has nothing to do with push. Push additionally requires a **separate step**: `CustomerIO.registerDeviceToken(token)` (from `customerio-reactnative`, see `node_modules/customerio-reactnative/src/customerio-cdp.ts`) binding the FCM/APN device token to the identified profile.

Trace the token flow to check this:
1. `src/integrations/firebase/mobile/messaging/token.ts` — `getToken()`/`onTokenRefresh()` wrap `@react-native-firebase/messaging`, this is where the FCM token itself is fetched natively.
2. `src/screens/Home/components/DeviceInfoCollector.tsx` — subscribes to the token and calls `createOrUpdateDevice(token)`, which only sends the token to GenialCare's **own backend** via the `createOrUpdateUserDevice` GraphQL mutation.
3. Grep for `CustomerIO.registerDeviceToken` under `src/` — if there are zero hits, that's the bug: the token never reaches Customer.io, so CIO has an identified profile with no device token attached and nothing to push to.
4. Native-side files (`ios/MyAppPushNotificationsHandler.swift`, Android `NativeMessagingPushModuleImpl.kt`) only wire up the FCM *delegate for receiving/handling* pushes (`MessagingPush.shared.messaging(...):didReceiveRegistrationToken:` on iOS) — this is NOT the same as registering the token with the CIO profile from the JS layer; don't assume the native plumbing already covers it.

**Fix**: call `CustomerIO.registerDeviceToken(token)` alongside `createOrUpdateDevice(token)` in `DeviceInfoCollector.tsx`'s token handler. Symmetrically, `IdentificationContext.tsx`'s `signOut` should call `CustomerIO.deleteDeviceToken()` and `CustomerIO.clearIdentify()` before restarting — today it only does `signOutFirebase()`/`deleteUserProfile()`/`signOutAuthentication()`, so switching users on the same device would leave the previous profile/token still bound in Customer.io.

## Related skills

- `genialcare-local-dev` — env var precedence, Docker networking, and the general "diagnose environment before app code" instinct for the core/bff/panel stack (same instinct applies here for mobile).
- `systematic-debugging` — general root-cause-first process; this skill supplies the RN/Auth0-specific tactics for Phase 1 (building the feedback loop, reading the real error).
