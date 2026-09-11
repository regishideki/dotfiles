# Documents Config & Visibility System

Investigation from PR #6427 (PEC-4149) — "Documentos ficam invisíveis em
casos de tenants com configurações incompletas".

## The problem

After introducing scope-based filtering (clinical/operational) on
`Documents::ClinicalCaseFileTypeConfig`, documents became invisible in
tenants that lacked generic configs (insurance_health_plan=nil,
discipline=nil) for some document types. The `by_config_scopes` scope
only returns document types that have a matching DB record — no fallback.

## Key components

### `Documents::ClinicalCaseFile.by_config_scopes` (app/models/)
```ruby
scope :by_config_scopes, ->(scopes) {
  normalized_scopes = Array(scopes).filter_map { |scope| scope.to_s.presence }.uniq
  return all if normalized_scopes.empty?

  document_types = Documents::ClinicalCaseFileTypeConfig
    .where(normalized_scopes.map { "? = ANY(scopes)" }.join(" OR "), *normalized_scopes)
    .select(:document_type)

  where(document_type: document_types)
}
```
DB-only query. If no config exists for a document_type, that type is
absent from the subquery → files of that type are filtered out → invisible.

### `Documents::Services::DocumentTypeConfigResolver` (app/services/)
Has a fallback chain: plan+discipline config → plan config → generic
config → `payload_from_enum` (computed from constants). Always returns
a value. Used by the upload/signing flow, NOT by the list/filter scope.

### `Documents::ClinicalCaseFileTypesPresenter` (app/presenters/)
Reads `ClinicalCaseFileTypeConfig.pluck(:document_type, :scopes,
:manual_upload_enabled)` — DB-only. Falls back to `default_metadata`
(scopes: [], manual_upload_enabled: false) for types without a config.
This means types without configs show up in the presenter but with
empty scopes, so they get filtered out by the scope intersection.

### `Documents::ClinicalCaseFileTypeConfigBackfill` (app/services/)
Two entry points:
- `call(tenant:)` — original, uses `find_or_initialize_by` + `save!`.
  Called only from `db/seeds.rb`.
- `build_generic_config(tenant:, document_type:)` — returns unsaved
  config with defaults. Used by the backfill rake for dry-run.

### `Documents::Enum::ClinicalCaseFileTypes.eligible_for_generic_backfill`
Returns `all - EXCLUDED_FROM_GENERIC_BACKFILL`. Excluded types (e.g.
INFORMED_CONSENT_FORM) should NOT get generic configs.

## The backfill rake (PR #6427)

`lib/tasks/documents/backfill_missing_clinical_case_file_type_configs.rake`
- ENV: `TENANT_NAMES` (required, comma-separated or "all"), `DRY_RUN`
  (default "true")
- Dry-run by default, idempotent (checks existing generic configs before
  creating)
- Uses `build_generic_config` + non-bang `save` (per AGENTS.md)
- Per-tenant `CurrentTenant.with_tenant` wrapping

## Gap: no automatic provisioning for new tenants

`ClinicalCaseFileTypeConfigBackfill.call` is only called from
`db/seeds.rb`. There is no `after_create` on `Tenant`, no provisioning
job, no onboarding hook. New tenants created in production will have
zero document configs until someone manually runs the rake.

Options to fix permanently:
1. `after_create` on `Tenant` calling `ClinicalCaseFileTypeConfigBackfill.call`
2. Provisioning job enqueued during tenant onboarding
3. Change `by_config_scopes` to be generous with unconfigured types
   (treat "no config" as "all scopes" instead of "no scopes")

Option 3 changes the semantics: config becomes optional for visibility
rather than required. The rake + option 1/2 keeps config as the source
of truth for scope assignment.
