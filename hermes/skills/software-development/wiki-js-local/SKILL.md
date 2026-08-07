---
name: wiki-js-local
description: Local Wiki.js. Use when sidebar is empty after make wiki.
---

# wiki-js-local

The `product-engineer-agent` repo ships a local Wiki.js via Docker Compose for browsing documentation as a wiki. The Makefile has targets for the full lifecycle.

## Makefile targets

| Target | What it does |
|---|---|
| `make wiki` | `docker compose up -d` + runs `.wiki/setup.js` (boot + sync) |
| `make wiki-sync` | Re-syncs docs only (no container restart) |
| `make wiki-stop` | Stops the container |
| `make wiki-clean` | Stops and deletes all data (full reset) |

## Credentials (hardcoded in .wiki/setup.js)

- URL: `http://localhost:3001`
- Email: `admin@wiki.local`
- Password: `wiki-local-dev`
- Locale: `pt-br`

## How page sync works

`.wiki/setup.js` does:
1. Waits for Wiki.js healthcheck (`/healthz`)
2. On first boot: calls `/finalize` to create the admin account
3. Downloads and configures the `pt-br` locale (single-locale, no namespacing)
4. Walks `documentations/` and `error-analysis/` for `.md` files
5. Creates or updates each as a Wiki.js page via GraphQL

## CRITICAL PITFALL: setup.js does NOT configure navigation

`setup.js` syncs all pages but never calls `navigation.updateTree`. After `make wiki`, the sidebar shows only the home page — all 900+ pages exist but are unreachable from the UI.

**Fix:** run `.wiki/setup-nav.js` after `make wiki` (or after `make wiki-sync` if the nav was lost):

```
node .wiki/setup-nav.js
```

This script:
1. Logs in via GraphQL
2. Lists all pages
3. Builds a flat list of `NavigationItemInput` with slash-separated `id` fields (e.g. `documentations`, `documentations/adrs`, `documentations/adrs/0001-foo`) — Wiki.js infers the tree from the `/` hierarchy
4. Calls `navigation.updateConfig(mode: TREE)` then `navigation.updateTree(tree: [{locale, items}])`

If `setup-nav.js` is missing or broken, see `references/wikijs-navigation-graphql.md` for the full API schema and a reproduction recipe.

## Post-sync checklist

1. `docker compose ps` — container is Up
2. `curl -s http://localhost:3001/healthz` — returns `{"ok":true}`
3. `node .wiki/setup-nav.js` — prints item count and success
4. Open `http://localhost:3001/pt-br/` — sidebar should show folder tree

## Adding setup-nav.js to the Makefile (recommended)

The `make wiki` target should run setup-nav after setup so the user doesn't need a manual second step. Patch the `wiki` target:

```makefile
wiki: ## Sobe o Wiki.js e sincroniza os documentos do repo
	@docker compose up -d
	@node .wiki/setup.js
	@node .wiki/setup-nav.js
```

## After `make wiki-clean`

A full reset wipes the database. The next `make wiki` will re-run finalize (admin creation), locale config, and page sync. Navigation must be re-run too — so include `setup-nav.js` in the `wiki` target or run it manually.
