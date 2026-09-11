---
name: de-para-mapping
description: "De-para mapping: link two taxonomies that lack shared IDs."
category: software-development
---

# De-para (mapping between two taxonomies)

No stack GenialCare, "de-para" é o padrão recorrente de ligar **dois domínios que não
compartilham identificadores** — tipicamente uma **avaliação/registro** (itens heterogêneos)
de um lado e uma **biblioteca de objetivos** (IDs estáveis) do outro. Já aparece em pelo menos
três lugares: mapper de Terapia Ocupacional, Vineland (PeiTrack), e Avaliação de Fono.

## Quando usar

- Você precisa mapear **item ↔ objetivo** (ou qualquer "coisa A ↔ coisa B") onde um lado tem
  biblioteca/IDs e o outro é um conjunto heterogêneo de campos/enums sem identificador único.
- Você está planejando exibir "o que está relacionado a cada item" dentro do sistema (não num
  dashboard externo).
- Você precisa de um vínculo que sobreviva a mudanças de regra (recalculável).

## O padrão (4 princípios)

1. **`item_identifier` = o próprio nome do campo/enum que já existe no código.** Ex:
   `limited_speech_movement_range`, `rs`, `searched_for_aac_system`, `echolalia_profile`,
   `lip_appearance`. Chaveado junto com um `domain_type`/`assessment_type` (chave composta).
   Esse nome já é a chave em TRÊS lugares ao mesmo tempo — coluna/enum do model, chave do i18n
   no frontend, e a tabela de de-para. Resultado: o "wiring" é um simples lookup por string,
   **sem metaprogramação** (nada de `send`/`constantize`/reflection).

2. **Regras de match vivem no código (seed), não no banco.** O banco guarda apenas o
   RESULTADO (os pares `(domain_type, item_identifier, feature_name?, target_id)` — `feature_name`
   só existe para itens cruzados). A lógica de match —
   normalização de texto + match exato contra `description` — fica no rake de import. O mapa
   de tradução (nome→identificador) é um **CSV separado** (editável sem deploy), não hardcoded.
   Isso separa "configuração de negócio" (dado) de "como casar" (lógica).

3. **Seed idempotente full-rebuild** (`truncate` + re-import). Se uma regra mudar, o CSV mudar,
   ou a `description` de um alvo mudar, re-rodar o rake reconstrói a base inteira — sem estado
   incremental, impossível ficar "meio certo". O seed deve **reportar os que não casaram**
   (como `missing-objectives-in-mapper.sql` do TO mapper) para detectar fonte fora de sincronia.

4. **Distinguir estático vs dinâmico.** O de-para (item → library objective) é **estático** e
   recalculável. A resolução para o status (library objective → objetivo do PEI + status) é
   **dinâmica** e calculada on-the-fly a cada leitura — nunca materializada, nunca defasada,
   **não precisa de recálculo**. Não confunda os dois: o "recalcular full" só se aplica ao
   estático.

5. **Dimensão cruzada vira coluna, não regra de renderização.** Se um item cruza outra dimensão
   (ex: um "meio" × 9 "funções"), o cruzamento é **dado**: adicione uma coluna (`feature_name`,
   nullable, só preenchida para os itens cruzados) e gere um item por valor cruzado no seed.
   A tabela final tem N linhas por objetivo nesse caso (meio × funções), não uma só. Isso vale
   mesmo quando o frontend *já sabe* a estrutura do cruzamento (enum × enum) — o usuário quer o
   vínculo explícito na tabela, não inferido na hora de renderizar. (Filtros futuros "só mostrar
   quando X" também se apoiam nessa coluna.)
   **Na tela**, exiba os objetivos em **cada** linha/célula da coluna cruzada (ou numa coluna
   dedicada "Objetivos"), NÃO agregado uma única vez num bloco solto/badge de contagem — o
   usuário iterou (toggle → inline → coluna dedicada) e pediu explicitamente a repetição por
   linha. Onde o vínculo é 1 item = 1 linha, coluna dedicada funciona; onde é coluna × N linhas,
   repete o objetivo nas N células.

## Formatos e artefatos (três granularidades)

- **CSV é o padrão do time para import/mapa de tradução** — não YAML/JSON. É editável em
  planilha (onde o time clínico já trabalha) e é o mesmo formato do CSV fonte. Use CSV também
  para o mapa de tradução (`item_name, domain_type, item_identifier`), separado do CSV fonte,
  para o time editar nomes sem mexer em código. YAML/JSON só ganha quando há aninhamento; mapa
  chapado nome→código não tem.

- **Três artefatos, três números** (não confunda — a fonte compacta ≠ tabela expandida):
  1. **Fonte compacta** (orientada ao alvo): uma linha por objetivo, com N itens aninhados na
     MESMA célula (separados por `\n`). Ex: 108 objetivos → 108 linhas.
  2. **Lookup de tradução**: nomes DISTINTOS de item → código. Ex: 44 itens únicos → 44 linhas.
  3. **Tabela de pares expandida**: cada objetivo × cada item = uma linha. Ex: 298 pares (base;
   o cruzamento por dimensão do princípio 5 soma mais linhas ainda — o meio × 9 funções elevou
   a ~329 no caso Fono).
  A expansão (fonte → pares) acontece no seed, resolvendo nome→código pelo lookup. Quando
  alguém perguntar "por que a fonte tem X linhas e não X×N?", a resposta é: a fonte é compacta,
  a tabela final é que explode. Calcule o total real de pares (soma de itens por linha) antes de
  prometer um tamanho de tabela. (Atenção: o total *deduplicado* é menor que a soma bruta — ex.
  298 itens-pares brutos − 1 item que não casa com campo = 297. Dedupe `(domain_type,
  item_identifier, target_id)` no seed.)
- **A tabela expandida é fixture, não input.** A rake lê (fonte + lookup) e expande internamente.
  Não troque o input pela tabela expandida e apague o lookup de tradução: isso quebra o
  \"recalcular full = um comando\" (vira regenerar o expandido + re-rodar, com risco de drift
  silencioso). O expandido serve como valor esperado do seed (fixture de teste) e preview de
  revisão — regere sob demanda quando a fonte mudar, não mantenha como fonte.

- **`item_identifier` em snake_case** (convenção Ruby), NÃO camelCase do frontend. Ex:
  `combines_two_plus_symbols`, não `combinesTwoPlusSymbols`. O frontend mapeia a casing ao
  consultar.

- **Valide unicidade no seed.** O identificador é o nome-folha (sem a sub-tabela), então só é
  único se os nomes não colidirem dentro do domínio. O seed deve reportar colisão de
  `(domain_type, item_identifier)` como erro explícito, não falhar silencioso.

## Alternativa estudada: `domain_path` (path completo)

Em vez de `domain_type` + nome-folha, usar um path completo até o dado (ex:
`speech_motor_control.general_speech_motor_controls.limited_speech_movement_range`).
- Prós: self-documenting (analista vê onde o dado vive sem abrir os models); robusto a colisão.
- Contras: mais frágil a refactor (mais segmentos dão drift); o segmento intermediário é
  derivável do código (YAGNI).
- Decisão: manter `domain_type` + nome-folha; o path é expansão determinística — dá para gerar
  como view no BQ depois, sem redesenhar a tabela.

## Precedentes no GenialCare

- **Vineland (PeiTrack):** o item da avaliação é a MESMA taxonomia do objetivo por construção —
   `VinelandReportSubdomainItemScore` tem `belongs_to :protocol_item` + `has_many :objectives`,
   e `Objective` aponta de volta (`vineland_report_subdomain_item_score_id`). É o precedente de
   "item ↔ objetivo via protocol_item", mas só existe porque ali os dois mundos são um só.
- **TO mapper:** external table (Google Sheets) + `normalize_obj()` (lowercase, trim, colapsa
   espaços, aspas curvas→retas) + `missing-objectives-in-mapper.sql` para auditar sem match.
- **Ligação dupla (Library ↔ PEI Objective):** `Objective` referencia `library_objective_id`
  **ou** `protocol_item_id` (ambos opcionais). O join de resolução precisa cobrir os DOIS
  caminhos, senão objetivos que só têm `protocol_item_id` ficam de fora.
- **Ordem canônica das 5 sub-avaliações de Fono** (fonte: type `SpeechTherapyAssessmentTypes` em
  `clinical-panel/src/types/assessments/speechTherapy.ts`): `expressive_communication` →
  `phonological` → `speech_motor_control` → `orofacial_myology` →
  `augmentative_and_alternative_communication` (Comunicação Expressiva primeiro). Ao montar
  tabs/protótipo, siga essa ordem — não é alfabética, e começa por Comunicação Expressiva.

## Trade-offs da forma do de-para

| Forma | Prós | Contras |
|---|---|---|
| **Tabela de pares** (config) | Editável sem deploy; fonte única reutilizável; seedável do CSV | Exige convenção de `item_identifier` + seed |
| **Constante em código** | Sem tabela; identificadores já são código; type-safe | Deploy p/ mudar; não reutilizável por BQ/outras camadas; duplica o CSV |
| **Híbrido** | Normalização no código + pares na tabela | Mais complexidade |

**Recomendação default: tabela de pares.** O de-para é configuração de negócio que o time
clínico itera (é literalmente uma planilha), então precisa ser editável e reutilizável.

## Genérico vs específico (duas camadas de de-para)

O de-para descrito acima é **genérico** (tipo de item → objetivo, por `item_identifier` string).
Existe uma camada **específica** possível (instância preenchida → objetivo, por FK real) — a
distinção importa ao modelar:

- **Genérico:** mapeia o TIPO ("todo `limited_speech_movement_range`, em qualquer avaliação").
  Referencia o item por string (`domain_type` + `item_identifier` + `feature_name`) porque o item
  não tem biblioteca/ID próprio. Sem integridade referencial no lado do item.
- **Específico:** mapeia a INSTÂNCIA ("o item `request_attention` da avaliação do caso 450"). Pode
  ter FK polimórfica (`itemable_type` + `itemable_id` → `library_objective_id`) com integridade.

**O obstáculo: itens heterogêneos (linha vs coluna).** Só itens que são LINHAS de tabela têm ID
para a FK polimórfica:
- Linha (têm ID): `expressive_communication_features`, `communication_skills`,
  `phonological_atypical_processes` — polimórfico funciona.
- Coluna (não têm ID): `general_speech_motor_controls.limited_speech_movement_range`,
  `physical_conditions`/`orofacial_functions` — o "item" é um campo, não entidade. Precisaria
  apontar para a sub-avaliação + um discriminador `column`, fora do polimórfico puro.

**Dois caminhos para a camada específica com integridade:**
1. **Polimórfico + discriminador de coluna** — funciona, mas fica assimétrico (linha vs coluna).
2. **Normalizar itens preenchidos numa tabela de resultados** (ex. `assessment_item_results`): cada
   item preenchido vira uma linha com ID, uniforme para linha E coluna. É o que a Vineland já faz —
   `VinelandReportSubdomainItemScore` é a tabela de "item pontuado" com `belongs_to :protocol_item`.
   Fono hoje não tem essa tabela de resultados, por isso só o genérico é possível sem refactor.

**Quando a camada específica vale a pena** (não construa antecipadamente — só com necessidade
concreta):
- **Override por caso** (o clínico ajusta o vínculo de UM caso).
- **Auditabilidade** ("quais objetivos foram vinculados a este item nesta data?").
- **Geração de objetivos** a partir da avaliação (como a Vineland) — aí o específico é obrigatório.

Para exibição/consulta pura, o genérico + resolução dinâmica (library objective → objetivo do PEI)
já resolve. A camada específica pode apontar para o `generic_de_para_id` (traceabilidade) ou
sobrescrever o `library_objective_id` (override) — e pode ser adicionada DEPOIS sem re-trabalhar o
genérico, que já deixa o gancho pronto.

## Pitfalls

- **Não tente unificar os itens num enum só.** Os itens são estruturalmente diferentes: alguns
  são *campos* (Bandeiras Vermelhas, CAA, Motricidade — campo com valor sim/não), outros são
  *valores de enum* (Imitação — processo fonológico), e Comunicação Expressiva mistura os dois
  (um "meio" que cruza N funções). Use `item_identifier` em string + `domain_type`, não force
  uma taxonomia única.
- **O "meio" que cruza feature_name** (ex: `combines_two_plus_symbols` × 9 `feature_name`s) é o
  único caso que não é campo/enum simples. **Materialize o cruzamento na tabela**: adicione uma
  coluna de dimensão (`feature_name`) e gere UM item por valor cruzado (meio × N funções = N
  itens, cada um apontando para os mesmos objetivos). **NÃO** deixe como regra de exibição do
  frontend ("o meio aplica-se a todas as funções") — o usuário quer o vínculo completo expresso
  no dado, para cada item. Isso já foi corrigido explicitamente num caso real: o cliente rejeitou
  "é regra de frontend" e pediu o cruzamento na tabela.
- **Match por texto tem armadilhas de truncamento/empatar**: `bq query --format=csv` trunca em
  100 linhas sem aviso (use `--max_rows`); fuzzy match top-N esconde o candidato certo quando
  itens de outro fonema/mesma configuração têm ratio quase idêntico — extraia a dimensão
  discriminante (ex: fonema via regex) e filtre por ela ANTES de comparar configuração.
- **Células malformadas na fonte** (itens colados com `.`/`;` em vez de `\n`) quebram o parser
  ingênuo. Corrija na fonte OU detecte programaticamente (scan de múltiplos prefixos de item na
  mesma linha) e trate no seed.
- **Não confunda "mesmo texto com outra redação" com "dois campos".** Antes de criar um campo
  novo, confirme se é só inconsistência de redação (vale confirmar com o time clínico). Ex:
  "Combinação de dois ou mais símbolos" = "Combina mais de dois símbolos" = um campo só.

## Direção inversa (objetivo → itens) — mesmo de-para

O de-para é **N:N simétrica**: a mesma tabela serve para as **duas direções**, sem adaptação de
dado.

- **Forward (item → objetivos):** dado `(domain_type, item_identifier, feature_name)`, quais
  `target_id`? — exibido na tela de avaliação.
- **Inversa (objetivo → itens):** dado `target_id`, quais `(domain_type, item_identifier,
  feature_name)`? — exibido num "roadmap" de objetivos.

Só muda a **consulta** (join invertido) e a UI; tabela, CSV e seed são os mesmos. Ao comparar as
duas direções (usuário pediu um comparativo explícito), **não duplique o de-para** — reutilize a
tabela e adicione apenas um endpoint de consulta invertida.

### A visão inversa precisa do RESULTADO (não só a descrição do item)

No roadmap inverso, listar só a **descrição** do item não basta: o usuário quer o **resultado** da
avaliação (ex: "Não realiza", "Alterada", "Presente", "2 ocorrências"), porque é o resultado que
mostra **por que** o objetivo existe — o gap. Sem ele, a visão inversa é uma lista morta de
"objetivo → item" sem o "e o item estava assim".

- **O resultado NÃO vive no de-para.** O de-para só diz *qual item ↔ qual objetivo*. O resultado
  vem do **dado da avaliação preenchida** (o valor registrado na tela de avaliação). Então a visão
  inversa precisa de **dois joins**: (1) de-para invertido (objetivo → itens) + (2) avaliação
  preenchida (item → resultado). É a mesma avaliação que a direção forward já exibe — só muda o
  ponto de entrada.
- **O "resultado" tem TRÊS formatos** (leia os tipos reais de cada sub-avaliação antes de assumir
  que é um valor único), e o formato define a representação:
  1. **Escalar** (campo string/enum — Bandeiras Vermelhas "Presente/Ausente", Motricidade
     "Adequada/Alterada", CAA "Sim/Não/Não observado") → badge único.
  2. **Frequência + checkboxes/perfil** (Comunicação Expressiva: `performedFrequency` + meios
     `CheckedField` por função) → dois elementos; um meio vira contagem ("realiza em **0/9**
     funções"), não booleano.
  3. **Contagem + contexto** (Imitação: processo com `quantity` distribuído em palavras com
     transcrição + checkbox de acerto) → **não cabe num badge**; mostrar agregado ("2 ocorrências
     · 1 palavra") + drill-down/link para a avaliação. NÃO duplique a UI de transcrição/checkboxes
     na visão inversa — ela responde *"por que o objetivo existe"* (gap + magnitude), não substitui
     a tela de preenchimento.

### Inspiração: PeiTrack (a direção inversa já existe p/ Vineland)

O PeiTrack (`intervention_pei_tracks` → `module_progresses` → `module_progress_items`) é o
"roadmap" que nasce populado com todos os LibraryObjectives da Vineland: cada linha = item de
protocolo que pode virar um Objective do PEI, com status sintetizado (objetivo + resultado
Vineland + manual). O ponto de partida é a **Library Objective** (catálogo, estável), com o
Objective do PEI (status) como coluna — espelha `objective: Objective | null`.

**Não reutilize o PeiTrack direto p/ Fono:** ele computa percentual por módulo e usa
`ModuleProgressItemStatuses` (`completed_by_vineland` etc.) que Fono não tem — inserir objetivos
de Fono ali contaminaria as métricas de Vineland/Psico. Faça uma tela **separada** inspirada no
PeiTrack (reusa `ObjectiveStatuses` + padrão de tabela de objetivos), com a coluna "avaliações
relacionadas" no lugar de "domínio/subdomínio/item".

Ver user story `20260908-objetivos-referenciando-avaliacoes-fono` (alternativa inversa,
comparativo com a forward `20260903-vinculo-objetivos-itens-avaliacao-fono`).

## Ver também

- `references/fono-assessment-objectives.md` — exemplo trabalhado completo (Avaliação de Fono ↔
  Objetivos do PEI): tabelas, item_identifiers, decisões tomadas com o time clínico.
- `references/fono-bq-data-extraction.md` — lado dinâmico: tabelas BQ (assessment/intervention),
  filtro por protocolo `Fonoaudiologia`, enum de status reais (`completed/validated/rejected/
  pending/in_maintenance`), e como achar casos-teste ricos + casar de-para × PEI por descrição.
- User story `20260903-vinculo-objetivos-itens-avaliacao-fono` no repo product-engineer-agent
  (analysis.md / PRD.md / todo.md) e o `de-para-csv-sistema.md` do discovery de Fono.
