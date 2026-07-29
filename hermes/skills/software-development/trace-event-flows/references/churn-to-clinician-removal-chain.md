# Churn → Clinician Removal: Full Event Chain

Traced 2026-07-27. Example of a 5-link event cascade crossing two packs
(operational → clinical) with a delayed side effect.

## The chain

### Link 1: Contract churn → ChildChurned event

- **Emitter**: `People::UseCases::CreateOrUpdateFamily`
  (`packs/operational/app/concepts/people/use_cases/create_or_update_family.rb:191-193`)
- **Logic**: When a contract changes and gets `churned_at` set (line 65-66),
  it's collected as `churned_contracts`. For each, `People::Events::ChildChurned.build_from(contract)`
  is appended to `ctx[:events]`.
- **Event class**: `People::Events::ChildChurned`
  (`packs/operational/app/concepts/people/events/child_churned.rb`)
- **Topic**: `people.children.v1`, **Event name**: `child_churned`

### Link 2: ChildChurned → DiscardSchedulesAfterChurnJob

- **Subscriber**: `event_consumer_start.rb:689-700`
  (subscription: `core-child-churned-sub`)
- **Job**: `Scheduling::DiscardSchedulesAfterChurnJob`
  (`packs/operational/app/jobs/scheduling/discard_schedules_after_churn_job.rb`)
- **Mapper**: passes `clinical_case_id`, `contract_id`, `final_session_date`
- **Note**: There are TWO other subscribers for `child_churned`:
  - `PeopleSubscriber` (line 69-80) → `CloseCollaboratorChildHistoryAssignmentsByChildChurnedJob`
    (closes collaborator history assignments, does NOT touch clinicians)
  - `FinanceSubscriber` (line 634-644) → `DeleteChurnedContractAttendancePeriodsJob`
    (deletes attendance periods, does NOT touch clinicians)

### Link 3: DiscardSchedulesChurnedChild → DiscardSchedule (per schedule)

- **Use case**: `Scheduling::UseCases::DiscardSchedulesChurnedChild`
  (`packs/operational/app/concepts/scheduling/use_cases/discard_schedules_churned_child.rb`)
- **Logic**: Discards ALL schedules for the clinical case — first official
  ones (line 90), then remaining non-official (line 103-108). Each schedule
  goes through `Subprocess(Scheduling::UseCases::DiscardSchedule)`.

### Link 4: DiscardSchedule → AllSchedulingForCollaboratorInClinicalCaseDiscarded

- **Use case**: `Scheduling::UseCases::DiscardSchedule`
  (`packs/operational/app/concepts/scheduling/use_cases/discard_schedule.rb:83-95`)
- **CONDITIONAL emission** (line 84): only fires when
  `schedule.official? && schedule.intervention?`. If the clinician only
  has non-official or non-intervention schedules, this event is NOT emitted
  and the chain breaks here silently.
- **Logic** (line 86-88): After discarding, checks if the collaborator now
  has zero official schedules for the clinical case. If so, emits
  `Scheduling::Events::AllSchedulingForCollaboratorInClinicalCaseDiscarded`.
- **Event class**: `Scheduling::Events::AllSchedulingForCollaboratorInClinicalCaseDiscarded`
  (`packs/operational/app/concepts/scheduling/events/all_scheduling_for_collaborator_in_clinical_case_discarded.rb`)
- **Topic**: `scheduling.schedule.v1`

### Link 5: AllSchedulingForCollaboratorInClinicalCaseDiscarded → ScheduleClinicianDeallocation

- **Subscriber**: `event_consumer_start.rb:411-425`
  (subscription: `schedule-clinician-deallocation-from-clinical-case-sub`)
- **Use case**: `ClinicalCases::UseCases::ScheduleClinicianDeallocation`
  (`packs/clinical/app/concepts/clinical_cases/use_cases/schedule_clinician_deallocation.rb`)
- **Logic** (line 41): Sets `to_be_removed_at = (deallocation_after || Date.current) + 14.days`
  on the `ClinicalCaseClinician`. Does NOT remove immediately — only schedules.
- **Also** (line 52-54): Enqueues `ClinicalGuidance::DeletePlanningsAndTasksJob`
  for the clinical case clinician.

### Link 6 (delayed): Daily job removes the clinician

- **Recurring job**: `config/recurring.yml:233-237`
  (`schedule_deallocate_clinical_case_clinicians`, runs daily at 6AM America/Sao_Paulo)
- **Job**: `ClinicalCases::ScheduleDeallocateCliniciansJob`
  → `ClinicalCases::UseCases::DeallocateClinicians`
  (`packs/clinical/app/concepts/clinical_cases/use_cases/deallocate_clinicians.rb`)
- **Logic** (line 19): Finds all `ClinicalCaseClinician` where
  `to_be_removed_at <= today`, enqueues `ClinicalCases::RemoveClinicianJob`
  for each.
- **RemoveClinicianJob** → `ClinicalCases::UseCases::RemoveClinician`
  (`packs/clinical/app/public/clinical_cases/use_cases/remove_clinician.rb`)
  — destroys the `ClinicalCaseClinician` record, emits
  `ClinicianRemovedFromClinicalCase`, and enqueues
  `ClinicalGuidance::DeletePlanningsAndTasksJob`.

## Total delay

From churn event to actual clinician removal: up to 14 days + up to 24 hours
(until the 6AM daily job runs). The plannings/tasks deletion happens
immediately at link 5, but the clinician record stays for ~14 days.

## Silent break points

1. **Link 4 condition**: if no schedule is `official? && intervention?`,
   the `AllSchedulingForCollaboratorInClinicalCaseDiscarded` event is never
   emitted. The clinician stays assigned forever.
2. **Link 4 condition**: if the collaborator still has another official
   schedule for the same clinical case (shouldn't happen after full churn
   discard, but possible if schedules were created in a race), the event
   is not emitted for that collaborator.
3. **Link 2 `final_session_date`**: `DiscardSchedulesAfterChurnJob` returns
   early (line 10) if `final_session_date` is blank. If the churned contract
   has no `final_session_date`, no schedules are discarded.
