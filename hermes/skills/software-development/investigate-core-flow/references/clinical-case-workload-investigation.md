# Clinical Case Workload Investigation

Investigation of `ClinicalCaseWorkload` for the feature: "Add
`last_modified_by` (name of who made the last modification) to clinical
case workloads."

## Model: ClinicalCaseWorkload

- **File**: `packs/clinical/app/models/clinical_case_workload.rb`
- **Table**: `clinical_case_workloads` (UUID PK, `db/schema.rb:1155`)
- **Inheritance**: `ApplicationRecordTenant` (multi-tenant)
- **Includes**: `Discard::Model` (soft delete, `default_scope { kept }`)

### DB columns

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | `gen_random_uuid()` default |
| `clinical_case_id` | uuid | NOT NULL, FK |
| `workload_type` | string | enum: `recommended_hours`, `shared_schedule_hours` |
| `discipline` | string | enum: `Enum::ExtendedClinicalDisciplines` |
| `hours` | interval | validated 0–50h |
| `minutes` | integer | auto-set via `before_save :set_minutes` |
| `in_effect_since` | datetime | when this workload takes effect |
| `change_reason` | string | NOT NULL, default `""` |
| `default_value` | boolean | default false |
| `suggested_workload_id` | uuid | FK → `assessments_suggested_workloads` |
| `created_by_id` | uuid | FK → `users`, nullable (added 2025-09-03) |
| `tenant_id` | uuid | NOT NULL |
| `created_at` | datetime | NOT NULL |
| `updated_at` | datetime | NOT NULL |
| `discarded_at` | datetime | Discard soft-delete column |

### Associations

- `belongs_to :clinical_case`
- `belongs_to :suggested_workload` (optional, `dependent: :destroy`)
- `belongs_to :created_by` (class_name: "User", optional: true)
- **No `updated_by` association** — does not exist on this model

### Key behavior

- **No update route**: Controller uses `except: [:show, :edit, :update]`.
  Lifecycle is create → discard. New "version" = new record with new
  `in_effect_since`.
- `before_save :set_minutes` — converts `hours` (interval) to integer minutes
- Multiple class methods for querying "current" recommended/shared hours by
  discipline and date

## Entry points

### Routes (`config/routes.rb:150`)

```ruby
resources :clinical_case_workloads, path: "workloads", as: "workloads",
  except: [:show, :edit, :update] do
  get :in_effect, on: :collection
end
scope module: :clinical_case_workloads do
  resource :workload_limits, only: [:show]
end
```

Nested under `clinical_cases/:clinical_case_id/`.

### Controller

`packs/clinical/app/controllers/clinical_case_workloads_controller.rb`
- `index` — returns `recommended_hours_history` scope
- `new` — builds empty workload
- `create` — calls `ClinicalCaseWorkloads::UseCases::CreateWorkload`
- `destroy` — calls `ClinicalCaseWorkloads::UseCases::DeleteWorkload`
- `in_effect` — returns workloads active at current date

### BFF (Node.js GraphQL)

`projects/clinical-panel-bff/`:
- `src/datasources/core/clinical-cases-api.js` — HTTP calls to
  `/clinical_cases/:id/workloads.json` and `.../in_effect.json`
- `src/schema/workloads/resolvers.js` — GraphQL resolvers:
  `ClinicalCase.workloads`, `workloadsInEffect`, `sharedScheduleWorkloads`,
  `Query.clinicalCaseWorkloads`, `Mutation.createClinicalCaseWorkload`

## Use cases

### CreateWorkload (`packs/clinical/app/concepts/clinical_case_workloads/use_cases/create_workload.rb`)

Trailblazer activity with Dry::Validation contract. Steps:
1. Find ClinicalCase
2. `build_workload` — builds with `created_by: current_user`
3. `validate_limits` — checks `Services::WorkloadLimits` per discipline
4. `save_workload`
5. `build_event` → `WorkloadCreated` → `EmitEvent`

Contract requires: `clinical_case_id`, `workload_type`, `discipline`,
`hours` (integer), `change_reason`. Optional: `in_effect_since`,
`default_value`, `suggested_workload_id`.

### DeleteWorkload (`packs/clinical/app/concepts/clinical_case_workloads/use_cases/delete_workload.rb`)

Simple Railway: find clinical_case → `workload.discard` → emit
`WorkloadDeleted`. Does NOT receive or set `current_user`.

## Events

- **WorkloadCreated** (`.../events/workload_created.rb`): topic
  `clinical_case.workload.v1`, carries `clinical_case_id`, `workload_id`,
  `workload_type`, `discipline`, `minutes`, `in_effect_since`,
  `change_reason`, `default_value`
- **WorkloadDeleted** (`.../events/workload_deleted.rb`): same topic,
  carries `clinical_case_id`, `workload_id`

Neither event carries `created_by` or any user identifier.

## JSON output

`_workload.json.jbuilder` (partial used by index, show, in_effect):
```ruby
json.extract! workload, :id, :clinical_case_id, :workload_type,
  :discipline, :in_effect_since, :change_reason, :created_at, :updated_at
json.hours workload.hours.iso8601
```

No `created_by` or user name is exposed in the JSON.

## Audit field patterns in the codebase

### `TrackCreationBy` concern (`app/models/concerns/track_creation_by.rb`)

Auto-assigns `created_by` (create only) and `updated_by` (every save)
from `Current.user`. ClinicalCaseWorkload does NOT use this concern —
it defines `created_by` manually.

### `updated_by` in other clinical models

Used in: `Intervention::Note`, `Intervention::SessionActivity`,
`Intervention::Pei::Program`, `Intervention::Pei::Target`,
`Intervention::Pei::Strategy`, `Intervention::Pei::ProgramStrategy`,
`Intervention::Pei::SpeechTherapyProgram`,
`Intervention::Pei::OccupationalTherapyProgram`,
`Intervention::Pei::SensorialFunction`, `Documents::ClinicalCaseFile`.

Pattern: `belongs_to :updated_by, class_name: "User"` + set explicitly
in use case (e.g. `record.update(updated_by: current_user)`).

### `Current` (`app/models/current.rb`)

```ruby
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :authenticated_user
end
```

Canonical source of the current user across the request cycle.

## Key insight for "last_modified_by" feature

The feature asks for a **name** (string) of who made the last
modification. This is ambiguous because:

1. **No update action exists** — workloads are create/discard only
2. **"Last modification"** could mean: (a) who created the current
   workload, (b) who discarded the previous one, or (c) a new field
   to populate on both create and discard
3. **The codebase pattern is FK → users**, not denormalized name strings
4. `created_by_id` already exists but is not exposed in JSON or events
5. `DeleteWorkload` does not receive `current_user` — would need to be
   threaded through if "who discarded" matters

## Migrations history

| Date | Migration | What |
|------|-----------|------|
| 2022-05-26 | `create_clinical_case_workloads` | Initial table |
| 2022-06-15 | `change_workload_hours_type` | Changed hours to interval |
| 2022-06-15 | `add_in_effect_since_date...` | Added `in_effect_since` |
| 2023-06-02 | `add_change_reason...` | Added `change_reason` (NOT NULL) |
| 2023-06-02 | `adjust_change_reason...` | Made NOT NULL with default `""` |
| 2024-10-08 | `add_minutes_column...` | Added `minutes` integer |
| 2025-01-23 | `add_discarded_at_to_workloads` | Added Discard column |
| 2025-08-13 | `add_default_value...` | Added `default_value` boolean |
| 2025-09-03 | `add_created_by_to_workload` | Added `created_by_id` FK → users |

## Exposing `created_by` in JSON: the clinical_case_preferences pattern

The canonical pattern for exposing `created_by` / `updated_by` as a
nested object is in
`packs/clinical/app/views/preferences/clinical_case_preferences/_clinical_case_preferences.json.jbuilder`:

```ruby
json.created_by do
  json.id clinical_case_preferences.created_by.id
  json.name clinical_case_preferences.created_by&.clinician&.name
end
json.updated_by do
  json.id clinical_case_preferences.updated_by.id
  json.name clinical_case_preferences.updated_by&.clinician&.name
end
```

- The **name** comes from `user.clinician.name` (User has_one :clinician)
- Safe navigation (`&.`) is used on the `clinician` lookup but NOT on the
  `.id` call — assumes `created_by` is present. If `created_by` can be
  NULL (as on `ClinicalCaseWorkload` for old records), the partial must
  guard the entire block: `if workload.created_by.present?`
- The `_workload.json.jbuilder` partial currently does NOT expose
  `created_by` — it only extracts `:id, :clinical_case_id, :workload_type,
  :discipline, :in_effect_since, :change_reason, :created_at, :updated_at`

## Exposing `created_by` in events: the clinical_case_preferences pattern

The `ClinicalCasePreferencesCreated` and `ClinicalCasePreferencesUpdated`
events include `updated_by_id` as an attribute and populate it in
`build_from`:

```ruby
attribute :updated_by_id

def self.build_from(clinical_case_preference)
  build(
    ...,
    updated_by_id: clinical_case_preference.updated_by.id
  )
end
```

`WorkloadCreated` and `WorkloadDeleted` do NOT include `created_by` or
any user identifier in their event payloads. Adding it would require
adding an `attribute :created_by_id` and populating it in `build_from`.

## Workload event subscribers (full list)

All subscribers for topic `clinical_case.workload.v1`:

**In `event_consumer_start.rb` (root registry):**
- `core-workload-created-changed-schedule-offer-sub` →
  `Marketplace::ScheduleOffersProcessingByEvent` (workload_created)
- `core-workload-deleted-changed-schedule-offer-sub` →
  `Marketplace::ScheduleOffersProcessingByEvent` (workload_deleted)
- `core-process-shared-schedule-workload-created-sub` →
  `CalculateSharedScheduleHoursWorkload` (workload_created only)

**In pack-local subscribers:**
- `packs/operational/app/infra/subscribers/finance/finance_subscriber.rb`:
  `core-create-tp-workload_created-sub` → `Finance::CreateTherapeuticPlan`
  (workload_created only — triggers therapeutic plan creation)
- `packs/operational/app/infra/subscribers/scheduling/agendas/agenda_subscriber.rb`:
  `core-workload_created-calc-child-agenda-sub` and
  `core-workload_deleted-calc-child-agenda-sub` → `Agenda::CalculateChildAgendaJob`

## Supervision CDC: how data flows to the data warehouse

**Critical distinction**: The supervision project does NOT consume PubSub
events. It uses **Google Cloud Datastream** — a CDC mechanism that
replicates PostgreSQL table changes directly to Google Cloud Storage,
which BigQuery external tables then read.

### Architecture

```
PostgreSQL (core DB)
    ↓ Datastream CDC (streams table changes)
GCS: gs://genialcare-event-store-{env}/streams/database-events/core/public_{table_name}/*
    ↓ BigQuery external tables (Dataform definitions)
BigQuery (supervision project)
    ↓ Dataform transformations
BigQuery reporting tables (bronze/silver/gold)
```

### Supervision project structure

```
supervision/
  definitions/           # Dataform SQLX definitions
    datasources/         # BigQuery external table declarations (CDC sources)
    assessment/          # Domain-specific transformed tables
    intervention/        # Domain-specific transformed tables
  includes/              # Shared table metadata (column docs, assertions)
    assessments/tables/  # Table schema definitions for assessments domain
    intervention/tables/ # Table schema definitions for intervention domain
  deploy/                # Kubernetes deployment configs (Dataform, BigQuery, PubSub)
  bigquery/              # BigQuery schema definitions (Python)
  build/                 # Python Dataflow pipeline code (legacy)
```

### CDC table pattern (example: suggested_workload)

Each CDC-backed table in supervision has two files:

1. **Events file** (`*_events.sqlx`) — declares a BigQuery external table
   that reads from GCS:
   ```sql
   config {
     type: "operations",
     name: "suggested_workload_events",
     description: "Raw suggested workload events from datastream CDC.",
     hasOutput: true,
     schema: "raw"
   }
   CREATE OR REPLACE EXTERNAL TABLE ${self()}
   WITH CONNECTION `us-east1.supervision` OPTIONS(
     format = "JSON",
     uris = ['gs://genialcare-event-store-${dataform.projectConfig.vars.env}/streams/database-events/core/public_assessments_suggested_workloads/*'],
     ignore_unknown_values = TRUE,
     max_staleness = INTERVAL 2 HOUR,
     metadata_cache_mode = "AUTOMATIC"
   );
   ```

2. **Table file** (`*.sqlx`) — transforms raw events into a clean table:
   ```sql
   config { ...tables.suggested_workload }
   WITH events AS (${functions.renderEventTable(ref("suggested_workload_events"))})
   SELECT events.id, events.clinical_case_id, ...
   FROM events
   WHERE rnk = 1 AND is_deleted IS FALSE
   ```

### Key implications for features

- **Datastream replicates ALL columns** from the PostgreSQL table
  automatically — if `created_by_id` exists in the DB, it's already in
  the CDC stream. No event payload change needed for CDC.
- **No `clinical_case_workloads` table exists in supervision** — only
  `suggested_workload` is defined. Adding workload data to supervision
  requires creating the `_events.sqlx` and `.sqlx` definition files
  following the pattern above, with the GCS URI path
  `core/public_clinical_case_workloads/*`.
- **Event payloads (PubSub) are separate from CDC (Datastream)** —
  changing what's in the `WorkloadCreated` event does NOT affect what
  supervision sees. Supervision sees the raw DB row, not the event
  payload.
- **If supervision needs the user NAME** (not just `created_by_id`),
  it would need a JOIN with a users table or a separate CDC stream for
  `users`.

## CreateDefaultWorkload: system_user as created_by

`packs/clinical/app/public/general/use_cases/create_default_workload.rb`
creates workloads with `current_user: dev_user` where `dev_user` returns
`User.system_user`. This means workloads created via automated/default
flows have `created_by = system_user`, not a real clinician. Exposing
`created_by` for these records will show the system user's name.

## CalculateWorkload: current_user threading

`CalculateWorkload` (triggered by `vineland_report_created` event) calls
`CreateWorkload` internally. The event consumer in
`event_consumer_start.rb` maps the event data to a use case call but
does NOT pass `current_user` — it only passes
`{ "vineland_report_id" => data[:vineland_report_id] }`. This means
`CalculateWorkload` needs to either find a user from the vineland report
context or fall back to a system user. Check the use case implementation
to verify how `current_user` is resolved in this flow.
