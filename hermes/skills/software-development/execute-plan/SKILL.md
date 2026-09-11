---
name: execute-plan
description: Execute a user story plan step by step, updating todo.md.
metadata:
  hermes:
    tags: [execution, user-story, todo, plan, implementation, workflow]
    related_skills: [plan, create-react-component, test-driven-development]
---

# Execute Plan

Executa o plano de uma user story passo a passo, atualizando o progresso no `todo.md` compartilhado entre repos.

## 1. Seleção da user story

Antes de listar, pergunte ao usuário:

> "Esta story pertence a uma iniciativa? Se sim, qual o slug da iniciativa."

**Se sim:** liste as pastas em `documentations/initiatives/<slug>/user_stories/`.

**Se não:** liste as 10 pastas mais recentes de `documentations/user_stories/` (ordenadas por nome decrescente, que equivale a mais recentes primeiro pelo prefixo de data).

Apresente-as numeradas e peça ao usuário para escolher uma.

## 2. Leitura do contexto

Leia **todos os arquivos** da pasta escolhida (PRD.md, analysis.md, plan.md, todo.md, etc.) para ter contexto completo antes de qualquer ação.

## 3. Criação do todo.md (se não existir)

Se não houver `todo.md`, crie um a partir do plan.md e demais artefatos.

Siga o formato de **execução vertical**: organize por fatias de valor, não por sistema. Cada fatia é uma unidade funcional que atravessa os sistemas necessários de ponta a ponta. Dentro de cada fatia, ordene as tasks pela dependência natural de execução (ex: migration → model → endpoint → bff → frontend).

Cada task deve indicar o sistema-alvo entre colchetes: `[core]`, `[bff]`, `[clinical-panel]`, `[data-kernel]`, etc.

Status: `[ ]` pendente · `[~]` em progresso · `[x]` concluído · `[!]` bloqueado

## 4. Identificação do repo atual

Identifique em qual repo este comando está sendo executado (via `basename $(git rev-parse --show-toplevel)` ou pelo nome do diretório raiz). Use essa informação para focar nas tasks do sistema correspondente.

Apresente ao usuário:
- Qual repo foi identificado
- Quais fatias têm tasks para este repo
- Quantas tasks pendentes existem para este repo no total

Pergunte se ele quer executar a próxima task pendente deste repo, ou se prefere escolher uma específica.

## 5. Levantamento de skills do projeto atual

O projeto que fez o planejamento tem uma visão geral mas às vezes não consegue ir tanto no detalhe. Portanto, não confie cegamente no que está escrito no `todo.md`.

Utilize o conhecimento que você tem do projeto e suas skills para identificar melhorias nas tasks. Caso identifique a necessidade de alteração, proponha ao usuário e, após aprovação, atualize o `todo.md` e a task do Jira correspondente.

Se a execução revelar uma mudança estrutural de estratégia da story (ex: um fluxo antes modelado como cancelamento passa a ser retry, um evento muda de semântica, ou uma task deixa de fazer sentido), não atualize só o `todo.md`: revise também o `plan.md` e registre explicitamente quais premissas foram superadas e qual passou a ser a direção válida.

## 6. Execução passo a passo

Para cada task executada:

1. Marque como `[~]` em progresso no `todo.md`
2. Implemente a task com qualidade — consulte os artefatos da user story e o código existente do repo para seguir os padrões locais. Carregue skills relevantes do projeto (ex: `create-react-component` para componentes React, `test-driven-development` para testes).
3. Ao concluir, marque como `[x]` no `todo.md`
4. Mostre um resumo do que foi feito
5. Pergunte se deve continuar para a próxima task ou pausar

### Validação obrigatória

Antes de marcar uma task como `[x]`, execute as validações relevantes para o repo:

- **clinical-panel**: `yarn vitest run <test-file>`, `yarn lint:fix`, `yarn types`
- **clinical-panel-bff** (Node/Jest, JS puro — NÃO tem `types`/tsc): `yarn test <test-file>`, `yarn lint` / `yarn lint:fix`. Ver `references/clinical-panel-bff-testing.md`
- **core (Rails)**: `bundle exec rspec <spec_file>`, `bundle exec standardrb --fix` (NÃO `rubocop` — o projeto usa `standardrb`)
- Sempre rode os testes do arquivo alterado, não a suite completa (a suite é grande)
- **core com Docker (modo default)**: ver pitfall "Rodar testes no core via Docker" abaixo — `docker compose run` não captura output; usar `up -d` + `exec -T`

Para padrões de teste específicos do clinical-panel (ex: mock de authenticated user para cenários multi-tenant), consulte `references/clinical-panel-testing.md`.

Se durante a execução a implementação final divergir materialmente da task original, atualize a descrição, dependências e critérios de aceite no `todo.md` antes de seguir, para que o documento continue refletindo o sistema real e não um plano já ultrapassado.

Se encontrar um bloqueio (dependência externa, dúvida de escopo, decisão necessária), marque como `[!]` e descreva o bloqueio como um comentário abaixo da task no `todo.md`:
```
- [!] [core] Criar endpoint `POST /api/x`
  > Bloqueado: endpoint depende do model Y que ainda não foi criado no repo core.
```

### Dependência pendente com placeholder (não-bloqueante)

Quando a dependência é um valor concreto que outra task ainda não produziu (ex: ID de um dashboard a ser criado manualmente, nome de um recurso externo), avalie se a task pode ser implementada com um **placeholder marcado** em vez de bloqueada. Critério: a lógica/estrutura do código não muda com o valor — apenas o valor precisa ser preenchido depois.

Padrão:
1. Implemente a task usando um valor placeholder (ex: `= 0`, `= 'TODO'`)
2. Adicione um comentário `// TODO: substituir pelo <X> (T<id>/PEC-<n>)` apontando para a task bloqueadora
3. Marque a task como `[x]` no `todo.md` (não `[!]`) — a implementação está completa, apenas o valor precisa ser substituído
4. Comunique ao usuário quais placeholders precisam ser preenchidos quando a task bloqueadora concluir

Isso permite que o código avance, testes sejam escritos, e o PR seja aberto — o único trabalho restante é trocar o valor literal quando a dependência externa for resolvida.

## 7. Visão de progresso

Ao final de cada ciclo (ou quando o usuário pedir), exiba um resumo:
- Tasks concluídas vs. total deste repo
- Tasks concluídas vs. total geral (todos os sistemas)
- Próxima task pendente

## Observações

- O `todo.md` é compartilhado entre todos os repos (via symlink do `documentations/`). Ao atualizar o status de uma task, você está atualizando o progresso global da story.
- Sempre leia o `todo.md` atualizado antes de iniciar, pois outro repo pode ter avançado tasks que este repo depende.
- Priorize tasks cujas dependências em outros sistemas já estejam concluídas.

## Pitfalls

### Patch no todo.md resolve para fora do workspace

O `todo.md` vive em `documentations/` que é um symlink compartilhado entre repos. Ao usar `patch` com path relativo `documentations/user_stories/...`, o Hermes file tool pode resolver o path absoluto para fora do workspace atual (ex: `/Users/.../product-engineer-agent/documentations/...`). Isso é esperado — o edit landed no local correto. O warning `_warning` na resposta do patch pode ser ignorado quando o objetivo é exatamente atualizar o arquivo compartilhado.

### Variáveis redeclaradas ao mover extração de dados

Ao implementar um redirect-antes-do-formulário (pattern de auto-redirect durante loading), você move `const session = data?.session` para antes dos hooks de navegação. Não redeclare `const session = data.session` após os early returns — use nomes diferentes (`sessionData`, `clinicalCaseData`) no JSX.

### Cron jobs com schedule one-shot vs recorrente

Ao criar jobs de monitoramento (ex: após abrir PR, monitorar CI/comentários), use `schedule: "every 10m"` (recorrente) e não `schedule: "10m"` (one-shot). Jobs one-shot rodam uma vez e completam — o parâmetro `repeat` não os torna recorrentes. Para jobs recorrentes com limite, use `every Xm` + `repeat: N`. Sem `repeat`, roda para sempre até remoção manual.

### MCPs precisam de login interativo

Slack e Atlassian (Jira) MCPs exigem `hermes mcp login slack` e `hermes mcp login atlassian` interativos antes do uso. Em sessões CLI não-interativas, não é possível autenticar — avise o usuário para rodar esses comandos manualmente.

**Fallback REST direto (quando o MCP não está carregado na sessão):** assimétrico entre os dois. O **Slack** funciona — o token em `~/.hermes/mcp-tokens/slack.json` tem `access_token` e permite `chat.postMessage` direto (snippet no skill `pr-request-review`). O **Atlassian/Jira NÃO tem fallback REST** — o token em `~/.hermes/mcp-tokens/atlassian.json` é OAuth com `scope` vazio e retorna `401` no endpoint `https://api.atlassian.com/oauth/token/accessible-resources`; ele só serve ao MCP server (`mcp.atlassian.com`). Para mover cards Jira, a única via é o MCP (`hermes mcp login atlassian` + nova sessão/`/reset`). Não gaste tempo tentando o fallback REST para Jira — reporte o bloqueio ao usuário em vez disso.

### Atlassian MCP transitionJiraIssue — shape do parâmetro

A ferramenta `mcp__atlassian__transitionJiraIssue` exige o parâmetro `transition` como um **objeto aninhado** `{ id: "X" }`, não `transitionId: "X"`. Passar `transitionId` como string plana resulta em erro de validação. Exemplo correto:

```json
{
  "cloudId": "1e91fa41-0b59-4d11-9437-d2352fb6a18d",
  "issueIdOrKey": "PEC-4062",
  "transition": { "id": "61" }
}
```

Para descobrir o ID da transição, chame `mcp__atlassian__getTransitionsForJiraIssue` primeiro e procure pelo `name` desejado (ex: "Review" → id "61", "VALIDATION" → id "51", "Done" → id "41").

### Sub-task e parent story no Jira

Quando uma task do `todo.md` corresponde a uma sub-task do Jira (ex: PEC-4062), mova também a parent story (ex: PEC-4035) ao mudar de status. A sub-task representa a task técnica, mas a story pai é o que o time acompanha no board. Identifique a hierarquia pelo contexto (título da story vs título da sub-task) na lista de cards atribuídos ao usuário.

### Working directory pode ter mudanças de outra sessão em andamento

Antes de commitar, sempre rode `git status --short` e revise qualquer diff inesperado com `git diff`. Se o mesmo clone/workspace é reutilizado por múltiplas sessões/threads do Hermes em paralelo (comum quando o usuário abre uma nova thread sobre um assunto relacionado enquanto a sessão atual segue rodando), pode haver mudanças não commitadas que não vieram desta sessão — inclusive já implementando uma abordagem diferente da que você acabou de combinar com o usuário.

Se encontrar isso: não assuma que são suas; confirme com o usuário antes de descartar (`git checkout -- <arquivo>`) ou de continuar em cima delas. Só descarte após confirmação explícita.

### Branch atual pode ser de outra feature não relacionada

Ao começar a executar uma task nova, rode `git branch --show-current` e `git log --oneline -5` e confira se a branch atual realmente pertence à story em execução. Se a branch atual for de outra feature (ex: sessão anterior deixou o workspace em `fix/outra-coisa`), não commite a nova task em cima dela.

Padrão para isolar corretamente:
```bash
git fetch origin main
git stash                                    # preserva mudanças não commitadas desta task
git checkout -b feat/nome-da-nova-feature origin/main
git stash pop
git branch --unset-upstream                  # evita push acidental sinalizado para origin/main
```

### Achado técnico adjacente durante a execução — juntar ou separar em outro PR?

É comum, ao investigar ou implementar uma task, notar um bug ou melhoria relacionada mas fora do escopo original (ex: durante T3 de uma story sobre participantes no checkout, descobrir que a página de anotações também exibe participantes incorretamente). Não assuma unilateralmente juntar no mesmo PR nem abrir um novo — pergunte ao usuário, apresentando o trade-off (tema relacionado vs. escopo de review/rollback mais limpo).

**Investigar a causa raiz é bem-vindo; corrigi-la sem pedido não é.** Ao diagnosticar um achado adjacente até a causa raiz (ex: rastrear até o resolver/query/linha exata do bug), pare na explicação e no registro no `todo.md` — não ofereça nem comece a implementar o fix num repo/escopo que não é o da task atual, mesmo com um `clarify()` "quer que eu corrija?" no meio do caminho. Se o usuário não pediu a correção, a resposta certa é documentar e parar; escalar para "vou consertar" antes de um pedido explícito é o tipo de tangente que o usuário corrige rispidamente ("não precisa!"). Isso é diferente de ações operacionais necessárias pra validar a própria task (ex: mergear uma branch do BFF em `development` pra destravar teste manual do T5 — isso é meio, não escopo novo).

Se o usuário decidir juntar no PR já aberto: atualize a descrição do PR para refletir os dois escopos (não só o commit message), e rode a validação completa (testes + lint + types + build) cobrindo as áreas de código de ambos os escopos antes de dar push.

### Estender uma lista numerada compartilhada (componentes React tipo List/List.Item)

Quando o clinical-panel usa um componente de lista customizado com numeração automática (ex.: `components/List` + `List.Item`, que renderiza um `<ul>` com `list-style: decimal`), cada instância de `<List>` reinicia sua própria numeração — HTML não continua contagem entre `<ul>`s irmãos. Se uma nova seção precisa aparecer "depois do item 5" com número 6 (não reiniciar em 1), **não renderize uma segunda `<List>` separada abaixo** da primeira. Em vez disso:

1. Adicione um `children?: React.ReactNode` opcional ao componente que já renderiza a `<List>` existente (ex.: `AssessmentDetail`, templates de disciplina como `ABA`/`TO`/`Fono`).
2. Renderize `{children}` como último filho, dentro da mesma `<List>`.
3. No componente pai, passe o novo conteúdo via `<ComponenteExistente>{novoConteudo}</ComponenteExistente>` em vez de justapor os dois componentes lado a lado.

Isso vale para qualquer extensão de UI que precise "continuar" uma numeração/contagem visual controlada por CSS `list-style` — o padrão geral é: quando o requisito é "sequência contínua", extenda via slot/children da estrutura existente, não crie uma estrutura irmã paralela.

### Nomear uma nova seção de UI perto de uma existente

Antes de nomear uma nova seção/label na UI, procure por strings i18n ou rótulos já usados nas proximidades (`grep`/`search_files` por palavras candidatas nos arquivos `i18n/locales/**/pt-br.json` e nos componentes vizinhos). Se o nome candidato colidir semanticamente com um rótulo já existente mas com significado diferente (ex.: "Participantes" já usado para acompanhantes/família em outro componente, candidato novo era para a equipe clínica), isso vai gerar ambiguidade para quem lê a tela. Apresente ao usuário 2-3 alternativas com uma justificativa curta (o porquê da colisão) em vez de escolher sozinho ou só listar opções sem contexto — o usuário validou bem essa abordagem quando trade-offs foram explicados.

### Renomear um campo GraphQL exposto — propaga para mais lugares que o óbvio

Quando o usuário pedir para renomear um campo GraphQL já implementado (ex.: `practicalHbjHours` → `feasiblePlaytimeTogetherHours`), o rename propaga para: (1) type-defs.graphql, (2) a chave no resolver, (3) o spec (query + describe + asserções), (4) o **nome do arquivo** do spec (`git mv`), (5) o `todo.md` — incluindo o grafo mermaid, os títulos das tasks e os campos `findings`/`validated` (que citam o nome do spec), e (6) a descrição do PR (`gh pr edit --body-file`). Os lugares fáceis de esquecer são o **grafo mermaid** e a **task downstream** (ex.: T5) que consome o campo — ambos referenciam o nome antigo e um rename incompleto deixa o documento desatualizado. Rode `search_files` pelo nome antigo em todo o repo + `documentations/` para achar todas as ocorrências de uma vez antes de editar.

### Refinamento visual é iterativo — espere múltiplas rodadas de ajuste fino

Ao implementar uma nova seção de UI (rótulo, formatação de texto, posição), o usuário costuma só perceber problemas de estilo (número errado, fonte destoante, formato incompleto) depois de ver o resultado renderizado — não durante a especificação inicial. Trate a primeira implementação como um rascunho a ser refinado, não como entrega final: rode a validação completa (testes + lint + types + build) a cada rodada de ajuste, mesmo que pequena, porque mudanças de estrutura de componente (ex.: adicionar prop `children`) tendem a exigir atualizar testes existentes em cascata.

### Ajustar espaçamento/estilo de um campo: reutilizar classe CSS existente, não inventar valor novo

Ao corrigir espaçamento apertado ou estilo inconsistente de um campo/seção (ex.: usuário reporta "está grudado no campo abaixo" ou "a fonte está diferente"), primeiro procure no mesmo arquivo `styles.module.css` (ou equivalente) por uma classe já usada para o mesmo propósito em um campo irmão (ex.: `.expertiseFieldContainer { margin-bottom: var(--ant-margin-lg); }`). Copie esse padrão para uma nova classe (`.fieldSection`) em vez de escrever um valor de margin/padding arbitrário. Isso mantém a tela visualmente consistente e usa os design tokens (`var(--ant-*)`) já adotados no projeto, em vez de introduzir um valor mágico que só resolve o sintoma pontual.

**Cuidado com a direção da margin**: `margin-bottom` no elemento espaça o que vem *depois* dele; não resolve uma reclamação de "está grudado no campo *acima*". Se o usuário reclamar do espaço **acima** de um campo/título novo (ex.: "o texto X ficou muito próximo do campo anterior"), a correção é `margin-top` no próprio elemento (ou `margin-bottom` no elemento anterior) — não `margin-bottom` no elemento novo. Antes de aplicar, identifique de qual lado do elemento é a reclamação e confira, no elemento de referência citado pelo usuário (ex.: outro título do mesmo formulário), se o espaçamento vem de `margin-top` do próprio título ou de `margin-bottom` do campo anterior, para replicar exatamente essa direção.

### Escopo separado ficou pendente de extração e quebrou o CI depois

Quando um achado técnico adjacente (ver pitfall anterior) foi implementado e depois o usuário decide separá-lo, marcar a pendência no `todo.md` não é suficiente por si só — se os commits continuarem na branch/PR original, eles seguem sendo testados pelo CI normalmente e podem quebrar quando, em outra sessão, você adiciona mais commits em cima (o CI só roda ao abrir/atualizar o PR, então a falha pode aparecer bem depois da decisão de separar). Sinal de que é esse o caso: a falha do CI é em um teste de um componente que não faz parte da task atual, mas está listado como "achado técnico separado" no `todo.md`.

Ao confirmar essa causa, extraia de fato (não deixe só anotado):
1. Preserve o trabalho antes de descartar: `git branch <nome-da-branch-nova> <sha-do-commit-mais-recente-do-escopo>` — cria uma branch local apontando para o commit sem precisar de checkout/cherry-pick.
2. Confirme que os commits do escopo a extrair não tocam os mesmos arquivos que os commits que devem ficar (`git show --stat <sha>` de cada um) — se não há sobreposição, um `git revert --no-commit <mais-recente> <mais-antigo>` (nessa ordem, do mais novo pro mais antigo) reverte ambos em um único commit limpo, sem conflitos.
3. Rode a suíte de testes relevante (incluindo os testes que estavam falhando) antes do push, para confirmar que o revert de fato resolve.
4. Atualize o `todo.md`: mude a nota de "ação pendente" para "extração concluída em <data>" com o SHA do commit de revert e o nome da branch onde o trabalho ficou preservado.

### Múltiplas instâncias de dev server (`yarn start`) acumuladas quebram callback de login local

Se o usuário relatar que `yarn start` sobe numa porta inesperada (ex.: 5054 em vez da porta fixa configurada em `vite.config.ts`) e o login (Auth0 ou similar) não funciona, verifique processos anteriores ainda vivos antes de investigar configuração:

```bash
lsof -nP -iTCP -sTCP:LISTEN | grep node
ps -p <pids> -o pid,lstart,args
```

Sessões anteriores de `yarn start`/`yarn start:local` não encerradas corretamente se acumulam, cada uma ocupando a porta seguinte por auto-incremento do Vite. O sintoma é o app abrir numa porta que não está cadastrada como "Allowed Callback URL"/"Allowed Web Origin" no provedor de auth, fazendo o redirect de login falhar silenciosamente. Fix: `kill <pids>` de todas as instâncias antigas e pedir para o usuário rodar `yarn start` de novo — deve subir limpo na porta fixa esperada.

### Reintroduzir um escopo extraído a pedido do usuário

Se o usuário pedir para trazer de volta ao mesmo PR um escopo que você havia extraído/revertido (ex.: "quero que entre no mesmo PR que já existe"), use `git revert --no-edit <sha-do-commit-de-revert>` — isso desfaz o revert e restaura os arquivos originais automaticamente, sem precisar recriar nada manualmente. Depois de restaurar, rode a suíte de testes ampla da área afetada (não só o arquivo alterado), porque componentes vizinhos podem ter testes com contagens (`toHaveLength(N)`) que dependiam da ausência da feature — ajuste a expectativa do teste com um comentário inline explicando a nova contagem, nunca revertendo a feature de novo só para não quebrar um teste desatualizado. Atualize o `todo.md` com o histórico completo (extraído em X, reintroduzido em Y, SHAs de cada revert) para não perder o fio em caso de nova mudança de direção.

### Migração de constante para coluna com backfill — separar em PR aditivo + PR de troca de comportamento

Quando uma task envolve migrar uma regra de negócio de uma constante hardcoded para um valor persistido no banco (ex.: percentual fixo no código vira coluna configurável em uma tabela existente, com um script de console para popular os registros existentes), **não implemente isso em um único PR** mesmo que o `todo.md` planeje as tasks sequenciais como uma unidade. O risco: se o PR que troca a fonte de leitura (constante → coluna) for deployado antes do backfill rodar em todos os ambientes (staging, produção), qualquer registro/tenant cuja coluna ainda esteja `nil` passa a falhar (em vez de calcular corretamente como fazia com a constante) — uma regressão real num fluxo que hoje funciona para todo mundo. Proponha esse split proativamente ao usuário quando notar o padrão — foi exatamente o trade-off que o usuário levantou depois de eu já ter feito tudo num PR só (deveria ter antecipado).

Padrão de split:

1. **PR1 (aditivo, zero mudança de comportamento):** migration da coluna nova (nullable), atributo declarado no model, script de console de backfill, e qualquer exposição de API/serialização do novo campo que ainda não é consumida por nada. Pode mergear e deployar sem pressa — não muda nenhum resultado observável.
2. **PR2 (troca de comportamento), branch com base no PR1:** a lógica de negócio passa a ler da coluna em vez da constante. Documentar explicitamente no corpo do commit/PR que o deploy **só deve acontecer depois de confirmar que o backfill rodou em todos os ambientes** — sem isso, registros sem o valor populado quebram.

Mecânica git para separar depois que o código já foi escrito como um único diff:
```bash
# 1. Commit tudo numa branch (a partir de main)
git checkout -b feat/pr1-nome main

# 2. Salve o diff dos arquivos exclusivos do PR2 antes de descartá-los dessa branch
git diff -- <arquivos-do-PR2> > /tmp/pr2.patch
git checkout -- <arquivos-do-PR2>   # essa branch fica só com o PR1

# 3. Rode os testes do PR1, commit, push
git push -u origin feat/pr1-nome

# 4. Branch do PR2 EMPILHADA sobre o PR1 (não a partir de main)
git checkout -b feat/pr2-nome feat/pr1-nome
git apply /tmp/pr2.patch
```
Depois de aplicar o patch do PR2, rode os testes de novo — specs que dependiam de comportamento incidental introduzido pelo PR2 (ex.: uma factory que ganhou um default só no PR2) podem fazer um teste do PR1 falhar porque ele não passa mais o valor explicitamente. Ajuste o teste do PR1 para setar o valor manualmente em vez de depender de um default que só existe depois do PR2 ser reaplicado.

**`/test-impact` em PR empilhado (stacked PR):** ao rodar a skill `test-impact` (geralmente delegada a um subagent) para o PR2, compare contra `origin/<branch-do-PR1>`, nunca contra `origin/main` — comparar contra `main` incluiria os arquivos do PR1 na análise de impacto, duplicando specs que já têm seu próprio `.test-impact/impact-*.txt` gerado no PR1. Ao instruir o subagent, deixe explícito o comando exato (`git diff --name-only origin/<branch-do-PR1>...HEAD`) e reforce a checagem de impacto por **factory alterada**: se uma factory usada por muitos specs ganhou um novo `after(:build)`/default no PR2, faça o subagent rodar `search_files` por `factory_name` em todo o repo (não só no pack atual) para achar todos os consumidores — o levantamento manual tende a ser mais raso do que o de um subagent dedicado que varre o repo inteiro.

Abra o PR2 com `gh pr create --base <branch-do-PR1>` (não `main`) — isso faz o GitHub mostrar só o diff incremental e sinalizar a dependência entre PRs. Depois de mesclar `origin/main` em cada branch (podem ter avançado durante o trabalho), sincronize nesta ordem: main → branch do PR1 → branch do PR2 (`git merge <branch-do-PR1>` dentro da branch do PR2, não `origin/main` diretamente), senão o PR2 herda conflitos que já foram resolvidos no PR1.

### Mergear uma feature branch em `development` sem tocar na branch local

Quando o usuário pedir para mergear uma branch de feature (ou PR) na `development` remota para testar, e não houver uma skill de merge própria do projeto disponível para uso autônomo, aplique esta técnica não-destrutiva (evita `reset --hard` e force-push):

1. `git fetch origin development <branch-de-origem>`
2. `git checkout -b tmp/merge-<algo> origin/development` (branch temporária local, nunca a `development` local)
3. `git merge origin/<branch-de-origem> --no-edit`
4. Rode a suíte de testes relevante nessa branch temporária antes do push — o merge pode revelar regressões que nenhuma das branches isoladas tinha (ex.: teste de contagem de texto que só quebra quando duas features do mesmo PR se combinam)
5. `git push origin tmp/merge-<algo>:development` — publica o conteúdo da branch temporária como push normal (fast-forward) direto na `development` remota, sem mexer na branch local `development` nem fazer force-push
6. Volte para a branch de origem: `git checkout <branch-de-origem>`
7. Apague a branch temporária: `git branch -D tmp/merge-<algo>`
8. Sincronize a `development` local só por conveniência, sem checkout nela: `git branch -f development origin/development`

Sempre confira o CI da branch de origem (`gh pr checks <PR>`) antes de mergear — nunca mergeie um PR com CI vermelho "para testar", corrija a causa primeiro.

### FactoryBot: `after(:build)` + `||=` para valor default sobrescreve `nil` explícito silenciosamente

Ao adicionar um valor default condicional numa factory (ex.: popular um percentual/status baseado em outro atributo já setado, tipo `name_alias`), evite o padrão:

```ruby
# ERRADO — nil explícito passado num teste é sobrescrito silenciosamente
after(:build) do |record|
  record.campo ||= default_baseado_em(record.outro_atributo)
end
```

`||=` trata `nil` como "não setado" e aplica o default mesmo quando o teste passou `campo: nil` de propósito (ex.: para testar o cenário "sem esse valor configurado"). O teste passa, mas está testando o cenário errado — o bug só aparece quando alguém percebe que o `nil` nunca chegou ao model.

Use um **bloco de atributo dinâmico** do FactoryBot em vez de callback:

```ruby
# CORRETO — respeita nil explícito, só aplica o bloco quando o atributo não é informado
campo do
  default_baseado_em(name_alias)
end
```

O FactoryBot só executa o bloco de atributo quando o valor não foi passado no `create`/`build`; um `campo: nil` explícito é respeitado como está. Ao revisar/escrever uma factory com default condicional, prefira sempre esse padrão — e adicione um spec de model cobrindo os dois casos (default aplicado quando omitido, `nil` explícito preservado) para travar o comportamento.

Achado real de review de bot de code review (gemini-code-assist) — o bot pegou esse padrão corretamente; vale considerar como sinal legítimo mesmo vindo de bot, desde que a sugestão seja verificada (ver pitfall seguinte sobre sugestões de bot que soam plausíveis mas quebram o comportamento).

### Verificar sugestões de bot de code review antes de aceitar — nem toda sugestão "correta" é segura

Bots de code review (gemini-code-assist e similares) frequentemente sugerem trocar um guard/validação por uma coerção "mais simples" (ex.: usar `.to_f` direto em vez de checar `nil` antes). Antes de aceitar, teste a sugestão isoladamente quando ela mexe em lógica de controle de fluxo (guards, `unless`, `return` condicional) — em Ruby, `nil.to_f` retorna `0.0`, que é **truthy**. Se o código atual tem `return erro unless valor` e você troca `valor` por `valor.to_f`, o guard nunca mais dispara para `nil` (silenciosamente vira `0.0` em vez de falhar), quebrando exatamente o cenário de erro que a validação existia para cobrir.

Ao recusar uma sugestão de bot, responda a thread explicando o teste que você fez (ex.: "testei `nil.to_f` localmente, retorna `0.0` que é truthy, isso quebraria o guard X") em vez de só dizer "não vou aplicar" — isso documenta a decisão para quem revisar depois e evita que a mesma sugestão seja reproposta sem contexto.

### Branch local diverge do remoto após PR anterior ser mergeado/rebaseado (force-push do GitHub)

Em PRs empilhados (PR2 com base = branch do PR1), quando o PR1 é mergeado na `main`, o GitHub costuma rebasear automaticamente a base do PR2 para `main` — isso força um push não-linear na branch remota do PR2. Se você tiver checkout local dessa branch de uma sessão anterior, o próximo `git fetch` + `git checkout` mostra `have diverged, X and Y different commits each` em vez de um simples "up to date" ou fast-forward.

Antes de decidir como resolver, **investigue a causa** — não assuma corrupção:
```bash
git log --oneline origin/<branch>-10        # veja se o remoto tem um merge commit de PR mergeado
gh pr view <PR> --json baseRefName,mergeable,state   # confirme se a base mudou e se ainda é mergeable
gh pr view <PR-anterior> --json state,mergedAt       # confirme se o PR anterior já foi mergeado
```

Se o remoto reflete um rebase legítimo do GitHub (PR anterior mergeado, base ajustada), o remoto é a fonte de verdade — `git reset --hard origin/<branch>` para sincronizar o local. Não tente reconciliar manualmente um merge/rebase que a plataforma já fez. Depois do reset, releia os arquivos afetados antes de continuar editando (o conteúdo pode ter mudado de path/versão de commit em relação ao que você tinha em memória).

### Frontend mostra placeholder ("–") mesmo com T5 implementado corretamente — verificar se o BFF/Core já foram deployados antes de suspeitar do próprio código

Quando o usuário reporta "testei e não está funcionando" para uma feature que atravessa `core` → `bff` → `clinical-panel` (execução vertical típica desta skill), e o frontend cai no fallback (`-`, placeholder, skeleton preso), **não assuma bug no código do frontend antes de descartar deploy pendente das camadas anteriores**. Um PR de `bff`/`core` marcado `[x]` no `todo.md` só significa "implementado e testado localmente" — não "deployado no ambiente que o usuário está testando" (dev/staging local costuma apontar pra um BFF de ambiente compartilhado, não pro código local).

Sequência de diagnóstico rápida (mais barata que ler o componente de novo):
1. Ache a URL do BFF/API que o frontend consome: `grep VITE_.*_API_URL .env*` (ou equivalente do stack).
2. Teste o schema via introspection GraphQL, sem autenticação — só quer saber se o campo existe:
   ```bash
   curl -s -X POST <bff_url>/graphql -H "Content-Type: application/json" \
     -d '{"query":"query{__type(name:\"ClinicalCase\"){fields{name}}}"}'
   ```
   Se o campo novo (`feasiblePlaytimeTogetherHours` etc.) não aparece na lista, ou uma query real com esse campo retorna `Cannot query field ... on type ...` (`GRAPHQL_VALIDATION_FAILED`), o BFF do ambiente ainda não tem o PR mergeado/deployado — **não é bug do frontend**, é falta de deploy.
3. Um `401 Unauthorized` na mesma query (sem token) é esperado e não invalida o teste — o importante é a mensagem de erro ser de auth e não de schema/validação.
4. Se confirmado "falta deploy": aplique o pitfall "Mergear uma feature branch em development sem tocar na branch local" (mais abaixo) no repo do BFF/core faltante, valide a suíte antes do push, e monitore o workflow de deploy automático (`gh run list --branch development`) até concluir — reconsulte a introspection depois do deploy pra confirmar antes de pedir pro usuário testar de novo.
5. Ao recarregar a página no navegador do usuário via `computer_use`, lembre que a sessão do driver pode cair no meio da tarefa (`session '...' has ended`) — nesse caso, use `screencapture` (macOS) + `vision_analyze` como fallback pra continuar verificando visualmente sem depender de reabrir a sessão do cua-driver.

### Divergência de valor exibido entre dois campos que leem o "mesmo dado" — prefira coerção de tipo a teorias de resolver/race condition antes de confirmar

Se dois campos numa mesma tela (ex.: um tooltip mostrando "X horas agendadas" e um resultado calculado a partir dessas horas) parecem usar dados diferentes mesmo lendo, em tese, o mesmo campo GraphQL na mesma query, a **primeira hipótese a testar é coerção de tipo no frontend, não dessincronia entre resolvers/chamadas HTTP** — mesmo que multiplos resolvers independentes pareçam uma explicação plausível à primeira vista. Um caso real dessa sessão: suspeitei inicialmente que `ClinicalCase.feasiblePlaytimeTogetherHours` fizesse sua própria chamada a `children(id)` de forma dessincronizada de `ClinicalCase.children` (child na ordem errada entre duas chamadas) — **hipótese descartada** depois que o usuário apontou que o dado (horas agendadas) é pouco volátil, o que não se sustenta com uma teoria de race condition. A causa real: o campo `aba` era `String` no `type-defs.graphql` do BFF, e o componente passava esse valor direto para `count` no `t()` do i18next sem `Number()` — isso quebra a resolução de pluralização (`hoursText_one`/`_other`) e sempre cai no fallback literal da chave (ex.: `"0 horas"`), **independente do valor real**. Prova rápida: outro componente irmão que já consumia o mesmo campo (`Schedule.tsx`) já fazia `Number(value)` — se existir esse precedente no codebase, é sinal forte de que o padrão correto já é conhecido e só não foi replicado no componente novo.

Checklist de diagnóstico, do mais barato ao mais caro:
1. Pergunte (ou avalie) se o dado subjacente é volátil. Se não é, descarte teorias de race condition/cache/ordem de resolução — dado estável + mesma leitura deveria sempre bater.
2. `grep` o tipo do campo no `type-defs.graphql` do BFF — se for `String` onde o frontend assume `number`, é a causa mais provável.
3. Procure um componente irmão que já consome o mesmo campo e veja se ele já faz `Number(value)`/coerção — se sim, replique o padrão em vez de investigar mais.
4. Só depois de descartar 1-3, investigue DataLoader/cache/ordem de chamadas como hipótese de última instância.
5. Se outro agente (ou pessoa) apresentar um diagnóstico alternativo, **verifique contra o código antes de concordar ou refutar** — releia o schema e o componente citados, não aceite/rejeite pela plausibilidade da narrativa.

Fix: `Number(campoGraphQL)` no ponto de leitura no frontend (menor blast radius) em vez de mudar o tipo do schema do BFF. Depois de corrigir, escreva um teste de regressão que mocka o campo como `string` (reproduzindo o shape real do BFF) e verifica o texto renderizado — **confirme que o teste falha sem o fix** (reverta temporariamente, rode isolado com `-t 'nome do teste'`, veja falhar, reaplique o fix, veja passar) antes de considerar a cobertura válida.

### Tooltip/UI com "valor principal + fallback condicional para info secundária" — pergunte se a condição de fallback é rara antes de implementar

Ao implementar um padrão "mostra X normalmente, mas cai para Y quando falta dado Z" (ex.: tooltip que explica o cálculo prático quando módulo+percentual+horas existem, senão mostra a info do "Ideal Genial" como referência), **pergunte (ou infira do domínio) se a condição que dispara o fallback é rara ou frequente na prática** antes de codificar a lógica condicional. Se o dado que aciona o valor principal (`feasiblePlaytimeTogetherHours`) é praticamente sempre presente, o fallback para a informação secundária (`idealGenialTooltipText`) quase nunca dispara — e uma informação que o PRD/analysis.md explicitamente pede como "sempre acessível como referência secundária" fica invisível na prática, mesmo com o código "funcionando conforme especificado". O usuário só percebeu isso ao perguntar "você mostra X em alguns momentos e Y em outros, é isso mesmo?" — uma pergunta de esclarecimento que expôs um requisito mal modelado.

Fix estrutural: quando a secondary info deve estar **sempre** acessível (não só como fallback de erro), concatene ambas as informações (`[bodyPrincipal, bodySecundaria].filter(Boolean).join(' ')`) em vez de escolher uma via `||`/ternário. Reserve o fallback condicional só para casos genuinamente excludentes (ex.: "não há dado nenhum para mostrar").

Ao testar esse tipo de tooltip, não baste checar `expect(title.parentElement).toBeInTheDocument()` — isso só prova que *algum* elemento existe, não qual texto está lá. Dispare o hover (`userEvent.hover(icon)`) e faça `findByText` no conteúdo esperado; esse nível de asserção foi o que revelou, em retrospecto, que o teste anterior "passava" mesmo com o comportamento errado.

**Coda: concatenar nem sempre é o fix final — texto de duas fontes pode ser redundante, não complementar.** Depois de implementar a concatenação (`[bodyPrincipal, bodySecundaria].join(' ')`), o usuário revisou o resultado renderizado e notou que a "info secundária" (um campo de texto livre vindo de outra camada, ex.: `changeReason` gerado no Core) repetia com outras palavras o que a frase principal já dizia (mesmo módulo/percentual, fiação de texto quase idêntica) — poluição, não complementaridade. Quando isso acontecer:
1. Decomponha o texto renderizado frase por frase e identifique a origem de cada trecho (nosso `t()`/i18n vs. campo de texto livre de outra camada) antes de propor edição — o usuário pode perguntar "que parte vem de onde?" e a resposta precisa ser exata.
2. Apresente 2-3 variações de texto ao usuário via `clarify()` em vez de escolher uma reescrita sozinho — encurtar prosa é subjetivo, e a escolha certa (remover a fonte redundante vs. manter as duas) depende de julgamento de produto, não só de código.
3. Se a decisão for remover uma fonte de texto (não só reformular), propague a remoção: tire o campo agora não-usado da query GraphQL, delete utils/helpers que só existiam para formatá-lo (ex.: um `transformToHours` usado somente ali), e reescreva os testes que afirmavam a presença do texto antigo — não deixe código morto nem teste testando um comportamento que deixou de existir.
4. Aproveite a rodada para adicionar informação que faltava e o usuário perguntou sobre (ex.: a regra de arredondamento "mínimo 1h quando positivo" que explicava por que valores pequenos "colavam" no mesmo resultado) — perguntas de esclarecimento do usuário sobre a regra de negócio são sinal de que a explicação no texto está incompleta, não só desorganizada.

### `db:migrate`/`db:prepare` no core traz schema.rb drift de outras migrations pendentes (mesmo quando você TEM uma migration própria)

Rodar `docker compose exec app bundle exec rails db:migrate` (ou `db:prepare`) no ambiente de dev compartilhado do core aplica **todas** as migrations pendentes no banco, não só a que você acabou de gerar — se o container/DB local está atrás do `main` remoto (comum quando fica dias sem rebuild), o `db/schema.rb` resultante mistura sua mudança com dezenas de outras (índices, colunas, tipos) de migrations de outras branches que nunca rodaram localmente. Isso é diferente do caso "PR sem migration própria" (já coberto no pitfall de `Bundler::GemNotFound` abaixo) — aqui você TEM uma migration legítima, mas o diff do `schema.rb` ainda vem contaminado.

Antes de comitar, sempre isole:
```bash
git diff db/schema.rb   # se aparecer muito mais que a sua tabela/coluna, há drift
```
Se houver drift: `git checkout -- db/schema.rb` para restaurar a versão do `main`, depois aplique manualmente só as duas mudanças da sua migration via `patch` cirúrgico — o version bump no topo (`ActiveRecord::Schema[X.Y].define(version: ...)`) e o trecho do `create_table`/`add_column` correspondente. Rode `bundle exec rails db:version` e `git diff db/schema.rb` de novo para confirmar que só sua mudança ficou.

### Testar critério de aceite "caso não mapeado / sem configuração" pode revelar bug pré-existente na pipeline Trailblazer

Ao escrever o teste do critério de aceite "módulo/enum/registro sem configuração retorna o erro esperado" (um cenário de falha que tipicamente não tinha spec antes), é comum descobrir que a pipeline Trailblazer não tem um `fail` step dedicado depois do step que pode falhar ali — o `false` cai no próximo `fail` handler da cadeia (geralmente o de persistência), que espera outro keyword arg (ex.: `create_workload_errors:`) e explode com `ArgumentError: missing keyword: ...` em vez de retornar o erro de negócio esperado. É um bug de tratamento de erro pré-existente, não introduzido pela sua mudança — só aparece quando alguém finalmente testa aquele caminho de falha.

Fix: adicione `fail :handle_<step>_error, fail_fast: true` logo após o `step` que pode falhar, com um handler mínimo (`def handle_x_error(ctx, **); false; end`) se o step já popula `ctx[:errors]` via `add_error` internamente — não duplique a construção do erro no handler. Documente no "findings" da task que é achado adjacente (bug pré-existente), mesmo mantendo no mesmo commit quando ele é exigido pelo próprio critério de aceite da task atual.

### Docker build/testes longos: cap de 60s do `terminal` foreground não é falha do build

`make build`, `make test` (suíte completa) e comandos Docker pesados podem levar bem mais que 60s. Rodar em foreground e receber `[Command timed out after 60s]` **não significa que o build falhou** — o processo continua rodando no container, só a chamada de terminal retornou por causa do cap. Rode esses comandos com `terminal(background=true, notify_on_complete=true)` redirecionando para um log (`> /tmp/algo.log 2>&1; echo "EXIT:$?" >> /tmp/algo.log`), depois `process(action='wait'/'poll')`, e leia o log com `read_file` — não confie no texto retornado por `process(action='wait')` como se fosse o output do comando: às vezes é só ruído do shell de login (tema/prompt), a fonte de verdade é sempre o arquivo de log.

### `patch` com `mode='replace'` em blocos Ruby/JS aninhados pode quebrar a sintaxe silenciosamente

Ao usar `patch(mode='replace')` para remover/mover um trecho no meio de um bloco `do...end` (ou `{...}`) grande — ex.: um teste RSpec com vários `context`/`it` aninhados — uma correção de uma linha (ex.: remover uma variável não usada) pode acidentalmente apagar um `end`/`}` de fechamento junto, deixando o arquivo com bloco não fechado. O `patch` tool não valida sintaxe completa, só confirma que a substituição de string foi aplicada. Depois de qualquer `patch` que mexa em estrutura de blocos (não só valor de uma linha), rode `bundle exec ruby -c <arquivo>` (ou o linter equivalente) antes de rodar a spec — mais rápido que descobrir o erro só na hora do teste.

### Rodar testes no core via Docker

O `config.default.yml` do core usa `execution.mode: docker` por padrão. Quando precisar rodar rspec/standardrb no repo `core` e o Docker não estiver rodando:

1. **Iniciar Docker Desktop** (se daemon não estiver ativo): `open -a Docker` e aguardar com `docker info` poll.
2. **Subir containers**: `docker compose up -d app` (sobe db + redis + app). O container `app` usa `sh init.sh ./bin/dev` como entrypoint — ele inicia o servidor web, NÃO um shell.
3. **Preparar banco de testes**: `docker compose exec -T -e RAILS_ENV=test app bundle exec rails db:prepare`
4. **Rodar rspec**: `docker compose exec -T -e RAILS_ENV=test app bundle exec rspec <spec_file> --format documentation`
5. **Rodar standardrb**: `docker compose exec -T app bundle exec standardrb <files>`

**NÃO use `docker compose run`** para rodar testes — o service tem `tty: true` + `stdin_open: true`, e mesmo com flag `-T` o output do rspec/standardrb não é capturado corretamente (container cria novo, roda `bundle install` a cada run, e stdout some). Use sempre `up -d` + `exec -T`.

Se só precisar de standardrb (sem rspec) e as gems do projeto não estão instaladas localmente, dá para rodar sem `bundle exec` chamando o binário do gemset diretamente: `/Users/<user>/.rvm/gems/ruby-3.4.5@core/bin/standardrb --no-fix <files>`. Standardrb só precisa do parser Ruby, não do bundle completo.

### Docker engine travado (daemon não responde) no core

Os três targets do Makefile (`make test`, `make lint`, `make build`) dependem de `docker compose exec ... app` — se o daemon estiver fora, **os três bloqueiam juntos**, não só o rspec. O gemset local só roda standardrb (binário do gemset), nunca rspec (gems do bundle não instaladas localmente → `Bundler::GemNotFound`).

Assinatura de engine travado (diferente de daemon simplesmente desligado):
- `docker info` / `docker version` **penduram** (timeout) em vez de retornar erro imediato.
- `curl -s --unix-socket ~/.docker/run/docker.sock http://localhost/version` retorna vazio.
- O socket `~/.docker/run/docker.sock` tem mtime antigo (dias) — o daemon morreu mas o UI/backend parent continua de pé (`com.docker.backend` vivo, `com.docker.backend run` e `com.docker.virtualization` mortos).

`open -a Docker` + `osascript quit` **não** revivem um backend meio-morto (o parent não relança o VM supervisor). Isso exige reinício manual do Docker Desktop pelo usuário. **Não rode `pkill -9 com.docker`** sem consentimento explícito — é destrutivo e o usuário pode ter outros containers.

Quando bater nesse estado: rode standardrb (verde) mas **não marque a task `[x]`** nem alegue teste verde — mantenha `[~]` e reporte o bloqueio honestamente, pedindo ao usuário para reiniciar o Docker e então rodar `up -d` + `db:prepare` + `exec -T rspec`.

### App container cai com `Bundler::GemNotFound` (volume `bundle_path` defasado)

Após o Docker voltar e rodar `docker compose up -d app`, o container `core-app-1` pode subir e **cair em segundos** (`exited with code 1`). O log (`docker logs core-app-1`) mostra:

```
Could not find rails-8.1.3.1, trailblazer-activity-0.17.0, spring-4.7.0, ... in locally installed gems (Bundler::GemNotFound)
```

**Causa:** o bundle do app vive no volume nomeado `bundle_path` montado em `/bundle` (`BUNDLE_PATH=/bundle/vendor` no `docker-compose.yml`). Esse volume foi populado com gems de um `Gemfile.lock` antigo. Quando o lockfile muda (bump de rails/spring etc.), o volume fica defasado. O `RUN bundle install` do `Dockerfile.dev` roda **no build** e instala em `/usr/local/bundle` (camada da imagem), NÃO no volume — por isso `docker compose build app` **não** corrige o bundle de runtime.

**Fix (não-destrutivo):**
```bash
docker compose run --rm app bundle install   # instala gems frescas em /bundle/vendor (volume)
docker compose up -d app                      # recria o app com o bundle atualizado
```
Depois confirme que o container fica `Up` (não `exited`): `docker compose ps` + `docker logs core-app-1 | tail`. O servidor web boota com um monte de warnings `Enum element ... uses the prefix 'not_'` — isso é normal, não é erro.

Sequência completa de validação após o fix: `docker compose exec -T -e RAILS_ENV=test app bundle exec rails db:prepare` → `docker compose exec -T -e RAILS_ENV=test app bundle exec rspec <spec_file> --format documentation`.

Nota: `rails db:prepare` rodando migrations pode regravar `db/schema.rb` mesmo que o PR não tenha migration própria (migrations de outras branches que nunca rodaram localmente). Antes de commitar, cheque `git status --short` por um diff inesperado em `db/schema.rb` e reverta com `git checkout -- db/schema.rb` quando o PR não inclui migration — o usuário não quer esse arquivo no commit.
