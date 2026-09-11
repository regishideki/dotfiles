---
name: genialcare-clinical-panel-stack
description: Use when working across GenialCare clinical-panel repos.
metadata:
  hermes:
    tags: [genialcare, clinical-panel, bff, cross-repo, debugging, integration]
---

# GenialCare Clinical Panel Stack

Gotchas e técnicas para trabalho cross-repo na stack do Painel Clínico (Core → clinical-panel-bff → clinical-panel). Coisas que custaram tempo de debug em sessões anteriores.

## Data contract: campo numérico exposto como `String` no BFF

O BFF expõe vários campos numéricos como `String` no schema GraphQL (ex.: `CalculatedOfficialScheduledHoursByDiscipline.aba`). Quando o frontend usa esse valor (que chega como string, ex. `"2"`) diretamente como `count` no i18next (`t('hours.hoursText', { count: valor })`), a pluralização falha e cai no fallback da chave base (ex. `"0 horas"`).

- Sempre normalize com `Number(valor)` antes de usar em `count` de i18next ou em aritmética.
- Padrão já usado em `clinical-panel/src/pages/CoverPage/Workloads/Schedule/Schedule.tsx`: `count: Number(value)`.
- O tipo TS no frontend pode declarar `number` enquanto o BFF devolve `String` — isso mascara o bug no `tsc`.
- Correção alternativa (raiz): tipar o campo como `Float`/`Int` no BFF, mas é mudança de contrato — a coerção no frontend é mais barata e imediata.

## Removendo feature flags (SplitIO) no frontend: cuidado com specs que dependem do default "off" em teste

Ao remover uma flag do tipo `DISABLE_X` (ou qualquer flag) de `src/constants/flags.ts` e hardcodar o comportamento "sempre ligada", **não baste alterar o componente e seu spec direto** — rode a suíte completa (`CI=true yarn vitest run --bail=1`) antes de abrir o PR, porque:

- `useFeatureFlag` usa `useTreatments` do `@splitsoftware/splitio-react`. Em testes, o SDK do Split.io normalmente **não é mockado** (não há mock global em `setupTests.ts`), então `useTreatments` retorna o treatment `'control'` por padrão → `defaultTreatment(treatment) = treatment === 'on'` → **a flag sempre avalia como `false` (desligada) nos testes**, mesmo que em produção ela esteja ligada.
- Isso significa que specs em OUTROS arquivos (não o componente que você está mexendo) podem ter sido escritos assumindo o comportamento de "flag desligada" — porque é isso que sempre rodou em CI. Quando você hardcoda o comportamento de "flag ligada", esses specs quebram mesmo sem você tocar neles.
- Exemplo real: ao remover `DISABLE_INTERVENTION_COMPLETE_SESSION_PARTICIPANTS` de `ConfirmedFields.tsx` (fazendo `enableParticipantsEdition = !isIntervention`), o arquivo `src/pages/Sessions/Complete/__tests__/Complete.spec.tsx` quebrou: vários testes com sessão do tipo `Intervention` tentavam digitar/selecionar um clínico adicional no campo `clinicians-input`, que agora fica `disabled`/`hidden` para esse tipo de sessão. Foi necessário ajustar os mocks de `clinicianIds` esperados (removendo o clínico que não pode mais ser adicionado via UI) e trocar `fillSessionForm({ clinicians: [mockClinicians[0]] })` por `fillSessionForm({ clinicians: [] })` nesses casos.
- **Procedimento recomendado**: depois de remover a flag e ajustar o componente + spec "óbvio", rode a suíte inteira. Se algo quebrar, o padrão do bug é sempre o mesmo — um teste que assumia o ramo "flag off" porque era o default de teste. Corrija esses testes para refletir o comportamento final (documentando a decisão no PR), não reverta a remoção da flag.
- `yarn vitest run <arquivo>` roda rápido; a suíte completa (`yarn vitest run` sem filtro, ~4 min) é o que realmente garante que não sobrou nenhum teste dependente do default antigo — vale a pena rodar antes do push final mesmo que o escopo pedido pelo usuário liste só 1-2 arquivos.

## Removendo várias feature flags em lote (orquestração com subagentes)

Quando o pedido é "remove todas as feature flags obsoletas" (não uma só), o
volume — clinical-panel tende a acumular 15-20+ flags em `src/constants/flags.ts`
— exige orquestração, não execução flag-a-flag manual. Abordagem que funcionou:

1. **Mapear uso real antes de agrupar por tema.** Não confie em nomes de
   constante para inferir relação — rode `grep -rl "\bFLAG_NAME\b" src
   --include='*.ts' --include='*.tsx'` para cada flag e agrupe pelos arquivos
   que ela realmente toca. Um agrupamento "por nome" (ex. todas com
   `THERAPY` no nome) pode juntar flags que não têm nada em comum, e separar
   flags que compartilham componente (ex. `CLINICAL_CASE_OWNER_HOME_ENABLED`
   e `THERAPIST_AREA` só ficam claramente relacionadas quando se vê que
   ambas tocam `MenuContent.tsx`/dashboard do Metabase no painel).
2. **Aceite um grupo "outros"/catch-all.** Nem toda flag pertence a um tema
   coerente — forçar agrupamento onde não há relação real (ex.
   `PLANNING_BY_CLINICAL_CASE_PAGE`, `COMPLETE_DISCIPLINE_ENABLED`,
   `SHOW_HOME_UPCOMING_SESSIONS_CARD`, `AVAILABLE_HOURS_OFFER` neste projeto)
   só confunde. Um catch-all explícito é mais honesto que um agrupamento
   artificial.
3. **Valide o fluxo completo com 1 flag simples antes de escalar.** Antes de
   disparar 15+ subagentes, rode 1 flag de baixo uso (2 arquivos) ponta a
   ponta: subagente → testes locais → PR → CI → sua revisão. Isso expõe cedo
   os dois problemas recorrentes: (a) o subagente que hits o limite de
   iterações reporta "push feito" sem ter commitado (ver
   `multi-agent-orchestration` skill, pitfall "push already done" — sempre
   confirme com `git fetch origin <branch> && git log origin/<branch>
   --oneline` você mesmo antes de aceitar); (b) o efeito colateral do
   default "flag off" nos testes (seção acima).
4. **Base do PR: confirme com histórico real, não suposição.** `gh pr list
   --state merged --limit 5 --json baseRefName` para saber se o time abre PR
   contra `main` ou `development` antes de instruir os subagentes — CLAUDE.md
   do repo organizador pode estar desatualizado ou ambíguo sobre isso.
5. Instrua cada subagente a, antes de finalizar: rodar a suíte completa
   (`CI=true yarn vitest run --bail=1`), fazer `grep` para confirmar 0
   referências restantes à flag, e confirmar explicitamente `git
   status`/`git log origin/<branch>` (não apenas relatar de memória).

## Removendo uma flag: recontaminação do arquivo compartilhado DEPOIS de já ter limpado uma vez

Quando `flags.ts` (ou outro arquivo muito compartilhado) é editado por uma
tarefa irmã em paralelo, a contaminação não é um evento único — o arquivo pode
ser sobrescrito de novo DEPOIS que você já removeu sua linha e seguiu em
frente para outros arquivos. Sintoma: você reaplica a remoção, segue
trabalhando em specs/componentes por vários passos, e ao rodar `grep` final
pela flag ainda encontra a constante em `flags.ts` — não porque o patch
falhou, mas porque o arquivo foi reescrito por outro agente enquanto você
mexia em outros arquivos.

- Não assuma que resolver a contaminação uma vez no início basta. Rode
  `grep`/`search_files` pela flag no repo inteiro **de novo, logo antes do
  commit final** (não só logo após o `git checkout -b`).
- Se reaparecer, reaplique a remoção pontual (old_string/new_string do seu
  trecho, nunca reescrevendo o arquivo inteiro) e não toque nas linhas de
  outras flags que estejam presentes — elas são o trabalho legítimo da tarefa
  irmã, mesmo que tenham "voltado" no meio do seu fluxo.
- Ao montar a lista de arquivos para `git add`, gere-a a partir de `git status
  --short` checado nesse momento final, não de uma lista mental feita no
  início da tarefa — o conjunto de arquivos tocados por você é estável, mas o
  conteúdo de arquivos compartilhados (`flags.ts`) pode ter ido e voltado.

## Removendo uma flag: um componente inteiro pode colapsar para "sempre null", não só uma prop

Quando o componente usa a flag dentro de uma condição OR de early-return (ex.
`if (flagSempreLigada || outraCondicao || maisOutra) return null;`), tornar a
flag permanentemente `true` faz essa condição ser **sempre verdadeira** —
o componente inteiro passa a renderizar `null` incondicionalmente, não é só
uma prop que fica fixa (o caso de prop fixa já está coberto mais abaixo, mas é
distinto: ali uma prop de um componente FILHO fica sempre no mesmo valor;
aqui o próprio componente que tinha a flag deixa de renderizar qualquer
coisa).

- Confirme esse colapso lendo os testes do componente antes de simplificar:
  se o describe "quando a flag está habilitada" já testava "não mostra X",
  isso confirma que o comportamento final é `return null` sempre.
- Simplifique o componente para retornar `null` incondicionalmente (com um
  comentário citando o nome da flag removida e por quê), mantendo a mesma
  assinatura de props se o componente pai não fez parte do escopo pedido —
  evita precisar editar o caller.
- Não delete o arquivo do componente nem remova seu import do caller a menos
  que isso tenha sido pedido explicitamente; um componente-vestígio que só
  retorna `null` é o diff mínimo e mais seguro.

## Timeout de teste isolado não é necessariamente regressão: reproduza sem paralelismo antes de investigar a fundo

Ao rodar vários spec files juntos (`yarn vitest run <arquivo1> <arquivo2>
...`), é comum ver 1-3 testes falharem com `Test timed out in 5000ms` mesmo
sem relação lógica com a mudança feita — é contenção de recursos entre
workers paralelos do Vitest, não regressão do seu código. Outro sinal do
mesmo tipo de falso positivo, mas com assinatura diferente: erro
`Unable to perform pointer interaction as the element has
'pointer-events: none'` vindo de `@testing-library/user-event` num teste que
não tem relação com o arquivo que você mudou (ex. um teste de fechar banner
de erro falhando durante a remoção de uma flag em outro componente
completamente distinto). Ambos são flakiness de CI sob carga, não bug real.

- Antes de tratar como bug real, reisole os arquivos que falharam e rode de
  novo com `--no-file-parallelism` (ou apenas os 1-2 arquivos que falharam,
  sozinhos). Se passarem limpo nesse modo, é flakiness de paralelismo — não
  investigue mais a fundo nem reverta a mudança por causa disso.
- Só trate como regressão real se a falha persistir isolada/sem paralelismo,
  ou se a mensagem de erro for de asserção (valor incorreto) e não de
  timeout/`pointer-events`/console-warning genérico.
- Se a falha aconteceu no CI (não localmente) e o shard seguinte foi
  cancelado por `--bail=1`, rode o arquivo isolado localmente (ou num
  worktree fresh a partir do commit do PR) para confirmar antes de gastar
  tempo investigando a fundo. Se passar, dispare `gh run rerun <run-id>
  --failed` em vez de reescrever código — reexecuta só os jobs que
  falharam, sem novo push.

## Removendo uma flag: workspace pode ter trabalho não commitado de OUTRA flag em andamento

Quando várias remoções de flag rodam em sequência/paralelo no mesmo working
directory persistente (não um clone novo por task), é possível herdar índice
git (staged) e/ou working tree sujos de uma tarefa anterior/irmã que ainda não
commitou. Sintoma: depois de editar só o que você pediu, `git status --short`
mostra arquivos que você nunca tocou (ex. `MM flags.ts`, ou specs em outra
pasta completamente sem relação com sua flag).

- **Sempre confira `git status --short` logo depois do `git checkout -b` e de
  novo antes de commitar.** Se aparecer arquivo fora do escopo da sua flag,
  pare antes de commitar.
- Diagnóstico: `git diff --cached -- <arquivo>` (HEAD vs índice) separado de
  `git diff -- <arquivo>` (índice/HEAD vs working tree). Se `--cached` já
  mostra remoção de uma constante que não é a sua, tem trabalho de outra
  tarefa staged nesse índice.
- Correção sem perder o trabalho alheio: `git reset` (desfaz apenas o stage,
  não toca no working tree) e depois **restaure no seu arquivo qualquer
  linha/constante que não seja da sua flag** de volta ao estado de HEAD
  (`git show HEAD:<arquivo>` para conferir o que deveria estar lá). Isso
  isola seu diff sem descartar o progresso de quem está mexendo na outra flag
  — a decisão de commitar/descartar aquilo é do dono daquela tarefa, não sua.
- Antes do commit final, rode `git diff -- <cada arquivo que você vai
  commitar>` e confirme que cada hunk corresponde só à sua flag. `git add`
  arquivo por arquivo (não `git add -A`) quando o workspace estiver
  potencialmente contaminado.

### Pior caso: a tarefa irmã troca de branch no meio da sua execução

O cenário acima assume que o branch não muda sob seus pés — mas quando duas
tarefas de remoção de flag rodam em paralelo no MESMO working directory
persistente (não worktrees separados), a tarefa irmã pode rodar `git
checkout -b <branch-dela>` entre duas das suas chamadas de ferramenta. Sintomas
que você só percebe DEPOIS de commitar:

- `git commit` reporta sucesso, mas `git log --oneline -3` mostra seu commit
  no topo de um branch com nome que você nunca criou (o branch da tarefa
  irmã). `git branch --show-current` confirma que você não está mais no seu
  branch — mesmo que seu branch (`git branch -a`) ainda exista, intacto.
- Um arquivo que você editou (ex. `flags.ts`) já tinha sido resetado para
  HEAD e reescrito pela tarefa irmã antes do seu `git add` rodar — sua
  remoção de constante "desapareceu" do arquivo e a remoção deles apareceu
  no lugar, mesmo sem você ter feito `git checkout`/`git reset` nele. Sinal:
  `git diff` de um arquivo que você editou não mostra sua mudança esperada
  antes de você commitar.

**Recuperação sem perder trabalho de ninguém** (testado e funcionou):
1. `git log --oneline -3` e `git branch --show-current` para confirmar em
   qual branch seu commit realmente foi parar.
2. `git reset --soft HEAD~1` nesse branch (o da tarefa irmã) — desfaz só o
   commit, mantém os arquivos como estavam staged, sem tocar no que não foi
   commitado.
3. Restaure cada arquivo seu (`git restore --staged <arquivo>` +
   `git checkout -- <arquivo>`) para o estado que a tarefa irmã esperava —
   se for um arquivo que só você tocou (ex. o componente da sua flag),
   `git checkout -- <arquivo>` basta. Se for um arquivo compartilhado (ex.
   `flags.ts`, onde as duas tarefas removem constantes diferentes),
   `checkout --` reverteria também a remoção deles — em vez disso,
   reescreva o arquivo inteiro via `write_file` com APENAS a remoção deles
   presente (a constante da tarefa irmã fora, a sua de volta), replicando o
   estado que existia antes da sua interferência.
4. Confirme com `git diff -- <arquivo>` que o branch da tarefa irmã voltou a
   ter só a mudança dela, e `git status --short` que nenhum arquivo seu
   restou modificado ali.
5. Para aplicar seu trabalho no SEU branch sem repetir a edição manualmente:
   `git worktree add /tmp/<nome> <seu-branch>` (cria uma working tree
   isolada, sem interferência da tarefa irmã) e `git cherry-pick <hash do
   commit que você tinha feito antes do reset>` dentro dela. Isso preserva
   sua mensagem de commit e diff exatos sem precisar reconstruir os patches.
6. Lição geral: quando há qualquer sinal de que outra tarefa está ativa no
   mesmo working directory (arquivos modificados fora do seu escopo — ver
   seção anterior), prefira criar sua PRÓPRIA `git worktree` logo no início
   da tarefa (`git worktree add /tmp/<nome> -b <seu-branch>`) em vez de
   `git checkout -b` no diretório compartilhado. Custa um `yarn install` ou
   os symlinks de `node_modules`/`styled-system` (ver seção de worktree mais
   abaixo), mas elimina de vez o risco de branch-switch e reset alheios
   afetarem seu commit.

## `patch` reporta sucesso com diff mas a mudança não persiste: cuidado com texto duplicado no arquivo

Em specs com blocos `it(...)` de nome literalmente duplicado (ex. duas
ocorrências de `it('does not render filter option overdue when user has no
access', ...)` no mesmo arquivo) é possível a ferramenta `patch` retornar
`success: true` com um `diff` que parece correto, mas o conteúdo real gravado
em disco não refletir a mudança pretendida — ou refletir só parte dela.
Sintoma: minutos depois, um `grep`/`search_files` pela string que você
"removeu" ainda a encontra no arquivo, mesmo sem nenhuma tarefa irmã ativa
naquele working directory (ou seja, não é o cenário de contaminação
cross-task descrito acima — é a própria ferramenta de patch não persistindo
o hunk certo quando o texto-alvo não é único no arquivo).

- **Nunca confie apenas no `diff` retornado por `patch` como prova de que a
  mudança foi aplicada**, especialmente em arquivos com blocos de teste
  repetidos/nome duplicado ou quando o `old_string` aparece em mais de um
  lugar do arquivo. Depois de uma leva de patches num arquivo assim, rode um
  `grep`/`search_files` de confirmação pelo texto removido antes de seguir
  para o próximo arquivo — não espere até o commit final para descobrir.
- Ao final da tarefa (antes do commit), sempre rode a busca pela
  constante/string-alvo no diretório inteiro de novo — não assuma que
  patches individuais "confirmados" ao longo do caminho continuam válidos.
- Se encontrar um arquivo que reverteu, não tente mais um `patch`
  incremental no mesmo trecho ambíguo — reescreva o arquivo inteiro via
  `write_file` (leia o arquivo completo primeiro) para eliminar qualquer
  ambiguidade de matching. Isso resolveu de forma confiável quando `patch`
  incremental tinha falhado silenciosamente no mesmo arquivo.
- Depois de remover um import que só existia para setar comportamento
  agora sempre-on (ex. `enableFlags` de `test-utils`, ou a constante da
  flag), rode `yarn eslint --max-warnings=0 <arquivos tocados>` antes de
  considerar pronto — o import passa a ficar sem uso
  (`@typescript-eslint/no-unused-vars`) e isso derruba o job de lint do CI
  mesmo com todos os testes passando. `eslint --fix` corrige a formatação
  resultante (ex. quebra de linha de import multi-linha que virou
  single-linha) mas não remove sozinho o import não usado.

## Editar spec com `describe`/`it` aninhados: patch por old_string/new_string quebra brace-matching

Remover um nível de `describe` (ex. o wrapper `describe('when feature flag is
enabled')`) via `patch(old_string, new_string)` é arriscado quando o bloco tem
vários níveis de aninhamento — é fácil remover a abertura de um `describe` e
esquecer de remover o `});` de fechamento correspondente (ou vice-versa),
gerando um arquivo com chaves desbalanceadas que o LSP só aponta como erro
genérico de sintaxe várias linhas depois do problema real.

- Para remoção de um nível de aninhamento em arquivo de teste, é mais seguro
  puxar a versão original do arquivo (`git show origin/main:<path> >
  /tmp/original.tsx`), ler o arquivo inteiro, e reescrever o arquivo inteiro
  via `write_file` já com a indentação e chaves corretas — em vez de várias
  chamadas incrementais de `patch` tentando acertar chave por chave.
- Sinal de que você entrou nesse buraco: diagnósticos de LSP tipo
  "Declaration or statement expected" ou "Cannot find name X" em múltiplas
  linhas após um `patch` que parecia inofensivo — pare, não tente mais um
  patch incremental, reescreva o arquivo do zero a partir do original.

## Comandos longos via `terminal(background=true)` (suite completa, `gh pr checks --watch`): node errado + ruído de zsh

Ao rodar a suíte inteira (`CI=true yarn vitest run --bail=1`, ~5-6 min) ou
`gh pr checks <n> --watch`, o comando estoura o timeout de foreground (600s
não é problema, mas o call foreground do orquestrador tem seu próprio limite
de ~60s por resposta) — o padrão certo é `terminal(background=true,
notify_on_complete=true)` seguido de `process(action='wait', timeout=60)` em
loop até `status: exited`.

- **Toda invocação em background imprime ruído de inicialização do zsh no
  campo `output`** (`stty: stdin isn't a terminal`, `Usage: prompt
  <options>...`, `(eval):1: can't change option: zle`) — isso vem do tema/
  plugin do shell interativo tentando rodar em um shell não-interativo, **não
  é falha do comando**. Ignore esse texto e cheque o `exit_code` e o arquivo
  de log redirecionado (`> /tmp/algo.log 2>&1`) para saber o resultado real.
- **`nvm` não é herdado em `background=true`** mesmo que uma chamada
  `terminal()` anterior em foreground já tenha rodado `nvm use
  20.19.2` — o processo em background sobe um shell novo sem o `PATH`
  ajustado, e cai no Node do sistema (mais antigo). Sintoma característico:
  `yarn vitest` falha na inicialização com `SyntaxError: The requested module
  'node:fs/promises' does not provide an export named 'constants'` (erro de
  ESM do Vite, não relacionado ao código da flag). Correção: prefixar o
  próprio comando com `export PATH="/Users/<user>/.nvm/versions/node/<versão
  do .nvmrc>/bin:$PATH" &&` dentro do `command` do `terminal(background=true,
  ...)` — não basta ter feito `nvm use` numa chamada foreground anterior.
  **Cuidado com o `v` no nome do diretório**: os diretórios de versão do nvm
  usam o formato `v20.19.2`, não `20.19.2` (`~/.nvm/versions/node/v20.19.2/bin`).
  Um PATH montado sem o `v` (ex. copiando o valor do `.nvmrc`, que normalmente
  não tem o prefixo) não dá erro de "diretório inexistente" — o `export` roda
  silenciosamente, simplesmente não bate com nada, e o shell cai de volta no
  Node do sistema, reproduzindo o mesmo erro de ESM acima como se o PATH nunca
  tivesse sido setado. Confirme o nome exato com `ls ~/.nvm/versions/node/`
  antes de montar a string, em vez de assumir o formato a partir do `.nvmrc`.
- Não encadeie seu próprio `&` de background dentro do `command` de um
  `terminal(background=true, ...)` (ex. `export PATH=... && yarn vitest ... &
  \necho started $!`). A ferramenta já roda o `command` em background — abrir
  um segundo nível de backgrounding com `&` faz a chamada retornar sucesso
  imediatamente (só ecoa o PID do subshell), mas não há garantia de que o
  `export PATH=...` da mesma linha tenha propagado para o processo real do
  `yarn vitest` antes dele ser forkado. Resultado: o comando "termina" rápido
  sem erro visível, e só ao ler o arquivo de log é que aparece o mesmo erro de
  ESM do node errado — mascarando por mais tempo a causa raiz. Passe o comando
  de teste direto como `command` (sem `&` nem `echo started $!`) e deixe
  `background=true` cuidar de tudo.
- `process(action='wait', timeout=60)` frequentemente retorna
  `status: timeout` mesmo com o processo saudável e progredindo — é só o
  clamp de 60s do wait, não sinal de travamento. Chame de novo com o mesmo
  `session_id` até ver `status: exited`; só then leia o log completo com
  `read_file` (a suíte inteira gera arquivo de log grande, use `offset`
  próximo do fim para pegar o resumo `Test Files ... / Tests ...`).

## Worktree novo: symlinkar `node_modules` e `src/styled-system` do clone principal

Um `git worktree add` cria uma working tree limpa sem `node_modules` nem os
artefatos gerados (`src/styled-system` do Panda CSS). Rodar `yarn install`
do zero nesses casos custa vários minutos por worktree — desnecessário se já
existe um clone principal instalado e íntegro ao lado:

```bash
ln -s /caminho/do/clone-principal/node_modules node_modules
ln -s /caminho/do/clone-principal/src/styled-system src/styled-system
```

Isso deixa `yarn vitest`, `yarn eslint`, `yarn types` e `yarn build` prontos
para rodar no worktree imediatamente. Só rode `yarn install` de verdade no
worktree se o `package.json`/lockfile do branch divergir do clone principal
(dependência nova, versão bumped).

## Worktree novo: colisão de nome de branch se você já rodou `git checkout -b` no clone compartilhado

Se você já fez `git checkout -b <nome-da-flag>` no clone/working directory
compartilhado ANTES de perceber a contaminação (ver seções acima), não dá pra
criar o worktree isolado com esse mesmo nome de branch — `git worktree add`
falha com `fatal: '<nome-da-flag>' is already checked out at '<clone
principal>'` (git não permite o mesmo branch checked out em dois worktrees
simultaneamente).

- Não perca tempo tentando trocar o branch do clone principal para liberar o
  nome — isso mexe no HEAD que a tarefa irmã pode estar usando/observando.
- Crie o worktree com um nome de branch temporário qualquer a partir de
  `origin/main` (`git worktree add <path> -b wt-<algo-descritivo>
  origin/main`), faça todo o trabalho e o commit lá dentro normalmente.
- Na hora de publicar, não precisa renomear o branch local — dá pra empurrar
  direto para o nome de branch remoto correto: `git push origin
  wt-<algo-descritivo>:<nome-da-flag-correto>`. Isso cria/atualiza
  `origin/<nome-da-flag-correto>` sem exigir que o nome local bata com o
  remoto, e evita qualquer conflito de "já checked out" do início ao fim.
- O branch órfão criado sem querer no clone principal (`<nome-da-flag>`, sem
  commits) pode ficar ali sem problema — é só um ponteiro extra; delete depois
  com `git branch -d <nome-da-flag>` quando o clone principal não estiver mais
  em uso por ninguém, sem pressa.

## Diagnóstico rápido: `git worktree list` antes de investigar diffs inesperados

Ao entrar num repo compartilhado (`clinical-panel` no path canônico, não um
worktree seu) e ver qualquer sinal de contaminação — arquivo modificado que
você não tocou, `git status` sujo antes de você editar nada — rode `git
worktree list` **primeiro**, antes de tentar `git diff`/`git log` para
reconstruir o que aconteceu. Ele responde duas perguntas de uma vez:

- Se o checkout compartilhado aparece na lista já em um branch
  `chore/remove-flag-*` (ou qualquer nome de tarefa que não é a sua), isso
  sozinho já confirma que outra tarefa está rodando ali — não precisa
  aguardar o warning do `patch` ou um `git status` sujo para saber; o simples
  fato de o branch atual não ser `main`/o seu já é o sinal.
- Se já existem outros worktrees (`/Users/.../worktrees/clinical-panel-<algo>`)
  ao lado do checkout principal, isso confirma que o padrão da tarefa (várias
  remoções de flag em paralelo, uma por subagente) já está em andamento com
  outras instâncias usando exatamente a técnica de isolamento recomendada
  abaixo — reforça que a resposta certa é replicar o mesmo padrão (seu
  próprio `git worktree add ... origin/main`), não tentar "consertar" o
  checkout compartilhado.

## Detectar contaminação de sibling task ANTES de commitar: warning do próprio `patch`

A ferramenta `patch` retorna um campo `_warning` quando o arquivo que você
acabou de escrever foi modificado por outro subagente (`sibling subagent`)
depois da sua última leitura. Trate esse warning como sinal de alarme
imediato, não como ruído — ele geralmente aparece ANTES de você perceber
qualquer outro sintoma (branch trocado, `git status` sujo). Ao vê-lo:

1. Releia o arquivo na hora para ver o que realmente ficou gravado.
2. Rode `git branch --show-current` e `git status --short` imediatamente —
   é comum esse warning coincidir com o cenário "pior caso" (tarefa irmã
   trocou de branch sob seus pés, ver seção acima) mesmo sem você ainda
   ter commitado nada.
3. Se confirmar que o branch mudou e você ainda não commitou, não tente só
   "continuar de onde parou" — descarte suas edições diretas no diretório
   compartilhado (`git checkout -- <seus arquivos exclusivos>`, reconstrua
   manualmente a linha que é sua em arquivos compartilhados como
   `flags.ts`) e migre o resto do trabalho para uma `git worktree` isolada
   a partir de `origin/<branch base>` antes de continuar. Reaplicar os
   mesmos `patch`/`write_file` que você já tinha montado é rápido — não
   precisa reconstruir o diff do zero, só repetir as chamadas apontando
   para os caminhos do worktree.

## `gh pr checks <N>`: exit code 8 enquanto pending não é falha

`gh pr checks` retorna exit code 8 sempre que pelo menos um check ainda não
está `pass` (inclui `pending`/`running`). Ao fazer polling manual (`sleep N &&
gh pr checks <N>`, sem `--watch`, por instrução do usuário ou por preferir
controlar a cadência você mesmo), não trate esse exit code como erro de
ferramenta — leia a coluna de status impressa (`pending`/`pass`/`fail`) linha
a linha para decidir se continua esperando. Só pare o loop quando toda linha
mostrar `pass`, ou quando aparecer `fail` de verdade.

## `mergeStateStatus=BLOCKED` não é sinônimo de conflito — confirme antes de tratar como tal

O campo `mergeStateStatus` do GitHub tem valor `BLOCKED` para várias causas
diferentes (falta de aprovação de review, CI ainda rodando, conflito de
merge) — não assuma "conflito" só porque veio `BLOCKED`. Sempre cruze com:

- `mergeable` (`gh pr view <N> --json mergeable`): só é conflito de fato se
  vier `CONFLICTING`. Se vier `MERGEABLE`, o `BLOCKED` é por outro motivo
  (tipicamente falta de review approval ou CI pendente).
- `gh pr checks <N>`: confirma se o bloqueio é CI ainda rodando/falhando.
- `reviewDecision` (`gh pr view <N> --json reviewDecision`): `REVIEW_REQUIRED`
  sem nenhuma aprovação ainda é a causa mais comum de `BLOCKED` com
  `mergeable=MERGEABLE` e CI 100% verde.

## Merge recusado por branch protection mesmo com CI verde e `mergeable=MERGEABLE`

`gh pr merge <N> --squash --delete-branch` pode falhar com **"the base
branch policy prohibits the merge"** mesmo quando CI está 100% verde,
`mergeable=MERGEABLE` e não há comentário pendente do Gemini — a causa
típica é branch protection exigindo aprovação de review humana
(`reviewDecision=REVIEW_REQUIRED`) que ainda não aconteceu, mesmo que o
reviewer/time já tenha sido solicitado.

- **Não use `--admin` para contornar.** Isso bypassa a política do repo
  deliberadamente — é uma decisão de escopo do usuário/dono do repo, não
  algo para o agente decidir sozinho.
- **Não use `--auto`** a menos que o usuário peça explicitamente — habilita
  merge automático assim que os requisitos forem satisfeitos, o que pode
  mergear sem revisão humana ter realmente visto o diff final se a aprovação
  vier de forma automatizada/desatenta.
- Reporte esse PR como "pronto, aguardando aprovação de review" (não
  "aguardando CI" nem "conflito") no resumo final e no README de
  acompanhamento — é uma categoria de status distinta que precisa entrar na
  tabela de status por grupo (ver seção "Sincronizando Jira" abaixo: isso
  também significa que a subtask correspondente **não** deve ir para Done).

## Comentário do Gemini já resolvido em execução anterior: confirme pelo padrão de thread, não só pela ausência de novo comentário

Ao checar `gh api repos/<org>/<repo>/pulls/<N>/comments`, um comentário do
`gemini-code-assist[bot]` só está de fato resolvido quando a thread mostra 3
elos: (1) comentário original do bot, (2) reply do humano/agente linkando o
commit da correção (ex. `@gemini-code-assist Obrigado! Corrigido em <hash>`),
e (3) reply de reconhecimento do próprio bot. Se qualquer um dos três estiver
faltando, trate como pendência ainda aberta — não assuma resolvido só porque
não há comentário novo desde a última checagem. Filtre por
`in_reply_to_id`/`user.login` para reconstruir a cadeia completa antes de
decidir se precisa agir.

## Removendo uma flag: prop resultante `sempre true` não precisa virar remoção de prop se isso vazar para fora do escopo

Quando remover a flag deixa um componente filho recebendo sempre o mesmo
valor de prop (ex. `<ParentalTrainingForm showInputGoals={showInputGoals} />`
vira sempre `true`), o instinto é "simplificar" removendo a prop do
componente filho também. **Só faça isso se o componente filho e seu teste
dedicado não exigirem edição fora do escopo pedido.** Se o componente
filho tem teste próprio cobrindo os dois valores da prop (`true`/`false`)
e não há evidência de que o valor `false` nunca mais será necessário,
prefira apenas hardcodar `true` na chamada (`<ParentalTrainingForm
showInputGoals />`) e deixar o componente filho genérico como estava — menor
diff, menor risco, e não força um redesenho de API que não foi pedido.

## Removendo uma flag: `extraValidation` (ou prop opcional similar) que vira sempre `true` — delete a chave, não hardcode o valor

Quando a flag controla um campo opcional dentro de um objeto de configuração
(ex. `extraValidation?: boolean` num array de itens de menu, como em
`getMenuItemsOptions`), e o comportamento final é "sempre visível/ativo", a
correção mais limpa **não é** trocar `extraValidation: flagEnabled` por
`extraValidation: true` — é remover a linha inteira. Um campo opcional
ausente já produz o comportamento "sempre ativo" que o código consumidor
espera (ex. `isAuthorizedComponent(name, undefined)` trata `undefined` da
mesma forma que a ausência de restrição extra). É o mesmo princípio da seção
"prop resultante sempre true não precisa virar remoção de prop" abaixo, mas
aplicado ao lado oposto: aqui a chave/prop pertence ao PRÓPRIO objeto que
carregava a flag (não a um componente filho reaproveitável fora do escopo),
então o diff mínimo é apagar a chave — não fixá-la em `true`. Lembre de
remover também o parâmetro correspondente na função que monta o objeto
(campo do tipo, destructuring, e qualquer prop repassada de um componente
pai que só existia para carregar esse valor) — não só a linha do valor.

## Falso positivo de suíte completa: `ENOSPC: no space left on device`

Além de timeout/`pointer-events: none` sob paralelismo (ver seção abaixo),
`yarn vitest run` completo pode falhar em arquivos aleatórios sem relação com
a mudança feita com `Error: ENOSPC: no space left on device` ao importar
assets (`.svg?react`, `.module.css`) — isso é o disco da máquina host cheio
(confirme com `df -h /tmp` ou `df -h /` mostrando `Capacity` perto de 100%),
não um bug introduzido pela remoção da flag. Mesmo protocolo dos outros
falsos positivos dessa suíte: confirme que os arquivos que falharam não têm
relação com o que você mudou, rode-os isolados se restar dúvida, e não trate
isso como sinal para investigar mais a fundo nem para reverter a mudança —
é ambiente, não regressão. Não tente "corrigir" o disco cheio por conta
própria (é fora do escopo da tarefa de remover uma flag); apenas registre no
PR/relatório os nomes dos arquivos com falha pré-existente de ambiente e
siga em frente.

## Testes que cobriam o ramo "flag off": consolide, não apenas delete

Ao tornar o comportamento sempre-on, specs que existiam para comparar
"flag on" vs "flag off" (dois `describe`s irmãos, um mockando a flag ligada)
devem ser fundidos em um único cenário que reflete o comportamento final —
inclusive `it.skip` marcados como TODO de migração, que também merecem ter
os dados de teste atualizados para o novo ramo único (mesmo pulados, ficam
como referência futura e não devem continuar testando um ramo morto).

## `eslint --fix` corrige prettier mas não remove imports não usados: rode `yarn lint --max-warnings=0` completo antes de dar push

`eslint --fix <arquivo>` corrige violações de `prettier/prettier`
automaticamente, mas **não remove** um import que ficou sem uso depois de
uma edição (`@typescript-eslint/no-unused-vars` é só reportado, não
autofixável). O CI deste repo roda `yarn lint --max-warnings=0` — ou seja,
um warning de import não usado falha o build tanto quanto um erro. Padrão
recorrente ao remover flags: vários spec files copiados do mesmo template
importam `waitFor` de `test-utils` mas só usam `render`/`screen` depois que
a lógica condicional (que dependia da flag) é removida — o CI acusa 6+
warnings desse tipo espalhados em specs "irmãos" que nem pareciam
relacionados à mudança.

- Depois de qualquer `eslint --fix` em arquivos específicos, rode o comando
  de lint **exatamente como o CI roda** (`yarn lint --max-warnings=0`, sem
  escopo de arquivo) antes de considerar o PR pronto — não confie em
  "rodei --fix nos arquivos que toquei" como suficiente (ver Pattern 21 na
  skill `multi-agent-orchestration`).
- Se o CI falhar só no job de lint (testes passando), é sinal de que faltou
  esse passo — reproduza localmente antes de reabrir investigação mais
  ampla: `yarn eslint --fix src` (escopo completo) resolve os erros de
  prettier; os warnings de import remanescentes precisam de remoção manual
  da linha de import.


## `patch`/`write_file` auto-lint em arquivo `.ts`/`.tsx`: ruído de `node_modules` não é regressão sua

Depois de editar um arquivo `.ts`/`.tsx` com a ferramenta `patch`, o autolint
que ela roda pode disparar um `tsc` avulso (sem o `tsconfig.json`/flags do
projeto, ex. sem `skipLibCheck`) e devolver **centenas de erros** vindos de
`node_modules` (`@types/react-dom`, `@types/react-native`,
`ts-toolbelt`, `dom-view-transitions` — duplicidade de identificadores,
"Type instantiation is excessively deep", etc.). Isso é ruído estrutural do
monorepo de `@types` conflitantes, não uma regressão introduzida pelo seu
edit — o próprio retorno da ferramenta já rotula isso como "Pre-existing
lint errors" quando reconhece o padrão, mas quando o `tsc` avulso trava antes
disso, você só vê o despejo bruto.

- Nunca conclua "meu patch quebrou o build de types" só pelo output do
  autolint do `patch`. Rode o script de typecheck real do projeto
  (`yarn types`, que executa `tsc --noEmit` com o `tsconfig.json` do repo) —
  se ele voltar limpo, os erros do autolint eram ruído e podem ser ignorados.
- O mesmo vale para `eslint`: confirme com `yarn lint` (ou `yarn eslint src
  --ext .js,.jsx,.ts,.tsx`, o comando que o CI roda) em vez de confiar só no
  lint parcial que o `patch`/`write_file` reporta arquivo a arquivo.
- Ordem de verificação recomendada ao final de uma remoção de flag: (1)
  `yarn vitest run <specs afetados>` → depois suíte completa se o escopo for
  amplo, (2) `yarn lint` completo, (3) `yarn types` completo. Só depois desses
  três abrir o PR — o autolint incidental do `patch` não substitui nenhum
  deles.

## Sincronizando Jira (subtasks por flag) com o estado real dos PRs

Quando o card Jira pai tem 1 subtask por flag/unidade (ex. "Remover feature
flags do Painel Clínico" com 20 subtasks), trate o Jira e os PRs como duas
fontes que precisam ser reconciliadas ativamente, não apenas espelhadas uma
vez:

- **Detecção indireta de merge**: se você fez `git fetch origin` e uma
  branch remota que você sabia que existia (`chore/remove-flag-x`)
  desapareceu da lista, é sinal forte de que o PR correspondente foi
  mergeado (squash-merge deleta a branch) — confirme com `gh pr view <N>
  --json state,mergedAt` e já aproveite para mover a subtask para Done,
  mesmo que ninguém tenha avisado explicitamente.
- **Não deduza "Review" a partir de CI verde.** CI verde + comentários do
  bot resolvidos = pronto para o usuário decidir mandar para revisão — não
  é o mesmo que "já em revisão". Só mova a subtask para Review quando o
  usuário confirmar que mandou manualmente (ver skill
  `multi-agent-orchestration`, seção "Status-tier semantics").
- **Divisão de relatório vs divisão real do tracker**: se o usuário pedir
  para subdividir um grupo catch-all só para acompanhamento próprio ("chama
  de Outros 1 e Outros 2, só no relatório, não mexe no Jira"), aplique a
  divisão apenas no doc interno (README/progresso) — o Jira mantém o
  agrupamento original por summary. Deixe isso explícito no doc para não
  confundir uma futura sessão que só olhar o tracker.

Para debugar dados no Core (não rodar testes), rode um script via `rails runner` no container:

1. Escreva o script num arquivo no root do repo (montado em `/app` no container) — evita problema de quoting do shell com scripts multi-linha.
2. Rode: `docker compose exec -T -e DISABLE_SPRING=1 app bundle exec rails runner /app/script.rb`
3. Modelos multi-tenant (`ApplicationRecordTenant`) lançam `ActsAsTenant::Errors::NoTenantSet` se consultados sem tenant. Para achar um registro e descobrir o `tenant_id`: `ActsAsTenant.without_tenant { Model.find_by(id: "...") }`.
4. Depois consulte associações dentro do tenant: `ActsAsTenant.with_tenant(tenant) { ... }`.
5. Associações comuns são `has_one` (singular): `ClinicalCase#child`, `ClinicalCase#pei_track` — não `children`/`pei_tracks` (plural).
6. Métodos de decorator (ex.: `ChildDecorator#calculated_official_scheduled_hours_by_discipline`) não existem no model — use o equivalente do model (`Child#scheduled_hours_by_discipline(status: :official)`).
7. Apague o script temporário (`rm`) após o debug para não deixar arquivo órfão no repo.
