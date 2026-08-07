# Assessment schema reference

Session-discovered schema details for the `assessment` dataset in
`supervision-production-8f1v`. Built incrementally as queries are written.

## COPM (Canadian Occupational Performance Measure)

Four tables in `supervision-production-8f1v.assessment`:

```
copm_forms (59 rows)
  ├── copm_form_summaries (59 rows)        — 1:1 with forms
  │     marked_points: JSON array of {name, ordering} — prioritized issues
  └── copm_form_domains (177 rows)         — 1:N with forms (3 domains per form)
        └── copm_form_issues (885 rows)    — 1:N with domains (5 issues avg per domain)
              performance_score:  INTEGER (1-5 scale)
              satisfaction_score: INTEGER (1-5 scale)
              observations:       STRING (free text)
```

### Schema details

**copm_forms**
| column | type |
|--------|------|
| id | STRING |
| agreement_id | STRING |
| submitted_by_id | STRING |
| tenant_id | STRING |
| created_at | TIMESTAMP |
| updated_at | TIMESTAMP |

**copm_form_summaries**
| column | type |
|--------|------|
| id | STRING |
| copm_form_id | STRING |
| tenant_id | STRING |
| marked_points | JSON |
| created_at | TIMESTAMP |
| updated_at | TIMESTAMP |

**copm_form_domains**
| column | type |
|--------|------|
| id | STRING |
| copm_form_id | STRING |
| tenant_id | STRING |
| area | STRING |
| name_alias | STRING |
| created_at | TIMESTAMP |
| updated_at | TIMESTAMP |

**copm_form_issues**
| column | type |
|--------|------|
| id | STRING |
| copm_form_domain_id | STRING |
| tenant_id | STRING |
| question | STRING |
| performance_score | INTEGER |
| satisfaction_score | INTEGER |
| observations | STRING |
| created_at | TIMESTAMP |
| updated_at | TIMESTAMP |

### Join chain

```
copm_forms cf
  LEFT JOIN copm_form_summaries cs ON cs.copm_form_id = cf.id
  LEFT JOIN copm_form_domains  cd  ON cd.copm_form_id  = cf.id
  LEFT JOIN copm_form_issues   ci  ON ci.copm_form_domain_id = cd.id
```

### Pitfall: `agreement_id` is a dead-end FK in BigQuery

`copm_forms.agreement_id` references the Rails `Agreement` model, which
**has no corresponding table in BigQuery**. There is no `agreements` table
in any GenialCare GCP project (data-kernel, supervision, ops-data, guidance).

The `agreement_id` UUID does NOT match:
- `clinical_cases.id`
- `clinical_case_disciplines.id`
- `form_registrations.id`
- Any other known table's primary key

To link COPM data to a clinical case, you must use an indirect path:
- Join via `tenant_id` + `submitted_by_id` → `users` to identify the therapist
- Use `created_at` time window to correlate with sessions or clinical case events
- Or join via `tenant_id` to `tenants` and cross-reference with ops-data `children`

### Domain areas

Observed `area` values in copm_form_domains:
- `productivity` — "Produtividade e/ou educacional"
- `leisure` — "Lazer e socialização"
- `self_care` — "Autocuidado" (inferred from COPM standard domains)

### marked_points JSON structure

Array of objects with `name` (the issue question text) and `ordering` (priority rank, 1-based):

```json
[
  {"name": "Interação social", "ordering": 1},
  {"name": "Comportamentos autorregulatórios", "ordering": 2},
  {"name": "Lazer na comunidade", "ordering": 3},
  {"name": "Transições entre atividades", "ordering": 4},
  {"name": "Atenção e foco", "ordering": 5}
]
```

This represents the top-5 prioritized issues selected by the family during the COPM interview.

### Reference query

See `queries/assessment/copm.sql` for a working query that joins the full
hierarchy with `users` (for submitted_by email/name).
