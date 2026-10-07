# Pulling large BQ result sets (and the Metabase MCP 200-row cap)

When a panel/pipeline needs 1k–100k+ rows from production BQ, two read paths exist and they are
NOT interchangeable. Pick based on result size and whether the table is Drive-backed.

## Metabase MCP `execute_query` caps at 200 rows (server-enforced)

`mcp__metabase__execute_query` accepts a base64-encoded MBQL payload with a native stage to run
raw BigQuery SQL (cross-project joins, CTEs, `qualify`, window functions all work):

```python
payload = {"lib/type": "mbql/query", "database": 4,
           "stages": [{"lib/type": "mbql.stage/native", "native": SQL}]}
q = base64.b64encode(json.dumps(payload).encode()).decode()
```

But the server injects `"constraints": {"max-results": 200, "max-results-bare-rows": 200}` and
**ignores override attempts**. A 182k-row result would need ~900 OFFSET pages (each re-runs the
whole query = O(n²) on BQ, locks the slot). For anything over a few hundred rows, use the Python
client below instead of the MCP.

## Python `google-cloud-bigquery` via ADC — the path for large results

The ADC (`~/.config/gcloud/application_default_credentials.json`, type `authorized_user` with a
`refresh_token`) authenticates the `google-cloud-bigquery` library directly and reads production
datasets (`supervision-production-8f1v`, `data-kernel-production-4o7n`, `ops-data-production-8fk2`)
with NO row cap:

```python
from google.cloud import bigquery
c = bigquery.Client(project="supervision-production-8f1v")
result = c.query(SQL).result()          # returns ALL rows
cols  = [f.name for f in result.schema]
rows  = [[r.get(col) for col in cols] for r in result]   # Row.get(col), not attribute access
```

Normalize cells before handing to CSV/JSON consumers:
- `datetime.date` / `datetime.datetime` → `.isoformat()` (json.dump chokes on date objects)
- `bytes` → `.decode()`
- bool: keep native (`True`/`False`) for JSON, but write lowercase `"true"/"false"` for CSV —
  generators commonly do `r["flag"] == "true"`, and `str(True)` yields `"True"` which won't match.

## External Drive-backed tables: ADC fails, Metabase MCP works

Some views read Google Drive/Sheets EXTERNAL tables (e.g. `assessment.sensory-processing-measure`
→ `spm-age*`). Querying them via ADC raises `403 Permission denied while getting Drive credentials`
— the OAuth user has no Drive creds, but the Metabase service account does. For those tables
(usually small, ~1k rows), fall back to the Metabase MCP `execute_query` and page with a keyset
(`row_number() over (order by col)`) — the 200-row cap is tolerable at that size.

Note: a trailing space in a view name can be real (e.g. `` `sensory-processing-measure ` ``) — don't
strip it thinking it's a typo; confirm the exact name via `list_tables`.

## bq CLI does not honor ADC by default

Even when the ADC file exists, the `bq` CLI keeps preferring the (possibly expired) gcloud user
credential. Force ADC with `CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE=~/.config/gcloud/application_default_credentials.json`
(see `bq-cli-and-csv-reconciliation.md`), or — simpler for large pulls — use the Python client,
which honors the default ADC / `GOOGLE_APPLICATION_CREDENTIALS`.
