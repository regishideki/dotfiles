# BFF Patterns: createdBy / updatedBy Field Exposure

Findings from investigating how `createdBy` and `updatedBy` fields are exposed
across multiple domain schemas in `clinical-panel-bff`.

## Two patterns for exposing user-type fields

### Pattern A: Implicit (no field resolver)

The field comes as a nested object from the Core API (snake_case), and
`transformResponse` converts it to camelCase automatically. No custom resolver
is needed — Apollo's default resolver picks up the already-camelCased key.

**Example**: `ClinicalCasePreferences.updatedBy`

```graphql
type UpdatedByUser {
  id: ID!
  name: String
}

type ClinicalCasePreferences {
  ...
  updatedBy: UpdatedByUser!
  updatedAt: String!
}
```

- No resolver entry for `updatedBy` in `resolvers.js`.
- Core API returns `updated_by: { id, name }`.
- `transformResponse` converts to `updatedBy: { id, name }`.
- Apollo default resolver serves it directly.

### Pattern B: Explicit field resolver with destructuring

A field resolver explicitly maps the object, returning only the fields declared
in the GraphQL type.

**Example**: `ComplexityScore.createdBy`

```javascript
const resolvers = {
  ComplexityScore: {
    createdBy: ({ createdBy }) => ({
      id: createdBy.id,
      name: createdBy.name,
    }),
  },
  // ...Query, Mutation
};
```

```graphql
type ComplexityScoreUser {
  id: ID!
  name: String
}

type ComplexityScore {
  ...
  createdBy: ComplexityScoreUser!
}
```

- Explicit resolver in `resolvers.js` under the type key.
- Same Core API shape (`created_by: { id, name }`), same `transformResponse`.
- Resolver acts as a field whitelist / explicit mapping.

**When to use which**: Pattern A is simpler and works when the Core API response
shape exactly matches the GraphQL type. Pattern B is useful when you want to
explicitly document the contract, filter fields, or when the response shape
differs from the GraphQL type.

## Naming convention: per-schema user types

Each schema defines its own user type — there is **no shared generic `User` type**.

| Schema | Type name | Shape |
|---|---|---|
| clinical_case_preferences | `UpdatedByUser` | `{ id: ID!, name: String }` |
| complexity_scores | `ComplexityScoreUser` | `{ id: ID!, name: String }` |
| clinical_case_disciplines | `ClinicalCaseDisciplineUser` | `{ clinician: { name: String! } }` |
| clinical_case_files | `DocumentUser` | (own shape) |
| invoices | `FinanceUser` | (own shape) |
| parental_training | `ParentalTrainingNoteUser` | (own shape) |

Most are `{ id, name }` but some have richer nested structures (e.g. disciplines
wraps in `clinician`, demands has `clinician.professionalRegistrationNumber`).

## Schemas with `createdBy` (as of investigation date)

- `ComplexityScore` — `createdBy: ComplexityScoreUser!` (explicit resolver)
- `ClinicalGuidance` — `createdBy` with `{ id, name }`
- `Demand` — `createdBy` with nested `clinician` object
- `SensorialFunction` — `createdBy`
- `ClinicalGuidanceRegistry/Subject` — `createdBy: { id, name }`

## Schemas with `updatedBy` (as of investigation date)

- `ClinicalCasePreferences` — `updatedBy: UpdatedByUser!` (implicit)
- `ClinicalCaseDiscipline` — `updatedBy: ClinicalCaseDisciplineUser`
- `Document` (clinical_case_files) — `updatedBy: DocumentUser!`
- `Invoice` — `updatedBy: FinanceUser!`
- `ParentalTrainingNote` — `updatedBy: ParentalTrainingNoteUser`

## Key constraints

1. **`createdBy` is never in mutation inputs** — the Core API determines who
   created the record via the auth token. The BFF input types never include it.
2. **`transformResponse` is recursive** — nested objects like
   `created_by: { id, name }` are fully converted to `createdBy: { id, name }`
   without any special handling.
3. **Adding a `createdBy` field requires**:
   - Core API to return `created_by` in the response
   - A GraphQL type definition for the user object
   - Optionally, a field resolver (Pattern B) or nothing (Pattern A)
   - Test updates: mock response needs `created_by`, GraphQL fragment needs
     `createdBy`, assertions need to check the camelCased field

## Investigation checklist for "add createdBy/updatedBy to type X"

1. Check the type-defs: does the type already have a user-type field?
2. Check the resolvers: is there a field resolver for the type, or is it implicit?
3. Check the datasource: what REST endpoint returns the data? Does the Core API
   already include `created_by`/`updated_by` in its response?
4. Check existing patterns: pick the closest analog (same shape `{ id, name }`
   vs richer structure).
5. Check tests: what does the mock response look like? What does the GraphQL
   fragment include?
6. Verify `transformResponse` handles the nesting automatically (it does for
   any depth).
