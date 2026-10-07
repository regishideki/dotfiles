# Filtro de tenant (multi-tenant) — ⚠️ obrigatório em toda query

## O problema

O BigQuery direto (ADC/CLI) enxerga **TODOS os tenants**. O Metabase, por outro lado, só enxerga
o tenant `genialcare` — a service account dele é restrita (por isso as contagens CLI vs Metabase
divergem).

Além disso, `clinical_cases.number` **NÃO é único globalmente** — é único *por tenant*. O mesmo
número existe em vários tenants (ex.: o número `1` aparece em 5 tenants).

**Consequência sem filtro:** dados de outros tenants (Volarum, MindPlace, etc.) vazam para a
consulta E colidem/sobrescrevem os dados do genialcare quando você usa `numero_caso` como chave.
O sintoma no usuário final é "apareceram casos de outro tenant" + "perdemos o histórico".

## A regra

Em toda query que toca dados multi-tenant (clinical_cases, objectives, sessions, assessments,
clinical_agreements, etc.), filtre o tenant:

```sql
AND <alias>.tenant_id = '6f8da042-2dd1-4872-a613-84d371bde78c'  -- genialcare
```

Todas as tabelas de domínio têm a coluna `tenant_id` (`clinical_cases`, `objectives`,
`int_objectives_enriched`, `objective_evolution_checks`, `evolution_checks`, `peis`,
`fct_sessions`, `clinical_cases_clinicians`, `copm_forms`, `copm_form_issues`,
`occupational_therapy_registries`, ...).

O filtro mais simples é na tabela raiz (`clinical_cases cc` → `cc.tenant_id = ...`). Se a query não
toca `clinical_cases` diretamente (ex. direto em `objective_evolution_checks`), filtre nela.

## Como confirmar o tenant_id

- `whoami` do MCP `genial` → `current_tenant.id` (o `current_tenant_id` que ele mostra é o
  `external_id` estilo `org_...`, NÃO é o `tenant_id` das tabelas BQ — use o `.id`).
- Ou: `SELECT DISTINCT tenant_id, COUNT(*) FROM \`data-kernel-production-4o7n.datakernel.clinical_cases\` GROUP BY 1 ORDER BY 2 DESC`.

## Caso real (set/2026)

Ao migrar o painel "Farol TO" de Metabase → BigQuery direto, 6 tenants tinham casos de TO ativos:
genialcare (`6f8da042-...`) com 1023 casos + 5 outros somando 168 casos. Sem filtro, o painel
pulou de 778 → 799 casos e "perdeu" histórico (casos de outros tenants com número colidindo
sobrescreviam os genialcare). Após adicionar `tenant_id` em todas as queries (16 queries), voltou
para 776 casos.

Note que `clinical_cases.number` duplicado entre tenants é a causa raiz do "histórico perdido" —
não é perda real de dados (o histórico está no BQ), é colisão de chave.
