# Cross-Stack Field Tracing

Technique for investigating whether a specific field exists (or is missing)
across all three GenialCare layers: **frontend (clinical-panel)** → **BFF
(clinical-panel-bff)** → **core (Rails)**. Use when the user asks "does field X
exist?" or "exibir campo Y" — the answer almost always spans all three layers.

## Procedure (top-down: UI → query → BFF → core → DB)

### 1. Frontend (clinical-panel)

```
src/
  types/<feature>.ts              # TypeScript type — does the field exist here?
  queries/<feature>/get*.ts       # GraphQL query — is the field selected?
  pages/**/<Feature>*Info.tsx     # Component — is the field rendered?
  pages/**/<Feature>*Edit.tsx     # Edit form — is the field editable?
```

- Search for the field name in both snake_case and camelCase variants
  (`last_modified_by`, `lastModifiedBy`, `updatedBy`).
- If zero hits, the field doesn't exist anywhere in the frontend — the feature
  is greenfield from the UI perspective.
- Check the GraphQL query string (inside `gql` template literals) to see exactly
  which fields are selected from the server.

### 2. BFF (clinical-panel-bff)

```
src/schema/<domain>/
  type-defs.graphql               # Does the GraphQL type declare the field?
  resolvers.js                    # Is there a custom resolver, or default pass-through?
src/dataSources/core/*.js         # What REST endpoint is called?
```

- The BFF is a thin proxy. If the field is in `type-defs.graphql` but has no
  custom resolver, it's resolved by default from the (camelCased) core response.
- If the field is NOT in `type-defs.graphql`, the BFF strips it even if the core
  returns it. Adding a field here is necessary for it to reach the frontend.
- `transformResponse` in `src/schema/utils.js` recursively converts snake_case →
  camelCase, so `last_modified_by` from core becomes `lastModifiedBy` in GraphQL.

### 3. Core (Rails)

```
packs/<pack>/app/models/<model>.rb          # Does the model have the association/attribute?
packs/<pack>/app/views/<feature>/*.jbuilder # Does the JSON view expose the field?
packs/<pack>/app/controllers/*.rb           # What does the controller return?
db/schema.rb                                 # Does the column exist in the DB?
```

- **db/schema.rb is ground truth.** Use `grep -n "table_name" db/schema.rb` —
  the file is too large for search_files content search.
- Check if the model includes `TrackCreationBy` (see below).
- Check the jbuilder view (`_*.jbuilder` partials) — `json.extract!` lists
  exactly which fields are serialized. A field can exist in the DB but be absent
  from the jbuilder view, meaning it never reaches the BFF.

### 4. Synthesize gaps

Create a table or list showing: which layers have the field, which don't, and
what changes each layer needs. Example from the `last_modified_by` investigation:

| Layer | Has field? | What's needed |
|-------|-----------|---------------|
| DB schema | `created_by_id` only, no `updated_by_id` | Migration to add column (if "last modified" ≠ "created") |
| Model | `belongs_to :created_by`, no `TrackCreationBy` | Include concern or add association |
| Jbuilder | Not exposed | Add to `json.extract!` |
| BFF type-defs | Not declared | Add field to GraphQL type |
| BFF resolvers | N/A (default resolver) | No change needed (pass-through) |
| Frontend query | Not selected | Add to `gql` query string |
| Frontend type | Not defined | Add to TypeScript type |
| Frontend component | Not rendered | Add display element |

## Key patterns for "who modified/created X" features

### TrackCreationBy concern

Located at `app/models/concerns/track_creation_by.rb`. Provides:
- `belongs_to :created_by, class_name: "User"`
- `belongs_to :updated_by, class_name: "User"`
- `before_validation` callbacks that auto-assign `Current.user`

**Not all models include it.** Check the model file for `include TrackCreationBy`
or `track_creation_by`. Example: `ClinicalCaseDiscipline` includes it (has
`updated_by`), `ClinicalCaseWorkload` does not (only has `belongs_to :created_by`).

### Two `updatedBy` GraphQL shapes in the codebase

The codebase has two inconsistent patterns for exposing the modifier:

1. **Flat**: `updatedBy { id name }` — used in `clinicalCasePreferences`.
   The BFF resolves `updatedBy` directly from the core response (user object
   with `id` and `name`).

2. **Nested**: `updatedBy { clinician { name } }` — used in `disciplines`.
   The core returns `updated_by` as a User, but the BFF/core wraps it in a
   `clinician` object.

When adding a new `updatedBy` field, check which pattern the sibling entities in
the same domain use, and follow that convention. The frontend type definitions
must match the chosen shape.

### Create-only entities and "last modified" semantics

Some entities (e.g. `ClinicalCaseWorkload`) only support `create` and `destroy`
— no `update` action in the controller. For these, `updated_at` only changes on
creation, so "last modified by" semantically equals "created by". Adding true
"last modified" semantics may require introducing an update flow, which is a
product/backend decision, not just a field addition.

## Worked example: `last_modified_by` on workloads

**Feature**: Display who last modified a workload in the clinical case UI.

**Investigation path**:
1. Searched `clinical-panel/src` for `workload` → found
   `src/queries/clinicalCaseWorkloads/` and `src/pages/CoverPage/Workloads/`.
2. Read `getClinicalCaseWorkloads.ts` → GraphQL query selects `createdAt`,
   `updatedAt` but no `updatedBy`/`lastModifiedBy`.
3. Read `types/clinicalCaseWorkloads.ts` → type has `createdAt`/`updatedAt`
   but no author field.
4. Read `ClinicalCaseWorkloadsInfo.tsx` → renders workloads in 3 sections
   (suggested, in-effect, history) with discipline, hours, dates, changeReason.
5. Checked sibling pattern: `ClinicalCaseDiscipline` (same query) HAS
   `updatedBy { clinician { name } }` and `CompletedDisciplineCard.tsx` displays
   it as "Concluída em {date} por {name}".
6. BFF `type-defs.graphql` → `type Workload` has no `updatedBy` field.
7. BFF `resolvers.js` → `ClinicalCase.workloads` calls
   `clinicalCasesApi.workloads(id)` → `GET /clinical_cases/:id/workloads.json`.
8. Core `_workload.json.jbuilder` → `json.extract!` lists fields but no author.
9. Core model `clinical_case_workload.rb` → `belongs_to :created_by` only,
   no `TrackCreationBy`.
10. `db/schema.rb` → `clinical_case_workloads` has `created_by_id` column,
    no `updated_by_id`.

**Conclusion**: Field doesn't exist at any layer. Feature requires changes in
all 3 systems (core migration + model + jbuilder → BFF type-defs → frontend
query + type + component). The `created_by_id` column already in the DB could
serve as a starting point if "last modified" is acceptable as "created by"
(given workloads are create-only).
