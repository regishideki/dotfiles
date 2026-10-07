# PEI Objective ↔ Program data model (and its 3-era evolution)

Domain map of how a PEI Objective links to its Program, and why `objective.program`
(singular) and `objective.programs` (plural) are NOT interchangeable. Useful whenever
a feature touches "which program does this objective have" across core / BFFs / mobile.

## The two associations on `Intervention::Pei::Objective`

`packs/clinical/app/models/intervention/pei/objective.rb`:

```ruby
## TODO: Remove this association - legacy association specific for ABA programs
has_one :program, class_name: "Intervention::Pei::AbaProgram",
                  foreign_key: "intervention_objective_id", dependent: :destroy

has_many :programs, through: :objectives_programs,
                    class_name: "Intervention::Pei::Program", foreign_key: "intervention_program_id"
```

- **`program` (singular) = LEGACY, ABA-only.** Direct FK `intervention_aba_programs.intervention_objective_id`.
  Only exists for ABA objectives. Fono/TO/symbolic_play objectives have `nil` here — those subtypes
  (`SpeechTherapyProgram`, `OccupationalTherapyProgram`, `SimpleProgram`) have no `intervention_objective_id`
  column; they link only via `general_program` (polymorphic `has_one :general_program, as: :programable`)
  → join table.
- **`programs` (plural) = CURRENT model.** Join table `intervention_objectives_programs`
  → `Intervention::Pei::Program` (a "general program" shadow record with `enum :discipline` and
  `belongs_to :programable, polymorphic: true`; `id = programable.id`). Discipline values:
  `aba` / `speech_therapy` / `occupational_therapy` / `symbolic_play`.

## 3-era evolution (matches the product history)

1. **v1 — 1 program (any discipline).** The `has_one :program` → `AbaProgram` (ABA was the original
   discipline). Still present, marked `TODO: Remove`.
2. **v2 — N programs (1 main psico + others).** Join table + `CreateObjectiveWithDependencies`
   which does `Each` over `params[:programs]`. No unique index on `intervention_objective_id` in the
   join table, so the DB still allows N.
3. **v3 (current) — back to 1 program (any discipline), via the join table.** Frontend now sends a
   single program; `CreateProgram` dispatches to one subtype use case
   (`CreateAbaProgram` / `CreateSpeechTherapyProgram` / `CreateOccupationalTherapyProgram` /
   `CreateSimpleProgram`) and appends one `general_program` to `objective.programs`.

## Serializer asymmetry (`_objective.json.jbuilder`)

```ruby
json.program  do ... program: objective.program ... end   # legacy AbaProgram; emits {} when nil
json.programs do json.array! objective.programs { |p| ... p.programable ... } end
```

The `_program.json.jbuilder` partial routes by `program.general_program.discipline` to a subtype partial
(`aba_program`, `occupational_therapy_program`, `speech_therapy_program`, `symbolic_play_program`).

## BFFs mirror the split — singular stays ABA-only

- **mobile-bff** `src/schema/peis/type-defs.graphql`: `programs: [Program]` AND `program: Program`.
  `resolvers.ts` `mapObjectiveAttributes` maps `program` from `objective.program` (legacy) and
  `programs` from `objective.programs` filtered through `getImplementedPrograms` (drops non-ABA fono/TO
  programs that have no `targets`, keeps `symbolic_play`). Discipline is remapped
  `aba→'ABA'`, `speech_therapy→'Fono'`, `occupational_therapy→'TO'`.
- **clinical-panel-bff** `src/schema/peis/type-defs.graphql`: `program: AbaProgram` (explicit legacy type)
  + `programs: [Program]!`.

Consequence: swapping a client from `programs[0]` to `program` singular breaks non-ABA objectives
(they become null). The singular field is never a general "single current program".

## Production data (Oct 2026, kubectl → rails runner, `safe_unscoped_with_tenant`)

Non-discarded + non-rejected objectives: **32,974 total**.

- 26,049 have ≥1 program
  - **1 program: 25,802 (99.05%)**
  - 2: 194 · 3: 38 · 4: 13 · 5: 2 → **>1 program: 247 (0.95%)** = legacy v2 residue
- 6,925 (21%) have 0 programs

BQ is NOT usable for this: `supervision-production-8f1v.intervention.*` returns 0 rows for the service
account (row-level access policy) even though `bq show` reports non-zero metadata — see the main
SKILL.md pitfall about prod BQ mirror. Use the live Postgres pod for ground truth.

## Practical takeaway

The mobile pattern `find(objective.programs, p => p.discipline?.toLowerCase() === 'aba') || programs[0]`
is a v2-era "pick the main psico program" heuristic. With 99% of objectives now single-program it is
vestigial; `programs[0]` suffices. It only still "matters" for the ~247 legacy multi-program objectives
(where `programs[0]` order is non-deterministic). Do NOT replace it with `objective.program` singular.
