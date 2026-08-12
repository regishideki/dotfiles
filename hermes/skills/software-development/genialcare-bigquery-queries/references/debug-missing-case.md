# Debugging missing cases from complex CTE queries

When a case should appear in a query but doesn't (or appears with wrong status/value), run a parallel diagnostic battery to isolate which gate excludes it.

## Pattern

Instead of staring at the SQL, run N independent lightweight queries — one per filter/join gate — against the specific case number. Run all in parallel via `python3 << 'PYEOF'` (see main skill for ADC auth pattern).

## Template (OT assessment example)

```python
from google.cloud import bigquery
import json

client = bigquery.Client(project='supervision-production-8f1v')

queries = {
    "1_caso_status": """
        SELECT cc.id, cc.number, cc.status, cc.real_case, cc.discarded_at,
               ch.churned_at, ch.on_hold
        FROM `data-kernel-production-4o7n.datakernel.clinical_cases` cc
        LEFT JOIN `ops-data-production-8fk2.aggregates.children` ch ON ch.id = cc.id
        WHERE cc.number = <N>
    """,
    "2_disciplinas": """
        SELECT ccd.clinical_case_id, ccd.discipline, ccd.status
        FROM `data-kernel-production-4o7n.datakernel.clinical_case_disciplines` ccd
        JOIN `data-kernel-production-4o7n.datakernel.clinical_cases` cc ON cc.id = ccd.clinical_case_id
        WHERE cc.number = <N>
    """,
    "3_registries": """
        SELECT otr.id, otr.clinical_case_id, otr.status, otr.started_at, otr.completed_at
        FROM `supervision-production-8f1v`.assessment.occupational_therapy_registries otr
        JOIN `data-kernel-production-4o7n.datakernel.clinical_cases` cc ON cc.id = otr.clinical_case_id
        WHERE cc.number = <N>
        ORDER BY otr.started_at DESC
    """,
    "4_devolutivas": """
        SELECT fs.session_id, fs.session_type, fs.discipline, fs.session_status,
               DATE(fs.started_scheduled_at, 'America/Sao_Paulo') AS data,
               fs.clinical_case_id
        FROM `ops-data-production-8fk2.scheduling.fct_sessions` fs
        JOIN `data-kernel-production-4o7n.datakernel.clinical_cases` cc ON cc.id = fs.clinical_case_id
        WHERE cc.number = <N>
          AND fs.discipline = 'occupational_therapy'
          AND fs.session_type = 'feedback_assessment'
        ORDER BY data DESC
    """,
}

for name, sql in queries.items():
    print(f"\n=== {name} ===")
    rows = list(client.query(sql).result())
    if not rows:
        print("(sem resultados)")
    for row in rows:
        d = dict(row)
        for k, v in d.items():
            if hasattr(v, 'isoformat'):
                d[k] = v.isoformat()
        print(json.dumps(d, ensure_ascii=False, indent=2))
```

## Generalizing

For any complex query, decompose it into one diagnostic query per gate:
1. **Row existence + base filters** — does the row pass the WHERE clause of the first CTE?
2. **JOIN keys** — does each required FK have a matching row in the joined table?
3. **Aggregates / QUALIFY / window functions** — which row does the window pick? Does it match expectations?
4. **Final conditional columns** — for computed status columns, run the subquery in isolation to see why it fails.

## Real-world examples

### Case 1441 — devolutive shows "Pendente" despite existing

- Case had 2 registries: `acbef9ce` (started 2026-07-03) and `978e8693` (started 2026-07-31)
- Devolutive was 2026-07-08, belonging to the first registry
- `QUALIFY ROW_NUMBER() ... ORDER BY started_at DESC` picked the second registry (2026-07-31)
- Condition `devolutive_date >= registry_started_at` → `2026-07-08 >= 2026-07-31` → FALSE
- Root cause: window function picked wrong registry for the comparison

### Case 1266 — case completely missing from query

- No rows in `occupational_therapy_registries` — `INNER JOIN` excluded the case entirely
- Devolutive existed but was `speech_therapy`, not `occupational_therapy` — discipline filter mismatch
- Two independent problems: (1) no registry at all, (2) wrong discipline on the devolutive session
