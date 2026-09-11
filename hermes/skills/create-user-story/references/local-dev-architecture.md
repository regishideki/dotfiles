# Local Dev Architecture (GenialCare 3-Project Stack)

Reference for user stories that involve local development environment, Docker orchestration, or cross-project integration testing. Last verified: 2026-08-21.

For the full guide (Makefile orchestrator, env file semantics, validation checklist, pitfalls), load the `genialcare-local-dev` skill instead — this file is a quick-reference summary.

## Os 3 projetos e suas portas

| Projeto | Stack | Porta local | Como roda local |
|---|---|---|---|
| core | Ruby on Rails | 3000 | Docker (docker-compose.yml) |
| clinical-panel-bff | Node.js + Apollo GraphQL | 4050 | Docker (docker-compose.yml) |
| clinical-panel | React + Vite | 5050 | Nativo (`yarn start` / `yarn start:local`) |

## Rede Docker `genial`

- Rede externa, criada por `make up` do core (`docker network create genial`)
- **core**: alias `core` na rede (também acessível como `core-app-1` — nome automático de container `<project>-<service>-1`)
- **bff**: sem alias explícito, acessível pelo nome de container gerado
- **painel**: não está no Docker — acessa bff e core via `localhost`

## Configuração de environment por projeto

### core (Rails)

- `RAILS_ENV=development` serve para local E GCP — a distinção é implícita (Docker local vs K8s na GCP)
- **Não existe** environment `local` ou `localdev`
- docker-compose.yml: app + Postgres 14 + Redis 7 + Firebase Firestore emulator
- Makefile: `make up` (tudo), `make up-dependencies` (só db + redis + firebase)
- `.env.development`: `CROSS_ORIGIN_URL="*"` (libera `/attachments.json` de qualquer origem)
- **CORS para `/auth/*` em `localhost:5050`**: condicional a `ENV["SERVER_ENV"] == "development"` em `cors.rb`. `SERVER_ENV` **não está setado** localmente — pode bloquear auth local. Fix: adicionar `SERVER_ENV=development` ao `.env.development` ou docker-compose.

### clinical-panel-bff (Node)

- **Único projeto com distinção clara** entre local e GCP
- Mecanismo: `NODE_ENV` seleciona `.env.*` em `src/config/index.js` (default: `local`)
- Arquivos em `src/config/`:

| Arquivo | `CORE_API_URL` | Modo |
|---|---|---|
| `.env.local` | `http://core-app-1:3000` | Local (core no Docker) |
| `.env.development` | `http://core-internal.api-gateway.svc.cluster.local` | GCP dev (K8s internal DNS) |
| `.env.local_to_development` | `https://core.development.internal.genialcare.com.br` | Hybrid (BFF local, core GCP) |
| `.env.staging` | `http://core-internal.api-gateway.svc.cluster.local` | GCP staging |
| `.env.production` | `http://core-internal.api-gateway.svc.cluster.local` | GCP prod |

- Makefile: `make up-local` (NODE_ENV=local), `make up-local-to-development` (hybrid), `make up` (NODE_ENV=development, GCP)
- **`OAUTH_CLIENT_ID` e `OAUTH_CLIENT_SECRET` são placeholders (`12345`) em todos os `.env.*` — NÃO são lidos pelo código.** O BFF é pass-through de auth: pega o header `Authorization` do frontend e repassa para o core. Não perca tempo tentando resolver isso.
- **`CLINICAL_LLM_API_URL=http://web-internal.clinical-llm.svc`** no `.env.local` — endereço de K8s que não resolve localmente. Features de LLM falham no modo local. Fora de escopo.

### clinical-panel (React/Vite)

- **Sem Docker, sem Makefile próprio, sem Dockerfile** — é `yarn start` (vite) puro
- `.env.development`: aponta para GCP dev por default (`VITE_BFF_API_URL=https://clinical-panel-bff.development.internal.genialcare.com.br/graphql`)
- **Modos do Vite**: o Vite carrega env files baseado no modo. O modo default do `yarn start` (= `vite`) é `development`, que carrega `.env.development` (GCP URLs).
- **Solução: `yarn start:local` com `vite --mode dev-local`** — o `package.json` tem um script `start:local` que roda `vite --mode dev-local`. Isso carrega `.env.dev-local` em vez de `.env.development`:
  - `yarn start` → GCP development (modo `development`, carrega `.env.development`)
  - `yarn start:local` → local (modo `dev-local`, carrega `.env.dev-local`)
- `.env.dev-local` está versionado no repo (não precisa copiar) — tem as mesmas credenciais de dev (Auth0, Firebase, Split.io) que `.env.development`
- Variáveis-chave: `VITE_BFF_API_URL`, `VITE_CORE_UPLOAD_URL`, `VITE_LEGACY_PANEL_URL`, `VITE_ENVIRONMENT`
- **Por que não `.env.local`?** O Vite carrega env files nesta ordem (posteriores sobrescrevem anteriores):
  1. `.env`
  2. `.env.local`
  3. `.env.[mode]` (ex: `.env.development`)
  4. `.env.[mode].local` (ex: `.env.development.local`)
  Como `yarn start` roda no modo `development`, `.env.development` **sobrescreve** `.env.local`. A abordagem `--mode dev-local` é mais limpa — alternar é só trocar de comando.
- **Por que não `--mode local`?** O Vite reserva `local` como nome de modo pois conflita com o sufixo `.local` dos env files. Erro: `"local" cannot be used as a mode name`. Use `dev-local` (ou qualquer nome sem `.local`).
- **Usa yarn, não npm**: o projeto tem `yarn.lock`. O Makefile deve chamar `yarn start:local`, não `npm run start:local`.
- **Requer `nvm use` antes**: o projeto tem `.nvmrc` (Node v20.19.2). O Makefile deve fazer `source ~/.nvm/nvm.sh && nvm use` antes de chamar yarn.

## Makefile orquestrador (product-engineer-agent)

Targets com prefixo de produto (`clinical-*`, futuro: `operational-*`, `mobile-*`):

| Target | O que faz |
|---|---|
| `make clinical-up` | core (Docker) + bff (Docker, NODE_ENV=local) + painel (Vite nativo, mode=dev-local) |
| `make clinical-up-hybrid` | bff (NODE_ENV=local_to_development) + painel (Vite nativo); core na GCP |
| `make clinical-down` | Para tudo (Docker + Vite) |
| `make clinical-logs` | Tails de todos os serviços |
| `make clinical-status` | Status dos containers e do processo Vite |

O processo Vite é gerenciado via pidfile (`/tmp/dev-clinical-panel.pid`) e log redirect (`/tmp/dev-clinical-panel.log`). O Makefile faz `source nvm.sh && nvm use && yarn start:local` para iniciar o painel.

## Fluxo de dados local (alvo)

```
clinical-panel (localhost:5050, Vite nativo, yarn start:local)
    ↓ VITE_BFF_API_URL=http://localhost:4050/graphql
clinical-panel-bff (Docker, porta 4050, NODE_ENV=local)
    ↓ CORE_API_URL=http://core-app-1:3000
core (Docker, porta 3000, RAILS_ENV=development)
    ↓ DATABASE_HOST=db, REDIS_URL=redis://redis:6379, FIRESTORE_EMULATOR_HOST=firebase:8080
Postgres 14 + Redis 7 + Firebase Firestore emulator (Docker)
```

## Fluxo de dados hybrid (já suportado pelo BFF)

```
clinical-panel (localhost:5050, Vite nativo, .env.dev-local com BFF local)
    ↓ http://localhost:4050/graphql
clinical-panel-bff (Docker, porta 4050, NODE_ENV=local_to_development)
    ↓ CORE_API_URL=https://core.development.internal.genialcare.com.br
core (GCP development)
```

## Problemas técnicos conhecidos

1. **Vite `.env.local` sobrescrito por `.env.development`**: usar `yarn start:local` (`vite --mode dev-local`) que carrega `.env.dev-local` em vez de `.env.development`.
2. **`local` é um nome de modo reservado no Vite**: `vite --mode local` falha. Usar `dev-local`.
3. **CORS condicional**: `cors.rb` do core libera `localhost:5050` para `/auth/*` só se `SERVER_ENV=development`, mas esse env var não está setado localmente.
4. **CLINICAL_LLM_API_URL**: endereço de K8s no `.env.local` do BFF, não resolve localmente.
5. **Firestore no browser**: SDK do Firebase no browser do painel pode apontar para GCP em vez do emulador local (`localhost:8080`).
6. **Comentários inline em dotenv**: comentários dentro de aspas duplas são interpretados como parte do valor. Pôr em linha separada acima da variável.
7. **Usar yarn e nvm**: o clinical-panel usa yarn (não npm) e requer Node v20.19.2 do `.nvmrc`. O Makefile deve fazer `source nvm.sh && nvm use && yarn start:local`.

## Referência: user story

`documentations/user_stories/20260821-local-dev-orchestration/` — user story que adicionou o Makefile orquestrador (Docker para core+bff, Vite nativo para painel) com modo local e hybrid.
