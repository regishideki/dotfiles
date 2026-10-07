---
name: pr-open-full
description: "Versão completa do pr-open: abre PR Draft, cria trigger de bootstrap no Claude Code Remote que dispara Job A (monitorar comentários) e Job B (aprovar e mergear)."
version: 1.0.0
author: regishattori
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [github, pull-request, ci, automation, claude-code-remote, jira, slack]
    related_skills: [pr-open, pr-analyse-comments, pr-request-review]
---

# PR Open Full

Versão completa do pr-open. Além de abrir o PR Draft, cria um trigger de bootstrap no Claude Code Remote (CCR) que por sua vez cria os Jobs A e B como triggers `meta_mcp`.

## Preparação (igual ao pr-open)

Se estiver no projeto `core`, antes de cada commit, siga o command `/test-impact` para rodar os testes impactados pelas mudanças.

Se ainda não rodou, rode o comando de lint para corrigir os erros de linting. Provavelmente ele estará no Makefile ou no package.json.
Se for problema em um arquivo de snippets, não tem problema pois ele está no gitignore.

Caso tenha feito alguma migração no banco, rode o comando de migração para atualizar o schema do banco.

### Verificar conflitos com a main

1. Rode `git fetch origin main && git merge origin/main`
2. Se houver conflitos, resolva-os e commite o merge
3. Faça push das mudanças

## Abrir o PR

Veja se já está na branch certa. Se não estiver, crie uma nova branch e faça o commit nela.

Abra um Pull Request como Draft com:
- **Assignee**: `regishideki`
- **Reviewer**: `GenialCare/genialcare-engineering-agent` (o **bot**, primeira camada de validação — NÃO `capacidade-clinica`, que entra só depois da validação do usuário)

O pedido de review do time `genialcare-engineering-agent` dispara o workflow `agentic-pr-review.yaml`
("PR Review") no core, que publica a review do bot.

**Gotcha crítico:** o PR precisa estar **READY (não-draft)** ANTES de pedir o review do bot.
Pedir review num PR draft dispara `review_requested` com `requested_team` vazio → o job cai em
`skipped`. Sequência: `gh pr create --draft ...` → `gh pr ready <N>` →
`gh pr edit <N> --add-reviewer GenialCare/genialcare-engineering-agent`.

O PR precisa ter um título e uma descrição com um resumo do que foi feito em pt-BR.
Descreva as necessidades de negócio, quando houver.

Quanto ao código, não precisa ser muito detalhista sobre quais arquivos foram alterados. A não ser que queira enfatizar algo.

## Bootstrap trigger

Após abrir o PR, crie um **trigger de bootstrap** via `mcp__claude_ai_Claude_Code_Remote__create_trigger`. O bootstrap dispara uma vez em uma sessão CCR e cria os Jobs A e B como triggers `meta_mcp` — o que garante que qualquer sessão futura (inclusive os próprios jobs no guard clause) possa deletá-los.

Após criar o bootstrap, faça imediatamente `update_trigger(BOOTSTRAP_ID, ...)` injetando o ID real no lugar do placeholder `{{BOOTSTRAP_ID}}` no prompt.

---

### Convenção de título dos jobs
```
[nome-do-repo] PR#NÚMERO CARDS — resumo curto | Job X: descrição
```
- `nome-do-repo`: apenas o nome sem owner (`clinical-panel`, `core`, etc.)
- `CARDS`: cards Jira em sequência (`PEC-4057/58/59/60`)
- `resumo curto`: ≤7 palavras descrevendo o que o PR faz

Exemplos:
- `[clinical-panel] PR#2074 PEC-4057/58/59/60 — alvos ativos no Checkin | Job A: monitorar comentários`
- `[core] PR#6110 PEC-4052 — regras de conclusão COPM | Job B: aprovar e mergear`

---

### Parâmetros do bootstrap (substituir todos com valores reais)

| Placeholder | Valor |
|---|---|
| `OWNER_REPO` | ex: `GenialCare/clinical-panel` |
| `PR_NUMBER` | número do PR |
| `BRANCH` | nome da branch |
| `WORKSPACE` | ex: `/Users/regishattori/workspace/genial/clinical-panel` |
| `JIRA_CARDS` | lista dos cards Jira |
| `ATLASSIAN_CLOUD_ID` | `1e91fa41-0b59-4d11-9437-d2352fb6a18d` (padrão GenialCare) |
| `TITULO_BASE` | ex: `[clinical-panel] PR#2074 PEC-4057/58/59/60 — alvos ativos no Checkin` |

---

### Bootstrap

**Nome:** `[REPO] PR#NÚMERO CARDS — Bootstrap: criar Job A e Job B`
**`run_once_at`:** agora + 1 minuto (RFC3339 UTC)
**MCP connections:** Claude Code Remote + Atlassian + Slack

**Prompt do bootstrap** (substituir todos os valores em MAIÚSCULO com dados reais):

```
Você é um agente de bootstrap. Execute cada passo em ordem e se auto-destrua no final.

## Passo 1 — Criar Job A (monitorar comentários)

mcp__claude_ai_Claude_Code_Remote__create_trigger com:
- name: "TITULO_BASE | Job A: monitorar comentários"
- cron_expression: "0 13-22 * * *"
- environment_id: env_013hHusocYttFaz2icXpuzHV
- create_new_session_on_fire: true
- mcp_connections: apenas Claude Code Remote (bf7c680d-5fdc-5ef4-b4a0-abadb619bf0a / https://api.anthropic.com/v1/code/mcp/meta)
- session_context.allowed_tools: ["preset:default", "Bash", "Glob", "Grep", "Read", "WebFetch", "Skill"]
- prompt:

---
## Guard clause — executar PRIMEIRO

Execute: gh pr view PR_NUMBER --repo OWNER_REPO --json state -q '.state'

Se o resultado for diferente de "OPEN":
  - mcp__claude_ai_Claude_Code_Remote__list_triggers()
  - Para cada trigger cujo nome contenha "PR#PR_NUMBER CARDS": mcp__claude_ai_Claude_Code_Remote__delete_trigger(trigger_id: <id>)
  - Encerrar sem fazer mais nada.

## Tarefa principal

Execute:
1. gh api repos/OWNER_REPO/pulls/PR_NUMBER/reviews
2. gh api repos/OWNER_REPO/pulls/PR_NUMBER/comments

Se houver comentários de qualquer usuário (humano ou bot), siga as instruções do skill pr-analyse-comments.
Se não houver comentários novos, encerre silenciosamente.
---

## Passo 2 — Criar Job B (aprovar e mergear)

mcp__claude_ai_Claude_Code_Remote__create_trigger com:
- name: "TITULO_BASE | Job B: aprovar e mergear"
- cron_expression: "0 13-22 * * *"
- environment_id: env_013hHusocYttFaz2icXpuzHV
- create_new_session_on_fire: true
- mcp_connections: Claude Code Remote (bf7c680d-5fdc-5ef4-b4a0-abadb619bf0a / https://api.anthropic.com/v1/code/mcp/meta) + Atlassian (0ceb92d8-f7e9-46c7-860d-a84374e5f2bf / https://mcp.atlassian.com/v1/mcp) + Slack (7a785ba1-1d42-4dda-bbad-2dab77447d7e / https://mcp.slack.com/mcp)
- session_context.allowed_tools: ["preset:default", "Bash", "Glob", "Grep", "Read", "WebFetch", "Skill"]
- prompt:

---
## Guard clause — executar PRIMEIRO

Execute: gh pr view PR_NUMBER --repo OWNER_REPO --json state -q '.state'

Se o resultado for diferente de "OPEN":
  - mcp__claude_ai_Claude_Code_Remote__list_triggers()
  - Para cada trigger cujo nome contenha "PR#PR_NUMBER CARDS": mcp__claude_ai_Claude_Code_Remote__delete_trigger(trigger_id: <id>)
  - Encerrar sem fazer mais nada.

## Tarefa principal

1. Verifique aprovação: gh pr view PR_NUMBER --repo OWNER_REPO --json reviewDecision
   - Se reviewDecision != APPROVED: encerre.

2. Verifique CI: gh pr checks PR_NUMBER --repo OWNER_REPO
   - Se falhando:
     - gh run list --repo OWNER_REPO --branch BRANCH --limit 3 e depois gh run view <id> --repo OWNER_REPO --log-failed
     - Se falha não relacionada ao PR: cd WORKSPACE && git fetch origin main && git merge origin/main && git push
     - Se falha no PR: analise, corrija, commit e push
     - Encerre (próxima execução verifica)
   - Se CI OK: continue para o passo 3.

3. Mergear: gh pr merge PR_NUMBER --repo OWNER_REPO --merge

4. Mover JIRA_CARDS para VALIDATION via Atlassian MCP (cloudId: ATLASSIAN_CLOUD_ID, transition id: 51).

5. Avisar Slack canal #claude-to-regis (ID: C0AQPLZ6HU7): informar que o PR #PR_NUMBER (JIRA_CARDS) foi mergeado.

6. Criar 3 Jobs C (deploy monitor) via create_trigger, espaçados 30 min (T+30, T+60, T+90 a partir de agora).
   create_new_session_on_fire: true em cada Job C.
   MCP connections dos Jobs C: Claude Code Remote + Atlassian + Slack.
   Prompt de cada Job C:
   - gh run list --repo OWNER_REPO --branch main --limit 5
   - Se deploy OK (conclusion == success no workflow pós-merge):
     - Avisar Slack (#claude-to-regis C0AQPLZ6HU7): deploy do PR #PR_NUMBER (JIRA_CARDS) concluiu com sucesso
     - Mover JIRA_CARDS para DONE via Atlassian (cloudId: ATLASSIAN_CLOUD_ID, transition id: 41)
     - list_triggers() e deletar todos cujo nome contenha "PR#PR_NUMBER CARDS" (Jobs C restantes)
   - Se ainda rodando: encerre e aguarde próximo disparo.
   - Se este for o último disparo sem sucesso: avisar Slack sobre possível falha e deletar Jobs C restantes.

7. Limpar: mcp__claude_ai_Claude_Code_Remote__list_triggers() e deletar todos cujo nome contenha "PR#PR_NUMBER CARDS".
---

## Passo 3 — Auto-destruir o bootstrap

- mcp__claude_ai_Claude_Code_Remote__list_triggers()
- Encontrar o trigger cujo nome contenha "PR#PR_NUMBER" e "Bootstrap"
- mcp__claude_ai_Claude_Code_Remote__delete_trigger(trigger_id: <bootstrap_id>)
```
