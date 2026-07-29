---
name: pr-request-review
description: "Remove marca Draft do PR, envia título+link para o Slack, move card Jira para REVIEW, e cria jobs para monitorar comentários e aprovação."
version: 2.0.0
author: regishattori
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [github, pull-request, review, slack, jira, automation]
    related_skills: [pr-open, pr-analyse-comments]
---

# PR Request Review

Solicita review de um PR: remove marca Draft, notifica Slack, move card Jira para REVIEW, e cria jobs de monitoramento.

## Pré-requisitos

- **Slack MCP**: precisa estar autenticado (`hermes mcp login slack`). Se não estiver, avise o usuário para rodar o login. Para enviar mensagens, use a API do Slack diretamente (chat.postMessage) com o token em `~/.hermes/mcp-tokens/slack.json`, ou a ferramenta `slack_send_message` se disponível.
- **Atlassian MCP**: precisa estar autenticado (`hermes mcp login atlassian`). Se não estiver, avise o usuário. As ferramentas do Atlassian MCP (como `searchJiraIssuesUsingJql`, `transitionJiraIssue`) só ficam disponíveis após `/reset` da sessão se o login foi feito durante a sessão.

## Passos

### 1. Verificar CI

Verifique com `gh pr checks PR_NUMBER --repo OWNER/REPO`. Se não estiver passando, corrija o problema antes de prosseguir.

### 2. Remover Draft

Se o PR estiver marcado como "Draft", remova com `gh pr ready PR_NUMBER --repo OWNER/REPO`.

### 3. Notificar Slack

Envie o título do PR + link do PR para o Slack no canal `#product-engineers-capacidade-clinica` (channel ID: `C06PPV63EU9`).

Forma de envio via API direta (mais confiável quando as ferramentas MCP não estão carregadas na sessão):
```python
import json, urllib.request, urllib.parse
with open(os.path.expanduser("~/.hermes/mcp-tokens/slack.json")) as f:
    tokens = json.load(f)
data = urllib.parse.urlencode({"channel": "C06PPV63EU9", "text": "TÍTULO — URL"}).encode()
req = urllib.request.Request("https://slack.com/api/chat.postMessage", data=data,
    headers={"Authorization": f"Bearer {tokens['access_token']}", "Content-Type": "application/x-www-form-urlencoded"})
resp = urllib.request.urlopen(req)
```

### 4. Mover card Jira para REVIEW

Busque TODOS os cards abertos atribuídos ao usuário atual com JQL: `assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC`

Com a lista em mãos, deduza qual card tem a ver com o PR atual (pelo título, contexto do branch, ou descrição) — não use busca por palavras-chave, pois os títulos de cards usam linguagem de negócio e podem não corresponder aos termos técnicos do PR.

Se encontrar, mova para "REVIEW" usando a transição correspondente. Se não encontrar, pergunte se quer que crie uma tarefa ou uma história.

## Jobs periódicos

Crie os jobs usando a ferramenta `cronjob`.

### Importante sobre sintaxe de schedule

- `every 30m` = job recorrente (re-executa a cada 30 min indefinidamente)
- `30m` = job one-shot (executa UMA vez após 30 min e para) — NÃO USE para jobs que devem repetir
- Para limitar por horário comercial, use expressão cron: `0,30 10-18 * * 1-5` (a cada 30min das 10h às 18h30, seg a sex)
- O parâmetro `repeat` controla quantas vezes um job recorrente executa antes de parar automaticamente
- Jobs devem se auto-remover (`cronjob(action='remove', job_id='JOB_ID')`) quando a condição final for atendida (PR mergeado, etc.). Inclua `cronjob` no `enabled_toolsets`.

### Job 1 — Verificar comentários
- **Schedule:** `0,30 10-18 * * 1-5` (horário comercial, seg a sex)
- **Repeat:** forever (auto-remover quando PR for merged/closed)
- **Prompt:** Verificar comentários do PR com:
  1. `gh api repos/OWNER/REPO/pulls/PR_NUMBER/reviews`
  2. `gh api repos/OWNER/REPO/pulls/PR_NUMBER/comments`
  - Se houver qualquer comentário, invoque o skill `pr-analyse-comments`.
  - Se o PR estiver merged/closed, auto-remover o job.
- **enabled_toolsets:** `["terminal", "file", "cronjob"]`

### Job 2 — Verificar aprovação e mergear
- **Schedule:** `0,30 10-18 * * 1-5` (horário comercial, seg a sex)
- **Repeat:** forever (auto-remover quando PR for mergeado)
- **Prompt:** Verificar com `gh pr view PR_NUMBER --repo OWNER/REPO --json reviews,state,mergedAt`:
  - Se ainda não aprovado: responder "PR ainda não aprovado." e nada mais.
  - Se aprovado (state APPROVED):
    1. Verificar CI com `gh pr checks PR_NUMBER --repo OWNER/REPO`
    2. Se CI OK: mergear com `gh pr merge PR_NUMBER --repo OWNER/REPO --squash --delete-branch`, mover card Jira para "VALIDATION", auto-remover este job, e criar um novo job de deploy (abaixo).
    3. Se CI com falha: analisar o erro, corrigir (se nos arquivos do PR) ou atualizar com main (se em arquivo não relacionado), fazer push.
    4. Se CI ainda rodando: responder "CI ainda em andamento." e nada mais.
  - Se houver mudanças solicitadas (CHANGES_REQUESTED): descrever quais.
  - Se PR merged/closed: auto-remover o job.
- **enabled_toolsets:** `["terminal", "file", "cronjob"]`

### Job 3 — Monitorar deploy (criado após merge)
- **Schedule:** `every 30m`
- **Repeat:** 3 (parar após 3 tentativas sem sucesso)
- **Prompt:** Verificar status do deploy. Se deploy foi feito com sucesso: mover card Jira para "DONE" e auto-remover o job. Se deploy não for feito com sucesso em 3 tentativas: avisar por Slack no canal `#claude-to-regis` e auto-remover o job.
- **enabled_toolsets:** `["terminal", "file", "cronjob"]`
