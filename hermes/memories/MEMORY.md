dotfiles via rcm (~/dotfiles). .claude/.hermes symlinked. GenialCare, pt-BR.
§
Slack: Farol TO→C04J33K1YLX; regras clínicas validar na fonte (DM C0C52MUT0F6).
§
UseCase.call kwargs: params:{}, current_user: (não posicional).
§
Core: PRs precisam .test-impact/impact-<branch>.txt (CI fail) ou SKIP_TESTS (não bloqueia merge). Lint=standardrb. FeatureFlag.on? exige key: (sem default); flag global usa key: clinical_case.tenant_id.
§
MCP OAuth: expira ~24h; `hermes mcp login <name>` exige TTY — `script -q /dev/null` (abre browser).
§
Sem RLS; multi-tenant→filtrar tenant_id=6f8da042-2dd1-4872-a613-84d371bde78c (genialcare UUID)
§
Não responde clarify()—julgamento conservador.
§
PR base=SEMPRE main. Bot 1ª validação=time genialcare-engineering-agent (dispara agentic-pr-review.yaml; PR precisa READY antes do request). capacidade-clinica só pós-validação usuário.
§
Docker=colima (não Desktop), 12GB/8cpu, auto-start via brew services.
§
Second-brain KB: ~/.hermes/second-brain/ (skill 'second-brain').
§
clinical-panel Auth0 dev: dev@genialcare.com.br (senha = o próprio email dev@genialcare.com.br).
§
prefere git/browser, não gsutil/gcloud.
§
mobile-bff: sem branch development; deploy=gh workflow run deploy-manually.yaml -f branchName=<b>.
§
BFF local: CORE_API_URL=http://localhost:3000 (senão core-app-1/remote). Panel: rota clinical-cases usa :id=clinicalCaseId; sessions usa :sessionId.
§
clinical-panel: assessment types TS manuais (sem codegen); enum GraphQL BFF não toca panel.
§
'psico'/'psicologia' = disciplina 'aba' (não existe 'psychology'). fono=speech_therapy; TO=occupational_therapy.
§
pup = Datadog CLI (~/bin/pup).
§
Proatividade: esgote código/skills, Slack, BQ/Postgres, memória, git, internet antes de perguntar. Perguntar só p/ decisão de produto ou sensível (OpenFGA/LGPD).
§
custom_gitignore/ (repo genial) = artefatos locais, gitignored. Nunca commitar.
§
Prefere cron 15min. Notif Slack: `bash ~/.hermes/scripts/notify_slack.sh "<msg>"` (bot Regermes, user U021XDAFMM4).
§
TCLE: só obrigatório se terapeuta tem ≥1 sessão finalizada; nunca atendeu→remoção manual. Reenvio: PO→Administração→Assinaturas.
§
core: env dev deploya da branch development (não main).