# Evolution checks & users — schema notes

## Who "created" an evolution check

`intervention.evolution_checks` has NO `created_by_id`. The author/performer of the
check is `assessed_by_id` (a `users.id`). Full column set:

| column                  | type      | notes                          |
|-------------------------|-----------|--------------------------------|
| id                      | STRING    | evolution_check id             |
| assessed_by_id          | STRING    | **who created/performed** the check (join `users.id`) |
| intervention_session_id | STRING    | `datakernel.sessions.id`       |
| assessed_at             | TIMESTAMP | when the check was performed   |
| tenant_id               | STRING    |                                |
| created_at / updated_at | TIMESTAMP |                                |

So "quem criou a checagem de evolução dessa sessão" is answered by filtering on
`intervention_session_id` and joining `assessed_by_id -> users`.

## `datakernel.users` has NO `name` column

Columns are exactly: `id`, `email`, `first_name`, `last_name`, `created_at`,
`updated_at`. Referencing `u.name` fails with `Name name not found inside u`.
Use `u.email` (and `first_name`/`last_name`, which may be NULL) for the person's
identity.

## Reusable query: author of an evolution check by session UUID

```sql
SELECT
  ec.id AS evolution_check_id,
  ec.assessed_at,
  ec.assessed_by_id,
  u.email AS assessed_by_email,
  u.first_name,
  u.last_name
FROM `supervision-production-8f1v`.intervention.evolution_checks ec
LEFT JOIN `data-kernel-production-4o7n`.datakernel.users u
  ON u.id = ec.assessed_by_id
WHERE ec.intervention_session_id = '<session-uuid>'
```

## bq auth token expiry

`bq query` / `gcloud` failing with "Reauthentication failed. cannot prompt during
non-interactive execution" means the refresh token is stale. Fix: run
`gcloud auth login` in a PTY (opens browser, completes OAuth). After it reports
"logged in as <user>", `bq query` works again. This recurs periodically.
