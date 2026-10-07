# Mobile Stack Analysis (GenialCare)

A stack GenialCare paralela à documentada em `cross-repo-analysis.md` (que cobre
`clinical-panel` / `clinical-panel-bff` / `core`). Esta cobre **`mobile` (React Native) /
`mobile-bff` (Node/GraphQL) / `core` (Rails)**. O `core` é compartilhado; o que muda é a
camada de apresentação (React Native em vez de React web) e um BFF próprio (`mobile-bff`).

## Princípio de rastreamento

Mesma ordem da stack web: buscar o termo de domínio nos 3 repos em paralelo, depois seguir
frontend → BFF resolver → core controller/use case. Pontos de entrada do mobile:

- Telas em `mobile/src/screens/...`
- Queries GraphQL em `mobile/src/screens/**/...tsx` (gql inline) ou `mobile/src/queries/...`
- Tipos em `mobile/src/types/...`

## Padrão-chave: mapeamento status → categoria fica no BFF (não no core nem no app)

Para **status de objetivos** (e padrões semelhantes de classificação de apresentação):

- **Core** é fonte da verdade do status e emite `status_details.{value,label}` — `value` é o
  status cru, `label` vem de i18n (`config/locales/pt-BR/intervention.yml`). O core **não
  emite categoria/aba**.
  - View: `packs/clinical/app/views/intervention/objectives/_objective.json.jbuilder`
  - Enum: `packs/clinical/app/models/intervention/enum/objective_statuses.rb`
- **BFF (`mobile-bff`)** classifica status → categoria num mapa único `statusCategory` em
  `src/schema/peis/resolvers.ts` (função `mapStatusInfo`). É um **concern de apresentação
  centralizado no BFF**: um status novo flui com `value`/`label` automáticos e, para entrar
  numa aba, basta categorizá-lo no BFF **sem release do app** (filosofia registrada em
  comentário no próprio resolver).
  - `statusInfo` exposto: `{ value, label, category }` (`type ObjectiveStatusInfo` em
    `type-defs.graphql`).
- **Mobile** renderiza as abas filtrando `statusInfo.category === activeTab`.

### Arquivos-chave (exemplo: objetivos do PEI)

| Camada | Arquivo |
|--------|---------|
| Lista (abas) | `mobile/src/screens/Pei/PeiObjectiveList/PeiObjectiveList.tsx` |
| Detalhe | `mobile/src/screens/Pei/PeiObjectiveDetails/PeiObjectiveDetails.tsx` |
| Tipos | `mobile/src/types/pei.ts` |
| Resolver BFF | `mobile-bff/src/schema/peis/resolvers.ts` |
| Schema BFF | `mobile-bff/src/schema/peis/type-defs.graphql` |
| View core | `core/packs/clinical/app/views/intervention/objectives/_objective.json.jbuilder` |

## Pitfall de design: "aparecer em mais de um grupo" vs. `category` único

O modelo `category` único (status → uma aba) **não suporta** um valor que precisa aparecer em
duas abas simultaneamente (ex: `in_maintenance` deve aparecer em "Em andamento" E "Concluídos",
pois a criança domina a habilidade mas ainda a exercita nas sessões).

Decisão tomada (2026-09-16, story `objetivos-manutencao-ativos-e-concluidos`): adicionar um
**campo booleano aditivo** `isInMaintenance: Boolean!` ao `statusInfo` (derivado de
`value === 'in_maintenance'` no `mapStatusInfo`), mantendo `category = 'completed'`. O app
passa a incluir o objetivo na aba ativa via `category === 'in_progress' || isInMaintenance`.

Alternativas descartadas e por quê:
- `categories: [String]` (lista) — mais geral, mas **quebra o contrato** `category` único
  consumido por outras telas (ex: `PeiObjectiveDetails` usa `category === 'completed'` para
  decidir "Data de conclusão") e aumenta risco de regressão.
- Nova categoria `in_maintenance` tratada especialmente no frontend — acopla o app ao valor do
  status, contrariando a filosofia de manter a classificação no BFF.

Regra prática: quando um valor de domínio precisa pertencer a N grupos mas o contrato atual é
"1 valor → 1 grupo", **prefira um flag booleano aditivo** (não-breaking) a uma lista ou a uma
nova categoria. Só vá para lista quando a cardinalidade N é uma regra de negócio real e
generalizável, não um caso único.

## Testes que cobrem o mapeamento

- `mobile-bff/src/__tests__/integration/clinical-case-peis.spec.js` — `it.each` mapeando
  `[status, label, category]`; linha com `['in_maintenance', 'Em manutenção', 'completed']`.
- `mobile/src/screens/Pei/PeiObjectiveList/__tests__/PeiObjectiveList.spec.tsx` — fixtures de
  `statusInfo` com `category`; usa `testID="pei-tab-completed"` para trocar de aba.
- `mobile/src/screens/Pei/PeiObjectiveDetails/__test__/PeiObjectiveDetails.spec.tsx` — checa
  "Data de conclusão do objetivo" quando `category === 'completed'`.

Componente reutilizável para tags: `mobile/src/components/Badge/Badge.tsx` (props `color`,
`bg`, `_text` via native-base).
