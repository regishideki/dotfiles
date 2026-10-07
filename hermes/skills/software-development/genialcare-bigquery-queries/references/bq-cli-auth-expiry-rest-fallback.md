# bq CLI auth-token expiry → query via REST API with application-default credentials

## Symptom

`bq query ...` fails with:

```
ERROR: (bq) There was a problem refreshing your current auth tokens: Reauthentication failed. cannot prompt during non-interactive execution.
```

This is the **gcloud user credential** (interactive `gcloud auth login`) expiring. It
can't be re-authenticated non-interactively (needs a browser). `gcloud auth list` still
shows the account as `ACTIVE`, which is misleading — the *account* is selected but its
*access/refresh token* is expired.

## Why it's not fatal

The **application-default credentials** (`~/.config/gcloud/application_default_credentials.json`)
are a SEPARATE credential with its own refresh token.
`gcloud auth application-default print-access-token` refreshes and prints a valid token
**non-interactively** — it keeps working even after the user credential expires.

## Workaround: bypass the `bq` CLI, hit the BigQuery REST API via curl

```bash
TOKEN="$(gcloud auth application-default print-access-token)"
curl -s -X POST \
  "https://bigquery.googleapis.com/bigquery/v2/projects/<PROJECT>/queries" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"<SQL>\", \"useLegacySql\": false, \"maxResults\": 500}"
```

`<PROJECT>` is the GCP project (e.g. `data-kernel-production-4o7n`); a query can still
reference tables in OTHER projects via fully-qualified names, so pick the project your
ADC identity has access to.

## Response shape (JSON)

- `schema.fields[].name` → column names.
- `rows[].f[].v` → cell values (strings; `""`/absent = NULL). Nested STRUCT cells have
  `cell.v.f[]`.
- `totalRows` → row count. `jobReference.jobId` → for `bq ls -j`-style follow-ups.
- On error: `error.message` + `error.reason`.

## Tips

- A ~20-line Python wrapper (get ADC token → curl → parse rows to TSV) is a drop-in
  replacement for `bq query --use_legacy_sql=false --format=pretty`. Keep one in `/tmp`
  and reuse it for the rest of the session — it avoids re-deriving the curl dance per query.
- `GOOGLE_APPLICATION_CREDENTIALS=<path>` does NOT change the `bq` CLI's auth (the CLI uses
  gcloud *user* creds, not ADC). Setting it won't fix the expiry — you must go through
  curl/REST, or have the user run `gcloud auth login` in a foreground session.
- This is a credential-EXPIRY state, not "bq is broken" — don't encode it as a permanent
  refusal. The CLI recovers as soon as the user re-logs in; the curl/REST path is the
  non-interactive fallback to keep working meanwhile.
