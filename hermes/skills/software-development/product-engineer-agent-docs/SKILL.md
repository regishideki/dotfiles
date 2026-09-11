---
name: product-engineer-agent-docs
description: "Use in product-engineer-agent repo for docs and prototypes."
category: software-development
---

# product-engineer-agent — docs & prototypes

Repo `~/workspace/genial/product-engineer-agent`: o "organizador de features" (só documentação e
planejamento; os repos irmãos ficam sob `projects/` como symlinks). Aqui você cria user stories
(`analysis.md`/`PRD.md`/`todo.md`), HTML prototypes e diagramas, e gerencia o sidebar docsify.

## Comandos de build — a distinção que importa (pitfall)

Dois "builds" diferentes e NÃO relacionados. Não confunda:

| Comando | O que faz | Quando |
|---|---|---|
| `npm run build` | `node generate-sidebar.js` — regenera o `_sidebar.md` (docsify) a partir de `documentations/`. **Auto-gerado, seguro** (só escreve `_sidebar.md`, header "não edite manualmente"). | Depois de criar/remover `.md`, para o sidebar incluir. |
| `npm run prototypes:test` + `npm run prototypes:build` | Valida e compila os HTML prototypes para `.prototype-site/` (guardrails: noindex, sem conteúdo bloqueado, manifest válido). | Depois de criar/editar um protótipo. |

**Pitfall (já custou várias voltas):** `npm run build` NÃO é build de protótipo (não toca HTML) e
NÃO destrói trabalho — `_sidebar.md` é auto-gerado; `git status` mostrando `M  _sidebar.md` é só
sidebar regenerado, não WIP manual. Rode `npm run build` à vontade para atualizar o sidebar; não
o recuse como "destrutivo". O pipeline de protótipo é o `prototypes:*` separado.

## Protótipos HTML

Local: `documentations/user_stories/<yyyyMMdd>-<slug>/prototipo/index.html` +
`prototipo/prototype.publish.json`.

Manifest (`prototype.publish.json`):
```json
{ "title": "...", "slug": "<slug>", "entrypoint": "index.html", "status": "em-validacao" }
```

```bash
npm run prototypes:test && npm run prototypes:build
open documentations/user_stories/<date>-<slug>/prototipo/index.html
```

Verificar um protótipo (não há build que cubra HTML standalone): parse de balanceamento de tags +
`node --check` no `<script>` inline. Para protótipos com muitos itens repetidos, renderize via JS
(dado + `innerHTML`) em vez de inflar o HTML.

## Convenções

- User stories em `documentations/user_stories/<yyyyMMdd>-<slug>/` com `analysis.md`, `PRD.md`,
  `todo.md` (grafo de dependência mermaid `T1 --> T2 --> …`).
- Docs em pt-BR; commit direto na `main` para docs; PR só para `.claude/commands/` / `.claude/skills/`.
- CSV é o padrão do time para imports/mappings (não YAML/JSON).
- Comparativos entre alternativas: pasta própria por alternativa + cross-reference nos dois
  sentidos (cada `analysis.md` aponta para o outro).
