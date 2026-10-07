# Dashboard assembly gotchas (verified on Metabase v0.60.3)

Hard-won while building a greenfield dashboard (native-SQL cards + text/heading cards,
full-width, in a named collection) from scratch via the REST API. These complement the
numbered Pitfalls in SKILL.md.

## Adding/replacing dashcards

- **`POST /api/dashboard/:id/cards` does NOT exist** in v0.60.3 — returns
  `"O endpoint da API não existe"`. There is no "insert card" endpoint. The only way to add
  or change cards is `PUT /api/dashboard/:id` with `{"dashcards": [...], "parameters": [...],
  "width": "full"}`. The `dashcards` array REPLACES the entire layout, so always `GET` the
  dashboard first and re-include its current `parameters` (PUT wipes `parameters` otherwise —
  see SKILL.md).

- **Every NEW dashcard needs a unique negative `id` — not just text cards.** Regular
  (query) cards must ALSO carry a unique negative `id` (e.g. `-1..-12`) alongside their
  `card_id`. Omitting `id` on a regular card makes the PUT silently not apply it: no error,
  but a follow-up `GET /api/dashboard/:id` returns `dashcards: []` (or the card is just
  missing). Give ALL dashcards distinct negative ids. Text cards additionally need
  `card_id: None` + `visualization_settings.virtual_card` (see SKILL.md text-card section).

## Card creation

- **`POST /api/card` requires `visualization_settings`** — omitting it returns `400`:
  `{"specific-errors":{"visualization_settings":["missing required key, recebido: nil"]}}`.
  Pass `"visualization_settings": {}` at minimum on every card create (native and MBQL alike).

## Width

- **Dashboard `POST` ignores `width`.** A freshly created dashboard comes back
  `"width": "fixed"` even if you `POST` `{"width": "full"}`. Set it with a follow-up
  `PUT /api/dashboard/:id` (conveniently the same PUT that carries `dashcards` + `parameters`).

## Native SQL pitfalls (BigQuery-backed cards)

- **Correlated subqueries referencing ANOTHER table fail** with:
  `"Correlated subqueries that reference other tables are not supported unless they can be
  de-correlated, such as by transforming them into an efficient JOIN."` This fires when the
  outer query ALSO joins other tables (the decorrelator gives up). Fix: pre-aggregate the
  other table into a CTE (`... AS (SELECT fk, STRING_AGG(...) ... GROUP BY fk)`) and
  `LEFT JOIN` it on the FK, instead of a `(SELECT ... WHERE x.fk = outer.id)` scalar
  subquery. A bare correlated subquery CAN work when the outer query is simple, so the
  failure is easy to miss until the query gets complex.

- **`COUNT(DISTINCT NULL)` returns 0, not 1.** When a "signature" column (e.g. an
  aggregated set of processes) is legitimately empty for some rows, `COALESCE(sig, '')`
  it BEFORE `COUNT(DISTINCT ...)`. Otherwise an all-empty group counts as 0 distinct values
  and silently flips a `CASE WHEN COUNT(DISTINCT x) = 1 THEN 'Consistente' ELSE 'Divergente'`
  to the wrong branch (all-empty should be "consistent", but 0 != 1 evaluates as divergent).

## Cross-project joins work in native cards

A native card on `database_id = 4` (supervision-production-big-query) can freely reference
`data-kernel-production-4o7n.datakernel.*` and `ops-data-production-8fk2.*` tables with
fully-qualified `\`project.dataset.table\`` names — the Metabase service account has access
across projects. No special config needed.
