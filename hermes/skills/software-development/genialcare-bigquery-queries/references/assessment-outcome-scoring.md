# Worked example: "desfecho positivo" scoring for speech therapy's 5 sub-assessments

Full analysis lives in `documentations/features/speech-therapy-assessments/ideal-outcome-analysis/`
in `product-engineer-agent` (00-overview.md + one doc per domain). This file is the
condensed pattern for reuse on other multi-domain assessments (OT, Vineland).

## The 5 domains and how each defines "positive"

| Domain | Positive outcome logic | Age-dependent? | Has a "not applicable" gate? |
|---|---|---|---|
| Phonological (Imitação) | Absence of atypical phonological processes AGE-ADJUSTED (process present past its documented "expected disappearance age" = alert) | Yes — needs `birth_date` | No, but only scoreable when the `phonological_words` (39-word list) path was used; the two fallback paths (`spontaneous_speeches`, `motor_vocalizations`) are free text, not objectively scoreable |
| Expressive Communication | All 9 functions at `performed_frequency = 'frequently'` using the 2 most advanced symbolic means (abstract symbols / combines 2+ symbols); `communicative_repertoire = 'expanded'`; absence of echolalia | No | No |
| Orofacial Myology (MMGBR) | Each of ~26 closed-enum fields matches its single "adequate"/"normal"/"efficient" value; 3 fields have NO neutral value in the enum at all (`jaw_posture`, `tongue_appearance`, `masticatory_side_preference`) — exclude those from the binary score, report as descriptive | No | No |
| Speech Motor Control (Bandeiras Vermelhas) | INVERTED: `no` on all 13 triage signs = healthy, any `yes` = alert. `partially` = 0.5 point. `not_observed` excluded from denominator | No | No |
| AAC/CAA | Different type of score entirely — `is_needed=false` is a valid gate (not a "good" or "bad" outcome, means N/A), `is_needed=true` scores on implementation success (positive/negative signal enum fields explicitly named by the UI/data-dictionary as such) not "typical development" | No | Yes — `is_needed=false` short-circuits completion and should be excluded from any consolidated "typical development" average |

## SQL pattern — per-domain outcome_score + is_fully_observed

Each domain CTE should return: `registry_id`, `outcome_score` (0-1, NULL if not
applicable), `is_fully_observed` (boolean — false if any field hit its `not_observed`
sentinel). Example for the inverted triage-checklist domain (Bandeiras Vermelhas),
the simplest pattern to adapt:

```sql
WITH signals_unpivoted AS (
  SELECT registry_id, clinical_case_id, signal_name, signal_value
  FROM motor_control_context
  UNPIVOT(signal_value FOR signal_name IN (
    limited_speech_movement_range, limited_lip_retraction, /* ...13 total... */
  ))
),
scored AS (
  SELECT registry_id, clinical_case_id, signal_name, signal_value,
    CASE signal_value
      WHEN 'no' THEN 1.0
      WHEN 'partially' THEN 0.5
      WHEN 'yes' THEN 0.0
      ELSE NULL  -- not_observed: excluded from denominator
    END AS signal_score
  FROM signals_unpivoted
)
SELECT
  registry_id, clinical_case_id,
  SAFE_DIVIDE(SUM(signal_score), COUNT(signal_score)) AS outcome_score,
  (COUNT(signal_score) = 13) AS is_fully_observed
FROM scored
GROUP BY registry_id, clinical_case_id
```

For the age-dependent domain (phonological processes), the extra piece is a
`process_age_reference` lookup (process name → expected disappearance age in months,
from `PhonologicalAtypicalProcessNames` enum + i18n) joined against
`DATE_DIFF(assessment_date, birth_date, MONTH)`, flagging a process occurrence as
"clinically relevant" only when it appears AFTER the expected disappearance age AND its
productivity (`occurrences / MAX_OCCURRENCES[process]`) crosses a materiality threshold
(the UI already uses 0.25 as its "highlight in red" cutoff — reuse it rather than
inventing a new one).

## Composing a Registry-level (multi-domain) score

```sql
SELECT
  str.id AS registry_id,
  (
    COALESCE(d1.outcome_score,0) + COALESCE(d2.outcome_score,0)
    + COALESCE(d3.outcome_score,0) + COALESCE(d4.outcome_score,0)
    + COALESCE(IF(d5.applies_to_score, d5.outcome_score, 0), 0)
  ) / (4 + IF(d5.applies_to_score, 1, 0)) AS registry_outcome_score,
  (
    COALESCE(d1.is_fully_observed,FALSE) AND COALESCE(d2.is_fully_observed,FALSE)
    AND COALESCE(d3.is_fully_observed,FALSE) AND COALESCE(d4.is_fully_observed,FALSE)
    AND (NOT d5.applies_to_score OR COALESCE(d5.is_fully_observed,FALSE))
  ) AS is_fully_reliable
FROM registries str
LEFT JOIN domain1_outcome d1 ON d1.registry_id = str.id
/* ...d2..d5... */
```

Unweighted average across applicable domains, `applies_to_score` flag lets a domain
(like CAA when not needed) opt out of the denominator instead of just defaulting its
score to 0 (which would wrongly penalize a case that legitimately doesn't need that
domain).

## `not_observed`/missing-data handling — apply ONE policy across every domain, not different ones per domain

When multiple domains in the same doc series have a "not observed" sentinel in their
enum (any domain with a `not_observed`/`notObserved` option — Speech Motor Control,
Orofacial Myology, AAC in the speech therapy example), it's easy to drift into
**inconsistent treatment across domains written in different passes**, and the two
naive options both have opposite biases:

| Approach | Bias |
|---|---|
| Exclude `not_observed` from the denominator (only average over observed fields) | **Inflates** the score when few fields were observed — 1 field observed, favorable, still yields `outcome_score = 1.0`, indistinguishable from a fully-observed favorable case |
| Keep a fixed denominator (total fields in the domain) and let `not_observed` count against the numerator | **Penalizes** a genuinely incomplete-but-fine assessment — a therapist who tested 20 of 26 fields (all adequate) scores worse than one who tested 10 of 26 (all adequate), purely because of session time constraints, not clinical findings |

User caught this exact inconsistency (2026-08-26) after reviewing 3 domains that had
each independently picked a different one of these two options. **Resolution, apply to
every domain with a `not_observed` sentinel:**

```
outcome_score = SUM(points earned on OBSERVED fields) / COUNT(OBSERVED fields)
                -- excludes not_observed from BOTH numerator and denominator

observed_fraction = COUNT(OBSERVED fields) / TOTAL fields in domain

is_fully_observed = (observed_fraction = 1.0)

is_score_reliable = (observed_fraction >= COVERAGE_THRESHOLD)
                     -- COVERAGE_THRESHOLD is a placeholder (e.g. 0.7), explicitly
                     -- flagged as an uncalibrated hypothesis, not a validated cutoff
```

Always report `outcome_score` **together with** `observed_fraction`/`is_score_reliable`
— never let a consumer read `outcome_score` alone, since a score computed from 1-2
observed fields is a different kind of claim than one computed from a nearly-full set.
Note in the doc that a statistically stronger alternative exists (a lower-bound
confidence interval on the observed proportion, e.g. Wilson score interval, which
naturally pulls small-sample scores toward uncertainty without a hand-picked threshold)
but wasn't implemented — name it as a documented future refinement rather than silently
picking the simpler heuristic.

Domains whose enum has no `not_observed` option, or whose confidence signal comes from
something else entirely (e.g. Phonological's `was_assessed` per word, which has a
protocol-fixed denominator by design, not a variable "how much was covered") don't need
this pattern — don't force it onto every domain uniformly, only the ones with the
sentinel-value ambiguity.

## Doc-writing conventions when publishing this kind of multi-domain analysis

Two conventions the user corrected on 2026-08-26, apply to any future doc set of this
shape (a data-dictionary or outcome-scoring series with one file per sub-domain of a
multi-domain clinical assessment):

1. **Number/order the per-domain files to match the order the domains appear in the
   product UI, not alphabetically and not by DB/FK column order.** For speech therapy
   this is the order in `clinical-panel/src/pages/Users/Session/contexts/SpeechTherapyAssessmentsProvider.tsx`
   (session navigation) and `clinical-panel/src/pages/DirectAssessments/Home/index.tsx`
   (`findFonoAssessmentsByRegistry` list) — both list Comunicação Expressiva → Fonológico
   → Bandeiras Vermelhas (Motor Control) → Motricidade Orofacial → CAA. Before numbering
   a new doc series for another assessment (OT, Vineland), grep the equivalent
   `*Provider.tsx`/registries-home component in `clinical-panel` for the canonical
   array order instead of guessing from column names or the data dictionary you're
   writing. Note the ordering source at the top of the doc series' overview file so the
   next editor doesn't "fix" it back to alphabetical.
2. **Any outcome-scoring/"desfecho ideal" proposal built by reverse-engineering enums,
   Rails models, and i18n — without direct validation from the clinical specialty team —
   must carry an explicit, visible "⚠️ preliminary analysis / not a validated clinical
   rule" banner at the top of the overview doc AND at the top of every per-domain doc**,
   not just a caveat buried in prose. State plainly that criteria, weights, and
   thresholds are working hypotheses subject to revision, and name the single weakest
   assumption in each doc (e.g. the CAA success-signal weights, since no existing UI
   precedent validates them, unlike the other 4 domains which mirror an
   already-shipped UI indicator). Do this proactively for every such analysis, not only
   when asked — the user asked for it once and expects it to persist as a default.

## Cross-discipline proxy-viability analysis — "can we do for X what we already do for Y"

Follow-up question that arose after the outcome-scoring analysis above: the org already
uses completed Objetivos as a proxy for the Vineland (indirect/Psico) reavaliação — "if
objectives A, B, C are done, the Vineland would likely already show result D". The user
asked whether the same trick works for the direct Fono assessment (the 5 domains above).

**Answer pattern: check whether the two taxonomies are the same by construction, not
just structurally similar.** Vineland works because the objective library FOR THAT
DISCIPLINE *is* the assessment protocol — Vineland 3 is simultaneously the instrument and
the PEI Track objective source (`pei/CLAUDE.md`: "Vineland 3 é o protocolo-base do PEI
Track"). Completing the objective **is** answering the item; there's no reconciliation
step. Fono's objectives library and its 5 assessment sub-protocols were built
independently — the existing de-para (`documentations/discoveries/20260824-eliminar-reavaliacao-fono/de-para-csv-sistema.md`)
needed fuzzy text matching + regex phoneme extraction to reconcile them, and even so left
7 objectives with no system match. That reconciliation effort is itself proof the two
aren't the same taxonomy — a real tell for any future "can we do X-for-Y" ask on a new
discipline pair.

**When the correspondence is reconciled (not by-construction), viability is per-subdomain,
never a single yes/no for the whole discipline.** Two orthogonal checks per subdomain:

1. **Mapping coverage** — what fraction of that subdomain's fields have ANY objective
   mapped in the de-para? (E.g. speech therapy's Orofacial Myology: only 5 of 29 fields
   had a mapped objective.)
2. **Trainability** — is the field a *skill* (objective completion can plausibly move it,
   e.g. phoneme production, communicative behaviors) or an *anatomical/physiological exam
   finding* (frenulum length, dental occlusion, oral reflexes — no amount of objective
   completion changes these; they're observed, not trained)? Low mapping coverage on an
   exam-finding subdomain is not a data gap to fix — it correctly reflects that objectives
   can't predict that kind of field.

Resulting per-domain table for the Fono case (as a template for the next such ask):

| Domain type | Mapping coverage | Trainability | Viability |
|---|---|---|---|
| Triage checklist inferred from observation during other tasks (Bandeiras Vermelhas) | Good | High (signals ARE clinical judgments over observed behavior, same epistemic shape as objective completion) | Most promising — still probabilistic, not deterministic |
| Closed-vocabulary drill test with a fixed word list (Phonological/Imitação processes) | Partial, granularity mismatch (objectives = free production drills; test = 39 fixed words) | Medium — correlated, not substitutable | Correlated only |
| Free-text/dynamic behavioral observation (Comunicação Expressiva, CAA behavioral part) | Weak | Medium | Not recommended / partial |
| Anatomical/physiological exam findings (Orofacial Myology's 24 non-mapped fields) | Very weak | None — not a trainable skill | Structurally inviable, not a mapping-coverage problem |

**Recommendation that generalizes:** do NOT collapse this into one "% estimability"
number for the whole discipline — that would hide which subdomains are fundamentally
unpredictable from objectives (same reasoning as never collapsing `outcome_score` across
domains in the scoring analysis above without flagging it as a simplification). Instead:
(a) publish the per-domain viability table, (b) for the single most-promising domain,
validate the hypothesis **retroactively** (compare historical objective-completion rate
against the REAL outcome_score already computed for cases with both data available)
before ever using it prospectively, (c) explicitly exclude domains whose viability is
"structurally inviable" from any future consolidated proxy, not just note the caveat and
build it anyway.

Full worked example: `documentations/features/speech-therapy-assessments/ideal-outcome-analysis/vineland-parity-analysis/00-overview.md`
in `product-engineer-agent`, with a frozen snapshot of the source de-para CSV in
`vineland-parity-analysis/snapshot/` (see the "Freeze external mapping sources" pitfall in
the main SKILL.md for why the snapshot matters).

## Quantify mapping-coverage claims with a real count before asserting viability — especially when the artifact was built by a domain expert

First pass at the per-domain viability table above described mapping coverage
qualitatively ("weak", "fraca", "não recomendado") from reading the de-para prose alone,
without counting. User pushback (2026-08-26): three of those five qualitative labels were
too pessimistic once actually counted, and — critically — the de-para CSV was built by
the clinical specialty lead herself, so a strong negative claim like "the association is
invalid" needed real evidence, not impression, before being stated.

**Fix, apply whenever a viability/coverage judgment is being made from a mapping table
someone else authored:**

```sh
grep -o "<domain prefix>: [^.\\]*" file.csv | sort | uniq -c | sort -rn
```

Count actual matched items per field/signal (numerator) against the total fields in that
domain (denominator) before writing any "weak"/"strong"/"not recommended" label. Concrete
effect in this case: recount turned "Bandeiras Vermelhas: boa, cardinalidade limpa" into
"12/13 = 92%, essentially done"; "Imitação: correlacionado, não substituível" into "14/14
= 100% mapped, only an aggregation rule is missing"; "CAA: parcial" into "6/19 = 32%,
but exactly the clinically decisive behaviors"; and most importantly walked back
"Comunicação Expressiva: mapeamento fraco, não recomendado" to "3/3 skills fully mapped,
only one generic item needs a granularity decision" — the qualitative read had been
flatly wrong on the strongest domain. Only Motricidade Orofacial's low coverage (5/29)
held up after counting, because the gap there is explained by field *nature* (anatomical
exam findings, not trainable skills), not by sloppy mapping.

**Tone rule when critiquing a mapping/de-para that a named subject-matter expert
authored:** never phrase a coverage gap as "the association is invalid" or "not
recommended" as a first-pass conclusion. Phrase it as an open question back to the
expert ("does completing objective X reliably predict outcome Y in your clinical
experience?") until they've had a chance to confirm or correct the technical reading —
the numbers can tell you coverage %, they can't tell you clinical validity.

## Producing a plain-language validation document for a domain expert, distinct from the technical analysis doc

When a technical BigQuery/data analysis (SQL, schema, enums, `outcome_score`
formulas) needs sign-off from a non-technical domain expert (e.g. the clinical
specialty lead who built the source mapping), write a SEPARATE companion document
instead of asking them to review the technical one:

- Zero SQL, enum codes, table/column names, or scoring formulas — describe the same
  finding in the language the domain already uses (e.g. "esse sinal de alerta" not
  `speech_motor_control_answers.yes`).
- One section per open technical assumption, each ending in ONE closed, concrete
  question the expert can answer from experience (yes/no, or "which of these 9
  options") — not an open "what do you think?" invitation.
- Close with a table mapping each domain/section to its single pending question, so
  the answers can be collected in one short conversation instead of a full re-read.
- Keep the tone as genuine uncertainty-seeking-confirmation, not as a report of
  conclusions already reached — this matters doubly when the technical doc already
  stated a viability judgment that later needs the expert's clinical read to hold up.

Worked example: `documentations/discoveries/20260824-eliminar-reavaliacao-fono/validacao-clinica-fono.md`
in `product-engineer-agent`, companion to the technical
`vineland-parity-analysis/00-overview.md` doc above — same 5-domain analysis, rewritten
entirely as closed clinical questions for the fono specialty lead.
