Prefere output BQ enxuto: sem prefixos de alias, sem IDs internos, sem colunas extras. Dados nível library_objective, não per-clinical-case. Tenant names explícitos, nunca "all".
§
Console/shell snippets: fix SNIPPET not repo code, follow EXACT pattern of working ones. User iterates fast: copy+test, reports exact error. Prefer concise output (summary counts + exceptions, not full dumps). ClinicalCaseWorkload#hours is :interval — pass Duration (4.hours) not .to_i.
§
Diferenças de contagem bq CLI vs Metabase: (1) filtros viram implicit INNER JOIN, (2) service account vê menos tenants, (3) CACHE STALE — forçar fresh run via /api/dataset antes de debugar.
§
Metabase: RAW única. PT-BR, full-width, drill-down crossfilter, cores Psico. Series: Aderente(bottom)/Sem obj(mid)/Não Aderente(top). Sort "Não Aderente" via UI. Filtros MBQL só via dashboard endpoint.
§
Security+LGPD: gitignore env/creds before writing; anonymize patient/therapist names in committed/published artifacts. English comments. Tooling: check .nvmrc+yarn.lock, yarn not npm.
§
PRs: only task-relevant changes — no drive-by commits. Docs go to main, not PRs. Self-contained docs per repo. PR descriptions in pt-BR for GenialCare repos. Makefile/code comments in English. Never commit secrets — verify .gitignore covers sensitive files and document how to fill gitignored configs in README.