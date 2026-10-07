# Dashboard build pitfalls (v0.60.3) — additions beyond SKILL.md

Verified against the live API during a from-scratch dashboard build (collection 905).
These extend the SKILL.md "Pitfalls" list (which was at its size limit).

## Adding/arranging dashcards

- **`POST /api/dashboard/:id/cards` does NOT exist** — returns `"O endpoint da API não existe"`.
  The ONLY way to add/arrange dashcards is `PUT /api/dashboard/:id` with the full
  `dashcards` array. Always re-include `parameters` and `width` in that PUT, or they get
  wiped (see the "CRITICAL: PUT wipes parameters" note in SKILL.md). There is no
  "add one card" endpoint — every layout change is a full-dashcards PUT.

- **Every dashcard — regular AND virtual — needs a unique negative `id`.** A regular
  dashcard that has `card_id` but NO `id` is silently dropped: the PUT succeeds with no
  error, but a subsequent `GET /api/dashboard/:id` shows `dashcards: []`. Give text cards
  AND regular cards unique negative ids (`-1`, `-2`, ...). This extends the existing
  "unique negatives" pitfall — it is NOT only text cards that need it.

- **`visualization_settings` is REQUIRED on card create/update** (v0.60.3).
  `POST/PUT /api/card` without it returns 400
  `"missing required key, recebido: nil"` / `"O valor deve ser um mapa."`.
  Include `"visualization_settings": {}` in every card payload, even when empty.

## Transport: use curl, not Python urllib

Python 3.13 `urllib` fails SSL cert verify (`CERTIFICATE_VERIFY_FAILED`) against the
Metabase host, and forcing `ssl.CERT_NONE` then gets a 403 from the front proxy. `curl`
(system certs) just works. Use a small helper:

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

## Native-SQL template-tag filter on a computed column

A `[[AND col = {{tag}}]]` filter cannot reference a SELECT alias or a `CASE` expression at
the same query level (BigQuery aliases-not-visible-in-WHERE rule). When the filter targets
a normalized/derived column (e.g. `CASE WHEN pw.word='roupas' THEN 'roupa' ELSE pw.word END`),
compute that column inside a `base` CTE and put the optional clause in the outer SELECT:

```sql
WITH base AS (
  SELECT ..., CASE WHEN pw.word='roupas' THEN 'roupa' ELSE pw.word END AS vocabulo, ...
  FROM ... (joins)
  WHERE <static filters (tenant, status, dates)>
)
SELECT * FROM base
WHERE 1=1 [[AND vocabulo = {{vocabulo}}]]
ORDER BY ...
```

## Crossfilter click behavior on a table column

The `click_behavior` lives under the dashcard's
`visualization_settings.column_settings["[\"name\",\"<col>\"]"].click_behavior` (not at the
top level of visualization_settings). The `parameterMapping` keys match the dashboard
parameter's `id`:

```python
vs = {"column_settings": {
    '["name","vocabulo"]': {"click_behavior": {
        "type": "crossfilter",
        "parameterMapping": {"vocabulo": {
            "source": {"type": "column", "id": "vocabulo", "name": "vocabulo"},
            "target": {"type": "parameter", "id": "vocabulo"},
            "id": "vocabulo",
        }}}}}}
```

Native cards that receive the filter declare it via `parameter_mappings` on the dashcard:

```python
{"parameter_id": "vocabulo", "card_id": CARD_ID,
 "target": ["variable", ["template-tag", "vocabulo"]]}
```

Dashboard parameter (with a dropdown sourced from a card) is the same shape as the
existing "OG Fono"/"CG" params: `values_source_type: "card"`, `values_source_config.value_field = ["field", col, {"base-type": "type/Text"}]`.

## Table cell line breaks (text_wrapping — NOT wrap_text, NOT markdown)

To render `\n` (real newline) as line breaks inside a table cell, the correct
`column_settings` key is **`text_wrapping: true`**. Emit actual `\n` from SQL
(e.g. `STRING_AGG(..., '\n')`), then set:

```python
viz.setdefault('column_settings', {})['["name","<col>"]'] = {"text_wrapping": True}
```

- `wrap_text` is the WRONG key — it only wraps long text by column width and ignores `\n`.
- `markdown_template: "{{value}}"` (+ `<br>`) also does NOT break lines here.
- Verified against a working reference: dashboard 266, card 7234 (columns `session_dates`
  / `therapists`), where removing `text_wrapping` collapses the lines to one row.
- Works on both native SQL and MBQL cards, at card-level `column_settings`.
