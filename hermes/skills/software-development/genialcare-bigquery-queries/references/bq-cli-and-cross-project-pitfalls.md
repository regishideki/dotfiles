# bq CLI and cross-project join pitfalls

Two non-obvious gotchas that produced confidently-wrong results in the Fono de-para
session. Both are durable facts about `bq` and the GenialCare GCP layout, not setup noise.

## `--max_rows` silent truncation

`bq query --format=csv` truncates output to **100 rows by default**, and does so
**silently** (no truncation notice in the output). Paired with an `ORDER BY` that pushes
the rows you care about past the cut, you get a clean-looking but wrong answer.

Real case: counting `library_objectives` in the "Fonoaudiologia" protocol. With
`--format=csv` (no `--max_rows`) the result looked like **100** objectives; the true
count was **111** — the 11 missing rows (the entire `augmentative_and_alternative_communication/system_communication`
subdomain) fell silently past the 100-row cut.

**Rule:** whenever the row count matters, pass `--max_rows=<n>` explicitly (e.g.
`--max_rows=500`) AND independently confirm with an isolated `select count(*)`. Do not
trust a default `--format=csv` count.

## `datakernel.tenants` cross-project join → "not found in location us-east1"

The `tenants` table does **not** live in `supervision-production-8f1v`. Joining
`supervision-production-8f1v.datakernel.tenants` fails with:

```
Not found: Dataset supervision-production-8f1v:datakernel was not found in location us-east1
```

`datakernel` (and `tenants`) is in the **data-kernel** project
(`data-kernel-production-4o7n`). To filter by tenant name inside a
`supervision`/`intervention` query, either:

- qualify the tenants table with the data-kernel project:
  `` `data-kernel-production-4o7n.datakernel.tenants` ``, or
- drop the tenants join entirely when the tenant filter isn't essential (the Fono de-para
  only needed objective descriptions, so the join was removable and the query ran).
