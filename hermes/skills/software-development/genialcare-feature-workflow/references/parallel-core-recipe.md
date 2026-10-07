# 2 cores em paralelo — receita validada (2026-10-06)

Validado de ponta a ponta: 2 cores (Rails) rodando ao mesmo tempo, cada um com
Postgres/Redis/Firebase próprios e health_check 200 em portas distintas. Isolamento de
DB confirmado (marcador num DB, ausente no outro).

## Pré-requisito único: inotify

2 apps Rails estouram o limite default do Colima. **Obrigatório antes de subir o 2º core:**

```bash
colima ssh -- sudo sysctl -w fs.inotify.max_user_instances=1024
```

Sem isso, o 2º core boota mas `health_check` retorna 500 com
`Errno::EMFILE (Failed to initialize inotify...)`. O valor reseta ao reiniciar a VM —
re-aplique após `colima restart`.

## Receita

### 1. Worktree dentro do $HOME (não em /tmp)

Colima NÃO faz bind-mount de `/tmp` para dentro da VM — um worktree em `/tmp` monta
vazio em `/app` (o `bundle`/`rails` não acha o Gemfile). Worktrees DEVEM viver sob
`$HOME` (ex.: `~/workspace/genial/worktrees/<nome>`).

```bash
cd ~/workspace/genial/core
git worktree add --detach ~/workspace/genial/worktrees/core-par-a HEAD
```

### 2. `docker-compose.override.yml` com `!override`

`docker compose` faz MERGE de `ports` por APPEND (não replace): sem a tag, o serviço
fica com as portas do base E as do override, e o 2º projeto colide. Use `!override`
(que substitui) — **não** `!reset` (que esvazia) e **não** lista crua (que concatena).

```yaml
# docker-compose.override.yml (gitignored, no worktree)
services:
  app:
    image: core-app:latest      # reusa a imagem buildada; pula rebuild
    ports: !override
      - '3001:3000'
  db:
    ports: !override
      - '5433:5432'
  redis:
    ports: !override
      - '6380:6379'
  firebase:
    ports: !override
      - '8081:8080'
      - '4001:4000'
      - '9001:9000'
      - '9098:9099'
volumes:
  bundle_path:
    external: true
    name: core_bundle_path      # compartilha gems (evita re-install)
```

O 2º worktree (`core-par-b`) é idêntico, com portas +1 (3002/5434/6381/8082...).

### 3. Subir, migrar, subir app

```bash
cd ~/workspace/genial/worktrees/core-par-a
docker compose -p corea up -d db redis firebase       # -p corea separa os volumes automaticamente
docker compose -p corea run --rm -T --entrypoint bundle app exec rails db:migrate
docker compose -p corea up -d app
```

- `-p <projeto>` é o que **isola** os volumes `postgres`/`redis`/`firebase` — não precisa
  nomear volume manualmente. Só as portas host precisam de remap (via `!override`).
- `image: core-app:latest` pula o rebuild (que re-rodaria `yarn install` + assets:precompile,
  lento). A imagem já existe após o primeiro `make up` do core canônico.
- O migrate usa `--entrypoint bundle` (o `init.sh` não roda comandos one-off; vê
  `genialcare-local-dev`). Sem migrate, o SolidQueue crasha no DB vazio e derruba o Puma.

### 4. Validar

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3001/health_check   # 200
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3002/health_check   # 200
```

### 5. Cleanup

```bash
docker compose -p corea down -v
docker compose -p coreb down -v
git worktree remove --force ~/workspace/genial/worktrees/core-par-a   # --force: override + db/schema.rb ficam sujos
git worktree remove --force ~/workspace/genial/worktrees/core-par-b
git worktree prune
```

O `--force` é necessário porque o migrate reordena `db/schema.rb` (cosmético) e o override
é untracked — os dois são descartáveis.

## Gotchas

- **`db/schema.rb` muda após `db:migrate`** (reordena colunas) — descarte com `git checkout`
  ou aceite no `--force` do worktree remove.
- **Firebase/Redis poderiam ser compartilhados** (infra dev stateless), mas é mais simples
  deixar `-p` separar tudo; o custo de 2 firebase emuladores é ~500MB cada, ok em 12GB.
- **O alias `core` na rede `genial` pode colidir** se ambos os cores subirem com o mesmo
  alias — para validação por host-port não importa; se um BFF local precisar apontar pro
  core B especificamente, alcance via `http://localhost:3001` (não via alias).
