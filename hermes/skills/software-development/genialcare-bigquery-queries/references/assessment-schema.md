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

## Occupational Therapy (OT) — direct assessment registries

Table: `supervision-production-8f1v.assessment.occupational_therapy_registries`

| column | type |
|--------|------|
| id | STRING |
| clinical_case_id | STRING |
| status | STRING |
| started_at | TIMESTAMP |
| completed_at | TIMESTAMP |
| tenant_id | STRING |
| created_at | TIMESTAMP |
| updated_at | TIMESTAMP |

### Sub-assessment tables (6 total, all linked via `registry_id` FK on the sub-table)

| Table | FK column |
|-------|-----------|
| `occupational_therapy_praxis_assessments` | `registry_id` |
| `occupational_therapy_proprioception_assessments` | `registry_id` |
| `occupational_therapy_pv_assessments` | `registry_id` |
| `occupational_therapy_tactile_assessments` | `registry_id` |
| `occupational_therapy_vestibular_assessments` | `registry_id` |
| `occupational_therapy_aal_assessments` | `registry_id` |

Each sub-assessment has a `status` column (STRING, values: `completed` / `started` / etc.).

### Join pattern (OT — FK on sub-table)

```sql
FROM occupational_therapy_registries otr
LEFT JOIN occupational_therapy_praxis_assessments praxis ON praxis.registry_id = otr.id
LEFT JOIN occupational_therapy_proprioception_assessments proprioception ON proprioception.registry_id = otr.id
-- ...repeat for all 6 sub-assessments
```

Completion percentage: count sub-assessments with `status = 'completed'`, divide by 6.

### assessment_sessions column

`assessment_sessions.assessment_occupational_therapy_registry_id` — links a session to its OT registry.

## Speech Therapy (Fono) — direct assessment registries

Table: `supervision-production-8f1v.assessment.speech_therapy_registries`

| column | type |
|--------|------|
| id | STRING |
| clinical_case_id | STRING |
| status | STRING |
| started_at | TIMESTAMP |
| completed_at | TIMESTAMP |
| phonological_assessment_id | STRING |
| expressive_communication_assessment_id | STRING |
| orofacial_myology_assessment_id | STRING |
| speech_motor_control_assessment_id | STRING |
| aac_assessment_id | STRING |
| tenant_id | STRING |
| created_at | TIMESTAMP |
| updated_at | TIMESTAMP |

### Sub-assessment tables (5 total)

**⚠️ FK pattern is INVERTED vs OT:** The registry holds the FK (`*_assessment_id`), not the sub-table. Join `sub_table.id = registry.<type>_assessment_id`.

| Table | Registry FK column | Has `status`? |
|-------|-------------------|---------------|
| `phonological_assessments` | `phonological_assessment_id` | Yes |
| `expressive_communication_assessments` | `expressive_communication_assessment_id` | Yes |
| `orofacial_myology_assessments` | `orofacial_myology_assessment_id` | Yes |
| `speech_motor_control_assessments` | `speech_motor_control_assessment_id` | Yes |
| `aac_clinical_decisions` / `aac_clinical_observations` | `aac_assessment_id` | **No** — use `CASE WHEN aac.id IS NOT NULL THEN 'completed' END` |

### Join pattern (Fono — FK on registry)

```sql
FROM speech_therapy_registries str
LEFT JOIN phonological_assessments phonological ON phonological.id = str.phonological_assessment_id
LEFT JOIN expressive_communication_assessments expressive ON expressive.id = str.expressive_communication_assessment_id
LEFT JOIN orofacial_myology_assessments orofacial ON orofacial.id = str.orofacial_myology_assessment_id
LEFT JOIN speech_motor_control_assessments motor ON motor.id = str.speech_motor_control_assessment_id
LEFT JOIN aac_clinical_decisions aac ON aac.aac_assessment_id = str.aac_assessment_id
```

Completion percentage: count sub-assessments with `status = 'completed'` (4 tables) + AAC existence check (1), divide by 5.

### assessment_sessions column

`assessment_sessions.assessment_speech_therapy_registry_id` — links a session to its Fono registry.

### Clinician roles

| Role | clinician_role value |
|------|---------------------|
| OG (specialty consultant) | `speech_specialty_consultant` (NOT `speech_therapy_specialty_consultant`) |
| Therapist | `speech_therapy_therapist` |
| Supervisor | `speech_therapy_supervisor` |
| Care coordinator | `speech_therapy_care_coordinator` |

### Reference queries

- `queries/assessment/assessment-ot-score.sql` — OT score query with devolutive status, Vineland, therapists
- `queries/assessment/assessment-speech-therapy-score.sql` — Fono equivalent

## Assessment Notes (feedback_assessment / devolutive annotations)

Table: `supervision-production-8f1v.assessment.assessment_notes`
Linked to sessions via `session_id`. One note per session (1:1).

| column | type |
|--------|------|
| id | STRING |
| created_by_id | STRING |
| updated_by_id | STRING |
| session_id | STRING |
| detail | RECORD |
| tenant_id | STRING |
| created_at | TIMESTAMP |
| updated_at | TIMESTAMP |

### detail sub-fields

| field | type | description |
|-------|------|-------------|
| type | STRING | Note type |
| protocol | STRING | Assessment protocol |
| observation | STRING | Free-text clinical observation |
| participants | STRING | Caregiver(s) who attended the devolutive session (free-text names) |
| health_checks | STRING (REPEATED) | Health checks performed |
| used_reinforcers | STRING | Reinforcers used during the session |
| challenging_behaviors | STRING | Challenging behaviors observed |
| key_development_milestones | STRING | Key developmental milestones discussed |
| expected_reassessment_date | DATE | Expected date for next reassessment |
| report_delivered | BOOLEAN | Whether the assessment report was delivered |

### Join pattern

```sql
LEFT JOIN `supervision-production-8f1v.assessment.assessment_notes` n
  ON n.session_id = s.id
```

Filter sessions with `s.session_type = 'feedback_assessment'` before joining.

### Reference queries

- `queries/session/feedbac-assessment-session-and-clinicians.sql` — devolutive sessions with clinicians + caregiver participants + observation
- `queries/session/feedback-assessment-sessions-note-and-clinicians.sql` — same with note creator and additional detail fields
