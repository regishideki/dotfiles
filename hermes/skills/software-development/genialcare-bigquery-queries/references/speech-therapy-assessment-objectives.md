# Fono assessment + PEI objectives (de-para) — data model & query recipe

How to pull, for a clinical case, the latest Fono (speech therapy) assessment and the case's PEI
objectives, then map them together via the de-para (assessment item → library objective).

## Tables (production, `supervision-production-8f1v` unless noted)

Assessment — registry + 5 sub-assessments + child tables:
- `assessment.speech_therapy_registries` — registry; holds the 5 sub-assessment IDs + status +
  `completion_percentage`.
- Sub-assessments: `phonological_assessments`, `expressive_communication_assessments`,
  `orofacial_myology_assessments`, `speech_motor_control_assessments`,
  `augmentative_and_alternative_communication_assessments`.
- Child tables: `motor_vocalizations(_assessments)`, `spontaneous_speeches(_assessments)`,
  `phonological_words(_assessments)`, `expressive_communication_features`, `communication_skills`,
  `physical_conditions`, `orofacial_functions`, `general_speech_motor_controls`,
  `segmental_features`, `suprasegmental_features`, `syllabic_complexities`,
  `aac_clinical_decisions`, `aac_clinical_observations`.

PEI objectives — chain:
`intervention.peis` (`clinical_case_id`) → `intervention.objectives` (`pei_id`,
`library_objective_id`, `status`, `discarded_at`) → `intervention.library_objectives`
(`description`, `protocol_item_id`) → `intervention.protocol_items` → `intervention.protocols`
(`name`).

Cases: `data-kernel-production-4o7n.datakernel.clinical_cases`.

## Key facts

- **"Fonoaudiologia" protocol = Fono objectives.** A case's PEI objectives span several protocols
  (`Vineland 3`, `Ocupacional`, `Integração Sensorial`, `Symbolic Play`, `Fonoaudiologia`). The
  de-para (assessment item → objective) only maps to **"Fonoaudiologia"** protocol objectives. To
  match a case's PEI against the de-para, filter `protocols.name = 'Fonoaudiologia'` — or just
  match by `description` against the de-para set.
- **Assessment and PEI objectives are independent.** A case can have a completed Fono assessment
  yet zero Fono objectives in its PEI (and vice-versa). When picking test cases, prefer cases that
  ALSO have Fono objectives, or the objective-status view comes back empty.
- **`objectives.objective_id` is the PK** (not `id`); other tables reference it via
  `intervention_objective_id`. Filter `obj.discarded_at IS NULL` to drop discarded objectives.

## Objective statuses → pt-BR (clinical-panel)

`intervention.objectives.status` values and their labels (source:
`clinical-panel/src/pages/PEI/Home/components/ObjectiveStatusFilter.tsx`):

| status | label | color (PEITrack StatusIndicator) |
|---|---|---|
| `completed` | Concluído | green |
| `in_maintenance` | Em manutenção | blue |
| `validated` | Validado | blue/cyan |
| `pending` | Pendente | red |
| `rejected` | Rejeitado | orange |

## Matching recipe (de-para ↔ case PEI)

1. Load the de-para CSV — columns `objective`, `assessment_type`, `item_identifier`,
   `feature_name`; ~106 distinct objectives, 43 items across 5 `assessment_type`s
   (`speech_motor_control`, `phonological`, `orofacial_myology`,
   `augmentative_and_alternative_communication`, `expressive_communication`).
2. Query the case's objectives (join peis → objectives → library_objectives → protocols).
3. Match by exact `objective_description` equality against the de-para `objective` set. Wording is
   identical when the objective is the same; verb-conjugation variants ("Falar" vs "Fala") are
   DIFFERENT objectives — don't fuzzy-match.
4. Matched objective → use the case's `status`; unmatched de-para objective → "not in this case's
   PEI" (display neutral, e.g. "Não iniciado").

## Query starters (code-snippets repo)

- Last completed assessment per case:
  `queries/assessment/speech_therapy/speech-therapy-last-assessment.sql` — one row/case; child
  rows (words, vocalizations, features) aggregated with `STRING_AGG`; uses
  `QUALIFY ROW_NUMBER() ... ORDER BY started_at DESC` to pick the latest.
- Active fono cases filter: `queries/utils/active-fono-cases.sql`.
- To scope to specific cases, append `WHERE cc.number IN (...)` before the final `ORDER BY`.
