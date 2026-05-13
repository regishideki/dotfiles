Leia TODOS os comentários feitos no Pull Request — tanto comentários gerais quanto comentários inline em linhas de código, e de qualquer autor (humanos ou bots).

Para buscar os comentários, use os dois comandos abaixo (substituindo OWNER/REPO e PR_NUMBER pelos valores corretos):

1. Comentários gerais de review:
   `gh api repos/OWNER/REPO/pulls/PR_NUMBER/reviews`

2. Comentários inline (em linhas específicas de código):
   `gh api repos/OWNER/REPO/pulls/comments`

Reflita sobre quais fazem sentido e quais não fazem.
Os que fazem sentido, faça a alteração necessária, dê push e comente nas threads que a alteração foi feita com link para
o commit. Para responder a um comentário inline, use:
   `gh api repos/OWNER/REPO/pulls/comments/COMMENT_ID/replies -f body="..."`

Os comentários que não entender ou que não fizer muito sentido, me avise quais são e o motivo da discórdia. Bole uma
mensagem de resposta, mas não a envie ainda até a minha aprovação.

Todas as respostas aos comentários devem ser escritas em pt-BR.
