---
name: dataform-bigquery-model-review
description: "Use when reviewing Dataform SQLX models backed by BigQuery."
version: 1.0.0
license: MIT
metadata:
  hermes:
    tags: [dataform, bigquery, code-review, data-modeling, sqlx, cdc]
    related_skills: [genialcare-bigquery-queries]
---

# Dataform / BigQuery model review

Analisar a correção e a qualidade de modelos Dataform (`.sqlx`) que materializam dados do BigQuery. Foco nos erros que um diff sozinho NÃO revela: schema real das fontes, envelope CDC do datastream e camadas Bronze/Silver/Gold.

## Regra de ouro: nunca confie na declaração `.sqlx` de external table

Tables `source-aligned/**` com `type: "operations"` + `CREATE OR REPLACE EXTERNAL TABLE ... OPTIONS(format="JSON", ignore_unknown_values=TRUE)` declaram um schema EXPLÍCITO que pode estar **dessincronizado do schema deployado**. O datastream CDC envelopa a linha inteira do Postgres sob `payload: RECORD`, e a declaração no repo frequentemente lista colunas top-level que na verdade estão aninhadas.

**Sempre verifique o schema REAL antes de apontar "type mismatch" ou "campo errado":**

```bash
bq show --format=prettyjson <PROJECT>:raw.<table>   # atenção: DOIS-PONTOS, não ponto
```

Já errei um veredito "crítico" (e um bot de review também) por confiar numa declaração stale — a autora do PR estava certa e o `payload.delivery_id` retornava STRING de fato. Se o código usa `payload.<campo>` e a `.sqlx` declara `<campo>` top-level, desconfie da `.sqlx`, não do código.

Se a `.sqlx` está stale, isso é um bug PRÉ-EXISTENTE (não introduzido pelo PR em review) — aponte como correção separada, não como bloqueio do PR.

## Envelope CDC do datastream (shape real)

Uma external table CDC de Postgres→GCS tem esta forma (verificado via `bq show`):

```
payload : RECORD
  <colunas do Postgres tipadas...>
  payload : JSON          # campo JSON original do Postgres, se houver
  tenant_id : STRING      # quase sempre 100% preenchido
schema_key / stream_name / uuid / read_method / object : STRING
source_metadata : RECORD
  primary_keys[] / lsn / change_type / tx_id / is_deleted / table / schema
source_timestamp / read_timestamp : TIMESTAMP
```

Consequências práticas:
- Campos de negócio moram em `payload.<campo>`, NÃO top-level.
- `payload.tenant_id` existe e geralmente é 100% preenchido (0 nulos). Prefira-o (ou `COALESCE(payload.tenant_id, ...)`) para resolver `tenant_id` — NÃO dependa de join demográfico que pode ficar NULL. Isso resolve `assertions.nonNull` + isolamento multi-tenant do Looker.
- `source_metadata.change_type` / `is_deleted` indicam se a fonte é append-only (só `INSERT`/`false`) ou tem updates/deletes.

## Dedup CDC: use `renderEventTable()`

`includes/functions.js` expõe `renderEventTable(ref(...))`, que encapsula: `ROW_NUMBER()` por `payload.id` ordenando `source_timestamp desc, source_metadata.lsn desc` + filtro `is_deleted IS FALSE` + backfill de `tenant_id`. A maioria dos consumidores `source-aligned` usa isso (ver `monthly_bundle_pricing.sqlx`: `WHERE rnk = 1 AND is_deleted IS FALSE`).

Se um modelo lê a external table raw DIRETO (sem `renderEventTable`), verifique se a fonte é de fato append-only antes de sinalizar. Checagem rápida:

```bash
bq query --nouse_legacy_sql 'SELECT source_metadata.change_type, source_metadata.is_deleted, COUNT(*) n FROM `<PROJECT>.raw.<table>` GROUP BY 1,2 ORDER BY n DESC'
```

Se só retorna `INSERT/false`, dedup não é necessário — não vire um falso bloqueio.

## Avaliação de camadas Bronze/Silver/Gold

Ir `raw` → `gold` direto é defensável quando a tabela final é pequena (centenas de linhas) e o caso de uso é estreito. Mas sinalize quando o fato Gold está "gordo demais" — embutindo lógica de camadas inferiores que tem reuso:

1. **`silver.stg_<fonte>`** — desaninhar o envelope CDC, tipar, centralizar o tratamento CDC (dedup/filter). Justificativa: QUALQUER futuro consumidor do webhook (email, push, SMS) precisa repetir esse desaninhamento; hoje ele não existe em lugar nenhum reutilizável.
2. **`dim_`/lookup para mapas hardcoded** — um `UNNEST([...])` gigante (ex.: mapa de `tracked_response` → etapa/nota) embutido no fato é uma dimension disfarçada de literal. Extrair permite consultar, testar isoladamente e detectar drift (assertion de "valor não-mapeado").
3. Deixa no Gold apenas a assemblagem final (joins de enriquecimento específicos do caso de uso).

## Quirks do bq CLI

- Nome de tabela usa **`PROJECT:dataset.table`** (dois-pontos), não ponto.
- NÃO passe `--project_id=X` junto com nome totalmente qualificado `X.dataset.table` — dá "Not found: Dataset X:X.dataset" (duplica o prefixo). Use um ou outro.
- `gcloud config get-value project` mostra o projeto default atual (que pode ser `core-development-hy78`, não o do dataset que você quer).
- Datasets por env: dev `ops-data-development-0j9c`, staging `ops-data-staging-5gd0`, prod `ops-data-production-8fk2`. Os datasets `raw`/`operational`/`aggregates` etc. vivem nesses projetos.

Ver `references/datastream-cdc-and-schema-verification.md` para o transcript concreto (schema real do webhook Customer.io, queries de verificação e o caso do PR #792).
