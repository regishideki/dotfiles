Se estiver no projeto `core`, antes de cada commit, siga o command `/test-impact` para rodar os testes impactados pelas mudanças.

Se ainda não rodou ainda, rode o comando de lint para corrigir os erros de linting. Provavelmente ele estará ou no Makefile ou no package.json.
Se for problema em um arquivo de snippets, não tem problema pois ele está no gitignore.

Caso tenha feito alguma migração no banco, rode o comando de migração para
atualizar o schema do banco.

Antes de abrir o PR, verifique se há conflitos com a main:
1. Rode `git fetch origin main && git merge origin/main`
2. Se houver conflitos, resolva-os e commite o merge
3. Faça push das mudanças

Veja se já está na branch certa. Se não estiver, crie uma nova branch e faça o commit nela.
Agora, abra um Pull Request como Draft com "regishideki" como assignee e "GenialCare/capacidade-clinica" como reviewer.
Ele precisa ter um título e uma descrição com um resumo do que foi feito em pt-BR.
Descreva as necessidades de negócio, quando houver.

Quanto ao código, não precisa ser muito detalhista sobre quais arquivos foram alterados, por exemplo. A não ser que
queira enfatizar algo.

