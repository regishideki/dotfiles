# Metabase v0.60.x REST API — pitfalls (verified 2026-09-18)

New gotchas hit while building a native-SQL dashboard in v0.60.3 via the REST API.
The main SKILL.md is at its size cap, so these live here.

## 1. `POST /api/card` requires `visualization_settings`

Omitting it returns `400`:

```json
{"specific-errors":{"visualization_settings":["missing required key, recebido: nil"]}}
```

Send at least `"visualization_settings": {}` even when you have no column settings.

## 2. There is NO `POST /api/dashboard/:id/cards` endpoint

Returns `"O endpoint da API não existe."` (endpoint does not exist). To add/replace
dashcards, `PUT /api/dashboard/:id` with the full body:

```json
{"dashcards": [...], "parameters": [...], "width": "full"}
```

- Re-include `parameters` even if unchanged (the PUT-wipes-`parameters` pitfall).
- `width` is only honored on PUT: `POST /api/dashboard` creates the dashboard with
  `width:"fixed"`, so set `width:"full"` in the same PUT that adds the cards.

## 3. Every dashcard needs a unique negative `id` — regular query cards too

A regular (non-virtual) dashcard with `card_id` set but NO `id` field makes the PUT
silently return an empty `dashcards` array (no error; a later GET shows 0 cards).
Give EACH dashcard — text AND query — a distinct negative id (`-1`, `-2`, …).

## 4. Python 3.13 urllib SSL → use curl subprocess

- `urllib.request.urlopen` raises `ssl.SSLCertVerificationError` (CERT_VERIFY_FAILED).
- Patching with `ssl.CERT_NONE` does NOT fix it — the fronting WAF rejects the handshake
  with HTTP `403 Forbidden`.

Reliable fix: shell out to `curl` via `subprocess.run(...)`. curl uses the system trust
store correctly and sails through the WAF:

```python
import subprocess, json
def api(method, path, payload=None):
    cmd = ["curl", "-s", "-X", method, "-H", f"x-api-key: {KEY}",
           "-H", "Content-Type: application/json"]
    if payload is not None:
        cmd += ["-d", json.dumps(payload)]
    cmd.append(BASE + path)
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    return json.loads(out) if out.strip() else {}
```

## 5. Table-card crossfilter lives under `column_settings`, not top-level

For a TABLE card, click-behavior goes at:

```python
"visualization_settings": {
    "column_settings": {
        '["name","<col>"]': {
            "click_behavior": {
                "type": "crossfilter",
                "parameterMapping": {
                    "<param_id>": {
                        "source": {"type": "column", "id": "<col>", "name": "<col>"},
                        "target": {"type": "parameter", "id": "<param_id>"},
                        "id": "<param_id>",
                    }
                }
            }
        }
    }
}
```

The `parameterMapping` keys are the parameter's `id` (not its slug). The top-level
`visualization_settings.click_behavior` shape is for non-table charts.

## 6. Parameter with a card-sourced dropdown

To make a filter show a dropdown of values from another card (rather than free text):

```json
{"name": "Vocábulo", "slug": "vocabulo", "id": "vocabulo",
 "type": "string/=", "sectionId": "string", "isMultiSelect": false,
 "values_source_type": "card",
 "values_source_config": {
   "card_id": 8549,
   "value_field": ["field", "vocabulo", {"base-type": "type/Text"}]
 }}
```

## Verification loop that works

- Run a card in isolation: `POST /api/card/:id/query` (returns status + error).
- Test a dashboard filter end-to-end: `POST /api/dashboard/:dash_id/dashcard/:dashcard_id/card/:card_id/query`
  with `{"parameters":[{"id":"<param_id>","value":"<val>","type":"string/="}]}` —
  confirm the result set is actually filtered, not just that no error is thrown.
