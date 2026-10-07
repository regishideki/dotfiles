# clinical_case_file NOT_FOUND → "file was deleted before the job ran"

Worked example (2026-09-22): Datadog error-tracking issue ET-2912,
`ApplicationJobError: Job: Assessments::UseCases::ExtractSensoryProcessingMeasureReportInfoJob -
{code: "NOT_FOUND", message: "clinical_case_file not found"}`. Resolution: benign — the file was
created, deleted ~55s later by the user (upload → delete → re-upload), and the async job ran
~1h later against the already-deleted row. No bug.

## The wiring (why the job runs at all)

`event_consumer_start.rb` maps `documents.clinical_case_files.v1` / `clinical_case_file_created`
→ `ExecuteUseCaseJob` with `use_case: Assessments::UseCases::ExtractSensoryProcessingMeasureReportInfo`
(subscription `core-created-clinical-case-file-spm-report-sub`). `ExecuteUseCaseJob` (`app/jobs/execute_use_case_job.rb`)
resolves the use case from `params["use_case"]`, calls it, and raises
`ApplicationJobError.new(job: "#{use_case}Job", ...)` on failure — so the Datadog `resource_name`
is `<UseCase>Job` even though no such Job class exists (it's synthesized in the error).

The use case (`packs/clinical/app/concepts/assessments/use_cases/extract_sensory_processing_measure_report_info.rb`)
uses `CustomMacros::Model.Find(model_class: Documents::ClinicalCaseFile, model_key: :clinical_case_file)`
→ the `NOT_FOUND` end when the row is gone. It only proceeds for
`document_type == OCCUPATIONAL_THERAPY_SPM_WPS_REPORT` (`validate_params` passes fast otherwise).

## The CDC proof (create → delete timeline)

Query `raw.clinical_case_documents_events` for `payload.id = <clinical_case_file_id>`
(Postgres table `documents_clinical_case_files` is renamed in BQ to `clinical_case_documents_events`):

```
15:06:02.256  INSERT   "SPM - COMPARATIVO FEV - SET/26"
15:06:02.256  UPDATE
15:06:02.310  UPDATE
15:06:57.091  UPDATE
15:06:57.091  DELETE   (is_deleted=true)
```

Then, to prove the "re-upload" pattern, filter the same table by
`payload.clinical_case_id` + `payload.document_type`, order by `source_timestamp`. The same case
showed three SPM files on 22/09: `8c3a1765` "SPM - SETEMBRO/26" (15:05:28, still exists),
`0e69033c` "SPM - COMPARATIVO FEV - SET/26" (15:06:02, DELETED 15:06:57), and
`497a7c75` "SPM COMPARATIVO FEV/SET.26" (15:07:30, still exists) — the user deleted the original
and re-uploaded a corrected name ~33s later.

## The gap that produces the noise

`event_consumer_start.rb` has a `clinical_case_file_deleted` handler, but it only fires
`Assessments::UseCases::EmitVinelandReportDeletedEvent` (Vineland domain). Nothing cancels the
pending SPM extraction job when a file is deleted, so "file deleted before the delayed job runs"
surfaces as a NOT_FOUND error. Minor enhancement candidate (cancel pending job on delete), not a
production bug.

## Takeaway

When a `...Job` reports `NOT_FOUND: clinical_case_file not found` (or any `<entity> not found`
from an event-driven `ExecuteUseCaseJob`), the first hypothesis to check is "the entity was
created then deleted before the async job ran" — pull the CDC `raw.<table>_events` history for the
entity id and look for a DELETE. If INSERT→DELETE both precede the job's `scheduled_at`, the error
is benign and can be ignored.
