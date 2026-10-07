---
name: genialcare-clinical-panel-stack
description: Use when working across GenialCare clinical-panel repos.
metadata:
  hermes:
    tags: [genialcare, clinical-panel, bff, cross-repo, debugging, integration]
---

# GenialCare Clinical Panel Stack

Gotchas e técnicas para trabalho cross-repo na stack do Painel Clínico (Core → clinical-panel-bff → clinical-panel). Coisas que custaram tempo de debug em sessões anteriores.

## Generalizando endpoint de disciplina (Fono → Fono+TO): o BFF auto-detecta schema, o panel é desacoplado

Quando o pedido é "tornar genérico" um endpoint hoje específico de uma disciplina (ex. `related_objectives` de Fono), o refactor atravessa os 3 repos — mas o custo é MENOR do que parece, porque BFF e panel têm estruturas que desacoplam as mudanças. Fatos estruturais que evitam superestimar o trabalho (nesta sessão o usuário corrigiu: *"não entendi porque isso é tão mais custoso"* — renomear enum só toca o BFF):

- **BFF: schema é auto-carregado, só datasource precisa de registro manual.** `src/schema/index.js` usa `@graphql-tools/load-files` com glob `**/type-defs.graphql` + `**/resolvers.js` + `mergeTypeDefs`/`mergeResolvers`. Criar um diretório novo (ex. `schema/assessments/related_objectives/` com `type-defs.graphql` + `resolvers.js`) é detectado automaticamente — zero registro. Datasource é diferente: registrar em `src/datasources/index.js` (mapa `APIs`; a chave `XApi` vira `dataSources.xApi` em camelCase). Tipos GraphQL são globais (merge por nome), então mover um tipo de arquivo não quebra referências de outro arquivo.
- **Panel: tipos de assessment são MANUAIS, sem codegen.** `types/assessments/speechTherapy.ts` define `export type SpeechTherapyAssessmentTypes = 'phonological' | ...` (string union à mão) + interfaces próprias. O NOME do enum GraphQL do BFF **não aparece** em lugar nenhum do panel — só os valores como string literals. Consequência: renomear um enum no BFF (`AssessmentTypes` → `SpeechTherapyAssessmentTypes`) é INVISÍVEL pro panel. Antes de estimar "isso mexe no panel também", verifique se o nome que você vai mudar é referenciado por types gerados (codegen) ou por types manuais — se manual, é BFF-only.
- **Dois caminhos, um vivo e um morto.** O panel consome objetivos relacionados pelo CAMPO `relatedObjectives` dentro de `speechTherapyAssessmentsRegistry(...)` (resolvido no `show` do core), NÃO pela query standalone `assessmentRelatedObjectives`. Mudar a assinatura da query standalone (adicionar arg) não toca o panel. Sempre confirme qual query/campo o panel de fato usa antes de declarar "a query mudou, o panel quebra".
- **Core: `CustomMacros::Model.Find` aceita `model_class` como lambda** (`model_class.respond_to?(:call) ? model_class.call(ctx) : model_class`). Para resolver o model dinamicamente por disciplina: `model_class: ->(ctx) { REGISTRY_CLASSES[ctx[:params][:registry_type]] }` + um mapa constante `REGISTRY_CLASSES = { "speech_therapy" => SpeechTherapy::Registry, "occupational_therapy" => OccupationalTherapy::Registry }`. A `AssessmentsRegistryPolicy` já resolve por disciplina via `case @record` — não precisa generalizar a policy.
- **Enum compartilhado = união dos enums por disciplina.** Para a validação de `assessment_type` ficar genérica (Fono + TO) sem o edge case de `distinct.pluck` (tabela vazia rejeitaria todos os tipos e quebra os specs), crie `Assessments::Enum::AssessmentTypes` com `def self.all = SpeechTherapyAssessmentTypes.all + OccupationalTherapyAssessmentTypes.all`. ~3 linhas, barato.

**Pitfall ao mover resolvers via `patch`:** remover um bloco de resolver (ex. o field-resolver `AssessmentRelatedObjective`) é fácil de errar — se o `old_string` for só a linha SEGUINTE (`PhonologicalAssessment: { ... }`) e o `new_string` re-adicionar o bloco antes dela, você DUPLICA o bloco em vez de removê-lo (aconteceu: ficou 2× e quebrou o merge de resolvers). Depois de um patch de "remoção", sempre releia o arquivo e confirme que o bloco não ficou duplicado.

## Front local quebra "do nada" (erros de GraphQL/dados): suspeite de migration pendente no CORE antes de debuggar o front

Quando o painel local (localhost:5050) começa a falhar em runtime — telas quebram ao buscar dados, erros de GraphQL — mas `yarn types`/`vitest`/`eslint` passam e o código do front/BFF não mudou, a causa mais provável é o **core devolvendo 500 por migration pendente** (`ActiveRecord::Migration::CheckPending`), que bloqueia TODAS as requisições do core → o BFF falha → o panel quebra em cascata. Dispara depois de `git fetch origin main` + rebase trazerem migrações novas (de trabalho de OUTRAS pessoas, ex. domínio de invoicing) que não foram aplicadas no dev DB. A página de login carrega normal (não toca o core); só quebra depois, quando o app busca dados.

- **Diagnóstico rápido (não debugue o front primeiro):** `curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/health` (ou qualquer endpoint do core). Se vier `500`, rode `docker logs core-app-1 --tail 200 | grep -iE "pending|migrat"` — a linha "You have N pending migrations" + a lista de arquivos confirma na hora.
- **Fix:** `docker compose exec -e DISABLE_SPRING=1 app rails db:migrate` (comando já em memória). As migrações aplicam em segundos.
- **Como saber que voltou:** o endpoint passa de `500` para `401` (auth, sem token) ou `404` (rota inexistente) — NÃO `500`. A primeira request pós-migrate pode ser lenta (~10s, cold boot/Spring), as seguintes ~20ms — não confunda esse primeiro slow request com "ainda quebrado".
- A migration pendente é lacuna de ambiente (dev DB defasado), não regressão do seu código — não reverta o refactor por causa disso. O `db:migrate` resolve e o front volta sem nenhuma mudança de código.
- **`curl /health` devolve `000` (conexão recusada), não 500?** O container do core está PARADO, não é migration. `docker ps -a` mostra `core-app-1` como `Exited` enquanto `core-db-1`/`core-redis-1`/`core-firebase-1` seguem `Up`. Suba com `docker compose start app` (não `docker compose up -d app` — o `terminal` de foreground rejeita `up` como "long-lived server/watch process"; `start` num container já existente retorna rápido). Confirme que voltou quando `/health` sai de `000` para `404`/`401` (app de pé e roteando; `404` em `/health` é só rota inexistente, não erro).

## Login do painel (E2E/screenshot): tem uma etapa de seleção de clínica ANTES do Auth0

O login do clinical-panel **não** vai direto pro Auth0 — primeiro aparece uma tela "Boas-vindas ao Painel Clínico" com 3 cards de clínica (Genial Care / Mindplace Kids / Outra Clinica) e um botão "Entrar" que só habilita depois de selecionar uma clínica. Só clínica + "Entrar" caem no Auth0 email/senha (credenciais dev em memória: `dev@genialcare.com.br`).

Para scripts de screenshot/E2E, selecione o card da clínica **primeiro** (é um elemento genérico com `onclick`, não um `radio`/`button` acessível — em Playwright `getByText('Genial Care')` pode casar com o logo; use um seletor mais específico ou o índice do elemento) e então clique "Entrar". Pular direto pro campo email/senha não funciona — o form do Auth0 só aparece depois dessa etapa.

## Avaliações de fono (speech therapy): dois layouts, mesmos formulários

A tela de avaliação direta de fono tem **dois fluxos distintos** que renderizam os MESMOS formulários (`*Form`/`Form`) mas com layouts DIFERENTES — e o URL/`sessionId` de um não serve para o outro:

| Fluxo | Layout | URL | Modo |
|---|---|---|---|
| **Dentro do checkin** (avaliação numa sessão) | `pages/Users/Session/components/DirectAssessmentsLayout` | `/users/sessions/:sessionId/assessments/speech-therapy/:type` | edit |
| **Fora do checkin** (avaliação direta do caso) | `pages/DirectAssessments/components/DirectAssessmentsViewLayout` | `/clinical-cases/:id/assessments/direct-assessments/:registryId/speech-therapy/:type` | view (tem botão "Editar") |

### `useParams()`: os params de rota NÃO têm o nome que você espera (`id`/`sessionId`, não `clinicalCaseId`)

Os nomes reais dos segmentos de rota não batem com os nomes semânticos. Os componentes-pai
fazem alias explícito: `const { id: clinicalCaseId = '', registryId = '' } = useParams()`
(fluxo `clinical-cases`) e `const { sessionId } = useParams()` (fluxo `sessions`). Se um **hook
compartilhado** fizer `const { registryId = '', clinicalCaseId = '' } = useParams()` direto,
`clinicalCaseId` vem `''` (o param é `:id`, não `:clinicalCaseId`) e qualquer
`useQuery(..., { skip: !registryId || !clinicalCaseId })` é **silenciosamente pulado** — o hook
retorna `data: undefined` para sempre e o mapa derivado fica vazio, mesmo com o pai já tendo
buscado a query. No fluxo `sessions`, o param é `:sessionId` (não `:registryId` nem `:id`), então
`registryId` e `clinicalCaseId` vêm ambos `''` — uma query keyed nesses params também é pulada
ali (correto SÓ se aquele fluxo não precisa dos dados; o fluxo de sessão não exibe objetivos).

- Sintoma: um hook chama `useQuery` mas `data` é sempre falsy e o `useMemo` derivado fica vazio,
  enquanto o parente já renderizou os dados. Não procure bug de cache Apollo primeiro — confira se
  `useParams()` está destruturando o nome certo.
- Fix: no fluxo `clinical-cases`, alias `const { registryId = '', id: clinicalCaseId = '' } =
  useParams()`. Confirme o nome real no `Routes.tsx` (ou no `index.tsx` do componente-pai) antes de
  assumir `clinicalCaseId`.

⚠️ **Fácil de inverter (errei duas vezes — o usuário corrigiu com "você inverteu! Olha a URL!").** A regra mnemônica é: **`sessions` na URL = DENTRO do fluxo de checkin** (a avaliação acontece dentro de uma sessão de atendimento); **`clinical-cases` na URL = FORA do fluxo de checkin** (avaliação direta no caso, sem sessão). Quando o usuário diz "no checkin não precisa do toggle" e "valide no fluxo dentro do caso", o toggle vai no layout de `clinical-cases` (`DirectAssessmentsViewLayout`), NÃO no de `sessions`. Não confie no nome dos componentes para inferir isso — `DirectAssessmentsLayout` (nome "genérico") é o de `sessions`/checkin, e `DirectAssessmentsViewLayout` (nome "view") é o de `clinical-cases`/fora-do-checkin.

- Ao adicionar um controle que deve aparecer "acima do formulário" (ex. um toggle global de objetivos), você precisa colocá-lo no layout CERTO. Colocar só em `DirectAssessmentsLayout` (sessions/checkin) faz o fluxo fora-do-checkin (`clinical-cases`, que usa `DirectAssessmentsViewLayout`) não exibir nada — e vice-versa. Descobrir isso custa uma rodada inteira de "o toggle não aparece" + screenshot.
- Se o usuário disser que o toggle só deve existir num dos fluxos (ex. "no checkin não precisa"), extraia o controle para um componente compartilhado (ex. `ObjectivesToggle`) e use só onde interessa — mas mantenha o provider de contexto montado nos DOIS grupos de rota se o hook for chamado nos dois fluxos (o hook lança sem provider, ver próxima seção).
- O fluxo fora-do-checkin (`clinical-cases`) usa `registryId` (não `sessionId`) e funciona SEM `general_session`; o fluxo dentro-do-checkin (`sessions`) exige `sessionId` e uma `general_session` + `assessment_session` (polimórfico, shared PK) vinculada ao registry — criar isso à mão no dev DB é pesado (ver pitfall "criar sessão de fono" abaixo).

### Persistir estado entre as sub-avaliações: o provider precisa ficar ACIMA das rotas

As 5 sub-avaliações são **rotas separadas** — o stepper (`AssessmentsSteps`) faz `navigate(assessments[i].pathname)`, então trocar de aba desmonta o componente da aba anterior (e o `SpeechTherapyAssessmentsProvider`, que é montado por-rota). Qualquer `useState` dentro de um componente de rota **reseta** ao trocar de aba. Para persistir (ex. um toggle "ver objetivos" que deve ficar ligado ao navegar entre as abas), o estado precisa subir para **acima das rotas**, via um provider em layout-route no `Routes.tsx`:

```jsx
<Route
  path="speech-therapy"
  element={<RelatedObjectivesProvider><Outlet /></RelatedObjectivesProvider>}
>
  <Route path="speech-motor-control" element={...} />
  ...
</Route>
```

Há DOIS grupos `speech-therapy` no `Routes.tsx` (in-session `:sessionId/assessments/speech-therapy` E checkin `assessments/direct-assessments/:registryId/speech-therapy`) — monte o provider nos dois se o hook for chamado nos dois fluxos. Padrão de contexto deste repo: `createContext<Type | null>(null)` + `useContext` + `throw new Error('... must be used within ...')` (igual ao `DirectAssessmentsProvider`).

### O `item_identifier` do de-para é um contrato de STRING solto (v1) — a "segunda versão" troca por associação/FK

O de-para v1 (`assessment_objective_mappings`) liga item de avaliação → `library_objective` por uma chave string `item_identifier` que atravessa 4 camadas (CSV → regras de tradução da rake → tabela no DB → lookup no front `objectivesByItem[<chave>]`) sem FK nem type enforcement. A semântica da chave é **inconsistente entre avaliações**, e isso é o risco de manutenção de longo prazo (o usuário levantou exatamente essa preocupação perguntando "isso não demandou lógica extra estranha e cuja manutenção pode ficar complicada, principalmente na segunda versão onde objetivo e avaliação estarão intimamente ligados no backend?"):

- **Fonologia** (`phonological`): `item_identifier` = código do processo, reusando o enum existente `PhonologicalAtypicalProcessNames` (`RS = "rs"`, `HC = "hc"`, …). Coincide com o `name` do registro `phonological_atypical_process`, então o front faz `objectivesByItem[record.name]` direto, SEM tradução. É por isso que os objetivos aparecem como coluna na tabela de ocorrências de processos fonológicos (`AtypicalProcessesScore`): a granularidade do de-para validada pela fono É o processo individual, que é exatamente a linha dessa tabela.
- **Fono motora / CAA**: `item_identifier` = field name (`limited_speech_movement_range`, `is_needed`).
- **Comunicação expressiva**: field + `feature_name` (caso especial `combines_two_plus_symbols`).

Consequências práticas: (1) se um código de processo/campo mudar, o mapeamento quebra **silenciosamente** (objetivos somem, sem erro); (2) o front precisa de keying por-componente (`record.name` num lugar, `record.aspect` noutro, `MEANS_FIELDS.flatMap` noutro); (3) o de-para vive em CSV + hash de tradução em código (`ITEM_TRANSLATION` com ~80 entradas + normalização + tratamento de "células malformadas") — difícil de auditar.

O lado "limpo": o `item_identifier` reusa valores de enum que já existiam (não é código inventado), então é um **v1 pragmático** — serve pra validar UX + conteúdo do de-para com a fono antes de investir no modelo definitivo. A "segunda versão" (objetivo ↔ avaliação intimamente ligados no backend) é o que elimina os três riscos: troca a string por associação/FK de verdade, matando o contrato de string + as regras de tradução + o caso especial `feature_name`. Ao trabalhar nesse de-para, se o pedido for "deixar genérico/reutilizável pra outras disciplinas", o ponto de inflexão é exatamente esse: deixou de ser dado estático e virou relação de domínio.

### De-para de fono tem uma dimensão `feature_name` que o endpoint colapsa

O de-para (`assessment_objective_mappings`) tem uma coluna `feature_name` que só é preenchida para UM
item: "Combinação de dois ou mais símbolos" (`combines_two_plus_symbols`), expandido para as 9 funções
comunicativas via `MEANS_BY_FEATURE` na rake de import. Ou seja, o banco tem 9 linhas
`combines_two_plus_symbols` com `feature_name` distinto (`request_attention`, `request_present_object`, …),
cada uma apontando para os MESMOS 4 library objectives.

O endpoint `Assessments::UseCases::ResolveRelatedObjectives#resolve_objectives` faz
`.group_by(&:item_identifier)` — agrupa SÓ por item, **descartando `feature_name`**. As 9 linhas
colapsam numa única entrada `combines_two_plus_symbols`, e a informação "pertence à função X" se perde.

**Sintoma no panel:** na Comunicação Expressiva, as funções (Pedido de atenção, Pedido de objeto…) não
têm objetivos por-linha — só as "habilidades" (Ecolalia, Intenção, Repertório, que usam coluna por-linha)
e os "meios" (lista achatada `meansObjectives` abaixo da tabela) mostram objetivos. O usuário relata
"a linha 'pedido de atenção' não mostra objetivos".

**Diagnóstico:** quando "alguns itens mostram objetivos e outros não", confira se o endpoint agrupa por
TODAS as dimensões do de-para (`item_identifier` + `feature_name`) e se o BFF expõe `featureName`. Um
`.group_by` numa chave só derruba a dimensão secundária silenciosamente.

**Resolução (implementada — NÃO é fix de 3 repos):** os 4 objetivos são **IDÊNTICOS** nas 9 funções
(confirme no banco: `SELECT DISTINCT lo.description ... WHERE item_identifier='combines_two_plus_symbols'`),
então a coluna `feature_name` é redundante para a exibição e o panel resolve sozinho, sem mexer no
endpoint/BFF. Renderize a **união dos objetivos dos meios** (dedup por `id`) numa **coluna à direita**,
repetida em cada linha de função:

```jsx
const meansObjectives = useMemo(() => {
  const seen = new Set<string>();
  return MEANS_FIELDS.flatMap((f) => objectivesByItem[f] ?? []).filter((o) => {
    if (seen.has(o.id)) return false;
    seen.add(o.id); return true;
  });
}, [objectivesByItem]);
// coluna extra no array `columns`:
...(showObjectives ? [{ title: t('relatedObjectives.toggle'), width: '40%',
  render: () => <RelatedObjectivesTags objectives={meansObjectives} /> }] : [])
```

Isso espelha o protótipo FORWARD (a união `CE_ALL_OBJS` repetida por linha de função). **NÃO agrupe por
meio abaixo da tabela** — o usuário corrigiu explicitamente: *"você fez totalmente diferente do
protótipo. Não era para ter repetido os objetivos em todas as linhas?"* + *"não tínhamos combinado de
colocar os objetivos na coluna da direita?"*. A regra é: **coluna à direita, repetida por linha**,
igual às demais sub-avaliações (Bandeiras Vermelhas, Motricidade, CAA, habilidades) — nunca abaixo da
tabela nem agrupado por meio.

**Pitfall de protótipo (direção):** quando o usuário disser "verifique como está no protótipo e faça
igual", o protótipo **FORWARD** (avaliação → objetivos, a direção que a feature implementa) está
publicado no GitHub Pages
`https://genialcare.github.io/product-engineer-agent/prototypes/vinculo-objetivos-itens-avaliacao-fono/`
e é referenciado no `PRD.md` da story `20260903-vinculo-objetivos-itens-avaliacao-fono`. O `index.html`
em `documentations/user_stories/20260908-objetivos-referenciando-avaliacoes-fono/prototipo/` é a
"alternativa INVERSA" (objetivo → avaliações) — direção OPOSTA; segui-la leva ao design errado (agrupar
objetivos por meio abaixo, em vez de coluna à direita por linha). Antes de implementar, confirme qual
direção o protótipo que você está lendo representa.

### antd `Radio.Button` / `Select` em teste: `data-testid` cai num elemento oculto — clique o label / o selector

- **`data-testid` em antd `Radio.Button` cai no `<input>` OCULTO** (estrutura
  `<label.ant-radio-button-wrapper><span.ant-radio-button><input … data-testid></span>…</label>`),
  que tem `pointer-events: none`. `userEvent.click(input)` falha com `Unable to perform pointer
  interaction as the element has 'pointer-events: none'` — **NÃO é o flakiness de paralelismo da seção
  "Timeout de teste isolado" acima; aqui é determinístico.** Fix: clique o `<label>` que embrulha —
  RTL: `fireEvent.click(screen.getByTestId('x').closest('label') as HTMLElement)`; Playwright:
  `page.click('label:has([data-testid="x"])')`.
- **antd `Select` (com prop `options`) abre via `mousedown` no `.ant-select-selector` interno**, NÃO no
  root onde o `data-testid` cai. `fireEvent.mouseDown(select.querySelector('.ant-select-selector'))` abre
  o dropdown (renderizado em portal) para `await screen.findByText('<label da option>')`; `fireEvent.mouseDown`
  no root do Select não faz nada. Prefira `fireEvent.click`/`mouseDown` (não `userEvent`) para esses
  controles — evita as checagens de `pointer-events` do user-event.

### antd `Form`: `disabled` do submit lendo `form.getFieldsError()` no render fica STALE — use `<Form.Item shouldUpdate>`

Quando o `disabled` do botão de salvar depende do estado de validação (`form.getFieldsError().some(({errors}) => errors.length > 0)`), ler isso **no corpo do componente-pai** (fora de um `Form.Item`) é não-reativo: ao preencher os campos, o `Form.Item` interno re-renderiza, mas o componente-pai que contém o `Form` NÃO — então o `hasErrors()` guarda o valor da última renderização do pai e o botão fica desabilitado mesmo com o form completo. O sintoma é **intermitente** porque qualquer re-render paralelo (mudar disciplina, `setHourOptions`) reavalia o `hasErrors()` e destrava.

- **Fix idiomático**: envolver os botões num `<Form.Item shouldUpdate noStyle>` cujo render-prop recomputa o erro a cada mudança de campo:
  ```tsx
  <Form.Item shouldUpdate noStyle>
    {() => {
      const hasErrors = form.getFieldsError().some(({ errors }) => errors.length > 0);
      return (<Flex gap="large">…<Button htmlType="submit" disabled={isLoading || hasErrors}>Salvar</Button>…</Flex>);
    }}
  </Form.Item>
  ```
- Não deixe o `hasErrors` como função solta no corpo do componente (ela só é reavaliada quando o pai re-renderiza, não quando os `Form.Item` mudam). Alternativa com estado (`onFieldsChange` → `setHasErrors`) também funciona, mas `shouldUpdate` é mais enxuto.

### Antd Table `tableLayout="fixed"`: colunas percentuais somando >100% são espremidas

Ao adicionar uma coluna larga (ex. "objetivos relacionados" com descrições longas) a uma tabela com `tableLayout="fixed"` e colunas em `%`, o total passa de 100% e o Antd **espreme proporcionalmente** todas as colunas — a coluna nova fica estreita/ilegível. Fix: redistribuir para somar 100% (ex. itens 60%→40%, resposta 40%→20%, objetivos 40%), ou usar `scroll.x` fixo. Não use `scroll.x` maior que o viewport para "deixar a coluna larga" — ela fica cortada fora da tela e o usuário precisa rolar para ver.

### Coluna condicional (ex. "objetivos" só quando o toggle liga): config object nomeado com % somando 100%, NÃO `flex` nem número mágico

O usuário tem preferência explícita por **controle de cada coluna** e por **larguras que somam 100%** nos DOIS estados (com/sem a coluna condicional). A iteração que funcionou: um config object nomeado com os dois estados completos, cada um somando exatamente 100%:

```ts
const COLUMN_WIDTHS = {
  base: { process: '30%', occurrences: '15%', possibilities: '15%', productivePercentage: '20%', age: '20%' }, // 100%
  withObjectives: { process: '22%', objectives: '40%', occurrences: '8%', possibilities: '8%', productivePercentage: '12%', age: '10%' }, // 100%
} as const;
// no componente: const widths = showObjectives ? COLUMN_WIDTHS.withObjectives : COLUMN_WIDTHS.base;
```

- **Não use `flex: 1` na coluna larga + `width` px fixo na condicional como primeira tentativa.** Fiz isso e o usuário reclamou que ficou "muito apertado" — `flex` tira o controle explícito de cada coluna e o resultado varia com conteúdo/tela. Ele mesmo propôs voltar pro config object: *"a opção A dá maior controle sobre o tamanho de cada coluna"*.
- As colunas numéricas estreitas (Ocorrências/Possibilidades/%) têm headers longos em pt-BR; dar `%` explícito evita o auto-size espremer a coluna larga.
- Colunas sem `width` viram "auto" e **não entram na soma** — é isso que torna a soma opaca. O usuário pergunta explicitamente "soma 100%?"; confirme que cada estado soma exatamente 100% antes de dar como pronto.

### Status de objetivo de PEI: reusar `ObjectiveStatus` pro LABEL (não criar i18n novo); cores NÃO têm fonte única

O status do objetivo de PEI aparece em 3 lugares com granularidade e rótulos DIVERGENTES. Ao exibir "status de objetivo" numa tela nova (ex. tags de objetivos relacionados nas avaliações), não crie chave i18n nova nem mapa de cor do zero:

- **`ObjectiveStatus`** (`types/pei.ts`, 5 valores) — `pending='Pendente'`, `validated='Validado'`, `completed='Concluído'`, `in_maintenance='Em manutenção'`, `rejected='Rejeitado'`. É o status do OBJETIVO (o que `peiObjective.status` retorna nas avaliações) e a fonte usada pelo `SelectStatus`/`BadgeStatus` na tela de PEI. **Reuse `ObjectiveStatus[status as keyof typeof ObjectiveStatus]` para o LABEL** — `status` vem tipado `string` (`AssessmentRelatedObjective`), o cast é inevitável.
- **`PeiModuleItemStatus`** (`types/peiTrack.ts`, 9 valores) — status do MODULE ITEM (tela PeiTrack), granularidade maior, e o rótulo de `validated` difere (`'Em andamento'` vs `'Validado'`). Não é o mesmo conceito do status de objetivo; não confunda ao escolher a fonte.
- **Cores são fragmentadas e discordam entre si** — não há fonte única: `BadgeStatus` (`components/BadgeStatus`, design system Atipico `yellow300`/`purple300`...) usa cores DIFERENTES do PeiTrack `Tag.tsx` (`TAGS_BY_OBJECTIVE_STATUS`, antd `success`/`processing`/`red`/`orange`/`blue`). Ex.: `validated` = `purple300` (BadgeStatus) vs `processing`/azul (PeiTrack); `in_maintenance` = `yellow300` vs `blue`. Reusar cor cross-tela exigiria exportar map privado + mapear `ObjectiveStatus`→`PeiModuleItemStatus` (ambiguidade: `completed`→3 valores `COMPLETED_*`). Mantenha um `STATUS_COLORS` local (5 pares, antd, alinhado ao PeiTrack).
- `notStarted` (objetivo não vinculado = `peiObjective` null) é status SINTETIZADO, sem equivalente nos enums — mantenha no i18n. (`PeiModuleItemStatus.TO_DO`='A fazer' é o mais próximo, mas label + enum diferentes.)

Pitfall de review real: a revisora LBeghini apontou exatamente essa duplicação — `relatedObjectives.status.*` no i18n re-criava `ObjectiveStatus`. Resposta certa: reusar o enum (labels), manter `STATUS_COLORS` (cores) e `notStarted`/`toggle` no i18n.

## Modelo de dados PEI/Objective: `libraryObjective` singular vs array; `peis[0]` é a convenção; unicidade é por `description`

Fatos estruturais do domínio de objetivos do PEI (úteis tanto para feature work quanto para revisar PRs nesse domínio — descobri ao revisar o PR que desabilita itens de catálogo já ativos no formulário "Novo objetivo"):

- **`ProtocolItem` (`types/pei.ts`) tem DOIS campos para o objetivo de biblioteca**: `libraryObjective?` (singular) E `libraryObjectives?` (array). Não é redundância — são disciplinas com shapes diferentes: **SymbolicPlay tem UM objetivo por subdomínio** (usa o singular, `currentProtocolItem?.libraryObjective?.description` em `SymbolicPlayForm`), enquanto SpeechTherapy / OccupationalTherapy / Occupational / Vineland usam o array (`item.libraryObjectives.map(...)`). Ao escrever lógica que varre objetivos de biblioteca por disciplina, NÃO unifique esses dois campos — confirme qual shape a disciplina em questão usa antes de acessar.
- **`peis?.[0]?.objectives` é a convenção para "o PEI atual" do caso clínico** — usada de forma consistente em `PEI/Home`, `Checkin`, `Sessions/Preparation`, `Users/Planning/Details`, `SessionPlanning/Details`. O tipo `PEI` tem `version`, mas a codebase trata `peis[0]` como o PEI ativo; não trate "usar `[0]`" como bug de multi-PEI (é padrão estabelecido).
- **Unicidade de objetivo no PEI é validada no backend por `description`**, não por id: `VALIDATION_DESCRIPTION_TAKEN` sobre `discarded_at: nil`. Consequência para o frontend: para desabilitar itens de catálogo "já usados", monte um `Set<string>` das `description` existentes e compare por `description` (espelha exatamente o que o backend vai rejeitar no submit). É o que `pages/PEI/New/New.tsx` faz: `GET_CLINICAL_CASE_PEI_OBJECTIVES` + `useMemo` que constrói o `Set`, propagado como `takenDescriptions?: Set<string>` pelos `Form`/hooks.
- **Pitfall de over-fetch**: `GET_CLINICAL_CASE_PEI_OBJECTIVES` retorna dados profundamente aninhados (programs, targets, measurement data, prompt schedules, configurations) — para só montar o `Set` de descrições, apenas `objectives { description }` é necessário. Reusar a query evita duplicação, mas pese o custo de payload; uma query leve dedicada é uma alternativa legítima.
- **Correspondência de `description` colide se dois itens de catálogo distintos tiverem o mesmo texto** — mas como o backend também valida por descrição, desabilitar por `description` é consistente (não é bug, só um limite do contrato).

### Novo provider de contexto → adicionar ao `test-utils.tsx` `AllTheProviders`

Quando você introduz um provider de contexto que um componente/hook consome (e o hook lança `must be used within ...` sem provider), os specs existentes dos formulários quebram com esse erro — eles renderizam via `render` de `test-utils` (`src/test-utils.tsx`), cujo wrapper `AllTheProviders` não conhece o novo provider. Adicione o provider ali (perto do `BrowserRouter`) em vez de mockar em cada um dos N spec files — corrige todos de uma vez.

### Criar uma sessão de fono no dev DB (para testar o fluxo dentro-do-checkin / `sessions`)

O fluxo dentro-do-checkin (`sessions`) exige `sessionId` (o fora-do-checkin `clinical-cases`, não — usa `registryId` e roda sem sessão). Se não houver sessão no dev, crie via `rails runner` + FactoryBot (abaixo) — mas se você sincronizou o banco de development real (`make import-remote-db`), já existem sessões/casos: ache uma direto no SQL em vez de criar (`SELECT s.id FROM assessment_sessions s WHERE s.assessment_speech_therapy_registry_id = '<registry_id>'`; o `general_session` tem o MESMO `id` do `assessment_session`, shared PK, então esse `s.id` é o `sessionId` da rota):

```ruby
require 'factory_bot_rails'
ActsAsTenant.current_tenant = Tenant.find('<tenant_id do registry>')  # sem isso: NoTenantSet
cc = ClinicalCase.find('<case_id>')
reg = Assessments::SpeechTherapy::Registry.find('<registry_id>')
s = FactoryBot.create(:general_session, :with_assessment_sessionable,
  clinical_case: cc, discipline: "speech_therapy",
  sessionable_attributes: { assessment_speech_therapy_registry_id: reg.id })
```

- Para achar o tenant: `Tenant.find_by(name: 'genialcare')` — **NÃO** `Tenant.find_by(external_id: 'genialcare')` (o `external_id` é um hash tipo `org_tiWWPpuGf2Mrve6E`, não o nome legível; `find_by(external_id: 'genialcare')` retorna `nil` e você cai no `NoTenantSet` de novo). O jeito mais à prova de erro é ler o `tenant_id` direto da linha do registry com psql e passar o UUID: `Tenant.find('2bd3d29f-...')`.
- Disciplinas válidas: `["aba", "speech_therapy", "occupational_therapy"]` (`::Enum::ClinicalDisciplines.all`).
- `:with_assessment_sessionable` cria o `assessment_session` (tabela `assessment_sessions`) com o MESMO `id` do `general_session` (polimórfico, shared PK) apontando para o registry via `assessment_speech_therapy_registry_id`.
- Se `general_session` falhar na validação com `Discipline must be one of: ` (lista VAZIA), o model valida `discipline` via `DomainConfiguration::DictionaryRecord::Validation::DisciplineValidatable` — a lista vem de um dicionário de configuração de domínio (`domain_configurations`) que pode estar vazio/não-seedado nesse ambiente. É lacuna de ambiente, não do seu código; não perca tempo tentando outro valor de `discipline`.

## Data contract: campo numérico exposto como `String` no BFF

O BFF expõe vários campos numéricos como `String` no schema GraphQL (ex.: `CalculatedOfficialScheduledHoursByDiscipline.aba`). Quando o frontend usa esse valor (que chega como string, ex. `"2"`) diretamente como `count` no i18next (`t('hours.hoursText', { count: valor })`), a pluralização falha e cai no fallback da chave base (ex. `"0 horas"`).

- Sempre normalize com `Number(valor)` antes de usar em `count` de i18next ou em aritmética.
- Padrão já usado em `clinical-panel/src/pages/CoverPage/Workloads/Schedule/Schedule.tsx`: `count: Number(value)`.
- O tipo TS no frontend pode declarar `number` enquanto o BFF devolve `String` — isso mascara o bug no `tsc`.
- Correção alternativa (raiz): tipar o campo como `Float`/`Int` no BFF, mas é mudança de contrato — a coerção no frontend é mais barata e imediata.

## Fluxo de carga horária (workload): mapa do território

Investigação read-only (2026-09-30) do fluxo completo de carga horária no painel (form → GraphQL → REST, flags, erros, plano de saúde). Detalhe completo, mapa de arquivos e payloads exatos em `references/workload-flow.md`. Fatos que mudam decisões de implementação:

- **Um form = uma disciplina por submit.** `WorkloadsForm` edita UMA disciplina por vez (mudar ABA+Fono+TO = 3 submits); a página de edit não conhece o estado combinado das outras disciplinas.
- **Dropdown de horas é derivado de `workloadLimits` por disciplina** (loop `min..max` gera um option por hora) e é a ÚNICA restrição client-side — não há validação de min/max no submit; a validação real é no core e o erro chega como toast cru.
- **Não existe lógica de TOTAL de horas em nenhuma camada** (nem no frontend, nem no BFF, nem no contrato `WorkloadLimits { aba, speechTherapy, occupationalTherapy }`). Uma regra de total por operadora (ex: Amil ≤ 6h somando disciplinas) exige campo novo no core+BFF+query+form ou validação backend exibida via toast.
  - **→ Implementado para Amil** (story `20260930-amil-nova-regra-carga-horaria`, PRs core #6926 / BFF #749 / panel #2195). Arquitetura do teto total, caso uma sessão futura precise extender/generalizar (ex. outra operadora): `NewAmilRegime` (flag global `enable_new_amil_workload_rule` + plano nome exato `"Amil"` + delay_level + corte de data 2026-10-06) decide se o caso entra no regime novo; `NewAmilWorkload` fornece matriz + teto por delay level; `WorkloadLimits` calcula `max` dinâmico por disciplina (`teto − soma das outras vigentes`, **SEM** `min` com a matriz) e acrescenta campo `total` no payload; `CreateWorkload` valida o teto (isenção para carga `default_value` e exceção para re-prescrição do total vigente). **⚠️ Corrigido 02/10/2026**: a primeira versão usava `min(matriz_max, teto − soma)`, transformando a matriz (5/2/2 etc.) num teto POR disciplina — mas a matriz é apenas a distribuição padrão **sugerida** na primeira avaliação, e o ÚNICO limite rígido é o total semanal (6/7/9h); a distribuição de horas entre disciplinas é livre dentro do teto (ex.: severo permite 9h ABA + 0 Fono + 0 TO). Validei contra a fonte primária (group DM no Slack Regis/Malu/Tamyres/Alberto) quando o usuário suspeitou que a doc estava errada — a doc derivada (PRD/analysis) tinha codificado a matriz como cap. O campo `total` propaga core → BFF (`WorkloadLimits.total`, opcional/null) → panel (hint "Teto semanal Amil" + dropdown que mantém o valor vigente/sugerido selecionável quando excede o max).
  - **Pitfall (teto ≠ soma da matriz quando há override de primeira avaliação):** o `calculate_hours` do `CalculateWorkload` tem regra geral `no_delay && first_assessment? → usa a matriz mild (4/1/1 = 6h)`. Então a entrada `SUGGESTED_WORKLOADS[no_delay]` só vale para REAVALIAÇÃO. Não derive o teto como `SUGGESTED_WORKLOADS[no_delay].values.sum` — se o `no_delay` for 3/1/1 na reavaliação, a soma dá 5h, mas a primeira avaliação prescreve 6h (via mild) e seria rejeitada pelo `validate_total_limit`. O teto do `no_delay` deve seguir o **mild** (6h, o valor da primeira avaliação), não a matriz de reavaliação. Guarda-geral: quando uma matriz de reavaliação difere da de primeira avaliação (override no `calculate_hours`), o teto acompanha a de PRIMEIRA avaliação (o maior).
### Não recompute no frontend uma regra que o backend já calcula e expõe (fonte de dados divergente = risco)

O hint "Teto semanal Amil … restam Xh" inicialmente recalculava o orçamento restante no cliente (`remainingTotalHours = total.max − soma(currentHoursPerDiscipline exceto a selecionada)`), duplicando a regra que o core já aplica em `workload_limits.rb` (`max = teto − current_hours_excluding`) e — pior — usando uma fonte de dados DIFERENTE: o frontend lia `workloadsInEffect` (`workload_hours_in_effect` → `current_recommended_for`, desempate por soma de timestamps), enquanto o backend usa `active_recommended_for` (desempate por `created_at`). Os dois quase sempre coincidem, mas divergem no desempate quando há dois workloads com o mesmo `in_effect_since` — o hint mostraria "restam 5h" enquanto o dropdown (que usa `workloadLimits[disciplina].max` da API) permite até 7h, ou o contrário.

- **Regra**: regra de negócio tem UMA fonte de verdade — o backend. O frontend deve CONSUMIR o valor que já veio na API (`workloadLimits[selectedDiscipline].max`), não recalcular a partir de outra query/outro campo.
- **Sinal**: um `useMemo` no frontend reimplementando uma subtração/limite que o payload da API já traz pronto. Confirme se o campo equivalente já existe no payload antes de escrever a lógica client-side.
- **Fix**: extraia um helper de mapeamento disciplina→limites (o `switch` que já existia para montar o dropdown) e use `workloadLimits[selectedDiscipline].max` no hint — elimina a duplicação E a fonte divergente. O `currentHoursPerDiscipline` (de `workloadsInEffect`) só continua necessário onde alimenta o dropdown (manter o valor vigente/sugerido selecionável mesmo acima do max), não para o hint.
- **Encoding de horas**: GraphQL `hours: Int` vira o par multiparameter Rails `'hours(4i)': N, 'hours(5i)': 0` no body (`clinical_case_workload` no POST `workloads.json`; `workload_input` no PUT `reprove.json`). A resposta volta como duração ISO (`"PT10H"`) — parse no frontend com `dayjs.duration(hours).asHours()`.
- **Hardlock por plano de saúde é sempre ativo** (a flag `ENABLE_HARDLOCK_BRADESCO_BUTTON` foi removida; a constante ficou órfã em `constants/flags.ts`). `restrictedPlans = ['Bradesco Saúde - Operadora', 'Bradesco Saúde', 'Mediservice']` com match exato case-sensitive em `useHealthPlanRestrictions`; `shouldShowButton = isClinicalCaseReference || canShowButton` esconde os botões de editar (carga vigente e sugestão), mas NÃO o de aprovar sugestão. "Amil" não existe em nenhum dos dois repos ainda.
- **Erros de workload não têm mensagens hardcoded no frontend**: `notifyErrorMessages` mostra `businessErrors[].message` primeiro, fallback `extensions.response.body.details[0].errors[0].message || message` — texto do core em toast, verbatim.

## Apollo `cache-first` devolve dado STALE para query com resultado DINÂMICO — use `fetchPolicy: 'network-only'`

O default de `useQuery`/`useAuthorizedQuery` é `cache-first`: na primeira montagem busca da rede e cacheia; ao re-montar (navegar para longe e voltar), devolve o cache SEM refetch. Para queries de resultado ESTÁTICO (ex. limites de default/Porto/Bradesco, que não mudam por delay level) isso era inofensivo. Mas quando o resultado vira DINÂMICO — depende de estado que muda após uma mutation — o `cache-first` faz o dado ficar obsoleto.

Caso real (Amil workload): `workloadLimits` tem `max` por disciplina = `teto − soma das horas vigentes das outras disciplinas`. Depois de salvar uma disciplina, a mutation muda as horas vigentes, mas o Apollo mantém o `workloadLimits` antigo em cache; ao sair e voltar para a tela de edição, o dropdown continua com o `max` antigo (ex. Fono ainda travado em 0–3 em vez de recair para 0–4).

- **Fix**: `fetchPolicy: 'network-only'` nas queries de estado dinâmico — força refetch a cada montagem (e ainda escreve no cache, então outros leitores veem o valor novo). Aplicado em `ClinicalCaseWorkloadsEdit` e `ClinicalCaseSuggestedWorkloadEdit` para `workloadLimits` + `workloadsInEffect`.
- **Regra geral**: quando introduzir um limite/valor derivado de estado mutável (não estático), reavalie as queries que o alimentam — se a página é re-montada após o save e o valor "não recalcula", suspeite de `cache-first` ANTES de procurar bug de lógica de recálculo.
- `network-only` (não `no-cache`) é a escolha certa aqui: `no-cache` não popula o cache, então leitores subsequentes re-fetcham desnecessariamente; `network-only` refetcha mas mantém o cache consistente.

## Extrair seleção GraphQL repetida em um fragment

Quando a mesma seleção GraphQL se repete em vários arquivos de query do mesmo domínio (ex.: `relatedObjectives { itemIdentifier objectives { libraryObjective { id description } peiObjective { status } } }` repetido em 5 queries de sub-avaliação), extraia para um fragment em `src/queries/<domain>/fragments/<name>Fragment.ts` — este repo segue essa convenção (ver `queries/assessments/fragments/itemScoreFragment.ts` como modelo):

```ts
import { gql } from '@apollo/client';

export const ASSESSMENT_RELATED_OBJECTIVES_FRAGMENT = gql`
  fragment AssessmentRelatedObjectivesFields on AssessmentItemRelatedObjectives {
    itemIdentifier
    objectives {
      libraryObjective { id description }
      peiObjective { status }
    }
  }
`;
```

Em cada query: (1) importe o fragment, (2) interpole `${FRAGMENT}` logo após o `` gql` ``, (3) troque a seleção inline por `...FragmentName`:

```ts
import { ASSESSMENT_RELATED_OBJECTIVES_FRAGMENT } from './fragments/assessmentRelatedObjectivesFragment';

export const GET_X = gql`
  ${ASSESSMENT_RELATED_OBJECTIVES_FRAGMENT}

  query getX($registryId: ID!, $clinicalCaseId: ID!) {
    ...
    relatedObjectives { ...AssessmentRelatedObjectivesFields }
  }
`;
```

- **Confirme o nome exato do tipo GraphQL (cláusula `on`) e os campos direto no `type-defs.graphql` do BFF** antes de escrever o fragment — o nome do tipo TS no frontend nem sempre bate com o nome do tipo GraphQL (ex.: no frontend o tipo era `AssessmentItemRelatedObjectives`, e é esse o nome que vai no `on`). Um fragment com tipo/fildes errados não quebra `tsc`/eslint — só falha em runtime quando o BFF valida a query.
- O fragment não precisa de type TS próprio (é só `gql`); o `TypedDocumentNode` da query continua resolvendo os tipos via o fragment interpolado.
- Verificação pós-refactor: `yarn types` + `yarn lint` (full) + `vitest` nas specs afetadas. O `yarn lint` completo costuma pegar violações `prettier/prettier` pré-existentes em arquivos irmãos que você não tocou — rode `eslint --fix` nelas e inclua no mesmo commit (ou ao menos confirme que não é da sua mudança).

### Query GraphQL que ficou morta: o arquivo pode sobreviver só como re-export de type — redirecione e delete

Depois de refatorar uma feature para não usar mais um endpoint (ex.: objetivos relacionados passaram a vir embutidos no `show` da avaliação, matando a query `assessmentRelatedObjectives`), o arquivo da query antiga pode ficar "vivo" apenas porque re-exporta um TYPE que componentes ainda importam (ex.: `export type { AssessmentRelatedObjective } from 'types'` em `getAssessmentRelatedObjectives.ts`). A query em si vira dead code, mas o `export type` mantém o arquivo importado por N componentes.

- **Confirme se a query está realmente morta** buscando pelo NOME da constante (`GET_ASSESSMENT_RELATED_OBJECTIVES`), não só pelo nome do arquivo — se nenhum arquivo importa a constante (só o type), a query é dead.
- **Fix limpo**: redirecione os imports de type dos componentes direto para `types` (`import { AssessmentRelatedObjective } from 'types'`) e delete o arquivo (remova também o `export *` no barrel `queries/<domain>/index.ts`). Não deixe o arquivo só como "re-export de type" — é indireção que esconde onde o type realmente vive (`types/`).

### `lodash` já é dependência do repo — use `lodash/camelCase`, não reimplemente snake→camel

Vários arquivos já importam de `lodash` (`lodash/debounce`, `lodash/pickBy`, `_ from 'lodash'`). Para converter `snake_case`→`camelCase` (ex.: `uses_vocalizations`→`usesVocalizations`), use `import camelCase from 'lodash/camelCase'` em vez de escrever um helper local com regex. `_.camelCase` cobre os mesmos casos e mais (underscores duplos, acrônimos, leading/trailing underscores).

## Removendo feature flags (SplitIO) no frontend: cuidado com specs que dependem do default "off" em teste

Ao remover uma flag do tipo `DISABLE_X` (ou qualquer flag) de `src/constants/flags.ts` e hardcodar o comportamento "sempre ligada", **não baste alterar o componente e seu spec direto** — rode a suíte completa (`CI=true yarn vitest run --bail=1`) antes de abrir o PR, porque:

- `useFeatureFlag` usa `useTreatments` do `@splitsoftware/splitio-react`. Em testes, o SDK do Split.io normalmente **não é mockado** (não há mock global em `setupTests.ts`), então `useTreatments` retorna o treatment `'control'` por padrão → `defaultTreatment(treatment) = treatment === 'on'` → **a flag sempre avalia como `false` (desligada) nos testes**, mesmo que em produção ela esteja ligada.
- Isso significa que specs em OUTROS arquivos (não o componente que você está mexendo) podem ter sido escritos assumindo o comportamento de "flag desligada" — porque é isso que sempre rodou em CI. Quando você hardcoda o comportamento de "flag ligada", esses specs quebram mesmo sem você tocar neles.
- Exemplo real: ao remover `DISABLE_INTERVENTION_COMPLETE_SESSION_PARTICIPANTS` de `ConfirmedFields.tsx` (fazendo `enableParticipantsEdition = !isIntervention`), o arquivo `src/pages/Sessions/Complete/__tests__/Complete.spec.tsx` quebrou: vários testes com sessão do tipo `Intervention` tentavam digitar/selecionar um clínico adicional no campo `clinicians-input`, que agora fica `disabled`/`hidden` para esse tipo de sessão. Foi necessário ajustar os mocks de `clinicianIds` esperados (removendo o clínico que não pode mais ser adicionado via UI) e trocar `fillSessionForm({ clinicians: [mockClinicians[0]] })` por `fillSessionForm({ clinicians: [] })` nesses casos.
- **Procedimento recomendado**: depois de remover a flag e ajustar o componente + spec "óbvio", rode a suíte inteira. Se algo quebrar, o padrão do bug é sempre o mesmo — um teste que assumia o ramo "flag off" porque era o default de teste. Corrija esses testes para refletir o comportamento final (documentando a decisão no PR), não reverta a remoção da flag.
- `yarn vitest run <arquivo>` roda rápido; a suíte completa (`yarn vitest run` sem filtro, ~4 min) é o que realmente garante que não sobrou nenhum teste dependente do default antigo — vale a pena rodar antes do push final mesmo que o escopo pedido pelo usuário liste só 1-2 arquivos.

## Removendo várias feature flags em lote (orquestração com subagentes)

Quando o pedido é "remove todas as feature flags obsoletas" (não uma só), o
volume — clinical-panel tende a acumular 15-20+ flags em `src/constants/flags.ts`
— exige orquestração, não execução flag-a-flag manual. Abordagem que funcionou:

1. **Mapear uso real antes de agrupar por tema.** Não confie em nomes de
   constante para inferir relação — rode `grep -rl "\bFLAG_NAME\b" src
   --include='*.ts' --include='*.tsx'` para cada flag e agrupe pelos arquivos
   que ela realmente toca. Um agrupamento "por nome" (ex. todas com
   `THERAPY` no nome) pode juntar flags que não têm nada em comum, e separar
   flags que compartilham componente (ex. `CLINICAL_CASE_OWNER_HOME_ENABLED`
   e `THERAPIST_AREA` só ficam claramente relacionadas quando se vê que
   ambas tocam `MenuContent.tsx`/dashboard do Metabase no painel).
2. **Aceite um grupo "outros"/catch-all.** Nem toda flag pertence a um tema
   coerente — forçar agrupamento onde não há relação real (ex.
   `PLANNING_BY_CLINICAL_CASE_PAGE`, `COMPLETE_DISCIPLINE_ENABLED`,
   `SHOW_HOME_UPCOMING_SESSIONS_CARD`, `AVAILABLE_HOURS_OFFER` neste projeto)
   só confunde. Um catch-all explícito é mais honesto que um agrupamento
   artificial.
3. **Valide o fluxo completo com 1 flag simples antes de escalar.** Antes de
   disparar 15+ subagentes, rode 1 flag de baixo uso (2 arquivos) ponta a
   ponta: subagente → testes locais → PR → CI → sua revisão. Isso expõe cedo
   os dois problemas recorrentes: (a) o subagente que hits o limite de
   iterações reporta "push feito" sem ter commitado (ver
   `multi-agent-orchestration` skill, pitfall "push already done" — sempre
   confirme com `git fetch origin <branch> && git log origin/<branch>
   --oneline` você mesmo antes de aceitar); (b) o efeito colateral do
   default "flag off" nos testes (seção acima).
4. **Base do PR: confirme com histórico real, não suposição.** `gh pr list
   --state merged --limit 5 --json baseRefName` para saber se o time abre PR
   contra `main` ou `development` antes de instruir os subagentes — CLAUDE.md
   do repo organizador pode estar desatualizado ou ambíguo sobre isso.
5. Instrua cada subagente a, antes de finalizar: rodar a suíte completa
   (`CI=true yarn vitest run --bail=1`), fazer `grep` para confirmar 0
   referências restantes à flag, e confirmar explicitamente `git
   status`/`git log origin/<branch>` (não apenas relatar de memória).

## Removendo uma flag: recontaminação do arquivo compartilhado DEPOIS de já ter limpado uma vez

Quando `flags.ts` (ou outro arquivo muito compartilhado) é editado por uma
tarefa irmã em paralelo, a contaminação não é um evento único — o arquivo pode
ser sobrescrito de novo DEPOIS que você já removeu sua linha e seguiu em
frente para outros arquivos. Sintoma: você reaplica a remoção, segue
trabalhando em specs/componentes por vários passos, e ao rodar `grep` final
pela flag ainda encontra a constante em `flags.ts` — não porque o patch
falhou, mas porque o arquivo foi reescrito por outro agente enquanto você
mexia em outros arquivos.

- Não assuma que resolver a contaminação uma vez no início basta. Rode
  `grep`/`search_files` pela flag no repo inteiro **de novo, logo antes do
  commit final** (não só logo após o `git checkout -b`).
- Se reaparecer, reaplique a remoção pontual (old_string/new_string do seu
  trecho, nunca reescrevendo o arquivo inteiro) e não toque nas linhas de
  outras flags que estejam presentes — elas são o trabalho legítimo da tarefa
  irmã, mesmo que tenham "voltado" no meio do seu fluxo.
- Ao montar a lista de arquivos para `git add`, gere-a a partir de `git status
  --short` checado nesse momento final, não de uma lista mental feita no
  início da tarefa — o conjunto de arquivos tocados por você é estável, mas o
  conteúdo de arquivos compartilhados (`flags.ts`) pode ter ido e voltado.

## Removendo uma flag: um componente inteiro pode colapsar para "sempre null", não só uma prop

Quando o componente usa a flag dentro de uma condição OR de early-return (ex.
`if (flagSempreLigada || outraCondicao || maisOutra) return null;`), tornar a
flag permanentemente `true` faz essa condição ser **sempre verdadeira** —
o componente inteiro passa a renderizar `null` incondicionalmente, não é só
uma prop que fica fixa (o caso de prop fixa já está coberto mais abaixo, mas é
distinto: ali uma prop de um componente FILHO fica sempre no mesmo valor;
aqui o próprio componente que tinha a flag deixa de renderizar qualquer
coisa).

- Confirme esse colapso lendo os testes do componente antes de simplificar:
  se o describe "quando a flag está habilitada" já testava "não mostra X",
  isso confirma que o comportamento final é `return null` sempre.
- Simplifique o componente para retornar `null` incondicionalmente (com um
  comentário citando o nome da flag removida e por quê), mantendo a mesma
  assinatura de props se o componente pai não fez parte do escopo pedido —
  evita precisar editar o caller.
- Não delete o arquivo do componente nem remova seu import do caller a menos
  que isso tenha sido pedido explicitamente; um componente-vestígio que só
  retorna `null` é o diff mínimo e mais seguro.

## Timeout de teste isolado não é necessariamente regressão: reproduza sem paralelismo antes de investigar a fundo

Ao rodar vários spec files juntos (`yarn vitest run <arquivo1> <arquivo2>
...`), é comum ver 1-3 testes falharem com `Test timed out in 5000ms` mesmo
sem relação lógica com a mudança feita — é contenção de recursos entre
workers paralelos do Vitest, não regressão do seu código. Outro sinal do
mesmo tipo de falso positivo, mas com assinatura diferente: erro
`Unable to perform pointer interaction as the element has
'pointer-events: none'` vindo de `@testing-library/user-event` num teste que
não tem relação com o arquivo que você mudou (ex. um teste de fechar banner
de erro falhando durante a remoção de uma flag em outro componente
completamente distinto). Ambos são flakiness de CI sob carga, não bug real.

- Antes de tratar como bug real, reisole os arquivos que falharam e rode de
  novo com `--no-file-parallelism` (ou apenas os 1-2 arquivos que falharam,
  sozinhos). Se passarem limpo nesse modo, é flakiness de paralelismo — não
  investigue mais a fundo nem reverta a mudança por causa disso.
- Só trate como regressão real se a falha persistir isolada/sem paralelismo,
  ou se a mensagem de erro for de asserção (valor incorreto) e não de
  timeout/`pointer-events`/console-warning genérico.
- Se a falha aconteceu no CI (não localmente) e o shard seguinte foi
  cancelado por `--bail=1`, rode o arquivo isolado localmente (ou num
  worktree fresh a partir do commit do PR) para confirmar antes de gastar
  tempo investigando a fundo. Se passar, dispare `gh run rerun <run-id>
  --failed` em vez de reescrever código — reexecuta só os jobs que
  falharam, sem novo push.

## Removendo uma flag: workspace pode ter trabalho não commitado de OUTRA flag em andamento

Quando várias remoções de flag rodam em sequência/paralelo no mesmo working
directory persistente (não um clone novo por task), é possível herdar índice
git (staged) e/ou working tree sujos de uma tarefa anterior/irmã que ainda não
commitou. Sintoma: depois de editar só o que você pediu, `git status --short`
mostra arquivos que você nunca tocou (ex. `MM flags.ts`, ou specs em outra
pasta completamente sem relação com sua flag).

- **Sempre confira `git status --short` logo depois do `git checkout -b` e de
  novo antes de commitar.** Se aparecer arquivo fora do escopo da sua flag,
  pare antes de commitar.
- Diagnóstico: `git diff --cached -- <arquivo>` (HEAD vs índice) separado de
  `git diff -- <arquivo>` (índice/HEAD vs working tree). Se `--cached` já
  mostra remoção de uma constante que não é a sua, tem trabalho de outra
  tarefa staged nesse índice.
- Correção sem perder o trabalho alheio: `git reset` (desfaz apenas o stage,
  não toca no working tree) e depois **restaure no seu arquivo qualquer
  linha/constante que não seja da sua flag** de volta ao estado de HEAD
  (`git show HEAD:<arquivo>` para conferir o que deveria estar lá). Isso
  isola seu diff sem descartar o progresso de quem está mexendo na outra flag
  — a decisão de commitar/descartar aquilo é do dono daquela tarefa, não sua.
- Antes do commit final, rode `git diff -- <cada arquivo que você vai
  commitar>` e confirme que cada hunk corresponde só à sua flag. `git add`
  arquivo por arquivo (não `git add -A`) quando o workspace estiver
  potencialmente contaminado.

### Pior caso: a tarefa irmã troca de branch no meio da sua execução

O cenário acima assume que o branch não muda sob seus pés — mas quando duas
tarefas de remoção de flag rodam em paralelo no MESMO working directory
persistente (não worktrees separados), a tarefa irmã pode rodar `git
checkout -b <branch-dela>` entre duas das suas chamadas de ferramenta. Sintomas
que você só percebe DEPOIS de commitar:

- `git commit` reporta sucesso, mas `git log --oneline -3` mostra seu commit
  no topo de um branch com nome que você nunca criou (o branch da tarefa
  irmã). `git branch --show-current` confirma que você não está mais no seu
  branch — mesmo que seu branch (`git branch -a`) ainda exista, intacto.
- Um arquivo que você editou (ex. `flags.ts`) já tinha sido resetado para
  HEAD e reescrito pela tarefa irmã antes do seu `git add` rodar — sua
  remoção de constante "desapareceu" do arquivo e a remoção deles apareceu
  no lugar, mesmo sem você ter feito `git checkout`/`git reset` nele. Sinal:
  `git diff` de um arquivo que você editou não mostra sua mudança esperada
  antes de você commitar.

**Recuperação sem perder trabalho de ninguém** (testado e funcionou):
1. `git log --oneline -3` e `git branch --show-current` para confirmar em
   qual branch seu commit realmente foi parar.
2. `git reset --soft HEAD~1` nesse branch (o da tarefa irmã) — desfaz só o
   commit, mantém os arquivos como estavam staged, sem tocar no que não foi
   commitado.
3. Restaure cada arquivo seu (`git restore --staged <arquivo>` +
   `git checkout -- <arquivo>`) para o estado que a tarefa irmã esperava —
   se for um arquivo que só você tocou (ex. o componente da sua flag),
   `git checkout -- <arquivo>` basta. Se for um arquivo compartilhado (ex.
   `flags.ts`, onde as duas tarefas removem constantes diferentes),
   `checkout --` reverteria também a remoção deles — em vez disso,
   reescreva o arquivo inteiro via `write_file` com APENAS a remoção deles
   presente (a constante da tarefa irmã fora, a sua de volta), replicando o
   estado que existia antes da sua interferência.
4. Confirme com `git diff -- <arquivo>` que o branch da tarefa irmã voltou a
   ter só a mudança dela, e `git status --short` que nenhum arquivo seu
   restou modificado ali.
5. Para aplicar seu trabalho no SEU branch sem repetir a edição manualmente:
   `git worktree add /tmp/<nome> <seu-branch>` (cria uma working tree
   isolada, sem interferência da tarefa irmã) e `git cherry-pick <hash do
   commit que você tinha feito antes do reset>` dentro dela. Isso preserva
   sua mensagem de commit e diff exatos sem precisar reconstruir os patches.
6. Lição geral: quando há qualquer sinal de que outra tarefa está ativa no
   mesmo working directory (arquivos modificados fora do seu escopo — ver
   seção anterior), prefira criar sua PRÓPRIA `git worktree` logo no início
   da tarefa (`git worktree add /tmp/<nome> -b <seu-branch>`) em vez de
   `git checkout -b` no diretório compartilhado. Custa um `yarn install` ou
   os symlinks de `node_modules`/`styled-system` (ver seção de worktree mais
   abaixo), mas elimina de vez o risco de branch-switch e reset alheios
   afetarem seu commit.

## `patch` reporta sucesso com diff mas a mudança não persiste: cuidado com texto duplicado no arquivo

Em specs com blocos `it(...)` de nome literalmente duplicado (ex. duas
ocorrências de `it('does not render filter option overdue when user has no
access', ...)` no mesmo arquivo) é possível a ferramenta `patch` retornar
`success: true` com um `diff` que parece correto, mas o conteúdo real gravado
em disco não refletir a mudança pretendida — ou refletir só parte dela.
Sintoma: minutos depois, um `grep`/`search_files` pela string que você
"removeu" ainda a encontra no arquivo, mesmo sem nenhuma tarefa irmã ativa
naquele working directory (ou seja, não é o cenário de contaminação
cross-task descrito acima — é a própria ferramenta de patch não persistindo
o hunk certo quando o texto-alvo não é único no arquivo).

- **Nunca confie apenas no `diff` retornado por `patch` como prova de que a
  mudança foi aplicada**, especialmente em arquivos com blocos de teste
  repetidos/nome duplicado ou quando o `old_string` aparece em mais de um
  lugar do arquivo. Depois de uma leva de patches num arquivo assim, rode um
  `grep`/`search_files` de confirmação pelo texto removido antes de seguir
  para o próximo arquivo — não espere até o commit final para descobrir.
- Ao final da tarefa (antes do commit), sempre rode a busca pela
  constante/string-alvo no diretório inteiro de novo — não assuma que
  patches individuais "confirmados" ao longo do caminho continuam válidos.
- Se encontrar um arquivo que reverteu, não tente mais um `patch`
  incremental no mesmo trecho ambíguo — reescreva o arquivo inteiro via
  `write_file` (leia o arquivo completo primeiro) para eliminar qualquer
  ambiguidade de matching. Isso resolveu de forma confiável quando `patch`
  incremental tinha falhado silenciosamente no mesmo arquivo.
- Depois de remover um import que só existia para setar comportamento
  agora sempre-on (ex. `enableFlags` de `test-utils`, ou a constante da
  flag), rode `yarn eslint --max-warnings=0 <arquivos tocados>` antes de
  considerar pronto — o import passa a ficar sem uso
  (`@typescript-eslint/no-unused-vars`) e isso derruba o job de lint do CI
  mesmo com todos os testes passando. `eslint --fix` corrige a formatação
  resultante (ex. quebra de linha de import multi-linha que virou
  single-linha) mas não remove sozinho o import não usado.

## Editar spec com `describe`/`it` aninhados: patch por old_string/new_string quebra brace-matching

Remover um nível de `describe` (ex. o wrapper `describe('when feature flag is
enabled')`) via `patch(old_string, new_string)` é arriscado quando o bloco tem
vários níveis de aninhamento — é fácil remover a abertura de um `describe` e
esquecer de remover o `});` de fechamento correspondente (ou vice-versa),
gerando um arquivo com chaves desbalanceadas que o LSP só aponta como erro
genérico de sintaxe várias linhas depois do problema real.

- Para remoção de um nível de aninhamento em arquivo de teste, é mais seguro
  puxar a versão original do arquivo (`git show origin/main:<path> >
  /tmp/original.tsx`), ler o arquivo inteiro, e reescrever o arquivo inteiro
  via `write_file` já com a indentação e chaves corretas — em vez de várias
  chamadas incrementais de `patch` tentando acertar chave por chave.
- Sinal de que você entrou nesse buraco: diagnósticos de LSP tipo
  "Declaration or statement expected" ou "Cannot find name X" em múltiplas
  linhas após um `patch` que parecia inofensivo — pare, não tente mais um
  patch incremental, reescreva o arquivo do zero a partir do original.

## Comandos longos via `terminal(background=true)` (suite completa, `gh pr checks --watch`): node errado + ruído de zsh

Ao rodar a suíte inteira (`CI=true yarn vitest run --bail=1`, ~5-6 min) ou
`gh pr checks <n> --watch`, o comando estoura o timeout de foreground (600s
não é problema, mas o call foreground do orquestrador tem seu próprio limite
de ~60s por resposta) — o padrão certo é `terminal(background=true,
notify_on_complete=true)` seguido de `process(action='wait', timeout=60)` em
loop até `status: exited`.

- **Toda invocação em background imprime ruído de inicialização do zsh no
  campo `output`** (`stty: stdin isn't a terminal`, `Usage: prompt
  <options>...`, `(eval):1: can't change option: zle`) — isso vem do tema/
  plugin do shell interativo tentando rodar em um shell não-interativo, **não
  é falha do comando**. Ignore esse texto e cheque o `exit_code` e o arquivo
  de log redirecionado (`> /tmp/algo.log 2>&1`) para saber o resultado real.
- **`nvm` não é herdado em `background=true`** mesmo que uma chamada
  `terminal()` anterior em foreground já tenha rodado `nvm use
  20.19.2` — o processo em background sobe um shell novo sem o `PATH`
  ajustado, e cai no Node do sistema (mais antigo). Sintoma característico:
  `yarn vitest` falha na inicialização com `SyntaxError: The requested module
  'node:fs/promises' does not provide an export named 'constants'` (erro de
  ESM do Vite, não relacionado ao código da flag). Correção: prefixar o
  próprio comando com `export PATH="/Users/<user>/.nvm/versions/node/<versão
  do .nvmrc>/bin:$PATH" &&` dentro do `command` do `terminal(background=true,
  ...)` — não basta ter feito `nvm use` numa chamada foreground anterior.
  **Cuidado com o `v` no nome do diretório**: os diretórios de versão do nvm
  usam o formato `v20.19.2`, não `20.19.2` (`~/.nvm/versions/node/v20.19.2/bin`).
  Um PATH montado sem o `v` (ex. copiando o valor do `.nvmrc`, que normalmente
  não tem o prefixo) não dá erro de "diretório inexistente" — o `export` roda
  silenciosamente, simplesmente não bate com nada, e o shell cai de volta no
  Node do sistema, reproduzindo o mesmo erro de ESM acima como se o PATH nunca
  tivesse sido setado. Confirme o nome exato com `ls ~/.nvm/versions/node/`
  antes de montar a string, em vez de assumir o formato a partir do `.nvmrc`.
- Não encadeie seu próprio `&` de background dentro do `command` de um
  `terminal(background=true, ...)` (ex. `export PATH=... && yarn vitest ... &
  \necho started $!`). A ferramenta já roda o `command` em background — abrir
  um segundo nível de backgrounding com `&` faz a chamada retornar sucesso
  imediatamente (só ecoa o PID do subshell), mas não há garantia de que o
  `export PATH=...` da mesma linha tenha propagado para o processo real do
  `yarn vitest` antes dele ser forkado. Resultado: o comando "termina" rápido
  sem erro visível, e só ao ler o arquivo de log é que aparece o mesmo erro de
  ESM do node errado — mascarando por mais tempo a causa raiz. Passe o comando
  de teste direto como `command` (sem `&` nem `echo started $!`) e deixe
  `background=true` cuidar de tudo.
- `process(action='wait', timeout=60)` frequentemente retorna
  `status: timeout` mesmo com o processo saudável e progredindo — é só o
  clamp de 60s do wait, não sinal de travamento. Chame de novo com o mesmo
  `session_id` até ver `status: exited`; só then leia o log completo com
  `read_file` (a suíte inteira gera arquivo de log grande, use `offset`
  próximo do fim para pegar o resumo `Test Files ... / Tests ...`).

## Worktree novo: symlinkar `node_modules` e `src/styled-system` do clone principal

Um `git worktree add` cria uma working tree limpa sem `node_modules` nem os
artefatos gerados (`src/styled-system` do Panda CSS). Rodar `yarn install`
do zero nesses casos custa vários minutos por worktree — desnecessário se já
existe um clone principal instalado e íntegro ao lado:

```bash
ln -s /caminho/do/clone-principal/node_modules node_modules
ln -s /caminho/do/clone-principal/src/styled-system src/styled-system
```

Isso deixa `yarn vitest`, `yarn eslint`, `yarn types` e `yarn build` prontos
para rodar no worktree imediatamente. Só rode `yarn install` de verdade no
worktree se o `package.json`/lockfile do branch divergir do clone principal
(dependência nova, versão bumped).

## Worktree novo: colisão de nome de branch se você já rodou `git checkout -b` no clone compartilhado

Se você já fez `git checkout -b <nome-da-flag>` no clone/working directory
compartilhado ANTES de perceber a contaminação (ver seções acima), não dá pra
criar o worktree isolado com esse mesmo nome de branch — `git worktree add`
falha com `fatal: '<nome-da-flag>' is already checked out at '<clone
principal>'` (git não permite o mesmo branch checked out em dois worktrees
simultaneamente).

- Não perca tempo tentando trocar o branch do clone principal para liberar o
  nome — isso mexe no HEAD que a tarefa irmã pode estar usando/observando.
- Crie o worktree com um nome de branch temporário qualquer a partir de
  `origin/main` (`git worktree add <path> -b wt-<algo-descritivo>
  origin/main`), faça todo o trabalho e o commit lá dentro normalmente.
- Na hora de publicar, não precisa renomear o branch local — dá pra empurrar
  direto para o nome de branch remoto correto: `git push origin
  wt-<algo-descritivo>:<nome-da-flag-correto>`. Isso cria/atualiza
  `origin/<nome-da-flag-correto>` sem exigir que o nome local bata com o
  remoto, e evita qualquer conflito de "já checked out" do início ao fim.
- O branch órfão criado sem querer no clone principal (`<nome-da-flag>`, sem
  commits) pode ficar ali sem problema — é só um ponteiro extra; delete depois
  com `git branch -d <nome-da-flag>` quando o clone principal não estiver mais
  em uso por ninguém, sem pressa.

## Diagnóstico rápido: `git worktree list` antes de investigar diffs inesperados

Ao entrar num repo compartilhado (`clinical-panel` no path canônico, não um
worktree seu) e ver qualquer sinal de contaminação — arquivo modificado que
você não tocou, `git status` sujo antes de você editar nada — rode `git
worktree list` **primeiro**, antes de tentar `git diff`/`git log` para
reconstruir o que aconteceu. Ele responde duas perguntas de uma vez:

- Se o checkout compartilhado aparece na lista já em um branch
  `chore/remove-flag-*` (ou qualquer nome de tarefa que não é a sua), isso
  sozinho já confirma que outra tarefa está rodando ali — não precisa
  aguardar o warning do `patch` ou um `git status` sujo para saber; o simples
  fato de o branch atual não ser `main`/o seu já é o sinal.
- Se já existem outros worktrees (`/Users/.../worktrees/clinical-panel-<algo>`)
  ao lado do checkout principal, isso confirma que o padrão da tarefa (várias
  remoções de flag em paralelo, uma por subagente) já está em andamento com
  outras instâncias usando exatamente a técnica de isolamento recomendada
  abaixo — reforça que a resposta certa é replicar o mesmo padrão (seu
  próprio `git worktree add ... origin/main`), não tentar "consertar" o
  checkout compartilhado.

## Detectar contaminação de sibling task ANTES de commitar: warning do próprio `patch`

A ferramenta `patch` retorna um campo `_warning` quando o arquivo que você
acabou de escrever foi modificado por outro subagente (`sibling subagent`)
depois da sua última leitura. Trate esse warning como sinal de alarme
imediato, não como ruído — ele geralmente aparece ANTES de você perceber
qualquer outro sintoma (branch trocado, `git status` sujo). Ao vê-lo:

1. Releia o arquivo na hora para ver o que realmente ficou gravado.
2. Rode `git branch --show-current` e `git status --short` imediatamente —
   é comum esse warning coincidir com o cenário "pior caso" (tarefa irmã
   trocou de branch sob seus pés, ver seção acima) mesmo sem você ainda
   ter commitado nada.
3. Se confirmar que o branch mudou e você ainda não commitou, não tente só
   "continuar de onde parou" — descarte suas edições diretas no diretório
   compartilhado (`git checkout -- <seus arquivos exclusivos>`, reconstrua
   manualmente a linha que é sua em arquivos compartilhados como
   `flags.ts`) e migre o resto do trabalho para uma `git worktree` isolada
   a partir de `origin/<branch base>` antes de continuar. Reaplicar os
   mesmos `patch`/`write_file` que você já tinha montado é rápido — não
   precisa reconstruir o diff do zero, só repetir as chamadas apontando
   para os caminhos do worktree.

## `gh pr checks <N>`: exit code 8 enquanto pending não é falha

`gh pr checks` retorna exit code 8 sempre que pelo menos um check ainda não
está `pass` (inclui `pending`/`running`). Ao fazer polling manual (`sleep N &&
gh pr checks <N>`, sem `--watch`, por instrução do usuário ou por preferir
controlar a cadência você mesmo), não trate esse exit code como erro de
ferramenta — leia a coluna de status impressa (`pending`/`pass`/`fail`) linha
a linha para decidir se continua esperando. Só pare o loop quando toda linha
mostrar `pass`, ou quando aparecer `fail` de verdade.

## `mergeStateStatus=BLOCKED` não é sinônimo de conflito — confirme antes de tratar como tal

O campo `mergeStateStatus` do GitHub tem valor `BLOCKED` para várias causas
diferentes (falta de aprovação de review, CI ainda rodando, conflito de
merge) — não assuma "conflito" só porque veio `BLOCKED`. Sempre cruze com:

- `mergeable` (`gh pr view <N> --json mergeable`): só é conflito de fato se
  vier `CONFLICTING`. Se vier `MERGEABLE`, o `BLOCKED` é por outro motivo
  (tipicamente falta de review approval ou CI pendente).
- `gh pr checks <N>`: confirma se o bloqueio é CI ainda rodando/falhando.
- `reviewDecision` (`gh pr view <N> --json reviewDecision`): `REVIEW_REQUIRED`
  sem nenhuma aprovação ainda é a causa mais comum de `BLOCKED` com
  `mergeable=MERGEABLE` e CI 100% verde.

## Merge recusado por branch protection mesmo com CI verde e `mergeable=MERGEABLE`

`gh pr merge <N> --squash --delete-branch` pode falhar com **"the base
branch policy prohibits the merge"** mesmo quando CI está 100% verde,
`mergeable=MERGEABLE` e não há comentário pendente do Gemini — a causa
típica é branch protection exigindo aprovação de review humana
(`reviewDecision=REVIEW_REQUIRED`) que ainda não aconteceu, mesmo que o
reviewer/time já tenha sido solicitado.

- **Não use `--admin` para contornar.** Isso bypassa a política do repo
  deliberadamente — é uma decisão de escopo do usuário/dono do repo, não
  algo para o agente decidir sozinho.
- **Não use `--auto`** a menos que o usuário peça explicitamente — habilita
  merge automático assim que os requisitos forem satisfeitos, o que pode
  mergear sem revisão humana ter realmente visto o diff final se a aprovação
  vier de forma automatizada/desatenta.
- Reporte esse PR como "pronto, aguardando aprovação de review" (não
  "aguardando CI" nem "conflito") no resumo final e no README de
  acompanhamento — é uma categoria de status distinta que precisa entrar na
  tabela de status por grupo (ver seção "Sincronizando Jira" abaixo: isso
  também significa que a subtask correspondente **não** deve ir para Done).

## Comentário do Gemini já resolvido em execução anterior: confirme pelo padrão de thread, não só pela ausência de novo comentário

Ao checar `gh api repos/<org>/<repo>/pulls/<N>/comments`, um comentário do
`gemini-code-assist[bot]` só está de fato resolvido quando a thread mostra 3
elos: (1) comentário original do bot, (2) reply do humano/agente linkando o
commit da correção (ex. `@gemini-code-assist Obrigado! Corrigido em <hash>`),
e (3) reply de reconhecimento do próprio bot. Se qualquer um dos três estiver
faltando, trate como pendência ainda aberta — não assuma resolvido só porque
não há comentário novo desde a última checagem. Filtre por
`in_reply_to_id`/`user.login` para reconstruir a cadeia completa antes de
decidir se precisa agir.

### Gemini re-sinaliza o MESMO problema numa nova rodada de review + sugestões com nuance técnica (PG/NULL)

O bot `gemini-code-assist` pode re-sinalizar uma questão já resolvida quando roda de novo num commit posterior (novo review round), gerando um comentário DUPLICADO na mesma linha — mesmo que a thread anterior já tenha a cadeia completa de 3 elos. Não trate como pendência nova: verifique se há uma thread anterior na mesma linha (`discussion_r<id>`) e, se houver, apenas responda referenciando-a ("já discutido em <link da thread>"), sem reaplicar a mudança.

Além disso, as sugestões do bot às vezes carregam premissas técnicas que NÃO valem neste repo:

- **`nulls_not_distinct: true` num índice único exige PostgreSQL 15+** — este repo roda **PG 14** (14.24), então a opção não existe no Rails/Postgres daqui. O gap de `NULL` fica coberto pela validação de unicidade do Rails (`uniqueness: { scope: [...] }`, que gera `IS NULL` no scope e trata NULL corretamente).
- **Índice único padrão do PG não impõe unicidade entre valores `NULL`** (`NULL <> NULL`). Consequência: um teste de nível de DB (`duplicate.save!(validate: false)` esperando `ActiveRecord::RecordNotUnique`) **falha** se a coluna do índice for `NULL` (o default da factory). Para exercitar o índice de verdade, use um valor NÃO-nulo na coluna (`feature_name: "..."`). A validação de Rails continua cobrindo o caso NULL no nível da aplicação — só o índice do DB não cobre.
- **Sugestão "defensiva" pode INVERTER a semântica do `nil`, não só guardar contra erro.** Caso real (Amil): o bot sugeriu `(first_workload_at || Date.current).to_date >= CUTOFF` para "tratar nil defensivamente". Mas o `nil` aqui tinha significado de domínio — um caso sem workload nenhum é *família nova* e DEVE entrar no regime novo (regra `first_workload_at.nil? || ...`), porém `Date.current < cutoff` (antes do corte) faria a expressão avaliar `false` e o caso cairia no regime legado. Um fallback `|| <valor>` muda o que o `nil` SIGNIFICA; só é seguro quando o `nil` é "ausência de dado a ser preenchida", não quando é "estado de negócio distinto". Verifique o que a mudança faz no caso nil/vazio/desempate antes de aceitar, e discorde com justificativa quando estiver errada.

## Removendo uma flag: prop resultante `sempre true` não precisa virar remoção de prop se isso vazar para fora do escopo

Quando remover a flag deixa um componente filho recebendo sempre o mesmo
valor de prop (ex. `<ParentalTrainingForm showInputGoals={showInputGoals} />`
vira sempre `true`), o instinto é "simplificar" removendo a prop do
componente filho também. **Só faça isso se o componente filho e seu teste
dedicado não exigirem edição fora do escopo pedido.** Se o componente
filho tem teste próprio cobrindo os dois valores da prop (`true`/`false`)
e não há evidência de que o valor `false` nunca mais será necessário,
prefira apenas hardcodar `true` na chamada (`<ParentalTrainingForm
showInputGoals />`) e deixar o componente filho genérico como estava — menor
diff, menor risco, e não força um redesenho de API que não foi pedido.

## Removendo uma flag: `extraValidation` (ou prop opcional similar) que vira sempre `true` — delete a chave, não hardcode o valor

Quando a flag controla um campo opcional dentro de um objeto de configuração
(ex. `extraValidation?: boolean` num array de itens de menu, como em
`getMenuItemsOptions`), e o comportamento final é "sempre visível/ativo", a
correção mais limpa **não é** trocar `extraValidation: flagEnabled` por
`extraValidation: true` — é remover a linha inteira. Um campo opcional
ausente já produz o comportamento "sempre ativo" que o código consumidor
espera (ex. `isAuthorizedComponent(name, undefined)` trata `undefined` da
mesma forma que a ausência de restrição extra). É o mesmo princípio da seção
"prop resultante sempre true não precisa virar remoção de prop" abaixo, mas
aplicado ao lado oposto: aqui a chave/prop pertence ao PRÓPRIO objeto que
carregava a flag (não a um componente filho reaproveitável fora do escopo),
então o diff mínimo é apagar a chave — não fixá-la em `true`. Lembre de
remover também o parâmetro correspondente na função que monta o objeto
(campo do tipo, destructuring, e qualquer prop repassada de um componente
pai que só existia para carregar esse valor) — não só a linha do valor.

## Falso positivo de suíte completa: `ENOSPC: no space left on device`

Além de timeout/`pointer-events: none` sob paralelismo (ver seção abaixo),
`yarn vitest run` completo pode falhar em arquivos aleatórios sem relação com
a mudança feita com `Error: ENOSPC: no space left on device` ao importar
assets (`.svg?react`, `.module.css`) — isso é o disco da máquina host cheio
(confirme com `df -h /tmp` ou `df -h /` mostrando `Capacity` perto de 100%),
não um bug introduzido pela remoção da flag. Mesmo protocolo dos outros
falsos positivos dessa suíte: confirme que os arquivos que falharam não têm
relação com o que você mudou, rode-os isolados se restar dúvida, e não trate
isso como sinal para investigar mais a fundo nem para reverter a mudança —
é ambiente, não regressão. Não tente "corrigir" o disco cheio por conta
própria (é fora do escopo da tarefa de remover uma flag); apenas registre no
PR/relatório os nomes dos arquivos com falha pré-existente de ambiente e
siga em frente.

## Testes que cobriam o ramo "flag off": consolide, não apenas delete

Ao tornar o comportamento sempre-on, specs que existiam para comparar
"flag on" vs "flag off" (dois `describe`s irmãos, um mockando a flag ligada)
devem ser fundidos em um único cenário que reflete o comportamento final —
inclusive `it.skip` marcados como TODO de migração, que também merecem ter
os dados de teste atualizados para o novo ramo único (mesmo pulados, ficam
como referência futura e não devem continuar testando um ramo morto).

## `eslint --fix` corrige prettier mas não remove imports não usados: rode `yarn lint --max-warnings=0` completo antes de dar push

`eslint --fix <arquivo>` corrige violações de `prettier/prettier`
automaticamente, mas **não remove** um import que ficou sem uso depois de
uma edição (`@typescript-eslint/no-unused-vars` é só reportado, não
autofixável). O CI deste repo roda `yarn lint --max-warnings=0` — ou seja,
um warning de import não usado falha o build tanto quanto um erro. Padrão
recorrente ao remover flags: vários spec files copiados do mesmo template
importam `waitFor` de `test-utils` mas só usam `render`/`screen` depois que
a lógica condicional (que dependia da flag) é removida — o CI acusa 6+
warnings desse tipo espalhados em specs "irmãos" que nem pareciam
relacionados à mudança.

- Depois de qualquer `eslint --fix` em arquivos específicos, rode o comando
  de lint **exatamente como o CI roda** (`yarn lint --max-warnings=0`, sem
  escopo de arquivo) antes de considerar o PR pronto — não confie em
  "rodei --fix nos arquivos que toquei" como suficiente (ver Pattern 21 na
  skill `multi-agent-orchestration`).
- Se o CI falhar só no job de lint (testes passando), é sinal de que faltou
  esse passo — reproduza localmente antes de reabrir investigação mais
  ampla: `yarn eslint --fix src` (escopo completo) resolve os erros de
  prettier; os warnings de import remanescentes precisam de remoção manual
  da linha de import.


## `patch`/`write_file` auto-lint em arquivo `.ts`/`.tsx`: ruído de `node_modules` não é regressão sua

Depois de editar um arquivo `.ts`/`.tsx` com a ferramenta `patch`, o autolint
que ela roda pode disparar um `tsc` avulso (sem o `tsconfig.json`/flags do
projeto, ex. sem `skipLibCheck`) e devolver **centenas de erros** vindos de
`node_modules` (`@types/react-dom`, `@types/react-native`,
`ts-toolbelt`, `dom-view-transitions` — duplicidade de identificadores,
"Type instantiation is excessively deep", etc.). Isso é ruído estrutural do
monorepo de `@types` conflitantes, não uma regressão introduzida pelo seu
edit — o próprio retorno da ferramenta já rotula isso como "Pre-existing
lint errors" quando reconhece o padrão, mas quando o `tsc` avulso trava antes
disso, você só vê o despejo bruto.

- Nunca conclua "meu patch quebrou o build de types" só pelo output do
  autolint do `patch`. Rode o script de typecheck real do projeto
  (`yarn types`, que executa `tsc --noEmit` com o `tsconfig.json` do repo) —
  se ele voltar limpo, os erros do autolint eram ruído e podem ser ignorados.
- O mesmo vale para `eslint`: confirme com `yarn lint` (ou `yarn eslint src
  --ext .js,.jsx,.ts,.tsx`, o comando que o CI roda) em vez de confiar só no
  lint parcial que o `patch`/`write_file` reporta arquivo a arquivo.
- Ordem de verificação recomendada ao final de uma remoção de flag: (1)
  `yarn vitest run <specs afetados>` → depois suíte completa se o escopo for
  amplo, (2) `yarn lint` completo, (3) `yarn types` completo. Só depois desses
  três abrir o PR — o autolint incidental do `patch` não substitui nenhum
  deles.

## Sincronizando Jira (subtasks por flag) com o estado real dos PRs

Quando o card Jira pai tem 1 subtask por flag/unidade (ex. "Remover feature
flags do Painel Clínico" com 20 subtasks), trate o Jira e os PRs como duas
fontes que precisam ser reconciliadas ativamente, não apenas espelhadas uma
vez:

- **Detecção indireta de merge**: se você fez `git fetch origin` e uma
  branch remota que você sabia que existia (`chore/remove-flag-x`)
  desapareceu da lista, é sinal forte de que o PR correspondente foi
  mergeado (squash-merge deleta a branch) — confirme com `gh pr view <N>
  --json state,mergedAt` e já aproveite para mover a subtask para Done,
  mesmo que ninguém tenha avisado explicitamente.
- **Não deduza "Review" a partir de CI verde.** CI verde + comentários do
  bot resolvidos = pronto para o usuário decidir mandar para revisão — não
  é o mesmo que "já em revisão". Só mova a subtask para Review quando o
  usuário confirmar que mandou manualmente (ver skill
  `multi-agent-orchestration`, seção "Status-tier semantics").
- **Divisão de relatório vs divisão real do tracker**: se o usuário pedir
  para subdividir um grupo catch-all só para acompanhamento próprio ("chama
  de Outros 1 e Outros 2, só no relatório, não mexe no Jira"), aplique a
  divisão apenas no doc interno (README/progresso) — o Jira mantém o
  agrupamento original por summary. Deixe isso explícito no doc para não
  confundir uma futura sessão que só olhar o tracker.

Para debugar dados no Core (não rodar testes), rode um script via `rails runner` no container:

1. Escreva o script num arquivo no root do repo (montado em `/app` no container) — evita problema de quoting do shell com scripts multi-linha.
2. Rode: `docker compose exec -T -e DISABLE_SPRING=1 app bundle exec rails runner /app/script.rb`
3. Modelos multi-tenant (`ApplicationRecordTenant`) lançam `ActsAsTenant::Errors::NoTenantSet` se consultados sem tenant. Para achar um registro e descobrir o `tenant_id`: `ActsAsTenant.without_tenant { Model.find_by(id: "...") }`.
4. Depois consulte associações dentro do tenant: `ActsAsTenant.with_tenant(tenant) { ... }`.
5. Associações comuns são `has_one` (singular): `ClinicalCase#child`, `ClinicalCase#pei_track` — não `children`/`pei_tracks` (plural).
6. Métodos de decorator (ex.: `ChildDecorator#calculated_official_scheduled_hours_by_discipline`) não existem no model — use o equivalente do model (`Child#scheduled_hours_by_discipline(status: :official)`).
7. Apague o script temporário (`rm`) após o debug para não deixar arquivo órfão no repo.

## Debugando "tela branca" (crash de render) no clinical-panel: procure non-null assertion (`!`) colidindo com uma flag que virou always-on

Quando um usuário relata que uma tela fica **totalmente branca** ao navegar (não um
erro visível, não um toast — silêncio total), a causa raiz típica no clinical-panel é
um crash de renderização React não capturado de forma amigável: um `objeto!.campo`
(non-null assertion) ou acesso direto a propriedade de um valor que na teoria "sempre
existe" mas que, para aquele registro específico, veio `undefined`.

**Procedimento que funcionou para achar a causa em ~30 tool calls, sem acesso ao
Datadog:**

1. Ache a página de destino a partir do texto do botão clicado (`search_files` pelo
   label exato, ex. "Preencher formulário") e siga a cadeia de navegação
   (`onClick={() => navigate(...)}` → rota em `Routes.tsx` → componente lazy).
2. Quando a navegação passa por um hook de decisão de fluxo (ex.
   `useChooseSessionType`, `useCheckinCheckoutFlowNavigation`), **compare a versão
   local com `origin/main`** via `git show origin/main:<path>` — feature flags
   removidas recentemente (`chore: remove <FLAG> feature flag`) mudam o
   comportamento de produção mesmo que o checkout local esteja em outra branch/
   desatualizado. `git log origin/main --oneline -- <arquivo>` mostra rapidamente
   se uma flag que condicionava esse fluxo foi tornada always-on.
3. Na página de destino, procure por `!` (non-null assertion) ou encadeamento sem
   `?.` em valores que vêm de uma relação populada assincronamente/condicionalmente
   pelo backend (ex. `registry!.id` assumindo que toda sessão `direct_assessment`
   tem um registry associado). Esse é o candidato a "explode se undefined".
4. **Verifique no BigQuery se o dado que alimenta esse valor realmente existe** para
   o registro específico do usuário — não assuma que a invariante do código está
   correta. Ex.: `assessment_sessions.assessment_occupational_therapy_registry_id`
   pode estar `NULL` para uma sessão específica mesmo que o use case de criação
   (`ScheduleSessionFromOperational`) tenha uma etapa dedicada para popular esse
   campo — o registro pode ter sido criado por outro caminho (reagendamento,
   conversão de tipo, dado legado anterior ao fix) que não passa por essa etapa.
5. Cruze o `session_id`/`clinical_case` do BQ com o código do core: se existir um
   PR anterior tipo "sessões nascem sem registry de avaliação" (busque
   `git log --oneline -- <use_case_que_cria_o_registry>`), isso confirma que o gap
   é conhecido e provavelmente cobre só um caminho de criação (ex. criação nova),
   não todos (reagendamento, edição administrativa, dados anteriores ao fix).

**Dataset útil para esse tipo de investigação:** `data-kernel-production-4o7n.datakernel`
(via `bq query --project_id=data-kernel-production-4o7n`) tem `sessions`,
`clinicians`, `clinical_cases`, `clinical_cases_clinicians`, `users` — bom para achar
o caso/sessão/terapeuta a partir de email/número de caso. O dataset
`supervision-production-8f1v.assessment` tem as tabelas de registry
(`occupational_therapy_registries`, `assessment_sessions` com as FKs
`assessment_speech_therapy_registry_id`/`assessment_occupational_therapy_registry_id`)
que revelam o gap de dado por trás do crash.

**Sem Datadog, a hipótese de causa raiz de dado já é verificável e específica** —
"achar o `!`/acesso sem guard no código + confirmar no BQ que o dado está de fato
ausente" é suficiente para uma boa hipótese mesmo sem observability (útil quando o
MCP do Datadog está autenticado mas indisponível nesta sessão — ver `mcp-troubleshooting`
skill, pitfall "already authenticated, still missing mid-session"). **Mas quando o
Datadog RUM estiver disponível, sempre confirme o stack trace real antes de fechar a
análise** — ele pode revelar que o crash visível não é exatamente o `!`/guard que você
achou, e sim um crash SECUNDÁRIO em cascata (ver próxima seção).

### O `ErrorBoundary` pode crashar DE NOVO ao tentar renderizar o fallback — isso é o que produz a tela branca total, não o crash original

Confirmado via `mcp__datadog__search_datadog_rum_events` (`@type:error @usr.email:<email>`)
num caso real: o crash original era um `registry!.id` (`OccupationalTherapyAssessmentsSummary`)
com `registry` undefined porque a sessão não tinha `assessment_occupational_therapy_registry_id`
no banco. Mas o erro que o RUM efetivamente capturou (o único presente em toda a sessão de
navegação, repetido em ~5 tentativas) foi:

```
Error: useAuthenticatedUser must be used within an AuthenticatedUserContext
  at .../src/contexts/authenticatedUser.ts
```

Isso é um **segundo crash em cascata**: o `ErrorBoundary` (`App.tsx` → `ErrorBoundary`,
`componentDidCatch`) captura o crash original e tenta renderizar seu fallback
(`GenericError`/`NotFound`, via `BaseError`). Mas `BaseError` chama `useUserData()` e,
indiretamente através de `Layout`, componentes que chamam `useAuthenticatedUser()` — e o
`AuthenticatedUserContainer`/`AuthenticatedUserContext.Provider` que os alimenta fica
ACIMA do `ErrorBoundary` na árvore de rotas (`ProtectedLayout` → `AuthenticatedUserContainer`
→ `Outlet` → rotas com `ErrorBoundary` interno), então nem sempre está desmontado — mas
quando a árvore falha em um ponto que também desmonta esse provider (ou o fallback é
renderizado num contexto de rota que não tem o provider montando), o fallback do próprio
`ErrorBoundary` lança de novo, sem ninguém pra capturar esse segundo erro. Resultado: tela
branca total em vez da página de erro amigável esperada.

**Implicação prática:** ao investigar uma "tela branca" nesse app, não pare no primeiro `!`
suspeito encontrado no código da página que crashou — se o Datadog RUM mostra um erro
DIFERENTE do que você esperava (geralmente relacionado a um Context/Provider ausente, tipo
"`useX must be used within Y`"), é sinal de um crash em cascata: o crash real está em outro
componente (a página que o usuário estava tentando acessar), e o que você está vendo é o
fallback do `ErrorBoundary` falhando por sua vez. Trace de volta: qual página o usuário
estava navegando (RUM `view.url`/`referrer_url` mostra a URL de origem e destino) e aplique
o procedimento acima (non-null assertion + verificação no BQ) nessa página, não no arquivo
do stack trace capturado.

### Reconstruindo quem/quando causou o dado ausente: CDC (`raw.<table>_events`) + logs do core

Depois de confirmar QUE o dado está ausente (BQ), para saber COMO ficou ausente, consulte
`data-kernel-production-4o7n.raw.sessions_events` (CDC via Datastream — todo INSERT/UPDATE
histórico da tabela `general_sessions`, não só o estado atual):

```sql
SELECT source_timestamp, source_metadata.change_type,
       payload.status, payload.session_type, payload.discipline,
       payload.created_by_id, payload.updated_by_id
FROM `data-kernel-production-4o7n.raw.sessions_events`
WHERE payload.id = '<session-id>'
ORDER BY source_timestamp ASC
```

Isso reconstrói a timeline exata: quem criou a sessão e com que tipo, e cada update
subsequente com quem o fez. Resolva os UUIDs de `created_by_id`/`updated_by_id` para
email via `datakernel.users`. Cruze o `source_timestamp` de um update suspeito com
`search_datadog_logs(query='service:core "<session-id>"', from=<timestamp-5min>,
to=<timestamp+5min>)` para ver o `EmitEventJob`/evento de domínio exato que o use case
emitiu naquele segundo — isso confirma qual Trailblazer use case rodou e com quais
parâmetros, sem precisar reproduzir localmente. Ver `investigate-core-flow` skill,
pitfalls 11-12, para o padrão genérico (não específico a sessions) e para o passo de
quantificar quantos outros registros têm o mesmo gap (`COUNTIF` cross-table).

## Debugando "Planejamento de OC" (Orientação Clínica) vazio — não é bug de filtro, é job que ainda não criou a task

Quando o usuário relata que a tela "Planejamento de Orientação Clínica" aparece vazia
("Você ainda não possui Orientações Clínicas a Planejar"), a causa quase nunca é um filtro do
frontend — é que **não existe nenhuma task de `clinical_guidance_planning` para aquele usuário
ainda**. Investigar o frontend/BFF primeiro é perda de tempo; vá direto ao job de criação.

Fluxo e onde olhar:
- Frontend: `src/pages/Users/ClinicalGuidancePlanning/Home/Home.tsx` lista `user.clinicalGuidanceTasks`
  (statuses=[OPEN], subject type `clinical_guidance_planning`). Lista vazia = empty state.
- BFF `clinical_guidances/task` → Core `GET /clinical_guidance/tasks/mine.json`
  (`packs/clinical/app/controllers/clinical_guidance/tasks_controller.rb`, filtro
  `by_subject_types(["clinical_guidance_planning"])` + `by_mine_pendencies(assignee)`).
- As tasks **não são criadas manualmente**. O job recorrente
  `ClinicalGuidance::UseCases::CalculateClinicalGuidanceTask` roda **toda segunda 7h**
  (`config/recurring.yml`) e enfileira `CreateClinicalGuidanceTaskAndPlanning` por tripla
  (advisor, terapeuta, caso).

Duas travas de tempo **intencionais** (regra de produto, não bug) em
`create_clinical_guidance_task_and_planning.rb`:
1. OG (advisor) alocada ao caso há ≥ 15 dias — `CalculateClinicalGuidanceTask#retrieve_genial_advisors`
   usa `ClinicalCaseClinician.allocated_until(15.days.ago)`; o scope `allocated_until` é
   `where(created_at: ..date.end_of_day)`, ou seja "alocado" = `created_at` do registro em
   `clinical_cases_clinicians` (não há coluna `allocated_at`).
2. Primeira sessão de intervenção ≥ 15 dias (`EXPECTED_DAYS_FOR_FIRST_CLINICAL_GUIDANCES=15`);
   OCs seguintes usam 20 dias (`EXPECTED_DAYS_TO_PLAN_NEXT_CLINICAL_GUIDANCES=20`) desde a última
   registry FINISHED. `final_started_at = started_at || start_scheduled_at`, então sessão futura
   agendada também conta (mas a checagem `last_session_age <= expected_days` derruba se for recente).

Papéis: `Enum::ClinicianRoles.genial_advisor_roles` = [CLINICAL_CASE_OWNER (OG Psico/ABA),
OCCUPATIONAL_THERAPY_SPECIALTY_CONSULTANT (OG TO), SPEECH_SPECIALTY_CONSULTANT (OG Fono)].
`Specializations.get_therapist_role` mapeia specialization do advisor → role do terapeuta
(psychology→aba_therapist, speech_therapy→speech_therapy_therapist,
occupational_therapy→occupational_therapy_therapist). **A feature NÃO é exclusiva de ABA** — já
existem 635 plannings de `speech_specialty_consultant` e 1162 de `occupational_therapy_specialty_consultant`
(confirmado via BQ). A percepção de "só ABA tem" vem do fato de os OGs de especialidade serem alocados
mais recentemente. Diagnóstico típico: "OG Fono/TO recém-alocada (últimos ~15 dias) vê tela vazia até a
trava de 15 dias + ciclo semanal de segunda passar" = comportamento esperado.

BQ deste domínio:
- `guidance-data-production-l38y.guidance` → `plannings` (mentor_id/mentee_id/clinical_case_id/status),
  `tasks` (subject_type='ClinicalGuidance::Planning'), `registries`, `subjects`, `discussions`.
- `data-kernel-production-4o7n.datakernel` → `clinical_cases_clinicians` (clinician_role, created_at,
  to_be_removed_at), `clinicians` (specialization, user_id), `sessions` (discipline, session_type,
  status, started_at/start_scheduled_at).

Fallback de auth do BQ quando as credenciais user do `gcloud` expirarem ("Reauthentication failed")
mas a ADC (application-default) ainda valer — injectar o token ADC no bq:
```bash
export CLOUDSDK_AUTH_ACCESS_TOKEN="$(gcloud auth application-default print-access-token)"
export GOOGLE_APPLICATION_CREDENTIALS=~/.config/gcloud/application_default_credentials.json
bq query --use_legacy_sql=false --project_id=supervision-production-8f1v "..."
```

## Validação de tamanho: JS `value.length` vs Ruby `String#size` divergem em emoji (surrogate pairs)

Quando frontend e core aplicam a MESMA regra "mínimo N caracteres" mas contam diferente, um comentário só de emojis passa no frontend e cai num 422 cru do core. É o clássico "o frontend aceitou, o backend rejeitou" — desconfie disso antes de procurar bug de lógica.

- JS `"👏👏👏💜".length` = **8** (cada emoji é um surrogate pair = 2 UTF-16 code units). O `minLength` do react-hook-form usa `.length`.
- Ruby `"👏👏👏💜".size` = **4** (cada emoji = 1 code point). O dry-validation do core (`required(:content).value(:string, min_size?: 5)` em `packs/clinical/app/concepts/clinical_guidance/use_cases/create_comment.rb`) usa `.size`.

Logo `minLength: 5` no frontend aceita 4 emojis (8 >= 5) enquanto `min_size?: 5` no core rejeita (4 < 5) → erro `size cannot be less than 5`.

- **Fix no frontend** (alinhar a contagem com o Ruby): trocar `minLength: N` por `validate` contando code points — `validate: (v) => [...v].length >= N || 'msg'`. O spread `[...v]` itera por code point (igual a `String#size`), então `[...v].length` bate com o backend.
- Mantenha `required: true`; se o campo puder vir `undefined`, guarde com `(v ?? '')` antes do spread.
- Mensagem de erro em pt-BR segue o padrão `buildMinLengthValidationMessage` (ex. "O texto deve ser maior que N caracteres").

## Testando validação de react-hook-form num hook: `isValid` começa `false` — use `trigger`, e registre o campo antes

Ao testar um hook que embrulha `useForm` (`mode: 'onBlur'`), não afirme sobre `formState.isValid` logo após `setValue('field', x, { shouldValidate: true })` — `isValid` é `false` no estado inicial e não vira `true` de forma confiável nesse modo (o teste "aceita 5 chars" falha, e o teste "rejeita 4 emojis" passa por acidente, porque o default já é `false`).

- **Registre o campo primeiro**: chame `result.current.getContentInputProps()` (ou o que quer que invoque `register('field', rules)`) antes de validar — senão `trigger` não acha as regras.
- **Use `trigger` e afirme no retorno**: dentro de `act(async () => { setValue(...); const ok = await formMethods.trigger('field'); })`, afirme em `ok`. `trigger('field')` roda as regras explicitamente e devolve `Promise<boolean>` — sem ambiguidade de estado assíncrono.
- Padrão de teste que ficou robusto: 1 caso "rejeita 4 emojis" (motivo da mudança), 1 "aceita 5 caracteres", 1 "aceita 5 emojis" (borda exata). Com `minLength` o caso dos 4 emojis falha (guarda o fix); com o `validate` por code points todos passam.
