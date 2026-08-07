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
- **core (Rails)**: `bundle exec rspec <spec_file>`, `bundle exec rubocop`
- Sempre rode os testes do arquivo alterado, não a suite completa (a suite é grande)

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
