# Core 403 (authorization) vs 401 (authentication)

When a report says "muitos erros 403 pipocando" across clinical-panel / clinical-panel-bff /
core, the word "403" usually hides two unrelated failure classes. Separate them before
concluding anything.

## The two classes

| | 403 | 401 |
|---|---|---|
| Layer | Pundit authorization | JWT authentication |
| Source | `ClinicalCasePolicy#default_validation` (`core/packs/clinical/app/policies/clinical_case_policy.rb`) | `ValidateAccessToken` → `TokenRejectedError` (`core/app/controllers/concerns/validate_access_token.rb`) |
| Log signature | `Error when trying to access clinical case X by user Y` (from `raise_error`, line 84) | `[Auth] JWT decode failed — fallback /userinfo triggered` |
| Meaning | user is authenticated but lacks a `clinician`/`caregiver` link to that case | the `Authorization` value failed JWT decode AND `/userinfo` also rejected it |
| Correctness | usually correct isolation (multi-tenant mismatch, not a bug) | depends on WHY decode failed |

## Distinguishing the 401 sub-causes (the key trick)

The `JWT decode failed` WARN fires on two very different errors. Query each separately:

- `service:core "ExpiredSignature"` → token genuinely expired. In the 2026-09 investigation this
  was **0** occurrences in 7d.
- `service:core "MalformedTokenError"` / `"Not enough or too many segments"` → the token value has
  the wrong number of dot-separated segments. A valid JWT has 3. This means the `Authorization`
  header isn't a JWT at all — empty, `"Bearer"` with nothing after it, or a placeholder/garbage
  string. In 2026-09 this was **~22,640 in 7d** (~3,700/day), hitting `POST /users.json`.

So the classic "token expired, no refresh mechanism" hypothesis is often WRONG: it's a caller
sending a structurally invalid token, not an expiry problem. The fix is on the caller (give it a
real access token or client-credentials grant), not a refresh mechanism.

## Where each error surfaces

- 403 → mostly `ClinicalGuidance::ClinicalGuidancesController#show`, then
  `ClinicalCasesCaregiversController`, `ClinicalCaseComplexityScoresController`. ~14 distinct
  (user, case) pairs in a day — not one incident.
- 401 → `POST /users.json` (`UsersController#create`), a **root `rack.request` span**
  (`parent_id: "0"`, `http.base_url: core.genialcare.io`), no `browser.request`/`graphql` spans →
  called directly, not through a BFF.

## Attribution recipe (who is calling)

The `[Auth] JWT decode failed` WARN log line carries ONLY `custom.request_id` — no URL, no IP, no
user-agent. To find the caller, read the ACCESS-LOG (lograge) line that carries `@http.status_code`:

```
search_datadog_logs(query='service:core @http.method:POST @http.status_code:401',
                    extra_fields=["*", "ip", "remote_ip", "params"], ...)
```

`extra_fields` uses BARE names (no `@` / no `custom.` prefix). Useful fields on the access line:

- `custom.ip` / `custom.remote_ip` — the caller's public IP. `grep -oE 'custom.remote_ip: [0-9.]+' | sort | uniq -c`.
- `custom.params` — e.g. `{"user":{"email":"[FILTERED]","tenant_external_id":null}}`. `tenant_external_id: null` is a strong signal: the caller has no Auth0 org context.
- `custom.controller` / `custom.action` / `custom.format`.

2026-09 worked example: a single IP `3.134.176.17` (AWS EC2 us-east-2, AS16509) drove ~100% of the
401s, POSTing `{"user":{"email":"...","tenant_external_id":null}}` (and sometimes
`org_jTwTzOJkZPMDw7kw` = genialcare) directly against `core.genialcare.io`. That's an internal
job/script of user provisioning with a broken token — not a browser, not a BFF bug.

## The RUM side (what the user actually sees)

Frontend RUM `@type:error` on `clinical-panel` showed the 403 surfacing as `ApolloError: 403:
Forbidden` on views like `/panel/clinical-cases/?/overview` and `/panel/home`. The BFF maps core's
403 to a GraphQL `FORBIDDEN` error (`clinical-panel-bff/src/datasources/base-datasource.js` →
`access denied`), so the user sees a generic failure, not a "wrong tenant" message. The backend
isolation is correct; the gap is UX (distinguish NOT_FOUND from "no permission").
