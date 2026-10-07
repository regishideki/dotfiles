# Phonological imitation assessment (fono) — data model + normalization shims

Domain notes for the "Prova de Imitação (Fonologia) (Haydee Fiszbein Wertzner)" assessment.
Useful when writing BQ for phonological-process consistency analysis (e.g. "does the same
transcription get the same process classification across cases?").

## Join chain (word-level detail)

```
phonological_words → phonological_words_assessments → phonological_assessments
  → speech_therapy_registries → clinical_cases
```

Plus `phonological_atypical_processes` (1:N per word, on `phonological_word_id`).

- Tables live in `supervision-production-8f1v.assessment`; `clinical_cases` in
  `data-kernel-production-4o7n.datakernel`. Cross-project join works from a Metabase db 4
  (supervision) native card using fully-qualified names.
- `speech_therapy_registries` links the case to the assessment and holds `started_at` /
  `completed_at` / `status`. A case can have MULTIPLE registries (multiple assessments).

## "Completed, older than N days, with response" scope

```sql
WHERE str.tenant_id = '6f8da042-2dd1-4872-a613-84d371bde78c'  -- genialcare
  AND str.status = 'completed'
  AND str.completed_at < TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 10 DAY)
  AND pw.was_assessed = true          -- has a response (not "ausência de resposta")
```

## Normalization shims (apply or historical records split)

1. **Word**: legacy plural `"roupas"` → `"roupa"` (enum `PermittedPhonologicalWords`
   has `CLOTHES = "roupa"` + `CLOTHES_LEGACY = "roupas"`). Normalize:
   `CASE WHEN pw.word = 'roupas' THEN 'roupa' ELSE pw.word END`.
2. **Process (cortina only)**: `"sf"` was replaced by `"scf"` historically; the
   clinical-panel shim maps `sf → scf` for `cortina` (see
   `clinical-panel .../phonological.tsx`). Not applied blindly — `sf` and `scf` are
   DIFFERENT processes; the shim is word-scoped and display-only.

## Transcription convention: case is PHONEMIC (do NOT LOWER)

Uppercase marks specific phonemes, so case is meaningful:
- `"E"` = open vowel /ɛ/ (é); `"e"` = closed /e/ (ê). 100% consistent in the panel's
  `transcriptionExample` (peteca→/petEka/, zero→/zEru/, café→/kafE/; bandeja→/bandeja/).
- `"R"` = strong r /ʁ/ (rr, initial r, r-before-consonant); `"r"` = tap /ɾ/.

Consequence: comparing transcriptions case-insensitively (`LOWER`) collapses open/closed
vowel and strong/tap-r distinctions. Only the literal marker `"ok"` (child produced
correctly) is safe to lowercase. Recommended normalization:
`CASE WHEN LOWER(TRIM(t, ' /')) = 'ok' THEN 'ok' ELSE TRIM(t, ' /') END` — `TRIM(x, ' /')`
strips leading/trailing spaces AND `/` (IPA slashes), preserving internal case.

## Process enum — 16 official codes (`PhonologicalAtypicalProcessNames`)

`rs, hc, pf, ep, sp, ef, fv, sf, sl, pv, sfv, pp, fp, sec, scf, others`

- Backend enum canonical is `"others"` (English) but the data stores `"outros"` (PT);
  treat both as the same catch-all. Compare case-insensitively: `SEC == sec`.
- The field has heavy data-quality drift: ~100+ distinct raw values vs 16 codes —
  case variants ("SEC"/"sec"), free-text "outros" descriptions ("interposição de língua",
  "ceceio"), typos ("scf2", "sfc", "spv"), full names instead of codes
  ("simplificação de líquida" = sl), and combined cells ("FV, SL").

## "Which assessment number" ordinal (case → 1st/2nd/3rd assessment)

```sql
ROW_NUMBER() OVER (PARTITION BY clinical_case_id ORDER BY started_at, id) AS avaliacao_num
```

over `speech_therapy_registries`; join back to the word rows to label each case's
assessment chronologically. Compute it in its own CTE (registry-level), not inline in a
word-level join (word-level ROW_NUMBER would re-number per word).
