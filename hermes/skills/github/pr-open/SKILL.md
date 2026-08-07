---
name: pr-open
description: "Prepara branch, abre PR como Draft com assignee/reviewer, e cria jobs periódicos para monitorar comentários de bots e CI."
version: 2.0.0
author: regishattori
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [github, pull-request, ci, automation, workflow]
    related_skills: [pr-analyse-comments, pr-open-full, pr-request-review]
---

# PR Open

Prepara a branch e abre um Pull Request como Draft, depois cria jobs periódicos para monitorar comentários de bots e status do CI.

## Antes de abrir o PR

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
- **Reviewer**: `GenialCare/capacidade-clinica`

O PR precisa ter um título e uma descrição com um resumo do que foi feito em pt-BR.
Descreva as necessidades de negócio, quando houver.

Quanto ao código, não precisa ser muito detalhista sobre quais arquivos foram alterados. A não ser que queira enfatizar algo.

## Jobs periódicos

Após abrir o PR, crie os seguintes jobs usando a ferramenta `cronjob`.

### Importante sobre sintaxe de schedule

- `every 10m` = job recorrente (re-executa a cada 10 min indefinidamente)
- `10m` = job one-shot (executa UMA vez após 10 min e para) — NÃO USE para jobs que devem repetir
- Para limitar por horário comercial, use expressão cron: `0,30 10-18 * * 1-5` (a cada 30min das 10h às 18h30, seg a sex)
- O parâmetro `repeat` controla quantas vezes um job recorrente executa antes de parar automaticamente

### Convenção de nome dos jobs

Use o padrão: `[nome-do-repo] PR#N — resumo-curto | Job N: descrição`

- `nome-do-repo`: apenas o nome sem owner (`clinical-panel`, `clinical-language-models`, `core`, etc.)
- `resumo-curto`: ≤7 palavras descrevendo o que o PR faz (extraído do título do PR)
- Exemplo: `[clinical-panel] PR#2074 — alvos ativos no Checkin | Job 1: comentários de bots`
- O `name` deve ser passado como parâmetro em TODAS as chamadas `cronjob action=create`.

### Job 1 — Verificar comentários de bots
- **Name:** `[REPO] PR#N — RESUMO | Job 1: comentários de bots`
- **Schedule:** `every 10m`
- **Repeat:** 3
- **Prompt:** Verificar comentários do PR com os dois comandos:
  1. Comentários gerais: `gh api repos/OWNER/REPO/pulls/PR_NUMBER/reviews`
  2. Comentários inline: `gh api repos/OWNER/REPO/pulls/PR_NUMBER/comments`
  - Se houver qualquer comentário de bot (usuário com `[bot]` no nome), invoque IMEDIATAMENTE o skill `pr-analyse-comments` — não analise os comentários por conta própria.
  - Se não houver comentários de bot, responder apenas "Nenhum comentário de bot encontrado." e nada mais.
- **enabled_toolsets:** `["terminal", "file"]`

### Job 2 — Verificar CI
- **Name:** `[REPO] PR#N — RESUMO | Job 2: monitorar CI`
- **Schedule:** `every 10m`
- **Repeat:** 6 (suficiente para cobrir um ciclo completo de CI)
- **Prompt:** Verificar status do CI com `gh pr checks PR_NUMBER --repo OWNER/REPO`:
  - Se estiver OK (todos passando): responder "CI do PR #PR_NUMBER completou com sucesso." e nada mais. O job deve se auto-remover com `cronjob(action='remove', job_id='JOB_ID')`.
  - Se ainda estiver rodando (pending): responder "CI ainda em andamento." e nada mais.
  - Se houver falha:
    - Se a falha for em arquivo não relacionado às mudanças do PR, tente atualizar a branch com a main (`git fetch origin main && git merge origin/main`). Se o merge resolver, dê push.
    - Se a falha for nos arquivos do PR, analise o erro, corrija, faça commit e push.
    - Descreva o que encontrou e o que fez para corrigir.
- **enabled_toolsets:** `["terminal", "file", "cronjob"]`
- **workdir:** caminho absoluto do repo

### Importante sobre jobs no CLI

Jobs criados em sessão CLI são local-only: o output é salvo mas NÃO é entregue de volta na sessão. O agente dentro do job deve usar `cronjob(action='remove', job_id='...')` para se auto-terminar quando a condição for atendida (CI passou, PR mergeado, etc.). Inclua `cronjob` no `enabled_toolsets` para permitir isso.
