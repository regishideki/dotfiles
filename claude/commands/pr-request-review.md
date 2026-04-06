Verificar se está passsando no CI.
Se não estiver, corrigir o problema.

Se o PR estiver marcado como "Draft", remover essa marcação.
Envie o título do PR + link do PR para o Slack no canal #product-engineers-capacidade-clinica

Verifique no Jira se há tasks que indiquem o que foi feito. Para encontrar o card correto:
1. Busque TODOS os cards abertos atribuídos ao usuário atual com JQL: `assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC`
2. Com a lista em mãos, deduza qual card tem a ver com o PR atual (pelo título, contexto do branch, ou descrição) — não use busca por palavras-chave, pois os títulos de cards usam linguagem de negócio e podem não corresponder aos termos técnicos do PR
3. Se encontrar, mova para "REVIEW". Se não encontrar, pergunte se quer que crie uma tarefa ou uma história.

Crie o seguinte job periódico:
- verificar comentários de 30 em 30 minutos das 10:00 às 19:00
  - verifique se tem comentários no PR. Se tiver, siga as instruções do comando `/pr-analyse-comments`
- Verificar se PR está aprovado de 30 em 30 minutos das 10:00 às 19:00
    - Se tiver aprovado, criar um job periódico que de 5 em 5 minutos:
        - verifique status do CI
            - se não estiver OK, verifique o que tem de errado, corrija e dê push
                - se a falha for em um arquivo não relacionado às mudanças do PR, tente atualizar a branch com o main (`git fetch origin main && git merge origin/main`) 
                — pode ser que o main tenha a correção. Se o merge resolver, dê push.
            - se estiver OK:
                - mergear PR
                - mover card do Jira para "VALIDATION"
                - parar job
                - iniciar um novo job que roda de 30 em 30 minutos que verifica
                  status do deploy.
                    - se deploy não for feito com sucesso em 3
                  tentativas
                        - me avisar por Slack no canal #claude-to-regis
                    - se deploy foi feito com sucesso
                        - mover card do Jira para "DONE"

