---
name: genialcare-service-deploy
description: Deploy de BFFs GenialCare via GitHub Actions → GKE.
---

# Deploy de serviços GenialCare (mobile-bff / BFFs)

Fluxo de deploy dos serviços backend GenialCare (ex: `mobile-bff`) via GitHub Actions → GKE (kapp). NÃO confundir com a skill `genialcare-app-deploy` (apps estáticos mcp-genial) nem com `k8s-deployment-debugging` (debug de rollout).

## Terminologia crítica: "development" é um AMBIENTE, não uma branch

O `mobile-bff` **não tem branch `development`** (nem `develop`/`dev`). As branches são apenas `main` e `staging`.

`development` é o nome de um **ambiente GCP** (cluster GKE `kubernetes-development`, região `us-east1-c`), não de uma branch. Isso difere do repo `core`, que usa uma branch `development` como convenção — não transfira essa convenção entre repos.

## Fluxos de deploy (mobile-bff)

| Objetivo | Como disparar |
|---|---|
| Produção (staging → prod, automático em sequência) | push na `main` (`deploy.yaml`) |
| Ambiente development (GKE `kubernetes-development`) | `deploy-manually.yaml` via `workflow_dispatch`, apontando pra uma branch |
| Staging manual | `deploy-staging.yaml` via `workflow_dispatch` |

Workflows relevantes em `.github/workflows/`: `deploy.yaml` (push main), `deploy-manually.yaml` (manual → development), `deploy-staging.yaml` (manual → staging), `deploy-branch.yaml` (reusable `workflow_call`, tem o grosso da lógica).

Mapeamento display-name → filename do `gh workflow list` (os nomes exibidos NÃO são os arquivos):

| `gh workflow list` mostra | arquivo real |
|---|---|
| `Deploy branch manually` | `deploy-manually.yaml` |
| `Deploy` | `deploy.yaml` |
| `Deploy Staging` | `deploy-staging.yaml` |
| `Deploy branch` | `deploy-branch.yaml` |

Use `gh workflow view "<nome exibido>"` para confirmar o filename antes de `gh workflow run <arquivo>.yaml`.

### Deploy de uma branch de feature para o ambiente development

```bash
gh workflow run deploy-manually.yaml \
  --ref <branch> -f branchName=<branch>
```

- `--ref` = de qual ref o workflow file é lido (use a branch de feature, ou `main` para a versão estável do workflow).
- `branchName` = qual branch será deployada (é o que importa — o job faz checkout dela).
- Secret usado: `DEPLOY_DEVELOPMENT`.
- Requer `gh` autenticado com scope `workflow` (`gh auth status` deve listar `workflow`).

## PITFALL: nome de branch com `/` quebra o build Docker

O `deploy-branch.yaml` gera a tag da imagem como `{branchName}-{shortSHA}` (ex:
`mobile-bff:feat/in-maintenance-...-87cc1bd`). A `/` é interpretada como separador de
namespace em tags Docker → erro `invalid reference format`, e o build falha em ~30s.

**Use nome de branch SEM `/`** (hífens ou underscore): `feat-in-maintenance-...`, não `feat/in-maintenance-...`.

Para corrigir uma branch já pushada com barra:
```bash
git branch -m <novo-nome-sem-barra>
git push -u origin <novo-nome-sem-barra>
git push origin --delete <nome-antigo-com-barra>
gh workflow run deploy-manually.yaml -f branchName=<novo-nome-sem-barra>
```

## Verificar status do deploy

```bash
gh run list --workflow deploy-manually.yaml --limit 3
gh run view <run_id> --repo GenialCare/mobile-bff --json status,conclusion
gh run view <run_id> --log-failed   # diagnose falha; grep por error/failed/invalid
```

Deploy bem-sucedido leva ~3-4 min. Falha de build (tag inválida) falha em ~30s — sinal claro do pitfall acima.

## PITFALL: a coluna "branch" do `gh run list` mostra o ref de dispatch, NÃO o que foi deployado

Após disparar `gh workflow run deploy-manually.yaml -f branchName=<feature>`, o `gh run list` mostra `main` na coluna de branch — isso **não** significa que deployou a main. A coluna reflete o ref de onde o workflow file foi lido (o `--ref`, default `main`), não o input `branchName`. Os runs anteriores da mesma branch também podem aparecer inconsistentes.

Para confirmar a branch/commit REALMENTE deployados, leia o log do run e procure a tag da imagem:

```bash
gh run view <run_id> --log | grep -iE "tag=|branchName:|ref:|short HEAD"
# confirme algo como: mobile-bff:feat-in-maintenance-objective-in-progress-11ab65c
# e o diff do ytt mostrando a troca de versão: -0514a2a ... +11ab65c
```

O que importa: a tag da imagem (`{branchName}-{shortSHA}`) e a linha `ref=<branch>` do checkout. Se a tag bate com o commit que você acabou de dar push, deployou a branch certa — ignore o `main` da coluna.

## Testar localmente antes de deployar

```bash
cd mobile-bff && NODE_ENV=test yarn test --testPathPattern=<arquivo>   # jest é o teste canônico do CI
yarn lint
yarn tsc --noEmit   # pode falhar com erro pré-existente de tsconfig se o node local não for o do .nvmrc (v24)
```

O CI (`test.yaml`) roda `yarn test -i`, `yarn tsc` e `yarn lint` com Node `24.13.0` (o valor do `.nvmrc`). Se o `tsc` local falhar com `TS6046` (opção `--lib`), é desalinhamento de versão do Node local, não a sua mudança — o teste jest é a fonte da verdade para validar o comportamento.

## Monitorar deploy até concluir (padrão watchdog)

Ver `scripts/watch_deploy.sh` — script reutilizável que imprime apenas quando um run conclui (silencioso enquanto `in_progress`/`queued`), adequado para cron job `no_agent=true` ou background process com `notify_on_complete`.

**No CLI, cron job é LOCAL-ONLY**: o output é salvo (visível via `cronjob action=list`), mas NÃO é entregue de volta ao terminal — não há canal de live-delivery. Para avisar o usuário em tempo real numa sessão, use um **background process** (`terminal background=true + notify_on_complete=true`) que polla `gh run view` até `completed` e sai — a notificação de saída re-entra na conversa e aí você avisa + remove o cron job. O cron job serve de histórico persistente, mas não substitui o aviso em sessão.
