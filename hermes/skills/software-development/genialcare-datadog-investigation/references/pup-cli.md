# Datadog `pup` CLI

`pup` is Datadog's "AI-agent-ready" command-line interface — a Go-based wrapper over the
Datadog APIs that mirrors what the `mcp__datadog__*` tools do, but from a shell. It's the
successor to the old `doggo` CLI and is documented at https://docs.datadoghq.com/cli/ and
github.com/DataDog/pup. When the Datadog MCP tools aren't in the session catalog (or you'd
rather drive Datadog from a terminal than through MCP tool calls), `pup` is the clean
alternative — same data, `--jq` filtering, and `--output json|table|csv`.

## Install

```bash
brew tap datadog-labs/pack && brew install datadog-labs/pack/pup
```

**macOS Sequoia gotcha:** `brew install` of `pup` fails with
`Error: Xcode alone is not sufficient on Sequoia. Install the Command Line Tools:
xcode-select --install`. The formula is just a prebuilt binary tarball, so bypass Homebrew:
download the release directly and verify its SHA256 against the value in the formula
(`brew info datadog-labs/pack/pup` shows the source URL; the formula source is at
`/opt/homebrew/Library/Taps/datadog-labs/homebrew-pack/Formula/pup.rb`):

```bash
# Darwin arm64 example — check the current version/sha in the formula first
curl -sL https://github.com/DataDog/pup/releases/download/v1.24.0/pup_1.24.0_Darwin_arm64.tar.gz -o /tmp/pup.tar.gz
shasum -a 256 /tmp/pup.tar.gz   # compare to formula sha256
tar xzf /tmp/pup.tar.gz         # extracts a `pup` binary
mkdir -p ~/bin && cp /tmp/pup ~/bin/pup && chmod +x ~/bin/pup
```

`~/bin` is already on PATH in this environment. Auth is OAuth2+PKCE (scoped, ~24h refresh):
`pup auth login` then `pup auth status`.

## Recipes discovered (GenialCare investigation)

**Find your own user UUID** (needed for case-assignee filtering):
```bash
pup api v2/current_user          # data.attributes.uuid, .email, .name
```

Alternative when you only know an email (or `pup api v2/current_user` isn't handy):
`pup users list` — but **default page-size is 10**, so a 36-user org silently returns only
the first 10. Pass `--page-size 1000` to get everyone, then `--jq` filter by email:
```bash
pup users list --page-size 1000 --jq '[.[] | select(.attributes.email|test("regis";"i")) | {id, email:.attributes.email, name:.attributes.name}]'
```
Note the list shape is `{data:[{attributes:{email,name,handle}, id}]}` — jq must read
`.attributes.email` (the whole record has no top-level `email` key). `pup users get me`
404s (`user not found`); there is no `me` shorthand.

**List Case Management cases assigned to a user** — the `--query` facet is the user's
**UUID**, not email. `assignee:regis@genialcare.com.br` and `assignee:Regis Hattori` return 0.
Two facets both work against a UUID: `assignee:<uuid>` (verified 2026-10-06, returned 86 cases)
and `assignee_id:<uuid>` (verified earlier, 83 cases). Prefer `assignee:<uuid>`; if it ever
returns 0, fall back to `assignee_id:<uuid>`. Both are verified via `relationships.assignee.data.id`:
```bash
pup cases search --query "assignee_id:fa4e9148-62a0-11ec-af40-da7ad0900002" --page-size 100
```
Response is `{data:[...], meta:{total_cases}}`; each case has `attributes.key` (`ET-3002`),
`attributes.title`, `attributes.status_name`, `attributes.priority`, and a
`relationships.assignee.data.id`. `--query` without `assignee:` does free-text search over
title/description, not assignee.

**Case lifecycle — status and comments** (no `COMPLETED` status; the terminal value is
`CLOSED`):
```bash
pup cases update-status --status CLOSED <case-id>     # valid: OPEN, IN_PROGRESS, CLOSED
pup cases comments create --body "..." <case-id>       # leave a traceability note (e.g. link the fix PR)
pup cases comments list <case-id>                      # body lives at .data[].attributes.cell_content.message
```
`pup cases update-status --status FOOBAR ...` errors with `use OPEN, IN_PROGRESS, CLOSED`,
confirming the enum. When the user says "marcar como completo", map that to `CLOSED`. To
close a case whose fix PR is already merged, add a comment first linking the PR, then
`update-status --status CLOSED`.

**Get an Error Tracking issue by id** (from a case's `attributes.insights[].resource_id`):
```bash
pup error-tracking issues get 05aceb84-bb39-11f1-8d71-da7ad0900002
```
Returns `error_message`, `error_type`, `service`, `first_seen`, `last_seen_version`,
`state`. Note `pup api v2/error-tracking/issues/<id>/events` 404s — `pup error-tracking
issues get` is the working path.

**Sort cases by occurrence count** (the "which of my cases fires most?" workflow): the case
object does NOT carry a count — you get it from Error Tracking. Each `ERROR_TRACKING_ISSUE`
case links to its issue via `attributes.insights[].resource_id`; the occurrence count is the
issue's `total_count` from a search:
```bash
# sort ALL error-tracking issues assigned to a user by occurrence count, desc
pup error-tracking issues search --assignee fa4e9148-... --order-by TOTAL_COUNT --persona ALL --from 90d
# → data[] each have attributes.total_count (the occurrence count)
```
Two traps:
- **`--track` and `--persona` are mutually exclusive, and one of them is REQUIRED** (omitting
  both errors "required arguments: --track --persona"; passing both errors "cannot be used
  with"). For a mixed service (browser + backend, i.e. RUM + logs) use `--persona ALL` to cover
  both tracks at once.
- **`total_count` is scoped to the `--from`/`--to` window**, and `--state` filters it further.
  `--from 30d --state ACKNOWLEDGED` returns only the currently-open issues with their window
  counts; dropping `--state` and widening `--from 90d` surfaces CLOSED issues too (which often
  have far higher historical counts). Decide the window to match the question ("open cases now"
  vs "biggest offenders ever"). `--order-by` also accepts `FIRST_SEEN`, `IMPACTED_SESSIONS`,
  `PRIORITY`.

Note the count can UNDERSTATE the true blast radius: Error Tracking groups by fingerprint, so
one "issue" with `total_count: 4` can correspond to ~100 underlying core log lines of the same
generic message (e.g. "Acesso não permitido.") — the count is per-fingerprint, not per-request.
To size the real volume, search the SOURCE logs and aggregate (see the `--jq`/`grep` group-by
pattern below).

**Search logs** (v1 API, `service:` + free-text):
```bash
pup logs search --query 'service:clinical-panel-bff "some message"' --from '7d' --limit 20
```

**Search RUM events (raw) — the endpoint for "which page + where did they come from"**:
`pup rum` has no `events search` subcommand; drive the v2 API directly with a POST body:
```bash
cat > /tmp/rum.json << 'EOF'
{"filter":{"from":"now-7d","to":"now",
  "query":"@type:error @application.id:f5443c26-0b27-44c8-8f42-cf71414db108 \"Acesso não permitido\""},
 "page":{"limit":100}}
EOF
pup api -X POST v2/rum/events/search --input /tmp/rum.json
```
`--application.id` is the RUM app UUID (`pup rum apps list` → Clinical Panel =
`f5443c26-0b27-44c8-8f42-cf71414db108`, type `react`). The gold is under
`.data[].attributes.attributes`:
- `.view.url` — the destination page, **including `?utm_source=...&utm_campaign=...`**.
- `.view.referrer` — where they navigated from (empty = deep link / external app).
- `.context.component` — the React component that errored (e.g. `ClinicalCaseInfos`).
- `.context.graphQLErrors[].path` — the failing GraphQL field path (`["clinicalCase","currentComplexityScore"]`).
- `.context.graphQLErrors[].extensions.response.url` — the **internal core URL** that 403'd
  (`http://core-internal.api-gateway.svc.cluster.local/clinical_cases/<id>/complexity_scores/current.json`),
  which leaks the entity UUID for follow-up DB queries.
- `.usr.id` / `.session.id` / `.attributes.timestamp` for grouping.

`view.referrer` + the `utm_*` params on `view.url` are the direct answer to "the user came
from a notification / a link / internal navigation" — e.g. `utm_source=whatsapp&utm_campaign=next_session_notification`
proves the entry point was a WhatsApp "next session" deep link. `view.referrer` of
`https://auth.genialcare.com.br/` or `/?code=...&state=...` = came through the Auth0 login
callback; an internal `/panel/...` referrer = in-app navigation.

**Source-log aggregation for the true blast radius** (one error-tracking issue = one
fingerprint, not one request — see the note above): group raw `service:core` logs by the
entity/user pair with jq:
```bash
pup logs search --query '"Error when trying to access clinical case"' --from 7d --limit 500 -o json \
  | jq -r '.data[] | .attributes.message | capture("clinical case (?<c>[0-9a-f-]+) by user (?<u>[0-9a-f-]+)") | "\(.u) -> \(.c)"' \
  | sort | uniq -c | sort -rn
```
A single pair at 99× in a week is a stuck/looping client or a stale-notification blast, not
casual one-off access.

**Get the FULL stack trace (exact file:line) — `pup error-tracking issues get` does NOT
return it.** The issue object only carries `error_message`, `error_type`, `file_path`,
`first_seen`, `last_seen`, `service` — no `error.stack`. To get the line-level stack:
(1) `pup logs search --query 'service:core "<error message fragment>"' --from '1d'` to find a
log line whose `message` carries `dd.trace_id=<id>`; (2) fetch the trace with
`pup api 'v1/trace/<trace_id>'` — **v1 works, `v2/trace/...` 404s**; (3) the response is
`{trace:{spans:{...}}}` — each span's `resource` names the controller action (e.g.
`General::SessionsController#show`) and `meta.error.stack` holds the full backtrace with the
exact app line (`.../general/sessions_controller.rb:38:in '...Controller#show'`) plus
`meta.http.url` / `meta.http.method` / `meta.http.status_code`. `pup traces search` returns
spans but error spans are sampling-dropped — once you have a `trace_id`, `v1/trace/<id>` is
the reliable path. Query-syntax traps: `@error.type:ActiveRecord::RecordNotFound` breaks the
parser (the `::` confuses it), and `--from '30 minutes'` is invalid (use `30m`, `1d`, etc.).

## CLI structure notes

- Top-level commands mirror Datadog products: `cases`, `error-tracking`, `logs`, `metrics`,
  `apm`, `ddsql`, `users`, `api`, `monitors`, `rum`, `security`, etc.
- `pup api <endpoint>` sends raw requests (`v2/current_user`, `v2/cases/...`); relative paths
  auto-prefix `/api/`.
- Global flags: `--output json|table|yaml|csv|tsv`, `--jq '<expr>'` (applied before
  formatting), `--read-only` (blocks write ops), `-v` (rate-limit headers).
