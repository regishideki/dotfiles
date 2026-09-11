# Migration snapshots: reconciling "absent" records against pre-migration state

When an objective/record/field looks like it "doesn't exist" in current production data, do NOT
conclude "never existed" before checking the migration snapshots under `documentations/initiatives/`.

## Where they live

`documentations/initiatives/<initiative>/user_stories/<date>-<slug>/data/*.json`

These are read-only dumps of production state captured at investigation time (they carry an
`extraido_em` field), often the "before" state of a planned migration. They are the cheapest
source of historical production state when BQ auth is unavailable.

## The Fono (speech therapy) case

`qualidade-pei-fono/.../data/producao-fono-objetivos.json` (extracted 2026-08-10) captured the
protocol BEFORE the "Migração de Objetivos e Checagem de Evolução de Fono". Old subdomains:

- `speech/prosody`, `speech/phonological_process`, `speech/phonetic_inventory`, `speech/word_configuration`
- `aac/device_skill`, `aac/system_communication`, `aac/device_manipulation`
- `orofacial_motricity/articulation`, `orofacial_motricity/breathing`, `orofacial_motricity/chewing`

The migration created `speech/sound_acquisition` (101 "Produz o fonema /X/ em palavras com
configuração ..." objectives) and removed the old speech subdomains. So objectives that look
"absent" in the current protocol — e.g. prosody items "tempo da vogal tônica", "entonação de
frases"; CAA "navega entre as pranchas" (was `device_skill`); "mantém os lábios fechados" (was
`breathing`) — actually existed pre-migration and were dropped. Re-adding them is reverting a
removal, not creating from scratch.

## Technique

1. When something seems absent, grep `documentations/initiatives/*/data/*.json` for the exact
   text (or a normalized form) first — it may be a pre-migration dump.
2. Compare subdomain taxonomies old vs new. An entire subdomain being gone (e.g. `prosody`,
   `device_skill`) is the tell that it was dropped in a migration, not never-present.
3. Confirm live in BQ (discarded_at set vs moved to another subdomain) before writing the
   conclusion into a doc — but only once auth is available.

## Presentation note

When listing objectives/items/fields for this user, give the FULL text — no `...` truncation.
The user explicitly asks to "listar de forma inteira, sem cortar nada".
