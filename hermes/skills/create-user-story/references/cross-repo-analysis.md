# Cross-Repo Feature Analysis (GenialCare Stack)

Metodologia para rastrear uma feature ponta a ponta nos 3 tiers da stack GenialCare: clinical-panel (React frontend), clinical-panel-bff (Node.js GraphQL), e core (Rails backend).

## Princípio: buscar o termo de domínio nos 3 repos em paralelo

Toda feature tem um nome de domínio (em português). Ex: "Brincar Juntos", "Checagem de Evolução", "Carga Horária".

**Primeira busca — em paralelo nos 3 repos:**

```
search_files(pattern="(?i)termo1|termo2", path="projects/clinical-panel", file_glob="*.{ts,tsx,js,jsx}")
search_files(pattern="(?i)termo1|termo2", path="projects/clinical-panel-bff", file_glob="*.{js,ts}")
search_files(pattern="(?i)termo1|termo2", path="projects/core", file_glob="*.rb")
```

Dica: usar regex com variações do termo (singular/plural, com/sem acento, inglês se relevante).

## Rastreamento do fluxo de dados

Uma vez localizados os arquivos, seguir esta ordem:

### 1. Frontend (clinical-panel)

- Identificar o componente React que exibe a feature
- Encontrar a query GraphQL que o componente usa (import de `queries/...`)
- Anotar os campos que a query pede (ex: `hours`, `changeReason`, `discipline`)

### 2. BFF (clinical-panel-bff)

- Encontrar o resolver GraphQL correspondente em `src/schema/`
- Identificar qual datasource/core API ele chama (`clinicalCasesApi`, `schedulingApi`, etc.)
- Anotar o endpoint REST do core que é chamado (ex: `GET /clinical_cases/:id/workloads/in_effect.json`)

### 3. Core (Rails backend)

- Encontrar o controller que serve o endpoint (ex: `ClinicalCaseWorkloadsController#in_effect`)
- Se o dado vem de um use case (padrão Trailblazer), localizar o use case (ex: `CalculateSharedScheduleHoursWorkload`)
- **Sempre verificar** se o use case é disparado por eventos: buscar em `core/event_consumer_start.rb` por `"use_case" => <NomeDoUseCase>`
- Anotar os eventos que disparam o recálculo (topic + event + subscription)

### 4. Model/Scope

- Verificar os scopes do model usados pelo use case (ex: `active_recommended_for`, `shared_schedule_hours_in_effect`)
- Confirmar o tipo de dado retornado (ex: `RECOMMENDED_HOURS` vs `SHARED_SCHEDULE_HOURS`)

## Resumo final

Ao final da análise, deve-se ter:

| Camada | O que faz | Arquivo chave |
|--------|----------|---------------|
| Frontend | Exibe o dado | Componente React + query GraphQL |
| BFF | Repassa/transforma | Resolver + datasource API |
| Core API | Serve o dado | Controller + endpoint REST |
| Core Use Case | Calcula o dado | Use case Trailblazer |
| Eventos | Disparam recálculo | event_consumer_start.rb |

## Exemplo concreto: Direcional de HBJ no Painel Clínico

User story: `20260804-hbj-horas-agendadas-painel`

### Rastreamento

**Frontend:**
- Componente: `clinical-panel/src/pages/CoverPage/PlaytimeTogetherInfo/PlaytimeTogetherInfo.tsx`
- Query: `GET_CLINICAL_CASE_SHARE_SCHEDULE_WORKLOADS` (`queries/clinicalCaseWorkloads/getClinicalCaseShareScheduleWorkloads.ts`)
- Campos exibidos: `workloadInEffect.hours` (carga horária), `workloadInEffect.changeReason` (tooltip)

**BFF:**
- Resolver: `clinical-panel-bff/src/schema/workloads/resolvers.js:13-17`
- `sharedScheduleWorkloads` → `clinicalCasesApi.workloadsInEffect(id, 'shared_schedule_hours')`
- Endpoint: `GET /clinical_cases/:id/workloads/in_effect.json?workload_type=shared_schedule_hours`

**Core:**
- Controller: `ClinicalCaseWorkloadsController#in_effect` (`packs/clinical/app/controllers/clinical_case_workloads_controller.rb:60-65`)
- Use case: `CalculateSharedScheduleHoursWorkload` (`packs/clinical/app/concepts/clinical_case_workloads/use_cases/calculate_shared_schedule_hours_workload.rb`)
- Cálculo: `aba_hours` (de `active_recommended_for(ABA)` → horas **prescritas**) × `MODULE_PERCENTAGES[module]`
- Percentuais: `{ module_1: 0.15, module_2: 0.40, module_3: 0.60 }`

**Eventos que disparam recálculo (event_consumer_start.rb):**
| Linha | Evento | Subscription |
|-------|--------|-------------|
| 640 | `clinical_case_preferences_updated` | `core-shared-schedule-workload-sync` |
| 910 | `workload_created` (ABA) | `core-process-shared-schedule-workload-created-sub` |
| 927 | `pei_track_module_updated` | `core-process-shared-schedule-pei-module-updated-sub` |

### Descoberta: dado alternativo já existe

Horas ABA **agendadas** por disciplina já estão disponíveis no sistema:
- Core: `People::ChildDecorator#calculated_official_scheduled_hours_by_discipline` → `{ "aba" => 6.0, ... }`
- BFF: `Children.calculatedOfficialScheduledHoursByDiscipline` → `{ aba: "6.0", ... }`
- Frontend: componente `Schedule.tsx` já consome esse campo

### Lições deste caso

- **Validar entendimento antes de escrever**: a primeira versão do analysis.md assumiu "substituir prescrito por agendado". O usuário corrigiu: o ideal Genial (prescrito) fica, e precisamos **adicionar** o direcional prático (agendado). O cálculo existente não muda.
- **Dados podem existir em lugares inesperados**: as horas agendadas já estavam disponíveis no frontend via `child.calculatedOfficialScheduledHoursByDiscipline`, consumidas pelo componente `Schedule`, mas o `PlaytimeTogetherInfo` não as usava.
- **Sempre verificar eventos**: entender *quando* o valor é recalculado é tão importante quanto entender *como*.

## Pitfalls

- **Trailblazer use cases** são chamados com hash posicional (`UseCase.call({id:..., user:...})`), nunca kwargs.
- **Eventos**: se o valor parece "mágico" (atualiza sozinho), sempre verificar `event_consumer_start.rb`.
- **workload_type**: `RECOMMENDED_HOURS` = prescritas, `SHARED_SCHEDULE_HOURS` = HBJ calculado. Não confundir.
- **Não assumir substituição quando é adição**: quando a discussão menciona "mudar de X para Y", confirmar se é substituir ou adicionar Y mantendo X.
