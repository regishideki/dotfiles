# Metabase v0.60.3 gotchas (verified 2026-09-18, dash "Processos Fonológicos" 305)

Hard-won specifics from building a dashboard programmatically against
`analytics-panel.genialcare.com.br` (v0.60.3). The main SKILL.md is at its size limit,
so these live here.

## 1. `visualization_settings` is REQUIRED in `POST /api/card`

Omitting it returns 400:

```json
{"errors": {"visualization_settings": "O valor deve ser um mapa."}}
```

Always include `"visualization_settings": {}` in the card payload (even for native SQL
cards). The older example payloads in the main SKILL.md predate this requirement.

## 2. There is NO `POST /api/dashboard/:id/cards` endpoint

It returns `"O endpoint da API não existe."`. To add/replace dashcards, use
`PUT /api/dashboard/:id` with a full payload:

```json
{"dashcards": [...], "parameters": [...], "width": "full"}
```

Remember the PUT-wipes-`parameters` pitfall: always re-include the dashboard's current
`parameters` array (GET it first) or the filters vanish.

**Every dashcard in the array — regular AND text cards — needs a unique negative `id`**
(e.g. -1, -2, -3). Regular cards still carry their real `card_id`; text/virtual cards use
`card_id: null` + `visualization_settings.virtual_card`. This extends pitfall #6 in the main
SKILL.md: it is not just text cards — omitting `id` on a regular dashcard silently drops it
(the PUT reports success, a follow-up GET shows 0 dashcards).

Minimal working dashcard shapes:

```python
def qcard(i, card_id, row, col, sx, sy, pm=None, vs=None):
    return {"id": i, "card_id": card_id, "row": row, "col": col,
            "size_x": sx, "size_y": sy,
            "parameter_mappings": pm or [], "visualization_settings": vs or {}}

def text_card(i, row, col, sx, sy, text, display="text"):
    vc = {"name": None, "display": display, "visualization_settings": {}, "archived": False}
    return {"id": i, "card_id": None, "row": row, "col": col,
            "size_x": sx, "size_y": sy, "parameter_mappings": [],
            "visualization_settings": {"text": text, "virtual_card": vc}}
```

## 3. Cross-project BigQuery joins work in native SQL cards

A native card on `database 4` (`supervision-production-8f1v`) can reference
`data-kernel-production-4o7n.datakernel.*` and `ops-data-production-8fk2.*` with
fully-qualified names — the Metabase service account has access to all projects. No need to
pre-materialize or split the query across databases. (The PEI dashboard card 7228 already
does this; `speech-therapy-phonological-imitation.sql` joins supervision + data-kernel.)

## 4. Dataset_query format on this instance

Cards are stored with the MLv2 "lib" format (`"lib/type": "mbql/query"` with a native
`mbql.stage/native` stage), but POST/PUT still accepts the classic
`{"type": "native", "native": {"query": "...", "template-tags": {...}}, "database": id}`
form and normalizes it. Use the classic form — simpler and works.
