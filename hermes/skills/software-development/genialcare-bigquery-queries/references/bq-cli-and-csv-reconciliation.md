# BQ CLI gotchas + CSV↔system reconciliation (de-para)

## `bq query --format=csv` trunca silenciosamente em 100 linhas

`bq query --format=csv` SEM `--max_rows` trunca a saída em 100 linhas por padrão, **sem
nenhum aviso de truncamento na saída**. Com `ORDER BY`, as linhas cortadas são as do fim do
ordenamento — o que pode esconder exatamente os registros que você procura (ex: um subdomínio
inteiro de objetivos ficou de fora de uma contagem e só apareceu ao subir o limite).

Regra: quando a saída importa para contagem/comparação, passe `--max_rows=500` (ou mais) e
confirme totais com um `select count(*)` isolado. Não confie numa contagem feita em cima de
uma saída truncada sem ter verificado o limite.

## Dataset em location diferente

Nem todos os datasets do projeto `supervision-production-8f1v` estão na mesma location.
`datakernel` (ex: tabela `tenants`) não fica em `us-east1` como `intervention`/`assessment` —
um JOIN cross-dataset pode dar:
`Not found: Dataset supervision-production-8f1v:datakernel was not found in location us-east1`.
Se só precisa dos dados de um tenant, prefira filtrar por `tenant_id` direto (via subquery)
em vez de fazer JOIN com `datakernel.tenants`.

## Reconciliação CSV ↔ sistema (de-para)

Quando o objetivo é casar um CSV/planilha exportado com as estruturas reais do sistema:

- **Corrija a FONTE (planilha), não o CSV derivado.** Se patchear o CSV no repo, a planilha
  de origem continua errada e a próxima exportação traz o erro de volta. Liste as correções
  necessárias e deixe o usuário editar a planilha; depois revise a re-exportação. É o padrão
  que este usuário pede explicitamente.
- **Detecte células malformadas** (itens colados numa linha só, em vez de quebra de linha):
  escaneie cada célula contando ocorrências dos prefixos de item numa mesma linha. `>= 2`
  prefixos na mesma linha = célula malformada. Prefixos típicos de avaliação de Fono:
  `Bandeiras Vermelhas:`, `Avaliação - Imitação:`, `CAA:`, `Comunicação Expressiva:`,
  `Motricidade Orofacial:`.
- **Resíduo de separador**: ao quebrar itens colados, sobra o caractere que os separava
  (`.` ou `;`) grudado no fim do primeiro item. Valide com `item.strip().endswith('.')` /
  `endswith(';')`.
- **Corrija o CSV para casar com o texto EXATO do sistema** — incluindo typos do cadastro,
  ponto final sobrando etc. — porque o match exato do de-para depende disso. Confirme o texto
  real via `bq query` ANTES de editar; não assuma pela leitura anterior (a descrição pode ter
  sido reescrita entre snapshots/migrações).
- **Cheque snapshots antigos antes de concluir "não existe".** Um objetivo "ausente" no
  protocolo atual pode ter existido num protocolo anterior e sido descartado numa migração
  (ex: `producao-fono-objetivos.json` de uma iniciativa de migração). Isso muda a decisão:
  reinserir = reverter remoção, não criar do zero.

## Auth gcloud expirada → usar ADC

Quando `bq query` falha com `Reauthentication failed. cannot prompt during non-interactive
execution`, a credencial de *usuário* do gcloud expirou. O ADC
(`~/.config/gcloud/application_default_credentials.json`, tipo `authorized_user` com
`refresh_token`) muitas vezes ainda funciona. Force o bq a usar o ADC em vez da credencial
de usuário:

```sh
CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE=~/.config/gcloud/application_default_credentials.json \
  bq query --use_legacy_sql=false --project_id="supervision-production-8f1v" "SELECT 1"
```

`CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE` sozinho (sem `GOOGLE_APPLICATION_CREDENTIALS`) é o
que funciona — o bq continua preferindo a credencial de usuário do gcloud a menos que você
force via essa variável. Se nem isso resolver, valide o `refresh_token` do ADC direto via
`POST https://oauth2.googleapis.com/token` (`grant_type=refresh_token`) para saber se o
problema é só o cache do gcloud ou o token em si.

## bq CLI retorna 0 linhas SILENCIOSAMENTE quando o account ativo é o SA regis-automation

Sintoma: `bq query "SELECT COUNT(*) ..."` retorna `0` (exit 0, sem erro) numa tabela que tem dados —
a mesma query no Metabase retorna centenas. Causa: `gcloud auth list` mostra o service account
`regis-automation@kubernetes-production-cd91.iam.gserviceaccount.com` como ACTIVE (ativado em sessão
anterior p/ kubectl), não o usuário `regis@genialcare.com.br`. Esse SA enxerga os projetos e os
schemas (`bq ls` lista as tabelas), mas retorna vazio nos dados — **sem** "access denied", só 0 linhas.
Dica de `gcloud config list`: `account = regis-automation@...` e `project = core-development-hy78`.

Diagnóstico: `gcloud auth list` → qual account está com `*`? Se for `regis-automation@...`, é isso.

Fix: NÃO use o bq CLI (preso na credencial errada). Use o ADC via `google.cloud.bigquery` Python
(o ADC `~/.config/gcloud/application_default_credentials.json`, tipo `authorized_user`, tem
refresh_token próprio e segue funcionando mesmo com o token interativo expirado — ver seção
"Auth gcloud expirada → usar ADC" acima):

```python
from google.cloud import bigquery
c = bigquery.Client(project="supervision-production-8f1v")
for row in c.query("SELECT COUNT(*) n FROM `supervision-production-8f1v`.assessment.speech_therapy_registries").result():
    print(row.n)   # -> 849 (real)
```

Observações:
- `gcloud config set account regis@genialcare.com.br` pode falhar com "Reauthentication failed.
  cannot prompt" — o ADC/`google-cloud-bigquery` contorna isso sem mudar o account ativo.
- Python do sistema no macOS falha em SSL (`CERTIFICATE_VERIFY_FAILED`) ao trocar token via
  `urllib`; use `certifi` (`ssl.create_default_context(cafile=certifi.where())`) ou
  `ssl._create_unverified_context()`.
- Sinal de "account errado" é INCONSISTÊNCIA: algumas tabelas retornam dados (ex:
  `supervision.targets` = 67392) e outras 0 (ex: `assessment.*`, `datakernel.*`). Um IAM real
  daria erro, não 0 — 0 silencioso = SA sem acesso a dados, não tabela vazia.

## Passar SQL multi-linha ao bq via stdin (não $(cat))

`bq query "$(cat arquivo.sql)"` quebra quando o SQL começa com comentário `--`: o bq
interpreta o resto como flags e dá `Unknown command line flag`. Passe o arquivo via stdin:

```sh
bq query --use_legacy_sql=false --project_id="supervision-production-8f1v" \
  --max_rows=500 < arquivo.sql
```

Combine com `--max_rows=500` (ou mais) sempre que a contagem importar (ver gotcha de
truncamento acima).

## Programar via Python (google-cloud-bigquery) — puxa volume grande sem o cap do Metabase

Para puxar result sets GRANDES (dezenas/centenas de milhares de linhas) sem o cap de 200
linhas/página do Metabase MCP, use a lib Python direto no BQ:

```python
from google.cloud import bigquery
c = bigquery.Client(project="supervision-production-8f1v")
result = c.query(SQL).result()
cols = [f.name for f in result.schema]
rows = [[r.get(x) for x in cols] for r in result]
```

A lib usa o ADC por padrão (`GOOGLE_APPLICATION_CREDENTIALS` ou o ADC default em
`~/.config/gcloud/application_default_credentials.json`) — funciona mesmo quando o token
interativo do gcloud está expirado, sem precisar do `CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE`.
Normalize `datetime.date`/`datetime.datetime` → `isoformat()` e `bytes` → `decode()` antes de
serializar (json.dump falha em `date`).

## Tabelas federadas do Drive/Sheets: leia via Metabase MCP, não ADC

Tabelas EXTERNAL federadas do Google Drive/Sheets (ex: a view
`assessment.sensory-processing-measure` que referencia `spm-age2-5y`/`spm-age5-12y`/`spm-age10-30m`)
dão **`Permission denied while getting Drive credentials`** quando lidas via ADC (usuário OAuth).
O BQ precisa de uma conexão com credenciais do Drive — que só a service account do Metabase tem.
Para essas tabelas, leia via o MCP do Metabase (`execute_query` com native stage), não via bq/ADC.
Detecte a federção com `c.list_tables('assessment')` e cheque `t.table_type == "EXTERNAL"`.

## Filtro de tenant: `clinical_cases.number` NÃO é único entre tenants

`data-kernel-production-4o7n.datakernel.clinical_cases.number` é único POR tenant, não globalmente —
o número `1` existe em 5 tenants distintos. O ADC (bq CLI / google-cloud-bigquery) enxerga TODOS os
tenants — e as conexões "genialcare" do Metabase (db 3 `data-kernel-production-big-query`, db 4
`supervision-production-big-query`, db 11 `operational-data-big-query`) TAMBÉM enxergam todos: não há
RLS/restrição de linha na conexão (service account em `meta-production-2a6b`, `dataset-filters-type: all`).
O isolamento por marca existe só como conexões `mindplace-*` separadas (db 14/17/18/19). Logo o filtro
`tenant_id` é obrigatório em TODA query — no ADC E no Metabase (o mito "o Metabase só vê a genialcare" é
falso). Consequência: uma query
multi-tenant SEM `WHERE tenant_id = '...'` deixa casos de outros tenants (Volarum, MindPlace, …)
vazarem — e como `number` colide entre tenants, esses casos "sobrescrevem"/misturam os genialcare.
O sintoma reportado pelo time foi exatamente: "começaram a aparecer casos de outro tenant" +
"perdemos o histórico".

Regra: toda query que toca `clinical_cases` (ou outra tabela com coluna `tenant_id`) deve filtrar
`tenant_id = '6f8da042-2dd1-4872-a613-84d371bde78c'` (= genialcare). Confirmar o tenant correto:
`SELECT DISTINCT tenant_id, COUNT(*) FROM ...clinical_cases GROUP BY 1 ORDER BY 2 DESC` (o maior é o
genialcare) ou o `whoami` do MCP genial (`current_tenant.id`). Aplicar o filtro também nos CTEs/joins
que usam `objectives`, `objective_evolution_checks`, `fct_sessions`, etc. — todas têm `tenant_id`.

## Dois painéis mostram totais diferentes p/ a mesma métrica → ≠ bug de lógica

Quando o dash (Metabase) e o protótipo (Farol) reportam totais diferentes da MESMA métrica
(ex: "PEI aderente"), a causa mais comum NÃO é a lógica de cálculo — é **universo diferente**
(filtros que definem "quais casos contam" divergem entre as duas fontes). Diagnóstico:

1. Reproduza a lógica das DUAS fontes no BQ e compute o **symmetric difference** dos dois
   universos de caso (`A - B` e `B - A`), não só a contagem total. Use `id` de caso (UUID), não
   `number` (não é único entre tenants).
2. Decomponha a diferença por filtro. Caso real (PEI Aderente TO, 2026-09): o dash filtra
   `churned_at IS NULL AND on_hold IS NOT TRUE` e inclui "Sem OG TO"; o painel exige OG de TO
   alocada + (objetivo OU Vineland) e NÃO filtra churned. Três filtros: churned (+43 no painel),
   OG obrigatória (+28 no dash), Vineland/objetivo mínimo (+8 no dash) → saldo +7 (779 vs 772).
3. Alinhe os filtros de UNIVERSO (o de churned é o mais defensável: caso encerrado não é
   "ativo") ANTES de caçar bug na lógica — a lógica de aderência em si pode já estar idêntica.

Lições: (a) "mesma métrica" não garante "mesmo universo" — confirme os filtros de caso dos dois
lados; (b) um card que parece genialcare-only pode só ter as queries com `tenant_id`, porque a
CONEXÃO não restringe nada (ver seção "Filtro de tenant" acima).

## Ponto de milhar: BQ/ADC devolve `numero_caso` SEM ponto, editor exporta COM ponto

Ao puxar um CSV-equivalente direto do BQ (via `google.cloud.bigquery`/ADC ou `bq query`), colunas
numéricas como `numero_caso` voltam como inteiro cru (`"1001"`). O export do editor do Metabase formata
o MESMO campo com separador de milhar pt-BR (`"1.001"`). Se o código downstream cruza por essa coluna
(ex: `numero_caso` como chave de dict/join contra outro CSV que veio do editor), a divergência de
formato **derruba silenciosamente todos os casos ≥ 1000** — não é erro de join, é só o número que
não bate (os < 1000 casam, os ≥ 1000 somem). Sintoma real (2026-09): painel reportou 285 "Aderente"
em vez de 542 porque os casos ≥ 1000 saíram do cruzamento. Fix: formate ANTES de escrever o CSV, para
casar com o export do editor — `f"{int(v):,}".replace(",", ".")` (igual o `pull_ogcaso` faz). Não
normalize o outro lado: o consumidor espera o formato COM ponto.

## Editar query de um card do Metabase via API (GET → altera native → PUT)

Para corrigir o SQL de um card (question/model) do Metabase programaticamente — ex: adicionar o filtro
de `tenant_id` que faltava num card que vazava tenants:

1. `GET /api/card/{id}` com header `x-api-key` (a key fica em `config.personal.yml` → `metabase.api_key`).
2. Altere `dataset_query.stages[0].native` (SQL nativo; cards MBQL têm `stages[0].lib/type == "mbql.stage/native"`).
3. `PUT /api/card/{id}` com body `{"dataset_query": <dataset_query completo>}`.

Detalhes: use `curl` (o `urllib` do Python com `ssl` context custom deu `403`; `curl` funciona). O
`service-account-json` vem mascarado como `**MetabasePass**` — não dá pra ler o e-mail da SA pela API;
o projeto real da SA aparece em `details.project-id-from-credentials` (`meta-production-2a6b`). Cards do
Farol/dash PEI Aderente TO: 8137 (genialcare), 8315 (mindplace), 8342 (farol_B/objetivos), 8343 (checagem).
`tenant_id` da Mindplace (careplus_mindplace) = `a4d02a8c-4c27-41b6-80ac-3401f3964e34`. Faça backup do
`dataset_query` antes do PUT (o PUT sobrescreve; não há "só update").
