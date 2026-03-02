---
name: create_dataform_pipeline
description: Guia completo para criar pipelines Dataform nos projetos supervision, data-kernel e operational-data a partir de tabelas do core. Use quando o usuário pedir para importar tabelas do core para o BigQuery, criar um pipeline de dados, ou adicionar novas entidades ao Dataform.
---

# Skill: Create Dataform Pipeline

Existem três projetos Dataform que consomem eventos CDC via Datastream do banco do `core`:

| Projeto | BQ Project (dev) | Connection | Makefile |
|---|---|---|---|
| `supervision` | `supervision-development-9a7j` | `US.supervision` | `make dataform-test` / `make dataform-run` |
| `data-kernel` | `data-kernel-development-8a5x` | `US.data-kernel` | `make dataform-test` / `make dataform-run` |
| `operational-data` | `ops-data-development-0j9c` | `US.operational-data` | `make dataform-test` / `make dataform-run` |

---

## Passo 1 — Identificar o projeto e domínio corretos

- Tabelas de **avaliação clínica** (assessments, registries, sessões terapêuticas) → **supervision**
- Tabelas de **entidades core** compartilhadas (users, clinical_cases, sessions, clinicians, caregivers) → **data-kernel**
- Tabelas de **operação interna** (collaborators, contracts, scheduling, finance) → **operational-data**

### Schemas existem por domínio, não por projeto

Cada projeto tem **múltiplos schemas/datasets** no BigQuery, organizados por domínio:

**supervision:** `assessment`, `intervention`, `parentaltraining`, `family_support`, `scheduling`, `light`, `guidance`, `clinical_case_evolution`, ...

**data-kernel:** `datakernel` (principal), mas pode ter outros

**operational-data:** `people`, `finance`, `scheduling`, `marketplace`, `aggregates`, `allocation_model`, ...

**Antes de criar qualquer arquivo, explore o projeto para entender qual schema/domínio corresponde à sua tabela.** Não assuma o schema padrão.

---

## Passo 2 — Entender o padrão do domínio antes de criar arquivos

Os projetos estão em constante evolução e têm **dois estilos de config coexistindo**. O correto é **seguir o padrão já adotado pelo domínio onde você está trabalhando**.

### Estilo A — Inline (mais comum e mais novo)

Config definida diretamente no `.sqlx`. Usado na maioria dos domínios em todos os projetos.

```sql
config {
  type: "table",
  name: "<nome>",
  description: "...",
  tags: ['<dominio>', '<nome>'],
  bigquery: { labels: { context: "<dominio>", usage: "experimental", zone: "source-aligned" } },
  columns: tables.<nome>.columns,   -- ou columns: { id: "...", ... } inline
  schema: "<dominio>",
  assertions: {
    uniqueKeys: [["id"]],
    nonNull: ["id", "created_at", "updated_at"]
  }
}
```

As columns ficam no includes correspondente do projeto (ex: `datakernel.js`, `people.js`).

### Estilo B — Spread (legado, ainda presente em alguns domínios do supervision)

Config herdada do objeto `tables` definido nos includes, com possibilidade de sobrescrever campos:

```sql
config {
  ...tables.<nome>,
  -- campos opcionais para sobrescrever o que vier do includes
}
```

As columns e assertions ficam em arquivos JS individuais por tabela (ex: `includes/assessments/tables/<nome>.js`), registrados em um `index.js` do domínio via `fillDefaultTablesAttributes`.

### Como identificar qual usar

```bash
# Olhe como os outros arquivos do mesmo domínio estão escritos:
ls definitions/<dominio>/
cat definitions/<dominio>/<outro-entity>/<outro-entity>.sqlx | head -15
```

Se o domínio usa spread → crie o includes JS separado e registre no index.
Se o domínio usa inline → defina config no próprio SQLX e adicione columns no includes do projeto.

---

## Passo 3 — Descobrir os campos no `core`

### 3.1 Ler o `schema.rb`

O `schema.rb` é a fonte de verdade: reflete o estado final do banco após todas as migrations, com campos, tipos e constraints exatos. Não é necessário olhar as migrations.

```bash
grep -A 20 "create_table \"<nome_tabela>\"" ../core/db/schema.rb
```

Se a linha do campo **não tem** `null: false` → **nullable** → nunca adicione ao `nonNull`.

### 3.3 Mapeamento de tipos Rails → BigQuery

| Rails | BigQuery |
|---|---|
| `string` / `text` | `STRING` |
| `integer` | `INT64` |
| `boolean` | `BOOL` |
| `datetime` / `timestamp` | `TIMESTAMP` |
| `date` | `DATE` |
| `float` | `FLOAT64` |
| `decimal` | `NUMERIC` |
| `uuid` (referência) | `STRING` |

### 3.4 Padrão do caminho GCS

```
gs://genialcare-event-store-${dataform.projectConfig.vars.env}/streams/database-events/core/public_<nome_tabela_rails>/*
```

O prefixo `public_` vem do schema PostgreSQL. O sufixo é o nome exato da tabela Rails.

---

## Passo 4 — Criar os arquivos

Para cada entidade, crie dentro do domínio correspondente:

```
definitions/<dominio>/<nome>/
  <nome>_events.sqlx          ← external table (raw)
  <nome>.sqlx                 ← tabela materializada
  test_<nome>.sqlx            ← teste unitário
```

> **Convenção de nome dos events em operational-data:** usa prefixo de domínio para evitar colisão — ex: `people_collaborators_events`, não `collaborators_events`.

### `<nome>_events.sqlx` — External Table (igual em todos os projetos)

```sql
config {
  type: "operations",
  name: "<nome>_events",   -- em operational-data: "<dominio>_<nome>_events"
  description: "Raw ... events from datastream CDC.",
  tags: ['<dominio>', '<nome>', 'raw'],
  hasOutput: true,
  schema: "raw"
}

CREATE OR REPLACE EXTERNAL TABLE
  ${self()}
  ${
    functions.renderSchemaExternalTable([
      { name: 'id',         type: 'STRING' },
      -- demais campos — NÃO incluir tenant_id (injetado automaticamente)
      { name: 'created_at', type: 'TIMESTAMP' },
      { name: 'updated_at', type: 'TIMESTAMP' }
    ])
  }
WITH CONNECTION `US.<projeto>` OPTIONS(   -- supervision / data-kernel / operational-data
  format = "JSON",
  uris = ['gs://genialcare-event-store-${dataform.projectConfig.vars.env}/streams/database-events/core/public_<nome_tabela_rails>/*'],
  ignore_unknown_values = TRUE,
  max_staleness = INTERVAL 2 HOUR,
  metadata_cache_mode = "AUTOMATIC"
);
```

### `<nome>.sqlx` — Tabela Materializada

**Estilo A (inline):**

```sql
config {
  type: "table",
  name: "<nome>",
  description: "...",
  tags: ['<dominio>', '<nome>'],
  bigquery: { labels: { context: "<dominio>", usage: "experimental", zone: "source-aligned" } },
  columns: tables.<camelNome>.columns,
  schema: "<dominio>",
  assertions: {
    uniqueKeys: [["id"]],
    nonNull: ["id", /* apenas campos null: false */ "created_at", "updated_at"]
  }
}

WITH events AS (${functions.renderEventTable(ref("<nome>_events"))})
SELECT
  id,
  -- demais campos (sem prefixo events.)
  CAST(created_at AS TIMESTAMP) AS created_at,
  CAST(updated_at AS TIMESTAMP) AS updated_at
FROM events
WHERE rnk = 1 AND is_deleted IS FALSE
```

**Estilo B (spread — supervision com includes separados):**

```sql
config { ...tables.<nome>, }

WITH events AS (${functions.renderEventTable(ref("<nome>_events"))})
SELECT
  events.id,
  -- demais campos com prefixo events.
  events.tenant_id,
  CAST(events.created_at AS TIMESTAMP) AS created_at,
  CAST(events.updated_at AS TIMESTAMP) AS updated_at,
FROM events
WHERE rnk = 1 AND is_deleted IS FALSE
```

### `test_<nome>.sqlx` — Teste Unitário (igual em todos os projetos)

Verifica deduplicação e soft-delete: dois eventos para o mesmo `id`, lsn maior não deletado sobrevive.

```sql
config {
  type: "test",
  dataset: "<nome>"
}

SELECT
  '2bd3d29f-2361-4044-8a0f-8fa1f8317481' AS tenant_id,
  'id1' AS id,
  -- campos com valor esperado no output final
  CAST('2023-10-19T15:46:42.444' AS TIMESTAMP) AS created_at,
  CAST('2023-10-20T17:46:42.444' AS TIMESTAMP) AS updated_at
input "<nome>_events" {
  SELECT
    STRUCT ('id1' AS id, '2bd3d29f-2361-4044-8a0f-8fa1f8317481' AS tenant_id,
      '2023-10-19T15:46:42.444' AS created_at, '2023-10-20T17:46:42.444' AS updated_at) AS payload,
    STRUCT ('2' AS lsn, FALSE AS is_deleted) AS source_metadata,
    '2023-10-20T17:46:42.444' AS source_timestamp,
    '2023-10-20T17:46:42.444' AS read_timestamp
  UNION ALL
  SELECT
    STRUCT ('id1' AS id, '2bd3d29f-2361-4044-8a0f-8fa1f8317481' AS tenant_id,
      '2023-10-19T15:46:42.444' AS created_at, '2023-10-20T17:46:42.444' AS updated_at) AS payload,
    STRUCT ('1' AS lsn, TRUE AS is_deleted) AS source_metadata,
    '2023-10-20T17:46:42.444' AS source_timestamp,
    '2023-10-20T17:46:42.444' AS read_timestamp
}
```

---

## Passo 5 — Rodar os testes

```bash
make dataform-test
```

Erros mais comuns:
- Campo no SELECT que não está no schema da events table
- Tipo incorreto (ex: `BOOL` vs `STRING`)
- Campo esperado no output do teste que não está no SELECT da tabela principal

---

## Passo 6 — Rodar o pipeline

```bash
make dataform-run
```

Para rodar apenas as novas tabelas via tags:

```bash
make dataform-partial-run tags=<tag>
```

---

## Passo 7 — Queries de validação

Gere sempre as 3 queries abaixo e **inclua na descrição do PR** para que qualquer pessoa possa validar sem precisar de contexto técnico.

Para montar as queries, descubra o schema/dataset real onde a tabela será criada — que pode ser qualquer domínio, não apenas o padrão do projeto. Consulte o campo `schema:` no `.sqlx` ou o includes do domínio.

### Query 1 — Contagem nos eventos raw

Confirma que o Datastream está publicando no GCS e o BigQuery está lendo.
Se `raw_events = 0`, o problema está no CDC, não no Dataform.

```sql
SELECT '<nome>' AS entity, COUNT(*) AS raw_events
FROM `<bq-project>.raw.<nome>_events`
UNION ALL SELECT '<nome2>', COUNT(*) FROM `<bq-project>.raw.<nome2>_events`
ORDER BY entity;
```

### Query 2 — Contagem nas tabelas finais

Se `raw > 0` mas `total = 0`, o Dataform rodou mas falhou na materialização.

```sql
SELECT '<nome>' AS entity, COUNT(*) AS total
FROM `<bq-project>.<schema>.<nome>`
UNION ALL SELECT '<nome2>', COUNT(*) FROM `<bq-project>.<schema>.<nome2>`
ORDER BY entity;
```

### Query 3 — Navegação pelo grafo de relacionamentos

Valida integridade referencial entre entidades.

```sql
SELECT
  root.id, root.status, root.tenant_id, root.created_at,
  COUNT(DISTINCT child.id) AS child_count
FROM `<bq-project>.<schema>.<entidade_raiz>` root
LEFT JOIN `<bq-project>.<schema>.<entidade_filha>` child
  ON child.<fk_id> = root.id
GROUP BY 1, 2, 3, 4
ORDER BY root.created_at DESC
LIMIT 20;
```

> **Enfatize no PR:** As queries acima podem ser rodadas diretamente no BigQuery por qualquer membro do time para validar que os dados chegaram corretamente, sem necessidade de acesso ao código.

---

## Passo 8 — Rodar as queries e verificar

Acesse o BigQuery Console no projeto de desenvolvimento e rode as queries.

Sinais de que está tudo certo:
- **Query 1**: `raw_events > 0` para todas as entidades
- **Query 2**: `total > 0` e próximo ao valor de raw (desconto de deletados/deduplicados)
- **Query 3**: relacionamentos fazem sentido, sem valores absurdos

---

## Organização hierárquica de tabelas no PR

Quando o pipeline engloba muitas tabelas com relações de hierarquia:

```
Tabelas importadas:

<entidade_raiz>
  <sub_entidade_assessment>
    <sub_entidade_item>
      <sub_entidade_detalhe>
  <outra_sub_entidade_assessment>
    <outra_sub_entidade_item>
```

Exemplo real:

```
Tabelas importadas:

phonological_assessments
  phonological_words_assessments
    phonological_words
      phonological_atypical_processes
  spontaneous_speeches_assessments
    spontaneous_speeches
  motor_vocalizations_assessments
    motor_vocalizations
```

---

## Checklist

- [ ] Projeto correto identificado (supervision / data-kernel / operational-data)
- [ ] Schema/domínio correto identificado (não assumir o schema padrão do projeto)
- [ ] Padrão do domínio seguido (inline ou spread — olhar arquivos vizinhos)
- [ ] Campos confirmados no `schema.rb` (não apenas nas migrations)
- [ ] `nonNull` contém apenas campos com `null: false` no `schema.rb`
- [ ] `tenant_id` **não** está no `renderSchemaExternalTable` (injetado automaticamente)
- [ ] Connection correta: `US.supervision` / `US.data-kernel` / `US.operational-data`
- [ ] Caminho GCS usa nome da tabela Rails com prefixo `public_`
- [ ] `make dataform-test` passou
- [ ] `make dataform-run` executou sem erro
- [ ] Queries de validação (3 camadas) incluídas na descrição do PR
- [ ] Tabelas listadas de forma hierárquica no PR quando aplicável

---

## Armadilhas comuns

### Assumir o schema errado
supervision tem `assessment`, `intervention`, `parentaltraining`, e outros. data-kernel tem `datakernel`. operational-data tem `people`, `finance`, `scheduling`, etc. **Sempre verifique qual schema o domínio usa antes de criar arquivos.**

### Misturar estilos dentro do mesmo domínio
Se o domínio já usa inline, não crie includes JS separados. Se usa spread, não defina config inline. Siga o que já existe no domínio.

### `nonNull` com campo nullable
O Gemini Code Assist frequentemente sugere adicionar FKs ao `nonNull`. **Sempre verifique o `schema.rb`** — sem `null: false` na linha do campo, ele é nullable.

### `tenant_id` duplicado no schema da events table
`renderSchemaExternalTable` injeta `tenant_id` automaticamente. Duplicar causa erro.

### Connection errada
`US.supervision`, `US.data-kernel` ou `US.operational-data` — cada projeto tem a sua.

### Nome dos events em operational-data
Usa prefixo de domínio: `people_collaborators_events`, não `collaborators_events`.

### Tipo errado para booleanos e inteiros
`boolean` → `BOOL` (não `BOOLEAN`). `integer` → `INT64` (não `INTEGER`).
