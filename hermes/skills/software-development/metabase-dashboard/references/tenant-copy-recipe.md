# Tenant Copy Recipe (Genial → Mindplace) — worked example

Verified end-to-end copying the "PEIs Aderentes TO" dashboard + model + 7 cards from the
Genial subcollection to a new Mindplace subcollection. The only thing that changed was the
`database_id` (4 → 18). SQL/MBQL bodies stayed byte-identical (fully-qualified
`project.dataset.table` names unchanged; tenant scoping is done by the service account).

## 0. Recon (read-only)

1. `GET /api/database` → list all connections; find the `mindplace-*` sibling of the source
   connection. In GenialCare: Genial `supervision-production-big-query` (4) ↔
   `mindplace-supervision-production-big-query` (18).
2. `GET /api/database/:id` → confirm `project-id-from-credentials` (masked) matches the source
   project. `project-id` is often empty on mindplace connections — that's fine.
3. `GET /api/collection/773/items` → find the Genial subcollection (e.g. 774) and enumerate its
   cards/dashboards. `GET /api/collection/:id/items` for the card list.
4. `GET /api/card/:id` for every card + `GET /api/dashboard/:id` for the dashboard. Save to disk.

## 1. Verify-before-copy probe

```bash
curl -s -X POST -H "x-api-key: $MB_API_KEY" -H "Content-Type: application/json" \
  -d '{"database":18,"type":"native","native":{"query":"SELECT tenant_id, COUNT(*) c FROM `data-kernel-production-4o7n.datakernel.clinical_cases` GROUP BY tenant_id"},"parameters":[]}' \
  "$MB_URL/api/dataset"
```
Different tenant_id + small count vs. the source connection = swap confirmed.

## 2. Create the subcollection

```bash
curl -s -X POST -H "x-api-key: $MB_API_KEY" -H "Content-Type: application/json" \
  -d '{"name":"Tenant Careplus Mindplace","parent_id":773}' "$MB_URL/api/collection"
```

## 3. Create cards in dependency order (model first)

For each source card, build a `POST /api/card` payload with:
- `name` = `"Mindplace - " + src["name"]`
- `collection_id` = new subcollection id
- `database_id` = mindplace connection id (BOTH top-level and `dataset_query["database"]`)
- `visualization_settings`, `description` copied verbatim

Per-card-type specifics:

| src type | POST fields | re-pointing needed |
|---|---|---|
| `model` (native RAW) | `type:"model"`, `query_type:"native"`, **copy `result_metadata` verbatim** | none (no template-tags) |
| `question` MBQL (query_type=query) | `type:"question"`, `query_type:"query"` | `stages[].source-card` → new RAW id |
| `question` native, no card-ref | `type:"question"`, `query_type:"native"` | none |
| `question` native, `{{#RAW}}` card-ref | `type:"question"`, `query_type:"native"` | SQL `{{#OLD}}`→`{{#NEW}}`; template-tag key/`name`/`display-name` `#OLD`→`#NEW`; tag `card-id` → new RAW id |

Keep the template-tag internal `id` uuids as-is (they're per-card, no collision).

## 4. Create + fill the dashboard

1. `POST /api/dashboard` `{"name": "Mindplace - " + name, "collection_id": NEW}` → returns id.
2. `PUT /api/dashboard/:id` with `{"dashcards": [...], "parameters": src["parameters"], "width":"full"}`.
   For each source dashcard build a new object:
   - `id`: unique negative (-1, -2, ...)
   - `card_id`: `id_map[old_card_id]`, or `None` for text cards
   - `row`/`col`/`size_x`/`size_y`: copy
   - `visualization_settings`: deep-copy verbatim (includes `click_behavior`, text-card
     `virtual_card`+`text`, `card.title`, `viz.settings.card.title`)
   - `parameter_mappings`: deep-copy each, but **set `pm["card_id"] = id_map[pm["card_id"]]`**.
     The `target` body is card-id-independent — copy as-is.

## 5. Verify (dashboard endpoint, not card endpoint)

```bash
# model returns N distinct cases
curl -s -X POST -H "x-api-key: $MB_API_KEY" -d '{}' "$MB_URL/api/card/$NEW_MODEL_ID/query"
# derived MBQL card (need the real dashcard id from GET /api/dashboard/:id)
curl -s -X POST -H "x-api-key: $MB_API_KEY" -H "Content-Type: application/json" \
  -d '{"parameters":[]}' "$MB_URL/api/dashboard/$DASH_ID/dashcard/$DC_ID/card/$CARD_ID/query"
# gated native card: sentinel default → 0 rows
```

## Gotchas hit this run

- `tenants` table returns EMPTY via both genial and mindplace connections (no read grant) →
  `tenant_name` is NULL in the RAW on both sides. Pre-existing, identical, not a copy defect.
- The "Sugestões de Objetivos" native card existed in the collection but was NOT mounted on
  the dashboard (orphan, alongside a lone "Sugestões" heading). A faithful copy preserves that
  state — don't "fix" it by wiring it in unless the user asks.
- `execute_code` cannot reach `MB_API_KEY` exported in `terminal` (separate sandbox). Do the
  whole curl+parse chain inside `terminal()`, or drive curl via `subprocess` from a Python
  script run by `terminal`.
