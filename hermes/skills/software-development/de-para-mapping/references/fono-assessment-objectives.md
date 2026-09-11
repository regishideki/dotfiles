# Exemplo trabalhado: Avaliação de Fono ↔ Objetivos do PEI

Caso concreto do padrão `de-para-mapping` (user story `20260903-vinculo-objetivos-itens-avaliacao-fono`).

## O problema

A Avaliação Direta de Fono é um **Registry** com 5 sub-avaliações independentes (cada uma com
tabela/fields próprios), sem nenhum vínculo com a biblioteca de Objetivos do PEI. Objetivo da
feature: exibir, na tela de avaliação, quais objetivos se relacionam com cada item.

As 5 sub-avaliações e onde cada "item" vive:

| Sub-avaliação | Onde o item vive | Natureza do item |
|---|---|---|
| Bandeiras Vermelhas (`speech_motor_control`) | campos em 4 sub-tabelas (`general_speech_motor_controls`, `segmental_features`, `suprasegmental_features`, `syllabic_complexities`) | **campo** (valor yes/no/partially) |
| Imitação (`phonological`) | `phonological_atypical_processes.name` (enum `PhonologicalAtypicalProcessNames`) | **valor de enum** (rs, hc, pf…) |
| CAA (`augmentative_and_alternative_communication`) | `clinical_observations` (21 campos) | **campo** |
| Comunicação Expressiva (`expressive_communication`) | `communication_skills.skill_name` (enum) + `expressive_communication_features` (feature × 6 meios) | enum + **meio × função** |
| Motricidade Orofacial (`orofacial_myology`) | `physical_conditions` / `orofacial_functions` | **campo** |

## item_identifiers (exemplos reais)

- `limited_speech_movement_range` (Bandeiras Vermelhas — nome da coluna)
- `rs` (Imitação — código do enum `PhonologicalAtypicalProcessNames`)
- `searched_for_aac_system` (CAA — campo de `clinical_observations`)
- `echolalia_profile` (Comunicação Expressiva — código de `CommunicationSkillName`)
- `combinesTwoPlusSymbols` (Comunicação Expressiva — um dos 6 "meios", cruza as 9 funções)
- `lip_appearance` (Motricidade — campo de `physical_conditions`)

Chave composta: `(assessment_type, item_identifier, feature_name)` — `feature_name` é nullable,
preenchida só para meios que cruzam funções (9 funções de `ExpressiveCommunicationFeatureName`).

## Tabelas envolvidas

- **Fonte:** CSV `objective-to-speech-therapy-assessment.csv` (de-para humano: objetivo × itens).
- **Referência (match):** `intervention_library_objectives` (description, protocol_item_id),
  `intervention_protocols`/`protocol_items` (protocolo "Fonoaudiologia").
- **De-para (nova):** `speech_therapy_assessment_objective_mappings`
  (assessment_type, item_identifier, feature_name, library_objective_id).
- **Resolução (runtime):** `intervention_peis` + `intervention_objectives`.

## Regras de match (no rake de import)

1. Objetivo → `library_objective_id`: normalização (trim + lowercase + colapsa espaços) + match
   exato contra `library_objectives.description` (a `normalize_obj()` do TO mapper).
2. Item → `item_identifier`: mapa fixo de tradução (nome do CSV → campo/enum), extraído da
   seção 4 do `de-para-csv-sistema.md`.
3. Meio → expansão por função: itens que são "meios" (ex: `combines_two_plus_symbols`) são
   expandidos em um item por `feature_name` (9 funções), via constante/config no seed que espelha
   o enum `ExpressiveCommunicationFeatureName`.

Seed = `truncate` + re-import, idempotente, reporta os sem match.

## Decisões de domínio tomadas com o time clínico (e por quê importam)

- **"Combinação de dois ou mais símbolos" = "Combina mais de dois símbolos"** → mesmo campo
  `combinesTwoPlusSymbols`. Não crie campo novo; é inconsistência de redação.
- **`combinesTwoPlusSymbols` cruza as 9 funções → materializa na tabela.** O meio vira 9 itens
  no de-para (um por função), via coluna `feature_name`, cada um apontando para os mesmos
  objetivos. **NÃO é regra de frontend** (o usuário corrigiu isso explicitamente): o vínculo
  completo fica no dado, para cada item da avaliação.
- **Item genérico "Comunicação Expressiva"** (sem sub-campo) → refere-se à primeira parte da
  avaliação (Funções + meios), NÃO é artefato de digitação.

## Achados que generalizam

- **Ligação dupla** `library_objective_id` OU `protocol_item_id` no `Objective` — o join de
  resolução precisa cobrir os dois.
- **"Recomendar objetivo a partir do resultado" é o INVERSO de "exibir objetivos relacionados"**
  — são duas features distintas; a recomendação (sugerir quando Função = Não/Raramente, etc.)
  fica como segundo momento, fora do escopo da exibição.
- **PeiTrack (Vineland/Psico) é a direção contrária:** nasce populado com a biblioteca e recebe
  o resultado; Fono constrói o vínculo a partir da avaliação. O mesmo vínculo item↔objetivo é a
  base tanto para exibir quanto para (no futuro) um score por item.

Fonte completa: `documentations/user_stories/20260903-vinculo-objetivos-itens-avaliacao-fono/`
(analysis.md, PRD.md, todo.md) e
`documentations/discoveries/20260824-eliminar-reavaliacao-fono/de-para-csv-sistema.md`.
