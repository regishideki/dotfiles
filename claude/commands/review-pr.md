Analise o código de um PR ou branch comparado com a main. Siga os passos abaixo:

## 1. Identificar o alvo

Analise `$ARGUMENTS` para determinar o alvo:

**Caso A — índice numérico simples** (ex: `3`)
Se `$ARGUMENTS` for um número inteiro puro, leia `/tmp/claude-review-queue.json` e encontre a entrada com `index == $ARGUMENTS`. Isso resolve para `repo` e `number`. Exemplo:
```bash
cat /tmp/claude-review-queue.json | jq '.[] | select(.index == 3)'
# → { "index": 3, "repo": "GenialCare/clinical-panel", "number": 456 }
```
Use `repo` e `number` como alvo cross-repo (ver abaixo).

**Caso B — PR no repo atual** (ex: `123`)
Se `$ARGUMENTS` for um número e você estiver dentro de um repositório git, trate como número de PR do repo atual. Use `gh pr view <número>`.

**Caso C — PR cross-repo** (ex: `GenialCare/core#123` ou quando resolvido do Caso A)
Quando o alvo é de outro repositório, clone em diretório temporário:
```bash
gh repo clone <owner/repo> /tmp/review-$(basename <repo>) -- --depth=1
cd /tmp/review-$(basename <repo>)
gh pr checkout <number>
```
Ao terminar a análise, remova o diretório: `rm -rf /tmp/review-$(basename <repo>)`.

**Caso D — nome de branch**
Se `$ARGUMENTS` for um nome de branch, use essa branch no repo atual.

**Caso E — sem argumentos**
Use a branch atual no repo atual.

## 2. Obter o diff e puxar a branch

- Obtenha o diff completo comparado com a main:
  - Para PR: `gh pr diff <número>`
  - Para branch: `git diff origin/main...<branch>`

- O diff sozinho nem sempre é suficiente. Quando precisar de contexto adicional — verificar se um padrão existe em arquivos similares, checar se há testes equivalentes para código não alterado, entender a estrutura ao redor de uma mudança — acesse a branch e leia os arquivos diretamente. Use **git worktree** para não interferir com trabalho em andamento na branch atual:
  ```bash
  # Criar worktree em diretório irmão
  git worktree add ../$(basename $PWD)-review origin/<branch-do-pr>
  # Analisar os arquivos no novo diretório
  # Ao terminar, remover o worktree
  git worktree remove ../$(basename $PWD)-review
  ```
  - Para descobrir o nome da branch do PR: `gh pr view <número> --json headRefName -q .headRefName`
  - Se não houver WIP na branch atual, `gh pr checkout <número>` também funciona (mais simples), lembrando de voltar com `git checkout -` ao terminar.

## 3. Ler descrição do PR (se existir)

- Se for um PR, leia o título e a descrição com `gh pr view <número>`.
- Leia também os comentários de review existentes com `gh api repos/{owner}/{repo}/pulls/{número}/comments` e `gh api repos/{owner}/{repo}/issues/{número}/comments`.

## 4. Resumo do que foi feito

Comece apresentando um resumo claro e conciso do que o PR/branch faz:
- Qual problema resolve ou funcionalidade adiciona
- Qual a abordagem adotada
- Quantos arquivos alterados, linhas adicionadas/removidas

## 5. Apresentar os diffs em ordem lógica

Organize os diffs numa ordem que facilite o entendimento, agrupando cada implementação junto com seus testes:

1. **Ponto de entrada + testes** — controllers, routes, entrypoints, ou o arquivo principal da mudança, seguidos imediatamente pelos seus specs/tests correspondentes
2. **Camada de negócio + testes** — services, use cases, models, interactors, cada um seguido dos seus testes
3. **Camada de dados** — migrations, queries, schemas
4. **Configurações e infraestrutura** — configs, CI, docker, etc.
5. **Outros** — arquivos que não se encaixam nas categorias acima

Para cada arquivo de implementação, mostre o diff e explique brevemente o que mudou. Em seguida, mostre o diff do teste correspondente e analise a qualidade do teste (ver seção 6).

## 6. Análise de qualidade do código

Analise e comente sobre:

### Nomenclatura
- Os nomes de classes, funções e variáveis são claros e descritivos?
- Seguem as convenções do projeto/linguagem?
- Algum nome ambíguo ou enganoso?

### Design e arquitetura
- A estrutura faz sentido para o que está sendo feito?
- Ponderar entre o que já existe no projeto (mais difícil de mudar) vs alterações simples que melhorariam a manutenibilidade.
- Separação de responsabilidades está adequada?
- Há acoplamento desnecessário?

### Qualidade dos testes
Para cada teste presente no diff, analise:

**Completude:**
- Cobre o happy path?
- Cobre os edge cases relevantes (inputs inválidos, nil, vazio, limites)?
- Cobre os cenários de erro/falha?
- Se há autorização/permissões envolvidas, testa os diferentes perfis de acesso?
- Há cenários importantes que não foram testados?

**Qualidade do código de teste:**
- Os testes são claros e legíveis? Dá pra entender o que testam só pelo nome/descrição?
- Estão bem organizados (describe/context/it fazem sentido)?
- Usam factories/fixtures de forma adequada ou criam dados demais?
- Há setup desnecessário ou compartilhado que torna os testes frágeis?
- Testam comportamento (o que o código faz) ou implementação (como o código faz)?
- Há testes redundantes que poderiam ser consolidados?

### Qualidade geral
- Há código duplicado que poderia ser extraído?
- Tratamento de erros está adequado?
- Há problemas de segurança (SQL injection, XSS, mass assignment, etc.)?

## 7. Veredito final

Dê sua opinião geral:
- **Aprovaria** — código está bom, pode ir
- **Aprovaria com sugestões** — está funcional mas tem pontos de melhoria (liste-os)
- **Pediria mudanças** — há problemas que deveriam ser resolvidos antes do merge (liste-os)

Seja pragmático. Foque em problemas reais que impactam manutenibilidade, legibilidade ou correção. Não seja pedante com questões puramente estilísticas que não afetam a qualidade do código.

## 8. Aprovar (se aplicável)

Se o veredito for "Aprovaria" ou "Aprovaria com sugestões" e o usuário pedir para aprovar, use `gh pr review <número> --repo <owner>/<repo> --approve` **sem body** — só a aprovação, sem comentários. A menos que o usuário peça explicitamente para incluir um comentário.
