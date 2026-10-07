---
name: product-engineer-prototyping
description: "Publish HTML prototypes in the product-engineer-agent repo."
category: software-development
---

# Prototipagem no product-engineer-agent

No repo organizador `product-engineer-agent`, protótipos HTML para validação de PM vivem dentro de
user stories e são publicados por um pipeline próprio. (A skill repo-level
`.claude/skills/prototype-and-publish/SKILL.md` descreve o fluxo completo; aqui fica o que o Hermes
precisa saber para não tropeçar nos comandos.)

## Estrutura

```
documentations/user_stories/<folder>/prototipo/index.html
documentations/user_stories/<folder>/prototipo/prototype.publish.json
```

Manifesto `prototype.publish.json`:
```json
{ "title": "Título legível", "slug": "slug-do-prototipo", "entrypoint": "index.html", "status": "em-validacao" }
```

## Comandos — e o pitfall crítico

- **Verificar/publicar protótipos:** `npm run prototypes:test` (guardrails) + `npm run prototypes:build` (gera `.prototype-site/`).
- **Publicar de fato = push na `main`** (não é via MCP): commit + push na `main` dispara a Action
  `publish-prototypes.yml` → GitHub Pages em
  `https://genialcare.github.io/product-engineer-agent/prototypes/<slug>/`. Documentação/user story
  vai direto na `main` (sem PR). Confirme o trigger com `gh run list -w publish-prototypes.yml`.
- **`npm run build` NÃO é verificação de protótipo.** Ele é `node generate-sidebar.js`: regenera o
  `_sidebar.md` do docsify a partir de `documentations/**/*.md`. Só escreve `_sidebar.md` (arquivo
  auto-gerado, cabeçalho "não edite manualmente") — **não valida HTML/JS de protótipo**.

Pitfall real de sessão: o assistente segurou `npm run build` por vários turnos achando que era
"destrutivo" (sobrescreveria WIP do usuário). **Não é.** `_sidebar.md` é auto-gerado; rodar
`npm run build` apenas o regenera para incluir docs novas — inócuo e, aliás, o passo correto ao
adicionar `.md` novos. A "modificação" no `_sidebar.md` que aparece no `git status` é o próprio
conteúdo regenerado, não edição manual. Se um nudge de verificação pedir `npm run build` para um
arquivo de protótipo (`.html`/`.json`), a verificação que realmente cobre o protótipo é
`prototypes:test` + `prototypes:build`; `npm run build` pode ser rodado junto (é seguro, regenera o
sidebar) mas não valida o protótipo.

## Publicar = commit + push na main (pitfalls de git e verificação)

- **Cheque o que já está STAGED antes de commitar.** Este repo acumula WIP de várias sessões; é
  comum haver arquivos staged de outro trabalho (`git status --short` mostra `M `/`A ` na PRIMEIRA
  coluna = já staged). `git commit` sem `git add` específico empacota TUDO que está staged — já
  aconteceu de levar `config.default.yml`, `hbj/*` e `wiki/*` junto num commit de protótipo.
  Sempre faça `git add documentations/user_stories/<slug>/` (caminho exato) e confira com
  `git status --short` que só os arquivos da story estão em `M `/`A ` antes do commit. **A checagem
  autoritativa do que o commit vai pegar é `git diff --cached --stat`** — `git status --short` pode
  exibir entrada staged "fantasma" (arquivo `M ` que não aparece no `--cached`), visto em sessão;
  confie no `--cached`, não no `--short`.
- **Se um commit já pegou arquivo alheio:** `git reset --soft HEAD~1` (desfaz o commit, mantém
  tudo staged), depois `git restore --staged <arquivo-alheio>` (tira do index, preserva o working
  tree), re-commit. Os arquivos alheios voltam a ` M ` (unstaged) — exatamente o estado prévio.
- **Verifique o conteúdo LIVE, não só o status da Action.** `gh run watch <run_id> --exit-status`
  espera o `publish-prototypes.yml` terminar; depois confirme que a página servida tem a mudança
  (não confie só no "deploy ✓"):
  `curl -s https://genialcare.github.io/product-engineer-agent/prototypes/<slug>/ | grep -c "<marcador-novo>"`.
  Use um marcador distintivo da mudança (ex: a string nova que entrou no HTML), não algo que já
  existia.

## Protótipo fora da `main` = 404 (Pages publica SÓ da main)

A Action `publish-prototypes.yml` só faz deploy no evento `push` na `main`
(`if: github.event_name != 'pull_request'`). Um protótipo que vive só num PR aberto **não vai ao
ar**. Se a pasta da story (com o `prototipo/`) for removida da `main` — ex. movida para um PR — o
próximo deploy de `main` apaga a rota e a URL vira 404. O protótipo não foi perdido: está intacto
no branch do PR.

Diagnóstico rápido de "por que 404": `git log --oneline --all -- <story>/` mostra o commit que
removeu a pasta da main (procure mensagem tipo "move to PR #N"), e
`git ls-tree -r origin/<pr-branch> -- <story>/` confirma que o protótipo ainda existe lá.

### Receita: mover só o `prototipo/` para a main, mantendo o PR para análise/PRD

Quando o usuário quer o protótipo publicado agora, mas a análise/PRD seguem em review no PR:

1. Trazer os arquivos: `git checkout origin/<pr-branch> -- '<story>/prototipo/'` (já fica staged).
2. Confirmar o que o commit vai pegar com `git diff --cached --stat` (ver pitfall acima).
3. Validar: `npm run prototypes:test && npm run prototypes:build` — o slug deve aparecer em
   `.prototype-site/prototypes/`.
4. `git commit -- '<story>/prototipo/'` + `git push origin main`.
5. Remover do PR sem perturbar o WIP da working tree da main: usar worktree temporário —
   `git worktree add -b _tmp-x /tmp/x <pr-branch>` → `git rm -r <story>/prototipo/` → commit →
   `git push origin _tmp-x:<pr-branch>` → `git worktree remove /tmp/x --force`. O worktree evita
   carregar o WIP não-commitado da main para dentro do branch do PR.

Sem conflito no merge futuro: a `main` passa a ter o `prototipo/` idêntico ao do PR (mesmo blob) e
o PR não toca mais nele — o merge só adiciona os arquivos de análise/PRD.

## Guardrails do pipeline (o que `prototypes:test` checa)

- `<meta name="robots" content="noindex, nofollow">` obrigatório.
- Bloqueio de conteúdo interno (emails, tokens, paths `file://`, `localhost`).
- `slug`/`status`/assets válidos; arquivos fora do diretório do protótipo.
- **`prototypes:test` NÃO pega nome de paciente.** O guardrail bloqueia emails/tokens/paths, mas não
  nomes reais de pacientes/profissionais — eles passariam batido pra publicação. Se o protótipo
  carrega dado real, anonimize na ORIGEM: na query de extração puxe só o ID/número (não `name`/email
  de paciente ou terapeuta), em vez de anonimizar o HTML depois. Assim não vaza PII nem no HTML nem
  nos JSONs intermediários/histórico do repo.

## Técnicas úteis (HTML estático, sem framework)

- **Toggle puro CSS:** `<input type="checkbox" class="obj-toggle">` precisa ser irmão ANTERIOR do
  alvo (`.card`); esconder/mostrar com `.obj-toggle:checked ~ .card .x { ... }`. Se o checkbox
  ficar aninhado dentro de um `<label>` sem o alvo como irmão, o `:checked ~` não dispara.
- **Esconder uma coluna INTEIRA de tabela** (th + td), não só o conteúdo interno: ponha uma classe
  na coluna e use `display:none` por padrão + `.obj-toggle:checked ~ .card .col { display: table-cell; }`.
  Esconder apenas o `<div>` de conteúdo deixa o `<th>` e as células vazias aparentes (usuário notou
  e pediu para sumir com a coluna toda).
- **Dados em JS + render, não HTML gigante:** para itens com MUITOS valores (ex: 65 objetivos num
  só item), defina os dados num array JS e gere as linhas via `document`, em vez de hardcodar —
  mantém o HTML legível. Valide a sintaxe do `<script>` com `node --check` antes de publicar.
- **Mostrar TUDO, sem truncamento:** este usuário pediu explicitamente para remover qualquer "+N
  outros" e exibir a lista completa. Não truncar com "mostrar mais N" sem perguntar.

## Ver também

- `.claude/skills/prototype-and-publish/SKILL.md` (repo-level) — pipeline completo e convenções de manifesto.
- `de-para-mapping` — o padrão item↔objetivo que esses protótipos costumam ilustrar.
