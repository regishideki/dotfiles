# Prova de Imitação (Fonologia) — transcription semantics & data quality

Data model (join chain) and the 16-code process dictionary live in the repo data
dictionary: `product-engineer-agent/documentations/features/speech-therapy-assessments/data-dictionary/02-phonological.md`.
This reference adds what that doc does NOT cover.

Join chain (all in `supervision-production-8f1v.assessment`, tenant filter
`genialcare = 6f8da042-2dd1-4872-a613-84d371bde78c`):

    phonological_words → phonological_words_assessments → phonological_assessments
        → speech_therapy_registries → clinical_cases (data-kernel-production-4o7n)

"Registry" = `speech_therapy_registries` (has `status`, `completed_at`,
`clinical_case_id`, `phonological_assessment_id`).

## Transcription case is phonemically MEANINGFUL (do not blind-LOWER)

`clinical-panel/src/constants/atypicalProcesses.tsx` (`transcriptionExample` and
process `example` fields) uses capital letters deliberately:

- `E` (capital) = open vowel /ɛ/ ("é"); `e` (lowercase) = closed /e/ ("ê").
  100% consistent: peteca→/petEka/, zero→/zEru/, café→/kafE/, prego→/prEgu/
  vs bandeja→/bandeja/, selo→/selu/, foguete→/fogetxi/.
- `R` (capital) = strong R /ʁ/ (carro→/kaRu/, raposa→/Rapoza/, cortina→/koRtxina/,
  borracha→/boRaxa/); `r` (lowercase) = tap /ɾ/ (prego→/prEgu/, fraco→/fraku/).

This is a Wertzner-protocol convention (structuralist phonology, Mattoso Câmara).
It is NOT documented in the UI — the "Orientações para registro" only explain the
asterisk (`*` = distortion). So therapists preserve case inconsistently.

Consequence: `LOWER(TRIM(transcription))` collapses open/closed-vowel and
strong/tap-R distinctions (e.g. `/zEru/` vs `/zeru/` are different productions).
For consistency comparisons, use a case-AWARE normalization: collapse only
edge/whole-word case ("OK" vs "ok"), preserve internal `E`/`R`/`S`.

## Process `name` field is highly inconsistent

~105 distinct values in `phonological_atypical_processes.name` vs 16 official
codes (rs, hc, pf, ep, sp, ef, fv, sf, sl, pv, sfv, pp, fp, sec, scf, others):

- Case variants: `SEC`/`Sec`/`sec`, `SCF`/`SFC`/`sfc`/`scf`, `SL`/`sl`, `OUTROS`/`outros`/`outro`.
- Free-text "outros" written ~40 ways: "interposição de língua", "ceceio",
  "distorção", "treme lingua no r", "adição de som final"…
- Typos/invalid: `o`, `O`, `q`, `e`, `ff`, `du`, `op`, `spv`, `scf2`, `sfc`, `SGC`, `OCI`, `outross`, `outro]`.
- Combined in one cell: `"FV, SL"`, `"outros + sl"`, `"outros + scf + outros"`.

Normalize case before comparing process sets (order-insensitive, e.g.
`STRING_AGG(DISTINCT LOWER(TRIM(name)), '|' ORDER BY LOWER(TRIM(name)))`), and
treat free-text/typos as distinct values in any "same processes?" comparison.
