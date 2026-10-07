# "Alta" / "graduation" de disciplina (ClinicalCaseDiscipline)

Domain map for the "alta"/"graduation" of a discipline in the core, and the
safe way to reverse it. Grounded in a real production fix (caso 1065, fono).

## Models & enums

- **`ClinicalCaseDiscipline`** (`packs/clinical/app/models/clinical_case_discipline.rb`)
  — the per-case-per-discipline row. Columns: `clinical_case_id`, `discipline`,
  `status` (default `"active"`), `note` (text), `updated_by_id`, timestamps.
- **`Enum::ClinicalCaseDisciplineStatuses`** — `ACTIVE = "active"`, `COMPLETED = "completed"`.
  "Alta"/"graduation" **is** `status == "completed"`.
- **`Enum::ClinicalDisciplines`** (`app/models/enum/clinical_disciplines.rb`) —
  `ABA = "aba"`, `SPEECH_THERAPY = "speech_therapy"` (fono),
  `OCCUPATIONAL_THERAPY = "occupational_therapy"`. `ExtendedClinicalDisciplines`
  adds `PARENT_TRAINING = "parent_training"`.
- **`ClinicalCase.number`** (`integer`) is the human-facing case number
  ("caso 1065"), unique per tenant via partial index
  `(tenant_id, number) WHERE number > 0 AND number IS NOT NULL`. To look up by
  number across tenants: `ClinicalCase.unscoped.where(number: N)`.
- **Unique index** on `clinical_case_disciplines`:
  `(tenant_id, clinical_case_id, discipline)` — exactly one row per discipline
  per case.

## Completion side effects (`UpdateClinicalCaseDiscipline`)

`packs/clinical/app/concepts/clinical_case_disciplines/use_cases/update_clinical_case_discipline.rb`.

When `status` transitions to `COMPLETED`, `handle_completion` fires (all inside
one `Wrap(TrailblazerTransactionWrap)`):
1. `CreateWorkload` with `workload_type: RECOMMENDED_HOURS`, `hours: 0.hours`,
   `change_reason: note` — this is the **"prescrição zerada"** root cause: a
   zero-hour recommended-hours workload that later shows 0h.
2. `ReproveSuggestedWorkload` for every PENDING suggested workload of that
   discipline.
3. Emits `ClinicalCaseDisciplines::Events::DisciplineCompleted`
   (topic `clinical_case.discipline.v1`).

When `status` is `ACTIVE` (or any value other than `COMPLETED`), `handle_completion`
returns `pass_fast!` and **NONE of the above runs** — it is a plain
`update!(status:, note:, updated_by:)` with no event. This is the safe
reactivation path (confirmed by spec "when status is ACTIVE ... not to change
ClinicalCaseWorkload, :count").

## Removing an "alta" (reactivating a discipline)

There is no dedicated "un-complete" use case — reactivation IS
`UpdateClinicalCaseDiscipline` with `status: "active"`:

```ruby
# IMPORTANT: wrap the .call in ActsAsTenant.with_tenant. The use case internally
# re-finds the record via a SCOPED find_by (CustomMacros::Model.Find -> default
# scope -> acts_as_tenant), which raises ActsAsTenant::Errors::NoTenantSet in a
# bare `rails runner` EVEN THOUGH you fetched the record via .unscoped. The
# exception surfaces at the Find step (BEFORE any write), so a failed attempt
# leaves data untouched — safe to retry after adding the wrapper.
tenant = Tenant.unscoped.find_by(id: discipline.tenant_id)
result = ActsAsTenant.with_tenant(tenant) do
  ClinicalCaseDisciplines::UseCases::UpdateClinicalCaseDiscipline.call(
    params: { id: discipline_id, status: ::Enum::ClinicalCaseDisciplineStatuses::ACTIVE, note: "..." },
    current_user: User.system_user   # falls back to dev@genialcare.com.br
  )
end
```

Key facts that make this clean:
- The `Contract` requires `note` filled (any non-empty string).
- `status: "active"` produces NO side effects (no zero workload, no reprove, no event).
- Sets `updated_by` correctly (audit), unlike a raw `update_column`.
- `User.system_user` resolves via `User.system_user_for(tenant)` then
  `User.find_by(email: "dev@genialcare.com.br")` (DEFAULT_SYSTEM_USER_EMAIL);
  `User < ApplicationRecordMultipleTenant` so the email lookup is NOT
  acts_as_tenant-scoped — safe from a bare `rails runner`.

## "Horas zeradas" after a new prescription

The zero workload is created with a specific `in_effect_since` (the completion
timestamp). A later prescription creates a NEW `ClinicalCaseWorkload` (immutable
create/discard model) with a later `in_effect_since`, which
`current_recommended_for` / `active_recommended_for` pick as current. So once the
OGRef has added a new prescription (1h in the real case), reactivating the
discipline status is usually the ONLY remaining fix — the zero workload is
historical and already superseded by `in_effect_since` ordering. Verify with:

```ruby
ClinicalCaseWorkload.unscoped.where(clinical_case_id: id, discipline: FONO).order(:created_at)
```

Watch the `unscoped` — `ClinicalCaseWorkload` has `default_scope -> { kept }`
(discard) AND acts_as_tenant, so a bare `.where` from `rails runner` raises
`ActsAsTenant::Errors::NoTenantSet`; use `.unscoped` for the global read.

## Production read-only verification pattern (worked this session)

Write the script to a local file and pipe it to the pod's stdin:

```
kubectl exec -n core <web-pod> -c web -i -- bash -c 'cd /app && bin/rails runner -' < /tmp/script.rb
```

- Pods: `kubectl get pods -n core | grep -i web`.
- **Flake**: the FIRST pod attempt returned `exit code 137` mid-boot (SIGKILL
  during Rails boot); retrying on a DIFFERENT web pod succeeded. If a runner
  dies at 137 with no script output, re-run against another `web-*` pod before
  debugging the script.
- gcloud SA re-auth first: `gcloud auth activate-service-account
  --key-file=~/.config/gcloud/regis-automation-sa-key.json` then
  `rm -f ~/.kube/gke_gcloud_auth_plugin_cache`.
