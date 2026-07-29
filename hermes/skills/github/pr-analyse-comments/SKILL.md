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

2. Comentários inline (em linhas específicas de código):
   `gh api repos/OWNER/REPO/pulls/comments`

## Análise

Reflita sobre quais fazem sentido e quais não fazem.

Os que fazem sentido:
- Faça a alteração necessária
- Crie um teste para validar, se necessário
- Dê push
- Comente nas threads que a alteração foi feita com link para o commit

Para responder a um comentário inline, use:
```
gh api repos/OWNER/REPO/pulls/comments/COMMENT_ID/replies -f body="..."
```

Os comentários que não entender ou que não fizer muito sentido, avise quais são e o motivo da discórdia. Bole uma mensagem de resposta, mas não a envie ainda até a aprovação do usuário.

## Regras

- Todas as respostas aos comentários devem ser escritas em pt-BR.
- Caso seja uma mensagem do bot do Gemini, marcar o @gemini-code-assist.
