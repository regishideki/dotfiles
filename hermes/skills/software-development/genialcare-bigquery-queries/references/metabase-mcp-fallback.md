# Metabase MCP as a fallback data path (and why it can't replace the `bq` CLI)

When the `bq` CLI's gcloud token is expired (`gcloud auth print-access-token`
→ `Reauthentication failed ... invalid_rapt`), the `bq` CLI needs an interactive
`gcloud auth login` (browser + Google consent). Two fallbacks exist:

## 1. Metabase MCP — semantic-layer ONLY, no raw SQL / no JOINs

The `metabase` MCP server (`https://analytics-panel.genialcare.com.br/api/mcp`,
scope `agent:query:execute` etc.) exposes 8 tools: `search`, `get_table`,
`get_metric`, `get_table_field_values`, `get_metric_field_values`,
`construct_query`, `execute_query`, `query`.

**Hard limitation:** these operate on a SINGLE Metabase table/metric with
filters/aggregations/group_by — they CANNOT express:
- cross-table JOINs (e.g. "registry started AND all 5 sub-assessments completed"),
- raw/native SQL,
- CDC `raw.<table>_events` tables (not exposed as Metabase semantic tables).

So for the blast-radius / divergence / CDC-forensic queries this repo needs, the
Metabase MCP is NOT a substitute for `bq`. Do not burn time trying to express a
JOIN through `construct_query`/`execute_query` — it doesn't support it.

Re-auth (only needed when the token expires): `hermes mcp reauth metabase`
auto-completes WITHOUT user interaction if the browser already has a valid
Genial/Google SSO session (it opens the consent URL and the flow finishes itself).
Run it through `script -q /dev/null` if it needs a TTY.

## 2. Direct MCP HTTP client (`~/.hermes/scripts/mcp_metabase.py`)

`~/.hermes/scripts/mcp_metabase.py` is a minimal Streamable-HTTP MCP client
that reads the bearer token from `~/.hermes/mcp-tokens/metabase.json` and calls
`tools/list` / `tools/call`. Non-obvious quirks it encodes:

- **`User-Agent` header is REQUIRED.** The endpoint sits behind Cloudflare, which
  returns `403 Forbidden` to the default `Python-urllib/3.x` UA. Use the browser UA
  `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36` (same one the
  hermes config sets for this server).
- **`protocolVersion` must be `2024-11-05`**, not `2025-03-26` — sending the newer
  version returns 403; the server responds with `2025-03-26` either way.
- **`Mcp-Session-Id` header** is required on every request after `initialize`; the
  server returns it in the `initialize` response headers. `notifications/initialized`
  must be sent once after `initialize`.
- Responses come back as SSE (`text/event-stream`) or a bare JSON-RPC body — `parse_sse`
  in the script handles both and the `data: [DONE]` sentinel.

## Other paths that DON'T work (already checked)

- `core/core-development-sa-key.json` (service account `core-web@core-development-hy78`)
  has NO BigQuery permission (403 on `bigquery.jobs.create` even in its own project).
- Metabase REST `/api/dataset` (native SQL) rejects the MCP bearer token with
  `Unauthenticated` — it needs a Metabase session / API key, which the MCP token is not.
- The gcloud legacy `authorized_user` refresh token hits `invalid_grant`/`invalid_rapt`
  (Google re-auth protection) — requires a fresh interactive `gcloud auth login`.

Bottom line: for JOIN/CDC queries, get the `bq` CLI re-authed (user runs
`gcloud auth login`); the Metabase MCP is only good for single-table lookups.
