---
name: pr-analyse-comments
description: "Lê todos os comentários de um PR (gerais e inline), analisa quais fazem sentido, faz as alterações necessárias, responde threads em pt-BR."
version: 1.0.0
author: regishattori
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [github, pull-request, review, comments, automation]
    related_skills: [pr-open, review-pr]
---

# PR Analyse Comments

Leia TODOS os comentários feitos no Pull Request — tanto comentários gerais quanto comentários inline em linhas de código, e de qualquer autor (humanos ou bots).

## Buscar comentários

Use os dois comandos abaixo (substituindo OWNER/REPO e PR_NUMBER pelos valores corretos):

1. Comentários gerais de review:
   `gh api repos/OWNER/REPO/pulls/PR_NUMBER/reviews`

2. Comentários inline (em linhas específicas de código, **apenas deste PR** — note o `PR_NUMBER` no path, senão o GitHub retorna comentários de TODOS os PRs do repo):
   `gh api repos/OWNER/REPO/pulls/PR_NUMBER/comments`

## Análise

Reflita sobre quais fazem sentido e quais não fazem.

Os que fazem sentido:
- Faça a alteração necessária
- Crie um teste para validar, se necessário
- **Commit incremental por comentário resolvido** (não acumule tudo num único commit no final — cada comentário resolvido vira um commit próprio, com push)
- Dê push
- Comente na thread que a alteração foi feita, **incluindo o link do commit** (ex: `https://github.com/OWNER/REPO/commit/<sha>`) pra pessoa ver exatamente o que mudou

Para responder a um comentário inline, use (note o `PR_NUMBER` no path — sem ele o GitHub retorna 404):
```
gh api -X POST repos/OWNER/REPO/pulls/PR_NUMBER/comments/COMMENT_ID/replies -f body="..."
```

Os comentários que não entender ou que não fizer muito sentido, avise quais são e o motivo da discórdia. Bole uma mensagem de resposta, mas não a envie ainda até a aprovação do usuário.

## Regras

- Todas as respostas aos comentários devem ser escritas em pt-BR.
- Caso seja uma mensagem do bot do Gemini, marcar o @gemini-code-assist.
