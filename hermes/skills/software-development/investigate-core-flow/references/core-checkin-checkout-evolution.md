# Checkin/Checkout & Evolution Check — Rails Core Backend

Investigated 2026-07-28. All paths relative to `projects/core/`.

## Overview

Two separate domains are involved:

- **Evolution Check** — `packs/clinical/` — Clinical domain. Records the
  assessment of intervention objectives during a session.
- **Checkin/Checkout** — `packs/operational/` — Operational domain. Records
  the physical presence/time tracking for a scheduling session.

These are **independent** — evolution checks reference `Intervention::Sessions::Session`
(clinical), while checkin/checkout reference `Scheduling::Session` (operational).
They are connected via the session model hierarchy (General::Sessions::Session →
sessionable polymorphic → Intervention::Sessions::Session or Scheduling::Session).

## Evolution Check

### Models

**`Intervention::Evolution::EvolutionCheck`**
- File: `packs/clinical/app/models/intervention/evolution/evolution_check.rb`
- Table: `intervention_evolution_checks`
- Columns: `assessed_at` (datetime), `correlation_id` (uuid, unique),
  `assessed_by_id` (fk → users), `intervention_session_id` (fk → intervention_sessions,
  **unique**), `tenant_id`
- Relations: `belongs_to :intervention_session`, `belongs_to :assessed_by` (User),
  `has_many :objective_evolution_checks` (dependent: :destroy)

**`Intervention::Evolution::ObjectiveEvolutionCheck`**
- File: `packs/clinical/app/models/intervention/evolution/objective_evolution_check.rb`
- Table: `intervention_objective_evolution_checks`
- Columns: `was_assessed`, `prerequisites` (typed array), `requisites` (typed array),
  `prompted_correct_responses_quantity`, `independent_correct_responses_quantity`,
  `evolution_scale` (decimal), `pros`, `cons`, `observations`
- Relations: `belongs_to :configuration` (optional), `belongs_to :evolution_check`,
  `belongs_to :objective` (Intervention::Pei::Objective)

### DB Constraints (the real validations)

From `db/schema.rb` lines 2422-2436:
```ruby
t.index ["correlation_id"], unique: true
t.index ["intervention_session_id"], unique: true   # ← THIS IS THE KEY CONSTRAINT
```

Migration: `db/migrate/20240509144412_add_unique_index_to_intervention_session_id.rb`
added the unique index on `intervention_session_id`.

**There are NO model-level uniqueness validations.** The DB unique index is
the sole enforcement. One `EvolutionCheck` per `Intervention::Sessions::Session`.

### Use Cases

**`Intervention::Evolution::UseCases::CreateEvolutionCheck`**
- File: `packs/clinical/app/concepts/intervention/evolution/use_cases/create_evolution_check.rb`
- 245 lines. This is the orchestrator use case.

**Flow:**
1. **Contract validation** (Dry::Validation): requires `correlation_id`, `session_id`,
   `objective_evolution_checks` (array, min_size 1) with nested objective params.
2. **Find session**: `Intervention::Sessions::Session.find(session_id)`
3. **Validate user**: must be technical_responsible OR clinician in the session
   or clinical case. Errors: `USER_NOT_A_CLINICIAN`, `CLINICIAN_NOT_IN_SESSION`.
4. **Create evolution check + process objectives** (in a transaction):
   - `evolution_check.save!` — if this fails with `RecordNotUnique`, the rescue
     tries `find_by(correlation_id:)`. If found (same correlation_id = retry),
     returns existing record as success. If not found (different correlation_id),
     returns `false`.
   - If save succeeds, delegates each objective to a sub-use-case based on
     `configuration_type`:
     - `"checklist"` → `CreateObjectiveEvolutionCheckByChecklist`
     - `"trial_counter"` → `CreateObjectiveEvolutionCheckByTrialCounter`
     - else → `CreateObjectiveEvolutionCheckWithoutConfiguration`
   - If any sub-use-case fails, collects errors and rolls back the transaction.
5. **Error handling** (`handle_errors` / `fail` step):
   - If `use_case_errors` present → formats per-objective validation errors.
   - If no use_case_errors (the `RecordNotUnique` with different correlation_id
     case) → generates the generic error:
     ```
     "Session with id #{session.id} already has an evolution check"
     code: "VALIDATION_ERROR"
     ```

### The Error: "Session already has an evolution check"

**Root cause:** Unique DB index on `intervention_session_id` in
`intervention_evolution_checks` table. One evolution check per session, enforced
at the DB level.

**Error path in code:**
1. `evolution_check.save!` (line 80) raises `ActiveRecord::RecordNotUnique`
2. Rescue (line 91-98): `find_by(correlation_id: params[:correlation_id])`
3. If different `correlation_id` → `find_by` returns nil → `return false` (line 93)
4. `false` triggers `fail :handle_errors` (line 45)
5. `handle_errors` (line 123): `use_case_errors` is empty (never processed objectives),
   falls through to the generic error message (lines 155-165)

**Idempotency:** If the same request is retried with the same `correlation_id`,
the rescue finds the existing record and returns success (lines 92-98). This is
the idempotency mechanism — same `correlation_id` = safe retry.

**Test confirming this:** `packs/clinical/spec/concepts/intervention/evolution/use_cases/create_evolution_check_spec.rb`
lines 217-253 — context "when session already has an evolution check" expects
failure with the "already has an evolution check" message.

### Sub-Use-Cases (Objective Evolution Checks)

Each creates an `ObjectiveEvolutionCheck` record with type-specific validation:

**`CreateObjectiveEvolutionCheckByChecklist`** (`configuration_type: "checklist"`)
- Validates: `evolution_scale` required when `was_assessed=true`, `requisites`
  required when assessed, consistency between requisites checked and evolution_scale.

**`CreateObjectiveEvolutionCheckByTrialCounter`** (`configuration_type: "trial_counter"`)
- Validates: `evolution_scale` and `prerequisites` required when `was_assessed=true`.

**`CreateObjectiveEvolutionCheckWithoutConfiguration`** (no configuration_type)
- Validates: `evolution_scale` required when assessed (range 0.0-1.0), `pros`
  required when scale ≠ 0.0, `cons` required when scale ≠ 1.0.

### Controller & Routes

- Controller: `packs/clinical/app/controllers/intervention/evolution_checks_controller.rb`
- Route: `POST /evolution_checks` → `Intervention::EvolutionChecksController#create`
  (routes.rb line 308: `resources :evolution_checks, only: [:create]`)
- Other routes:
  - `GET /objectives/:objective_id/evolution_checks` (line 313, index by objective)
  - `GET /evolution_checks/weekly` (line 85, weekly report by user)
- Response: Jbuilder view `packs/clinical/app/views/intervention/evolution_checks/_evolution_check.json.jbuilder`

### Controller params

```ruby
params.permit(:session_id, :correlation_id,
  objective_evolution_checks: [
    :objective_id, :configuration_id, :configuration_type, :was_assessed,
    :prompted_correct_responses_quantity, :independent_correct_responses_quantity,
    :evolution_scale, :pros, :cons, :observations,
    prerequisites: [:name, :checked],
    requisites: [:name, :checked]
  ]
)
```

## Checkin/Checkout

### Models

**`Scheduling::SessionCheckin`**
- File: `packs/operational/app/models/scheduling/session_checkin.rb`
- Table: `operational_scheduling_session_checkins`
- Columns: `checkin_at`, `session_id` (**unique index**), `checkin_by_id` (fk → users)
- Relations: `belongs_to :session`, `belongs_to :checkin_by` (User)

**`Scheduling::SessionCheckout`**
- File: `packs/operational/app/models/scheduling/session_checkout.rb`
- Table: `operational_scheduling_session_checkouts`
- Columns: `checkout_at`, `session_id` (**unique index**), `checkout_by_id` (fk → users),
  `participants` (string array, default [])
- Relations: `belongs_to :session`, `belongs_to :checkout_by` (User)

**`Scheduling::Session`** associations (file: `packs/operational/app/models/scheduling/session.rb`):
```ruby
has_one :checkin, class_name: "Scheduling::SessionCheckin", dependent: :destroy
has_one :checkout, class_name: "Scheduling::SessionCheckout", dependent: :destroy
```

### DB Constraints

From `db/schema.rb`:
- `session_checkins`: `t.index ["session_id"], unique: true`
- `session_checkouts`: `t.index ["session_id"], unique: true`

Both are 1:1 with session. No model-level uniqueness validations — DB enforces.

### Session Status Enum

File: `packs/operational/app/models/enum/scheduling/session_statuses.rb`
```ruby
SCHEDULED = "scheduled"
CANCELLED = "cancelled"
COMPLETED = "completed"
WAITING_REPLACEMENT = "waiting_replacement"
```

**No state machine.** Status transitions are done explicitly in use cases
(e.g., `CompleteSession` sets status to `completed`).

### Use Cases

**`Scheduling::UseCases::CheckinSession`**
- File: `packs/operational/app/concepts/scheduling/use_cases/checkin_session.rb`
- Flow: validate session exists → validate user is session participant →
  create `SessionCheckin` → if `RecordNotUnique`, fail with "already checked-in"
- No state change to the session status — just creates the checkin record.

**`Scheduling::UseCases::CheckoutSession`**
- File: `packs/operational/app/concepts/scheduling/use_cases/checkout_session.rb`
- Flow: validate session → validate user is participant → validate session is
  checked in (`SessionCheckin.exists?(session_id:)`) → create `SessionCheckout` →
  call `CompleteSession` (sets status to `completed`, adjusts timestamps)
- If `RecordNotUnique` on checkout create → fail with "already checked-out"
- `CompleteSession` is called with participants, started_at (from checkin or param),
  ended_at (from checkout or param), clinician_ids, update_to_assessment flag.
- **Timezone hack**: `adjust_datetime` adds UTC offset for America/Sao_Paulo
  because session start/end dates have a timezone bug (see Jira link in code).

### Endpoints (ActiveAdmin, not Rails controllers)

Checkin/checkout are exposed via **ActiveAdmin member actions**, not dedicated
controllers:

File: `packs/operational/app/admin/scheduling/session.rb`
```ruby
member_action :checkin, method: [:post] do
  # calls Scheduling::UseCases::CheckinSession.call(...)
end

member_action :checkout, method: [:post] do
  # calls Scheduling::UseCases::CheckoutSession.call(...)
end
```

Auto-generated routes (confirmed by spec):
```
POST /admin/operational_scheduling_sessions/:id/checkin.json
POST /admin/operational_scheduling_sessions/:id/checkout.json
```

There are NO Rails controllers for checkin/checkout — searching
`app/controllers/` for "checkin" or "checkout" returns nothing.

### Key Differences from Evolution Check

| Aspect | Evolution Check | Checkin/Checkout |
|--------|----------------|------------------|
| Pack | clinical | operational |
| Session type | Intervention::Sessions::Session | Scheduling::Session |
| Endpoint type | Rails controller | ActiveAdmin member action |
| Idempotency | correlation_id (UUID) | None (RecordNotUnique → error) |
| Unique constraint | intervention_session_id | session_id |
| Sub-use-cases | Yes (by configuration_type) | No |
