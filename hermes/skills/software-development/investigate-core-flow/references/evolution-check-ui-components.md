# Evolution Check: Frontend UI Components & Screen Layout

Companion to `references/evolution-check-types-and-disciplines.md` (which
covers backend types, validation rules, and BQ data). This file captures the
frontend rendering layer in `clinical-panel`.

## Component Decision Tree

```
Form.tsx
  for each objective:
    configuration = objective.libraryObjective?.evolutionCheckConfiguration
    if (configuration) → ObjectiveEvolutionCheckWithConfig
      if configurationType === 'trial_counter' → GeneralMeasurement
      else → CheckListMeasurement
    else → ObjectiveEvolutionCheck (pros/cons qualitative)
```

Key file: `src/pages/Sessions/EvolutionCheck/components/Form/Form.tsx`

## Discipline-to-ProgramType Mapping

`src/pages/Sessions/EvolutionCheck/utils.ts` → `getProgramType()`:

```
if programs contains SYMBOLIC_PLAY → 'symbolicPlay'
if programs contains Fono discipline and !legacy → 'speechTherapy'
if programs contains TO discipline and !legacy → 'occupationalTherapy'
else → 'aba'
```

This drives the Tag color and label shown on each objective card.

## i18n Labels (pt-br.json)

`src/i18n/locales/evolutionCheck/pt-br.json`:

| Key | Value |
|-----|-------|
| program.aba | "Vineland" |
| program.symbolicPlay | "Brincar Simbólico" |
| program.speechTherapy | "Fonoaudiologia" |
| program.occupationalTherapy | "Terapia Ocupacional" |
| activeTargetTitle.aba | "Alvos ativos" |
| activeTargetTitle.symbolicPlay | "Expansões" |
| activeTargetTitle.speechTherapy | "Alvos ativos" |
| activeTargetTitle.occupationalTherapy | "Atividades-alvos ativas" |

## Tag Colors by Discipline

| ProgramType | Tag Color |
|-------------|-----------|
| aba | purple |
| occupationalTherapy | blue |
| speechTherapy | cyan |
| symbolicPlay | magenta |

## Screen Layout Per Type (top to bottom)

### Common elements (all types, inside Card)

1. Tag (discipline name, colored) + objective description text
2. "Não avaliado" checkbox (top-right of card) — disables all fields when checked
3. Active targets list (targets with status in_treatment or in_maintenance)

### trial_counter (GeneralMeasurement)

1. Common elements
2. "Hierarquia de dicas" (PromptSchedule — only for ABA programs with TrialConfiguration)
3. Active targets
4. **Pré-requisitos** — section title + tooltip ("É uma avaliação se a criança tem os pré-requisitos necessários...")
5. Prerequisite cards (Checkbox per prerequisite, from config, static names)
6. When ALL prerequisites checked → opens:
   - Instructions alert (if config.instructions present)
   - **Faz com dica** — QuantityMeasure card (counter +/- buttons)
   - **Faz independente** — QuantityMeasure card (counter +/- buttons)
   - EvolutionScaleProgress — circular progress bar (green at 100%)
7. **Observações** — TextArea (optional, max 300 chars)

### checklist (CheckListMeasurement)

1. Common elements
2. Active targets
3. **Requisitos** — section title + tooltip ("É uma avaliação se a criança tem os requisitos necessários...")
4. Instructions alert (shown only when at least 1 requisite is checked)
5. Requisite items (Checkbox per requisite, from config, static names)
6. When at least 1 requisite checked → EvolutionScaleProgress (circular)
7. **Observações** — TextArea (obligatory when "Não avaliado", optional otherwise)

### without_configuration (ObjectiveEvolutionCheck)

1. Common elements
2. Active targets
3. **Escala de evolução** — section title + Tooltip with percentage definitions
4. RadioGroup: 0% | 25% | 50% | 75% | 100% (button-style radio)
5. **"O que a criança já faz"** — TextArea (required when scale ≠ 0%, min 5 chars)
6. **"O que falta para completar"** — TextArea (required when scale ≠ 100%, min 5 chars)

## Scale Definitions (Tooltip text, visible to therapist)

- **0%** — O terapeuta ainda está avaliando a criança quanto a este objetivo E/OU ainda está em fase de vínculo...
- **25%** — Vínculo estabelecido. A criança responde com suporte alto...
- **50%** — Criança responde com suporte médio...
- **75%** — Criança responde com dica leve ou mesmo de forma independente...
- **100%** — A criança atingiu o comportamento segundo as métricas do objetivo, de forma completamente independente.

Source: `src/pages/Sessions/EvolutionCheck/components/ObjectiveEvolutionCheck/components/Tooltip.tsx`

## Evolution Scale Calculations (Frontend)

### trial_counter

`useCalculateQuantitativeEvolutionScale.tsx`:
```
evolution_scale = (independent + 0.5 * prompted) / max_measurements
isLimitReached = prompted + independent >= max_measurements
```

### checklist

`CheckListMeasurement/index.tsx`:
```
evolution_scale = min(checked_requisites / completion_threshold, 1.0)
```
If no requisites checked → scale = 0.

### without_configuration

Scale is chosen manually by the therapist (0, 0.25, 0.5, 0.75, 1.0).

## Auto-Save

The form uses `useFormAutoSave` which persists draft data to Firestore
(collection prefix: `evolution-check-form`). Draft data is filtered by
`filterObjectiveChecksFromDraft` before reload to remove stale objectives.

## Checkout Flow

`CheckoutEvolutionCheck.tsx` checks if the **logged-in clinician** already
has `weeklyEvolutionChecks` for the current week for that case. If yes,
skips the evolution check page. If no, shows a warning box and renders the
EvolutionCheck component inline.

The weekly check is fetched via `user.weeklyEvolutionChecks` (GraphQL query
on the `User` type, not `ClinicalCase`) which calls
`usersApi.weeklyEvolutionChecks({ clinicalCaseIds })` →
`GET /users/evolution_checks/weekly.json` in the core. The core endpoint
filters by `clinician_id = authenticated_user.clinician.id`, so the check
is **per-clinician**: if another therapist did a check for the same case
this week, it does NOT count for the logged-in therapist.

The evolution check page is **skippable** (`isSkippable: true` in
`useCheckinCheckoutFlowNavigation`). The therapist can navigate away
without filling it. Enforcement (at least one per case per week per
clinician) is external, via Metabase dashboards.

## Confirmation Dialog

Before saving, a confirmation dialog appears:
- Title: "Tem certeza que deseja encerrar e salvar a sua coleta?"
- Alert: "Ao prosseguir, você irá salvar as informações registradas e não será possível editá-las."
- Buttons: "Voltar" / "Encerrar coleta"
