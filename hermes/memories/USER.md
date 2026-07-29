User prefers lean BigQuery query output: no alias prefixes (e.g. `code` not `pi_code`), no internal IDs, no extra columns unless asked. Prefers library_objective-level data (not per-clinical-case) when the question is about the catalog/configuration of objectives.
§
When a console snippet errors, fix the SNIPPET — do not patch repo code. Verify correct usage by reading how specs call the same code before touching the repo. User corrected this firmly: 'não é um bug do código do repo!'
§
ClinicalCaseWorkload#hours is a PostgreSQL :interval attribute. The before_save callback calls hours.in_minutes, which requires ActiveSupport::Duration. Pass 4.hours (not 4.hours.to_i) to CreateWorkload. All specs pass hours as Duration, never Integer.
§
When writing Rails console snippets that produce output, keep it focused and concise. User said 'ficou confuso de analisar pois tem muitos dados' when a snippet listed all 284 agreements with full details. Prefer summary counts + only the exceptional/anomalous cases in the output (e.g. duplicates, missing records), not a full dump of every record.