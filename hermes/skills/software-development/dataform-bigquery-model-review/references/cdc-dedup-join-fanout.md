# CDC dedup + JOIN fan-out — caso concreto (PR #796)

Repositório: GenialCare/operational-data. Gold `fct_communication_csat_in_app_responses`
resolvia email de cliques CSAT via `JOIN customer_io.people ON customer_id = customer_uuid`.

## O bug encontrado

`customer_io.people` é changelog CDC (não é única por `customer_id`). O dedup original:

```sql
QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) = 1
```

Com 33 registros de `customer_id = ""`, todos colapsavam numa única partição e o `ROW_NUMBER() = 1`
descartava 32 `internal_customer_id` distintos e reais (mantinha só o mais recente). Perda silenciosa.

## O fix aplicado (padrão reutilizável)

```sql
pessoas_atuais AS (
  SELECT customer_id, internal_customer_id, email_addr
  FROM ${ref("customer_io", "people")}
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY COALESCE(NULLIF(customer_id, ""), CONCAT("__empty__", internal_customer_id))
    ORDER BY updated_at DESC
  ) = 1
)
```

Dois JOINs separados (caminho normal por `customer_uuid` + fallback por `recipient`),
com `NULLIF(..., "")` em ambos os lados para neutralizar o `"" = ""`:

```sql
LEFT JOIN pessoas_atuais p_uuid      ON NULLIF(p_uuid.customer_id, "")           = NULLIF(c.customer_uuid, "")
LEFT JOIN pessoas_atuais p_recipient ON NULLIF(p_recipient.internal_customer_id, "") = NULLIF(c.recipient, "")
```

`recipient` (= `people.internal_customer_id`) era o identificador real que sobrava quando
`customer_uuid` vinha vazio na fonte (100% dos eventos da campanha 69/Onboarding).

## A armadilha que restou aberta (não-bloqueante, mas verificável)

O dedup particiona por `customer_id` (não-vazio) OU `internal_customer_id` (vazio). Logo
`internal_customer_id` NÃO é garantidamente único em `pessoas_atuais`: o mesmo valor pode
sobreviver em 2 linhas se aparecer sob `customer_id=""` E sob um `customer_id` preenchido
(backfill tardio) — ou sob dois `customer_id` diferentes ao longo do tempo.

Nesse caso o `p_recipient` fan-out (1 clique → N linhas idênticas). O `uniqueKeys: [["event_id"]]`
da Gold pega isso em VOZ ALTA (falha no run), então não é corrupção silenciosa — mas é um cenário
a confirmar contra os dados e, idealmente, a travar com um caso de teste (mesmo `internal_customer_id`
sob `customer_id` vazio E preenchido).

## Checklist de review para esse padrão

- [ ] O dedup trata a key vazia (`""`) sem colapsar registros distintos? (`NULLIF` + fallback de partição)
- [ ] Todo JOIN por key de string tem guard `NULLIF(x, "")` em ambos os lados?
- [ ] Se há JOIN por uma chave secundária (diferente da chave de dedup), essa chave é única nas
      linhas sobreviventes? Se não, o `uniqueKeys` vai pegar — confirmar contra dados reais.
- [ ] `CONCAT("__empty__", NULL)` → NULL: registros com `key=""` E `secondary_key` NULL colapsam
      numa partição via `COALESCE(..., NULL)` — aceitável se forem irresolvíveis, mas saiba disso.
