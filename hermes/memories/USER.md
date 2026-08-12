Prefere output BQ enxuto: sem prefixos de alias, sem IDs internos, sem colunas extras. Dados nível library_objective, não per-clinical-case. Tenant names explícitos, nunca "all".
§
When a console snippet errors, fix the SNIPPET — do not patch repo code. Verify correct usage by reading how specs call the same code before touching the repo. User corrected this firmly: 'não é um bug do código do repo!'
§
ClinicalCaseWorkload#hours is a PostgreSQL :interval attribute. before_save calls hours.in_minutes — pass 4.hours (Duration), not 4.hours.to_i.
§
When writing Rails console snippets that produce output, keep it focused and concise. User said 'ficou confuso de analisar pois tem muitos dados' when a snippet listed all 284 agreements with full details. Prefer summary counts + only the exceptional/anomalous cases in the output (e.g. duplicates, missing records), not a full dump of every record.
§
Shell snippets: seguir EXATAMENTE padrão dos que funcionam (kubectl cp path relativo, nome CSV simples, cp do CSV pra custom_gitignore/migrations/ antes). NÃO inventar variações — se desviar, quebra em produção. User itera rápido: copia e testa, reporta erro exato.