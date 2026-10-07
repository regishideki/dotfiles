BQ enxuto: sem alias/IDs internos/colunas extras; nível library_objective; tenant names explícitos.
§
Snippets console: fix SNIPPET não repo; seguir EXACT pattern dos que funcionam. Itera rápido (copy+test, erro exato). Output enxuto (counts+exceções). ClinicalCaseWorkload#hours é :interval — passar Duration (4.hours).
§
bq CLI≠Metabase: filtros→INNER JOIN implícito; SA vê menos tenants; CACHE STALE (forçar fresh /api/dataset).
§
Metabase: RAW única. PT-BR, full-width, crossfilter, cores Psico. Filtros MBQL só via dashboard endpoint.
§
LGPD: gitignore creds; anonimizar pacientes em artefatos. English comments. yarn (ver .nvmrc), não npm.
§
PRs: only task-relevant changes — no drive-by commits. Deploy em PRs sequenciais (schema+sync → rake backfill → flip lógica) com gate manual de backfill. Docs go to main, not PRs. PR descriptions pt-BR; Makefile/comments English. Prefere arquitetura correta a atalho, mesmo com mais esforço.
§
Chamados: #alerta-central-produto primeiro, depois Claudinho (só Capacidade Clínica, S05U5PS6MJA). Ausente: scripts DRY_RUN prontos p/ aprovar depois.
§
Chamados: #alerta-central-produto primeiro, depois Claudinho (só S05U5PS6MJA). Aprovação POR ITEM antes de executar/responder; Regis fornece TOTP; escalado à RT=completo; às vezes responde pessoalmente — mandar link/contexto.