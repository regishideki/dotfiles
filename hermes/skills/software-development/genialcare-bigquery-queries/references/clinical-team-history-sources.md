# Clinical team (clinician/OG) history — which source is reliable

Question that recurs: "is there a table with the *history* of the clinical team, not just the
current snapshot?" The current snapshot lives in `clinical_cases_clinicians` (PLURAL — note the
extra `s`; not `clinical_case_clinicians`), keyed by `clinician_role` (`clinical_case_owner`,
`occupational_therapy_specialty_consultant`, `speech_specialty_consultant`, `aba_therapist`, etc.).

There are **two** history sources, and **neither covers the full history**. Answer accordingly.

## 1. CDC — `clinical_cases_clinicians_events` (datakernel, schema `raw`)

- External table (Dataform `type: "operations"`) over the Datastream CDC event-store:
  `gs://genialcare-event-store-<env>/streams/database-events/core/public_clinical_case_clinicians/*`
- Captures real INSERT/UPDATE/DELETE of the `public_clinical_case_clinicians` row — it is the
  ground-truth of "what actually changed in the DB".
- Coverage: **only since Datastream CDC was enabled** (a few years ago). No full history before that.
- Columns: `id`, `clinical_case_id`, `clinician_id`, `clinician_role`, `created_at`, `updated_at`,
  `created_by_id`, `updated_by_id`, `to_be_removed_at`.

## 2. Pubsub events from core (application domain events)

- `Events::ClinicianAddedToClinicalCase` and `Events::ClinicianRemovedFromClinicalCase`, emitted via
  `Events::Trailblazer::EmitEvent` (pubsub) in the `ClinicalCases::UseCases::AddClinician` /
  `RemoveClinician` use cases.
- Fired whenever add/remove goes through those use cases — including the automatic deallocation
  flow (`ScheduleClinicianDeallocation` → `DeallocateClinicians` → `RemoveClinicianJob`, which calls
  `UseCases::RemoveClinician`). So scheduled/automatic removal **does** emit.
- Gaps (why it is NOT 100% reliable):
  - Writes that bypass the use case and call the model method `clinical_case.add_clinician(...)`
    directly (seeds, historical backfills, data fixes / migrations). Those mutate the relation with
    no event.
  - Anything before the event system existed.

## Bottom line

- Neither source is complete. CDC is the best DB-ground-truth for the covered window.
- For a robust OG indicator, cross the two and accept that pre-CDC / pre-event history is simply not
  reliably recoverable.
