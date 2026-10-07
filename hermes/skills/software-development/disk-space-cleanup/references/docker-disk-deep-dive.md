# Docker disk deep-dive (números reais de uma sessão)

Sessão de referência: "meu HD está quase cheio" — volume de dados em 93% (31Gi livres
de 460Gi). Docker Desktop rodando, engine do Linux inicialmente desligado (só o app
Desktop aberto em tray).

## O problema do Docker.raw

- `Docker.raw` (esparso): tamanho aparente **152G**, mas `du` da pasta mostrava 90G
  alocados. O arquivo cresce com imagens/containers e **nunca encolhe sozinho**.
- Sintoma clássico: `docker system df` mostra pouco (imagens 30G, build cache 2.9G),
  mas o `.raw` está com 5x o uso real.

## O que o `docker system df` sub-reporta

Antes da poda:

```
Images       24   9   30.58GB   23.84GB (77%)
Containers   10   0   9.2MB     9.2MB
Volumes      22   11  5.36GB    3.32GB (62%)
Build Cache  101  0   2.979GB   2.979GB
```

`docker builder prune -af` retornou **"Total: 26.68GB"** — quase 10x o que o df
dizia. O build cache do buildkit é sub-reportado; confie no output do prune.

## Resultado da poda seletiva

| Ação | Reclamado |
| --- | --- |
| `docker builder prune -af` | 26.68GB |
| `docker container prune -f` | 9.2MB |
| `docker image prune -f` (dangling) | 17.6GB |
| `docker rmi` tags 2-3 anos | ~1.1GB |

Espaço livre: 31Gi → 62Gi. O `du` do diretório Docker caiu 90G → 65G (o `.raw`
esparso chegou a devolver ~25G, mas continua com ~48G de slack: 65G alocado vs ~17G
de dados reais = 12G imagens restantes + 5.4G volumes).

## Por que NÃO usar prune agressivo

Inventário de imagens mostrou a distinção:

- **Imagens `<none>:<none>`** (dangling, ~11 delas, 3G cada) = camadas de build
  órfãs de `docker build` sem tag. Seguro apagar.
- **Imagens taggeadas ativas**: `core-app:latest` (11 dias), `clinical-language-models-app`
  (3 semanas), `clinical-panel-bff-app` (2 semanas), `ghcr.io/requarks/wiki:2`,
  `postgres:14`, `redis:7-alpine`, `firebase-tools:15.26.0` — o usuário VAI reusar.
  `docker image prune -a` apagaria todas (0 containers ativos) = desperdício.
- **Volumes nomeados** = dados de dev: `core_postgres`, `core_redis`, `core_firebase`,
  `core_bundle_path`, `clinical-language-models_postgres`,
  `clinical-language-models_extra_postgres`, `product-engineer-agent_wiki-data`,
  `docker-prompts`. `docker volume prune` (após remover containers) apagaria TODOS.

## O que ficou de fora (decisão conservadora)

- `clinical-panel-2` (1.1G, clone duplicado parado há 7 semanas) — usuário pediu para
  deixar.
- Worktrees em `~/workspace/genial/worktrees/` (2.3G) — TODOS ativos (commits do dia).
  Worktrees com commits recentes nunca são candidato a limpeza.
- virtualenvs do poetry (1.4G) — ambientes ativos.
