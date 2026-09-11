# Worked example: "cancelamento com antecedência pela cuidadora"

Full trace of a read-only domain-investigation question, end to end, using the MCP metabase tools
then falling back to the `core` repo for the definition.

## 1. Find the tables (search)

`search` with `term_queries: ["cancelamento", "cancel", "sessao", "session"]` surfaced the relevant
tables (note `semantic_queries` returned empty — stick with `term_queries`):

- `scheduling.fct_sessions` (table id 4030, database_id 11) — the fact table.
- `events.session_cancelled` (table id 7265, database_id 17) — the event/CDC table.
- `scheduling.sessions`, `int_sessions`, `fct_sessions_historical`, `sessions_events*`, etc.

## 2. Read the fields (get_table with-fields)

`get_table(id=4030, with-fields=true)` revealed the defining columns:

- `cancellation_requested_by_role` (`type/Text`, semantic `type/Category`) — the "who".
- `cancellation_in_advance` (`type/Boolean`) — the "with notice?" flag.
- `cancellation_reason` (`type/Text`, Category), `cancelled_at`, `started_scheduled_at`.

Same shape on the event table: `requested_by_role` + `in_advance`.

## 3. Enumerate the role enum (get_table_field_values)

`get_table_field_values(id=4030, field-id="t4030-33")` →
`field_values: [null, "", "caregiver", "clinician", "external_professional", "genial", "genial_automation"]`.

"Cuidadora" = `caregiver`. On `curated_requested_by_role` (`t4030-43`) the same values are
translated: `"Família"` (=caregiver), `"Genial"`, `"Terapeuta"`, `"NA"`, `"Pendente"`,
`"Sessão realizada"`.

## 4. Sample real rows (query)

`query(table_id=4030, fields=[...], filters=[{field_id:"t4030-33", operation:"equals",
value:"caregiver"}], limit=10)` showed the pattern:

- `cancellation_in_advance=true` rows → `started_scheduled_at` days/hours after `cancelled_at`.
- `cancellation_in_advance=false` rows → `cancellation_reason = "caregiver_did_not_attend"`,
  with `cancelled_at` recorded AFTER `started_scheduled_at` (the absence was logged post-hoc).

## 5. The flag's MEANING lives in core code, not the schema

The Metabase schema has no threshold for `cancellation_in_advance` — it's a computed boolean.
Tracing `core` for the field name:

- `packs/operational/app/concepts/scheduling/use_cases/cancel_session.rb` — `assert_in_advance_cancellation`
  resolves `Scheduling::Config::AdvanceCancellationConfig.instance.get_configuration(...)` then
  calls `config.in_advance?(now:, session_started_at:)`; an explicit `params[:in_advance]`
  overrides the rule (admin override).
- `packs/operational/app/models/scheduling/config/advance_cancellation_config.rb` — default
  `{"mode" => Enum::Scheduling::AdvanceCancellationModes::DAY_BEFORE}`.
- `.../scheduling/config/advance_cancellation/dto.rb` — the actual rule:
  - `day_before`: `now.to_date < session_started_at.to_date` (America/Sao_Paulo) — i.e. cancel on
    any day BEFORE the session day counts as "in advance".
  - `hours_before`: `now <= session_started_at - advance_cancellation_hours.hours` (e.g. 8, 24, 48).
- Configurable per `location` / `discipline` / `insurance_health_plan`
  (`configuration_advance_cancellation_config_records`).
- `enum/scheduling/request_cancellation_roles.rb` — the role constants (`CAREGIVER = "caregiver"`).
- `enum/scheduling/cancellation_reasons.rb` — the reason enum + which reasons are enabled per role
  (`caregiver_did_not_attend` is a `clinician`-entered reason, explaining why those rows have
  `in_advance=false`).

## Bottom line

"cancelamento com antecedência pela cuidadora" =
`cancellation_requested_by_role = 'caregiver'` AND `cancellation_in_advance = true`, where the
boolean follows the configured `AdvanceCancellationConfig` rule (`day_before` by default).
