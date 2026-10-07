# Regras de carga horária (workload) no core — mapa para mudanças de regra

Mapa técnico consolidado do domínio de workload (carga horária) da GenialCare, valido
para planejar mudanças de regra por operadora (matriz, limiting, carga default). Fonte:
investigação da user story `20260930-amil-nova-regra-carga-horaria` (set/2026), com
código verificado no repo. Decisões finais marcadas com ✅ DECIDIDO (as alternativas
analisadas ficam para registro). Doc canônica do fluxo completo:
`documentations/features/workload-carga-horaria/doc.md` no product-engineer-agent.

## Anatomia da regra por operadora (o que uma "nova regra" precisa tocar)

| Conceito | Onde vive | Padrão |
|---|---|---|
| Matriz de horas por delay level | `packs/clinical/app/concepts/clinical_case_workloads/services/<operadora>_workload.rb`, herda `BaseWorkload` (`define_workload`) | `DefaultWorkload`, `PortoWorkload`, `BradescoWorkload` |
| Escolha da matriz | `CalculateWorkload#workload_class` (chain: bradesco_group? → porto_seguro? → default) | branch novo entra ANTES do default |
| Limiting (dropdown + validação) | `Services::WorkloadLimits` — único ponto; só 2 consumidores: `WorkloadLimitsController#show` e `CreateWorkload#validate_limits` | branch por operadora (só Porto tem hoje) |
| Hardlock por disponibilidade | dentro do `BradescoWorkload` (`should_reduce_workload?`) | feature flag por clinical_case.id |
| Carga default de contrato | `Agenda::Services::ChildWorkload#get_default_workload` (por pricing_model) → `General::UseCases::CreateDefaultWorkload` quando `contract.default_workload_applied` | 5/2/2 (ou 3/2/2 se fee_per_day) |

## Consequências do fato "todo caminho passa pelo CreateWorkload"

Quem cria `ClinicalCaseWorkload` (todos via `ClinicalCaseWorkloads::UseCases::CreateWorkload`,
que valida limites):

1. Primeira Vineland (`CalculateWorkload#create_workload`, author=system_user)
2. Aprovação de sugestão (`ApproveSuggestedWorkload` → subprocess CreateWorkload)
3. Reprovação com correção (`ReproveSuggestedWorkload` com workload_input)
4. Edição manual no painel (endpoint POST)
5. Carga default de contrato (`CreateDefaultWorkload` → subprocess, `default_value: true`)

**Implicação:** uma validação nova no `CreateWorkload` automaticamente cobre TODOS os
caminhos — incluindo aprovação de sugestão. Não precisa replicar validação por fluxo.
E qualquer exceção precisa considerar o caminho 5 (ex: carga default administrativa vs
prescrição clínica — ver pegadinha abaixo).

## Limite por TOTAL vs limite por ITEM (o problema estrutural)

O contrato de limiting hoje é `{disciplina => {min, max}}` por disciplina isolada. Um
teto por total (soma ABA+Fono+TO) **não é expressável nesse shape fixo**, porque o max
de cada disciplina depende do que já está prescrito nas outras. E o form do painel
(`WorkloadsForm.tsx`) submete **uma disciplina por submit** (radio de disciplina +
dropdown), então cada POST é validado isoladamente.

**Solução adotada (híbrido, da story Amil):**
1. Endpoint calcula **max dinâmico por disciplina**: `max = min(max_da_matriz, teto_total − soma_das_outras_vigentes)` via `active_recommended_for(discipline)` (exclui parent_training — `dependent_exclusive_hours`). `min = 0`.
2. Payload ganha campo opcional aditivo `total: {max: <teto>}` (BFF cameliza; FE reage à presença do campo — sem flag no frontend).
3. Backend valida a soma no `CreateWorkload` (fonte da verdade): `outras_vigentes + horas_novas > teto` → erro com teto e remanescente na mensagem (pt-BR, pipeline I18n — ver `genialcare-error-messages.md`).
4. **Exceção "total resultante == total vigente"** — análoga à exceção por disciplina existente (`create_workload.rb`, "aceita se horas == carga vigente"). Sem ela, casos legados acima do teto ficam travados (31 casos Amil rodavam > 9h na regra default).
5. Dropdown sempre inclui o valor vigente da disciplina como option mesmo acima do max dinâmico (espelha a exceção 4 no FE) — idem para o valor sugerido pré-preenchido no fluxo de reprovação (`initialValues.hours` da sugestão pode exceder o max dinâmico).
6. Condição de corrida (dois editores, limits obsoletos) é aceitável — backend rejeita com mensagem clara; mesma situação já existe no fluxo Porto.

**Por que NÃO as alternativas:** validação só no backend = UX ruim (erro só no submit);
form único das 3 disciplinas = quebra contrato + regressão em Porto/Bradesco/sugestões;
calcular max dinâmico só no FE = duplica regra e precisa dos vigentes no form.

## Identificação de operadora: DOIS lados, padrões diferentes

- **Finance** (`Finance::InsuranceHealthPlan`): tem `integration_alias` → `amil?`, `porto?`, `bradesco?`, `mediservice?` etc. Confiável.
- **Clínico** (`General::InsuranceHealthPlan`, o `clinical_case.health_plan`): só `name`, `cnpj`, `finance_insurance_health_plan_id`. **Sem alias — e não pode ter**: `packs/clinical/package.yml` só depende de `app`/`packs/domain_configuration`; o pack clinical não pode referenciar `Finance::InsuranceHealthPlan` (vive em packs/operational; direção permitida é operational → clinical). Essa é a **razão estrutural** do matcher por nome; propagar o alias exigiria mudar sync + contract + coluna (normalmente fora de escopo). O pattern existente é matcher por nome exato: `bradesco_group?` = name in ["Bradesco Saúde", "Bradesco Saúde - Operadora", "Mediservice"]; `porto_seguro?` = name == "Porto Seguro Seguro Saúde".
- O nome clínico é copiado do finance em `CreateOrUpdateFamily → SetInsuranceHealthPlan` (`find_or_create_by` por clinical_case — 1 plano clínico por caso). **O nome clínico é snapshot congelado**: renomear o plano finance NÃO atualiza casos antigos (só re-sincroniza quando a família passa de novo pelo `CreateOrUpdateFamily`).
- **`in_effect_since` ≠ data de criação**: o workload default de contrato nasce com `in_effect_since = contract.start_date` (data de **negócio**, pode ser retroativa/futura); `created_at` é o momento real da inserção. Para cutoffs/grandfathering, compare **`created_at`** (quando a família passou a ter prescrição de fato), não `in_effect_since`.
- **Precedentes de cutoff no core** (pattern `Date.new(...).freeze` + comparação `>=` com data de negócio): `TAX_RESPONSIBILITY_BENEFICIARY_CUTOFF_DATE` (`fiscal_invoice.rb:16`) e `REPLACEMENT_INCENTIVE_START_DATE` (`replacement_session_incentive_factory.rb:35`).

**Pegadinha de variante de plano (decidida na story Amil, 30/09/2026):** planos clínicos
com "Amil" no nome = `"Amil"` (115 casos) **e** `"Amil One"` (14 casos). A análise inicial
recomendou cobrir ambos defensivamente — **ERRADO**: o usuário decidiu que a regra vale
**apenas para "Amil"** ("Amil One é plano premium que não entra na mesma regra").
✅ DECIDIDO: matcher exato `name == "Amil"`. Verificação em produção que tornou o matcher
exato seguro: os 14 "Amil One" são snapshots legados (6 ativos, todos com plano atual
"Amil"; casos de 2024–2025, primeiro workload pré-corte) e **não existe plano finance
"Amil One" ativo** — sem registro finance ativo, não há caminho para novos casos clínicos
com esse nome. Lição: variante de nome de plano é decisão de negócio, não cobertura
defensiva — perguntar ao usuário e verificar em produção (ver
`production-data-for-scoping.md`).

## Feature flag de regime

Precedentes: `enable_hardlock_bradesco_workload` (key = clinical_case.id, consultada
dentro do service de matriz) e `enable_create_suggested_workload` (key =
vineland_report_id). Catálogo: `app/services/feature_flag.rb` (Split.io). Splits são
criados no dashboard do Split.io (não há rake); env de teste lê `config/split.yaml`
(adicionar o split novo com `treatment: 'off'`).

Proposta inicial da story Amil era flag por clinical_case.id (rollout gradual por caso).
✅ DECIDIDO (30/09/2026): **flag liga/desliga global**, sem key por caso — o usuário
preferiu simples (ligou, vale para todos do regime novo; desligou, kill-switch total).
Mantém: flag única no core; o painel NÃO lê flag — reage ao payload (`total` opcional).
Elimina inconsistência FE/BE (flag off → payload volta ao shape atual → FE volta ao
comportamento atual). A granularidade por caso continua possível no futuro sem mudança
de contract.

## Naming para regras com cohort: codificar o cohort no nome

✅ DECIDIDO (30/09/2026): classes/flag/constante carregam o cohort no nome, não só a
operadora — `NewAmilWorkload`, `NewAmilRegime`, `enable_new_amil_workload_rule`,
`NEW_AMIL_WORKLOAD_RULE_CUTOFF`. Motivação (proposta do usuário): o nome é a primeira
defesa contra o erro de alguém, meses depois, despachar por plano sem passar pelo
resolver do regime e aplicar a regra a um caso legado. Preferir **positivo**
(`New<Operadora>*`) a dupla negativa (`NonLegacy*` — exige salto mental e "legacy" não
é termo do codebase). Rejeitados: `<Operadora>NewCases*` (verboso), `<Operadora>V2*`
(ambíguo quando houver V3 do acordo). A regra vale para qualquer feature com
grandfathering: o nome do artefato deve expressar o cohort, não apenas o domínio.

## Grandfathering de regra: primeiro workload, não created_at

Critério adotado: `MIN(clinical_case_workloads.created_at) WHERE workload_type =
'recommended_hours'` (default_scope já filtra kept — delete é soft via `discard`)
>= data de corte. Nil (sem workload) conta como família nova. Razões: (1) "família em
intervenção" = tem prescrição, não tem caso criado; (2) resolve o cohort de casos
antigos sem carga (26% da base Amil); (3) os dois critérios coincidem para famílias
genuinamente novas; (4) query indexada por clinical_case_id. Nuance: o MIN nem sempre
é o default do contrato — casos sem "aplicar prescrição padrão" têm primeiro workload
só na primeira Vineland (reforça o critério: o que caracteriza intervenção é ter
qualquer prescrição).

**Encapsular a decisão num resolver único** (plano + corte + flag), consumido TANTO pelo
`workload_class` quanto pelo `WorkloadLimits` — senão matriz e limiting divergem.

## Pegadinhas específicas do domínio

- **"Psico" = ABA**: a disciplina `aba` mapeia para a especialização "psychology"
  (`Enum::ClinicalDisciplines.discipline_to_specialization_mapping`). O negócio fala
  "psico/fono/TO"; o domínio é aba/speech_therapy/occupational_therapy.
- **Carga default de contrato vs teto novo** — ✅ DECIDIDO (30/09/2026): carga default
  (`default_value: true`) é **isenta** da validação de total (teto valida prescrição
  clínica, não carga administrativa; a primeira Vineland sobrescreve conforme a matriz).
  Contexto: carga default de contrato depende do pricing_model — 5/2/2 = 9h (não
  fee_per_day) ou 3/2/2 = 7h (fee_per_day). **Conferir o pricing_model em produção,
  nunca nos seeds**: o plano Amil real é `fee_for_service` (default 9h) embora a
  suposição inicial fosse fee_per_day (7h) — os 2h de diferença invertiam a análise de
  teto. Sem a isenção, o `CreateDefaultWorkload` de um contrato novo com delay
  int/moderate (teto 7h) seria rejeitado.
- **`no_delay` na primeira avaliação usa a matriz de `mild`** (intervenção mínima
  garantida, `calculate_workload.rb` ~linha 68). ✅ DECIDIDO: matriz nova define
  `no_delay` = `mild` explicitamente (mesma regra).
- **`apply_minimum_workload_rule`**: reavaliação nunca aumenta carga — `min(matriz,
  carga_atual)`. Não mexer; já protege o teto no fluxo de reavaliação.
- **`shared_schedule_hours` (Brincar Juntos) já é isenta de limiting** (early return em
  `validate_limits`) e só existe para ABA.
- **`clinical_case_reference` é isenta dos limites Porto** (agenda flexível) — para teto
  de operadora (Amil), recomendação é NÃO isentar (regra da operadora, não de agenda);
  confirmar com negócio (ficou como pergunta menor em aberto na story Amil).
- **Consumidores downstream não mudam com regra nova de matriz/limiting**:
  `AllocationLimiting` (operacional, job diário) e `WeeklyWorkloadLimitForFeeForService`
  (regra de agenda Amil FFS, lê workload persistido por disciplina) leem o workload
  persistido, que continua existindo normalmente.
- **Contrato REST/GraphQL do limiting**: core devolve snake_case `{aba:
  {min, max}, speech_therapy: ..., occupational_therapy: ...}`; BFF cameliza
  (`transformResponse`) para `{aba, speechTherapy, occupationalTherapy}`; type-defs em
  `clinical-panel-bff/src/schema/workloads/type-defs.graphql`. Campo novo é aditivo e
  opcional (pattern de contrato aditivo do reference cross-repo-analysis). Shape
  travado por request spec (`clinical_case_workload_limits_spec.rb` — `match_array` das
  keys) e teste de integração do BFF — ambos precisam de update ao adicionar campo.
- **Dropdown do painel**: `WorkloadsForm.tsx` gera um option por inteiro no loop
  `for i = min; i <= max` — max dinâmico no endpoint não exige mudança no loop, só
  garantir option do valor vigente e (desejável) texto do teto/remanescente. O edit
  manual NÃO passa `initialValues` (form começa vazio); o fluxo de reprovação
  pré-preenche as horas da **sugestão** (não da vigente).
- **Mensagens de erro**: pipeline pt-BR do core existe (I18n com default inglês) mas
  tinha dois gaps de ponta a ponta — BFF não repassava `Accept-Language` e o controller
  de workloads tinha bug no branch JSON de erro (devolvia 500). Mapa completo e
  checklist: `genialcare-error-messages.md`.

## Dados de produção de referência (genialcare, 2026-09-30)

Números que embasaram as decisões da story Amil — re-coletar em stories futuras (mudam):

- Plano finance Amil: único, alias `amil`, `fee_for_service` → carga default de contrato 5/2/2 = 9h.
- Planos clínicos com "Amil": "Amil" 115 casos (99 ativos) + "Amil One" 14 (6 ativos, todos com plano atual "Amil").
- 88/129 casos com workload; 34 antigos sem workload nenhum (26% — decidiram o critério de grandfathering); 5 com primeiro workload desde set/2026; 31 casos com total vigente > 9h (maioria 11h = matriz default severa).
- Distribuição do total vigente: 6h:15, 7h:6, 8h:7, 9h:17, 10h:5, 11h:16, 12h:3, 13h:2, 14h:1, 15h:3, 16h:1 (+ menores).
