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
