# Metabase via MCP (read-only) — acesso, limitações e topologia de dados

A MCP do Metabase (`mcp__metabase__*`) é um caminho de **leitura** — distinto do REST API
(`x-api-key`, que é o caminho de ESCRITA usado para criar dashboards). Use a MCP quando o usuário
pedir para "ver no Metabase" / cross-checar dados sem tocar na UI ou sem re-logar.

## O que a MCP consegue vs não consegue

- `search` → encontra TABLES e METRICS, mas **NÃO encontra cards/questions nativas** (native SQL)
  nem models. Cards do dashboard (ex: "PEIs Aderentes TO - RAW", "Resumo por Caso") não aparecem
  — não dá para executar o SQL nativo de uma card pela MCP.
- `query` / `construct_query` / `execute_query` → consulta **UMA tabela por vez** (filters,
  group_by, aggregations). **Sem JOINs.** Não dá para reproduzir lógica multi-tabela (ex:
  aderência PEI = objectives → mapper → module_progress_items) numa única query MCP.
  Trabalho em cadeia: resolva IDs etapa por etapa (clinical_cases → peis → objectives).
- `get_table` → lista campos (`field_id` no formato `t<tableid>-<n>`) e tables relacionadas.

## Ler o SQL de uma card/question (via REST, NÃO MCP)

A MCP não expõe cards/questions (acima), mas a **REST API** expõe. Para ler o SQL de uma question
salva, use `GET /api/card/{id}`:

```bash
curl -s -H "x-api-key: <key>" https://analytics-panel.genialcare.com.br/api/card/8342
```

O SQL vem em `dataset_query.stages[].native` (card nativa) ou `dataset_query.query` (MBQL). A
`x-api-key` fica em `config.personal.yml` (chave `metabase.api_key`) — gitignored. **Expira**: se
`GET /api/card/{id}` retornar `401 Unauthenticated` (em qualquer variação de header), peça uma key
nova ao usuário (Admin → Settings → API Keys). Ex.: questions 8342 ("Objetivos - TO") e 8343
("Checagem TO") do painel de acompanhamento TO.

## Escopo de tenant: BQ direto (ADC) vs Metabase (service account)

Trocar a leitura da MCP do Metabase por SQL direto no BigQuery (ADC / `google-cloud-bigquery`)
MUDA o escopo de dados: o **ADC (OAuth do usuário) enxerga TODOS os tenants**, enquanto a service
account do Metabase vê um subconjunto. Queries diretas sem filtro de `tenant_id` **vazam dados de
outros tenants**. Agravante: `clinical_cases.number` é único **por tenant** (não globalmente) — o
mesmo número existe em tenants diferentes, então cruzar por `number` sem filtrar tenant colide
silenciosamente (um caso de outro tenant "sobrescreve" o genialcare). Sempre filtre `tenant_id`
(UUID; genialcare = `6f8da042-2dd1-4872-a613-84d371bde78c`) em toda tabela que tenha essa coluna.
Para descobrir os tenants presentes: `SELECT tenant_id, COUNT(*) FROM clinical_cases WHERE status='ongoing' GROUP BY 1`.

## Topologia dos "databases" (pega importante)

O mesmo dado aparece em MÚLTIPLOS databases do Metabase, com **UUIDs diferentes**:

- **database 4** = `supervision-production-8f1v` (o projeto real, o que o dashboard usa):
  `objectives` (id 70), `peis` (id 63), `library_objectives` (id 1590, ~390 objetivos),
  `module_progress_items` (id 3801), `pei_tracks` (id 3807).
- **database 18** = um mirror/sync DIFERENTE, onde o mapper
  `pei_track_to_occupational_therapy_objectives` (id 14255) é exposto. O `library_objectives`
  daqui (id 7534) tem ~1001 objetivos com **UUIDs diferentes** do database 4.
- **database 3** = `data-kernel-production-4o7n` (`clinical_cases` id 36, `clinical_case_disciplines`,
  etc.). Outros databases (11, 14, 17) são mirrors de outros projetos/tenants.

CONSEQUÊNCIA: filtrar o mapper (db 18) pelos `library_objective_id` de `supervision-production`
(db 4) retorna **0 linhas**, porque os UUIDs não batem. O mapper que o DASHBOARD usa é o do
projeto correto (`supervision-production-8f1v`, project-qualified no SQL nativo), não o do db 18.
Para cruzar o mapper, ou (a) use o db 18 por inteiro (busque o `library_objective` do MESMO db 18
e use o ID dele no mapper), ou (b) vá direto ao `bq` CLI (que lê o projeto real — ver skill
`genialcare-bigquery-queries`).

## field_id helpers (grão objetivo-TO x jornada)

- `clinical_cases` (db 3, id 36): id = t36-0, name = t36-3, number = t36-4.
- `peis` (db 4, id 63): id = t63-0, clinical_case_id = t63-2.
- `objectives` (db 4, id 70): objective_id = t70-0, pei_id = t70-1, description = t70-4,
  status = t70-5, library_objective_id = t70-15. (status "ativo" p/ PEI = `validated`/`in_maintenance`.)
- `library_objectives` (db 4, id 1590): id = t1590-0, description = t1590-4.
- mapper `pei_track_to_occupational_therapy_objectives` (db 18, id 14255):
  main_objective_id = t14255-0 (jornada/PEI Track), support_objective_id = t14255-1 (TO),
  tenant_id = t14255-2. (`support_objective_id` casa com `library_objectives.id`, não com
  `objectives.objective_id`.)
