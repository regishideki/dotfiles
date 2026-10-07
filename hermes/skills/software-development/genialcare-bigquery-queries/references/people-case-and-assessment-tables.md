# People / case / assessment table locations (discovered during incident investigations)

Quick map of where to find "who is attached to this case" and "when was this form
submitted" — these live in NON-obvious places and cost several exploratory queries to find.

## Caregivers of a clinical case (→ user email for RUM/APM search)

- `data-kernel-production-4o7n.datakernel.clinical_cases` — case by `number` (filter
  `tenant_id = '6f8da042-2dd1-4872-a613-84d371bde78c'` = genialcare; `number` is NOT
  globally unique). `id` = clinical_case_id.
- `data-kernel-production-4o7n.datakernel.caregivers` — has DENORMALIZED `user_id`,
  `user_full_name`, `user_email` directly (no extra join to `users` needed for RUM search).
  Also `profile`, `cellphone_number`, `name`.
- Join table: `datakernel.clinical_cases_caregivers` (`clinical_case_id` → `caregiver_id`).

```sql
SELECT cg.user_id, cg.user_email, cg.name, cg.profile
FROM `data-kernel-production-4o7n`.datakernel.clinical_cases_caregivers ccc
JOIN `data-kernel-production-4o7n`.datakernel.caregivers cg ON cg.id = ccc.caregiver_id
WHERE ccc.clinical_case_id = '<case-id>';
```

Note: `datakernel.users` does NOT have a `tenant_id` column; use `caregivers.user_id`/`user_email`.

## COPM form / agreement submission timestamps

- `supervision-production-8f1v.assessment.copm_forms` — one row per submitted COPM:
  columns `id`, `agreement_id`, `submitted_by_id`, `tenant_id`, `created_at`, `updated_at`.
  `created_at` = when the form was submitted (and the agreement completed in the same
  transaction). This is the fastest way to answer "was this COPM already submitted, and
  when/by whom".
- Related assessment tables (same `assessment` dataset): `copm_form_domains`,
  `copm_form_issues`, `copm_form_summaries`.

```sql
SELECT created_at, submitted_by_id
FROM `supervision-production-8f1v`.assessment.copm_forms
WHERE agreement_id = '<agreement-id>';
```

## `clinical_agreements` is NOT replicated to a queryable BQ table

The core model `Clinical::Agreement` (table `clinical_agreements`, with `completed_at`,
`native_form_type`, `specific_type`, `clinical_case_id`) has NO CDC/queryable mirror in
BQ. The only agreement-ish CDC table found is
`supervision-production-8f1v.raw.parental_training_clinical_agreements_events` (parental
training only). To answer "when did agreement X get completed", either join
`assessment.copm_forms` (for COPM) or fall back to the APM span (the `SubmitCopmForm` /
`MakeComplete` use-case span's `custom.params` + timestamp) — not BQ.

## Blast-radius shortcut

Once you know the use case, `aggregate_spans` on `resource_name:*<UseCase>* status:error`
grouped by `@error.message` sizes "one family stuck in a loop" vs "systemic" in one call.
