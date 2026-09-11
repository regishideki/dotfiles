dotfiles via rcm (~/dotfiles). .claude/.hermes symlinked. GenialCare, pt-BR.
§
Slack #product-engineers-capacidade-clinica = C06PPV63EU9.
§
Trailblazer use cases (*::UseCases::* < Railway): chamar com HASH POSICIONAL não kwargs: `UseCase.call({id:..., user:...})`. Kwargs→ArgumentError.
§
Core repo PRs need .test-impact/impact-<branch>.txt or CI fails (rake-only→SKIP_TESTS).
§
Jira/Atlassian MCP: precisa `hermes mcp login atlassian` (cai intermitente 'transport is down'—retry). Cards: REVIEW→VALIDATION→DONE.
§
db:migrate via docker-compose exec -e DISABLE_SPRING=1.
§
BQ+Metabase: MCP=read-only, write=REST API x-api-key. Single-RAW (1 RAW/sub-assessment) — ask antes de quebrar. BQ: assessment/PEI/objetivos=`supervision-production-8f1v`, casos/sessões=`data-kernel-production-4o7n`(datakernel).
§
User prefere respostas diretas e escopadas; corrige tangentes não pedidas. Não responde clarify() a tempo — julgamento conservador. Cobra varredura proativa de estado real (gh pr list --state all etc) a cada retomada de trabalho multi-PR — não aceita agente reativo (só age quando notificado).
§
GitHub GenialCare: PR→merge feature na development p/ testar. Docs na main. Migration+backfill: PR1=aditivo,PR2=troca fonte só após backfill. Todo PR: assignee=regishideki, reviewer=GenialCare/capacidade-clinica (gh pr edit --add-assignee regishideki --add-reviewer GenialCare/capacidade-clinica). Após CI verde, checar gemini-code-assist 2x (10min): simples→aplicar e responder EM REPLY NA THREAD (nunca comentário solto); complexa→avisar usuário; declinar→responder na thread com motivo.
§
Local-dev: targets clinical-* (inglês), yarn não npm, nvm use antes, git check-ignore antes de segredos (skill genialcare-local-dev). core: standardrb via ruby 3.4.5@core (não RVM). Docker bundle_path desatualizado→fix `docker compose run --rm app bundle install`. Dev/staging Cloud SQL só sintético.
§
OC = Clinical Guidance Registry (não é objetivo/PEI).
§
CSV padrão p/ imports; de-para deriva de Google Sheet (corrigir planilha, não CSV).
§
core: `development` é force-pushed → `git fetch` antes de checar remotes (refs stale).