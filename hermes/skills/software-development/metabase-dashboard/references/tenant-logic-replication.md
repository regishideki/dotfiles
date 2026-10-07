# Replicating a logic change across tenant dashboards

## Context

The PEI Aderente TO dashboard exists as per-tenant copies sharing identical
logic but different BigQuery connections:

| Tenant    | Dashboard | RAW model | DB id | Collection |
|-----------|-----------|-----------|-------|------------|
| Genial    | 296       | 8137      | 4     | 773        |
| MindPlace | 300       | 8315      | 18    | 782        |

The only model difference is the connection: Genial reads
`ops-data-production-8fk2.aggregates.children`, MindPlace reads
`data-kernel-production-4o7n.datakernel.*`. The `intervention.*` tables
(`supervision-production-8f1v`) are shared.

## The single-point rule (`is_pair_adherent`)

Adherence logic lives in ONE CASE expression in the RAW model. It drives BOTH
the case-level `aderencia_status` AND the per-objective flag used by the
"Objetivos TO" card (which does `max(is_pair_adherent)`). Edit once, both
propagate. Note: the `case_adherence` CTE also keys "Sem PEI" off
`MAX(has_mapper_pair) = FALSE`, and the new override rules can legitimately
flip a formerly "Sem PEI" case to "Aderente" (e.g. an all-Ocupacional case with
no mapper pairs).

The CASE after adding protocol/status override rules:

```sql
CASE
    WHEN ato.objective_id IS NULL THEN NULL
    WHEN ato.protocol_name = 'Ocupacional' THEN TRUE
    WHEN ato.protocol_name = 'Integração Sensorial' AND ato.objective_status = 'in_maintenance' THEN TRUE
    WHEN mapper.main_objective_id IS NULL THEN FALSE
    ELSE COALESCE(pti.module_progress_item_status IN ('validated', 'in_maintenance'), FALSE)
END AS is_pair_adherent
```

Override rules are inserted as extra `WHEN` clauses BEFORE the mapper fallback.

## Replication workflow

1. Change Genial first and verify end-to-end.
2. GET the other tenant's model; confirm the "before" CASE block is byte-identical.
3. Apply the SAME string replacement. PUT `{"dataset_query": dq}` back (partial
   merge — only `dataset_query` is needed; the REST API merges, it does not wipe).
4. Invalidate that tenant's derived cards (see cache pitfall in SKILL.md).
5. Verify via `/api/dataset` (below).

Derived cards on dash 300 (MindPlace): 8316 Resumo, 8317 Por OG TO, 8318 Por CG,
8319 Objetivos TO, 8320 Objetivos da Jornada, 8322 Distribuição de Aderência.

## Verification query

```python
q = ("SELECT to_protocol_name, to_objective_status, is_pair_adherent, COUNT(*) AS n_rows "
     "FROM {{#8315}} WHERE to_objective_id IS NOT NULL "
     "GROUP BY to_protocol_name, to_objective_status, is_pair_adherent ORDER BY 1,2,3")
payload = {
    'database': 18,   # tenant db id: 18 = MindPlace, 4 = Genial
    'type': 'native',
    'native': {'query': q, 'template-tags': {
        '#8315': {'type': 'card', 'card-id': 8315, 'name': '#8315', 'display-name': '#8315'}
    }},
    'parameters': [],
}
# POST /api/dataset
```

`database` MUST be the target tenant's db id, and `card-id` its RAW model id.
A rule with zero matching rows (e.g. no `in_maintenance` IS objectives yet)
simply won't appear in the GROUP BY output — that's expected, not a failure.
