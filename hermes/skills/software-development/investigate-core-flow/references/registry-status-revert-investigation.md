# Assessment registry "stuck started" despite all sub-assessments complete — investigation (root cause + CDC evidence)

Distinct bug from `direct-assessment-registry-null-investigation.md` (which was a
NULL registry / `session_type` mismatch). This one: a **Fono or TO direct-assessment
registry stays `status = 'started'` even though ALL its sub-assessments are
`completed`**. Symptom reported by therapists as "preenchi tudo mas o registry não
completa" — and, per the user, the team often fixes it by hand later (re-saving to
force a re-complete).

## Conclusion (root cause)

The registry's `DirectAssessmentRegistry#recalculate_status!` DOWNGRADES a completed
registry back to `started` whenever ANY sub-assessment is not-complete at recalc time:

```ruby
# packs/clinical/app/models/assessments/direct_assessment_registry.rb
def recalculate_status!(assessments:)
  if assessments.present? && assessments.all? { |a| a&.completed? }
    mark_as_completed      # update(status: COMPLETED, ...)
  else
    mark_as_started!       # update!(status: STARTED, completed_at: nil, editable_until: nil)
  end
end
```

During a re-edit (reopen within the 10-day editable window → `reopen` →
`mark_as_started!`), a sub-assessment is transiently `not_started` while its sub-items
are destroyed/recreated, so a concurrent (or even subsequent) recalc sees "not all
complete" and downgrades the registry. It only re-completes if a later save's recalc
sees all-complete — not guaranteed under concurrency or if the final save never lands.

Three structural gaps (all three matter):

1. **Fono `SpeechTherapy::Registry#recalculate_status!` has NO `with_lock`**; only
   `OccupationalTherapy::Registry` got the lock (commit `c56a7e8497`, PR #6011, Jun 2026).
   The June fix was TO-only — Fono was never locked.
2. **`reopen` / `mark_as_started!` is never locked** in EITHER discipline. The
   dispatcher step `reopen_registry_if_needed` (`save_speech_therapy_assessment.rb:32`,
   `save_occupational_therapy_assessment.rb:40`) calls `registry.reopen` directly, no
   `with_lock`, no transaction.
3. **The registry recalc runs in a SEPARATE transaction/step from the sub-assessment
   save.** `recalculate_registry_status` (`save_speech_therapy_assessment.rb:38`,
   `save_occupational_therapy_assessment.rb:54`) is OUTSIDE the handler's
   `Wrap(TrailblazerTransactionWrap)`, so the sub-assessment status write and the
   registry status read-modify-write are not atomic → TOCTOU window.

## Proof the June lock did NOT fix it

The TO registry `ab35aa73-8666-40e1-8994-d059e9312fe9` was reverted on **2026-09-18**,
AFTER the June lock — CDC shows INSERT started (09-11) → UPDATE completed (09-16) →
UPDATE started (09-18, `completed_at` nulled), stuck ever since. So the `with_lock` on
`recalculate_status!` alone is insufficient: the `reopen` path and the cross-transaction
split remain open.

## Concurrency confirmation (two people, user's hypothesis)

CDC for sub-assessment `orofacial_myology_assessments` id
`520b7aad-a7e2-4f47-9efc-479907d202f2` shows TWO different `updated_by_id` in the SAME
second (2026-05-05 13:43):

- `13:43:01` → `status=not_started` ×3, `updated_by_id = f1692af4` (camilla.abreu@genialcare.com.br)
- `13:43:02` → `status=completed`, `updated_by_id = 43cd6eb7` (edigondim@gmail.com)

Two different users writing the same sub-assessment near-simultaneously → registry
status flips. This is exactly "uma pessoa sobrescrevendo o efeito da outra".

## Key domain facts (save these)

- **Fono `SpeechTherapy::Registry` has NO `updated_by` column** (model has no
  `belongs_to :updated_by`); only TO's registry does (`belongs_to :updated_by, optional: true`).
  The fono registry `*_events` payload therefore has no `updated_by_id`.
- **`updated_by` on the TO registry is the CREATOR only** — `mark_as_completed` /
  `mark_as_started!` never set it, so you CANNOT attribute a revert via the registry's
  `updated_by`. Attribute via the SUB-assessment's `updated_by_id` (sub-assessments call
  `recalculate_status!(updated_by:)` on every save) or the Datadog trace `usr.email`.
- **CDC table names** (all under `supervision-production-8f1v.raw`):
  `speech_therapy_registries_events`, `occupational_therapy_registries_events`,
  `phonological_assessments_events`, `expressive_communication_assessments_events`,
  `orofacial_myology_assessments_events`, `speech_motor_control_assessments_events`,
  `augmentative_and_alternative_communication_assessments_events` (NOT `aac_assessments_events`).
- **Rails table-name gotcha for the remediation snippet**: the AAC sub-assessment's Rails
  `self.table_name` is `ast_augmentative_and_alternative_communication_assessments` (the
  `ast_` prefix, NOT `assessment_speech_therapy_` like the other 4 Fono sub-assessments).
  In a `.joins(:aac_assessment).where(...)` snippet the WHERE must reference the `ast_...`
  table; the other four are `assessment_speech_therapy_{phonological,expressive_communication,orofacial_myology,speech_motor_control}_assessments`.
- Current-state tables: `supervision-production-8f1v.assessment.speech_therapy_registries`
  / `...occupational_therapy_registries` (registry points at sub-assessments via
  `<sub>_assessment_id` FKs; TO sub-assessments point back via `registry_id`).

## BQ queries (in code-snippets, `queries/specific/assessment/`)

- `registry-stuck-blast-radius.sql` — count registries `status='started'` AND all subs
  `completed`, segmented by month/discipline.
- `registry-stuck-detail.sql` — IDs + timestamps of the stuck registries (feed CDC).
- `registry-completion-divergence.sql` — completed registries whose `completed_at`
  diverges from `MAX(sub.updated_at)`; a large gap = "completed by hand later".
- `registry-cdc-forensic.sql` — CDC status history template for one registry.

Blast radius found (Sep 2026): ~4 currently stuck (3 Fono + 1 TO) + 1 manually-fixed
with 7-day divergence — rare race, consistent with "às vezes acontece".

## Fix (implemented, PR #6799)

The shipped fix serialized the two UNLOCKED status writes (gaps #1 and #2 above) rather
than restructuring the transaction boundary — additive `with_lock`, no single-threaded
behavior change, so existing behavioral specs pass unchanged:

1. Wrap `SpeechTherapy::Registry#recalculate_status!` in `with_lock` (parity with TO).
2. Wrap `DirectAssessmentRegistry#reopen` in `with_lock` (serializes the
   completed→started downgrade for BOTH disciplines).

Note the earlier recommendation to "move recalc INTO the transaction" was NOT taken — it
was unnecessary: the recalc step already runs AFTER the handler's `Wrap` commits, so it
reads the committed sub-assessment state; the only inconsistency is cross-request
concurrency, which `with_lock` addresses. (The `return false unless editable?` guard
inside `reopen`'s `with_lock do` block was later changed to `next false` — the Gemini
review bot flagged `return` as a *non-local return* that exits the whole method; `next`
returns from the block instead, more idiomatic. Commit `c19e93acd2`.)

Regression spec: add `it_behaves_like "a direct assessment registry",
:assessment_speech_therapy_registry` to the Fono registry spec (it was TO-only), to get
`editable?`/`reopen` coverage for the discipline that was missing it.

Still open (product decision): whether `mark_as_started!` should downgrade an
already-completed registry at all, vs. an explicit separate "reopened for edit" state.

Remediation for the already-stuck registries (console snippets, gitignored — NOT part of
the PR): `custom_gitignore/snippets/assessments/speech_therapy.rb` (Fono) and
`occupational_therapy.rb` (TO) — both find `status='started'` + all-subs-completed and
call `recalculate_status!`.

## Executing the remediation in a production pod (verify → fix → re-verify)

Ran Sep 2026 (PR merged to `development`; prod still on `main`, but `recalculate_status!`
exists in prod regardless of the lock fix — the fix is a data write, not a code change).
Safe 3-step pattern with a `rails runner` script that defaults to `DRY_RUN=1`, copied into
the pod and run against the `web` container (Rails app at `/app`):

```
kubectl -n core cp script.rb <web-pod>:/tmp/script.rb
kubectl -n core exec <web-pod> -- env DRY_RUN=1 bin/rails runner /tmp/script.rb  # conta antes
kubectl -n core exec <web-pod> -- env DRY_RUN=0 bin/rails runner /tmp/script.rb  # corrige
kubectl -n core exec <web-pod> -- env DRY_RUN=1 bin/rails runner /tmp/script.rb  # conta depois (=0)
```

Find across ALL tenants with `ActsAsTenant.without_tenant { scope.joins(...).where(status:
"started", <sub_table>: {status: "completed"}) }`; fix inside
`ActsAsTenant.with_tenant(Tenant.find(r.tenant_id)) { r.recalculate_status! }`. All stuck
registries were in the single `genial` tenant (`6f8da042-2dd1-4872-a613-84d371bde78c`).

Two gotchas hit this session:
- **BQ (Datastream CDC) lags live Postgres** — BQ showed 4 stuck, the pod found 6 (2 new
  cases appeared after the earlier BQ scan, since the fix PR wasn't deployed to prod yet).
  Always re-verify in the POD, not just BQ.
- **Side-effect of `recalculate_status!`**: sets `completed_at = Time.current` (the
  original completion date was lost by the bug) and `editable_until = now + 10d`. Only 3
  fields, no callback/cascade/event — reversible; backfill `completed_at` from the CDC
  timestamp of the last `UPDATE ... completed` if the original date matters.
