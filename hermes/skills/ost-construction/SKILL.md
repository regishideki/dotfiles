---
name: ost-construction
description: Use when building OST trees with metric cascades.
---

# OST Construction (Opportunity-Solution Tree with Metric Cascades)

Build an OST that connects company-level strategy to specific opportunities and solutions. This method adds a metric cascade (driver tree) layer between the outcome and opportunities — each opportunity connects to a sub-metric, which chains up to the outcome via causal relationships.

## When to use

- Shifting a team from roadmap-based planning to outcome-based planning
- Building a strategic tree that connects company goals to team-level work
- Facilitating a team workshop to co-create an OST
- The existing planning artifacts (OKRs, roadmap, discovery) exist but need to be organized into an OST

## The 5-step method

### Step 1: Collect context

Gather everything the organization already knows. Do NOT analyze yet.

Sources: Slack threads, Confluence pages, OKRs, roadmaps, discovery interviews, whiteboards, dashboards.

Extract: objectives defined, baseline data, user evidence (what people who live the problem say), initiatives already in progress.

### Step 2: Analyze evolution of understanding

Compare initial planning vs later documents. Identify where premises were wrong.

Key questions:
- Do the original objectives still make sense?
- What changed between planning and later documents?
- Which premises were false?
- Which baseline metrics are dirty or misleading?

Output: a document comparing "initial understanding" vs "current understanding".

### Step 3: Critique the original OKRs

Check whether objectives measure output (% of feature delivered) or outcome (real-world problem solved).

Red flags: words like "robustez", "eficiência", "excelência" as objectives. Metrics like "% of process documented", "% of features built".

Rewrite: for each original OKR, ask "if we deliver everything, how will we know the problem is actually solved?" Reformulate as an outcome — a measurable change in the real world, centered on the end user.

### Step 4: Build the OST with metric cascade

#### 4a. Define the outcome

Pick ONE measurable, user-centered outcome. Ambitious but achievable in the time horizon.

#### 4b. Build the metric tree (driver tree)

Decompose the outcome into sub-metrics. At each level, ask: "what needs to happen for this metric to improve?"

Stop decomposing when the next layer would be an opportunity (problem), not a metric (number). Metrics measure; opportunities describe.

#### 4c. Position opportunities

Place each opportunity from Discovery under the sub-metric it most directly influences.

Validity test: "if we solved this, which sub-metric would move?" If the answer is "none directly", the opportunity is either transversal (affects multiple branches) or doesn't belong in the tree.

#### 4d. Link existing solutions

Map current initiatives to the opportunities they attack.

Validity test: "which opportunity does this initiative attack?" If the answer is "none", the initiative may be solving an unvalidated problem.

### Step 5: Use continuously

The OST is a living artifact, not a one-time planning exercise.

| Frequency | Action | Key question |
|---|---|---|
| Weekly | Check sub-metrics of active branches | "Are the numbers moving?" |
| Bi-weekly | Revisit opportunities | "Still the right ones? New ones emerged?" |
| Monthly | Tree retrospective | "Outcome still right? Metric tree still reflects reality?" |
| Per cycle | Rebuild or major adjustment | "What did we learn that changes the structure?" |

Golden rule: if a solution is in progress for more than one cycle and the sub-metric hasn't moved, don't add more solutions — question the opportunity.

## The metric cascade pattern

The core innovation of this method: inserting sub-metrics between the outcome and opportunities solves the abstraction gap problem. Without them, opportunities like "discussions lack @mention" seem disconnected from an outcome like "children get the right treatment plan in 30 days". With them:

```
Outcome: % children with adequate plan in ~30 days
├── M1: Cycle speed (Vineland → devolutiva)
│   ├── M1.1: Vineland → collection done
│   │   └── Opportunity: OG doesn't know which cases are in evaluation
│   ├── M1.2: Collection → PEI defined
│   └── M1.3: PEI → devolutiva done
│       └── Opportunity: Devolutiva is ritual, not function
├── M2: PEI adherence (%)
│   ├── M2.1: TO adherence (49% → ~84%)
│   │   └── Opportunity: TO catalog missing AVD objectives
│   └── M2.2: Fono adherence (37% artificial)
│       └── Opportunity: Speech objectives poorly structured
└── ...
```

This also helps prioritize: if an opportunity influences a sub-metric with low impact on the parent metric, it's lower priority.

## Visualizing the OST

### Markdown (Mermaid)

For documents, use Mermaid with separate diagrams per branch. See `references/mermaid-html-pattern.md` for the reusable HTML template with zoom/pan.

Key Mermaid rules learned:

1. **Use `htmlLabels: false`** — SVG text elements don't clip like `foreignObject` does. Always use single-line labels (no `<br/>`).
2. **Use subgraphs for each branch** — keeps related nodes together, reduces edge crossings.
3. **Pure tree structure** — each node has exactly one parent. No cross-subgraph edges. If a solution genuinely affects multiple opportunities, pick the primary one for the diagram and note secondary relationships in the text.
4. **Thicker arrows via CSS** — default Mermaid edges are thin. Add `#canvas svg .edgePath .path { stroke-width: 2.5px !important; }`.
5. **Light background** — dark backgrounds make default Mermaid arrows invisible. Use `#f5f5f8` or similar.

### Interactive HTML

Use the template in `references/mermaid-html-pattern.md`. It provides:
- Single full-tree Mermaid diagram
- Zoom (mouse wheel, +/- buttons, keyboard `+`/`-`/`0`)
- Pan (click-drag, touch-drag)
- Legend overlay
- Initial zoom at ~45-55% so the full tree is visible

### Pitfall: never use `<br/>` in Mermaid labels

Mermaid's `foreignObject` sizing is unreliable with multi-line text. Always single-line labels. The nodes will be wider but text won't clip.

## Differences from traditional planning

| Dimension | Traditional (roadmap) | This method |
|---|---|---|
| Starting point | Objective → Initiatives | Context → Outcome → Metrics → Opportunities |
| Decision space | Solution (what to build?) | Problem (what to solve?) |
| Progress metric | % of feature completed | Sub-metric moving in right direction |
| Pivots | Exception (requires realignment) | Rule (metric didn't move → pivot) |
| Solution timing | Defined during planning | Defined when opportunity is prioritized |
| Cross-team coordination | "Dependencies between initiatives" | "Dependencies between metrics" |

## Sources referenced in the pilot

- Teresa Torres — *Continuous Discovery Habits* (origin of OST framework)
- Slack thread, Confluence H2 folder, Discovery interviews with 6 OGs
- See pilot documents: `1-contexto.md`, `2-analise-evolucao-entendimento.md`, `3-analise-inicial-okrs.md`, `4-ost.md`, `5-metodo.md`
