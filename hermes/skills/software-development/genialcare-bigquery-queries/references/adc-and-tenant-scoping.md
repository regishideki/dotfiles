# ADC fallback + escopo de tenant (BigQuery GenialCare)

## Usar ADC quando gcloud/bq CLI estiver com token expirado

O `bq` CLI / `gcloud` falham com "Reauthentication failed. cannot prompt during non-interactive
execution" quando o token OAuth expira (e não dá para re-autenticar em modo não-interativo). Nesse
caso, use a **Application Default Credentials** (`~/.config/gcloud/application_default_credentials.json`),
que costuma ter um `refresh_token` ainda válido, via a biblioteca Python:

```python
from google.cloud import bigquery
c = bigquery.Client(project="supervision-production-8f1v")   # projeto de produção real
for row in c.query("SELECT ...").result():
    ...
```

O ADC (`authorized_user`, não service account) enxerga os datasets de produção
(`supervision-production-8f1v`, `data-kernel-production-4o7n`, `ops-data-production-8fk2`). O
runner BQ do painel TO (`_mb_runner.py` na pasta de trabalho) usa exatamente esse caminho.

## Escopo de tenant — filtro obrigatório (causa de "vazamento" entre tenants)

O ADC (OAuth do usuário) enxerga **todos** os tenants, enquanto a service account do Metabase vê
um subconjunto. Queries diretas no BQ **sem** `tenant_id` vazam dados de outros tenants. Agravante:
`clinical_cases.number` é único **por tenant** (não globalmente) — o mesmo número existe em tenants
diferentes, então cruzar por `number` sem filtrar tenant colide em silêncio (um caso de outro
tenant "sobrescreve" o do genialcare).

Regra: filtre `tenant_id` em TODA tabela que tenha essa coluna. UUID do tenant genialcare =
`6f8da042-2dd1-4872-a613-84d371bde78c`. Para listar os tenants presentes:

```sql
SELECT tenant_id, COUNT(*)
FROM `data-kernel-production-4o7n.datakernel.clinical_cases`
WHERE status='ongoing' AND number IS NOT NULL AND number <> 0
GROUP BY 1 ORDER BY 2 DESC;
```

## Tabelas externas do Drive (ex.: SPM)

A view `sensory-processing-measure` referencia tabelas EXTERNAL do Google Drive (`spm-age*`). Essas
NÃO são acessíveis via ADC (OAuth) — retornam "Permission denied while getting Drive credentials".
Só a service account do Metabase (que tem a conexão BQ→Drive) as alcança. Para essas fontes, use a
MCP do Metabase (`execute_query`), não o BQ direto.
