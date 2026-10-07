---
name: investigate-bff-flow
description: "Investigate GraphQL flows in GenialCare BFFs."
---

# investigate-bff-flow

GenialCare BFFs (Backend-for-Frontend) are Apollo GraphQL Node.js servers that
proxy and orchestrate calls between the frontend and two backend systems:

- **Core API** — Rails monolith (`CORE_API_URL`), endpoints under `/sessions.json`,
  `/evolution_checks.json`, `/users/...`, `/clinical_cases/...`, etc.
- **Operational API** — Rails scheduling/operational app (same `CORE_API_URL`
  base, different path prefix `/admin/operational/...`), handles scheduling
  sessions, checkin/checkout, confirmations, invoices, etc.

The BFF itself contains almost no business logic. It transforms formats
(snake_case ↔ camelCase), routes requests between the two backends, and
maps/enriches responses. All validation, state management, and domain rules
live in the core/operational backends.

## When to load this skill

- User asks to "investigar o fluxo de X no BFF"
- User asks what queries/mutations exist for a domain area
- User asks how the BFF communicates with the core
- User asks whether the BFF has validation or state logic for a feature
- User references `clinical-panel-bff` or another GenialCare BFF project

## BFF project structure

```
src/
  schema/                    # GraphQL schema (type-defs + resolvers per domain)
    <domain>/
      type-defs.graphql      # GraphQL types, inputs, queries, mutations
      resolvers.js           # Resolver functions
      mapper.js              # (optional) response mapping/transformation
      <sub-domain>/          # nested domain modules
  datasources/
    index.js                 # Registers all datasources → injected as context.dataSources
    base-datasource.js       # RESTDataSource base (handles 404→NOT_FOUND, 403→FORBIDDEN)
    core/                    # Core API datasources (extends CoreDataSource)
      core-datasource.js     # Sets baseURL = CORE_API_URL
      sessions-api.js
      evolution/...
      ...
    operational/             # Operational API datasources (extends OperationalDataSource)
      operational-datasource.js  # Sets baseURL = CORE_API_URL (same host, different paths)
      scheduling-sessions-api.js
      ...
```

## Investigation procedure

1. **Find GraphQL type-defs.** Search for `*.graphql` files in `src/schema/`:
   ```
   search_files pattern="*.graphql" target="files" path=".../clinical-panel-bff/src/schema"
   ```
   Each domain module has a `type-defs.graphql` with types, inputs, queries,
   and mutations. Schema is composed via `extend type` across modules.

2. **Read the resolvers.** Each `type-defs.graphql` has a sibling `resolvers.js`.
   Resolvers destructure `dataSources` from context — this is your map to which
   datasource (and therefore which backend) serves each field.

3. **Trace to datasources.** Open the datasource files referenced in resolvers.
   Datasource class names map to context keys via camelCase:
   `SchedulingSessionsApi` → `dataSources.schedulingSessionsApi`.
   Check `datasources/index.js` for the full registry.

4. **Identify REST endpoints.** Datasource methods call `this.get/post/put/patch`
   with explicit URL paths. Record the HTTP method, path, and request body shape.
   Core datasources hit paths like `/sessions/{id}.json`; operational datasources
   hit paths like `/admin/operational/scheduling_sessions/{id}/checkin.json`.

5. **Check for mappers.** Some domains have a `mapper.js` alongside resolvers.
   Mappers transform core responses (snake_case) into BFF schema shapes
   (camelCase, enum descriptions, computed fields). `transformResponse` in
   `src/schema/utils.js` does generic snake_case→camelCase recursively.

6. **Assess business logic.** Look for:
   - **Validation**: `validateContextDate` in sessions is one of the few examples.
   - **State checks**: almost none — the BFF trusts the backend to enforce state.
   - **Orchestration**: some mutations do multi-step (fetch session → call
     operational → re-fetch session), but no conditional branching beyond
     cancelled-vs-completed.
   - **Default field resolvers**: if a field in a type-def has no custom resolver,
     it's resolved by the default Apollo resolver from the (already camelCased)
     core response. This is common for embedded objects like
     `InterventionSessionable.evolutionCheck`.

   - **`createdBy` / `updatedBy` field exposure**: Two patterns exist:
     **(A) Implicit** — no field resolver; `transformResponse` converts
     `created_by` → `createdBy` and Apollo's default resolver serves it (e.g.
     `ClinicalCasePreferences.updatedBy`). **(B) Explicit** — a field resolver
     with destructuring acts as a whitelist (e.g. `ComplexityScore.createdBy`).
     Each schema defines its own user type (`UpdatedByUser`, `ComplexityScoreUser`,
     `DocumentUser`, etc.) — there is no shared generic `User` type. These fields
     are never in mutation inputs; the Core API sets them server-side via the auth
     token. See `references/created-by-updated-by-bff-patterns.md` for the full
     pattern catalog, naming convention table, and investigation checklist.

7. **Check tests for behavior.** Integration tests in `src/__tests__/integration/`
   mirror the schema structure. They stub core/operational HTTP responses and
   assert the GraphQL output. Tests reveal the expected core response shapes
   (snake_case) and confirm no hidden BFF logic.

## Key patterns

- **Dual identity**: Sessions have a core ID and an `operationalSchedulingSessionId`.
  Mutations first fetch the session from core to get the operational ID, then
  call the operational API.

- **`includes` parameter**: Field resolvers for `Session.checkin`, `Session.checkout`,
  `Session.confirmations` fetch the scheduling session with `includes: ['checkin']`
  etc. This is a lazy-loading pattern — the BFF only fetches the operational
  data when the client queries that specific field.

- **`transformResponse`**: Recursively converts snake_case keys to camelCase.
  Applied in most resolvers via `.then(transformResponse)`.

- **`transformInput`**: Converts camelCase input to snake_case for outgoing
  requests to the core. Applied in datasource methods.

- **Rails multiparameter duration encoding**: duration-typed inputs (GraphQL
  `hours: Int`) are sent to the core as Rails multiparameter attributes —
  `'hours(4i)': <int>` (hours) + `'hours(5i)': 0` (minutes) — e.g. the
  `clinical_case_workload` body in `createWorkload` and the `workload_input`
  body in `reproveSuggestedWorkload` (`datasources/core/clinical-cases-api.js`
  and `.../assessments/suggested-workload-api.js`). The core returns durations
  as ISO 8601 strings (`"PT10H"`), which the frontend parses with
  `dayjs.duration(hours).asHours()`. When adding any duration-typed input,
  copy this encoding and confirm the exact body shape in the domain's
  integration spec (`src/__tests__/integration/...`).

- **DataLoader**: Some datasources (e.g. `EvolutionCheckConfigurationsApi`) use
  DataLoader for batched requests to avoid N+1 queries.

- **Resolve a referenced `Objective` / `LibraryObjective` by id — prefer the DataLoader datasources (no `clinicalCaseId` needed)**: There are two Objective datasources with different signatures: `clinicalCasesApi.objectiveById(id, clinicalCaseId)` (hits `GET /clinical_cases/{clinicalCaseId}/objectives/{id}.json`, requires `clinicalCaseId`) vs `objectivesApi.findById(id)` (a DataLoader hitting `POST /objectives/query.json` with `{ids}`, no `clinicalCaseId`). When writing a BFF **field resolver** that resolves an Objective referenced by id (e.g. `AssessmentRelatedObjective.peiObjective`), use `objectivesApi.findById(parent.peiObjectiveId)` — it avoids plumbing `clinicalCaseId` through the whole GraphQL contract (the core response, the type, the resolver args). Likewise `libraryObjectivesApi.findById(id)` (DataLoader → `POST /library/objectives/query.json`) resolves a `LibraryObjective` by id. Both DataLoaders return raw snake_case core objects — apply `.then(transformResponse)`. This is the clean pattern for making a `{ libraryObjective, peiObjective }`-style composable shape instead of a flat `{ id, description, status }` mashup.

- **Union types & `__resolveType`**: `Sessionable` is a union resolved by
  `sessionType` field. `EvolutionCheckConfiguration` is resolved by
  `configurationType`.

## Investigation output format

When the user asks for a read-only investigation ("investigue", "mapeie o
território", "NÃO escreva código"), they expect:

- A markdown file saved to a path they specify (typically under
  `documentations/user_stories/<story-id>/investigation-bff.md`).
- A specific section structure: Tipo de projeto, Pontos de entrada, Fluxo
  principal, Schema GraphQL, Padrões existentes, Constraints, Dependências
  identificadas, Pontos de atenção.
- **No implementation decisions, no code writing** — only territory mapping.
- After saving, return only: `Sumário salvo em <caminho>` — no preamble,
  no summary, no follow-up questions.

## Pitfalls

- **Don't assume the BFF validates.** It almost never does. If you need to know
  whether a state transition is allowed, look at the core/operational backend.
- **Don't forget the operational backend.** Some flows (checkin, checkout,
  scheduling) live in a separate API under `/admin/operational/`. The BFF
  orchestrates between core and operational — missing this leads to confusion
  about where data comes from.
- **Default resolvers hide data flow.** When a field has no custom resolver,
  the data comes from the core response directly (after camelCase conversion).
  Check the core API response shape to understand what's available.
- **Schema is modular.** Types like `Session`, `ClinicalCase`, `Objective` are
  extended across multiple modules. Search all `type-defs.graphql` files for
  `extend type Session` to find all fields.
- **Field name / GraphQL type does NOT determine scoping.** A field can hang
  off one type but resolve to a user-scoped endpoint. Example: the field
  `ClinicalCase.weeklyEvolutionChecks` *sounds* "scoped by case", but its BFF
  resolver calls `usersApi.weeklyEvolutionChecks({ clinicalCaseIds: [id] })`,
  which hits `GET /users/evolution_checks/weekly.json` — a core controller that
  ALWAYS filters by `authenticated_user.clinician.id`
  (`core/packs/clinical/app/controllers/users/evolution_checks_controller.rb`,
  `.by_session_clinician(clinician_id)`). So that field was already scoped by
  the logged-in clinician, not by case. Two "sibling" fields
  (`clinicalCase.X` vs `user.X(args)`) can resolve to the SAME endpoint with
  the SAME scope — swapping one for the other is a functional no-op (and, if it
  adds a second round-trip, a performance regression). Before accepting a
  PR/issue that claims "field X is not scoped by Y", trace resolver →
  datasource → core controller and confirm the real scope; the resolver often
  re-hangs a field on a different type than the endpoint it actually delegates
  to, so the type name is misleading.\n- **Nullability is declared in the type-defs.** A field typed `String!`/`Type!`
  (non-null) can never be `null`/`undefined` at the resolver — Apollo throws a
  "non-null field" error before the resolver return is delivered. So a
  null-guard (`?? ''`, `?? default`, `if (!x)`) on a non-null field is dead
  code. Before adding — or accepting a reviewer's suggestion for — defensive
  null-handling, check the `!` on the field in `type-defs.graphql`. Conversely,
  a field typed without `!` (nullable) genuinely can be null and may need a
  guard. This is the single most common false-positive in Gemini Code Assist
  review comments on BFF resolvers.

## References

- `references/clinical-panel-bff-checkin-checkout-evolution.md` — Detailed findings
  from the checkin/checkout + evolution check investigation (queries, mutations,
  endpoints, data flow diagram).
- For the three evolution-check types (trial_counter, checklist,
  without_configuration), their validation rules, and discipline-to-type mapping,
  see the core skill's `references/evolution-check-types-and-disciplines.md`
  (load `investigate-core-flow` skill). For the frontend UI layer (component
  decision tree, i18n labels, screen layout per type), see the core skill's
  `references/evolution-check-ui-components.md`.
- For **cross-stack field tracing** — tracing whether a specific field exists
  across all three layers (frontend → BFF → core → DB) — see the core skill's
  `references/cross-stack-field-tracing.md` (load `investigate-core-flow` skill).
  Includes the top-down procedure, gap synthesis table format, and patterns for
  "who modified/created X" features (TrackCreationBy concern, two `updatedBy`
  GraphQL shapes, create-only entities).
