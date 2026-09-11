# clinical-panel-bff Testing Patterns

BFF Node.js (Apollo Server + GraphQL + Jest). JS puro com ESM, imports via alias `#src/...`. Diferente do `clinical-panel` (frontend React/Vite/vitest/TS) e do `core` (Rails/rspec).

## Validação

- Testes: `yarn test <test-file>` — Jest com `NODE_OPTIONS=--experimental-vm-modules`.
- Lint: `yarn lint` (eslint `--ext .js src/`) ou `yarn lint:fix`.
- **Não existe** `yarn types`/tsc — é JavaScript puro, sem type-check.

## Estrutura de teste (integration)

- `createTestClient({ apolloServer, accessToken })` → `{ query, mutate }` (do `src/test-helper.js`).
- Stubs de rede via **nock**: `stubAuthenticatedGetRequestToCore({ accessToken, url, responseBody })`.
- A URL no nock é **match exato**, incluindo query string e a ordem dos params. Ex.: o stub do `childDetails` deve casar `.../people_children/${id}.json?includes[]=calculated_official_scheduled_hours_by_discipline` (na ordem exata em que o DataLoader monta).
- Um spec por query/mutation em `src/__tests__/integration/<dominio>/`, usando factories (fishery) em `src/utils/factories/`.
- `transformResponse` (de `src/schema/utils.js`) converte **apenas as chaves** de snake_case → camelCase; os **valores ficam como o Core retorna** (não converte string↔number).

## GraphQL Float coage string → number (decimal do Core)

O Core serializa campos `decimal` como **string** no JSON (ex.: `percent_of_playtime_together_sessions: "0.15"`), por comportamento padrão do ActiveModel::Serializers. No BFF, declarar esse campo como `Float` no schema é seguro: o `graphql-js` `GraphQLFloat.serialize` faz `Number(coercedValue)` quando o valor é string (verificado no graphql-js 16.8.1). Ou seja, **não** precisa declarar como `String` só porque o Core manda string.

Regra prática: decimal do Core → `Float` no schema BFF. Só use `String` quando o campo é genuinamente texto (ex.: `Workload.hours: String!`).

## Resolver de campo calculado que cruza duas fontes

Para um campo em `ClinicalCase` que precisa de dados de dois datasources (ex.: horas agendadas do Child + percentual do PeiTrack), resolva em paralelo no próprio resolver:

```js
ClinicalCase: {
  feasiblePlaytimeTogetherHours: async (clinicalCase, _args, { dataSources: { clinicalCasesApi, peopleChildrenApi } }) => {
    const [peiTrack, children] = await Promise.all([
      clinicalCasesApi.peiTrack(clinicalCase).then(transformResponse),
      peopleChildrenApi.children(clinicalCase.id).then(transformResponses),
    ]);
    // ... parseFloat nos valores (Core manda number OU string, aceite ambos)
    // raw > 0 ? Math.max(1, Math.round(raw)) : 0  (mesma regra de round_hours do Core)
  },
},
```

- Ao ler valores numéricos vindos do Core, use `parseFloat(...)` + `Number.isFinite(...)` em vez de assumir number — o Core pode mandar string decimal.
- O `childDetails` do `peopleChildrenApi` usa DataLoader (chave `{ id, includes }`), então o stub de URL de include único é `?includes[]=<include>`.

## Expondo campo novo de um model já serializado pelo Core

Quando o Core (em outra task) adiciona um campo ao JSON de um endpoint que o BFF já faz pass-through (ex.: `current_module` no `pei_tracks.json`), o BFF normalmente **não precisa de novo datasource method** — basta:
1. declarar o campo no type-def (o `transformResponse` já converte `current_module` → `currentModule`), e
2. o resolver existente (`peiTrack`) já retorna o objeto transformado.

Só adicione datasource method se o campo exigir uma chamada nova de rede que ainda não existe.
