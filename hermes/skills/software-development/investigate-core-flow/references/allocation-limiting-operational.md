# "Limiting" is overloaded — `People::AllocationLimiting` vs `WorkloadLimits`

Two unrelated mechanisms in the core share the word "limiting". When a user asks
about "limiting" (limitar carga horária), disambiguate FIRST — they are different
packs, different models, different triggers, different consumers.

| | `WorkloadLimits` | `People::AllocationLimiting` |
|---|---|---|
| Pack | `clinical` | `operational` |
| Purpose | per-discipline min/max that drives the **dropdown** in clinical-panel and the `CreateWorkload#validate_limits` backend check | per-child operational ceiling: does the prescribed workload fit the family's clinical preference and availability? |
| Inputs | `health_plan`, `preferences.delay_level`, user role (`clinical_case_reference`) | `weekly_workload` vs `max_workload_per_day * 5` vs child `availability_time_slots` |
| Output | `{aba: {min,max}, speech_therapy: {min,max}, occupational_therapy: {min,max}}` | `limitings` array of `{rule, value}` (which ceiling was hit) |
| Trigger | on-demand (GET `workload_limits.json`) | recurring job, daily 1AM |
| Consumer | clinical-panel `WorkloadsForm.tsx` dropdown | admin (`ChildDecorator#allocation_limitings_info`) — NOT the panel |

See `workload-calculation-and-limits.md` and
`workload-limits-by-health-plan-and-delay-level.md` for the `WorkloadLimits` side.
This file covers the `AllocationLimiting` side only.

## Model — `People::AllocationLimiting`

`packs/operational/app/models/people/allocation_limiting.rb`:

- `attribute :limitings, People::LimitingList.to_type` (serialized list of `{rule, value}`)
- `attribute :weekly_workload, :decimal` — total prescribed (recommended) hours/week
- `attribute :weekly_clinical_preference, :decimal` — `max_workload_per_day * 5`
- `attribute :weekly_child_availability, :decimal` — sum of the child's availability slots in hours
- `belongs_to :child, class_name: "People::Child", optional: false`

Rules enum — `packs/operational/app/models/enum/people/allocation_limiting_rules.rb`:

- `WEEKLY_CLINICAL_PREFERENCE = "weekly_clinical_preference"`
- `WEEKLY_CHILD_AVAILABILITY = "weekly_child_availability"`

## Calculation — `CalculateAllocationLimiting`

`packs/operational/app/concepts/people/use_cases/calculate_allocation_limiting.rb`.

Input: `child_id` OR `clinical_case_id` (exactly one required). Resolves the
`People::Child` (by `child_id`, or by `clinical_case_id`), then:

1. `RetrieveCurrentTotalWorkload` (subprocess) → total recommended hours/week
   (`weekly_workload`).
2. `RetrievePreferences` (subprocess) → `max_workload_per_day`.
3. `weekly_clinical_preference = max_workload_per_day * 5`.
4. `weekly_child_availability = sum over child.availability_time_slots of
   (end_at - start_at) / 1.hour`.
5. `limitings` — append `{rule, value}` only when the ceiling is BELOW the workload:
   - `weekly_clinical_preference < weekly_workload` → rule `weekly_clinical_preference`
   - `weekly_child_availability < weekly_workload` → rule `weekly_child_availability`
6. Upsert: `People::AllocationLimiting.find_or_initialize_by(child_id:)` then `update!`.

So `limitings` is EMPTY when the workload fits both ceilings; each entry is a
*violation* (ceiling that is lower than the prescribed hours), with `value` = the
ceiling itself.

## Fan-out — `CalculateAllAllocationLimitings`

`packs/operational/app/concepts/people/use_cases/calculate_all_allocation_limitings.rb`:
iterates `People::Child.kept.where(churned_at: nil)` and enqueues
`ExecuteUseCaseJob` → `CalculateAllocationLimiting` per child.

## Trigger — recurring job

`core/config/recurring.yml` (~line 166), key `schedule_calculate_children_allocation_limitings`:

```yaml
schedule_calculate_children_allocation_limitings:
  schedule: "0 1 * * * America/Sao_Paulo"   # every day 1AM
  class: ExecuteRecurringJobWithTenant
  args:
  - target_class: ExecuteUseCaseJob
    target_args:
    - { use_case: People::UseCases::CalculateAllAllocationLimitings }
```

## Consumption

`packs/operational/app/decorators/people/child_decorator.rb#allocation_limitings_info`
maps each limiting to an I18n string
(`activerecord.attributes.people/allocation_limiting.limitings.rule.<rule>`, with
`count: value`) — rendered as an advisory in the operational/admin panel. It is
NOT wired into the clinical-panel workload dropdown (that's `WorkloadLimits`).

## Related preference ceilings (same "does it fit" family)

`Preferences::ClinicalCasePreferences` (`packs/clinical/app/models/preferences/clinical_case_preferences.rb`):

- `max_workload_per_day` — default 4, validated 0..8.
- `max_workload_per_discipline_day` — default ABA 3 / TO 1 / Fono 1.
- `weekday_availability` — array of weekdays (drives the Bradesco hardlock and the
  "N dias de disponibilidade" wording in the SuggestedWorkload reason).
- `delay_level` — enum `severe/moderate/intermediate/mild/no_delay`, written back
  by the Vineland calc.

These are the *input* ceilings that `AllocationLimiting` compares against; the
per-discipline *dropdown* ceilings are the separate `WorkloadLimits` tables.
