Dotfiles via rcm at ~/dotfiles. ~/.claude and ~/.hermes symlinked, .gitignore whitelist only (Hermes 2.7GB). Custom skills tracked with per-segment un-ignore. Claude commands → Hermes skills. User: GenialCare (GitHub), pt-BR, reviewer regishideki, team capacidade-clinica.
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
Mindplace tenant name in BigQuery `tenants` table is `Care+Mindplace` (ID: a4d02a8c-4c27-41b6-80ac-3401f3964e34). Filter `t.name = 'Care+Mindplace'`; `t.name = 'mindplace'` won't match.
§
BQ: Python google-cloud-bigquery c/ ADC quando bq CLI expira. Federated tables (Sheets) falham CLI. Dry-run funciona. normalize é reserved word. `sed 's/--.*//'` antes do bq query.
§
OT mapper: pei_track_to_occupational_therapy_objectives federated. queries/occupational-therapy-mapper/ — missing-objectives (normalize_obj 2-camadas), mapper-objective-pairs (pares IDs).