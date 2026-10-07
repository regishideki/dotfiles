# Fluxo de carga horária (workload) — clinical-panel + clinical-panel-bff

Investigação read-only (2026-09-30) do fluxo completo: form, dropdown de horas,
contratos GraphQL/REST, feature flags, exibição de erros e identificação do
plano de saúde. Base para qualquer mudança no domínio — em especial uma futura
regra de TOTAL de horas por operadora (ex: Amil), cujas implicações estão na
última seção.

## Mapa de arquivos

### Frontend (`clinical-panel/src/`)

| Arquivo | Papel |
|---|---|
| `pages/CoverPage/Workloads/Workloads/WorkloadsForm/WorkloadsForm.tsx` | Form reutilizável: disciplina (Radio.Group ABA/Fono/TO) → horas (Select) → data início (Input date) → justificativa (TextArea) |
| `pages/CoverPage/Workloads/Workloads/ClinicalCaseWorkloadsEdit.tsx` | Edição de carga vigente — rota `workloads/edit`; **não** passa `initialValues` (form começa vazio) |
| `pages/CoverPage/Workloads/Workloads/ClinicalCaseSuggestedWorkloadEdit.tsx` | Edição de sugestão pendente — rota `suggested-workload/edit`; pré-preenche a partir da sugestão |
| `pages/CoverPage/Workloads/Workloads/ClinicalCaseWorkloadsInfo.tsx` | Exibição (sugestões / carga atual / histórico) + hardlock por plano de saúde |
| `pages/CoverPage/Workloads/Workloads/useWorkload.ts` | Particiona workloads em suggested/inEffect/history (só sort; **sem cálculo**) |
| `pages/CoverPage/Workloads/Workloads/WorkloadsForm/components/WorkloadJustificationModal/` | Modal com exemplos de justificativa (texto estático) |
| `queries/clinicalCaseWorkloads/*` | `getClinicalCaseWorkloadLimits`, `getClinicalCaseWorkloads`, `createClinicalCaseWorkload`, `approveClinicalCaseSuggestedWorkload`, `reproveClinicalCaseSuggestedWorkload` |
| `hooks/useCreateClinicalCaseWorkload.ts` | Wrapper de `useAuthorizedMutation` |
| `types/clinicalCaseWorkloads.ts` | `ClinicalDisciplines` (aba/speech_therapy/occupational_therapy), `WorkloadType` (4 valores), `WorkloadLimits`, `CreateClinicalCaseWorkloadInput` |
| `utils/build-error-message.ts` | Pipeline de erros (ver seção Erros) |
| `hooks/useHealthPlanRestriction.ts` | Match exato de nome de plano contra lista de restritos |
| `constants/flags.ts` + `hooks/useFeatureFlag.ts` + `contexts/split-io.tsx` | Infra de feature flags (Split.io) |

### BFF (`clinical-panel-bff/src/`)

| Arquivo | Papel |
|---|---|
| `schema/workloads/type-defs.graphql` + `resolvers.js` | `Workload`, `CreateClinicalCaseWorkloadInput`, `WorkloadLimits`; Query `workloadLimits`/`clinicalCaseWorkloads`, Mutation `createClinicalCaseWorkload`; fields `ClinicalCase.workloads/workloadsInEffect/sharedScheduleWorkloads` |
| `schema/assessments/suggested_workload/type-defs.graphql` + `resolvers.js` | `SuggestedWorkload` (status pending/resolved); Query `suggestedWorkloads`, Mutations `approveSuggestedWorkload`/`reproveSuggestedWorkload`; o field `ClinicalCase.suggestedWorkloads` **fixa status='pending'** |
| `datasources/core/clinical-cases-api.js` (:303-335) | `workloads`, `createWorkload` (encoding `hours(4i)`), `workloadsInEffect`, `workloadLimits` |
| `datasources/core/assessments/suggested-workload-api.js` | `getSuggestedWorkloads`/`approve`/`reprove` |
| `schema/general/coverPage/` + `datasources/core/general/cover-page-api.js` | `coverPage.dependentInfo.healthPlan { name }` — origem do plano de saúde |
| `__tests__/integration/workload-limits.spec.js`, `__tests__/integration/clinical-case-workloads.spec.js`, `__tests__/integration/assessment/*suggested-workload*.spec.js` | **Documentação autoritativa dos shapes REST** (request e response) |

## Formulário

- Campos (`FormValues`): `workloadType`, `discipline`, `hours: number`,
  `changeReason?`, `inEffectSince?`.
- **Dropdown de horas derivado de `workloadLimits`**: `useEffect` observa a
  disciplina (`Form.useWatch`) + `workloadLimits`; switch escolhe
  `workloadLimits.aba | .speechTherapy | .occupationalTherapy`; loop
  `for (i = limits.min; i <= limits.max; i++)` gera um option por hora inteira
  (`t('hours.hoursText', { count: i })`).
- Trocar disciplina reseta `hours` (`form.setFieldsValue({ hours: undefined })`);
  o Select fica desabilitado sem disciplina ou sem options.
- **Validação client-side**: só `required` em tudo
  (`REQUIRED_ERROR_MESSAGE = 'Faltou você preencher esse campo'`), data ≥ hoje,
  ano com 4 dígitos, justificativa ≥ 10 chars. **Nenhuma validação de min/max de
  horas no cliente** — os limites só restringem as opções do dropdown; a
  validação real é no core.
- **Um form = uma disciplina por submit.** Não há edição conjunta nem
  validação de total (soma ABA+Fono+TO) em nenhuma camada.

### Dois fluxos de edição

| | `ClinicalCaseWorkloadsEdit` | `ClinicalCaseSuggestedWorkloadEdit` |
|---|---|---|
| Rota | `workloads/edit` | `suggested-workload/edit` |
| initialValues | **nenhum** (não usa a carga vigente como default) | da **sugestão pendente**: `{ discipline, hours: dayjs.duration(sug.hours).asHours(), changeReason: sug.reason }` |
| Disciplinas habilitadas | todas | só as com sugestão pendente (`enabledDisciplines`) |
| Mutação | `createClinicalCaseWorkload` (workloadType fixo `recommended_hours`) | `reproveSuggestedWorkload` com `workload` |
| Sem sugestão pendente | n/a | toast `'Não há sugestão pendente para esta disciplina.'` |

Exibição (`ClinicalCaseWorkloadsInfo`): seções Sugestões (approve/reprove com
modal de confirmação), Carga horária atual (`workloadsInEffect`, tag
"Vigente"), Histórico (allWorkloads menos inEffect), e
`CompletedDisciplineCard` para disciplinas concluídas.

## Contratos GraphQL → REST

### Queries

- `workloadLimits(clinicalCaseId)` → `GET /clinical_cases/:id/workload_limits.json`
  - REST: `{ "aba": {min,max}, "speech_therapy": {min,max}, "occupational_therapy": {min,max} }`
  - GraphQL: `WorkloadLimits { aba {min,max} speechTherapy {...} occupationalTherapy {...} }` — pass-through puro (`transformResponse` camelCase), zero agregação no BFF. **Shape por disciplina apenas — não há campo de total.**
- `ClinicalCase.workloads` → `GET /clinical_cases/:id/workloads.json`
- `ClinicalCase.workloadsInEffect` → `GET /clinical_cases/:id/workloads/in_effect.json?workload_type=recommended_hours`
- `ClinicalCase.sharedScheduleWorkloads` → idem com `workload_type=shared_schedule_hours`
- `suggestedWorkloads(clinicalCaseId, status?)` → `GET /clinical_cases/:id/suggested_workloads.json?status=...`
- Enum `WorkloadTypes` no BFF: `recommended_hours | recommended_agreed_hours | recurrently_scheduled_hours | shared_schedule_hours`

### Mutations

- `createClinicalCaseWorkload(clinicalCaseId, workload)` → `POST /clinical_cases/:id/workloads.json`
  ```json
  { "clinical_case_workload": { "discipline": "aba", "workload_type": "recommended_hours",
    "change_reason": "...", "in_effect_since": "...", "hours(4i)": 10, "hours(5i)": 0 } }
  ```
  `hours: Int` (GraphQL) vira o par multiparameter Rails `hours(4i)` (horas) /
  `hours(5i)` (minutos=0). Resposta do core: `hours` como duração ISO
  (`"PT10H"`), camelCased.
- `approveSuggestedWorkload(clinicalCaseId, id)` → `PUT /clinical_cases/:id/suggested_workloads/:id/approve.json` (sem body)
- `reproveSuggestedWorkload(clinicalCaseId, id, workload?)` → `PUT /clinical_cases/:id/suggested_workloads/:id/reprove.json`
  - sem workload: sem body; com workload: `{ "workload_input": { ...snake_case..., "hours(4i)": N, "hours(5i)": 0 } }`

## Plano de saúde (identificação + hardlock)

Fluxo do dado: `CoverPage.tsx` → query `GET_CLINICAL_CASE_COVER_PAGE`
(`coverPage.dependentInfo.healthPlan { name }`) → BFF resolver `coverPage` →
`GET /clinical_cases/:id/cover_page.json` (`dependent_info.health_plan.name`).

Hardlock no frontend (`ClinicalCaseWorkloadsInfo.tsx:49,64,73-75`):

```tsx
const restrictedPlans = ['Bradesco Saúde - Operadora', 'Bradesco Saúde', 'Mediservice'];
const { canShowButton } = useHealthPlanRestrictions(healthPlan, restrictedPlans);
// ENABLE_HARDLOCK_BRADESCO_BUTTON feature flag was removed; the hardlock is now always active
const shouldShowButton = isClinicalCaseReference || canShowButton;
```

- `shouldShowButton` controla os botões de **editar carga vigente** e **editar
  sugestão**; aprovar sugestão permanece liberado.
- `useHealthPlanRestrictions`: match **exato de string, case-sensitive**
  (`restrictedPlans.includes(planName)`), por nome completo do plano.
- A flag `ENABLE_HARDLOCK_BRADESCO_BUTTON` foi removida (hardlock sempre ativo);
  a constante ficou órfã em `constants/flags.ts`.
- **"Amil" não aparece em nenhum dos dois repos.**

## Feature flags (clinical-panel)

- Infra: Split.io (`@splitsoftware/splitio-react`), provider em
  `contexts/split-io.tsx` (montado no `App.tsx`), keys `VITE_SPLIT_IO_*`,
  refresh 1s, impressões reportadas ao Datadog RUM
  (`datadogRum.addFeatureFlagEvaluation`; RUM com
  `enableExperimentalFeatures: ['feature_flags']` em `services/datadog.ts`).
- Leitura sempre via hook `useFeatureFlag(flag, { attributes, treatmentHandler })`
  — treatment `'on'` → true. Targeting por atributos (ex: `{ user_email: email }`).
- Nomes centralizados em `constants/flags.ts`.
- **Nenhuma flag é usada hoje no fluxo de workload** — o único gate é o hardlock
  por plano + papel do usuário.

## Exibição de erros

- Mutations: `onError` → `notifyErrorMessages(error, m => toast.error(m))`.
- `build-error-message.ts`: extrai `graphQLErrors[].extensions.businessErrors[].message`
  primeiro; fallback `extensions.response.body` →
  `details[0].errors[0].message || message`. **Mensagens do core aparecem
  verbatim em toast, sem mapeamento/tradução.**
- Nenhuma mensagem de validação de workload hardcoded no frontend (buscas por
  "must be between" etc. → 0 resultados). Erros de query → componente
  `RetryError` com `buildErrorMessage`.
- BFF mapeia só 404→`NOT_FOUND` e 403→`FORBIDDEN` (`base-datasource.js`);
  422 do core passa com body intacto.

## Implicações para uma regra de TOTAL de horas (ex: Amil)

1. `WorkloadLimits` só tem shape por disciplina — uma regra de total (ex: soma
   ABA+Fono+TO ≤ 6h para plano X) não cabe no contrato atual: precisa de campo
   novo (ex: `total: {min,max}`) no core+BFF+query+form, OU validação só no
   backend com erro exibido via toast (funciona hoje, mas a UX é toast cru).
2. O form edita uma disciplina por submit e a página de edit não conhece o
   estado combinado das outras disciplinas (só busca `workloadLimits`) — uma
   validação de total na UI exigiria buscar `workloadsInEffect` no edit.
3. Identificação "Amil": seguiria o padrão `restrictedPlans` (nome exato,
   match de string) ou nova condição em `useHealthPlanRestrictions`.
4. Feature flag para rollout gradual tem infra pronta (`useFeatureFlag` +
   `constants/flags.ts`), sem precedente no módulo de workload. Lembrar do
   pitfall de specs que assumem flag-off em teste (ver seção "Removendo feature
   flags (SplitIO)" da skill principal).

## Parsing de horas no frontend

- Horas do core chegam como duração ISO (`"PT10H"`): parse com
  `dayjs.duration(hours).asHours()` (usado em `ClinicalCaseWorkloadsInfo.formatHours`
  e `ClinicalCaseSuggestedWorkloadEdit`).
- Em `t('hours.hoursText', { count })`, normalize para number — ver seção da
  skill sobre campos numéricos expostos como `String` no BFF.
