dotfiles via rcm (~/dotfiles). .claude/.hermes symlinked. GenialCare, pt-BR, reviewer regishideki, team capacidade-clinica.
§
Cron: "10m"=one-shot, "every 10m"=recurring. MCP need `hermes mcp login <name>`. Slack #product-engineers-capacidade-clinica = C06PPV63EU9 (privado), postMessage works even if conversations.list misses it.
§
clinical-panel: @genialcare/atipico-tokens (8px base, DM Sans). Agreement STI (Embedded/Content/Manual/NativeForm). COPM v1=Embedded, v2=NativeForm (flag CLINICAL_COPM_NATIVE_FORM_ENABLED). Trailblazer: positional hash only. Multi-tenant: prefer isPartOfGenialTenant (boolean from Auth0) over currentTenant.name. Test: spread authenticatedUserMock, override isPartOfGenialTenant.
§
Trailblazer use cases (*::UseCases::* < Trailblazer::Activity::Railway) must be called with a POSITIONAL HASH, not kwargs: `UseCase.call({id:..., user:...})` not `UseCase.call(id:..., user:...)`. Kwargs → ArgumentError: wrong number of arguments (given 0, expected 1). See controllers for canonical pattern.
§
Workflow: gather all context before analysis/solutions. Save incrementally to files with numeric prefixes (1-, 2-, 3-). Prefers Mermaid diagrams. Rejeita OKRs de output tipo 'robustez'; prefere métricas em cascata (driver trees): breakeven→retenção→OST.
§
Confluence whiteboards (type: 'whiteboard') 404 on getConfluencePage. Use searchConfluenceUsingCql with type=whiteboard. Only excerpts returned; full visual content inaccessible via REST API.
§
BQ: Python google-cloud-bigquery c/ ADC. normalize é reserved word. Mindplace tenant='Care+Mindplace' (a4d02a8c).
§
Fable method skills installed in ~/.hermes/skills/: fable-method (7-step problem-solving loop), fable-loop (orchestrated subagent workflow), fable-judge (adversarial verification of finished work), fable-domain (generates new domain adapters). Ported from github.com/Sahir619/fable-method. References include failure-modes (18 modes), flowcharts (8 Mermaid diagrams), examples, and 8 domain adapters (marketing, research, data-analysis, business-ops, finance, legal, design-ux, devops).