---
name: remove-feature-flag
description: Use when removing a feature flag, fixing it always-on/off.
version: 1.0.0
metadata:
  hermes:
    tags: [feature-flag, refactor, cleanup, clinical-panel]
    related_skills: [pr-open, implement-feature-hermes]
---

# Remove Feature Flag

Remove uma feature flag do código, fixando o comportamento no branch que rodava com a flag **ligada** (ou desligada, quando pedido), e abre PR seguindo as convenções do time.

Tarefa recorrente nos repos GenialCare (`clinical-panel` etc.) — o git log costuma ter vários commits `chore: remove <FLAG> feature flag`.

## Workflow

### 0. Setup do worktree

1. `git fetch origin`
2. `git worktree add ../worktrees/<repo>-<slug> -b chore/remove-flag-<slug> origin/main`
3. Symlink de dependências para não reinstalar:
   - `ln -s <repo>/node_modules node_modules`
   - `ln -s <repo>/src/styled-system src/styled-system` (repos com panda CSS)

### 1. Localizar todas as referências

Grep por TODAS as formas do nome — a constante UPPER_SNAKE e o valor/camelCase:

```
PLANNING_BY_CLINICAL_CASE_PAGE | planning_by_clinical_case_page | planningByClinicalCaseEnabled
```

As referências aparecem em: `constants/flags.ts`, componentes que chamam `useFeatureFlag`, funções utilitárias, e specs.

### 2. Fixar comportamento no branch "ligada"

Para cada ponto de uso: **mantenha o branch que roda com a flag LIGADA, remova o check e o branch desligada**.

Padrão comum — flag usada em boolean expression de `extraValidation` (ou similar), não em `if/else`:

```ts
// ANTES (dois itens mutuamente exclusivos controlados pela flag)
{ extraValidation: !isClinicalCaseOwner && !planningByClinicalCaseEnabled }  // branch OFF
{ extraValidation: !isClinicalCaseOwner && planningByClinicalCaseEnabled }   // branch ON

// DEPOIS (flag sempre on)
{ extraValidation: !isClinicalCaseOwner }   // só resta o branch ON
// o item gated por `!flag` vira código morto → REMOVER o item inteiro
```

Regra de ouro: `x && flag` → `x`; `x && !flag` → `false` (item morto, remova). A rota subjacente pode continuar existindo em `Routes.tsx` — **não toque em rotas**, apenas no menu/lógica que a flag controlava.

**Padrão `enabled` prop repassado para hooks internos**: às vezes a flag não vira `if/else` nem boolean expression — ela é lida com `useFeatureFlag(...)` no componente e o boolean é repassado como prop `enabled` para um ou mais hooks internos (ex. `useOfferDrawerState`, `useAvailableHoursOffersData`) que fazem `if (!enabled) return;` em `useEffect` e `skip: !enabled` em queries Apollo. Nesse caso o check do flag está DENTRO do hook, não no componente. O cleanup correto não é hardcodar `enabled: true` — é **remover o parâmetro `enabled` por completo** do hook (tipo + destructuring + todos os guards + deps arrays + `skip`), já que ele passa a ser sempre `true` e vira código morto. Antes de mexer, confirme com grep que o hook só é usado por aquele componente (`useOfferDrawerState|useAvailableHoursOffersData` → só o componente); se for compartilhado, remova só o check no componente e mantenha o parâmetro no hook. No componente: remova `useFeatureFlag`, o import, as props `enabled: ...` e o early-return `if (!enabled) return null;` se houver. Rode `yarn types` após cada batch de edição — os diagnósticos LSP intermediários ("Cannot find name 'enabled'") somem conforme os guards são removidos.

### 3. Limpar código

- `constants/flags.ts`: remover a constante.
- Componente: remover a chamada `useFeatureFlag(...)` e o import órfão da constante (mantenha outros imports de flags que continuam em uso).

### 4. Limpar testes

- Remover o parâmetro do flag do `setup()` e a linha correspondente no `mockImplementation`.
- Remover `describe`/`it` do comportamento "flag off" (ex: `session-planning-link`).
- Simplificar `setup({ planningByClinicalCaseEnabled: true })` → `setup()` (agora é o default).
- Se os casos "flag on" estiverem aninhados em `describe('when FLAG is enabled', () => { beforeEach(() => enableFlags([FLAG])) })`: remova o `describe` wrapper + `beforeEach` e PROMOVA os `describe`/`it` internos ao escopo pai, dedentando 2 espaços. Senão sobra referência à constante e o import quebra. Para re-indentar um bloco grande com segurança, use um script que localize os marcadores por conteúdo (ex: a linha `describe('...')` interna e o `});` de fechamento) e aplique `dedent` de 2 espaços no intervalo — não edite linha a linha à mão.
- Renomeie nomes de teste que mencionam a flag (ex: `'... when feature flag is enabled'` → `'...'`) — mas NÃO toque em `describe`/`it` de OUTRAS flags que coexistem no mesmo arquivo.
- **Testes "flag off" que NÃO citam o nome da flag**: quando a flag alterna entre dois comportamentos de UI diferentes (ex. modal `showModal(...)` vs. `window.open(...)` em nova aba), os testes do branch "off" assertam o comportamento antigo (o toast "aberto em nova aba", o `expect(spyWindowOpen).toHaveBeenCalledWith(...)`) SEM mencionar a constante. O `grep` pela flag retorna 0 e você pode achar que acabou, mas esses specs quebram no CI. Encontre-os grepando pelo COMPORTAMENTO, não pelo nome: o texto do toast do branch off, `window.open`/`spyOpen`, ou o `query` da mutation de embed. Converta esses testes para assertar o branch "on" (ex. `await screen.findByTestId('signature-iframe')`), mantendo o mock da mutation (agora consumida pelo componente modal).

### 5. Validar (nesta ordem)

```bash
grep -rn "FLAG_NAME\|flag_name\|camelCase" src   # deve retornar 0 matches
yarn lint --max-warnings=0
yarn types          # tsc --noEmit
yarn vitest run src/<caminho>/__tests__/<Spec>.spec.tsx
yarn build
```

### 6. Abrir PR via `pr-open` (NÃO `gh pr create`)

Seguir a skill `pr-open`: Draft, assignee `regishideki`, reviewer `GenialCare/capacidade-clinica`, descrição pt-BR (resumo de negócio, sem listar arquivos), e os 2 cron jobs (bots + CI).

Commit message: `chore: remove <FLAG_NAME> feature flag`.

## Mergeando um LOTE de PRs de remoção de flag (cron/babysitter)

Quando várias flags são removidas em paralelo (1 PR cada, todos target `main`
protegida), mergear vários PRs na mesma execução é um **efeito cascata**, não
uma operação independente por PR:

1. **Cada merge derruba TODOS os outros PRs abertos para BEHIND/CONFLICTING**,
   mesmo que estivessem `CLEAN`/`MERGEABLE` segundos antes — porque quase
   todos tocam o mesmo `constants/flags.ts` (uma linha por flag, adjacentes)
   e frequentemente o mesmo componente compartilhado (menu lateral, cards de
   dashboard) que lista múltiplas flags no mesmo arquivo.
2. Branch protection com "require branches to be up to date" faz
   `gh pr merge --squash` falhar com `the head branch is not up to date with
   the base branch` mesmo quando `mergeable=MERGEABLE` — o merge só é
   permitido depois de um novo `git merge origin/main` + push, o que dispara
   uma nova rodada de CI. **Não tente mergear vários PRs em sequência rápida
   sem re-checar `gh pr view <n> --json mergeable,mergeStateStatus` entre
   cada um** — trate como "mergear 1, então ressincronizar TODOS os
   worktrees restantes com origin/main antes do próximo merge", não como um
   loop `for n in $prs; do gh pr merge $n; done`.
3. **Resolução do conflito em `flags.ts` é sempre a mesma**: cada lado do
   `<<<<<<< HEAD / ======= / >>>>>>>` é a remoção de uma flag *diferente* —
   a resolução correta é **apagar as duas linhas inteiras** (nenhuma
   sobrevive), nunca escolher um lado. O mesmo padrão se repete em qualquer
   arquivo tocado por duas flags ao mesmo tempo (import de constante, hook
   `useFeatureFlag(...)`, prop passada adiante, chave em objeto de opções de
   menu): ambos os lados do conflito representam remoções válidas, deletar
   os dois blocos.
4. **Depois de resolver, procure órfãos que o merge automático deixou para
   trás** — o merge 3-way não sabe que um import ou parâmetro ficou sem uso
   só porque o conflito ao lado dele foi resolvido. Rode
   `yarn eslint --fix src` (todo o repo, não só o arquivo) — ele reordena
   imports mas não remove variáveis/parâmetros não usados de nível médio; em
   seguida `yarn lint --max-warnings=0` aponta exatamente o que sobrou
   (`'useFeatureFlag' is defined but never used`, `'enableFlags' is defined
   but never used`, `No value exists in scope for the shorthand property
   'xEnabled'`). Remova manualmente: import da constante/hook, o `const x =
   useFeatureFlag(...)` inteiro, a prop repassada (`x,` num objeto/params),
   e — se o hook ficou vazio de uso — o `const { email } = useUserData()`
   (ou similar) que só existia para alimentar aquele hook.
5. Depois de cada push de resincronização, rode `yarn lint --max-warnings=0`
   E os testes do(s) arquivo(s) tocado(s) (`yarn vitest run <spec>`) antes
   de considerar o PR pronto de novo — o merge pode ter reintroduzido um
   teste que assertava o comportamento antigo de uma flag já removida por
   outro PR.
6. CI de cada rodada de resync leva ~10-13min na prática (linters ~3min,
   cada shard de teste 9-12min em paralelo) — mais que o esperado, não
   ~5-8min. Espere pelo menos 6-7min antes do primeiro poll, confira
   `statusCheckRollup`/`gh pr checks <n>`, e só tente o merge de novo quando
   os 4 checks (`Run linters` + `Run tests (1..3, 3)`) estiverem `SUCCESS`.
7. **Um único PR pode precisar de 2-3+ rodadas seguidas** quando o lote tem
   4+ PRs sendo mergeados um atrás do outro: enquanto o CI da rodada de
   resync do PR A ainda roda (~10min), outro PR B do mesmo lote pode
   mergear e derrubar A para `BEHIND` de novo antes mesmo do merge de A ser
   tentado. Sintoma: `gh pr merge` retorna `the head branch is not up to
   date with the base branch` mesmo com CI 100% verde na tela — sempre
   refaça `git fetch origin` + `git merge-base --is-ancestor origin/main
   origin/<branch>` para confirmar antes de cada tentativa de merge, e
   repita o ciclo merge-lint-test-push quantas vezes for preciso até o PR
   ficar `CLEAN` no exato momento do `gh pr merge`. Isso é esperado, não um
   sinal de erro — só reflete quantos outros PRs do lote mergearam nesse
   meio-tempo.

## Pitfalls

- **Lint com `--max-warnings=0` + prettier**: o prettier quebra linhas longas; ao colapsar um `toHaveTextContent(...)` para uma linha, verifique se ele cabe — se caber numa linha, o prettier exige que fique numa linha (`Replace ⏎...⏎ with ...`). Rode `yarn lint` de novo após cada edição manual.
- **Falha na suíte completa não relacionada**: `test:ci` roda 1600+ testes e pode ter falha flaky em arquivo intocado. Re-execute o spec isolado (`yarn vitest run <spec>`) para confirmar; se passar, é pré-existente e não é da sua mudança. Reporte claramente em vez de tentar "consertar".
- **Symlink de `src/styled-system`**: sem ele o build/teste falha por falta do codegen do panda CSS. O `prepare` script (`panda codegen && panda cssgen`) não é necessário se o symlink apontar para o repo que já tem o output.
  - **Falha silenciosa do `ln -s` (nested symlink)**: se `src/styled-system` já existir como diretório real (gitignored, gerado por um `panda codegen`/`vitest` anterior no worktree), `ln -s <target> src/styled-system` cria um symlink ANINHADO (`src/styled-system/styled-system -> target`) em vez de substituir o diretório. Sintoma: centenas de erros `tsc "File .../styled-system/jsx/index.d.ts is not a module"` que o checkout principal NÃO tem. Confirme com `npx tsc --noEmit 2>&1 | grep -c "is not a module"` no checkout principal (deve ser 0). Fix: `rm -rf src/styled-system && ln -s <repo>/src/styled-system src/styled-system`, depois re-rodar `tsc --noEmit`.
- **`yarn types` é `tsc --noEmit`** — não existe script `typecheck` em alguns repos; confirme o nome no `package.json`.
- **Constante órfã sobrevive ao merge no `flags.ts` (resíduo de conflito)**: depois que o lote inteiro de PRs de remoção é mergeado, a **declaração da constante** pode continuar em `src/constants/flags.ts` na `main` mesmo que o PR "remove <FLAG>" tenha mergado — a resolução 3-way de conflito reintroduziu a linha (`export const <FLAG> = '...';`) enquanto o uso já foi apagado. O `grep -rn` do passo 5 roda contra o worktree no momento da edição, que fica atrás de `main` conforme outros PRs do lote mergam — então ele NÃO pega isso. **Verificação final obrigatória após o lote fechar**: `git show origin/main:src/constants/flags.ts` e compare as constantes restantes com a lista de excluídas (ex. só `OT_OCCUPATIONAL_PROTOCOL_ENABLED` deveria sobrar). Se uma constante inesperada persistir, confirme que é órfã com `git grep -n "<CONSTANT>" origin/main -- src | grep -v flags.ts` — se só retornar um comentário ("feature flag was removed; ... always active") e nada a referenciar em código, abra um PR pequeno de limpeza removendo a linha + o comentário obsoleto (mesmas convenções de assignee/reviewer). Não assuma que "0 referências no worktree = flag sumiu da main".
- **`findByTestId` estoura timeout quando o branch "on" abre modal via `await import()` + `showModal`**: o primeiro `import()` dinâmico de um componente pesado (ex. modal antd) dentro de um teste de integração dispara ~2s de transformação de módulo do vitest/vite. O `findByTestId` default tem timeout de 1000ms → falha falsa (`Unable to find an element by: [data-testid="..."]`), mesmo com o modal renderizando corretamente. Diagnóstico: o spec de hook correspondente (que chama `perform` direto, sem timeout) passa. Fix: `await screen.findByTestId('x', {}, { timeout: 10000 })`. Confirme com um spec debug que loga `document.body.querySelector('[data-testid=...]')` após ~1.5s — se `true`, é só timeout.
- **Worktree já existe com trabalho parcial**: o esforço de remover flags roda em paralelo — o caminho do worktree pode já existir numa branch velha (ex `chore/remove-complete-discipline-enabled-flag` vs `chore/remove-flag-<slug>`) com mudanças não commitadas, ou a branch-alvo já existir localmente no topo de `main`. Antes de recriar: `git worktree list`, `git branch | grep <slug>`, e inspecione `git diff` do que já está feito. Se o trabalho parcial estiver correto, apenas `git checkout chore/remove-flag-<slug>` no worktree (carrega as mudanças não commitadas) e finalize — não recrie do zero nem duplique o esforço. Confira também se a branch-alvo local está desatualizada vs `origin/main` (`git log HEAD..origin/main`) e atualize antes de commitar.
  - **Caminho real do worktree varia** — não assuma `../worktrees/<repo>-<slug>` cegamente. Já apareceram `/Users/<user>/workspace/genial/worktrees/<repo>-<slug>`, `/Users/<user>/workspace/genial/.worktrees/<repo>-<slug>`, e slugs que não batem 1:1 com o nome da flag (`clinical-panel-signature-modal` para `CLINICAL_PANEL_SIGNATURE_MODAL_ENABLED`). Rode `git worktree list` primeiro para descobrir caminho e branch reais em vez de construir o caminho por convenção.
  - **O trabalho pode já estar 100% pronto (commit + push + PR aberto)**, não só parcial/local. Antes de commitar/abrir PR, rode `gh pr list --repo <org>/<repo> --head <branch> --state all`. Se já existir um PR OPEN para a branch da flag, NÃO duplique o trabalho — apenas valide o que já foi feito: rode lint/tsc/specs relevantes localmente no worktree existente e confira `gh pr view <n> --json statusCheckRollup,assignees,reviewRequests` para confirmar CI, assignee e reviewer já configurados. Reporte que o PR já existe junto com as validações reproduzidas, em vez de recriar commits/PR.
