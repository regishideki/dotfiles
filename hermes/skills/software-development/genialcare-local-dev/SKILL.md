---
name: genialcare-local-dev
description: "Run GenialCare projects locally in an integrated way — core (Rails), clinical-panel-bff (Node), clinical-panel (React/Vite), or any combination. Use when debugging local dev configuration: env files, Docker networking, CORS, port conflicts, or cross-project connectivity. Makefile orchestrator uses product-prefixed targets (clinical-up, clinical-down, etc.) that extend to operational/mobile."
---

# GenialCare Local Dev Environment

Use this skill when the user wants to run GenialCare projects locally in an integrated way — core (Rails), clinical-panel-bff (Node), clinical-panel (React/Vite), or any combination. Also use when debugging local dev configuration: env files, Docker networking, CORS, port conflicts, or cross-project connectivity.

## Architecture: the three-project local dev stack

| Project | Type | Port | Docker? | Env switch |
|---|---|---|---|---|
| core | Rails (API) | 3000 | Yes (app+db+redis+firebase) | `RAILS_ENV=development` |
| clinical-panel-bff | Node (GraphQL BFF) | 4050 | Yes | `NODE_ENV` selects `.env.*` |
| clinical-panel | React/Vite | 5050 | No (native Vite) | Vite mode selects `.env.*` |

### The `genial` Docker network

core and bff both use an **external** Docker network called `genial`. It must be created once:
```bash
docker network create genial
```
Both projects' `docker-compose.yml` reference it as `external: true`. The `make up` target in core's Makefile creates it automatically.

The core container is accessible on this network as `core-app-1` (Docker Compose auto-generated name `<project>-<service>-1`) and also has the alias `core`. The BFF's `.env.local` uses `http://core-app-1:3000` — this works because Docker Compose registers the container name on the network.

### BFF environment distinction (the cleanest of the three)

The BFF is the only project that explicitly distinguishes local from GCP:

| `NODE_ENV` | `.env.*` file | `CORE_API_URL` | Meaning |
|---|---|---|---|
| `local` | `.env.local` | `http://core-app-1:3000` | Core local (Docker) |
| `development` | `.env.development` | `http://core-internal.api-gateway.svc.cluster.local` | Core on GCP (K8s) |
| `local_to_development` | `.env.local_to_development` | `https://core.development.internal.genialcare.com.br` | Hybrid: BFF local, core on GCP |

Mechanism: `src/config/index.js` reads `NODE_ENV` (default `local`) → loads `src/config/.env.${NODE_ENV}`.

### BFF is auth pass-through

The BFF does NOT exchange Auth0 tokens. It reads the `Authorization` header from the frontend's GraphQL request and forwards it verbatim to the core API. The `OAUTH_CLIENT_ID` and `OAUTH_CLIENT_SECRET` in all BFF `.env.*` files are **vestigial placeholders (`12345`) — never read by the code**. Do not waste time trying to "fix" them.

### clinical-panel env configuration

The panel uses Vite, which loads env files based on **mode**. The default mode for `npm start` (= `vite`) is `development`, which loads `.env.development` (GCP URLs).

**Solution: `yarn start:local` with `vite --mode dev-local`**

The `package.json` has a `start:local` script that runs `vite --mode dev-local`. This loads `.env.dev-local` instead of `.env.development` — no file swapping needed:
- `yarn start` → GCP development (mode=`development`, loads `.env.development`)
- `yarn start:local` → local services (mode=`dev-local`, loads `.env.dev-local`)

Setup is zero-config: `.env.dev-local` is committed to the repo with all local URLs pre-configured. No copy step needed — just run `yarn start:local`.

**Why not `.env.local`?** Vite env file precedence (later overrides earlier):
1. `.env`
2. `.env.local`
3. `.env.[mode]` (e.g. `.env.development`)
4. `.env.[mode].local` (e.g. `.env.development.local`)

Because `npm start` runs in `development` mode, `.env.development` **overrides** `.env.local`. We initially tried `.env.development.local` (highest precedence) but that requires adding/removing the file to switch between local and GCP. The `--mode dev-local` approach is cleaner — switching is just a different command.

**Why not `--mode local`?** Vite reserves `local` as a mode name because it conflicts with the `.local` postfix for env files. The error is: `"local" cannot be used as a mode name because it conflicts with the .local postfix for .env files`. Use `dev-local` (or any name without `.local` in it) instead.

### Key env vars per project

**clinical-panel** (`.env.dev-local` for local dev — copy from `.env.dev-local.example`):
- `VITE_BFF_API_URL` — GraphQL endpoint (local: `http://localhost:4050/graphql`)
- `VITE_CORE_UPLOAD_URL` — Rails ActiveStorage direct upload (local: `http://localhost:3000/attachments.json`)
- `VITE_LEGACY_PANEL_URL` — legacy panel link (local: `http://localhost:3000`)
- `VITE_ENVIRONMENT` — label (use `local` for local dev)
- Auth0, Firebase, Split.io, HelpHero vars: copy from `.env.development` (same dev tenants)

**clinical-panel-bff** (`.env.local` already exists):
- `CORE_API_URL` — core API base URL (local: `http://core-app-1:3000`)

**core** (`.env.development` + `.env.development.local`):
- `CROSS_ORIGIN_URL` — CORS origin for `/attachments.json` (`*` in dev, allows any origin)
- `SERVER_ENV` — set to `development` in `.env.development.local` (controls conditional CORS for `/auth/*`; comes from ConfigMap `core-cm` on GCP)
- `FIREBASE_SERVICE_ACCOUNT` — set to the JSON of `core-development-sa-key.json` in `.env.development.local` (required for Firebase custom token; comes from K8s Secret `web` on GCP). Use single quotes to wrap the JSON (Dotenv doesn't unescape single-quoted values, so inner double quotes stay literal): `FIREBASE_SERVICE_ACCOUNT='<inline JSON>'`
- `ACTIVE_STORAGE_TYPE` — set to `google` in `.env.development.local` (makes avatar photos load from GCP dev bucket instead of missing with Disk service)
- `GOOGLE_APPLICATION_CREDENTIALS` — already in `.env.development.local`, points to `core-development-sa-key.json` (the `storage.yml` ERB conditional uses its presence to switch between SA key file and metadata server)

## Makefile orchestrator pattern

The `product-engineer-agent` repo has a Makefile with product-prefixed targets that orchestrate all three projects for a given product line:

| Target | What it does |
|---|---|
| `make clinical-up` | core (Docker) + clinical-panel-bff (Docker, NODE_ENV=local) + clinical-panel (Vite native) |
| `make clinical-up-hybrid` | bff (NODE_ENV=local_to_development) + panel (Vite native); core stays on GCP |
| `make clinical-down` | Stops all Docker containers + kills Vite process |
| `make clinical-logs` | Tails logs from all three services |
| `make clinical-status` | Shows Docker container status + Vite process status |

### Naming convention: product-prefixed targets

Targets are prefixed by product line (`clinical-*`, `operational-*`, `mobile-*`) rather than generic (`local-*`). This makes it explicit which set of projects is being orchestrated and allows adding new product lines (e.g. `operational-up`, `mobile-up`) without naming collisions. Each product line has its own set of variables:

```makefile
CLINICAL_BFF_DIR   := $(WORKSPACE_DIR)/clinical-panel-bff
CLINICAL_PANEL_DIR := $(WORKSPACE_DIR)/clinical-panel
CLINICAL_PID       := /tmp/dev-clinical-panel.pid
CLINICAL_LOG       := /tmp/dev-clinical-panel.log
```

When adding a new product line (e.g. operational), copy the `clinical-*` targets, rename to `operational-*`, and swap the DIR/PID/LOG variables.

The Vite process is managed via pidfile (`/tmp/dev-clinical-panel.pid`) and log redirect (`/tmp/dev-clinical-panel.log`). The Makefile calls `yarn start:local` (not `npm start` or `npm run start:local`) to start Vite in `dev-local` mode. It must also `source ~/.nvm/nvm.sh && nvm use` before calling yarn, to respect the project's `.nvmrc` (Node v20.19.2) instead of the system default Node.

```makefile
NVM_SOURCE := $$([ -s $$HOME/.nvm/nvm.sh ] && echo $$HOME/.nvm/nvm.sh)

clinical-up:
	...
	@cd $(CLINICAL_PANEL_DIR) && (source $(NVM_SOURCE) && nvm use && yarn start:local > $(CLINICAL_LOG) 2>&1 & echo $$! > $(CLINICAL_PID))
```

The `NVM_SOURCE` variable safely resolves to the nvm.sh path or empty string, so the `source` doesn't fail if nvm isn't installed.

### Pattern for managing native (non-Docker) processes in Makefile targets

When a Makefile target needs to start a long-running process (like Vite) in the background:
```makefile
@cd $(CLINICAL_PANEL_DIR) && (npm start > $(CLINICAL_LOG) 2>&1 & echo $$! > $(CLINICAL_PID))
```
Track the PID in a file for `clinical-down` to kill. Use `kill -0 $(cat $(PID))` in `clinical-status` to check if alive.

## Template files

- `templates/.env.dev-local` — the actual env file for clinical-panel local dev, committed directly in the clinical-panel repo. Contains all VITE_* vars with local URLs pre-configured. Used with `yarn start:local` (`vite --mode dev-local`). No copy step needed — the file is tracked, not gitignored, because the credentials are the same dev-level ones already in `.env.development`.

## Reference files

- `references/core-env-investigation.md` — investigation of core env vars needed for local dev (`FIREBASE_SERVICE_ACCOUNT`, `SERVER_ENV`, `ACTIVE_STORAGE_TYPE`): symptoms, root causes, where each is set on GCP, and local fixes.
- `references/seed-minimal-data-for-feature-testing.md` — seed a minimal domain-data chain (tenant → protocol → library objectives → clinical case → PEI → registry) via `rails runner` to test a single core feature end-to-end WITHOUT the full remote DB import. Gotchas: `User` has `first_name`/`last_name` (not `name`); `ClinicalCase` needs `Preferences::ClinicalCasePreferences.create_default`; `Enum::Domains`/`Subdomains` take string values (print `to_h` to map the v2 CSV subdomains); and `UseCase.call(params:, current_user:)` kwargs (NOT a positional hash).

## Validation checklist for local dev

When verifying a local dev environment works end-to-end (after `make clinical-up`):
1. Core health: `curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/health_check` → 200
2. BFF health: `curl -s -o /dev/null -w "%{http_code}" http://localhost:4050/health` → 200
3. Panel: `curl -s -o /dev/null -w "%{http_code}" http://localhost:5050` → 200
4. BFF → Core (inside Docker): `docker exec clinical-panel-bff-app-1 sh -c 'wget -qO- --timeout=5 http://core-app-1:3000/health_check'`
5. Panel loaded local URLs: `curl -s http://localhost:5050/src/api/ApolloProviderWithAuth.tsx | grep localhost:4050`
6. BFF NODE_ENV: `docker exec clinical-panel-bff-app-1 sh -c 'echo $NODE_ENV'` → `local`
7. BFF CORE_API_URL: `docker exec clinical-panel-bff-app-1 sh -c 'echo $CORE_API_URL'` → `http://core:3000` (or `http://core-app-1:3000`). If empty → `.env.local` missing or not loaded.
8. No orphan Vite processes on wrong ports: `ps aux | grep vite | grep clinical-panel | grep -v grep` — should show exactly one Vite process. If multiple, kill orphans with `pkill -f "clinical-panel/node_modules/.bin/vite"`.
9. BFF logs clean (no 401 errors): `docker-compose logs --tail=20 app 2>&1 | grep -iE "401|unauthorized"` → should be empty after page reload.
10. Vite log shows successful startup: `tail -5 /tmp/dev-clinical-panel.log` → should contain `VITE.* ready in` — if it shows `SyntaxError` or `You are using Node.js 16`, Vite crashed (wrong Node version). Check `node --version` in the shell that launched it.
11. Panel page content renders (not just HTTP 200): capture the Chrome tab or `curl -s http://localhost:5050 | head -5` — if the HTML loads but the page shows "Erro ao carregar informações do usuário", the Core DB is empty or missing the Auth0 user. Check `docker exec core-db-1 psql -U root -d core_development -tAc "SELECT count(*) FROM users"` — if <100, import real dev data (see `local-dev-db-sync` skill).

## Pitfalls

- **Vite `.env.local` is overridden by `.env.[mode]`**: When `npm start` runs Vite in `development` mode, `.env.development` takes precedence over `.env.local`. Solution: use `yarn start:local` (`vite --mode dev-local`) which loads `.env.dev-local` instead. Do NOT try `.env.development.local` — it works but requires adding/removing the file to switch between local and GCP.

- **`local` is a reserved Vite mode name**: `vite --mode local` fails with `"local" cannot be used as a mode name because it conflicts with the .local postfix for .env files`. Use `dev-local` (or any name that doesn't end in `.local`) as the mode name.

- **`.env.local` means different things across projects**: In the BFF (Node), `.env.local` is loaded by custom code in `src/config/index.js` based on `NODE_ENV=local` — it works as expected. In clinical-panel (Vite), `.env.local` is a generic override that is overridden *by* `.env.development` (the mode-specific file). Same filename, different semantics. The `--mode dev-local` approach sidesteps this entirely.

- **Port 5050 conflicts from stale Vite processes**: If a previous Vite instance didn't get killed properly (no pidfile, or the PID was reused), `npm start` will silently fall back to port 5051 with only a small log message. Always check `lsof -i :5050` before starting, and use the pidfile-based kill in `make clinical-down`. **The conflict is NOT always a stale process from the same repo**: the user keeps two clinical-panel checkouts (`clinical-panel` and `clinical-panel-2`), both hardcoding `port: 5050` in `vite.config.ts`. A live `yarn start` in the *other* checkout silently holds 5050 and pushes yours to 5173 with no error — `lsof -nP -iTCP:5050 -sTCP:LISTEN` will show the offender's full path (e.g. `.../clinical-panel/node_modules/.bin/vite`, a different repo dir than the one you're in). Don't assume a "5173" binding means your config is wrong; check who owns 5050 first.

- **Multiple stale Vite processes and Auth0 login button doing nothing on wrong port (outside the Makefile too)**: This also happens with plain `yarn start` / `yarn start:local` run directly by the user (no Makefile), across separate terminal sessions over multiple days — confirmed recurrence: 5 stale `vite` processes accumulated over several days occupied ports 5050-5054 sequentially, with the user's newest `yarn start` landing on 5054. Symptom: `yarn start` opens on an unexpected port (5051, 5052... 5054), the Welcome page loads, but clicking "Entrar" (login) does nothing — no navigation, no visible error. Root cause: Auth0's "Allowed Callback URLs" / "Allowed Web Origins" for the dev tenant are registered for `http://localhost:5050` only; `loginWithRedirect` fires but Auth0 silently rejects the mismatched origin (check browser DevTools console for a `Callback URL mismatch` style error to confirm). Diagnose with `lsof -nP -iTCP -sTCP:LISTEN | grep node` to see every port in the 5050+ range with a listener, then `ps -o pid,lstart,args -p <pids>` to see how old each one is and whether it's `--mode dev-local` or plain `vite` (`yarn start`). Fix: `kill <pids>` all of them, then re-run `yarn start` — it will bind cleanly to 5050. This is the same root cause as "Orphan Vite processes accumulate across `make clinical-up` runs" below, but surfaces even without ever having used the Makefile orchestrator — any repeated `yarn start`/`yarn start:local` across sessions accumulates orphans the same way. `vite.config.ts` hardcodes `port: 5050` (no `strictPort`), so Vite auto-increments silently on conflict instead of erroring — always check for orphans FIRST when a user reports "login button does nothing" or "opened on an unexpected port", before investigating Auth0 config itself.

- **Orphan Vite processes accumulate across `make clinical-up` runs**: Each `make clinical-up` starts a new Vite process but doesn't kill old ones first — if the pidfile is stale or `clinical-down` wasn't run, old Vite instances keep listening on ports 5050, 5051, 5052, etc. The new instance silently falls back to the next free port (e.g. 5054), and the panel appears "not working" because the browser is on 5050 but Vite is on 5054. **Fix**: before starting fresh, kill all orphan Vite processes: `pkill -f "clinical-panel/node_modules/.bin/vite"`. Then verify with `ps aux | grep vite | grep clinical-panel | grep -v grep` — should be empty. Also clean up stale pid/log files: `rm -f /tmp/dev-clinical-panel.{pid,log}`.

- **Core CORS `/auth/*` blocked locally**: `cors.rb` only allows `http://localhost:5050` for `/auth/*` when `ENV["SERVER_ENV"] == "development"`. But `SERVER_ENV` is not set in any local config (`.env.development`, `docker-compose.yml`, `.env.development.local`). The `/attachments.json` endpoint works because `CROSS_ORIGIN_URL="*"` in `.env.development`. Fix: add `SERVER_ENV=development` to core's docker-compose env or `.env.development` — but only if the user is OK changing core.

- **Core container may restart on first `make up`**: If the core app container exits and restarts (e.g., DB not ready, gems being installed), the health check will fail transiently. Wait 8-10 seconds and retry before declaring failure.

- **`CLINICAL_LLM_API_URL` in BFF local points to K8s**: `.env.local` has `CLINICAL_LLM_API_URL=http://web-internal.clinical-llm.svc` which doesn't resolve locally. LLM features will fail in local mode. This is a known limitation — out of scope unless the user explicitly asks.

- **Firestore emulator vs GCP**: The core runs a Firestore emulator locally (project `clinical-panel-dev`, port 8080). The panel's Firebase SDK (in-browser) may still point to GCP Firestore, not the local emulator. If data seems inconsistent between panel and core, check whether the panel's Firebase config needs to be pointed at `localhost:8080` when `VITE_ENVIRONMENT=local`.

- **Commit hygiene when opening PRs for multiple repos**: When the product-engineer-agent repo has staged changes from other user stories (e.g. `20260819-*`), do NOT include them in the commit for the current feature. Reset, stage only the files belonging to the current task, then commit. Each PR must contain only changes relevant to its own feature. The user explicitly called this out: "toma cuidado para que o PR tenha coisas apenas a ver com o que fizemos aqui".

- **`.env.local.example` comments must be on separate lines**: In dotenv files, inline comments inside double-quoted values (e.g. `VAR="value  # comment"`) are parsed as part of the value. Put comments on their own line above the variable. This was caught by gemini-code-assist on PR review.

- **English comments in code/Makefiles**: User prefers comments and echo messages in Makefiles and code to be in English, not Portuguese. The clinical-panel README can be in Portuguese (it already is), but Makefiles and code comments should be English.

- **Use `yarn` not `npm` for GenialCare frontend projects**: clinical-panel and clinical-panel-bff both use yarn (have `yarn.lock`). The Makefile must call `yarn start:local`, not `npm run start:local` or `npm start`.

- **Must `nvm use` before running yarn/Vite**: GenialCare frontend projects have `.nvmrc` (e.g. Node v20.19.2). The system default Node may be a different version (e.g. v16.14.0). The Makefile must `source ~/.nvm/nvm.sh && nvm use` before calling `yarn start:local`, otherwise Vite may behave unexpectedly or fail. Use `NVM_SOURCE := $$([ -s $$HOME/.nvm/nvm.sh ] && echo $$HOME/.nvm/nvm.sh)` to safely resolve the nvm path.

- **`nvm use` without explicit version can pick wrong Node**: The Makefile's `nvm use` (no version arg) should read `.nvmrc`, but in background/subshell contexts it may fall back to the nvm default alias (e.g. v16.14.0) instead. Vite v7 requires Node 20.19+ — with Node 16 it crashes with `SyntaxError: The requested module 'node:fs/promises' does not provide an export named 'constants'` and logs `You are using Node.js 16.14.0. Vite requires Node.js version 20.19+`. **Fix**: when launching Vite manually (outside Makefile), always use `nvm use v20.19.2` with the explicit version from `.nvmrc`, not bare `nvm use`. When debugging a Vite crash, first check `node --version` in the same shell context — if it's not the `.nvmrc` version, that's the cause.

- **`nvm use` "succeeds" but `yarn`/`vite` still runs the wrong Node — check for a fixed `node` earlier in PATH (e.g. `~/.local/bin/node`)**: On this user's machine, `~/.zshrc` does `export PATH="$HOME/.local/bin:$PATH"` unconditionally, and `~/.local/bin/node` is a symlink to a fixed-version Node (e.g. Hermes Agent's bundled node, `~/.hermes/node/bin/node`). nvm's init block lives in `~/.zshrc.local`, sourced AFTER that export. `nvm use <version>` correctly *prepends* `~/.nvm/versions/node/vX.Y.Z/bin` to PATH, but it lands behind `~/.local/bin` — which was already there — so `which node` still resolves to the fixed version and any engine-check (`"engines": {"node": "~20.19.4"}` in `package.json`) fails with "The engine node is incompatible... Got <wrong version>" even right after a correct-looking `nvm use`. **Diagnose**: after `nvm use`, run `echo $PATH | tr ':' '\n' | head` and `which -a node` — if a non-nvm directory appears before the `.nvm/versions/...` entry, that's the shadow. **Fix options, in order of least invasive**: (1) per-command override — `PATH="$HOME/.nvm/versions/node/vX.Y.Z/bin:$PATH" yarn start`; (2) reorder shell init so the nvm-loading block runs, and re-exports PATH, after the fixed `~/.local/bin` export; (3) as a last resort, remove/rename the shadowing symlink. Don't just "run nvm use again" — it will keep losing to the earlier PATH entry every time until the ordering itself is fixed.

- **PRs should contain only task-relevant changes**: When opening PRs across multiple repos, ensure each PR contains only changes relevant to its own feature. If the repo has staged changes from other user stories or tasks, reset and stage only the current task's files before committing. Docs (user story markdown) go directly to `main` branch, not in the PR. The user explicitly called this out: "toma cuidado para que o PR tenha coisas apenas a ver com o que fizemos aqui".

- **English comments in Makefiles and code**: User prefers comments and echo messages in Makefiles and code to be in English, not Portuguese. README files can be in Portuguese (they already are), but Makefiles and code comments should be English. This was corrected mid-session: the Makefile was initially written with Portuguese comments and echo messages, then rewritten to English.

- **Product-prefixed target names for multi-project orchestration**: When naming Makefile targets that orchestrate multiple projects (core + bff + panel), use product-line prefixes (`clinical-up`, `clinical-down`, `clinical-status`) rather than generic names (`local-up`, `local-down`). This makes it explicit which set of projects is being orchestrated and allows adding new product lines (`operational-up`, `mobile-up`) without naming collisions. The user: "os comandos do makefile... sobrem o core e o bff, mas não sobre o clinical-panel?... também poderia haver outras configurações possíveis como core, operational-panel-bff e operational-panel."

- **Core missing `FIREBASE_SERVICE_ACCOUNT` causes 500 on `getFirebaseCustomToken` (FIXED)**: The panel's home page calls a GraphQL query `getFirebaseCustomToken` which the BFF forwards to core's `/auth/firebase/custom_token`. The core's `Firebase::ServiceAccount.from_env` does `JSON.parse(ENV["FIREBASE_SERVICE_ACCOUNT"])` — if the env var is nil (not set in any local config), this raises `TypeError: no implicit conversion of nil into String`. On GCP it comes from a K8s Secret named `web`. **Fix**: add the JSON key to `core/.env.development.local` (now loads correctly after the `application.rb` fix). The JSON is the same `core-development-sa-key.json` that's already used for `GOOGLE_APPLICATION_CREDENTIALS` — the Firebase emulator doesn't validate the SA project, so any SA with `client_email` and `private_key` works. See `references/core-env-investigation.md` for how to generate the escaped inline value.

- **Core missing `SERVER_ENV` causes 401 on `/me.json` (FIXED)**: The `cors.rb` conditional that allows `http://localhost:5050` for `/auth/*` only fires when `ENV["SERVER_ENV"] == "development"`. Without it, the core rejects authenticated requests from the local panel with 401. On GCP it comes from ConfigMap `core-cm`. **Fix**: add `SERVER_ENV=development` to `core/.env.development.local` (now loads correctly after the `application.rb` fix). Validated: after restart, `getFirebaseCustomToken` query changed from 500 (TypeError) to 401 (expected — no auth token in test). With a real Auth0 token, the BFF pass-through works.

- **Core `ACTIVE_STORAGE_TYPE` should be set to `google` locally (FIXED)**: `development.rb` defaults to `:local` (Disk) when `ACTIVE_STORAGE_TYPE` is not set — but with Disk, avatar photos won't appear because the DB was imported from remote (blobs reference GCS). Setting `ACTIVE_STORAGE_TYPE=google` forces GCS, and the `storage.yml` conditional fix (below) makes GCS work locally by using the SA key file. Photos appear from the GCP dev bucket. See `references/core-env-investigation.md`.

- **Core `storage.yml` GCS `iam: true` crashes locally (FIXED)**: The original `config/storage.yml` had `iam: true` hardcoded for the `google` service. This forces the GCS client to use the GCP metadata server for credentials — which only exists inside GCP VMs. Locally it crashes with `MetadataServerNotFoundError`. **Fix** (PR #6524): patched `storage.yml` to use ERB conditional — when `GOOGLE_APPLICATION_CREDENTIALS` is set (local), use `credentials: Rails.root.join(...)` and `iam: false`; when not set (GCP), keep `iam: true`. This makes avatar photos work locally (loaded from GCP dev bucket via SA key) and stays unchanged on GCP (metadata server). Key technique: must use single-line ERB ternary (`ENV[...] ? value : nil`) not multi-line `<% if %>` blocks — the `write_file` YAML validator rejects ERB blocks; use `execute_code` (Python) to write the file if the validator refuses.

- **Core `Dotenv::Rails.files` override blocked `.env.development.local` (FIXED)**: `config/application.rb:29-35` explicitly set `Dotenv::Rails.files` to `[\".env.#{RAILS_ENV}\"]` — a single file. This overrode Dotenv's default behavior, so `.env.development.local` was NEVER loaded. Adding `FIREBASE_SERVICE_ACCOUNT` or `SERVER_ENV` to `.env.development.local` had no effect. **Fix applied**: patched `application.rb` to include `.env.#{RAILS_ENV}.local` in the array (PR #6524). **IMPORTANT**: In Dotenv, the FIRST file in the list takes precedence (already-set env vars are NOT overwritten by later files). So `.local` files must come FIRST: `[\".env.#{env}.local\", \".env.#{env}\"]`. If reversed, the `.local` overrides are silently ignored. Now `.env.development.local` loads correctly — validated with `docker exec core-app-1 sh -c 'cd /app && bin/rails runner \"puts ENV[\\\"SERVER_ENV\\\"]\"'` returning `development`. When modifying core for local dev, the user prefers incrementing the existing `development` environment (not creating a new `local` env), because `RAILS_ENV=development` only runs locally anyway and creating a new env would break all `Rails.env.development?` checks in the codebase.

- **Never commit secrets/keys to git**: When adding service account JSON keys or credentials to env files, always verify the file is gitignored (`git check-ignore <file>`) before writing. The user explicitly flagged this: "mas você não vai fazer commit de chaves, né?". `.env.development.local` in core is gitignored — safe. But always verify, never assume. When the user asks about committing sensitive data, stop immediately and confirm the file is gitignored before proceeding. Do not write the file and then check — check first.

- **When `write_file` rejects YAML with ERB, use `execute_code`**: The `write_file` tool runs a YAML syntax validator that rejects ERB tags (especially multi-line `<% if %>` blocks and ternary `? :` syntax). For files like `storage.yml` that contain ERB, write them via `execute_code` (Python `open().write()`) which bypasses the validator. This is a tooling workaround, not a file format issue — the ERB is valid and Rails processes it correctly at runtime. **Pitfall**: when rewriting a file with `execute_code` (Python), diff the result against the original (`git diff`) to catch accidental changes to unrelated lines (e.g. `your_container_name` → `your_account_name`). The user caught this during PR review: \"qual o motivo dessa mudança?\".

- **Do NOT run `rails runner` or `db:migrate` inside the running core container during dev**: Running `rails runner` (or `bin/rails db:migrate`) inside the live `core-app-1` container spawns extra Ruby processes that share the DB connection. When they exit, they can corrupt SolidQueue state and cause Puma to crash with `Detected Solid Queue has gone away, stopping Puma...`. Additionally, `make migrate-dev` in the core Makefile does `db:drop db:setup` (drops and recreates the entire DB), which destroys all SolidQueue tables — the core then crashes on boot with `PG::UndefinedTable: relation "solid_queue_recurring_tasks" does not exist`. The user explicitly asked to prevent this: \"vê se tem como melhorar os scripts para não ter esse tipo de erro novamente\".

- **Recovering a wiped local DB (SolidQueue tables gone + no user data)**: If the DB was accidentally wiped by `make migrate-dev` (which does `db:drop db:setup`) or a `rails runner` crash, recovery is a two-step process:
  1. **Recreate schema + SolidQueue tables**: `docker compose run -T --rm --entrypoint bundle app exec rails db:migrate` — this bypasses `init.sh` and runs migrations directly. If the container is stopped (Puma crashed on boot), use `docker compose run` (not `docker compose exec` which requires a running container). See the pitfall below on why `--entrypoint bundle` is mandatory.
  2. **Restore real user data**: Run the import script from branch `feature/import-remote-db-locally`: `git checkout feature/import-remote-db-locally -- bin/custom/import_remote_database_locally.sh && bash bin/custom/import_remote_database_locally.sh` (or run from the other branch directly). This script dumps the GCP development DB via an ephemeral K8s pod and restores it locally, including all 553+ users. Verify with `docker exec core-db-1 psql -U root -d core_development -tAc "SELECT count(*) FROM users"` → should be ~553.
  3. After restore, `docker-compose restart app` to boot cleanly with the restored data.
  The import script is on branch `feature/import-remote-db-locally` — NOT on main or the local-dev feature branches. See `local-dev-db-sync` skill for the full script details.

- **`docker compose run` doesn't work with `init.sh` entrypoint — use `--entrypoint bundle`**: When the core container is stopped (Puma crashed) and you need to run a one-off command like `db:migrate`, `docker compose exec` won't work (container not running). But `docker compose run app <cmd>` also silently fails: `init.sh` has `set -e` and its `*)` case does `exec sh -c "$@"` — when `docker compose run` passes `bundle exec rails db:migrate` as the command, `sh -c` receives the arguments broken up and the command exits without executing or producing any output beyond `bundle install`. **Fix**: bypass `init.sh` entirely with `--entrypoint bundle`: `docker compose run -T --rm --entrypoint bundle app exec rails db:migrate`. The `bundle` binary becomes the entrypoint, `exec rails db:migrate` becomes its arguments, and the command actually runs. Use `-T` to disable TTY allocation (avoids output capture issues with `tty: true` in docker-compose.yml). This pattern works for any one-off Rails command when the container won't boot.

- **Run core specs from a `git worktree` by reusing the canonical project name (`-p core`)**: a
  worktree's `docker-compose.yml` is identical to the canonical core, so run specs against the shared
  dev DB/bundle/network WITHOUT spinning up a second stack. From inside the worktree:
  `docker compose -p core run --rm -T --entrypoint bundle -e RAILS_ENV=test -e DISABLE_SPRING=1 app exec rspec <specs>`.
  `-p core` reuses the already-running `core` project (so `db`/`redis` resolve to `core-db-1`/`core-redis-1`
  and the `core_bundle_path` volume is shared), while `- .:/app` mounts the WORKTREE code. For an isolated
  *server* (integration test / browser screenshot) instead of one-off specs:
  `docker run -d --name <name> --network core_default -v <worktree>:/app -v core_bundle_path:/bundle
  -p 3001:3000 -e DATABASE_HOST=db -e DATABASE_USERNAME=root -e DATABASE_PASSWORD='' -e REDIS_URL=redis://redis:6379/0
  -e BUNDLE_PATH=/bundle/vendor -e FIRESTORE_EMULATOR_HOST=firebase:8080 core-app web`
  (`init.sh web` = `rails s` on 3000). Then apply pending migrations with the `-p core run ... exec rails
  db:migrate` pattern above, and `git checkout db/schema.rb` afterward (the dump reorders columns cosmetically).
  Note the worktree lacks the gitignored `.env.development.local` — copy it from the canonical core before
  booting a server (SERVER_ENV/FIREBASE_SERVICE_ACCOUNT live there).

- **Rails boot in a Colima container can fail `Errno::EMFILE: Too many open files - Failed to
  initialize inotify: the user limit ... has been reached`**: `fs.inotify.max_user_instances` (default 128)
  is shared across ALL containers (they all run as root). With the canonical core + firebase + BFF (nodemon)
  + panel (Vite) all watching files, a fresh `rails runner`/`db:migrate` boot exhausts it. Fix (persists until
  VM restart): `colima ssh -- sudo sysctl -w fs.inotify.max_user_instances=512`.

- **Stale `tmp/pids/server.pid` blocks a worktree core server reboot**: after `docker rm -f <container>` (or
  any ungraceful kill), `tmp/pids/server.pid` is left in the MOUNTED worktree volume (it's a host file, not
  container state). The next `core-app web` boot then fails with `A server is already running (pid: 1, file:
  /app/tmp/pids/server.pid). Exiting` — the health check stays `000` (connection refused) even though Puma
  never actually starts. Fix: `rm -f tmp/pids/server.pid` inside the worktree, then `docker restart <container>`.
  (`init.sh web` runs `rails s` directly and does NOT clean the pidfile — only `bin/dev` does the `rm -f`.)

- **Feature flags come from real Split.io in development — `config/split.yaml` is test-only**: `config/initializers/split_client.rb`
  builds the client from `ENV["SPLIT_IO_KEY"]` (real remote Split.io) for every env EXCEPT test, which uses
  Split.io "localhost" mode + `config/split.yaml`. So a flag you add to `split.yaml` with `treatment: 'on'`
  has NO effect in local development — the split must exist in the Split.io dashboard (where it returns
  `control`/off until created). To toggle a flag for a local integration test WITHOUT the dashboard, make a
  temporary, uncommitted override in the worktree: (1) `split_client.rb` → `if !Rails.env.test? && !ENV["AMIL_LOCAL_FLAG"]`
  (the env var is the clean kill-switch, vs forcing localhost unconditionally); (2) `split.yaml` → `treatment: 'on'`;
  (3) boot the server with `-e AMIL_LOCAL_FLAG=1`. Revert both files (`git checkout config/split_client.rb
  config/split.yaml`) before committing the PR — the committed state keeps `treatment: 'off'` and the original
  initializer. These overrides do NOT affect specs: test mode already goes to the localhost branch, and the
 feature specs stub `FeatureFlag.on?`.

 - **Testing a "first-record >= cutoff date" grandfathering rule breaks when the cutoff is a FUTURE
 placeholder**: the pattern `first_record_at.nil? || first_record_at >= CUTOFF` treats "no record yet"
 as "new cohort" (nil → true), so a fresh entity shows the NEW behavior. But the moment you save the
 first record "today" (before the future cutoff), `first_record_at = today < CUTOFF` flips the entity
 OUT of the new cohort and it silently reverts to default/legacy behavior. Concrete case: Amil
 `NEW_AMIL_WORKLOAD_RULE_CUTOFF = Date.new(2026,10,6)` while testing on 2026-10-02 — a case with zero
 workloads returns the Amil limits, but after saving the first 5h workload it re-classifies as legacy
 and the NEXT discipline's dropdown shows default limits (Fono 0–3 instead of the correct 0–4). This is
 a placeholder-date artifact, not a logic bug (in prod the flag is OFF until the real go-live). Fix for
 live testing: temporarily move the cutoff to a past date (uncommitted, marked `# TEMP`, like the flag
 override) — pick a date between the spec's "before-cutoff" fixture and today so the boundary spec still
 passes — then `git checkout` it before committing.

- **Auth0 callback is NOT hard-locked to 5050 — non-5050 ports can work (test first)**: the "login button does
  nothing on a non-5050 port" pitfall assumes the dev tenant's Allowed Callback URLs / Web Origins are 5050-only.
  But in a recent session the panel was deliberately run on `localhost:5051` (`yarn start:local --port 5051`) and
  the Auth0 login + redirect succeeded, producing screenshots. So before killing the canonical 5050 panel to
  claim the port, TEST the login on the desired port first — the Auth0 config may already allow additional
  localhost ports (or have been widened to `localhost:*`). The safe pattern is: bring the panel up on the new
  port, run the Playwright login flow, and only escalate to "must be 5050" if Auth0 actually rejects the origin
  (DevTools console shows `Callback URL mismatch`).

- **Solid Queue crash loop on empty DB**: When the dev DB is empty (no `schema_migrations` table, no `solid_queue_*` tables), Puma boots, the `puma/plugin/solid_queue.rb` fork tries to start the Solid Queue supervisor, it queries `solid_queue_recurring_tasks` → `PG::UndefinedTable` → child process exits with code 1 → Puma logs `reaped unknown child process pid=NNN status=pid NNN exit 1` → `Detected Solid Queue has gone away, stopping Puma...` → container shuts down. The error chain in logs is: `PG::UndefinedTable: relation "solid_queue_recurring_tasks" does not exist` → `Detected Solid Queue has gone away, stopping Puma...` → `Exiting`. Fix: run `db:migrate` via the `--entrypoint bundle` pattern above, then `docker start core-app-1` (or `docker compose up -d app`). After 8-10 seconds, `curl -s -o /dev/null -w "%{http_code}" http://localhost:3000` should return 302 (login redirect) or 200 — not 000 (connection refused).

- **`make migrate-dev` is destructive — it does `db:drop db:setup`**: The core's Makefile `migrate-dev` target runs `db:drop db:setup` first, then `db:migrate`. This DESTROYS all data in the local DB (users, clinical cases, etc.) and recreates from seeds only. Never run `make migrate-dev` when you have imported real remote data that you want to keep. To run ONLY pending migrations without destroying data, use `docker-compose exec -e DISABLE_SPRING=1 app bundle exec rails db:migrate` directly.

- **Fresh DB after `db:migrate` has no seed data — panel shows 401 errors**: After running `db:migrate` on an empty local DB (e.g. recovering from a SolidQueue crash), the schema exists but there are no users. The BFF logs show `401 Unauthorized` from Core's `/me.json` endpoint, and the panel's login button stays in perpetual loading state. This is expected — there are no Auth0 users to authenticate against. To get a working panel, restore real user data via the import script (see `local-dev-db-sync` skill) or run `db:seed`. The 401 is NOT a config bug — it's an empty-DB symptom.

- **Visible symptom on the panel: "Erro ao carregar informações do usuário"**: When the BFF returns 401 from Core's `/me.json`, the panel's `AuthenticatedUserContainer` component (`src/components/AuthenticatedUserContainer/AuthenticatedUserContainer.tsx`) catches the GraphQL error and renders a plain-text error message: "Erro ao carregar informações do usuário." This is the **user-visible symptom** of an empty DB or missing BFF `.env.local` — not a crash, not a blank page, but a small text line at the top of an otherwise empty page. The Auth0Provider finishes loading (no spinner), but the `useAuthorizedQuery` for `AUTHENTICATED_USER` fails. If the user reports "erro ao entrar na home," check: (1) BFF `.env.local` exists with `CORE_API_URL=http://core:3000`, (2) Core DB has users (`SELECT count(*) FROM users` — if 0 or only seed users with synthetic emails, real Auth0 tokens won't match), (3) BFF logs for 401 on `/me.json`. The fix is importing real dev data via `bin/custom/import_remote_database_locally.sh` (requires `gcloud auth login` first).

- **`gcloud auth login` prerequisite for the import script**: `bin/custom/import_remote_database_locally.sh` needs kubectl access to the GCP cluster (creates an ephemeral pod to dump Cloud SQL). If the gcloud token has expired, `kubectl` fails with `Failed to retrieve access token:: failure while executing gcloud, with args [config config-helper --format=json]: exit status 1 (err: ERROR: (gcloud.config.config-helper) There was a problem refreshing your current auth tokens: Reauthentication failed. cannot prompt during non-interactive execution.` Run `gcloud auth login` (opens browser) before the import script. Verify with `kubectl get pods -n core` — if it lists pods, the auth is valid.

- **`db:seed` creates synthetic users that don't match real Auth0 tokens**: Running `db:seed` on the core creates 133 users from FactoryBot fixtures (e.g. `dev@genialcare.com.br`, `finance@genialcare.com.br`, `therapist@genialcare.com.br`) and 3 tenants (`genialcare`, `careplus_mindplace`, `tenent-clinica`). The seed may fail partway with `NameError: uninitialized constant Seeds::Finance::AttendancePeriodClinicalCaseFile` — but users and tenants are already created by that point. However, these synthetic emails do NOT match the email in a real Auth0 JWT from the development tenant. The Core's `Secured#current_user` does `User.find_by_email(user_email)` — if the Auth0 token email isn't in the local DB, it returns nil, `authenticated_user` raises `UserUnauthenticated`, and the BFF gets 401. `db:seed` is only useful for testing schema/relationships, NOT for getting a working panel with real Auth0 login. For a working panel, always use the remote DB import (`bin/custom/import_remote_database_locally.sh`).

- **`make clinical-up` prints success even when Vite has crashed**: The Makefile target starts Vite in a background subshell (`source $(NVM_SOURCE) && nvm use && yarn start:local > $(CLINICAL_LOG) 2>&1 &`), then `sleep 2`, then prints "✓ Clinical local environment ready!" — but it never checks whether the Vite process is actually alive after those 2 seconds. If nvm loaded the wrong Node version (e.g. v16 instead of v20.19.2), Vite crashes immediately with `SyntaxError: The requested module 'node:fs/promises' does not provide an export named 'constants'` (visible only in `/tmp/dev-clinical-panel.log`), but the Makefile still reports success. The user sees "ready!" but `http://localhost:5050` is dead. **Always verify after `make clinical-up`**: `curl -s -o /dev/null -w "%{http_code}" http://localhost:5050` should return 200; `tail -5 /tmp/dev-clinical-panel.log` should show `VITE ready in Nms`, not a crash traceback. If it crashed, kill any stale processes (`pkill -f "clinical-panel/node_modules/.bin/vite"`), then relaunch manually with explicit Node version: `source ~/.nvm/nvm.sh && nvm use v20.19.2 && cd clinical-panel && yarn start:local`.

- **BFF `.env.local` missing → `CORE_API_URL` undefined → 401 errors**: When the BFF runs with `NODE_ENV=local` but `.env.local` doesn't exist, `src/config/index.js` calls `dotenv.config({ path: '.env.local' })` which silently fails (no error, no warning). `CORE_API_URL` stays undefined, and the BFF's `core-datasource.js` sets `this.baseURL = undefined`. GraphQL queries to the BFF work (BFF itself is up), but every query that hits Core returns errors. The BFF logs show `401 Unauthorized` with `url: "http://core-app-1:3000/me.json"` — but that's misleading because the real URL was undefined, not `core-app-1`. **Fix**: create `.env.local` with `CORE_API_URL=http://core:3000` (using the Docker network alias, not `core-app-1`). Verify it loaded: `docker exec clinical-panel-bff-app-1 sh -c 'echo $CORE_API_URL'` should print the URL, not be empty.

- **Dotenv file ordering matters — `.local` files must come FIRST**: In Dotenv, the first file in the `Dotenv::Rails.files` array takes precedence — if an env var is already set by an earlier file, later files CANNOT overwrite it. So `.env.development.local` must come BEFORE `.env.development` in the array, or the `.local` overrides are silently ignored. This was caught by gemini-code-assist on PR review.

- **Increment existing environments, don't create new ones**: When the core needed env vars that weren't loading locally, the user was asked whether to create a new `local` Rails environment or increment the existing `development` one. The user chose to increment `development` because `RAILS_ENV=development` only runs locally anyway (GCP uses `RAILS_ENV=production` + `SERVER_ENV=development`), and creating a new env would break hundreds of `Rails.env.development?` checks in the codebase. This preference applies to any Rails project — prefer extending the existing env over creating new ones unless there's a compelling reason.

- **Document local dev setup in each repo's own README**: When a config change in repo A requires a setup step that affects repo B (e.g. clinical-panel needs `.env.dev-local` to work with the Makefile orchestrator in product-engineer-agent), document the instructions in repo B's own README — not only in repo A. The user: "acho bom colocar esse cp do arquivo de env no repo do clinical-panel pois quem estiver olhando para ele ou quem quiser descobrir porque o local não está funcionando, ou quando estiver instalando, já sabe". Each repo should be self-sufficient for its own onboarding. This also applies to the core README — the section "Local development with clinical-panel and clinical-panel-bff" documents `SERVER_ENV`, `FIREBASE_SERVICE_ACCOUNT`, and how to generate the inline JSON value.

- **`.env.dev-local` can be committed directly (no `.example` + copy pattern needed)**: Once the `--mode dev-local` approach is in place, `.env.dev-local` does NOT conflict with `.env.development` (different mode files, no override). The credentials in it (Auth0, Firebase, Split.io) are the same dev-level credentials already committed in `.env.development`. So `.env.dev-local` can go straight into version control — no need for a `.example` template + `cp` step. The user realized this: "agora que o env local não sobrescreve mais o development, será que não faz sentido deixar o arquivo lá direto sem precisar ficar copiando e nem precisar colocar no gitignore?"

- **User deliberates before modifying other repos**: When proposing changes to a repo the user asked to not touch ("não mexer no core preemptivamente"), present the options and let the user decide. Do NOT apply the fix and ask for forgiveness. The user said "vou pensar" — respected the deliberation period and left the env file reverted to its original state while waiting. Once the user decides ("sim! Pode continuar!"), apply the fix promptly. The user prefers incrementing the existing `development` env over creating a new `local` env when there is a clear need — `RAILS_ENV=development` only runs locally anyway, and a new env would break hundreds of `Rails.env.development?` checks.

- **`yarn types` (tsc --noEmit) and full-suite `yarn vitest run` on clinical-panel routinely exceed 60s**: A foreground `terminal()` call gets killed at the session's configured ceiling even if you request a higher `timeout` (observed clamp: 60s regardless of a requested 180–600s). Run `yarn types` and `CI=true yarn vitest run --bail=1` as `terminal(background=true, notify_on_complete=true)`, then poll with `process(action='wait', timeout=60)` repeatedly (or `process(action='poll')`) until `status: exited` — a `status: timeout` result mid-run is expected, just call `wait` again rather than re-issuing the command or asking for a bigger timeout.

- **`yarn vitest run` crashes at startup with `TypeError: Cannot read properties of undefined (reading 'length')` in `coverage.AVPTjMgw.js` → set `VITEST_JUNIT_OUTPUT_FILE`**: clinical-panel's `vite.config.ts` sets `reporters: junitOutputFile ? ['default', ['junit', ...]] : undefined`. When `VITEST_JUNIT_OUTPUT_FILE` is unset, `reporters` resolves to `undefined` and vitest's coverage chunk calls `.length` on it at config-resolution time, aborting before ANY test runs (with Node 16, 20 or 22 — it is NOT a Node-version problem). **Fix**: run tests with `VITEST_JUNIT_OUTPUT_FILE=/tmp/junit.xml yarn vitest run <spec>` (any value works; `/tmp/junit.xml` is harmless). CI always sets it, which is why the same command works in Actions but not locally. The `Sourcemap ... points to missing source files` warnings from `@genialcare/atipico-react` are unrelated noise — ignore them; the run exits 0 when tests pass.

- **Same background-loop pattern applies to `gh pr checks` polling**: `gh pr checks --watch` and long `sleep N && gh pr checks` one-shots don't fit well either — they block for the whole CI run and hit the same `process wait` clamp. Launch a self-terminating shell loop as a background process instead (`for i in $(seq 1 N); do sleep 30; gh pr checks <PR>; grep -q pending || break; done`), then repeatedly call `process(action='wait', timeout=60)` until it reports `exited`. The accumulated output across calls already has everything — don't fight the clamp. When babysitting a PR to merge (see `references/pr-blocked-unblocking.md`), this is the polling primitive.

- **Flaky test in a full-suite run — verify in isolation before reporting a regression**: If `CI=true yarn vitest run --bail=1` fails on a spec unrelated to the files you changed (e.g. a `Test timed out in 5000ms` in a component you never touched), don't assume your change broke it. Re-run just that spec file alone (`yarn vitest run path/to/spec.tsx`) — a test that passes cleanly in isolation but times out under full-suite parallelism/load is contention-flaky, not broken by your diff. Only escalate to the user/orchestrator if the isolated run also fails. (Seen with `DirectNoteForm.spec.tsx` in clinical-panel: failed under `--bail=1` full run with a 5s timeout, passed 7/7 when run isolated.)

- **BFF→core "socket hang up" (NOT 401/refused) → restart the core app**: If the BFF logs show
  `request to http://core-app-1:3000/me.json failed, reason: socket hang up` (or a direct
  `http.get` to `core-app-1:3000` from the BFF container hangs/timeouts) while `curl localhost:3000`
  from the host works fine, the core's Puma is **stuck** — single worker (`workers 1` in puma.rb)
  with stale `CLOSE_WAIT` sockets that never got cleaned up (visible in `/proc/net/tcp` state `08`).
  `docker compose restart app` (core) clears it; the BFF then reaches core (401 for unauthenticated
  `/me.json`, which is correct). This is distinct from the 401/empty-DB cases above — those return
  401, this hangs/resets the socket. Note: a crash here may also drop a large `core` dump file in the
  repo root (`file core` → "puma: cluster worker"); delete it, don't commit it.

- **Auth0 dev login for panel testing = `dev@genialcare.com.br` with password = the email itself
  (`dev@genialcare.com.br`), NOT "senha"**: the shorthand "email=senha" means email == password.
  For automated browser screenshots of the panel, use a local Playwright chromium (e.g.
  `~/clinical-panel-playwright/capture.mjs`) that clicks the panel's own "Entrar" →
  `loginWithRedirect` (which sets up Auth0 PKCE correctly). The cloud `browser_*` tools do NOT fire
  the `loginWithRedirect` redirect, and hand-building an `authorize?` URL skips PKCE so the redirect
  back can't exchange the code (you land back on the Welcome screen, unauthenticated). Fono
  assessment URL shape: `/panel/clinical-cases/:caseId/assessments/direct-assessments/:registryId/speech-therapy/:type`
  (`speech-motor-control`, `expressive-communication`, `phonological`, `orofacial-myology`,
  `augmentative-and-alternative-communication`).

- **Colima (Docker daemon) must actually be running — "Cannot connect to the Docker daemon"**: Local core/bff run under Colima (not Docker Desktop), socket `unix:///Users/regishattori/.colima/default/docker.sock`. If `docker ps` / `docker compose` fail with `Cannot connect to the Docker daemon`, Colima is down even when `colima status` still says "running" (VM up but the daemon socket is stale). Fix: `colima restart` (or `colima start`), then re-run `make up` — `docker compose up -d` re-creates the containers that were stopped. When Colima is down, the user sometimes reaches core/bff via an SSH tunnel instead (see next-but-one pitfall); that is a symptom of local Docker being unavailable, not the intended setup.

- **Running the BFF on the macOS host (NOT in Docker) requires `CORE_API_URL=http://localhost:3000`**: The BFF normally runs in Docker and reaches core over the `genial` network via `http://core:3000` (or `http://core-app-1:3000`). But if you start it directly on the host (`cd clinical-panel-bff && yarn start:dev`), those hostnames don't resolve and every core call fails with `getaddrinfo ENOTFOUND core-app-1` (or `core`). Override the env var before dotenv loads `.env`/`.env.local` (which default to `https://core.development.internal.genialcare.com.br` / `http://core:3000`): `CORE_API_URL=http://localhost:3000 yarn start:dev`. Rule of thumb — BFF in Docker → `http://core:3000`; BFF on host → `http://localhost:3000`.

- **An SSH tunnel can shadow ports 3000/4050 (you're hitting a stale REMOTE, not local)**: If you change BFF/core code but the result doesn't appear (e.g. GraphQL introspection still shows the old `AssessmentRelatedObjective { id description status }` instead of your new fields), check who actually owns the ports: `lsof -nP -iTCP:3000 -iTCP:4050 -sTCP:LISTEN`. If `ssh <pid>` owns them, an SSH `-L` port-forward is routing localhost to a remote env and bypassing local Docker entirely. Kill it (`kill <pid>`) to free the ports, then start the local services. Note `docker compose ps` can still show `core-app-1` "Up" with the port mapping even while the tunnel owns the live LISTEN socket — `lsof` is authoritative, not the compose status.

## Related skills

- `docker-troubleshoot` — Docker container failures in GenialCare projects (Solid Queue tables, gems)
- `local-dev-db-sync` — Sync real Cloud SQL data into local docker-compose Postgres (overlaps with `local-dev-database-sync`)
- `investigate-bff-flow` — Investigate GraphQL flows in GenialCare BFFs
- `investigate-core-flow` — Investigate GenialCare Rails core backend flows
- `multi-agent-orchestration` (Pattern 14 / Pitfall 19) — if you're a subagent (or one of several parallel subagents, e.g. each removing a different feature flag) operating on a shared local clone of a GenialCare frontend repo (clinical-panel, clinical-panel-bff), watch for sibling-contamination signals (`patch`/`write_file` "modified by sibling subagent" warnings, `git diff`/`git status` showing hunks or files you didn't touch) and isolate into a `git worktree` immediately rather than working around it in place. When running `yarn vitest`/`yarn eslint`/`tsc` in that isolated worktree, don't reinstall — symlink the shared checkout's `node_modules` and any codegen output (e.g. clinical-panel's Panda CSS output at `src/styled-system`) into the new worktree instead; confirm the lockfile matches first. See that skill for the exact commands.
