# Extração de dados reais (BQ) — de-para de Fono

Lado "dinâmico" do de-para: resolver o status (library objective → objetivo do PEI + status)
e achar casos reais para validar o protótipo. Complementa `fono-assessment-objectives.md`
(que cobre o lado estático item ↔ objective).

## Tabelas BQ (produção)

| Conteúdo | Path |
|---|---|
| Avaliação de Fono | `supervision-production-8f1v.assessment.*` |
| Objetivos do PEI | `supervision-production-8f1v.intervention.*` |
| Casos clínicos | `data-kernel-production-4o7n.datakernel.clinical_cases` |

- **`assessment.*`** — `speech_therapy_registries` (1 por avaliação; FKs `phonological_assessment_id`,
  `expressive_communication_assessment_id`, `orofacial_myology_assessment_id`,
  `speech_motor_control_assessment_id`, `aac_assessment_id`) + 5 sub-avaliações + tabelas filhas:
  `motor_vocalizations(_assessments)`, `spontaneous_speeches(_assessments)`,
  `phonological_words(_assessments)`, `expressive_communication_features` (`feature_name`,
  `performed_frequency`), `communication_skills` (`skill_name`, `performed_frequency`),
  `physical_conditions` + `orofacial_functions` (Motricidade), `general_speech_motor_controls` +
  `segmental_features` + `suprasegmental_features` + `syllabic_complexities` (Bandeiras Vermelhas),
  `aac_clinical_decisions` + `aac_clinical_observations` (CAA).
- **`intervention.*`** — `peis` (`clinical_case_id`) → `objectives` (`pei_id`,
  `library_objective_id`, `status`, `objective_id` é a PK) → `library_objectives`
  (`protocol_item_id`, `description`) → `protocol_items` → `protocols`.

## Query canônica

`code-snippets/queries/assessment/speech_therapy/speech-therapy-last-assessment.sql` — último
registro COMPLETO por caso (uma linha por caso), com todas as sub-avaliações agregadas
(`\\n`-separadas). Para escopar a casos, insira `WHERE cc.number IN (...)` logo antes do
`ORDER BY cc.number` final.

**Anonimização (LGPD) — não extraia PII na origem.** A query canônica seleciona campos que NÃO são
necessários para o protótipo e vazam dado de paciente: `cc.name AS clinical_case_name` (nome),
`fo.fono_og_name`/`fo.fono_og_email` (nome/email do terapeuta) e `tp.therapists`. Para extração,
use uma cópia escopada SEM esses campos (só `cc.number`), e remova os CTEs que ficam mortos
(`clinicians`, `fono_og`, `therapists_per_registry`) + seus joins + o `UNNEST(s.clinicians)`/`c.clinician_id`
em `direct_assessment_sessions`. Não extrair o nome desde a origem evita ter que anonimizar os JSONs
depois (e evita que nome real entre no histórico do repo).

## De-para → protocolo "Fonoaudiologia"

O de-para (106 objetivos) mapeia para objetivos do protocolo **`Fonoaudiologia`**
(`protocols.name = 'Fonoaudiologia'`). O PEI de um caso mistura protocolos — Vineland 3,
Ocupacional, Integração Sensorial, Symbolic Play, Fonoaudiologia — e **só a fatia
"Fonoaudiologia" cruza com o de-para**. Filtre por esse protocolo ao buscar objetivos relevantes.

## Status reais dos objetivos (enum)

5 valores observados em produção: `completed`, `validated`, `rejected`, `pending`,
`in_maintenance`. O protótipo precisa de legenda com ≥ 5 estados; "não iniciado" = objetivo
ausente do PEI do caso (não é um status armazenado).

## Nuance: avaliação completa ≠ objetivos de Fono no PEI

Um caso pode ter avaliação de Fono `completed` (completion 1.0) e **zero** objetivos
"Fonoaudiologia" no PEI (só Vineland/Symbolic Play). Avaliação e objetivos do PEI são
independentes. Para validar o protótipo com status preenchidos, escolha casos **com** objetivos
de Fono no PEI — senão tudo aparece "não iniciado".

## Como achar casos-teste ricos

CTE: contar objetivos "Fonoaudiologia" por `pei.clinical_case_id` (com `obj.discarded_at IS NULL`),
cruzar com `speech_therapy_registries.status = 'completed'`, ordenar por contagem desc. Exemplo
real (2026-09): caso 450 = 20 objetivos de Fono (7 no de-para), 1570 = 2, 1526 = 0.

## Match de-para × PEI: por descrição (não por ID)

O CSV de-para só tem `objective` (descrição) — **não** `library_objective_id`. Case a descrição
do de-para contra `objectives.description` do caso (match exato). Objetivos do caso fora do
de-para (ex: "Fala as palavras alvos…", "Utiliza a língua…") são objetivos de Fono que NÃO
mapeiam a item de avaliação — não entram no snapshot. Cuidado com redações quase-iguais
("Respira"/"Respirar", "Fala"/"Falar") que são objetivos distintos.

## Snapshot por caso (estático vs per-caso)

- **Estático:** de-para (item → objective), do CSV — igual para todos os casos.
- **Per-caso:** `assessment` (resultados) + `peiObjectives` (objective → status), extraídos do BQ.
- Objetivo do de-para ausente no PEI do caso = "não iniciado".
