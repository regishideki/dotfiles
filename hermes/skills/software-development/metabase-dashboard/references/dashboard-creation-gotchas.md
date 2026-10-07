# Creating cards & dashcards from scratch (Metabase v0.60.3)

Verified against analytics-panel.genialcare.com.br (v0.60.3). These are the
things that break a from-scratch build (fresh collection → cards → dashboard).

## Card creation (POST /api/card)

- `POST /api/card` (native) **requires** `"visualization_settings": {}` in the
  payload. Omitting it returns
  `400 {"specific-errors":{"visualization_settings":["missing required key, recebido: nil"]}}`.
- Native SQL goes in `dataset_query.native.query` (the old `{"type":"native", ...}`
  format is still accepted and normalized server-side):
  ```json
  {"type":"native","native":{"query":"<sql>","template-tags":{}},"database":4}
  ```

## Adding cards to a dashboard

- `POST /api/dashboard/:id/cards` **does not exist** — returns
  `"O endpoint da API não existe"`. The ONLY way to add cards is
  `PUT /api/dashboard/:id` with the full `dashcards` array (a full-layout
  replacement; there is no insert-one-card endpoint).
- When creating a FRESH dashboard via PUT, **every** dashcard — regular query
  cards AND text/heading `virtual_card` cards — needs a unique negative `id`
  (-1, -2, -3…). A regular card with no `id` field is **silently dropped**: the
  PUT returns 200/ok but a follow-up `GET` shows 0 dashcards. The "unique
  negatives" rule applies to ALL new dashcards, not just text cards.

## Layout & width

- `width` is only honored on `PUT /api/dashboard/:id` (`{"width":"full"}`).
  Setting it on the initial `POST /api/dashboard` comes back as `"fixed"`.

## Verified from-scratch workflow

1. `POST /api/card` per card (with `visualization_settings:{}`), collect ids.
2. `POST /api/dashboard` with `{name, collection_id}`.
3. `GET /api/dashboard/:id` → grab `parameters` (usually `[]`).
4. `PUT /api/dashboard/:id` with `{"dashcards":[...], "parameters":params, "width":"full"}`,
   every dashcard carrying a unique negative `id`.
5. `GET /api/dashboard/:id` → assert `len(dashcards) == N` and each text card has
   `virtual_card` in its `visualization_settings`.

## SSL note (Python)

`urllib` on macOS Python 3.13 fails the TLS handshake against this host
(`CERTIFICATE_VERIFY_FAILED`), and a `CERT_NONE` context gets a 403 from the
front proxy. Use `curl` (system certs) instead — shell out from Python or write
a bash loop. This is the same Python-3.13-SSL issue as `references/raw-web-api-fallback.md`.
