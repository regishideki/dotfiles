Se ainda não rodou ainda, rode o comando de lint para corrigir os erros de linting. Provavelmente ele estará ou no Makefile ou no package.json.
Se for problema em um arquivo de snippets, não tem problema pois ele está no gitignore.

Caso tenha feito alguma migração no banco, rode o comando de migração para
atualizaro schema do banco.

Veja se já está na branch certa. Se não estiver, crie uma nova branch e faça o commit nela.
Agora, abra um Pull Request como Draft com "regishideki" como assignee e "GenialCare/capacidade-clinica" como reviewer.
Ele precisa ter um título e uma descrição com um resumo do que foi feito em pt-BR.
Descreva as necessidades de negócio, quando houver.

Quanto ao código, não precisa ser muito detalhista sobre quais arquivos foram alterados, por exemplo. A não ser que
queira enfatizar algo.

Após abrir o PR, crie os seguites jobs periódicos:

- verificar comentários de bots de 5 em 5 minutos no máximo 3 vezes
  - verifique se tem comentários de algum bot no PR. Se tiver, siga o comando `/pr-analyse-comments`

- verificar CI de 5 em 5 minutos até completar o ciclo com sucesso
  - verifique status do CI
    - se estiver OK:
        - executar comando `pr-to-slack`
        - parar job
    - se não estiver OK, verifique o que tem de errado, corrija e dê push
