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

- **DataLoader**: Some datasources (e.g. `EvolutionCheckConfigurationsApi`) use
  DataLoader for batched requests to avoid N+1 queries.

- **Union types & `__resolveType`**: `Sessionable` is a union resolved by
  `sessionType` field. `EvolutionCheckConfiguration` is resolved by
  `configurationType`.

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

## References

- `references/clinical-panel-bff-checkin-checkout-evolution.md` — Detailed findings
  from the checkin/checkout + evolution check investigation (queries, mutations,
  endpoints, data flow diagram).
