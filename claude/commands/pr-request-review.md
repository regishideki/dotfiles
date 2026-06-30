Verificar se está passando no CI.
Se não estiver, corrigir o problema.

Se o PR estiver marcado como "Draft", remover essa marcação.
Envie o título do PR + link do PR para o Slack no canal #product-engineers-capacidade-clinica com MCP.

Verifique no Jira se há tasks que indiquem o que foi feito. Para encontrar o card correto:
1. Busque TODOS os cards abertos atribuídos ao usuário atual com JQL: `assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC`
2. Com a lista em mãos, deduza qual card tem a ver com o PR atual (pelo título, contexto do branch, ou descrição) — não use busca por palavras-chave, pois os títulos de cards usam linguagem de negócio e podem não corresponder aos termos técnicos do PR
3. Se encontrar, mova para "REVIEW". Se não encontrar, pergunte se quer que crie uma tarefa ou uma história.

## Criação dos jobs de monitoramento

Crie os dois jobs periódicos abaixo usando `RemoteTrigger`. Em seguida, **atualize o prompt de cada um** via `update_trigger` para injetar os `trigger_id`s de ambos — isso é obrigatório para que os agentes consigam se auto-desativar.

Inclua o conector `Claude Code Remote` (connector_uuid: `bf7c680d-5fdc-5ef4-b4a0-abadb619bf0a`, name: `Claude-Code-Remote`, url: `https://api.anthropic.com/v1/code/mcp/meta`) nas `mcp_connections` de **todos** os jobs criados.

### Procedimento de criação (seguir esta ordem)

1. Crie **Job A** (comentários) com RemoteTrigger → guarde `TRIGGER_ID_A`
2. Crie **Job B** (aprovação + CI) com RemoteTrigger → guarde `TRIGGER_ID_B`
3. Atualize Job A via `update_trigger(trigger_id: TRIGGER_ID_A)` substituindo os placeholders `{{TRIGGER_ID_A}}` e `{{TRIGGER_ID_B}}` pelos IDs reais
4. Atualize Job B via `update_trigger(trigger_id: TRIGGER_ID_B)` da mesma forma

---

### Job A — monitorar comentários

- **Schedule:** `0 13-22 * * *` (10h–19h BRT)
- **Repo:** mesmo do PR

**Prompt do Job A** (substituir `{{PR_NUMBER}}`, `{{REPO}}`, `{{TRIGGER_ID_A}}`, `{{TRIGGER_ID_B}}`):

```
## Guard clause — executar PRIMEIRO

STATE=$(gh pr view {{PR_NUMBER}} --repo {{REPO}} --json state -q '.state')
Se STATE != "OPEN" (merged ou closed):
  - Desativar este job: update_trigger(trigger_id: "{{TRIGGER_ID_A}}", enabled: false) via Claude Code Remote MCP
  - Desativar Job B: update_trigger(trigger_id: "{{TRIGGER_ID_B}}", enabled: false) via Claude Code Remote MCP
  - Encerrar sem fazer mais nada.

## Tarefa principal

Execute:
1. gh api repos/{{REPO}}/pulls/{{PR_NUMBER}}/reviews
2. gh api repos/{{REPO}}/pulls/{{PR_NUMBER}}/comments

Se houver comentários de qualquer usuário (humano ou bot), siga as instruções do comando /pr-analyse-comments.
Se não houver comentários, encerre silenciosamente.
```

---

### Job B — monitorar aprovação e CI

- **Schedule:** `0 13-22 * * *` (10h–19h BRT)
- **Repo:** mesmo do PR

**Prompt do Job B** (substituir `{{PR_NUMBER}}`, `{{REPO}}`, `{{TRIGGER_ID_A}}`, `{{TRIGGER_ID_B}}`, `{{JIRA_CARD}}`):

```
## Guard clause — executar PRIMEIRO

STATE=$(gh pr view {{PR_NUMBER}} --repo {{REPO}} --json state -q '.state')
Se STATE != "OPEN" (merged ou closed):
  - Desativar Job A: update_trigger(trigger_id: "{{TRIGGER_ID_A}}", enabled: false) via Claude Code Remote MCP
  - Desativar este job: update_trigger(trigger_id: "{{TRIGGER_ID_B}}", enabled: false) via Claude Code Remote MCP
  - Encerrar sem fazer mais nada.

## Tarefa principal

1. Verifique aprovação: gh pr view {{PR_NUMBER}} --repo {{REPO}} --json reviewDecision
   - Se não aprovado: encerre.

2. Verifique CI: gh pr checks {{PR_NUMBER}} --repo {{REPO}}
   - Se CI falhando:
     - Identifique o motivo (gh run view <id> --log-failed)
     - Se falha não relacionada às mudanças do PR: git fetch origin main && git merge origin/main && git push
     - Se falha nas mudanças do PR: analise, corrija, commit e push
     - Encerre (próxima execução verifica o resultado)
   - Se CI OK: siga para o passo 3.

3. Mergear PR: gh pr merge {{PR_NUMBER}} --repo {{REPO}} --merge

4. Mover {{JIRA_CARD}} para "VALIDATION" via Atlassian MCP.

5. Desativar Job A e este job via Claude Code Remote MCP:
   - update_trigger(trigger_id: "{{TRIGGER_ID_A}}", enabled: false)
   - update_trigger(trigger_id: "{{TRIGGER_ID_B}}", enabled: false)

6. Criar Job C (deploy monitor) — schedule: a cada 30 minutos, máx 3 disparos.
   Incluir Claude Code Remote MCP nas mcp_connections do Job C.
   Guardar TRIGGER_ID_C e injetá-lo no próprio prompt do Job C.

   Prompt do Job C:
   - Verificar runs do GitHub Actions após o merge
   - Se deploy OK:
     - Avisar Slack no canal #claude-to-regis (ID: C0AQPLZ6HU7)
     - Mover {{JIRA_CARD}} para "DONE" via Atlassian MCP
     - Desativar este job: update_trigger(trigger_id: "{{TRIGGER_ID_C}}", enabled: false) via Claude Code Remote MCP
   - Se ainda não concluído: encerre e aguarde próxima execução.
   - Se falhou após 3 tentativas:
     - Avisar Slack no canal #claude-to-regis (ID: C0AQPLZ6HU7)
     - Desativar este job: update_trigger(trigger_id: "{{TRIGGER_ID_C}}", enabled: false) via Claude Code Remote MCP
```
