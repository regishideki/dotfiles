# Multi-tenant filter (obrigatório em query multi-tenant)

## A regra

Toda query que toca `clinical_cases` (ou qualquer tabela com `tenant_id`) e não tem um
escopo de tenant explícito DEVE filtrar `tenant_id = '6f8da042-2dd1-4872-a613-84d371bde78c'`
(= **genialcare**). Sem isso, dados de outros tenants vazam e corrompem o resultado.

## Por quê (root cause)

1. **BigQuery direto (ADC) enxerga TODOS os tenants.** O Metabase (service account) só
   enxerga o genialcare — por isso uma query que "funciona" no Metabase quebra quando
   portada para `bq` CLI / `google-cloud-bigquery` via ADC.
2. **`clinical_cases.number` NÃO é único entre tenants.** É único *por tenant*. Ex.: o
   número `1` existe em 5 tenants distintos. Em painéis/chaves que usam `numero_caso`
   como chave, casos de outros tenants **colidem e sobrescrevem** os casos genialcare.

## Sintoma quando falta o filtro

- "Casos de outro tenant apareceram" (ex.: Volarum, MindPlace).
- "Perdemos o histórico" — os casos genialcare são silenciosamente sobrescritos por casos
  de outro tenant com o mesmo `number`, parecendo perda de dados.
- Contagens maiores que o esperado (ex.: 799 casos em vez de 778; fonte A 811 → 788 após
  filtrar; fonte C 185008 → 183655).

## Como identificar os tenants

```sql
SELECT tenant_id, COUNT(*) n
FROM `data-kernel-production-4o7n.datakernel.clinical_cases`
WHERE status='ongoing' AND number IS NOT NULL AND number <> 0
GROUP BY tenant_id ORDER BY n DESC;
```

O genialcare é o tenant com mais casos. Confirmar o id: `whoami` do MCP `genial_care`
(`current_tenant.id`).

## Onde aplicar

- Tabela raiz de cada query (`clinical_cases` → `cc.tenant_id`; `objectives` →
  `obj.tenant_id`; `objective_evolution_checks` → `oec.tenant_id`; etc.).
- Em `qualify`-only queries (sem `WHERE`), adicionar `WHERE ...tenant_id = '...'` antes do
  `qualify`.
- Não basta filtrar só a tabela raiz se o join for por `number` (não por `id`/UUID) — o
  `number` colide entre tenants, então o filtro de tenant tem que estar na própria tabela
  que é a fonte do join por number.

## Tabelas GenialCare que têm `tenant_id` (set/2026)

`clinical_cases`, `clinical_cases_clinicians`, `objectives`, `int_objectives_enriched`,
`objective_evolution_checks`, `evolution_checks`, `peis`, `fct_sessions`,
`copm_forms`, `copm_form_issues`, `occupational_therapy_registries`, `clinical_agreements`
(praticamente todas as tabelas de domínio).

## Caso real (set/2026 — Farol TO)

O painel "Farol TO" foi portado do Metabase (manual) para BQ direto (ADC) e passou a
mostrar casos da Volarum + "perder histórico". Causa: falta do filtro de tenant. Correção:
adicionar o filtro em todas as queries de `_queries_farol.py` (B/C/D/E/F) e
`_pulls_json.py` (11 JSONs). Documentado em
`documentations/runbooks/painel-acompanhamento-to/runbook.md` §5.6.
