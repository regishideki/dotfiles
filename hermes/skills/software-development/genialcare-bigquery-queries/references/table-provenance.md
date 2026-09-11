# BQ Table Provenance (de-para)

Most tables exposed in BigQuery/Metabase originate from the `core` project — they mirror the
operational tables via CDC/Datastream. But the BigQuery table name **often differs** from the
source table name in `core`.

To find the mapping (de-para) between a BigQuery table and its source table, analyze the Dataform
repositories, which perform the transformation and renaming across the bronze/silver/gold layers:

- `data-kernel` — identity dimensions (users, tenants) as Gold `dim_*` BQ views
- `operational-data` — operational bronze/silver/gold models
- `supervision` — supervision domain models
- `semantic-data-layer` — semantic layer models

The `dataform-modeling` skill documents the bronze/silver/gold structure and naming conventions
(`dim_*`, `fct_*`, `int_*`, schemas by domain). Consult it when a BQ table name doesn't match what
you see in the source code.
