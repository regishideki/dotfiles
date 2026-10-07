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

## Auditoria de completude: classificar os "sem correspondência"

Quando o seed reporta alvos (objetivos) sem match, **não trate todos como o mesmo problema**.
Classifique cada um em duas naturezas opostas antes de decidir — juntar tudo num "N sem
correspondência" esconde que parte deles deveria existir:

- **Gap de catálogo** (deveria existir, falta no sistema): objetivo clinicamente válido que a
  biblioteca simplesmente não tem. Ex Fono: `/s/` e `/r/` Monossílabos — o sistema só tem esses
  fonemas em Dissílabos/Trissílabos. Implicação **mais forte que "não aparece na página"**: o
  objetivo não existe no catálogo, logo a terapeuta **nem consegue criá-lo no PEI**. O gap do
  de-para é *sintoma* de um gap de catálogo — corrigir é tarefa de dados/catálogo, não do de-para.
- **Descartado na migração** (dead data): objetivo removido intencionalmente. Ausente está certo;
  não ressuscitar.

### Como diagnosticar RÁPIDO (antes de classificar)

O próprio seed já separa as duas naturezas se você rodar em **DRY_RUN**:

```
DRY_RUN=true bundle exec rake <import_task> TENANT_NAMES=<tenant>
```

Ele imprime `Objectives without a library match (N)` com o **número de linha do CSV** e
`Items without a translation (N)`. Esse é o caminho mais curto para a lista exata de gaps — não
derive por comparação manual protótipo × banco.

**Armadilha do `discarded_at` (a causa mais comum de "sem match" que não é gap de catálogo):**
o rake de match usa escopo `.kept` (filtra `discarded_at IS NULL`). Um objetivo que **existe na
biblioteca mas está soft-deleted** é reportado como "sem match" mesmo estando lá. Então, para cada
objetivo "sem match", antes de concluir "falta no catálogo", rode:

```sql
SELECT description, discarded_at IS NOT NULL AS discarded
FROM intervention_library_objectives
WHERE description ILIKE '%<trecho>%';
```

- `discarded = t` → é dead data (objetivo renomeado/removido e a versão antiga descartada). No
  Fono, **todos** os 6 "sem match" (vogal tônica, entonação de frases, lábios fechados, navega
  entre as pranchas, `/s/` Monossílabos, `/r/` Monossílabos) eram: 4 descartados + 2 realmente
  ausentes. Classificar como "tudo gap de catálogo" levaria a criar objetivos duplicados.
- `discarded = f` ou `0 rows` → gap de catálogo genuíno (criar é decisão de produto/dados).

Note também que a biblioteca pode guardar **duas redações** do mesmo objetivo (a antiga do CSV e a
renomeada), ambas descartadas — sinal de revisão de catálogo, não de erro no de-para.

Riscos downstream que merecem verificação (não assuma que o único efeito é "some da tela"):

1. **Órfão de PEI** — se a migração que descartou um objetivo deixou `intervention_objectives`
   pendurados nele, ele "existe no PEI da criança mas some da tela" (nem o de-para nem o join de
   resolução o resgatam). Uma query por objetivos apontando para `library_objective_id` /
   `protocol_item_id` inexistente resolve em minutos.
2. **Drift do seed** — o full-rebuild é manual; quando o catálogo ganhar o objetivo faltante,
   alguém precisa atualizar o CSV + re-rodar o rake. Não há automação vigiando o catálogo.
3. **Perda de confiança** — a terapeuta assume a lista por item exaustiva; gap em fonema de alta
   frequência (`/s/` ceceio, `/r/` rotacismo) parece bug. Precedente real de confiança no de-para:
   TO mapper, caso 491.
4. **Assimetria suspeita** — `/rr/` Monossílabos existe mas `/r/` Monossílabos não; inconsistência
   que parece erro de cadastro, não decisão. Registre o porquê para não parecer bug.

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

## Versionando o CSV fonte quando o especialista de domínio corrige

Quando o time clínico grava um vídeo explicando uma correção e sobe uma planilha atualizada:

1. **Não sobrescreva o CSV antigo.** Copie o antigo para `<nome>.v1.csv` (histórico) e o novo
   para `<nome>.v2.csv` (vigente), ambos na pasta da story/skill que consome o de-para. Atualize
   os pontos de leitura (rake/seed docs, `analysis.md`, `todo.md`) para apontar para a versão
   vigente, com uma nota "histórico: `.v1.csv`".
2. **Valide a transcrição contra o diff real antes de documentar o achado.** Transcrição de
   vídeo tem erros de reconhecimento; não confie só na fala para descrever "o que mudou" — rode
   um diff entre a versão antiga e a nova e confirme linha a linha que o texto da transcrição
   bate com a mudança real. Normalize quebras de linha (CRLF vs LF) antes do diff — CSVs
   exportados de planilha turvam o diff com ruído de terminador de linha em toda linha idêntica;
   sem normalizar, um diff de 3 mudanças reais aparece como 300 linhas modificadas.
3. **Confirme se a correção é reordenação/dado (não regra nova).** Pergunta recorrente do
   usuário: "isso mudou uma regra condicional ou só reorganizou o de-para?". Responda contando
   ocorrências de termos-chave antes/depois (`old.count(term)` vs `new.count(term)`) e inspecionando
   se alguma coluna nova de condição apareceu — se não, é dado/ordem, não lógica. Documente essa
   distinção explicitamente na análise (o de-para geralmente é só dado; "quando sugerir" é regra
   condicional, categoria separada — ver seção "Regra de recomendação" no domínio Fono).
4. **Quando o usuário pedir para incorporar a v2** (não só analisar), o fluxo completo é:
   1. Adicione ao lookup de tradução (`item-name-to-identifier.csv`) qualquer item novo que a v2
      introduziu e que ainda não tinha `item_identifier` — nomeie o campo seguindo a convenção
      real do código-fonte quando possível (ex: se o CSV cita "Meios Não Convencionais" e o
      frontend tem um campo `uses_non_conventional_means`, use esse nome, não invente um novo).
   2. Regenere a tabela expandida a partir da v2 + lookup atualizado (mesmo script/lógica de
      sempre: split de itens por linha, resolve nome→`item_identifier`, expande cruzamentos por
      dimensão). Confira que **0 itens ficaram sem match** antes de prosseguir — se algum item
      não casar, é sinal de que o lookup ainda está incompleto, não que a v2 tem erro.
   3. Se houver protótipo/UI consumindo listas hardcoded de objetivos por item (constantes JS
      tipo `CE_COMBINES`, `caa`), atualize-as para refletir os novos vínculos — não baste trocar
      o CSV e esquecer o protótipo, ele é o artefato que o usuário de fato revisa visualmente.
   4. Rode a suíte de protótipos (`prototypes:test` + `prototypes:build` + `npm run build`) e
      abra o protótipo no navegador para confirmar visualmente (ligar o toggle e checar a coluna
      de objetivos) — não confie só na ausência de erro de sintaxe.

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

### Protótipos forward × inverso: confirme qual está em jogo

Quando o usuário disser "olha o protótipo", há **dois** e misturá-los é erro de correção imediata:

- **Forward** (item → objetivos, a tela de avaliação): story `20260903`, protótipo publicado em
  `https://genialcare.github.io/product-engineer-agent/prototypes/vinculo-objetivos-itens-avaliacao-fono/`.
  É a fonte de verdade da **tela** — o que aparece por item na avaliação.
- **Inversa** (objetivo → itens, o "roadmap"): story `20260908`, um `index.html` local na pasta da
  story (`prototipo/index.html`), sem deploy.

Os dois mostram o MESMO de-para, mas em direções opostas — e a inversa agrega por objetivo com
notas como "(aplica-se às 9 funções)". Se a tarefa é "fazer a TELA igual", olhe o **forward**; usar
a inversa faz você concluir "mostra uma vez" onde a tela pede "repetir por linha" (foi o erro real
desta sessão).

## Ver também

- `references/fono-assessment-objectives.md` — exemplo trabalhado completo (Avaliação de Fono ↔
  Objetivos do PEI): tabelas, item_identifiers, decisões tomadas com o time clínico.
- `references/fono-bq-data-extraction.md` — lado dinâmico: tabelas BQ (assessment/intervention),
  filtro por protocolo `Fonoaudiologia`, enum de status reais (`completed/validated/rejected/
  pending/in_maintenance`), e como achar casos-teste ricos + casar de-para × PEI por descrição.
- User story `20260903-vinculo-objetivos-itens-avaliacao-fono` no repo product-engineer-agent
  (analysis.md / PRD.md / todo.md) e o `de-para-csv-sistema.md` do discovery de Fono.
