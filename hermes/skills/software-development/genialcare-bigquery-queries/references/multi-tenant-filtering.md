# Multi-tenant no BigQuery GenialCare

## Regra de ouro

`clinical_cases.number` **NÃO é único entre tenants** — é único *por tenant* (ex.: o número `1`
existe em 5 tenants diferentes). Qualquer query que use `number` como chave de junção/agregação,
ou que alimente um painel/chave de merge, DEVE filtrar `tenant_id`. Sem o filtro, casos de outros
tenants colidem (mesmo número) e sobrescrevem os genialcare — o sintoma no painel é "apareceram
casos de outro tenant" + "perdeu o histórico".

## Por que o BQ direto difere do Metabase

- O **ADC** do dev (`~/.config/gcloud/application_default_credentials.json`) enxerga **todos** os
  tenants da organização.
- A **service account do Metabase** enxerga **só o genialcare** (escopo/restrição de IAM).
- Consequência: trocar o Metabase pelo BQ direto (ADC) sem adicionar o filtro de tenant faz vazar
  dados de outros tenants (Volarum, MindPlace, …) que antes não apareciam. Não é bug de permissão
  — é a diferença de escopo entre as duas credenciais.

## Como filtrar

```sql
WHERE tenant_id = '6f8da042-2dd1-4872-a613-84d371bde78c'  -- = genialcare
```

- Confirmar o tenant: `whoami` do MCP `genial` (`current_tenant.id`) — o `id` é o UUID usado na
  coluna `tenant_id`; o `external_id` (`org_jTwTzOJkZPMDw7kw`) NÃO é o que as tabelas guardam.
- Alternativa: `SELECT DISTINCT tenant_id FROM data-kernel-production-4o7n.datakernel.clinical_cases WHERE status='ongoing' ORDER BY 2 DESC`.
- Quase todas as tabelas de domínio têm a coluna `tenant_id` (`objectives`,
  `objective_evolution_checks`, `fct_sessions`, `copm_forms`, `clinical_cases_clinicians`,
  `occupational_therapy_registries`, …). Filtre na tabela-raiz de cada query; para CTEs que
  selecionam por `objective_id`/`clinical_case_id` (UUID, único globalmente), filtrar só na
  `clinical_cases` já basta — mas filtrar nas tabelas de origem também é seguro.

## Sintoma típico de diagnóstico

Contagens maiores do que o esperado após migrar Metabase→BQ; casos com `number` baixo (1, 2, 3…)
duplicados; painéis que "perderam" registros. Confirmar com:

```sql
SELECT number, COUNT(DISTINCT tenant_id) n_tenants
FROM `data-kernel-production-4o7n.datakernel.clinical_cases`
WHERE status='ongoing' AND number IS NOT NULL AND number <> 0
GROUP BY number HAVING n_tenants > 1 ORDER BY n_tenants DESC;
```

## guidance.registries — schema mudou (set/2026)

A tabela `guidance-data-production-l38y.guidance.registries` (OC — Orientação Clínica) perdeu
as colunas `has_light` e `discipline`. Mapeamento novo:

- `has_light IS TRUE` → **`status='finished'`**
- `discipline` → junta `created_by` → `clinicians.user_id` → `specialization`
  (`psychology`=aba, `speech_therapy`=fono, `occupational_therapy`=to)

```sql
oc AS (
  SELECT r.clinical_case_id, cl.specialization spec, MAX(DATE(r.created_at)) ult
  FROM `guidance-data-production-l38y.guidance.registries` r
  JOIN `data-kernel-production-4o7n.datakernel.clinicians` cl ON cl.user_id = r.created_by
  WHERE r.status='finished'
    AND cl.specialization IN ('psychology','speech_therapy','occupational_therapy')
  GROUP BY 1,2
)
```

## clinicians: `user_id` ≠ `clinician_id`

`data-kernel-production-4o7n.datakernel.clinicians` tem DUAS colunas de id com papéis diferentes:

- `registries.created_by` / `fct_sessions.completed_by_id` / `clinical_case_disciplines.updated_by_id`
  → junta em **`clinicians.user_id`**
- `clinical_cases_clinicians.clinician_id` → junta em **`clinicians.clinician_id`**

Misturar (junta `created_by` com `clinician_id`) devolve zero linhas silenciosamente — não dá erro,
só vem vazio.
