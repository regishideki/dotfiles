# Diagnosing + fixing a tenant leak in an existing native card

How to read an existing card's SQL, spot a silent multi-tenant leak, and fix it.
Grounded in the "PEIs Aderentes - TO" card 8137 (dashboard "Genial" 296) fix of 2026-09-22.

## Reading an existing card's native SQL

`curl -s -H "x-api-key: $KEY" https://<host>/api/card/<id>` — the native SQL is at
`dataset_query.stages[0].native` (stage has `lib/type: "mbql.stage/native"`). The card is
`type: "model"` when downstream cards consume it via `source-card`; `type: "question"`
otherwise. Dashboard shape: `/api/dashboard/<id>` → `parameters` (filter widgets) and
`dashcards[]` (`card_id`, `parameter_mappings`).

To diff two cards (e.g. the "Genial" vs "MindPlace" RAW models), extract both
`dataset_query.stages[0].native` strings and `diff` them.

## The silent multi-tenant leak (card 8137)

Symptom: a "Genial"-branded dashboard's numbers don't match a genialcare-scoped query/painel
and look inflated.

Root cause: the RAW native card had **no `tenant_id` filter anywhere**. Tells that the author
intended tenant scoping but never wired it: the card SELECTs a `tenant_name` column and has a
`tenant_names` CTE (`SELECT id, name FROM ...datakernel.tenants`), yet `active_ot_cases` and
`active_to_objectives` carry no `WHERE tenant_id = ...`. The Metabase connection itself is NOT tenant-scoped — the
"genialcare" BQ connections (db 3/4/11) see ALL tenants (no RLS/row-level restriction; the
service account lives in `meta-production-2a6b` with `dataset-filters-type: all`). Per-brand
isolation exists only as SEPARATE `mindplace-*` connections (db 14/17/18/19). So the
card returned **5 tenants** — genialcare + volarum + ser_especial + careplus_mindplace +
amanda_lemos_lopes — instead of just genialcare (932 cases vs 772).

### Correction to the "replicate across tenant copies" rule

The per-tenant dashboards (Genial 296 / MindPlace 300) do **not** reliably "differ only in DB
connection". Their RAW cards (8137 vs 8315) were **byte-identical** (diff = one trailing
newline) AND **both multi-tenant** — i.e. the tenant scoping was simply absent, not encoded in
a DB connection. Before assuming a tenant copy is tenant-scoped, diff the RAW cards and grep
their WHERE clauses for `tenant_id`. If it's absent from the case CTE, both dashboards leak.

## Diagnose with hard numbers before editing

Run the card's native SQL directly in BigQuery via ADC (`google-cloud-bigquery`) and
`GROUP BY tenant_name` over the case universe (strip the tenant filter if any, keep the
other active-case filters):

```sql
SELECT tn.name AS tenant_name, COUNT(*) AS casos
FROM `data-kernel-production-4o7n.datakernel.clinical_cases` cc
LEFT JOIN `data-kernel-production-4o7n.datakernel.tenants` tn ON tn.id = cc.tenant_id
WHERE cc.real_case IS TRUE AND cc.status='ongoing' AND cc.discarded_at IS NULL
  AND <other case filters, e.g. discipline OT active>
GROUP BY 1 ORDER BY 2 DESC
```

Seeing anything besides `genialcare` confirms the leak. Genialcare's tenant_id is
`6f8da042-2dd1-4872-a613-84d371bde78c` (also the value the in-repo Farol queries use).

## Fix

Add the filter to the case CTE (sufficient on its own — downstream joins are keyed on the
case id) AND the objective CTE (explicitness + matches the in-repo query), then PUT the card
back. Body is `{"dataset_query": <the same object with the modified native string>}`; the
transport is curl (see `dashboard-build-pitfalls.md` — Python urllib 403s).

```sql
-- active_ot_cases
    AND ch.on_hold IS NOT TRUE
    AND cc.tenant_id = '6f8da042-2dd1-4872-a613-84d371bde78c'
-- active_to_objectives
    AND p.name IN ('Ocupacional', 'Integração Sensorial')
    AND obj.tenant_id = '6f8da042-2dd1-4872-a613-84d371bde78c'
```

Requires a superuser key (`can_write: true`); a read-only key 403s on PUT. After the PUT,
verify with `POST /api/card/<id>/query` and confirm the returned rows carry only one
`tenant_name`.
