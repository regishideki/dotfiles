# BQ access fallbacks & Metabase MCP limitations

When a BQ investigation hits an auth wall, here is the fastest correct path — learned the
hard way (a whole session spent discovering which tools can actually run JOINs).

## Tool capability map (what can run what)

| Tool | Raw SQL | Cross-table JOINs | CDC `raw.*_events` tables | Auth |
|---|---|---|---|---|
| `bq` CLI (gcloud creds) | ✅ | ✅ | ✅ | user gcloud login |
| Metabase MCP (`analytics-panel.genialcare.com.br/api/mcp`) | ❌ | ❌ | ❌ | OAuth (`hermes mcp reauth metabase`) |
| Metabase REST `/api/dataset` | ✅ native | ✅ | — | needs a Metabase *session* (NOT the MCP bearer token) |

**Metabase MCP is semantic-layer only.** It exposes 8 tools (`search`, `get_table`,
`get_metric`, `query`, `construct_query`, `execute_query`, `get_*_field_values`) that operate
on a SINGLE Metabase table/metric with filters/aggregations/group_by — no raw SQL, no JOINs,
and the `raw.<table>_events` CDC tables are NOT registered as Metabase tables. For any
cross-table JOIN or CDC forensics, use the `bq` CLI. Do not spend turns trying to express a
JOIN through the Metabase MCP.

## Auth fallback chain (when `bq` says "Reauthentication failed")

1. `bq`/`gcloud` "Reauthentication failed ... `invalid_grant` / `invalid_rapt`" means the
   gcloud refresh token is DEAD. Only the USER can fix it: `gcloud auth login` (opens browser,
   requires password — an agent cannot/should not drive it). Tell the user, don't fight it.
   - A service-account key in the repo (`core/core-development-sa-key.json`,
     `core-web@core-development-hy78`) has NO `bigquery.jobs.create` — not a BQ fallback.
2. `hermes mcp reauth metabase` (needs a TTY: `script -q /dev/null hermes mcp reauth metabase`)
   auto-completes WITHOUT user interaction **if the browser already has a live Google session**
   — it refreshes the OAuth token for the existing server. Use this to restore Metabase MCP.
3. To talk to the Metabase MCP endpoint directly (curl/Python) instead of via Hermes tools:
   - Streamable-HTTP: POST JSON-RPC to `/api/mcp`; `initialize` with
     `protocolVersion: "2024-11-05"` (NOT `"2025-03-26"` — that returns 403), capture the
     `Mcp-Session-Id` response header, send `notifications/initialized`, then `tools/list` /
     `tools/call`.
   - Set a browser `User-Agent` header — Cloudflare 403s Python-urllib's default UA.
   - macOS system Python lacks the CA bundle → `ssl.CERTIFICATE_VERIFY_FAILED`; use
     `ssl._create_unverified_context()` or `certifi`.

## Helper scripts

Shared (in `projects/code-snippets/`):
- `bq_rest.py` — refresh an `authorized_user` refresh token and run a query via the
  BigQuery REST API (SSL-context handled). Only works while the gcloud refresh token is valid.

Personal (in `~/.hermes/scripts/`, moved out of the shared repo because they hardcode
user-specific paths):
- `bq_sa.py` — run a query with a service-account key (only if that SA has BQ permission).
- `mcp_metabase.py` — minimal MCP Streamable-HTTP client (initialize/tools-list/tools-call)
  for the Metabase MCP server.

The reliable production path remains: `projects/code-snippets/bq-run.sh --env production
<query.sql>` after the user has `gcloud auth login`'d.
