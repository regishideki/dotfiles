# Workload Limits: Health Plan + Delay Level Architecture

Investigated 2026-08-19. Slack thread C0B24BST335/p1787160854898369 —
user unable to edit ABA workload to maintain 4h; dropdown only showed 1-3h.

## The full chain

```
Frontend (clinical-panel)
  WorkloadsForm.tsx:72  →  for (let i = limits.min; i <= limits.max; i++)
                           options.push({value: i, label: `${i} horas`})
  ↓ GraphQL query workloadLimits(clinicalCaseId)
BFF (clinical-panel-bff)
  resolvers.js:29-31  →  clinicalCasesApi.workloadLimits(clinicalCaseId)
  datasources/core/clinical-cases-api.js:335-336
  ↓ GET /clinical_cases/:id/workload_limits.json
Core (Rails)
  WorkloadLimitsController#show
  → Services::WorkloadLimits.new(clinical_case, current_user).call
```

## Core: Services::WorkloadLimits

File: `packs/clinical/app/concepts/clinical_case_workloads/services/workload_limits.rb`

Three branches:

1. **Non-Porto plan** → `default_limits`: ABA {0..12}, Speech {0..3}, OT {0..3}
2. **Porto Seguro + user is `clinical_case_reference`** → `default_limits`
   (reference role gets flexible schedule → full range)
3. **Porto Seguro + any other role** → `PortoWorkload.new(delay_level, clinical_case).limits`
   (strict limits by delay level)

The `clinical_case_reference?` check:
```ruby
def clinical_case_reference?
  clinical_case_clinician(::Enum::ClinicianRoles::CLINICAL_CASE_REFERENCE).present?
end
```

If `delay_level` is nil, `PortoWorkload.limits` returns nil → `WorkloadLimits`
falls back to `default_limits` (0..12). So nil delay_level = permissive.

## PortoWorkload LIMITS table

File: `packs/clinical/app/concepts/clinical_case_workloads/services/porto_workload.rb`

| delay_level    | ABA    | Speech | OT     |
|----------------|--------|--------|--------|
| SEVERE         | 9-12   | 2-2    | 2-2    |
| MODERATE       | 7-9    | 2-2    | 2-2    |
| INTERMEDIATE   | 0-5    | 0-2    | 0-2    |
| MILD           | 0-3    | 0-1    | 0-1    |
| NO_DELAY       | 0-3    | 0-1    | 0-1    |

`delay_level` comes from `clinical_case.preferences&.delay_level` — set during
assessment (Assessments::Enum::DelayLevel).

## The "can't maintain existing value" pattern

A workload can be created with 4h ABA when:
- The plan is not Porto Seguro (default limits allow 0-12)
- The plan is Porto Seguro but delay_level was INTERMEDIATE+ (allows ≥4)
- The plan is Porto Seguro but the creator had `clinical_case_reference` role
- The delay_level was nil at creation time (falls back to default 0-12)

Later, when a different user (non-reference role) tries to EDIT the workload
— even just to change the justification text — the edit screen fetches
`workloadLimits` which returns the CURRENT limits based on the CURRENT
delay_level. If the delay_level was since updated to MILD/NO_DELAY (max 3),
the dropdown only shows 1-3. The user is stuck: they can't maintain 4h
because the edit form re-validates against current limits.

## Frontend: how options are generated

`WorkloadsForm.tsx` (clinical-panel):

```tsx
// Line 56-68: limits selected by discipline
switch (selectedDiscipline) {
  case ClinicalDisciplines.ABA:
    limits = workloadLimits.aba;        // {min: number, max: number}
  case ClinicalDisciplines.SPEECH_THERAPY:
    limits = workloadLimits.speechTherapy;
  case ClinicalDisciplines.OCCUPATIONAL_THERAPY:
    limits = workloadLimits.occupationalTherapy;
}

// Line 70-76: options generated from min..max
if (limits) {
  const options = [];
  for (let i = limits.min; i <= limits.max; i++) {
    options.push({ value: i, label: t('hours.hoursText', { count: i }) });
  }
  setHourOptions(options);
}
```

No hardcoded hour list — the dropdown is entirely driven by backend limits.

## BFF: the transform

`resolvers.js` calls `transformResponse(response)` which recursively converts
snake_case keys to camelCase. Core returns `{aba: {min: 0, max: 3}}` → BFF
passes through as-is (already the right shape, just key casing). The GraphQL
schema uses `aba`, `speechTherapy`, `occupationalTherapy` — note `aba` stays
lowercase (3 letters, no casing to transform).

## Key files

| Layer | File |
|-------|------|
| Frontend form | `clinical-panel/src/pages/CoverPage/Workloads/Workloads/WorkloadsForm/WorkloadsForm.tsx` |
| Frontend edit page | `clinical-panel/src/pages/CoverPage/Workloads/Workloads/ClinicalCaseWorkloadsEdit.tsx` |
| Frontend types | `clinical-panel/src/types/clinicalCaseWorkloads.ts` (WorkloadLimits type) |
| Frontend query | `clinical-panel/src/queries/clinicalCaseWorkloads/getClinicalCaseWorkloadLimits.ts` |
| BFF resolver | `clinical-panel-bff/src/schema/workloads/resolvers.js:29-31` |
| BFF datasource | `clinical-panel-bff/src/datasources/core/clinical-cases-api.js:335-336` |
| Core controller | `core/packs/clinical/app/controllers/clinical_case_workloads/workload_limits_controller.rb` |
| Core service | `core/packs/clinical/app/concepts/clinical_case_workloads/services/workload_limits.rb` |
| Porto limits | `core/packs/clinical/app/concepts/clinical_case_workloads/services/porto_workload.rb` |
| Core specs | `core/packs/clinical/spec/concepts/clinical_case_workloads/services/workload_limits_spec.rb` |
| Core routes | `core/config/routes.rb:164` — `resource :workload_limits, only: [:show]` |
