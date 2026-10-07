# Acesso ao BigQuery via ADC + tabelas externas (Drive/Sheets)

## Acessar produção via Application Default Credentials (ADC)

O `bq` CLI / `gcloud` pode estar com o token expirado ("Reauthentication failed. cannot prompt
during non-interactive execution") sem como re-autenticar. Mas o **ADC**
(`~/.config/gcloud/application_default_credentials.json`, um `authorized_user` com `refresh_token`)
costuma continuar válido e acessa produção via a biblioteca Python:

```python
from google.cloud import bigquery
c = bigquery.Client(project='supervision-production-8f1v')
cols = [f.name for f in c.query(sql).result().schema]
rows = [[r.get(x) for x in cols] for r in c.query(sql).result()]  # sem limite de linhas
```

Projetos de produção (todos `us-east1`): `supervision-production-8f1v` (assessment/PEI/objetivos),
`data-kernel-production-4o7n` (`datakernel`, casos clínicos), `ops-data-production-8fk2`
(`scheduling`, sessões/agenda).

Este é o caminho para puxar volumes grandes (20k+ linhas) que o MCP do Metabase **não** serve:
o `execute_query` capa em **200 linhas/página** (`constraints.max-results: 200`) e ignora
override de constraints. Para queries pesadas, rode o SQL completo uma vez via ADC em vez de
paginar pelo MCP.

Valores BQ que precisam de normalização antes de serializar (CSV/JSON):
- `datetime.date/datetime` → `.isoformat()` (json.dump falha com date nativo).
- `bool` → `"true"/"false"` em CSV (o `csv.writer` faria `str(True)="True"`, que quebra
  comparações `== "true"`).

## Pitfall: tabelas EXTERNAL (federadas do Google Drive/Sheets)

Tabelas/views que dependem de tabela external do Drive (ex: `assessment.sensory-processing-measure`
→ `spm-age2-5y`, `spm-age5-12y`, `spm-age10-30m`) falham via ADC OAuth com:

    Permission denied while getting Drive credentials

**Não é falta de privilégio do usuário.** Tabela external do Drive exige uma conexão BQ→Drive
configurada; o Metabase usa uma service account que TEM essa conexão, o ADC (OAuth de usuário)
não tem. Para essas fontes, use o MCP do Metabase (`mcp__metabase__execute_query`), não o ADC.
Uma fonte "grande demais pro MCP" que por acaso seja external do Drive é o pior dos dois mundos —
avalie caso a caso.

Para listar o nome REAL da tabela (desconfie de espaço no fim do nome) use `client.list_tables(dataset)`
e cheque `table_type` (VIEW vs TABLE vs EXTERNAL).

## Metabase MCP: limitações

- `execute_query` capa em 200 linhas; token OAuth tem escopo só `agent:table/metric/query` —
  `GET /api/card/:id` retorna "Unauthenticated", então **não dá para ler saved questions/cards**
  diretamente (nem o SQL delas). `search`/`get_table` só expõem tables/metrics, não cards.
- O runner MCP (`tools.mcp_tool` do Hermes) funciona fora do Hermes via o venv
  (`~/.hermes/hermes-agent/venv/bin/python`) usando o token OAuth cacheado em
  `~/.hermes/mcp-tokens/metabase.json` — útil p/ paginar uma fonte média pelo MCP sem o cap manual.
