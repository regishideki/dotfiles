# Digital signature envelopes (TCLE) — flow and the cancel/void gap

Domain: `Documents` signing (Zoho Sign default, Autentique as alternative
provider). Triggered when a clinician joins a clinical case.

## Event → job → document chain (TCLE / informed consent form)

1. `clinician_added_to_clinical_case` (topic `general.clinical_cases.v1`)
   → `Documents::CreateInformedConsentFormOnClinicianAddedJob`
   (`event_consumer_start.rb:815`). Mapper passes `clinical_case_id`,
   `clinician_id`, `clinician_role`.
2. Job → `Documents::UseCases::CreateInformedConsentFormDocument` — loads the
   active `ClinicalCaseFileTypeConfig` for the clinician's discipline (+
   optional insurance plan), skips via `pass_fast!` when no active digital
   config, resolves the main caregiver, then in a transaction:
   `create_document` → `request_digital_signature`.
3. `request_digital_signature` → `Documents::UseCases::RequestDigitalSignature`
   with `template_class: "informed_consent_form"`, building the envelope in the
   provider (Zoho `create_envelope` / Autentique `create_document`).
4. Recipients: `clinician` (signer, position 1 default) + `caregiver`
   (signer, position 2 default). `is_embedded` per recipient controls embed
   signing vs emailed link.

## Key facts

- **Idempotency is PER-CLINICIAN.** `check_idempotency`
  (`create_informed_consent_form_document.rb`) looks for an existing
  `INFORMED_CONSENT_FORM` `ClinicalCaseFile` whose `icfc.clinician_id` equals
  the incoming clinician, with signable status in
  `ACTIVE_SIGNABLE_STATUSES` (`in_progress`, `signed`, `partial_signed`).
  One TCLE per clinician per case — a pending TCLE for the OLD therapist does
  NOT block the NEW therapist's TCLE from being generated when they are added.
- **`Documents::SignableFileStatuses` has NO `cancelled`/`voided` value.**
  Only: `draft`, `pending_send`, `in_progress`, `partial_signed`, `signed`,
  `expired`, `declined`.
- **Neither provider client implements cancel/void.** `Zoho::Sign::DocumentsClient`
  (`app/infra/zoho/sign/documents_client.rb`) exposes create_document,
  create_envelope, update_document, submit_for_signature,
  send_signature_reminder, generate_embed_url, get_document, download_pdf —
  no void. `Signing::Providers::Autentique` likewise (create, update, submit
  no-op, resend_signatures, generate_embed_url, get_document, download_pdf) —
  no delete/void.
- **`clinician_removed_from_clinical_case` has no envelope-cancelling consumer.**
  `RemoveClinician` (packs/clinical) destroys the `ClinicalCaseClinician`
  relation, schedules `ClinicalGuidance::DeletePlanningsAndTasksJob`
  (`flow_option: :clinician_removed`), and emits the event. Consumers of the
  event are only: `FamilySupport::RemoveUserFromConversationJob`,
  `People::CreateOrUpdateCollaboratorChildHistoryAssignmentJob` (via
  `people_subscriber.rb`), and `Crm::SyncEntityToCrmByEventJob`. None touch
  `documents_signable_envelopes` / recipients / pendencies.

## The gap (what "cancel this pending TCLE" requires today)

There is NO automated or provider-level cancel/void path. When a therapist
leaves a case before signing their TCLE, the pending envelope lingers as a
"Assinatura de envelope" pendency (`missing_envelope_signature` →
`SignableEnvelopeRecipient`). Manual remediation is two parts:

1. **Clear the local pendency** — delete the TCLE `ClinicalCaseFile`.
   `Documents::UseCases::DeleteClinicalCaseFile` destroys the file +
   documentable + envelope (only when the envelope has no remaining
   `signable_files`). Exposed via:
   - ActiveAdmin (`packs/operational/app/admin/documents/clinical_case_files.rb`
     `destroy`), or
   - `DELETE /documents/clinical_case_files/:id.json`
     (`Documents::ClinicalCaseFilesController#destroy`).
2. **Void the external envelope** — `DeleteClinicalCaseFile` does NOT cancel
   the request in the provider. It must be manually voided/cancelled in the
   Zoho Sign (or Autentique) dashboard by `external_id`, otherwise it stays
   "pending" on the provider side until it expires.

## Engineering gap to flag

Missing feature candidates (surfaced as a user story, not silent work):
cancel pending envelopes on `clinician_removed_from_clinical_case`, add a
`cancelled`/`voided` status to `SignableFileStatuses`, and add a `void`
method to both provider clients (Zoho `DocumentsClient`, `Autentique`).

## File map

- `app/concepts/documents/use_cases/create_informed_consent_form_document.rb` — TCLE orchestration
- `app/jobs/documents/create_informed_consent_form_on_clinician_added_job.rb` — entry job
- `app/concepts/documents/use_cases/delete_clinical_case_file.rb` — local delete path
- `app/models/documents/enum/signable_file_statuses.rb` — status enum (no cancelled)
- `app/infra/zoho/sign/documents_client.rb` — Zoho client (no void)
- `app/services/signing/providers/autentique.rb` — Autentique provider (no void)
- `packs/clinical/app/public/clinical_cases/use_cases/remove_clinician.rb` — removal flow
- `event_consumer_start.rb` — subscriber registry (`clinician_*` mappings)
