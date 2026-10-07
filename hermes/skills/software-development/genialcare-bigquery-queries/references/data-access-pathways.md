# Acessando dados de produção GenialCare — 3 caminhos (e quando usar cada)

Produção = projetos `supervision-production-8f1v` (assessment/intervention/raw),
`data-kernel-production-4o7n` (datakernel), `ops-data-production-8fk2` (scheduling).

## 1. BigQuery direto via ADC — para pulls grandes (20k–200k+ linhas)

```python
from google.cloud import bigquery
c = bigquery.Client(project="supervision-production-8f1v")
rows = list(c.query(SQL).result())   # SEM cap de linhas
```

- Usa as **Application Default Credentials** (`~/.config/gcloud/application_default_credentials.json`),
  que acessam produção mesmo quando o `bq` CLI / `gcloud auth` está com token expirado
  ("Reauthentication failed"). Não dependa do `bq` CLI — use a lib `google-cloud-bigquery` + ADC.
- O MCP do Metabase capa em **200 linhas/página** e ignora override de constraints; paginar
  OFFSET é O(n²) e trava o BQ. Para qualquer fonte >~2k linhas, vá direto ao BQ via ADC.
- Converter valores: `datetime.date` → `.isoformat()`, `bool` → `"true"/"false"` (export do
  editor usa lowercase), `None` → `""`. Número de caso: o export do Metabase formata COM ponto
  de milhar (`1.001`), o BQ traz int — normalizar com `f"{int(v):,}".replace(",", ".")` em TODO
  cruzamento (ver `numero_caso` nos CSVs do Farol TO).

## 2. Tabelas EXTERNAL do Google Drive/Sheets → SÓ via MCP Metabase

- Algumas views (ex: `assessment.sensory-processing-measure` da SPM) referenciam tabelas
  **EXTERNAL** do Drive (`spm-age2-5y`, `spm-age5-12y`, `spm-age10-30m`).
- O ADC (authorized_user OAuth) NÃO consegue lê-las: erro `403 Permission denied while getting
  Drive credentials`. O MCP do Metabase roda com uma **service account que TEM a conexão
  BigQuery↔Drive configurada**, então é o único caminho para essas tabelas.
- Diagnosticar: `list_tables(dataset)` retorna `table_type: EXTERNAL` (vs `TABLE`/`VIEW`).
- Para fontes pequenas (SPM ~1k linhas), o MCP + paginação keyset serve; não é o gargalo.

## 3. Cards/questions do Metabase (SQL salvo) → REST `/api/card/{id}` com x-api-key

- O MCP do Metabase (read-only) **NÃO expõe cards/questions** — `search`/`get_table` só acham
  tables e metrics; não dá para ler nem executar o SQL nativo de uma card.
- Ler o SQL de uma question: `curl -H "x-api-key: <key>"
  https://analytics-panel.genialcare.com.br/api/card/{id}` → campo `dataset_query.stages[].native`
  (cards nativas). Hosts equivalentes: `metabase.production.internal.genialcare.com.br`.
- A **x-api-key fica em `config.personal.yml`** (chave `metabase.api_key`) no repo
  product-engineer-agent (gitignored). Keys antigas expiram (HTTP 401) — pedir nova ao usuário.

## 4. Pitfall: SQL commitado pode divergir da question canônica

- O SQL que vive num `_queries_farol.py` / script pode estar **desatualizado** em relação à
  question que a pessoa realmente usa no Metabase (a question evolui; o script não).
- Antes de confiar num SQL commitado para um painel/relatório, **puxe a question canônica via
  `/api/card/{id}`** e compare. Exemplo real (Farol TO, set/2026): a `Q_CE` commitada tinha um
  filtro `interval 12 month` + join complexo que retornava 40k linhas; a question 8343 real é um
  simples `SELECT ... QUALIFY ordem_recente <= 8` direto de `objective_evolution_checks`,
  retornando ~185k. As colunas calculadas (`ultima_ce`, `dias_objetivo_aberto`,
  `dias_desde_ultima_ce`) vinham de CTEs na question, não de um passo de enriquecimento.
