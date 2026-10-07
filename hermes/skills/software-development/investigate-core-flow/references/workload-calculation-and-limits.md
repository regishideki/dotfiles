# Workload (Carga Horária) Calculation & Limits — Full Architecture

Investigated 2026-09-28. Covers HOW `recommended_hours` is *calculated* (not just
validated), the plan dispatch, first-assessment-vs-reassessment split, the
SuggestedWorkload approval flow, and the three-layer limits. Complements (and
supersedes the Porto-only detail in)
`workload-limits-by-health-plan-and-delay-level.md` and the model/event detail in
`clinical-case-workload-investigation.md`.

## Two workload types (ClinicalCaseWorkload)

- `recommended_hours` — prescribed hours per discipline (ABA / Fono / TO).
- `shared_schedule_hours` — "Brincar Juntos" hours (ABA only), derived as a % of
  prescribed ABA hours by PEI current module. See `CalculateSharedScheduleHoursWorkload`.

Immutable resource: create/discard only, no update. New "version" = new row with
new `in_effect_since`.

## Calculation trigger

`vineland_report_created` (topic `assessment.vineland_report.v1`, subscription
`request-calculate-workload-sub` in `event_consumer_start.rb:302`) →
`ExecuteUseCaseJob` → `ClinicalCaseWorkloads::UseCases::CalculateWorkload`.

## Delay level (VinelandDelayLevelCalculation)

File: `packs/clinical/app/concepts/assessments/services/vineland_delay_level_calculation.rb`

- `first_assessment?` = `Assessments::Vineland::Report::Report.where(clinical_case_id:).kept.count == 1`
  (first = this is the case's ONLY kept Vineland report).
- `delay_level` = weighted average of `v_scale_score` across subdomains (weights:
  receptive/expressive/interpersonal/play 3, personal/coping/gross-motor 2, others 1).
- `delay_level_for(score)`: `<6` severe, `<9` moderate, `<11` intermediate, `<14` mild, else no_delay.
- The calculated `delay_level` is written back to `clinical_case.preferences.delay_level`.

## Plan dispatch (`CalculateWorkload#workload_class`)

| `InsuranceHealthPlan` predicate | Service | Names matched |
|---|---|---|
| `bradesco_group?` | `BradescoWorkload` | "Bradesco Saúde", "Bradesco Saúde - Operadora", "Mediservice" |
| `porto_seguro?` | `PortoWorkload` | "Porto Seguro Seguro Saúde" |
| else | `DefaultWorkload` | (everything else — incl. Amil today) |

`InsuranceHealthPlan` (per-case `has_one :health_plan`) is at
`packs/clinical/app/models/general/insurance_health_plan.rb`. Adding a new plan
(Amil, etc.) = add a predicate + a new `*Workload < BaseWorkload` service + a
`workload_class` branch.

## Suggested-hours tables (`define_workload(delay_level)` → `{ABA, Fono, TO}`)

**DefaultWorkload:**
SEVERE 11/2/2, MODERATE 7/2/2, INTERMEDIATE 5/2/2, MILD 4/1/1, NO_DELAY 3/1/1.

**PortoWorkload** has TWO tables:
- `SUGGESTED_WORKLOADS` (the auto-suggested value): SEVERE 11/2/2, MODERATE 7/2/2,
  INTERMEDIATE 5/2/2, MILD 3/1/1, NO_DELAY 3/1/1.
- `LIMITS` (min/max ranges that drive the dropdown):
  SEVERE ABA 9-12 / Fono 2-2 / TO 2-2; MODERATE ABA 7-9; INTERMEDIATE ABA 0-5 Fono 0-2 TO 0-2;
  MILD ABA 0-3 Fono 0-1 TO 0-1; NO_DELAY ABA 0-3 Fono 0-1 TO 0-1.

**BradescoWorkload** (`define_workload`): SEVERE 5/3/2, MODERATE 5/2/2,
INTERMEDIATE 4/2/2, MILD 3/2/2, NO_DELAY 3/1/1 — PLUS a "hardlock": if flag
`enable_hardlock_bradesco_workload` AND `aba_workload >= weekday_availability.count`
(>0), reduce via `workload_by_weekday_availability` (5→5h, 4→4h, 3→3h, 2→2h, 1→1h ABA).

## First assessment vs reassessment (the key branch in CalculateWorkload)

- `by_pass_reassessment`: proceeds only if `first_assessment?` OR flag
  `enable_create_suggested_workload` (keyed by `vineland_report_id`); otherwise
  `pass_fast!` = **nothing happens**.
- `calculate_hours`: if `NO_DELAY && first_assessment?` force **MILD** hours
  ("garantir intervenção mínima na primeira avaliação").
- `apply_minimum_workload_rule`: `min(matrix_hours, current_hours)` when a current
  recommended workload exists → **reassessment can only REDUCE, never increase**.
- **First assessment** → `create_workload` directly (auto-applied recommended_hours).
- **Reassessment** → `create_suggested_workload` (pending human approval), reason
  includes "…carga horária recomendada a partir dos dados de reavaliação".

## SuggestedWorkload approval flow

Model `Assessments::SuggestedWorkload`: status `pending/approved/reproved`,
`limit_date_to_approve` = 1 month. Flow (BFF `src/schema/assessments/suggested_workload/`,
frontend `src/pages/CoverPage/Workloads/`):
- `approveSuggestedWorkload` → `ApproveSuggestedWorkload` → `CreateWorkload`
  (recommended_hours, carries `suggested_workload_id`).
- `reproveSuggestedWorkload` → `ReproveSuggestedWorkload` → rejects, and MAY create a
  workload with different hours via `workload_input`.
- Expiry → `ResolveSuggestedWorkloads` + `ResolveSuggestedWorkloadJob`.

## Limits — three layers

1. **Model cap (global, always)**: `hours` 0–50h; `CompletedHourValidator`;
   `shared_schedule_hours_cannot_be_gt_recommended_hours`.
2. **`WorkloadLimits`** (`services/workload_limits.rb`) — dropdown/validation limits:
   - non-Porto → `default_limits` ABA 0-12 / Fono 0-3 / TO 0-3.
   - Porto + `clinical_case_reference` role → `default_limits` (loose).
   - Porto + normal clinician → strict `PortoWorkload.limits` by delay_level.
   - Porto + nil delay_level → `default_limits`.
   - **Reference-role semantics**: `clinical_case_reference?` =
     `clinical_case_clinicians.find_by(clinician: user.clinician, clinician_role: CLINICAL_CASE_REFERENCE).present?`
     — per-user, per-case. **OWNER does NOT bypass; only REFERENCE does.**
     `default_limits` is still a ceiling (0-12), NOT "any value".
3. **`CreateWorkload#validate_limits` escape**: a value outside limits is allowed
   if it equals the CURRENT active recommended workload — the fix for the
   "can't maintain existing 4h when editing" bug.

## Third definition path — "default workload" applied on contract (NOT Vineland)

Besides the Vineland calc and the SuggestedWorkload approval, a **third** path
creates `recommended_hours`: when a contract is created/updated with
`default_workload_applied: true`, `CreateOrUpdateFamily`
(`packs/operational/app/concepts/people/use_cases/create_or_update_family.rb`,
step `create_default_workload_if_new_contract`) → `General::UseCases::CreateDefaultWorkload`
creates workloads with `default_value: true`, `in_effect_since = contract.start_date`,
and a fixed `DEFAULT_WORKLOAD_CHANGE_REASON`. The matrix comes from
`Agenda::Services::ChildWorkload#get_default_workload` by **pricing model**:
- `fee_per_day` → ABA 3 / Fono 2 / TO 2 (`FEE_PER_DAY_DEFAULT_WORKLOAD_HOURS`)
- else → ABA 5 / Fono 2 / TO 2 (`DEFAULT_WORKLOAD_HOURS`)

`default_value` marks these rows; `ClinicalCaseWorkload.default_recommended_hours?`
recognizes the canonical default (ABA 7h / Fono 2h / TO 2h) for comparison.

## Downstream events of `workload_created`

Every `CreateWorkload` emits `clinical_case.workload.v1` / `workload_created`
(`WorkloadCreated`, `resource_id = workload_id`). Three consumers
(`event_consumer_start.rb:789+`):
1. `core-workload-created-changed-schedule-offer-sub` → `ScheduleOffersProcessingByEvent`
   (reprocesses marketplace offers; `workload_deleted` mirrors it).
2. `core-process-shared-schedule-workload-created-sub` → `CalculateSharedScheduleHoursWorkload`
   (recomputes Brincar Juntos when ABA recommended hours change).
3. `core-workload-created-customer-io-sub` → `CustomerIo::UseCases::ConsumeWorkloadCreated`
   → event `clinical_case_workload_changed` to each caregiver. **Idempotency key is
   `workload_id`, not the total** — a retry re-sends the same id (deduped), but a
   workload "return" (X → Y → X) gets a new id and must notify.

## Reprove permission is plan-conditional

`ClinicalCasePolicy#reprove_suggested_workload?` (`packs/clinical/app/policies/clinical_case_policy.rb`):
- `health_plan.bradesco_group?` → only `clinical_case_reference` or `full_privileges`
  (owner CANNOT reprove).
- else → `clinical_case_owner_and_escalation_roles` (owner OR reference OR full_privileges).

`approve` always uses `clinical_case_owner_and_escalation_roles`. `only_internal` =
`internal_test?` OR `full_privileges?` OR user's clinician linked to the case.

## Domain terminology gotcha

`OG_ROLES = [CLINICAL_CASE_OWNER, CLINICAL_CASE_REFERENCE]` (see
`family_support/use_cases/remove_user_from_conversation.rb`) — "OG" = owner+reference
role group, NOT a plan category. In limit logic only `CLINICAL_CASE_REFERENCE` matters.

## Files (core)

- `packs/clinical/app/models/clinical_case_workload.rb`
- `packs/clinical/app/concepts/clinical_case_workloads/use_cases/calculate_workload.rb`
- `.../services/vineland_delay_level_calculation.rb` (in `assessments/services/`)
- `.../services/{workload_limits,base_workload,porto_workload,bradesco_workload,default_workload}.rb`
- `.../use_cases/{create_workload,calculate_shared_schedule_hours_workload}.rb`
- `packs/clinical/app/concepts/assessments/use_cases/{create,approve,reprove}_suggested_workload.rb`
- `packs/clinical/app/concepts/clinical_cases/use_cases/resolve_suggested_workloads.rb`
- `packs/clinical/app/models/general/insurance_health_plan.rb`
