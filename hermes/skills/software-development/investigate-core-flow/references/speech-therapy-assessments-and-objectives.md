# Speech therapy assessments ↔ PEI objectives data model

Domain map of how the 5 Fono (speech therapy) sub-assessments relate (or
don't) to PEI objectives, library objectives, and protocol items. Useful when
investigating a feature to link assessment results to intervention objectives.

## Model locations (all under `packs/clinical/app/models/`)

| Concept | Class | Table | File |
|---|---|---|---|
| Library Objective | `Intervention::Pei::Library::Objective` | `intervention_library_objectives` | `intervention/pei/library/objective.rb` |
| PEI Objective | `Intervention::Pei::Objective` | `intervention_objectives` | `intervention/pei/objective.rb` |
| PEI | `Intervention::Pei::Pei` | `intervention_peis` | `intervention/pei/pei.rb` |
| Protocol Item | `Intervention::Protocol::ProtocolItem` | `intervention_protocol_items` | `intervention/protocol/protocol_item.rb` |
| Protocol | `Intervention::Protocol::Protocol` | `intervention_protocols` | `intervention/protocol/protocol.rb` |
| Skill | `Intervention::Skill` | `intervention_skills` | `intervention/skill.rb` |

## Relationship: Library Objective ↔ PEI Objective (DUAL link)

The PEI Objective links to the Library Objective through **two parallel paths**,
both mediated by `protocol_item`:

**`Library::Objective`** (`library/objective.rb`):
- `belongs_to :protocol_item` — FK `protocol_item_id` → `intervention_protocol_items` (line 17)
- `belongs_to :skill` — FK `skill_id`, optional (line 18)
- `belongs_to :pei_module` — optional (line 44)

**`Pei::Objective`** (`objective.rb`):
- `belongs_to :library_objective` — FK `library_objective_id`, **optional** (line 11)
- `belongs_to :pei` — FK `intervention_pei_id` (line 12)
- `belongs_to :protocol_item` — **polymorphic**, FK `protocol_item_id`, optional (line 13)
- `belongs_to :intervention_protocol_items` — FK `protocol_item_id` direct to ProtocolItem, optional (line 14)
- `belongs_to :skill` — FK `intervention_skill_id`, optional (line 15)

`ProtocolItem` has back-references: `has_one :library_objective` (legacy) and
`has_many :library_objectives` (`protocol_item.rb:24-25`).

Key FKs confirmed in `db/migrate/20240222193718_create_intervention_library_objectives.rb`:
- `intervention_library_objectives`: `protocol_item_id` (null:false), `skill_id` (null:false)
- `intervention_objectives`: `library_objective_id` (null:true)

So an Objective may point at the Library Objective **and/or** directly at the
ProtocolItem. `protocol_item` is the common denominator.

### Verified in production (2026-09): objectives WITHOUT `library_objective_id` are real, not hypothetical

Read-only `rails runner` on the prod core pod (all tenants, non-discarded):

```
total (all tenants):           39,029
not discarded:                 38,366
library_objective_id NULL:        274
  → protocol_item_id present:     274   (100% of them)
  → both NULL:                      0
```

Protocol-item type split of those 274 (all in tenant `6f8da042-2dd1-4872-a613-84d371bde78c`):

```
protocol_item_type = Intervention::Protocol::ProtocolItem → 204  (matchable via library_objective.protocol_item_id)
protocol_item_type = Intervention::Protocol::Protocol   →  70  (points at the Protocol, NOT a ProtocolItem — NOT reachable via library_objective.protocol_item_id)
```

### Protocol breakdown of the 274 (2026-09 follow-up) — ALL non-Fono, so the fallback is NOT needed for Fono

The 274 objectives WITHOUT `library_objective_id` break down by protocol name:

```
protocol_item_type = ProtocolItem → Vineland 3: 204
protocol_item_type = Protocol   → VB-MAPP 57, Socially Savvy 8, ABLLS 3, Jasper 2
```

**None are Fono.** The Fono ("Fonoaudiologia") protocol has **4,051 objectives,
and every single one has `library_objective_id` populated** (0 with NULL). The
274 NULL rows are all legacy Vineland/VB-MAPP/ABLLS/Jasper/Socially Savvy from
2023–2024 (86 of them in 32 still-active cases, but all non-Fono regardless).

Consequence for the Fono de-para feature: match PEI Objective → Library
Objective by **`library_objective_id` only** — no `protocol_item_id` fallback.
The fallback is unnecessary for Fono (no Fono objective lacks
`library_objective_id`) and would be ambiguous anyway (a `protocol_item` is N:1
with `library_objectives`). The "dual link" is a real data-model shape, but it
is **irrelevant to Fono**; keep the fallback in mind only for Vineland/VB-MAPP-
style objectives if those are ever wired into a de-para.

> Lesson: when verifying a data-model assumption against prod, characterize the
> rows by **domain/protocol**, not just by count — "274 objectives without
> `library_objective_id`" reads as "the fallback is required", but the protocol
> breakdown (all non-Fono) inverts the decision. A bare existence count can be
> actively misleading.

## Join path: library_objective + clinical_case → Objectives

```
ClinicalCase (has_one :pei, app/models/clinical_case.rb:44)
  → Pei
    → has_many :objectives (pei.rb:9-12, foreign_key: intervention_pei_id, kept)
      → Objective.library_objective_id == library_objective.id
```

Existing scope (`objective.rb:38-40`):
```ruby
scope :by_clinical_case, ->(clinical_case_id) {
  joins(:pei).where(pei: {clinical_case_id: clinical_case_id})
}
```
Query: `pei.objectives.where(library_objective_id: library_objective.id)` — or
fall back to matching by `protocol_item_id` if `library_objective_id` is nil.

## Scoping

- **Tenant**: all these models inherit `ApplicationRecordTenant`
  (`app/models/application_record_tenant.rb` → `MultiTenantConcern`) → scoped by
  `tenant_id`.
- **clinical_case**: `Objective` has NO direct `clinical_case_id` — reached via
  `Pei` (`objective → pei → clinical_case_id`). `by_clinical_case` does that join.
- **PEI**: each Objective belongs to a non-null `intervention_pei_id`.
- **1:1 clinical_case → pei**: `ClinicalCase has_one :pei` (not `has_many`).
  Also `has_one :pei_track` (line 43).

## Link between the 5 Fono sub-assessments and objectives/protocol_items

**NONE exists today.** The 5 sub-assessment models (under
`packs/clinical/app/models/assessments/speech_therapy/`) reference only
`updated_by`, `registry` (→ `clinical_case`), and their own sub-items — no
`library_objective` / `objective` / `protocol_item` FK or enum:

- `phonological_assessment.rb`
- `expressive_communication_assessment.rb`
- `orofacial_myology_assessment.rb`
- `speech_motor_control_assessment.rb`
- `augmentative_and_alternative_communication_assessment.rb`

The **only** assessment ↔ objective/protocol_item cross-reference in the
codebase is **Vineland** (not Fono):
- `assessments/vineland/report/subdomain_item_score.rb:14,20-23` — `belongs_to :protocol_item` + `has_many :objectives` (via `vineland_report_subdomain_item_score_id`).
- `Pei::Objective` has `belongs_to :vineland_report_subdomain_item_score` (`objective.rb:29-31`).

So Vineland is the only flow that feeds objectives today. Wiring Fono
sub-assessments → objectives is a net-new link (likely via `protocol_item_id`
or a new FK/mapping).

The Fono assessments are all rooted in a single `Assessments::SpeechTherapy::Registry`
(`speech_therapy/registry.rb`) that `belongs_to :clinical_case` and owns all 5
sub-assessments via optional `belongs_to` (phonological_assessment_id,
expressive_communication_assessment_id, orofacial_myology_assessment_id,
speech_motor_control_assessment_id, aac_assessment_id).

## Relevant enums (all in `packs/clinical/app/models/assessments/enum/`)

- `phonological_atypical_process_names.rb` → `PhonologicalAtypicalProcessNames` (RS/HC/PF/EP/SP/EF/FV/SF/SL/PV/SFV/PP/FP/SEC/SCF/OTHERS + `MAX_OCCURRENCES`)
- `permitted_phonological_words.rb`
- `expressive_communication_feature_name.rb` → `ExpressiveCommunicationFeatureName` (request_attention, request_present_object, request_absent_object, request_action, ask_questions, protest, comment, narrative, labeling)
- `communication_skill_name.rb` → `CommunicationSkillName` (echolalia_profile, communicative_intent, communicative_repertoire)
- `speech_motor_control_answers.rb` → `SpeechMotorControlAnswers` (yes/no/partially/not_observed)
- `harmful_oral_habits.rb`, `clinical_referrals.rb` → orofacial
- `echolalia_type.rb`, `communicative_repertoire_type.rb` → expressive_communication sub-items
- `augmentative_and_alternative_communication_answers.rb` / `..._technology_profile.rb` / `..._software_name.rb` / `..._technological_expertise.rb` → AAC
- `delay_level.rb`, `performed_frequency.rb`, `assessment_status.rb`, `registry_status.rb`, `speech_therapy_assessment_types.rb`

Objective status enum lives elsewhere:
`packs/clinical/app/models/intervention/enum/objective_statuses.rb` →
`Intervention::Enum::ObjectiveStatuses` (completed/rejected/pending/in_maintenance/validated).
