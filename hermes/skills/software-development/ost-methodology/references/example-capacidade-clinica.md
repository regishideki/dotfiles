# Example: OST Capacidade Clínica (GenialCare, H2-2026)

Full artifacts at: `product-engineer-agent/documentations/ost-piloto/`

## Context

Team wanted to shift from roadmap-based planning to OST. The original H2-2026 OKRs were framed around "robustez" (robustness) — a term that measures output (% of process built), not outcome.

## What we built

- **Outcome:** "% de crianças com plano adequado e família ciente em ~30 dias pós-Vineland"
- **Strategy layer:** Breakeven → Receita → Retenção → 3 pillars (Tempo até enxergar valor, Evolução constante, Visibilidade)
- **Metric tree:** 4 branches (M1: Velocidade, M2: Qualidade PEI, M3: Engajamento família, M4: Confiabilidade dados)
- **20 opportunities** from 6 OG interviews (Discovery)
- **27 solutions** linked with status (done/progress/todo)

## Key documents produced

1. `1-contexto.md` — All gathered context (Slack, Confluence, roadmap)
2. `2-analise-evolucao-entendimento.md` — Initial OKRs vs post-discovery reality
3. `3-analise-inicial-okrs.md` — Why "robustez" measures output, not outcome
4. `4-ost.md` — Full OST with metric tree, prose + Mermaid diagrams
5. `5-metodo.md` — The 5-step methodology itself

## Key lessons

- "Robustez" as an objective leads to measuring % of features built, not % of problem solved
- OGs (power users) don't feel "objective selection" as pain — the real pain is visibility, alerts, and navigation
- Fono objectives structure was the real blocker, not automation
- Metric cascade (outcome → sub-metrics → opportunities) solves the abstraction gap
- Pure tree structure (no cross-subgraph edges) is critical for Mermaid readability
