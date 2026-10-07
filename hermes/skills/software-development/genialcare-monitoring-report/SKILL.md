---
name: genialcare-monitoring-report
description: Run GenialCare daily app monitoring report (report diario).
---

# GenialCare Monitoring Report

O "report diário" (e semanal) de monitoramento de aplicações da GenialCare é
implementado por skills **do repo** `product-engineer-agent`, NÃO por skills do
Hermes (`~/.hermes/skills`). Elas ficam em `.claude/skills/` e `.claude/skills/shared/`.

## ⚠️ Pitfall de descoberta (correção recorrente do usuário)

`skills_list` NÃO lista as skills do repo. Antes de concluir que "não existe skill"
para uma tarefa neste repo, rodar:

```
search_files(pattern="*", target="files", path=".claude/skills")
search_files(pattern="*", target="files", path=".claude/skills/shared")
```

Skills-chave que só aparecem assim (não no `skills_list`): `application-monitoring`
(diária), `application-monitoring-weekly` (semanal), `plan-feature`, `implement-feature`,
`analyze-feature`, `create-user-story`, `adr`, `wiki`, `discovery`, etc.

## Skills relevantes (ler ANTES de executar)

- `.claude/skills/application-monitoring/SKILL.md` — report DIÁRIO. Fontes: Datadog
  (Error Tracking, APM, logs, RUM, monitors, cases, custo) + `failed_jobs_list` via
  MCP Genial + Slack `#alerts` + deploys GitHub. É a skill autoritativa — ler o
  arquivo inteiro (14 sub-fases na FASE 1, template de relatório na FASE 3).
- `.claude/skills/application-monitoring-weekly/SKILL.md` — report SEMANAL (infra,
  performance, query cost vs semana anterior).

## Fatos operacionais (validados)

- Saída: `inbox/monitoring/YYYY-MM-DD/report.md` + `tasks.md`. **A pasta é a data da
  JANELA coberta**, não a data de geração. `window:` e `date:` no frontmatter = dia
  coberto. Report gerado de manhã cobre o dia anterior; segunda cobre sex+sáb+dom
  num único report consolidado.
- Slack: resumo publicado em `#technology` (`C02650V1B9V`) na FASE 4. Usar token
  mrkdwn `<!subteam^GROUP_ID>` para on-call e `<@USER_ID>` para pessoa física
  (resolver via `slack_search_users` pelo email) — `@handle` solto NÃO notifica.

  ⚠️ **`slack_search_users` NÃO resolve user-group/subteam** — só busca pessoas físicas.
  Consultar `on-call-capacidade-clinica` / `on-call-data-platform` por esse tool retorna
  "No results". O único `GROUP_ID` estável conhecido é Capacidade Operacional
  (`S0A91M9QA9F` → `<!subteam^S0A91M9QA9F>`). Para clínica/data platform, sem ID:
  registrar a pendência em texto sem menção (não inventar `@on-call-*` solto), ou
  resolver o ID por outro caminho antes de mandar.
- Ownership (Fonte 6): `Finance::*`/`Scheduling::*`/`Invoice*` → Capacidade
  Operacional (`<!subteam^S0A91M9QA9F>`); `Clinical*`/`clinical-panel*`/`mobile*` →
  Capacidade Clínica; `dataform`/`gcp_*`/pipelines → Data Platform.

## Pré-requisitos (destravados 2026-09-15)

- Datadog toolset `cases`: config `datadog.url` com `toolsets=all,cases` (o `cases` é
  preview e NÃO vem no `all`). Desbloqueia `search_datadog_cases`/`get_datadog_case`.
- MCP Genial `failed_jobs_list`: requer role `developer` no Core + token OAuth em
  `~/.hermes/mcp-tokens/genial.json` (login `hermes mcp login genial`). Validar com
  `mcp__genial__whoami` — deve retornar email com `developer` em `all_roles`.

## ⚠️ Token OAuth do MCP Genial expira ~24h — NÃO tentar renovar em modo não-interativo

O access token do MCP Genial expira em ~24h (`expires_in: 86400` no `genial.json`). Um
report diário que roda 24h após o último login já encontra o token expirado — é o estado
esperado, não um acidente.

**Pitfall destrutivo (validado 18/09/2026):** rodar `hermes mcp login genial` em ambiente
não-interativo (CLI/cron, sem browser) **NÃO renova** o token. Ele falha com
"non-interactive environment and no cached tokens found" **e APAGA os arquivos de token
cacheados** (`genial.json`, `genial.client.json`, `genial.meta.json`). Depois disso não
sobra refresh token para reusar — a tentativa de "refresh" piora o estado. Nunca usar o
comando de login como gambiarra de renovação automática.

**Sinal de expiração:** quando o token expira, as tools do MCP Genial (`failed_jobs_list`,
`mcp__genial__whoami`) **somem do `tool_search`** — o servidor não indexa tools sem auth.
Não há `mcp__genial__*` no catálogo deferred da sessão. O único caminho é HTTP direto (que
também exige token válido), então na prática a fonte fica indisponível.

**Conduta correta:** detectou expiração → seguir FASE 0.2: parar antes de montar o report e
pedir ao usuário para rodar `hermes mcp login genial` num terminal com browser/SSO. Não
insistir no login via agent. Registrar `> Fonte indisponível: token OAuth MCP Genial
expirado — rodar hermes mcp login genial` na seção de failed jobs.

## Padrão de upsert (não re-rodar as 14 fontes)

Se `report.md` do dia já existe (ex.: gerado parcial porque uma fonte estava
indisponível), fazer **upsert**: completar apenas as seções que faltavam e atualizar
TL;DR + pendências. Remover o aviso de "fonte indisponível" das fontes que voltaram.
Não re-coletar as fontes que já estão no arquivo.

## Slack: completude vs. limite de 5000 chars

Com 25+ cases e 14+ deploys, listar TUDO (completude exigida pela skill) estoura o
limite de 5000 chars por mensagem do MCP. Técnica p/ caber em UMA mensagem sem perder
dado: (1) tabela de cases com só `Key | Título` — derrubar colunas `Prio`/`Assignee`
(estão no report.md linkado); (2) deploys como linha única com títulos de 1–2 tokens
(`#NNNN` com link + assunto curto); (3) cortar linhas de baixo valor (resumo de
`#alerts` quando não há incidente novo). Manter todos os links `[alias](url)` e todos
os cases/monitors/failed-jobs. Se ainda passar, priorizar cases/monitors/issues sobre
deploys (que são contexto, não alarme).

## Pre-flight obrigatório (FASE 0 da skill)

Smoke test antes de coletar (em paralelo):
- `search_datadog_monitors(query:"status:alert")`
- `failed_jobs_list(page_size:1)`
- `slack_search_public_and_private(query:"in:#alerts", include_bots:true)` — `include_bots:true` é obrigatório (alertas são postados pelo bot Datadog).

Se Datadog ou MCP Genial falhar após 1 retry, parar e reportar ao usuário antes de
montar o report (não prosseguir com fallbacks silenciosamente). Slack/GitHub são
complementares — falha neles não bloqueia.

## Preferência de delivery (usuário)

NÃO mandar o Slack em partes. Acumular tudo, e **avisar o usuário no meio do caminho**
se algo quebrar (MCP fora, fonte vazia, limitação), resolver junto, e só então mandar
UMA mensagem consolidada ao final da FASE 4.

## Privacidade (regra dura da skill)

`failed_jobs_list` retorna `message` bruto (texto livre, pode ter PII/contexto
sensível). Nunca persistir nem publicar `message`; usar apenas leitura sanitizada
(`exception_class` + domínio inferido) no report, tasks e Slack.

## Paginação completa do `failed_jobs_list`

Páginas de 300 jobs com `message` SOAP gigante ultrapassam ~250 KB → o Hermes
persiste em arquivo e **elide o `meta.next_cursor`** (base64 vira `"eyJjIj...OTl9"`
com `...` literal), tanto no arquivo quanto no stdout. Não é bug do endpoint.

Duas saídas (detalhe completo em `references/failed-jobs-pagination.md`):
1. **Reconstruir o cursor** deterministicamente:
   `base64url(json.dumps({"c": <failed_at do último job, em segundos>+"Z", "i": <id do último job>}, separators=(",", ":")))`.
2. **Loop completo via HTTP direto** (recomendado): script Python auto-contido que
   faz o handshake MCP e itera todas as páginas, mantendo o cursor fora da exibição.
   Destravou com: `ssl._create_unverified_context()` (cert do macOS), User-Agent de
   navegador (Cloudflare 1010), token de `~/.hermes/mcp-tokens/genial.json`, e
   `notifications/initialized` com resposta vazia (não parsear).

## Slack #alerts: busca retorna texto vazio

`slack_search_public_and_private(query:"in:#alerts ...")` retorna os `message_ts`/
timestamps mas com o campo `Text` **vazio** (é resumo de busca, não o conteúdo). Para
ler o conteúdo real dos alertas, usar `slack_read_channel(channel_id="C02G0B8SK5E",
oldest=<ts_inicio>, latest=<ts_fim>)` — aí vêm os attachments com a mensagem do
monitor Datadog (SOAP fault, issue.id, "ignored this issue", etc.).
