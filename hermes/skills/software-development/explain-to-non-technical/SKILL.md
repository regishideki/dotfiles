---
name: explain-to-non-technical
description: Use when explaining code/flows to non-technical PMs.
---

# Explaining Technical Things to Non-Technical People

Translate — don't just simplify. The goal is a document a PM or product person can read
top-to-bottom and actually use, not a dumbed-down copy of the technical one.
This is the approach that produced `documentations/features/checagem-evolucao/doc.md`,
which the user considered the gold standard for non-technical readers.

## Core principle

Every technical noun has a human equivalent. Before writing anything, ask "what does
this person SEE or USE in their day-to-day?" and write that, not the code name. Jargon
removal is a translation pass, not a deletion pass — you still describe behavior and
rules accurately, just in the reader's vocabulary.

## Output structure (canonical skeleton)

1. **Title** — plain, descriptive (`# Checagem de Evolução`).
2. **Quote summary** — `> <one sentence: what it does and for whom>`.
3. **Visão Geral** — 1–3 paragraphs of business purpose and context.
4. **Sistemas envolvidos** — a table mapping each system to its ROLE, not its repo name
   (`clinical-panel` → "Painel do Terapeuta", `bff` → "Camada Intermediária", `core` → "Servidor").
5. **Jornada / fluxo** — Mermaid flowchart or sequenceDiagram, then a numbered prose walkthrough.
6. **"O que muda por X"** — the variation frame (below). This is the most valuable section.
7. **Cada variação com mockup ASCII** — one box-drawing mockup per mode/type.
8. **Dados reais** — production counts/distributions when they clarify the story.
9. **Regras / validações** — stated as business rules, not schema constraints.
10. **Pontos de atenção** — edge cases and gotchas in plain language.
11. **Referências** — links to related docs, minus raw file paths.

## Jargon translation rules

- **System/repo name → role it plays** for the reader ("Camada Intermediária", not "bff").
- **Attribute/code field → what the user sees on screen** (`was_assessed` → "quando a criança foi/não foi avaliada").
- **Internal enum / STI subtype → the visible "type of card"** (`trial_counter` → "Contagem de Tentativas", `checklist` → "Checklist").
- **Opaque infra term → its user-facing effect** (`correlation_id` → "identificador único", "Firestore" → "o auto-save salva rascunho").
- **Protocol/transport words → delete** (GraphQL, mutation, REST, endpoint). The reader never needs them.
- Keep code names ONLY where they are genuinely useful references; never in the narrative.

The exact pairs applied in the canonical example live in
`references/jargon-translation-table.md` — reuse before inventing new ones.

## Visual rules

- **Mermaid**: `flowchart TD` for decisions/journeys, `sequenceDiagram` for cross-system flows.
  Never use `\n` inside node labels — use `<br/>` or keep labels short; prefer extra nodes
  over long labels (does not render as a line break in most renderers).
- **ASCII mockups**: for any screen/form/card, draw a box-drawing mockup showing elements
  top-to-bottom with example data filled in. This is what non-technical readers find most
  legible — do not skip it when a screen is central to the explanation.
- A comparative table (one row per aspect, one column per mode/type) is usually clearer
  than prose when there are 2–4 variations.

## Data grounding

When the question is about rules that only become clear from the DB (e.g. which fields are
optional vs required per subtype — often an STI/enum), query real data rather than guessing:
- Use the BigQuery query project (e.g. `projects/code-snippets/queries/`) to pull counts and
  distributions per type.
- Report real numbers ("330 configs Vineland, 40 Fono") and per-field fill rates ("75% of
  evaluated checks have counters") — these turn an abstract rule into a concrete, trustable fact.
- If data can't be reproduced, mark it as a lacuna explicitly; never invent a number.

## "What changes per X" frame

The single most useful move for non-technical readers: structure the explanation around the
axis that actually varies (per discipline, per type, per scenario, per tenant). State the
decision rule plainly ("se o objetivo tem configuração, o tipo dela define o fluxo; senão cai
no qualitativo"), then give each branch its own subsection with mockup + rules. This mirrors
how the reader will reason about it in practice.

## Pitfalls

- Don't leave repo/file paths in the narrative — references section only, and even there prefer
  human links.
- Don't describe the code's internal structure ("o use case chama o service"); describe the
  user-visible journey and its consequences.
- Don't omit the "não é obrigatório / pode pular / cobrança vem depois" nuance — non-technical
  readers care a lot about what is optional vs enforced, and where enforcement happens.
- Mark inference vs confirmed fact explicitly; a PM will quote the doc as truth.
