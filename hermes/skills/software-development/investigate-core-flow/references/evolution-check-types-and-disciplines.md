# Evolution Check: Types, Disciplines & Attribute Analysis

Investigated 2026-08-03. All paths relative to `projects/core/`.

## Overview

The Evolution Check feature has a **logical STI** (not ActiveRecord STI) with
three types, dispatched by `configuration_type` on the associated
`EvolutionCheckConfiguration`. The type determines which attributes are
required, which UI component renders, and which validation contract applies.

There is no `type` column on `intervention_objective_evolution_checks`. The
"type" is determined by:
1. The `configuration_id` FK (nullable) → links to an `EvolutionCheckConfiguration`
2. The `configuration_type` field on that configuration (`trial_counter` | `checklist`)
3. If `configuration_id` is null or `configuration_type` is absent → "without_configuration"

## The Three Types

### 1. trial_counter (Fonoaudiologia, Vineland 3 / ABA)

**Config fields:** `prerequisites[]`, `unit_of_measurement`, `max_measurements`, `instructions`
**Check fields:** `prerequisites[]`, `prompted_correct_responses_quantity`, `independent_correct_responses_quantity`, `evolution_scale`, `observations`

**Validation rules (Dry::Validation contract):**
- When `was_assessed=true`: `evolution_scale` required, `prerequisites` required (min 1)
- `prerequisites` items have `{name, checked}` shape

**Evolution scale calculation (frontend):**
```
evolution_scale = (independent_correct + 0.5 * prompted_correct) / max_measurements
```

**Disciplines:** Fonoaudiologia (protocol "Fonoaudiologia"), ABA (protocol "Vineland 3")
- Rake task: `import_speech_therapy_objectives.rake` sets `TRIAL_COUNTER`
- Rake task: `import_pei_modules_genial_objectives.rake` creates configs without explicit type (defaults to trial_counter in practice)

### 2. checklist (Terapia Ocupacional: Integração Sensorial, Ocupacional)

**Config fields:** `requisites[]`, `completion_threshold`, `max_measurements`
**Check fields:** `requisites[]`, `evolution_scale`, `observations`

**Validation rules:**
- When `was_assessed=false`: `observations` required
- When `was_assessed=true`: `evolution_scale` required, `requisites` required (min 1)
- Consistency: if all requisites unchecked and `evolution_scale > 0` → error
- Consistency: if any requisite checked and `evolution_scale == 0` → error

**Evolution scale calculation (frontend):**
```
evolution_scale = min(checked_requisites / completion_threshold, 1.0)
```

**Disciplines:** Terapia Ocupacional
- Rake task: `import_occupational_therapy_pei_objectives_v1.rake` sets `CHECKLIST`
- Rake task: `import_occupational_protocol.rake` sets `CHECKLIST`

### 3. without_configuration (ABA legacy, Symbolic Play, old objectives)

**No config associated** (`configuration_id` is null)
**Check fields:** `evolution_scale`, `pros`, `cons`

**Validation rules:**
- When `was_assessed=true`: `evolution_scale` required (range 0.0–1.0)
- `pros` required when `evolution_scale != 0.0`
- `cons` required when `evolution_scale != 1.0`
- No `prerequisites`, `requisites`, `prompted_*`, `independent_*`, or `observations`

**Disciplines:** ABA (legacy objectives without config), Symbolic Play, any objective where the library_objective has no `EvolutionCheckConfiguration`.

## Dispatch Logic (Core)

`CreateEvolutionCheck` (orchestrator) at
`packs/clinical/app/concepts/intervention/evolution/use_cases/create_evolution_check.rb`:

```ruby
def delegate_to_specific_use_case(evolution_check:, objective_params:)
  case objective_params[:configuration_type]
  when "checklist"
    CreateObjectiveEvolutionCheckByChecklist.call(...)
  when "trial_counter"
    CreateObjectiveEvolutionCheckByTrialCounter.call(...)
  else
    CreateObjectiveEvolutionCheckWithoutConfiguration.call(...)
  end
end
```

Each sub-use-case has its own `Dry::Validation::Contract` with type-specific
rules. The `build_*_params` methods in the orchestrator filter which fields
are passed to each sub-use-case:
- `build_checklist_params`: evolution_scale, requisites, observations
- `build_trial_counter_params`: evolution_scale, prerequisites, prompted/independent qty, observations
- `build_without_configuration_params`: evolution_scale, pros, cons

## Frontend Rendering Decision Tree

`components/Form/Form.tsx` decides which component to render per objective:

```
if (objective.libraryObjective?.evolutionCheckConfiguration) {
  → ObjectiveEvolutionCheckWithConfig
    → if configurationType === 'trial_counter': GeneralMeasurement
    → else: CheckListMeasurement
} else {
  → ObjectiveEvolutionCheck (pros/cons style, no config)
}
```

## Enum Definition

`packs/clinical/app/models/intervention/evolution/library/enum/evolution_check_configuration_types.rb`:
```ruby
TRIAL_COUNTER = "trial_counter"
CHECKLIST = "checklist"
```

## Weekly Check: Per-Clinician, Not Per-Case

The weekly evolution check verification is **per-clinician**, not per-case.
The endpoint `GET /users/evolution_checks/weekly.json` (controller
`Users::EvolutionChecksController#weekly`) filters by:

```ruby
clinician_id = authenticated_user.clinician.id
@evolution_checks = Intervention::Evolution::EvolutionCheck
  .by_session_scheduled_at(started_date, ended_date)
  .by_session_clinician(clinician_id)          # ← filters by logged-in clinician
  .by_session_clinical_case(clinical_case_ids)
```

This means: if Therapist A did an evolution check for a case this week,
Therapist B (who also sees the same case) still sees the "you haven't filled
this week" prompt and must do their own check. The weekly check is NOT
shared across therapists on the same case.

## Evolution Check Is Skippable

The evolution check is **not mandatory** at the moment of checkout. The
`useCheckinCheckoutFlowNavigation` hook marks `EVOLUTION_CHECK` as
`isSkippable: true`. The therapist can navigate away without filling it.
The enforcement (at least one check per case per week per clinician) is
external — tracked in Metabase dashboards, not enforced by the app.

## BQ Data: Configuration Distribution by Protocol (GenialCare tenant)

| Protocol | trial_counter configs | checklist configs |
|---|---|---|
| Fonoaudiologia | 40 | — |
| Vineland 3 (ABA) | 330 | — |
| Integração Sensorial (TO) | — | 26 |
| Ocupacional (TO) | — | 16 |

## BQ Data: Attribute Fill Rates by Type (production)

From `supervision-production-8f1v.intervention.objective_evolution_checks`:

| config_type | was_assessed | total | evolution_scale | prerequisites | requisites | prompted_qty | independent_qty | pros | cons | observations |
|---|---|---|---|---|---|---|---|---|---|---|
| trial_counter | true | 277,080 | 207,300 | 277,080 | 0 | 207,300 | 207,300 | 21 | 17 | 40,453 |
| trial_counter | false | 215,825 | 0 | 215,825 | 0 | 0 | 0 | 1 | 1 | 118,990 |
| checklist | true | 32,238 | 32,238 | 0 | 32,238 | 0 | 0 | 0 | 0 | 6,709 |
| checklist | false | 4,553 | 0 | 0 | 4,553 | 0 | 0 | 0 | 0 | 4,553 |
| without_config | true | 123,070 | 123,070 | 0 | 0 | 0 | 0 | 122,731 | 120,118 | 0 |
| without_config | false | 57,949 | 0 | 0 | 0 | 0 | 0 | 328 | 178 | 0 |

Key observations:
- `trial_counter`: always has prerequisites (even when not assessed); prompted/independent qty only when assessed
- `checklist`: always has requisites; observations required when not assessed
- `without_config`: pros/cons are the signature fields; observations never used
- The `without_config` type spans all protocols (old objectives without configuration)

## BQ Tables

- `supervision-production-8f1v.intervention.evolution_check_configurations` — library-level configs
- `supervision-production-8f1v.intervention.objective_evolution_checks` — per-objective check records
- `supervision-production-8f1v.intervention.evolution_checks` — per-session check records
- `supervision-production-8f1v.intervention.library_objectives` — join to protocol_items → protocols for discipline mapping
- GenialCare tenant_id: `6f8da042-2dd1-4872-a613-84d371bde78c`

## Useful BQ Queries

### Configuration type distribution by protocol
```sql
SELECT p.name AS protocol_name, ecc.configuration_type, COUNT(*) AS count
FROM `supervision-production-8f1v.intervention.evolution_check_configurations` ecc
INNER JOIN `supervision-production-8f1v.intervention.library_objectives` lobj ON ecc.library_objective_id = lobj.id
INNER JOIN `supervision-production-8f1v.intervention.protocol_items` pi ON pi.id = lobj.protocol_item_id AND pi.discarded_at IS NULL
INNER JOIN `supervision-production-8f1v.intervention.protocols` p ON p.id = pi.protocol_id AND p.tenant_id = "6f8da042-2dd1-4872-a613-84d371bde78c"
WHERE lobj.discarded_at IS NULL
GROUP BY protocol_name, configuration_type ORDER BY protocol_name, configuration_type
```

### Attribute fill rate by type (NULL analysis for required/optional inference)
```sql
SELECT
  IFNULL(ecc.configuration_type, "without_config") AS config_type,
  oec.was_assessed,
  COUNT(*) AS total,
  SUM(CASE WHEN oec.evolution_scale IS NOT NULL THEN 1 ELSE 0 END) AS evolution_scale,
  SUM(CASE WHEN oec.prerequisites IS NOT NULL AND ARRAY_LENGTH(oec.prerequisites) > 0 THEN 1 ELSE 0 END) AS prerequisites,
  SUM(CASE WHEN oec.requisites IS NOT NULL AND ARRAY_LENGTH(oec.requisites) > 0 THEN 1 ELSE 0 END) AS requisites,
  -- ... repeat for each attribute
FROM `supervision-production-8f1v.intervention.objective_evolution_checks` oec
LEFT JOIN `supervision-production-8f1v.intervention.evolution_check_configurations` ecc ON oec.configuration_id = ecc.id
GROUP BY config_type, oec.was_assessed ORDER BY config_type, oec.was_assessed
```
