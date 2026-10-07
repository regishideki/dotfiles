# Feature flags, grandfathering cutoffs, and health-plan identification (Amil workload territory)

Read-only territory investigation (2026-09-30) for an Amil workload rule with a
grandfathering decision. Covers: `FeatureFlag` key resolution, how splits get
created, cutoff-date precedents, the contract → clinical case → default
workload chain, `clinical_case_workloads` index gaps, and how operators
(Amil/Bradesco/Porto) are identified on the clinical side.

## FeatureFlag `key` resolution — no convention, each call site picks one

`FeatureFlag.on?(key:, split_name:)` — the `key` (Split.io bucketing key)
varies per flag:

| split_name | key | file |
|---|---|---|
| `enable_create_suggested_workload` | `vineland_report_id` (UUID) | `packs/clinical/app/concepts/clinical_case_workloads/use_cases/calculate_workload.rb:153-158` |
| `enable_hardlock_bradesco_workload` | `clinical_case.id` | `packs/clinical/app/concepts/clinical_case_workloads/services/bradesco_workload.rb:44-49` |
| `clinical_copm_agreement_enabled` | `clinical_case.tenant_id` | `packs/clinical/app/concepts/clinical_cases/use_cases/create_initial_clinical_case_agreements.rb:69-74` |
| `core_enable_new_authorization` | `ActsAsTenant.current_tenant.external_id` | `app/infra/authorization/helper.rb:4` |

Precedents: per-case flag → `clinical_case.id`; per-tenant flag → `tenant_id`
(or `external_id`). These two flags (`enable_*_workload`) are the closest
analogues for a new `enable_amil_workload_rule`-style flag.

## Creating a new split

- Splits are created in the **Split.io dashboard** — there is NO rake/task in
  core that creates splits.
- For tests, add the split to `config/split.yaml` (e.g.
  `enable_amil_workload_rule: treatment: 'off'`) — the test factory reads
  that file with a 10s reload.
- An undefined split returns treatment `"control"` (≠ "on" → flag off), so a
  missing split.yaml entry silently fails-closed in tests that don't stub.
- Specs stub globally: `allow(FeatureFlag).to receive(:on?).and_return(true/false)`
  — the pattern used in every workload spec (e.g. `calculate_workload_spec.rb:29,54`).
- The `model:` param (`FeatureFlagableModel` tracking) has NO production call
  site today — only marketplace specs use it.

## Grandfathering / cutoff-date precedents (exactly 2 in core, both business dates)

1. `packs/operational/app/models/finance/invoice/fiscal_invoice.rb:16`
   ```ruby
   TAX_RESPONSIBILITY_BENEFICIARY_CUTOFF_DATE = Date.new(2026, 8, 1).freeze
   # line 129:
   if issued_at && issued_at.to_date >= TAX_RESPONSIBILITY_BENEFICIARY_CUTOFF_DATE
   ```
   (with a `# TEMPORARY:` comment explaining the cutoff ignores plan config)
2. `packs/operational/app/concepts/finance/invoice/services/payment_pricing/replacement_session_incentive_factory.rb:35`
   ```ruby
   REPLACEMENT_INCENTIVE_START_DATE = Date.new(2026, 3, 9).freeze
   # line 38:
   session.started_at >= REPLACEMENT_INCENTIVE_START_DATE
   ```

Pattern: frozen `Date.new(...).freeze` constant at the top of the class + `>=`
comparison against a **business date** of the record (`issued_at`,
`started_at`) — never `created_at`. An Amil cutoff would analogously compare
`contract.start_date >= AMIL_CUTOFF`.

## Contract → clinical case → default workload chain

- `People::Child#current_contract` = `contracts.max_by(&:start_date)`
  (`packs/operational/app/models/people/child.rb:264-266`).
- `People::Contract` → table `operational_people_contracts` (`db/schema.rb:6331`):
  `start_date` (date, NOT NULL, unique per child via
  `index_operational_people_contracts_on_child_id_and_start_date`),
  `default_workload_applied` (boolean), `insurance_health_plan_id` →
  `Finance::InsuranceHealthPlan`, `churned_at`.
- `People::UseCases::CreateOrUpdateFamily` (`packs/operational/app/concepts/people/use_cases/create_or_update_family.rb`)
  steps IN ORDER, all inside one `Wrap(TrailblazerTransactionWrap)`:
  `save_family` → `sync_clinical_case_with_clinical` (creates the clinical
  case) → `sync_insurance_health_plan_with_clinical` →
  `create_default_workload_if_new_contract`.
- `create_default_workload_if_new_contract` (lines 144-167) fires only when
  the contract is new AND `default_workload_applied` is true (admin checkbox
  "Aplicar prescrição padrão?", `packs/operational/app/admin/people/people_families.rb:674`),
  then calls `General::UseCases::CreateDefaultWorkload` with
  **`in_effect_since: changed_contract.start_date`**,
  `change_reason: "Criação automática de carga horária padrão em fluxo de backflow"`,
  and `default_value: true` (`packs/clinical/app/public/general/use_cases/create_default_workload.rb:43-48`).
- Default hour tables come from `Agenda::Services::ChildWorkload`
  (`packs/operational/app/concepts/agenda/services/child_workload.rb:4-14`):
  FEE_PER_DAY → ABA 3h; otherwise ABA 5h / Fono 2h / TO 2h. `pricing_model`
  read from `child.current_contract&.insurance_health_plan&.pricing_model`.

### Consequences for "existing vs new case" grandfathering decisions

- Clinical case and its default workload are created in the SAME transaction →
  `created_at` values are nearly identical. But the workload's
  `in_effect_since` = `contract.start_date` (a business date that can be
  backdated or future-dated), while `created_at` = insertion moment.
- `MIN(workloads.created_at)` is NOT a reliable "contract default" proxy:
  there are 8 other `CreateWorkload` call sites (workloads controller,
  approve/reprove suggested workload, `calculate_shared_schedule_hours_workload`
  ×3, `calculate_workload`, `update_clinical_case_discipline`), and cases
  created WITHOUT "aplicar prescrição padrão" get their first workload only
  at the first Vineland (`CalculateWorkload` auto-creates).
- Best proxies: `clinical_case.created_at` for "when the family/case entered";
  `MIN(in_effect_since) WHERE default_value = true` for the contract-default
  analog; `current_contract.start_date` for the contract business date.
- Workloads are immutable (create/discard) — any "first workload" query must
  decide how to treat `discarded_at`.

## clinical_case_workloads indexes (grandfathering query cost)

From `db/schema.rb:1183-1205`:

- `index_clinical_case_workloads_on_clinical_case_id` — fine for per-case scans.
- `idx_ccw_tenant_case_type` on `[tenant_id, clinical_case_id, workload_type]`
  `WHERE discarded_at IS NULL` — partial, **not** unique.
- NO index on `created_at` or `in_effect_since` — a per-case
  `MIN(created_at)`/`MIN(in_effect_since)` rides the `clinical_case_id` index
  + sort; fine per-case, costly as a full-table backfill filter.
- `workload_type` enum (`Enum::ClinicalWorkloadTypes`):
  `recommended_hours` | `shared_schedule_hours`.

## How operators are identified on the CLINICAL side (Amil)

- `General::InsuranceHealthPlan` (clinical pack,
  `packs/clinical/app/models/general/insurance_health_plan.rb`) has ONLY
  `name`, `cnpj`, `finance_insurance_health_plan_id` (1:1 with
  `clinical_case` via `has_one :health_plan`).
- `integration_alias` is NOT propagated from the finance plan. The clinical
  plan row is populated by `General::UseCases::SetInsuranceHealthPlan`
  (called from `CreateOrUpdateFamily#sync_insurance_health_plan_with_clinical`)
  with `name`, `cnpj`, `finance_insurance_health_plan_id`; it DELETES the row
  when `contracting_model == "private_contracting"`.
- Operator identification in the clinical pack is BY NAME STRING:
  ```ruby
  def bradesco_group?
    name.in?(["Bradesco Saúde", "Bradesco Saúde - Operadora", "Mediservice"])
  end
  def porto_seguro?
    name == "Porto Seguro Seguro Saúde"
  end
  ```
  Consumed by `CalculateWorkload#workload_class` (`calculate_workload.rb:160-165`)
  → BradescoWorkload / PortoWorkload / DefaultWorkload dispatch.
- Structural root cause: `packs/clinical/package.yml` depends only on
  `app` + `packs/domain_configuration`; `Finance::InsuranceHealthPlan` lives
  in `packs/operational` and the pack direction is operational → clinical.
  Clinical code CANNOT reference the finance model — hence name strings. The
  association-based leak-through (`clinical_case.child.contracts`) is not
  available from `CalculateWorkload`'s vantage without the BFF composing.
- Seeds (`db/seeds.rb:934-942`): exactly ONE Amil plan — "Amil One"
  (business_name "Amil Assitência Médica Internacional S.A.", cnpj
  29.309.127/0001-79, `integration_alias: "amil"`, FEE_FOR_SERVICE). Other
  aliases in seeds: porto, bradesco, careplus, alice, siriolibanes, omint
  (lines 916-986). No Amil factory in `spec/factories/`.
- `amil?` (`integration_alias == "amil"`,
  `packs/operational/app/models/finance/insurance_health_plan.rb:250-251`)
  has 20+ call sites on the finance/operational side only
  (`authorization_factory.rb:12,29,46`, `eligibility_factory.rb:15`,
  `invoicing_batch_mapper.rb:471`, file-service-authorization jobs/use cases,
  attendance-period rules, ...).
- Finance-side precedent for Amil scoping:
  `lib/tasks/backfill_amil_contract_category_type.rake` uses
  `Finance::InsuranceHealthPlan.where(integration_alias: "amil")` joined to
  contracts, backfilling `category_type: premium_amil`.
- A clinical-side Amil rule would follow the name-predicate pattern (e.g.
  `name == "Amil One"`). Whether other Amil plan names can appear in prod
  (making `start_with?("Amil")` necessary) is a product/data question —
  `Finance::InsuranceHealthPlan` rows per tenant must be checked in the real
  DB, seeds list only one.

## Spec territory for workload rules (test-effort estimate)

9 spec files match workload terms (8 domain + 1 tangential finance):
- `packs/clinical/spec/concepts/clinical_case_workloads/use_cases/calculate_workload_spec.rb`
  (~10 `FeatureFlag` stubs; dispatch tests live here)
- `.../use_cases/create_workload_spec.rb`
- `.../services/workload_limits_spec.rb` +
  `packs/clinical/spec/requests/api/clinical_case_workload_limits_spec.rb`
- `.../services/porto_workload_spec.rb`, `.../services/bradesco_workload_spec.rb`,
  `.../services/default_workload_spec.rb`
- `packs/clinical/spec/public/general/use_cases/create_default_workload_spec.rb`
- `packs/operational/spec/concepts/finance/use_cases/attendance_period/create_workload_change_report_pendency_spec.rb`

A new per-operator workload service mirrors the bradesco/porto specs; expect
3-5 spec files touched (new service spec + calculate_workload dispatch +
workload_limits/request specs).

## Backflow / plan-change grandfathering refinement (contract-anchored "first workload")

Follow-up to the Amil grandfathering analysis (2026-10-02): the chosen criterion
"first workload ever (`MIN(created_at)`) >= cutoff" misclassifies families that did
**backflow** (Amil → churn → Amil again) or **plan change** (Bradesco/Porto → Amil),
because their old workloads stay in the picture. Two domain facts make this concrete:

- **`ClinicalCaseWorkload` has NO `contract_id`** — only `clinical_case_id`
  (`packs/clinical/app/models/clinical_case_workload.rb`). There is no workload→contract
  link; "belongs to a contract" can only be inferred by date.
- **No workload discard on churn.** The `child_churned` subscriber only closes
  collaborator history assignments (`CloseCollaboratorChildHistoryAssignmentsByChildChurnedJob`).
  The sole workload discard is manual `DeleteWorkload` (controller). So old contracts'
  workloads remain `kept` and `MIN(created_at)` returns a stale date.

Proposed refinement (user, 2026-10-02): anchor "first workload" to the **current contract** —
`first workload WHERE created_at >= child.current_contract.start_date`, `MIN` of that.
`nil` (no workload under the current contract) still means "new family" → new regime,
preserving the "old case with no workload yet" behavior.

Two hard decisions before implementing (the logic is trivial; these are the real cost):

1. **Cross-pack read (clinical → operational).** `NewAmilRegime` lives in `packs/clinical`,
   whose `package.yml` depends only on `app` + `packs/domain_configuration`; contracts live in
   `packs/operational` (direction operational → clinical). NO clinical code currently reads
   `clinical_case.child` / `current_contract` — this would be an inédito cross-pack read. Options:
   (a) duck-typed `clinical_case.child.current_contract&.start_date` — works at runtime because the
   string association `has_one :child, class_name: "People::Child"` is already on `ClinicalCase`
   (`app/models/clinical_case.rb:42`) and packwerk does NOT flag duck-typed calls (no lexical
   `People::Contract` reference), but it is hidden coupling against the dependency direction;
   (b) sync `current_contract.start_date` into a clinical-side column via `SetInsuranceHealthPlan`
   (cleaner, but column + contract + sync + backfill).
2. **Anchor field: `created_at` vs `in_effect_since`.** The default workload is created with
   `in_effect_since = contract.start_date` (business date, backdatable — see
   `create_default_workload_if_new_contract`); clinical workloads default `in_effect_since = Time.now`.
   The existing cutoff comparison uses `created_at` deliberately to avoid backdating. A backdated
   new contract (post-cutoff sign, pre-cutoff `start_date`) classifies differently under the two fields.

Production reality (genialcare, 2026-10-02): 115 clinical cases with plan "Amil"; 12 with
multi-contract children; 7 whose first workload predates current-contract start; 27 with no
`recommended_hours` workload. All 7 affected have current-contract start Feb–Sep 2026 (pre-cutoff),
so the refinement is forward-looking — no behavior change until the cutoff passes and post-cutoff
backflow/plan-change actually occurs. Tenant lookup gotcha: `Tenant.find_by!(name: "genialcare")`
NOT `external_id` (external_id is `org_jTwTzOJkZPMDw7kw`).
