# Checkin/Checkout & Evolution Check Flow — clinical-panel-bff

Investigated 2026-07-28. All paths relative to `projects/clinical-panel-bff/`.

## Architecture

```
Frontend → BFF (GraphQL) → Core API (REST: /sessions, /evolution_checks, /users)
                         → Operational API (REST: /admin/operational/scheduling_sessions)
```

Both backends share the same `CORE_API_URL` base. Core datasources extend
`CoreDataSource`, operational datasources extend `OperationalDataSource` — both
are thin wrappers over `BaseDataSource` (Apollo RESTDataSource).

## Checkin/Checkout

### GraphQL Schema

**Type-defs:** `src/schema/general/checkin/type-defs.graphql`
`src/schema/general/checkout/type-defs.graphql`

```graphql
extend type Session { checkin: Checkin }
type Checkin { checkinAt: String }

extend type Session { checkout: Checkout }
type Checkout { checkoutAt: String }
```

**Mutations** (`src/schema/general/sessions/type-defs.graphql` lines 251-257):
```graphql
type Mutation {
  completeSession(sessionId: ID!, request: CompleteSessionRequestInput!): Session
  updateSession(sessionId: ID!, request: UpdateSessionRequestInput!): Session
  checkinSession(sessionId: ID!): Session
  checkoutSession(sessionId: ID!, request: CheckoutSessionRequestInput!): Session
  confirmSessions(request: ConfirmSessionsRequestInput!): ConfirmSessionsResponse!
}
```

`CheckoutSessionRequestInput`:
```graphql
input CheckoutSessionRequestInput {
  participants: [String]
  updateToAssessment: Boolean
  sessionStartedAt: String
  sessionEndedAt: String
}
```

### Resolvers

**Field resolvers** (`checkin/resolvers.js`, `checkout/resolvers.js`):
- `Session.checkin` → `schedulingSessionsApi.getScheduledSession({ id, includes: ['checkin'] })` → extract `.checkin`
- `Session.checkout` → `schedulingSessionsApi.getScheduledSession({ id, includes: ['checkout'] })` → extract `.checkout`
- Lazy-loaded: only fetched when the client queries `checkin` or `checkout` field.

**Mutations** (`sessions/resolvers.js` lines 91-130):
- `checkinSession`: fetch session from core → get `operationalSchedulingSessionId` → POST to operational checkin endpoint → re-fetch session from core → return mapped session.
- `checkoutSession`: same pattern but POST with request body (participants, updateToAssessment, sessionStartedAt, sessionEndedAt).
- Neither mutation has any BFF-side validation. All state rules (can you checkin twice? can you checkout without checkin?) are in the operational backend.

### Datasource

`src/datasources/operational/scheduling-sessions-api.js`:
```
POST   /admin/operational/scheduling_sessions/{sessionId}/checkin.json
POST   /admin/operational/scheduling_sessions/{sessionId}/checkout.json  (body: scheduling_session={...})
PUT    /admin/operational/scheduling_sessions/{sessionId}/complete.json  (body: scheduling_session={...})
PUT    /admin/operational/scheduling_sessions/{sessionId}/cancel.json    (body: scheduling_session={...})
PATCH  /admin/operational/scheduling_sessions/{sessionId}.json           (body: scheduling_session={...})
POST   /admin/operational/scheduling_sessions/batch_confirm.json
GET    /admin/operational/scheduling_sessions/{id}.json?includes[]=checkin
GET    /admin/operational/scheduling_sessions/{id}.json?includes[]=checkout
```

## Evolution Check

### GraphQL Schema

**Type-defs:** `src/schema/evolution/evolution_check/type-defs.graphql`

```graphql
type EvolutionCheck {
  id: ID!
  sessionId: ID!
  assessedAt: String!
  assessedBy: EvolutionCheckAssessedBy!
  objectiveEvolutionChecks: [ObjectiveEvolutionCheck]
}

type ObjectiveEvolutionCheck {
  id: ID!
  objectiveId: ID!
  evolutionCheckId: ID
  wasAssessed: Boolean!
  evolutionScale: Float
  pros: String
  cons: String
  createdAt: String
  updatedAt: String
}

input CreateEvolutionCheckInput {
  sessionId: ID!
  correlationId: ID
  objectiveEvolutionChecks: [CreateObjectiveEvolutionCheckInput!]!
}

type Mutation {
  createEvolutionCheck(request: CreateEvolutionCheckInput!): EvolutionCheck!
}

type ClinicalCase { weeklyEvolutionChecks: [EvolutionCheck] }
type User { weeklyEvolutionChecks(clinicalCaseIds: [ID!]): [EvolutionCheck] }
type Objective { evolutionChecks(order: EvolutionCheckOrder, limit: Int): [ObjectiveEvolutionCheck] }
```

**Embedded in sessions** (`sessions/type-defs.graphql` lines 113-126):
```graphql
type EvolutionCheck {
  id: ID!
  assessedAt: String!
  assessedBy: EvolutionCheckAssessedBy!
}

type InterventionSessionable {
  id: ID!
  sessionType: SessionTypes!
  suggestedNote: SuggestedNote
  suggestedChildProgressionNote: SuggestedChildProgressionNote
  evolutionCheck: EvolutionCheck       # no custom resolver — from core response
  clinicalGuidanceRegistryId: ID
}
```

Note: the `EvolutionCheck` type in `sessions/type-defs.graphql` is a simplified
version (no `sessionId`, no `objectiveEvolutionChecks`). The full type is in
`evolution/evolution_check/type-defs.graphql`. Apollo merges them via
`extend type` or name collision — the schema composition resolves this.

### Resolvers

**`evolution/evolution_check/resolvers.js`:**
- `ClinicalCase.weeklyEvolutionChecks` → `usersApi.weeklyEvolutionChecks({ clinicalCaseIds: [id] })`
- `Objective.evolutionChecks` → `evolutionChecksApi.getObjectiveEvolutionChecks({ objectiveId, limit, order })`
- `Mutation.createEvolutionCheck` → `evolutionChecksApi.create(request)` (no validation, no dedup check)
- `User.weeklyEvolutionChecks` → `usersApi.weeklyEvolutionChecks({ clinicalCaseIds })`

**`InterventionSessionable.evolutionCheck`:** No custom resolver. The value
comes from the core session response (field `sessionable.evolution_check`),
converted to camelCase by `transformResponse`.

### Configuration

`src/schema/evolution/evolution_check/library/evolution_check_configurations/`:
```graphql
union EvolutionCheckConfiguration =
    TrialCounterEvolutionCheckConfiguration
  | ChecklistEvolutionCheckConfiguration

type LibraryObjective {
  currentEvolutionCheckConfiguration: TrialCounterEvolutionCheckConfiguration
  evolutionCheckConfiguration: EvolutionCheckConfiguration
}
```
Resolved via `evolutionCheckConfigurationsApi.getByLibraryObjectiveId` using
DataLoader for batched requests.

### PEIS filter

`src/schema/peis/type-defs.graphql` line 532:
```graphql
input ObjectivesInputFilter {
  statuses: [ObjectiveStatus]
  protocolsIds: [ID]
  byEvolutionCheckRule: Boolean
}
```
Used in `objectives(clinicalCaseId: ID!, filters: ObjectivesInputFilter)` query
to filter objectives by whether they have an evolution check rule configured.

### Datasource endpoints

```
POST   /evolution_checks.json                                     (create)
GET    /objectives/{objectiveId}/evolution_checks.json            (list by objective)
GET    /users/evolution_checks/weekly.json?clinical_case_ids=[...] (weekly by clinical case)
GET    /library/evolution_check_configurations.json?library_objective_ids=[...]
```

## Key finding: No dedicated "has evolution check" query

There is no dedicated endpoint to check if a session already has an evolution
check. The available approaches are:

1. **Via `session(id)`**: Query `sessionable { ... on InterventionSessionable { evolutionCheck { id } } }`.
   Returns null if no evolution check exists.
2. **Via `weeklyEvolutionChecks`**: Returns all evolution checks for the week for
   a clinical case. Each has `sessionId` — filter client-side.
3. **Via `Objective.evolutionChecks`**: Lists checks per objective, not per session.

The `createEvolutionCheck` mutation does NOT check for duplicates — it passes
straight through to `POST /evolution_checks.json` on the core. Any dedup logic
must be in the core backend.
