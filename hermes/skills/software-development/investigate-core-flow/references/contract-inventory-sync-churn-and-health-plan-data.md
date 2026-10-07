# Contract inventory, clinical health-plan sync, churn, and backflow semantics

Follow-up to `feature-flags-cutoffs-and-health-plan-identification.md` (2026-10-02).
Covers what data lives on the contract, how it is (or is NOT) propagated to the
clinical side, and what churn/backflow actually do — the building blocks for any
grandfathering / plan-identification / "anchor the workload to the current contract"
decision.

## Contract columns (`operational_people_contracts`, `db/schema.rb:6317`)

| Column | Notes |
|---|---|
| `start_date` (date, NOT NULL) | Unique per child (`index_..._child_id_and_start_date`). Business date, backdatable. |
| `churned_at` (date, nullable) | Unique per child (partial index `WHERE churned_at IS NOT NULL`). A contract is churned ONCE, terminally — no reopen/unchurn mechanism exists (the `reopen` methods in the codebase are `Scheduling::RoomBooking`/`AvailableHour`, unrelated). |
| `churn_reason` / `churn_other_reason` | `family_changed_insurer` and `family_losses_insurer` explicitly signal plan change / backflow — more declarative than date inference. |
| `contracting_model` | `insurance_health_plan` | `private_contracting` (top-level billing routing). |
| `insurance_health_plan_id` | FK → `Finance::InsuranceHealthPlan`. |
| `insurance_health_plan_number` | Member's plan number. |
| `category_type` | `Enum::People::CategoryTypes` — **the robust operator/plan discriminator** (see below). |
| `default_workload_applied` (bool, default false) | Whether the contract applied a default prescription (admin checkbox "Aplicar prescrição padrão?"). |
| `onboarded_at`, `created_at`, `updated_at`, `child_id`, `tenant_id` | — |

`People::Child#current_contract = contracts.max_by(&:start_date)` (`child.rb:264`).
`child.contracting_model` / `child.insurance_health_plan` are DERIVED (before_save
`normalize_insurance_attributes`) from `current_contract`, so they always reflect the
latest contract.

## `category_type` — the robust "Amil vs Amil One (premium)" discriminator

`Enum::People::CategoryTypes` (`packs/operational/app/models/enum/people/category_types.rb`)
has explicit Amil sub-plan categories:

```
BASIC_AMIL, INTERMEDIATE_AMIL, PREMIUM_AMIL, ONE_HEALTH_AMIL, LINCX_AMIL, AMIL_ONE_AMIL
```

`AMIL_ONE_AMIL` corresponds to the premium "Amil One" plan. This is a FAR more robust
signal than the clinical-side name string match (`name == "Amil"`), which is fragile
against future "Amil X" plan names (risk R8 in the Amil story). There is already a
finance-side precedent: `lib/tasks/backfill_amil_contract_category_type.rake`
(backfills `category_type: premium_amil`). `category_type` is on the CONTRACT (per
engagement), not the plan — so the relevant value is the CURRENT contract's category.

## `Finance::InsuranceHealthPlan` key fields (via `insurance_health_plan_id` FK)

`name`, `business_name`, `cnpj`, `governmental_code`, `integration_alias`
(`"amil"`, `"porto"`, `"bradesco"` — canonical operator id, 20+ finance call sites),
`pricing_model` (`fee_for_service` | `fee_per_day` — drives the default workload
5/2/2 vs 3h via `Agenda::Services::ChildWorkload`), `payment_method`, `state`,
`eligible_to_invoice`, `average_ticket`.

## Clinical-side sync: `SetInsuranceHealthPlan` (UPDATE in place, not create-new)

`packs/clinical/app/public/general/use_cases/set_insurance_health_plan.rb`:

```ruby
# find_or_create_by → 1 row per clinical case (ClinicalCase has_one :health_plan)
health_plan = General::InsuranceHealthPlan.find_or_create_by(clinical_case_id: ...)

if to_delete?(params)          # contracting_model == "private_contracting"
  health_plan.delete           # raw SQL DELETE, no callbacks — row is GONE
else
  health_plan.assign_attributes(params.except(:contracting_model))
  health_plan.save             # UPDATE in place — overwrites name/cnpj/plan_id
end
```

Consequences:
- **No history.** Each plan change overwrites the previous `name`/`cnpj`/
  `finance_insurance_health_plan_id`. `created_at` reflects the FIRST sync ever, not
  the current plan. The "Amil One" frozen names on legacy cases exist precisely
  because the sync only runs when the family passes through `CreateOrUpdateFamily`
  again — a finance-side rename alone does not re-trigger it.
- **No DB-level 1:1 guarantee.** `general_insurance_health_plans` has only a regular
  (non-unique) index on `clinical_case_id`. The 1:1 is enforced solely by
  `find_or_create_by` logic — a latent race (two concurrent calls could create two rows).
- **`General::InsuranceHealthPlan` carries ONLY `name`, `cnpj`,
  `finance_insurance_health_plan_id`** — no `category_type`, no `integration_alias`,
  no `pricing_model`, no contract `start_date`, no `churned_at`. `bradesco_group?` /
  `porto_seguro?` / (new) `amil?` all match on `name` string.

## Churn: the clinical side is NOT touched

- `child_churned` event (topic `people.children.v1`) has exactly 3 consumers, ALL in
  the operational pack — NONE touch clinical data:
  - `Scheduling::DiscardSchedulesAfterChurnJob`
  - `Finance::DeleteChurnedContractAttendancePeriodsJob`
  - `People::CloseCollaboratorChildHistoryAssignmentsByChildChurnedJob`
- The clinical pack has ZERO references to "churn".
- Churn is done via `CreateOrUpdateFamily` (admin sets `contract.churned_at` +
  `churn_reason`). That flow DOES run `sync_insurance_health_plan_with_clinical` →
  `SetInsuranceHealthPlan`, but churn does NOT change `contracting_model` or the plan,
  so it is a no-op UPDATE — the clinical plan row stays (same name). Deletion only
  happens for `private_contracting`, a separate action.
- `child.churned_at` is DERIVED (`normalize_churned_attributes`, `child.rb:131-143`):
  copied from `current_contract.churned_at` when the latest contract is churned, else
  `nil`. So the child auto-"un-churns" when a newer contract is added, but the OLD
  contract keeps its `churned_at` forever (history lives in the `contracts` list).

## Backflow / plan change = NEW contract (never a reopen)

- `start_date` unique per child ⇒ a new engagement requires a new `start_date`.
- `churned_at` unique per child + no reopen mechanism ⇒ the old contract stays churned.
- Admin form treats the new contract as `new_record?`; the `default_workload_applied`
  checkbox only shows for a NEW contract when other contracts already exist (the
  backflow case).
- `CreateOrUpdateFamily#create_default_workload_if_new_contract` fires only on a
  `new_contract` with `default_workload_applied`, creating a default workload with
  `in_effect_since = changed_contract.start_date` and `change_reason
  "Criação automática de carga horária padrão em fluxo de backflow"`.

## Workload ↔ contract linkage (there is NONE)

- `ClinicalCaseWorkload` has NO `contract_id` — only `clinical_case_id`. The only
  implicit link to a contract is DATE-based.
- No workload discard on churn (only manual `DeleteWorkload`). Old workloads stay
  `kept`, so `MIN(created_at)` over all `recommended_hours` workloads returns the
  pre-backflow date.
- Date-field nuance: the default workload's `in_effect_since = contract.start_date`
  (backdatable business date); a clinical (Vineland) workload defaults
  `in_effect_since = Time.now`. The current Amil regime compares `created_at`
  (insertion) against the cutoff to avoid `in_effect_since` backdating.

## Implication for "anchor the workload to the current contract"

Because backflow/plan-change always yields a NEW contract with a fresh `start_date`,
`current_contract.start_date` is a free, reliable cutoff anchor — old-contract
workloads have `created_at`/`in_effect_since` < the new `start_date` and are naturally
excluded, no `contract_id` needed. But `current_contract.start_date` (and
`category_type`, `churned_at`) are OPERATIONAL-only data; the clinical pack does not
see them today. Options: (a) duck-typed read `clinical_case.child.current_contract`
(works at runtime via the `has_one :child` string association; packwerk does not flag
duck-typed calls, but it is a hidden cross-pack read against the
operational→clinical direction); (b) extend `SetInsuranceHealthPlan` to sync
`start_date` + `category_type` (+ maybe `churned_at`) into new clinical-side columns
— clean, but schema + contract + sync + backfill cost. For "current contract" values,
syncing is sufficient; for contract HISTORY you must read `operational_people_contracts`
directly (cross-pack or BFF composition).

## Single-resolver pattern: one gate for matrix + limiting + validation

When a cohort rule (e.g. "new Amil regime") must apply consistently across
several consumers, put the decision in ONE resolver and have every consumer call
it. `NewAmilRegime#apply?` is the single gate consumed by all three workload
layers:

- `CalculateWorkload#workload_class` → `Services::NewAmilWorkload` (matrix)
- `WorkloadLimits#new_amil_regime?` → max dinâmico + teto total (limiting)
- `CreateWorkload#new_amil_regime?` → validação do teto

All three call `Services::NewAmilRegime.new(clinical_case).apply?`, whose cutoff
logic lives in `apply?` → `first_workload_after_cutoff?` → `first_workload_at`.
Changing `first_workload_at` (e.g. to filter by `current_contract.start_date`)
fixes matrix + limiting + validation in one edit, without touching the three
consumers. Keep the "is this case in the cohort" decision in ONE place so the
consumers can't drift.

## Cross-pack data sync — the "correct" recipe (not duck-typed, not events)

When clinical needs contract/plan data that lives in operational, the correct
pattern (respecting `operational → clinical`):

1. Add a column to the clinical model (e.g. `current_contract_start_date`).
2. Extend the existing **public** use case (`SetInsuranceHealthPlan`) to accept
   the field (`optional(:field).maybe(:date)` in the Dry::Validation contract;
   `assign_attributes(params.except(:contracting_model))` picks it up automatically).
3. In `CreateOrUpdateFamily#sync_insurance_health_plan_with_clinical`, pass
   `field: child.current_contract&.field` as a param (operational reads its own
   data and hands it to the clinical public API — allowed direction).
4. Backfill existing rows via an idempotent, multi-tenant rake.

Rejected alternatives:
- **Duck-typed cross-pack read** (`clinical_case.child.current_contract.start_date`)
  works at runtime (string association + duck typing, packwerk won't flag) but is
  hidden coupling against the graph direction. Cheap for one field, does not scale.
- **Event listener**: no `contract_created` event exists; the sync is already
  synchronous and covers create/update/churn/backflow. A listener would duplicate
  the sync AND add async lag.

Deploy a sync'd column safely in 3 sequential PRs — **migration+sync → rake →
consumer** — running the rake to completion BEFORE the consumer PR merges, so the
column is fully populated when the logic first reads it. Defensive NULL fallback
in the consumer: if the column is nil, skip the filter (fail-closed to old
behavior) rather than letting `col >= NULL` return nothing (which would
misclassify as "new family").
