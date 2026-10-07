---
name: genialcare-feature-workflow
description: "Use em feature multi-repo GenialCare. Condutor do ciclo."
---

# GenialCare Feature Workflow — condutor do ciclo de vida de uma feature multi-repo

Use esta skill ao **executar qualquer feature que mexa em 2+ sistemas GenialCare**
(core + clinical-panel-bff + clinical-panel, ou combinações com operational/mobile).
Ela é o "condutor" que amarra o fluxo ponta a ponta. Não duplica o que já existe:
delega para `genialcare-local-dev` (dev local), `pr-open-full`/`pr-analyse-comments`
(PRs e comentários), `local-dev-db-sync` (dados), `github-stacked-pr-merge` (stacks),
`implement-feature` (orquestração por subagents).

## Princípio 0 — Proatividade: busque antes de perguntar

Antes de fazer qualquer pergunta ao usuário, esgote as fontes de baixo custo, nesta ordem:

1. **Código dos repos irmãos** (`projects/<repo>/`) — leia o código real, trace símbolos até
   a definição, não chute shape. `search_files` para localizar.
2. **Skills/convenções do próprio repo** — `projects/<repo>/.claude/skills/`, `AGENTS.md`/
   `CLAUDE.md`/`.cursorrules`. É a fonte do "como se faz aqui".
3. **Slack** (MCP) — contexto de produto/negócio que não está no código.
4. **Dados** — BQ (CLI `bq` ou Metabase) para dados não-real-time; Postgres do core
   (`docker exec core-db-1 psql ...`) para dados que precisam ser real-time.
5. **Memória + `session_search`** — decisões passadas sobre o mesmo tema.
6. **Git** (`git log`/`git blame`) — o "porquê" de decisões já tomadas.
7. **Internet** — docs de libs/APIs.

**Só pergunte ao usuário quando** for uma decisão de produto genuína, não-descoberta por
essas fontes, ou sensível (permissionamento OpenFGA, segredos, LGPD). Quando decidir por
conta própria, use julgamento conservador e registre a decisão (decision log / status.md).

## Princípio 1 — Gate de qualidade antes de devolver código

Antes de dar por concluído qualquer trecho, cheque (não é checklist opcional):

- **Já existe solução na codebase?** Não reinvente. `search_files` antes de escrever.
- **Skills do repo foram lidas?** As convenções específicas de cada projeto (`rake`,
  `enum`, `permissions-catalog` no core; `create-react-component` no panel).
- **Legibilidade/manutenção**: nomes descritivos, sem número mágico, sem duplicação.
- **Refactor pequeno com ganho grande?** Se sim, aponte como follow-up separado — **não
  faça refactor drive-by** no meio da task (viola "só mudanças relevantes").
- **Performance**: N+1, índices, query pesada. **Segurança**: isolamento de tenant
  (`tenant_id`), LGPD (anônimizar em artefatos publicados), nunca commitar segredo.
- **Convenções de projeto** (resumo; a fonte é a skill de cada repo):
  - core: `standardrb` (não rubocop), `UseCase.call(params:, current_user:)` kwargs,
    `FeatureFlag.on?(key:)` sem default, specs sem `let`, PR base **sempre `main`**.
  - panel/bff: `yarn` (não npm), respeitar `.nvmrc`, `yarn types` antes de commitar.

## Princípio 2 — Rodar tudo local e validar de verdade

1. **Subir a stack**: `make clinical-up` (tudo local) ou `make clinical-up-hybrid`
   (panel+bff local, core no GCP) a partir do repo `product-engineer-agent`.
   `make clinical-down` para parar; `make clinical-status`/`clinical-logs` para checar.
   Detalhes de env/Docker/CORS: skill `genialcare-local-dev`.
2. **Dados reais, não seeds**: `local-dev-db-sync` (importa o DB de development) — seeds
   sintéticos não batem com tokens Auth0 reais. Liberdade total para alterar dados locais
   e viabilizar o teste de integração.
3. **Rodar testes a cada mudança de código** — sua, do usuário, ou de reviewer. No panel,
   use `VITEST_JUNIT_OUTPUT_FILE=/tmp/junit.xml yarn vitest run <spec>` (senão crasha).
   `yarn types` e suíte full via `terminal(background=true, notify_on_complete=true)`.
4. **Integração entre sistemas**: terminou o BFF, teste contra o core; terminou o panel,
   teste contra BFF+core. Use **browser headless** para as partes que tocam o panel.
5. **Evidência visual**: tire screenshots antes/depois (Playwright local, login
   `dev@genialcare.com.br` / senha = o próprio email). Valide **funcional E bonito**
   (larguras, cores, estados). Screenshots e GIFs/vídeos são bem-vindos como evidência — mas
   **fora do repo** (ex.: `/tmp/` ou pasta scratch fora do workspace), para usar no PR e ao
   mostrar pros usuários. Nunca commite mídia no repo; apague depois.

## Princípio 3 — Worktrees para paralelizar (com realismo)

- **Frontend paraleliza**: o panel roda em `5050/5051/5052` — até 3 stories de UI ao mesmo
  tempo em worktrees separados. Auth0 dev aceita esses ports (teste antes de matar o 5050).
- **2 cores em paralelo — VALIDADO (receita completa em `references/parallel-core-recipe.md`)**.
  Até 2 confortável no Colima 12GB/8cpu; 3 apertado. Requisitos, em ordem:
  1. worktree sob `$HOME` (Colima não bind-monta `/tmp` → `/app` vazio);
  2. `docker-compose.override.yml` com `ports: !override` (não `!reset` = esvazia, não lista crua = concatena);
  3. `colima ssh -- sudo sysctl -w fs.inotify.max_user_instances=1024` antes do 2º core (senão 500 EMFILE);
  4. `image: core-app:latest` + volume `bundle_path` externo `core_bundle_path` (pula rebuild + re-install);
  5. `-p <projeto>` separa os volumes Postgres/Redis/Firebase sozinho — só as portas host precisam remap.
  Para specs sem subir 2ª stack, reutilize o projeto canônico: `docker compose -p core run --rm -T --entrypoint bundle -e RAILS_ENV=test app exec rspec <specs>`.
- Registre no `status.md` qual story está em qual worktree/porta.

## Princípio 4 — `status.md` vivo (não só DoD)

Mantenha um `status.md` **vivo** dentro da pasta da user story. O DoD estático (checklist de
critérios) pode coexistir, mas adicione a seção de runtime abaixo. Use o template em
`templates/status.md`. Atualize a cada transição de estado (PR aberto → aprovado → mergeado;
worktree criado/removido; job criado/parado).

## Princípio 5 — Fluxo de PRs

1. **Dividir PRs**: um PR por sistema/fluxo. PR grande que mexe em mais de um fluxo →
   separar. Ordem de merge obrigatória → **GitHub Stack** (`github-stacked-pr-merge`).
2. **Abrir como Draft** (`pr-open-full`), e pedir review do **bot `genialcare-engineering-agent`**
   como **primeira e única** camada de validação:
   - assignee `regishideki`; reviewer **somente** `GenialCare/genialcare-engineering-agent`
     (time) — **NÃO** `capacidade-clinica` (esse entra só depois da validação do usuário, passo 4).
   - O pedido de review do time dispara o workflow `agentic-pr-review.yaml` ("PR Review") no core,
     que publica a review do bot (`APPROVE`/`REQUEST_CHANGES`/`COMMENT` + inline comments).
   - **Gotcha crítico:** o PR precisa estar **READY (não-draft)** ANTES de pedir o review do bot.
     Pedir review num PR draft dispara `review_requested` com `requested_team` vazio → o job cai
     em `skipped` (parece que "marcou" mas não revisou). Sequência correta: abrir draft →
     `gh pr ready <N>` → `gh pr edit <N> --remove-reviewer <outro> --add-reviewer GenialCare/genialcare-engineering-agent`.
     Se o bot foi adicionado ainda em draft (timeline mostra `review_requested` antes de
     `ready_for_review`), re-dispara com remove+add do time DEPOIS do ready.
   - Descrição = **visão geral** (igual em todos os PRs da story) + **visão específica** (o que
     este PR resolve).
3. **Cron de varredura de comentários** (via `cronjob`, não CCR — estamos no Hermes):
   - Agenda recomendada: **`0 9-19 * * 1-5`** (hora em hora, dias úteis). 15 min é excessivo:
     comentários não chegam nessa velocidade e cada varredura custa tokens. Use `*/15` só se
     o usuário insistir num fluxo quente.
   - A cada disparo: lista comentários do PR (`gh api .../reviews` e `.../comments`), segue
     `pr-analyse-comments`, mas com a regra de escalonamento abaixo.
   - **Guardrails duros**: (a) nunca push na `main`, só na branch do PR; (b) comentário
     ambíguo/interpretativo → **escale para o usuário**, não resolva por conta; (c) comentário
     claramente correto → aplica, commit incremental, responde na thread com link do commit
     (menciona o bot que pediu); (d) uma rodada sem comentário novo → marca como "pronto para
     validação do usuário".
4. **Após validação do usuário** → `pr-request-review` (adiciona o time `capacidade-clinica`
   como revisor, avisa). O bot `genialcare-engineering-agent` sai da jogada (ele mesmo se remove
   da lista de reviewers depois de publicar a review — não precisa limpar manualmente).
5. **Cron de merge**: a cada disparo, se `reviewDecision == APPROVED` e CI ok → merge /
   auto-merge; se branch desatualizada ou conflito → `git fetch origin main && git merge
   origin/main && git push`; se já mergeado → atualiza status.
6. Re-rodar testes a cada mudança pedida por você ou por reviewer (Princípio 2.3).

## Princípio 6 — Cleanup pós-merge

Quando todos os PRs estiverem mergeados (ou o usuário avisar que terminou):

1. Atualizar `status.md` (estado final de cada PR).
2. Mergear a pasta da user story na `main` do `product-engineer-agent` + push (docs vão
   direto pra main, não em PR).
3. Parar os projetos: `make clinical-down`.
4. Remover worktrees: `git worktree remove <path>` (e `git worktree prune`).
5. Parar os cron jobs: `cronjob(action='remove', job_id=...)` — liste antes com
   `cronjob(action='list')`, nunca adivinhe IDs.
6. Limpar arquivos temporários (pidfiles, logs, junit) e qualquer coisa que sobrou.

## Ordem canônica do fluxo

```
implement-feature (orquestra execução)
  → Princípio 2/3 (dev local + worktrees + validação visual + testes)
  → Princípio 4 (status.md vivo, atualizado a cada transição)
  → Princípio 5.2 (PRs draft + menciona bot)
  → Princípio 5.3/5.5 (cron jobs de comentários + merge)
  → Princípio 6 (cleanup)
```

## Pitfalls

- **Não duplique as skills existentes**: se `genialcare-local-dev` já explica um gotcha de
  Docker/env, referencie-a, não copie. Esta skill é o fio condutor, não o manual.
- **Cron no Hermes ≠ Claude Code Remote**: `pr-open-full` documenta o caminho CCR
  (`mcp__claude_ai_Claude_Code_Remote__create_trigger`). Neste ambiente (Hermes Agent), o
  mecanismo nativo é a tool `cronjob`. Prefira `cronjob` e adapte o prompt do job para ser
  self-contained (jobs de cron rodam em sessão nova, sem contexto desta conversa).
- **Timezone do cron**: o scheduler do Hermes usa hora local (BRT). `0 9-19 * * 1-5` está
  correto, sem ajuste de fuso.
- **Não deixe jobs órfãos**: cada PR/cron criado precisa de um dono claro e de um passo de
  cleanup (Princípio 6). Job que não se auto-remove nem é removido no cleanup vira ruído.
- **Paralelismo (validado)**: frontend paraleliza fácil (5050/5051/5052). 2 cores em paralelo
  funcionam (Princípio 3), mas 3 gotchas não-óbvios: (a) `ports` em override CONCATENA — use
  `!override`; (b) worktree em `/tmp` monta vazio no Colima — use `$HOME`; (c) 2 Rails estouram
  `fs.inotify.max_user_instances` (128) → `colima ssh -- sudo sysctl -w
  fs.inotify.max_user_instances=1024`. Receita completa: `references/parallel-core-recipe.md`.
