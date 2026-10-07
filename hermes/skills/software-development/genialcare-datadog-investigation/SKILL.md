---
name: genialcare-datadog-investigation
description: "Use for GenialCare prod incidents: RUM+APM+BQ triangulation."
metadata:
  hermes:
    tags: [datadog, rum, apm, incident-investigation, bigquery, genialcare, root-cause]
    related_skills: [investigate-core-flow, investigate-bff-flow, genialcare-bigquery-queries, mcp-troubleshooting]
---

# GenialCare Datadog Investigation

Methodology for root-causing a production bug report ("terapeuta relatou erro X", "tela
branca ao clicar Y") by triangulating three independent sources: Datadog RUM (frontend
errors), Datadog APM traces + Logs (backend execution), and BigQuery CDC/tables (actual data
state). No single source is trustworthy alone — see the Pitfalls section.

## When to load this skill

- User reports a specific person hit an error/crash/blank-screen in a GenialCare product
  (clinical-panel, operational-panel, mobile) and asks to investigate root cause.
- User asks "verifica no Datadog", "acha o erro no RUM/APM", or references a session replay.
- Investigating whether a bug is a one-off or systemic (blast-radius sizing).
- Before proposing a fix for a "worked before, broke silently" backend flow — the trace vs.
  actual-state cross-check here is often what reveals a swallowed rollback or silent failure.

## MCP setup (do this first if Datadog tools are missing)

If `mcp__datadog__*` tools aren't in your live tool list even though `hermes mcp list` shows
`datadog: ✓ enabled`, see the `mcp-troubleshooting` skill — most likely cause is the session's
tool catalog predates the MCP login/reload; the fix is the user typing `/reload-mcp`, not
re-authenticating.

## Investigation flow (outside-in: user report → data → frontend error → backend trace)

1. **Anchor on a real identifier from BigQuery, not just the user's description.** Resolve
   the reported case/session/entity number to a real UUID via `datakernel`/`supervision`
   tables (see `genialcare-bigquery-queries`). Get the therapist's `user_id` too
   (`datakernel.users` by email) — RUM/APM queries need IDs, not names. For a
   family/caregiver report ("a família X não consegue..."), resolve caregivers with
   `data-kernel-production-4o7n.datakernel.clinical_cases_caregivers` JOIN
   `datakernel.caregivers` — the `caregivers` row already has `user_id`/`user_full_name`/
   `user_email` columns, so no join to `users` is needed to get the RUM search key
   (`@usr.email`). `clinical_cases.number` is NOT unique across tenants (filter
   `tenant_id = '6f8da042-2dd1-4872-a613-84d371bde78c'`).

2. **Reconstruct the timeline from BigQuery CDC first** (`raw.<table>_events`, see
   `investigate-core-flow` pitfall #11) — this gives you exact timestamps of every state
   change with zero Datadog quota cost, and tells you WHEN to scope the RUM/APM search
   (narrow windows return faster and cleaner results).

3. **Search Datadog RUM for the frontend error**, scoped to the user + narrow time window:
   ```
   mcp__datadog__search_datadog_rum_events(
     query='@type:error @usr.email:<email>',
     from='<incident-day>T00:00:00Z', to='<incident-day+1>T00:00:00Z',
     detailed_output=true
   )
   ```
   The `error.message`/`error.stack` field is the actual crash, not what the user described —
   trust the stack trace over the user's paraphrase of what "looked wrong". A user reporting
   "tela branca" can map to a completely different underlying error than your first hypothesis
   from reading the frontend source alone (e.g. the real crash was `useAuthenticatedUser must
   be used within an AuthenticatedUserContext` — a *secondary* crash inside the app's own
   ErrorBoundary fallback, not the originally-hypothesized `undefined.id` in the page
   component). Also pull `@type:view` events for the same `view.id`/session to see
   `error_count`, navigation `referrer`, and how many times the user retried.

4. **Pull the exact backend request via `service:core`/`service:<bff>` logs**, searching by
   the entity ID as a free-text query (works even without knowing the field name):
   ```
   mcp__datadog__search_datadog_logs(query='service:core "<entity-id>"', from=..., to=...)
   ```
   Extract the `trace_id` from a matching log line's `dd.trace_id=...` tag or the `trace_id`
   column in the TSV response.

5. **Pull the full APM trace** with that `trace_id` via `get_datadog_trace` (strip dashes,
   lowercase hex). Read the span list for the Trailblazer use-case span name (matches the
   Ruby class, e.g. `General_Sessions_UseCases_Subprocess_UpdateInterventionSessionToAssessment`)
   and every DB query nested under it. **Do not conclude a write persisted just because its
   `INSERT`/`UPDATE` span appears in the trace** — see the `investigate-core-flow` pitfall on
   `Wrap(TrailblazerTransactionWrap)` silently rolling back a fully-executed-looking
   transaction with zero error signal. Always close the loop by re-querying BigQuery/the DB
   for the expected end state before declaring the write succeeded.

6. **Once root cause is understood, size the blast radius immediately** (see
   `investigate-core-flow` pitfall #12: JOIN + COUNTIF across BQ tables). Report the number
   before finishing — "1 user hit this" vs. "3% of records in the last 2 months" changes the
   priority conversation entirely.

## Pitfalls

- **When a root-cause hypothesis needs local reproduction (Rails console / concurrent-request
  test) but Docker itself is unavailable or hanging, don't burn the session waiting on it — report
  the hypothesis at its true confidence level and name the exact repro step for next time.** If
  `docker pull`/`docker compose build` hangs indefinitely on image metadata fetch (no error, no
  progress, while `docker version`/`docker info` still respond fine) after a genuine wait, that's
  a local Docker Desktop/daemon issue, not a code problem — don't keep polling it for many
  minutes. Finish the investigation via static analysis (code + `schema.rb` + CDC timestamps) and
  write up the hypothesis explicitly as "high confidence pending reproduction" rather than
  silently upgrading it to "confirmed" or giving up on the write-up. Tell the user exactly what
  command would confirm it (e.g. "drive 2 concurrent requests against use case X in a Rails
  console") so a future session with working Docker can close the loop in one step instead of
  re-deriving the hypothesis from scratch.

- **For a FRONTEND render-time crash (context hook called outside its provider, non-null assertion on `undefined`, etc.), you can prove before/after a fix in a real headless browser WITHOUT the auth wall — build a throwaway minimal Vite harness instead of driving the authenticated app.** The full-app path needs Auth0 login + live BFF + real entity IDs; the harness path renders the REAL component with a minimal provider stack and toggles the fix via git. This is the fast empirical confirmation the "local reproduction" pitfall above leaves open for frontend bugs (no Docker, no backend needed). Concrete recipe — clinical-panel provider stack, the exported-vs-private-context stub trick, exact `vite.config.ts` for the `baseUrl: "./src"` alias resolution, and the browser-tool verify loop — lives in `references/frontend-crash-browser-repro.md`. Core moves: (1) `vite-tsconfig-paths({ root: repoRoot })` so bare `contexts/`/`pages/`/`components/` imports resolve from a `repro/` subdir; (2) skip heavy providers by providing the EXPORTED context directly (`<ToastContext.Provider value={{ trigger: stub }}>` beats rendering `ToastProvider` → `<Toast />`); if the context is module-private (e.g. `ModalContext`), use the real lightweight provider; (3) wrap in a tiny ErrorBoundary that renders a `data-testid="crash"` div — production already wraps the app in one, so this faithfully reproduces the *handled* error Datadog reports as `is_crash: false`; (4) confirm via `browser_snapshot` + `browser_console`, then delete `repro/` before committing. Always prefix dev-server commands with `export PATH="$HOME/.nvm/versions/node/v20.19.2/bin:$PATH"` (the background shell defaults to Node 16; Vite 7 needs ≥20).

- **Don't trust your own first hypothesis over the actual RUM stack trace.** Reading frontend
  source and finding a plausible-looking bug (e.g. a non-null assertion `foo!.id` that could
  throw if `foo` is undefined) is a hypothesis, not a finding. The RUM error may show a
  completely different, secondary crash (e.g. a context-provider error thrown while the app's
  own ErrorBoundary tried to render its fallback UI, because the fallback itself depends on a
  context that unmounted along with the crashed subtree). Always fetch the actual RUM error
  event before writing up a root cause — do not present a source-reading hypothesis as if it
  were confirmed.

- **`bq query` against BigQuery *external tables* backed by GCS/Datastream (the `raw.*_events`
  CDC tables, or any `EXTERNAL` table type) can genuinely take 60-90+ seconds** — this
  regularly exceeds the foreground `terminal` tool's 60s soft return and looks like a hang.
  Symptom: `[Command timed out after 60s]` with the query still `RUNNING` per `bq ls -j -a`.
  Fix: write the query to a small shell script file and run it via
  `terminal(background=True, notify_on_complete=True)`, then `process(action='wait',
  timeout=60)` (may need 2 calls — first often returns `status: timeout` even though the
  job finishes shortly after; call `wait` again). Read the output file with `read_file`
  afterward rather than relying on the terminal tool's captured stdout — background terminal
  output can be swallowed on this environment's zsh init noise (`stty: stdin isn't a
  terminal`, `Usage: prompt <options>...` — this is shell theme noise on non-interactive
  invocation, not a real error; ignore it and check the redirected output file instead).
  Keep the SELECT column list narrow (see `investigate-core-flow` pitfall #11) — this alone
  often avoids the timeout without needing to background the call at all.

- **`get_datadog_error_tracking_issue` requires `issue_id`, not a query string** — pass the
  literal issue UUID from a prior RUM/error-tracking search result's `issue.id` field, not a
  Datadog query-syntax string. `get_datadog_trace` requires `trace_id` as 32 lowercase hex
  chars (no dashes) — take it directly from a log line's `dd.trace_id=` tag.

- **A single `search_datadog_rum_events` call for `@type:error` on a busy view can return the
  same underlying issue many times** (session replays across multiple page-load attempts).
  Group by `error.fingerprint`/`issue.id` mentally before concluding there are multiple
  distinct bugs — a user retrying the same broken page 5 times produces 5 near-identical
  error events, not 5 different problems.

- **To confirm a specific backend use case / destructive action actually RAN in production (not just "the code exists"), search APM spans by `resource_name`.** The Trailblazer monitoring wrap names each span after the use case class (e.g. `Assessments::UseCases::DeleteOccupationalTherapyAssessmentsRegistry`, with `::` → `_` in `operationname`). `mcp__datadog__search_datadog_spans(query='service:core resource_name:*Delete*AssessmentsRegistry*', from='now-30d', to='now')` returns every invocation with `status: ok`, `custom.params` (e.g. the deleted `registry_id`), and `custom.current_user` — proof the action happened, its frequency, and its actors. This is the fastest way to tell "the record is missing because a write was rolled back" apart from "the record was written then DELETED": the delete's own span appears in APM even when the entity has NO CDC table in `raw.*`. Pair `custom.params.<entity-id>` with the incident's record id to correlate a specific delete to a specific incident. (Worked example: the direct-assessment "NULL registry" bug — a span search on the `Delete*AssessmentsRegistry` use cases proved the registry was created-then-deleted by a real user action, ruling out rollback/race.)

- **To identify WHO performed a state-changing action (who deleted/updated a record), read the `browser.request` span's `usr.email`/`usr.id` — NOT the use-case span's `current_user`.** The Trailblazer monitoring wrap serializes `current_user` into the use-case span via `inspect`, producing `custom.current_user: '#<User:0x00007eae...>'` — a Ruby object memory address, useless for attribution. The real identity is captured by Datadog's Rack/Rails instrumentation on the HTTP entry spans: the `browser.request` span (service `clinical-panel`, `type: browser`) carries `usr.email` and `usr.id` of the logged-in user whose frontend session issued the request. Procedure: (1) find the use-case span by `resource_name`, note its `trace_id`; (2) `search_datadog_spans(query='trace_id:<id>')` to pull the full trace; (3) read the `browser.request` span's `usr.email`. Worked example: the direct-assessment registry delete — the `DeleteOccupationalTherapyAssessmentsRegistry` span showed only `current_user: '#<User:0x...>'`, but the `browser.request` span in the same trace showed `usr.email: ariela.vecchio@genialcare.com.br`, identifying who deleted it. Corollary: the emitted domain event (e.g. `...RegistryDeleted`) DOES carry `deleted_by_id`, but it goes to Pub/Sub and may not be mirrored into any queryable BQ table — the APM trace is the reliable attribution source, not CDC (whose DELETE events only carry the primary key) and not BQ.

- **Cloud Cost (`datadog.cost.amortized`) is NOT gated by the `cases` toolset — and a metric that EXISTS but returns NO_DATA is an ingestion problem, not an MCP config problem.** Cost is queried via `get_datadog_metric(use_cloud_cost=true)` on metric `datadog.cost.amortized` (the ONLY Cloud Cost metric enabled on the GenialCare org — `all.cost` does not exist here). Adding `?toolsets=all,cases` to the Datadog MCP URL unlocks CASE MANAGEMENT (`search_datadog_cases`), not cost — the two are unrelated. When cost returns NO_DATA, do this before blaming the query: (1) confirm the metric exists via `search_datadog_metrics(use_cloud_cost=true)` — it lists `datadog.cost.amortized` plus `cloud_cost_months_queried`; (2) confirm tags are intact via `get_datadog_metric_context(use_cloud_cost=true)` (`cost_type`, `dimension`, `datadog_product`, …); (3) query the BARE metric — no `filters`, no `group_by` — across BOTH current and prior month, and BOTH daily (`rollup_interval:86400`) and monthly (`2592000`) rollups. If all shapes return NO_DATA while the metric + tags are intact, the data stopped flowing into Cloud Cost Management on the org — escalate to whoever owns Datadog billing/CCM, don't keep tweaking the query. (Observed 2026-09: cost reported fine ~07–08 Sep then went NO_DATA; metric + tags intact, every query shape empty → ingestion/CCM issue, not MCP or toolset.) This is the cost of DATADOG ITSELF (the org's own Datadog bill — APM hosts, indexed logs, ingested spans, RUM sessions), NOT cloud-infra cost: confirm via the metric tags `datadog_product` (apm/logs/rum/…) and `dimension` (apm_host/logs_indexed_30day/…). Three extra checks before escalating: (a) `cost_recommendations` is AMBIGUOUS — it returns \"not a CCM customer OR has no recommendations\"; do NOT conclude \"not a CCM customer\" from it, since \"has no recommendations\" is the normal case for Datadog's own-cost metric (it never produces cloud savings recommendations) — the metric-level NO_DATA tests above are the real signal. (b) Decisive delay-vs-loss test: re-query the EXACT window a prior report successfully populated (values are committed in `inbox/monitoring/*/report.md` under the repo's `application-monitoring` skill output); if that historical window NOW returns NO_DATA, the data was removed / access revoked — NOT a billing delay (a delay preserves history). (c) The OAuth token's `scope` must include `cloud_cost_management_read` (read the `scope` field of `~/.hermes/mcp-tokens/datadog.json`, never the access_token): missing scope = token problem; scope present but NO_DATA = org/ingestion problem.

- **A user-reported *generic* frontend message ("não foi possível enviar", "tente novamente", a generic toast) can mask a *clean, intended* backend business rejection — always pull the APM span's `custom.error.message` / `trailblazer.errors` to get the REAL code before concluding the backend is broken.** The failure is often in the frontend's error-code DETECTION, not the backend. Concretely (worked example: COPM form `submitCopmForm`): core returns 422 + `{errors:[{code:"AGREEMENT_ALREADY_COMPLETED"}]}`, but the BFF (`RESTDataSource`) wraps ANY non-2xx core response as `extensions.code = 'INTERNAL_SERVER_ERROR'` — the core's real `code` lands under `extensions.response.body.errors[].code`, NOT `extensions.code`. The BFF's `formatErrorMessage` (`mobile-bff/src/utils/error-utils.ts`) also renders the code in UPPERCASE inside the message. So a mobile check like `e.extensions.code === 'AGREEMENT_ALREADY_COMPLETED' || e.message.includes('agreement_already_completed')` is silently ALWAYS false (wrong extensions field + case-sensitive lowercase match vs uppercase message) — the user sees the misleading generic "tente novamente" instead of the intended "já registrada". Detection recipe: (1) the APM span `status:error` + `custom.error.message` gives the true core code; (2) cross-check the frontend `catch` block's error-detection branch; (3) the fix is either propagate core's `code` to GraphQL `extensions.code` in the BFF, or read `extensions.response.body.errors[].code` + case-insensitive match client-side. Blast radius: `aggregate_spans` on `resource_name:*<UseCase>* status:error` grouped by `@error.message` — a high count of one code means systemic, not one family.

- **To prove HOW a user reached a screen (not just that they errored there), pull `@type:view` events for that user and sort by timestamp — `view_name` maps to React Navigation screen names, so the chronological sequence IS the navigation trail.** A tight window like `Home → CompletedAgreementList → CopmFormCover → CopmFormArea` proves the user navigated through "Combinados concluídos" to reopen a completed form — refuting a hypothesis like "the app froze and stayed on the page for weeks". Each screen mount is one view, so timestamps reflect when each screen became active. This is the concrete evidence to show a user who is skeptical of a navigation hypothesis ("a família nunca reabre combinados concluídos"). Worked example: the COPM "already completed" incident — the view sequence proved the caregiver reopened an already-completed agreement via the completed-agreements list (tappable `MiniAgreementListItem` → `useOpenAgreement` with no `completedAt` guard), rather than a stuck screen.

- **To answer "where did the user come from — a notification, a link, or in-app navigation?" read `view.referrer` and the `utm_*` params on `view.url` from a raw RUM error/view event (not just the `@type:view` trail).** `view.referrer` empty + `view.url` carrying `utm_source=whatsapp&utm_campaign=next_session_notification` is the smoking gun that the entry point was a **WhatsApp "next session" deep link**, not in-app navigation. `view.referrer` = `https://auth.genialcare.com.br/` or `/?code=...&state=...` = came through the Auth0 login callback; an internal `/panel/...` referrer = in-app click. The raw events endpoint is `pup api -X POST v2/rum/events/search` (see `references/pup-cli.md` for the exact body + the `context.graphQLErrors[].path` / `extensions.response.url` fields that leak the failing GraphQL field and the entity UUID).

- **To hand the user a clickable Datadog link to watch the incident, construct the RUM Session Replay / Explorer URL — and remember `@session.id` (RUM browser session) is NOT the clinical session/case id.** Replay: `https://app.datadoghq.com/rum/replay/sessions/{session_id}?from_ts={from_ms}&to_ts={to_ms}&live=false` (site US1 = `app.datadoghq.com`); Explorer for the raw errors: `https://app.datadoghq.com/rum/explorer?query=@session.id:{session_id} @type:error&from_ts=...&to_ts=...`. Get `session.id`/`view.id` from the raw event (`.attributes.attributes.session.id`) and the `from_ts`/`to_ts` as epoch-ms around the event's `.attributes.timestamp`. **The clinical case/session UUID the user asks about is NOT a RUM facet — it lives inside `@view.url`** (`/clinical-cases/<caseId>/sessions/<sessionId>/preparation`), so point the user at the replay's URL bar or add the `@view.url` column in Explorer (this is usually the source of "how do you know the session id — I don't see it in Datadog"). Also, a GraphQL 403 is a *silent* `@type:error` (that field just fails to load) and does NOT reliably show as a visible red banner in the replay — direct the user to `@type:error` in Explorer to see the actual failure rather than expecting a visual error on-screen.

- **A 403 "Acesso não permitido." that arrives via a notification deep link is usually a NOTIFICATION-TARGETING bug, not a permission bug — verify the user is still linked to the case before blaming `ClinicalCasePolicy`.** When the RUM referrer shows a `utm_source=whatsapp&utm_campaign=next_session_notification` deep link landing on `/sessions/<id>/preparation`, the recipient is a clinician who was notified about a session but is NO LONGER in `clinical_case_clinicians` for that case (or the session is already `completed`). Core's `default_access?` denial is *correct* — the defect is Customer.io still sending the "next session" notification to a de-linked clinician. Confirm via Postgres (`kubectl exec -n core <web-pod> -c web -- psql "$DATABASE_URL"`): (1) `SELECT clinician_id, clinician_role, to_be_removed_at FROM clinical_case_clinicians WHERE clinical_case_id='<id>'` — the recipient's `clinician_id` is absent; (2) `SELECT status, completed_by_id FROM general_sessions WHERE id='<session>'` — often `status='completed'` and `completed_by_id` = that same clinician (they finished the session long ago, then were removed from the case). Fix is on the notification side (exclude clinicians without an active case link, and drop `completed`/`cancelled` sessions from the deep-link target), plus optionally a graceful frontend state ("você não tem mais acesso a este caso") instead of a raw `ApolloError`. The `users` table has no `user_type` column — resolve clinician-vs-caregiver by which join table has a row (`clinicians.user_id` vs `caregivers.user_id`).

- **To list Datadog CASES (Case Management, keyed `ET-*` / `PER-*` / `MON-*`) by assignee: resolve the user's UUID first, and do NOT mix the `assignee` param with a `query` string.** `mcp__datadog__search_datadog_cases` (and `search_datadog_users`) require a `telemetry` object with an `intent` string — calls fail with a missing-argument error without it. The `assignee` filter takes a **UUID, not email**: `search_datadog_users(query='<email>')` returns the `uuid` (e.g. `fa4e9148-...`). Gotcha: passing BOTH the `assignee` param AND a `query` string like `status:OPEN OR status:IN_PROGRESS` causes the query to **override the assignee filter** — you silently get every open case in the org (other people's cases included). To combine filters, put everything in the query: `search_datadog_cases(query='assignee:<uuid> AND (status:OPEN OR status:IN_PROGRESS)', view='summary')`. Status values for standard cases are OPEN/IN_PROGRESS/CLOSED; Error-Tracking issues (`type: ERROR_TRACKING_ISSUE`) are the bulk of the ET-* keys and auto-close when the error stops recurring. Cases with no `assignee_name` field in the result are unassigned — useful when the user asks "what's open with me" vs "what's open at all".

- **When a "size cannot be less than N" / `MIN_SIZE` 422 surfaces and the frontend *does* already have a min-length rule, the bug is almost always a character-counting divergence — JS counts UTF-16 code units, Ruby counts code points.** The core error message "size cannot be less than 5" comes from a dry-validation contract predicate `min_size?: 5` (e.g. `core/packs/clinical/app/concepts/clinical_guidance/use_cases/create_comment.rb:6`), mapped to code `MIN_SIZE` in `core/app/infra/http_error_format.rb` `PREDICATES_MAP` (`min_size? → "MIN_SIZE"`, `key? → "REQUIRED"`). The frontend guards the same field with react-hook-form `minLength: 5`, which uses JS `String.length` — emoji above U+FFFF (surrogate pairs: 👏💜 etc.) count as **2** code units in JS but **1** character in Ruby. So a 4-emoji comment "👏👏👏💜" = 8 in JS (passes `minLength: 5`) but = 4 in Ruby (fails `min_size?: 5`), letting the user submit and hit a raw backend 422. One-line diagnosis: `node -e 'console.log("👏👏👏💜".length, [..."👏👏👏💜"].length)'` → `8 4`, vs `ruby -e 'puts "👏👏👏💜".size'` → `4`. Fix is on the FRONTEND (the backend rule is correct and stays): replace `minLength` with `validate: (v?: string) => [...(v ?? '')].length >= N || 'Mínimo N caracteres'` (spread counts code points, matching Ruby; the `?? ''` guards `undefined` — react-hook-form passes it for an untouched field, `[...undefined]` throws `TypeError`, and `required` doesn't stop `validate` from running). Generalize: any "backend rejects what frontend allowed" where both layers appear to validate the same field is a candidate for this encoding/counting mismatch, not a missing rule.

- **A `Couldn't find <Model> with [WHERE "...".tenant_id = $1 AND "...".id = $2]` 404 (Rails `find!` miss on an `acts_as_tenant` model) is usually a MULTI-TENANT mismatch, not a deleted record — verify before assuming data loss.** A user in more than one tenant can be authenticated into tenant B while opening a link/bookmark/notification that points to a record in tenant A; the tenant-scoped query then returns nothing and the record *looks* deleted when it isn't. Read-only diagnosis via `bin/rails runner -` (`kubectl exec -i -n core web-<pod> -- bin/rails runner - < /tmp/x.rb`): (1) list the user's tenants — `User.find_by(email:).tenants` (join table `tenants_users`); (2) check the record cross-tenant — `ActsAsTenant.without_tenant { General::Sessions::Session.unscoped.find_by(id:) }` and read `tenant_id`/`status`/`cancelled_at` (a non-nil status + nil `cancelled_at` ⇒ exists, never deleted); (3) **the decisive step** — check a SIBLING record the user DID access successfully around the same time (grab it from the RUM `@type:view` trail) and read ITS `tenant_id`: if it sits in the user's "other" tenant, that proves which tenant the request was actually scoped to. Tenant is resolved in `core/app/controllers/concerns/secured.rb` `get_current_tenant_from_user_session`: `org_id` (Auth0 org claim) → `X-TENANT-ID` → `X-TENANT-NAME` → `params[:tenant_id]` → `params[:tenant_name]`, each mapped to `Tenant.external_id`/`name`. Recurring errors with the SAME entity id + SAME user across days = a stale saved link/notification, not fresh navigation. This is correct tenant isolation, not a code bug — the fix is UX (frontend should distinguish NOT_FOUND from "wrong tenant"), not the backend. Full recipe + model/tenant facts in `references/multi-tenant-notfound.md`.

- **When a user reports "403 errors popping up" across clinical-panel / clinical-panel-bff / core, do NOT conflate 403 and 401 — they are different layers and the fix lives in different places.** In core, **403 = authorization** (Pundit) and **401 = authentication** (JWT rejected). The 403s come from `ClinicalCasePolicy#default_validation` (`core/packs/clinical/app/policies/clinical_case_policy.rb`), which logs `Error when trying to access clinical case X by user Y` before raising `ClinicalCaseAccessDenied` — this is *correct* isolation of a user lacking a `clinician`/`caregiver` link to the case (usually a multi-tenant mismatch, see `references/multi-tenant-notfound.md`). The 401s come from `ValidateAccessToken` → `TokenRejectedError`. The `[Auth] JWT decode failed — fallback /userinfo triggered` WARN line fires on BOTH `JWT::ExpiredSignature` (expired) AND `JWT::MalformedTokenError: Not enough or too many segments` (wrong dot-segment count — i.e. the `Authorization` value isn't even a JWT: empty, `"Bearer"` with no token, or garbage). **Query the error classes separately to tell them apart**: `"ExpiredSignature"` vs `"MalformedTokenError"`. If ExpiredSignature = 0 but MalformedTokenError = thousands/day, the "token expired, no refresh" hypothesis is WRONG — it's a caller sending a structurally invalid token. Full worked breakdown in `references/core-403-vs-401-auth.md`.

- **Frontend/backend validation divergence around `null`/absent answers: a core rule that "requires at least one YES" will reject what a frontend `validate` that tests "NOT all NO" lets through.** When both layers appear to enforce the same business rule but the frontend still lets an invalid state submit (surfacing as a raw 422 / `ApolloError` in the panel), the bug is usually the frontend phrasing the rule as `every(answer === NO)` or `answer !== NO` — both treat `null` (unanswered) as "not NO" = valid — while core phrases it as `some(answer === YES)` (and `.compact`-drops nulls, so null is "not YES" = invalid). Fix: rewrite the frontend check to explicitly test for the YES case (`someCommonYes`, `refusalBehavior?.response?.answer === YES`), matching core's predicate shape, not just inverting the NO check. Worked example: ET-3002 (occupational-therapy assessment `expected_behavior` exclusivity) — core `valid_exclusive_combination?` in `save_occupational_therapy_assessment.rb` requires `expected="no"` ⇒ at least one other behavior `yes`; the panel's `ExpectedBehaviorAnswerCell` used `every(...=== NO)` + `!== NO`, so an `expected="no"` row with all-`null` common answers passed client-side validation but core 422'd it. The trigger scenario is often a refusal flow: marking `refusal="yes"` forces `expected="no"` and nulls the common answers, then clearing the refusal leaves `expected="no"` + all-`null` — exactly the state the old check missed.

- **`UserInputError: "Boolean cannot represent a non boolean value: \"true\""` = the client sent a JSON *string* where the GraphQL schema declares a `Boolean` scalar — an input-coercion bug rejected at the BFF before core is ever called.** Signature: `Variable "$preferences" got invalid value "true" at "preferences.canShareSchedule"`. `error_type: UserInputError`, `service: clinical-panel-bff` (the GraphQL layer). GraphQL refuses to coerce the string `"true"` → boolean, so the mutation fails input validation regardless of what core would accept. Diagnose by tracing the frontend code that builds that field — the TS type is often already `boolean`, masking a runtime string: a boolean read from a URL query param (`useParams`/`searchParams` always yield strings), a Radio/Select whose `value` is a string literal, or a `.toString()` applied to a boolean before submit. Fix is frontend-side coercion (`value === true` / re-type the Radio values as booleans), not the BFF schema. (Worked example: ET-2839, `canShareSchedule: Boolean` receiving string `"true"`.)

- **The SAME core 422 surfaces as MULTIPLE `ET-*` cases across service layers, and Datadog redaction makes them LOOK different — dedupe before treating each as a new bug.** A single business rejection in core (e.g. the `Invalid behavior combination` validation) shows up as one case per layer that logged it: `clinical-panel` logs it as `ApolloError` (client), while `clinical-panel-bff` logs the SAME upstream 422 as `GraphQLError` (server). The `error_type` + `service` fields on the `pup error-tracking issues get <id>` result tell the layers apart (`platform: BACKEND` + `service: clinical-panel-bff` vs the frontend's RUM). **The giveaway that two cases are the same bug: Datadog Error Tracking redacts short single-quoted literals in the BFF/backend case title — `'yes'`/`'no'` become `'MASKED'`.** So a case titled `...expected behavior is 'MASKED'...` is the duplicate of the sibling whose title shows `'yes'`/`'no'` literally, not a distinct error with masked secrets. When triaging a batch of assigned cases, group by the unredacted message and confirm via the fix PR before opening a new one — the frontend fix (mirroring core's predicate) resolves every layer's case at once. Worked example: ET-3002 (`clinical-panel`, ApolloError, unmasked) and ET-3003 (`clinical-panel-bff`, GraphQLError, `'MASKED'`) were the same `expected_behavior` exclusivity 422; one frontend PR fixed both.

- **To attribute WHO/WHAT is hitting a core endpoint (source IP, user-agent, params), read the ACCESS-LOG (lograge) line — the one carrying `@http.status_code` — not the `[Auth] JWT decode failed` WARN line.** The WARN line only carries `custom.request_id` (no `http.url`/`http.method`/IP). The access line carries `custom.ip`, `custom.remote_ip`, `custom.params` (e.g. `{"user":{"email":"[FILTERED]","tenant_external_id":null}}`), `custom.controller`, `custom.action`, `custom.format`. Query `service:core @http.method:POST @http.status_code:401` with `extra_fields: ["*", "ip", "remote_ip", "params"]` (bare names — no `@` or `custom.` prefix) and `grep -oE 'custom.remote_ip: [0-9.]+' | sort | uniq -c` to get the IP distribution. A single public AWS EC2 IP hitting `POST /users.json` directly (root `rack.request` span, `parent_id: "0"`, no `browser.request`/`graphql` spans) means an external/internal job calling the user-creation endpoint with a bad token — not a browser session, and not a BFF bug.

  **Two `search_datadog_logs` `extra_fields` traps that waste real time:** (1) passing a SPECIFIC field name that core's lograge doesn't index (e.g. `"http.useragent"`, `"network.client.ip"`, `"http.request.headers.user-agent"`, `"http.url"`) silently returns NOTHING for that field — the attributes block comes back empty, not an error. Use `extra_fields: ["*"]` (or the bare names `ip`/`remote_ip`/`params`/`controller`/`action`/`format`) to see what core actually logs. The full set core emits on an access line: `custom.ip`, `custom.remote_ip`, `custom.params`, `custom.controller`, `custom.action`, `custom.format`, `custom.http.method`, `custom.http.status_code`, `custom.http.url_details.path`, `custom.duration`, `custom.db`, `custom.view`, `custom.allocations`, `custom.request_id`. (2) **`http.useragent` / `http.referer` are NEVER captured by core** (the Rack/APM spans also carry no `http.request.headers.*` — only `http.response.headers.*`). If you need user-agent/referer to fingerprint a caller, the Rails layer discards it — go to the GCP Load Balancer / ingress logs instead of re-querying Datadog for a field that isn't there.

  **Driving the Datadog MCP directly when the session catalog lacks the `mcp__datadog__*` tools:** after `hermes mcp login datadog`, if the session's tool catalog still lacks the MCP tools and no user is present to type `/reload-mcp`, query Datadog by calling the MCP endpoint over Streamable HTTP yourself with the OAuth access token from `~/.hermes/mcp-tokens/datadog.json`. A small Python driver (urllib POST to the MCP URL, `Authorization: Bearer <access_token>`, JSON-RPC `tools/call` with `{name, arguments}`) works; responses come back as either plain JSON or SSE (`event:`/`data:` framing), so parse both. Per-tool argument schemas differ: `search_datadog_logs` rejects `detailed_output` and takes `extra_fields`; `search_datadog_spans` rejects `extra_fields`; `search_datadog_rum_events` rejects `limit`. The access token is short-lived (~1h) — refresh via the stored `refresh_token` when it 401s, but note the refresh token itself can expire and force a fresh `hermes mcp login datadog` (needs a TTY: `script -q /dev/null`).

 - **To answer "is this traffic coming from Auth0?" (e.g. "repeated POST /users.json requests"), verify the source IPs against Auth0's published egress ranges — do NOT stop at "it's AWS".** Get the IP distribution from the access-log line via `analyze_datadog_logs`: `filter='service:core @http.method:POST @http.url_details.path:"/users.json"'`, `extra_columns=[{"@ip":varchar},{"@http.status_code":varchar}]`, `SELECT "@ip", "@http.status_code", count(*) AS cnt FROM logs GROUP BY "@ip", "@http.status_code" ORDER BY cnt DESC`. Then fetch `https://cdn.auth0.com/ip-ranges.json` (machine-readable; keys `regions` → US/EU/AU/JP/UK/CA, each with `ipv4_cidrs`) and match each IP with Python `ipaddress` — Auth0 lists many egress IPs as exact `/32`, so `ipaddress.ip_address(ip) in ipaddress.ip_network(cidr)` works. The docs page is `https://auth0.com/docs/secure/security-guidance/data-security/allowlist.md` (the old `/secure/networks/ip-addresses` URL 404s; append `.md` to fetch raw markdown). Worked example (2026-09, POST /users.json): 3.134.176.17, 18.116.79.126, 3.133.18.220 all matched Auth0 US `/32`. Supporting clue the caller is Auth0's user-sync flow: `tenant_external_id` arrives as an Auth0 **Organization ID** with the `org_` prefix (e.g. `org_jTwTzOJkZPMDw7kw`). If some of those requests 401 with `JWT::MalformedTokenError: Not enough or too many segments`, the Auth0 Action/Rule is intermittently sending a structurally-invalid/empty `Authorization` header (bug in the Action's token attachment), not expired tokens — see the 403-vs-401 pitfall above for the MalformedTokenError-vs-ExpiredSignature distinction.

  **When a user asks "does this traffic come from Auth0?" there are TWO senses — separate them, because they give opposite answers.** (1) *Flow* ("is Auth0 the HTTP client hitting core?"): **never.** Read the span tree of a trace: the inbound request is the `rack.request` span (`parent_id: \"0\"`, `span.kind: server`, `http.base_url: core.genialcare.io`); the `ethon.request` span (`resource: GET`, `parent_id` = that root span) is core making an **egress** call OUT to `https://auth.genialcare.com.br/userinfo` to validate a token it couldn't decode. Auth0 only ever appears as the outbound validator, never as the caller. (2) *Network identity* ("is the source IP Auth0's egress infra?"): **possibly** — Auth0 runs on AWS, so an IP like `3.134.176.17` (AWS EC2 us-east-2) can sit inside Auth0's published egress ranges even though it's nominally \"AWS\", and that's the signal that the caller is an Auth0 Action/Rule/Hook (post-login user-sync) rather than a random EC2. Confirm with the egress-range match above. **Do not answer the flow question with the identity evidence or vice versa** — \"it's an AWS IP\" does not disprove Auth0-as-source (flow), and \"Auth0 is in the trace as /userinfo\" does not prove Auth0 is the caller (identity). The user's phrasing \"o IP bate direto no core e não vem do Auth0?\" is asking the FLOW sense: answer it with the span directionality (rack.request = inbound caller; ethon.request = outbound validator), then optionally add the identity check.

 ## Cross-references

- **`investigate-core-flow`** — Rails/core investigation procedure, CDC event tables
  (`raw.<table>_events`), and the `Wrap(TrailblazerTransactionWrap)` silent-rollback pitfall
  this skill's step 5 depends on.
- **`investigate-bff-flow`** — Node.js GraphQL BFF layer; check when the trace shows a
  `clinical-panel-bff` span alongside the `core` spans (BFF proxies to core over HTTP, visible
  as `graphql.resolve` / `http.request` spans in the same trace).
- **`genialcare-bigquery-queries`** — General BQ CLI usage, dataset locations, and CSV
  reconciliation patterns.
- **`mcp-troubleshooting`** — Datadog MCP OAuth/token setup and the `/reload-mcp` fix for a
  stale in-session tool catalog.

## Support files

- `references/multi-tenant-notfound.md` — multi-tenant 404 diagnosis recipe (cross-tenant record
  check, tenant resolution order in `secured.rb`).
- `references/core-403-vs-401-auth.md` — 403 (Pundit) vs 401 (JWT) breakdown, the
  MalformedTokenError-vs-ExpiredSignature trick, and the access-log attribution recipe.
- `references/source-ip-to-business-owner.md` — resolving a source IP to the *business* owner
  (tenant/email-domain via `rails runner` read-only) when WHOIS only yields "AWS"; Rails runner
  `Arel.sql` + kubectl SA-auth pitfalls.
- `references/pup-cli.md` — the Datadog `pup` CLI (install incl. macOS Sequoia workaround,
  OAuth auth, and case/error-tracking/log query recipes) as a terminal alternative to the
  `mcp__datadog__*` tools.
- `references/frontend-crash-browser-repro.md` — minimal-harness recipe to prove a frontend
  render-time crash before/after a fix in a headless browser (no auth/backend): provider
  stack, exported-vs-private-context stub trick, `vite.config.ts` for `baseUrl: "./src"`.
