dotfiles via rcm (~/dotfiles). .claude/.hermes symlinked. GenialCare, pt-BR, reviewer regishideki, team capacidade-clinica.
§
Cron: "10m"=one-shot, "every 10m"=recurring. MCP need `hermes mcp login <name>`. Slack #product-engineers-capacidade-clinica = C06PPV63EU9 (privado), postMessage works even if conversations.list misses it.
§
clinical-panel: @genialcare/atipico-tokens. Agreement STI. Trailblazer: positional hash only. Multi-tenant: isPartOfGenialTenant. COPM v2=NativeForm (flag CLINICAL_COPM_NATIVE_FORM_ENABLED).
§
Trailblazer use cases (*::UseCases::* < Trailblazer::Activity::Railway) must be called with a POSITIONAL HASH, not kwargs: `UseCase.call({id:..., user:...})` not `UseCase.call(id:..., user:...)`. Kwargs → ArgumentError: wrong number of arguments (given 0, expected 1). See controllers for canonical pattern.
§
Workflow: gather all context before analysis/solutions. Save incrementally to files with numeric prefixes. Prefers Mermaid diagrams. Prefers outcome metrics over output.
§
BQ: Python google-cloud-bigquery, ADC. normalize=reserved word. Mindplace tenant='Care+Mindplace' (a4d02a8c).
§
Core repo PRs need .test-impact/impact-<branch>.txt or CI fails (rake-only→SKIP_TESTS).
§
Jira: needs `hermes mcp login atlassian`. User expects cards moved REVIEW→VALIDATION→DONE.
§
implement-feature skill: subagent briefing MUST use pr-open (not raw gh pr create) for PR creation. pr-open handles assignee, reviewer, test-impact, and cron jobs. T2 subagent used gh pr create --draft directly, missing test-impact/assignee/reviewer.
§
Orchestrator must sanity-check subagent output against contracts before accepting CONCLUIDO (not just accept self-report).
§
core local: Docker off→standardrb via ruby 3.4.5@core (RVM default 3.0.0 wrong; GEM_PATH+=@global+default gems). kubectl cp não cria dirs pais no pod — mkdir -p antes.