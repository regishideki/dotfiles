# Embasando decisões de escopo com dados de produção (read-only)

Quando a user story envolve uma decisão que depende de **quantos/quais registros são
afetados** — data de corte (grandfathering), rollout gradual, dimensionamento de backfill,
"vale a pena migrar os existentes?" — recomendar sem dados é chutar. A stack GenialCare
permite consultar produção read-only via `rails runner` no pod, e a consulta muda a
recomendação de forma concreta.

## Caso que originou este reference

User story `20260930-amil-nova-regra-carga-horaria`: escolha entre critério de
grandfathering por `clinical_case.created_at` vs data do primeiro workload. A consulta
de produção revelou que **34 dos 129 casos Amil (26%) eram antigos e não tinham nenhum
workload** — com `created_at` ficariam para sempre na regra antiga; com "primeiro
workload" receberiam a regra nova na primeira prescrição. O dado transformou uma
escolha discutível em recomendação clara (critério do primeiro workload).

## Como invocar (forma que funciona)

```bash
# 1. Autenticar SA e limpar cache do plugin (ver memória: kubectl SA regis-automation)
gcloud auth activate-service-account --key-file=$HOME/.config/gcloud/regis-automation-sa-key.json
rm -f ~/.kube/gke_gcloud_auth_plugin_cache

# 2. Descobrir o pod (namespace core, container chama-se "web")
kubectl get pods -n core | grep web

# 3. Rodar com script inline entre aspas simples (heredoc via stdin falha silenciosamente!)
kubectl exec -n core <pod> -c web -- bin/rails runner '<SCRIPT AQUI>' 2>&1 | grep -v "INFO\|WARN"
```

**Pitfalls de invocação (todos ocorreram na sessão de 2026-09-30):**

- **`kubectl exec ... -- bin/rails runner - <<'EOF'` não funciona**: o runner lê `-` mas o
  output do script nunca aparece (stdout some). Passar o script **inline entre aspas
  simples** funciona: `bin/rails runner 'puts "X"'`.
- **Container não se chama `app`**: no namespace core o container é `web`
  (`kubectl get pod <p> -o jsonpath='{.spec.containers[*].names}'` para confirmar).
- **Logs de boot afogam o output**: boot do Rails imprime ~30 linhas de WARN/INFO (enums,
  Split.io, datadog). Filtrar com `2>&1 | grep -v "INFO\|WARN"` e marcar o resultado com
  prefixo tipo `puts "RESULT: " ...` para grep fácil.
- **Read-only estrito**: só SELECTs/pluck/count/minimum. Nunca update/create via runner
  em produção (política registrada em memória).
- **Exit 137 = pod OOM-killed no meio da query** — refazer em outro pod (`kubectl get pods`
  de novo) e simplificar a query (menos `inspect` de objetos grandes, mais contagens).
- **Query sem output visível ≠ "não há dados"** — antes de concluir isso, verificar as
  quirks de output acima (heredoc, filtro de logs, prefixo RESULT).

## Padrão do script (multi-tenant, com rescue por tenant)

```ruby
results = {}
Tenant.find_each do |tenant|
  ActsAsTenant.with_tenant(tenant) do
    begin
      # ... queries read-only aqui ...
      results[tenant.name] = { metrica: valor }
    rescue => e
      results[tenant.name] = { error: e.class.name }
    end
  end
end
puts "RESULT: " + results.inspect
```

Se a métrica só existe num tenant relevante (ex: genialcare), iterar direto com
`ActsAsTenant.with_tenant(Tenant.find_by(name: "genialcare"))` para reduzir ruído.

## Cohorts de borda que valem medir (exemplos do caso Amil)

1. **Total da população** vs **população com o dado relevante** (129 casos vs 88 com
   workload) — revela o tamanho do "limbo".
2. **Registros antigos SEM o dado** (34 casos sem workload) — o cohort que diferencia
   critérios alternativos de corte; é a métrica que decide entre created_at vs
   primeira-ocorrência.
3. **Distribuição do valor vigente** (histograma de totais: quantos casos a 6h, 7h, 9h,
   11h+) — quantifica quem seria "travado" ou "reduzido" pela regra nova.
4. **Contagem acima do limite novo** (31 casos > 9h) — dimensiona o impacto se a regra
   fosse retroativa; justifica o grandfathering.
5. **Nomes/valores reais de enum-like data**: ex: planos clínicos contendo "Amil" são
   `"Amil"` (115) e `"Amil One"` (14) — dois nomes, não um. Sempre consultar os valores
   reais antes de escrever matcher por nome (o lado clínico não tem `integration_alias`).
6. **Legado vs ativo** — `discarded_at: nil` no caso + `child.current_contract&.churned_at`
   + plano ATUAL do child vs plano do registro clínico: distingue "snapshot congelado de
   renomeação" de "dado atual" (os 14 "Amil One" em produção tinham todos plano atual
   "Amil" — eram snapshot legado de renomeação, não população ativa do produto premium).
7. **Valor de config em produção, nunca nos seeds** — pricing_model/integration_alias/
   feature flag: seeds divergem da produção (seed "Amil One" vs produção "Amil";
   pricing_model assumido `fee_per_day` era `fee_for_service`, mudando a carga default
   de 7h para 9h e invertendo a análise de teto). Assumir errado até verificar.

## Depois de coletar: conferir a aritmética das interpretações

Antes de escrever conclusões sobre a distribuição coletada, recomputar somas/totais e
bater cada pico com a regra/matriz que o produziu — na sessão Amil (2026-09-30), o pico
de 11h foi atribuído à matriz severa (11/2/2) quando 11h = moderada (7/2/2); a severa
soma 15h e aparecia em 3 casos. Erro de aritmética em dado de produção é contestação
imediata — e a releitura final da story que pegou esse erro salvou o doc.

## Onde registrar nos docs da story

- analysis.md → seção "Dados técnicos relevantes": tabela de métricas com data da consulta
  (dados de produção envelhecem).
- analysis.md → a decisão que o dado embasa cita a métrica explicitamente
  ("34/129 casos antigos sem workload → critério do primeiro workload").
- PRD.md → critérios de aceite podem citar números quando eles definem "pronto"
  (ex: casos legados mantêm comportamento).
- Datas de corte ficam como constante única + placeholder declarado, com nota de quais
  cohorts ficam de fora com aquele corte específico.
