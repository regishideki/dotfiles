# Datastream CDC + verificação de schema (transcript do PR #792)

Caso concreto: PR GenialCare/operational-data#792 materializa `communication.csat_in_app_responses` lendo a external table `raw.infra_customer_io_webhook_events`.

## O erro que motivou esta referência

A `.sqlx` da fonte (`source-aligned/communication/infra_customer_io_webhook_events.sqlx`) declarava:

```
delivery_id, customer_id, campaign_id, metric, object_type,
tracked_response, occurred_at : STRING/TIMESTAMP   <- TOP-LEVEL
payload : JSON                                       <- coluna separada
```

O PR acessava `payload.delivery_id` etc. Um bot de review (e eu) concluímos "payload é JSON, `payload.delivery_id` retorna JSON → type mismatch → bug crítico". **Errado.** O schema real deployado é:

```
payload : RECORD
  id, event_id, metric, object_type, channel,
  delivery_id, campaign_id, customer_id, recipient, subject,
  tracked_response, occurred_at,
  payload : JSON,
  created_at, updated_at, tenant_id
schema_key, stream_name, uuid, read_method, object : STRING
source_metadata : RECORD (primary_keys[], lsn, change_type, tx_id, is_deleted, table, schema)
source_timestamp, read_timestamp : TIMESTAMP
```

`payload` é RECORD (datastream CDC envelopa a linha do Postgres), `payload.delivery_id` retorna STRING. A autora estava certa; a `.sqlx` é que estava stale.

## Comandos exatos que resolveram

```bash
# 1. Schema real (DOIS-PONTOS, não ponto)
bq show --format=prettyjson ops-data-development-0j9c:raw.infra_customer_io_webhook_events

# 2. Distribuição CDC (append-only vs com updates/deletes)
bq query --nouse_legacy_sql \
  'SELECT source_metadata.change_type ct, source_metadata.is_deleted del, COUNT(*) n
   FROM `ops-data-production-8fk2.raw.infra_customer_io_webhook_events`
   GROUP BY 1,2 ORDER BY n DESC'
# -> INSERT/false/458924  (append-only, sem dedup necessário)

# 3. População de tenant_id + contagem do filtro alvo
bq query --nouse_legacy_sql \
  'SELECT COUNT(*) total,
          COUNTIF(payload.tenant_id IS NULL) tenant_null,
          COUNTIF(payload.object_type="in_app" AND payload.metric="clicked") inapp_clicked
   FROM `ops-data-production-8fk2.raw.infra_customer_io_webhook_events`'
# -> total=458924, tenant_null=0, inapp_clicked=371
```

## Falhas de CLI que apareceram (para não repetir)

- `bq show --project_id=X X.dataset.table` → "Not found: Dataset X:X.dataset" (prefixo duplicado). Use `X:dataset.table` SEM `--project_id`, ou `dataset.table` COM `--project_id`.
- O projeto default da gcloud estava em `core-development-hy78` (não era o do dataset). Cheque `gcloud config get-value project` antes de assumir o projeto.
- `--format=prettyjson` + pipe para `python3 -c` para extrair o campo `schema.fields` funciona, mas o `bq show` já imprime o schema legível direto — use o JSON só se precisar parsear.

## Conclusões do review que valem para outros PRs do repo

- `payload.tenant_id` (do CDC) é o caminho limpo para `tenant_id` não-nulo — prefira a joins demográficos que podem dar NULL.
- A fonte webhook é append-only: não exigir dedup CDC onde a distribuição mostra só INSERT/false.
- O `renderEventTable()` (includes/functions.js) é o helper canônico de dedup CDC; um modelo que lê a external raw direto pode estar OK SE append-only.
