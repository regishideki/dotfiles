# Enum migration checklist — adding a new enum value

When adding a new value to an enum used across the stack (e.g. new subdomain,
domain, or any `Enum::Base` subclass), these are ALL the files that need changes:

## 1. Core — enum definition

`packs/clinical/app/models/enum/<name>.rb`

Add the new constant and include it in `self.all`.

## 2. Core — i18n translations

`config/locales/pt-BR/common.yml`

Add the Portuguese translation under the appropriate key (e.g. `subdomain:`).
Used by Rails `I18n.t` and the `Enum::Base#human_values` helper.

## 3. Clinical-panel — i18n translations (DUPLICATED)

`src/i18n/locales/protocol/pt-br.json`

Add the Portuguese translation under the appropriate key (e.g. `subdomain:`).
The clinical-panel maintains its own copy of domain/subdomain translations —
it does NOT consume them from the core. The PEI Track table uses
`t(\`subdomain.${value}\`)` which resolves against this file.

## NOT needed

These projects do NOT need changes when adding enum values:

- **clinical-panel-bff** — `subdomain` is a plain `String` in the GraphQL schema,
  not an enum type. Values pass through unchanged.
- **mobile** — No subdomain/domain references found.
- **mobile-bff** — No subdomain/domain references found.

## Discovery pattern

To map Portuguese CSV values to English enum values:

1. Read `core/config/locales/pt-BR/common.yml` for the full PT → EN mapping
2. Cross-reference with `clinical-panel/src/i18n/locales/protocol/pt-br.json`
   to confirm translations match
3. Query BigQuery to see which values are actually used in production:
   ```sql
   SELECT DISTINCT pi.subdomain
   FROM protocols p
   JOIN protocol_items pi ON p.id = pi.protocol_id
   JOIN library_objectives lo ON lo.protocol_item_id = pi.id
   WHERE p.name = '<protocol>' AND lo.discarded_at IS NULL AND pi.discarded_at IS NULL
   ORDER BY 1
   ```
4. For values NOT in the enum, check if they should map to an existing value
   or if a new enum value is needed
