---
name: implement-feature-bridge
description: Use ao executar implement-feature. PRs via pr-open, não gh.
version: 1.0.0
---

# Implement Feature Bridge

Complementa o fluxo `implement-feature` do repo `product-engineer-agent`.

## Regra principal

**NUNCA use `gh pr create --draft` diretamente.** Sempre use a skill `pr-open` para abrir PRs.

## O que o pr-open faz

- Abre PR como Draft
- Configura **assignee**: `regishideki`
- Configura **reviewer**: `GenialCare/capacidade-clinica`
- Cria 2 cron jobs: comentários de bots (3x) + monitorar CI (6x, auto-remove)

## Pitfall: PRs abertos sem pr-open

Se PRs foram abertos com `gh pr create --draft` sem `pr-open`, faça retrofit:
1. `gh pr edit <N> --add-assignee regishideki --add-reviewer GenialCare/capacidade-clinica`
2. Criar os 2 cron jobs conforme padrão do `pr-open`
3. Atualizar descrição se necessário (ex: link de planilha)

## Briefing do subagent (Passo 1.4 do implement-feature)

Ao despachar subagents de execução, a instrução sobre PR deve ser:

```
- Ao terminar: crie branch, commita, abra PR draft com skill pr-open.
```
