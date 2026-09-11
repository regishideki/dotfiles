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

## Context window management: subagents para investigação multi-repo

Quando a investigação spans 3+ repos, ler código de todos na mesma context window
degrada a qualidade do plano. O contexto fica cheio de código bruto que não precisa
estar todo presente simultaneamente.

**Técnica: orquestrador-worker com `delegate_task`**

Em vez de ler arquivos de cada repo sequencialmente na mesma sessão, spawnar um
subagent por repo via `delegate_task`. Cada subagent:

1. Recebe objetivo claro: "investigue o fluxo de <feature> no repo <X>, encontre
   pontos de entrada, fluxo principal, componentes-chave, e dependências"
2. Explora o repo com seu próprio context window (search_files, read_file)
3. Retorna apenas um sumário estruturado (não código bruto)

O agente principal consome apenas os sumários (token-light) e sintetiza o plano.

**Quando usar:** investigação que toca 3+ repos com código substancial para ler.
Para 1-2 repos ou investigação superficial, não vale o overhead de subagents.

**Quando NÃO usar:** quando os repos têm dependências circulares forte entre si
(o subagent de um repo precisa do contexto do outro para fazer sentido). Nesse caso,
a coordenação entre subagents é mais cara que o ganho.

**Fonte:** Anthropic, "How we built our multi-agent research system" — "Subagents
facilitate compression by operating in parallel with their own context windows,
exploring different aspects of the question simultaneously before condensing the
most important tokens for the lead research agent."

### Recuperando sumários truncados (delegate_task batch)

O resultado de um batch de `delegate_task` chega com `[SUMMARY TRUNCATED]` quando é grande (só
head + tail). Os sumários completos ficam em `~/.hermes/cache/delegation/subagent-summary-<N>-<timestamp>.txt`
(um por task) e o trace em `~/.hermes/cache/delegation/live/<delegation_id>/task-<N>.log`. Leia
esses arquivos com `read_file` (paginar via offset/limit) antes de sintetizar — o "miolo"
omitido costuma ter justamente o essencial (relação entre models, endpoints, vínculos).

### Dê perguntas numeradas e específicas aos subagents

Em vez de "investigue o fluxo de X", entregue N perguntas numeradas e pontuais (ex: "1) onde
estão os models; 2) qual FK liga A e B; 3) já existe vínculo hoje?"). Objetivo vago devolve
sumário vago — e perguntas específicas deixam claro o que faltou quando o sumário vem truncado.

## Pitfalls

- **Trailblazer use cases** são chamados com hash posicional (`UseCase.call({id:..., user:...})`), nunca kwargs.
- **Eventos**: se o valor parece "mágico" (atualiza sozinho), sempre verificar `event_consumer_start.rb`.
- **workload_type**: `RECOMMENDED_HOURS` = prescritas, `SHARED_SCHEDULE_HOURS` = HBJ calculado. Não confundir.
- **Não assumir substituição quando é adição**: quando a discussão menciona "mudar de X para Y", confirmar se é substituir ou adicionar Y mantendo X.
- **Context window overload**: se a investigação de 3+ repos está enchendo o contexto com código bruto, mudar para o padrão subagent (ver seção acima). Sinal de problema: o agente começa a perder informações do início da conversa ou o plano fica genérico por falta de espaço.
- **No BFF, o contrato real de uma mutation/query vive no `.graphql` (`type-defs.graphql`), não no resolver nem no datasource.** Resolvers e datasources (`schema/**/resolvers.js`, `datasources/**/*.js`) só mostram *quais* campos são repassados ao core, mas os campos que o frontend pode de fato enviar/receber (obrigatórios, opcionais, tipos) estão definidos nos `input`/`type` do `.graphql`. Ao investigar "que dado dá para mandar nessa mutation", sempre buscar o `input <NomeDoInput>` no `.graphql` antes de concluir pela leitura do resolver — evita relatar como "não suportado" um campo que só não estava sendo usado no fluxo específico analisado.
- **Duas features parecidas podem coexistir com maturidade bem diferente**: ao investigar um domínio (ex.: "participantes de sessão"), procurar por mais de um fluxo/entry-point antes de concluir que a feature não existe — o padrão comum na stack GenialCare é ter uma tela "principal" mais simples e uma tela "alternativa" (menu de contexto, ação secundária) mais completa ou legada. Buscar por todos os componentes/telas que tocam o mesmo campo de domínio (ex.: `clinicianIds`, `participants`) nas 3 camadas antes de decidir se é implementação nova ou correção de bug em feature existente.
