# Mapper missing objectives pattern

When a mapper table (N×N) joins on `description` text and you need to find which
descriptions don't exist in the GenialCare `library_objectives`, the naive approach
returns duplicates because each missing description appears in multiple mapper rows.

## Pattern: DISTINCT + UNION per side

Split into two CTEs (one per mapper column), use `DISTINCT` to collapse duplicates,
then `UNION DISTINCT` to merge. Each missing objective appears once.

```sql
WITH genial_library_objectives AS (
  SELECT lo.*
  FROM `supervision-production-8f1v.intervention.library_objectives` lo
  INNER JOIN `data-kernel-production-4o7n.datakernel.tenants` t ON t.id = lo.tenant_id
  WHERE t.name = "genialcare"
    AND lo.discarded_at IS NULL
),
missing_side_a AS (
  SELECT DISTINCT
    TRIM(LOWER(mapper.col_a)) AS objective,
    'col_a' AS source
  FROM mapper
  LEFT JOIN genial_library_objectives lo
    ON TRIM(LOWER(mapper.col_a)) = TRIM(LOWER(lo.description))
  WHERE lo.id IS NULL
),
missing_side_b AS (
  SELECT DISTINCT
    TRIM(LOWER(mapper.col_b)) AS objective,
    'col_b' AS source
  FROM mapper
  LEFT JOIN genial_library_objectives lo
    ON TRIM(LOWER(mapper.col_b)) = TRIM(LOWER(lo.description))
  WHERE lo.id IS NULL
)
SELECT objective, source FROM missing_side_a
UNION DISTINCT
SELECT objective, source FROM missing_side_b
ORDER BY source, objective
```

Key points:
- `TRIM(LOWER(...))` handles whitespace/case mismatches but NOT real typos
- `UNION DISTINCT` deduplicates across both sides (same text missing in both
  columns appears once)
- The tenant filter in the CTE avoids the 2× duplication pitfall

## Two-layer normalization for trivial mismatches

`TRIM(LOWER(...))` alone misses many false positives: trailing periods/commas,
curly vs straight quotes, ellipsis (`...`) vs `?`, extra whitespace, `etc` vs `etc.`,
`, etc)` filler. Apply TWO normalization layers to both the mapper text and the
library text before comparing.

Encapsulate in a UDF to keep the query clean:

```sql
CREATE TEMP FUNCTION normalize_obj(text STRING) AS (
  -- Layer 2: safe post-Layer 1 normalizations
  REGEXP_REPLACE(
    REGEXP_REPLACE(
      -- Layer 1: base normalization
      REGEXP_REPLACE(
        REPLACE(
          REPLACE(
            REPLACE(
              REGEXP_REPLACE(TRIM(LOWER(text)), r'[.,;]+$', ''),  -- strip trailing .,;
              '...', ''                                             -- remove ellipsis
            ),
            '\u201c', '"'   -- left curly double quote → straight
          ),
          '\u201d', '"'     -- right curly double quote → straight
        ),
        r'\s+', ' '          -- collapse multiple spaces
      ),
      -- Layer 2a: normalize "etc." and "etc," → "etc" (followed by space or paren)
      r'\betc[.,]\s', 'etc '
    ),
    -- Layer 2b: remove ", etc)" filler before closing paren
    r', etc\)', ')'
  )
);
```

Then use `normalize_obj(...)` on both sides of the join/comparison.

**Layer 1** resolves ~75% of false positives (38 of 51 in the GenialCare TO mapper):
trailing punctuation, curly quotes, ellipsis, whitespace.

**Layer 2** adds safe, low-risk normalizations that catch another ~5%:
- `etc.` / `etc,` → `etc` (the period after "etc" is a spelling variation, not a meaningful difference)
- `, etc)` → `)` (", etc" before closing paren is filler with no semantic value)

These Layer 2 transforms are SAFE because:
- `\betc[.,]\s` uses word boundary `\b` — won't match inside words like "petcare"
- `, etc)` is highly specific — won't match legitimate text differences

**Caution:** do NOT add broader transforms (substring, edit distance, removing arbitrary
words like "ao", "diariamente", fixing typos like "preposiçõe") — the risk of false
positive matches is high and errors are silent. If the user wants those, ask them to
review each case manually.

## Accent pitfall — normalize_obj does NOT handle accents

The `normalize_obj` UDF uses `LOWER()` which preserves Unicode accents. Strings
that differ only in accents (`posição` vs `posicao`) will NOT match after
normalization.

When the user asks to replace a mapper entry with a library description that was
found to be similar, **always provide the exact accented text** from the library.
The user may copy-paste without accents, causing a false "missing" on the next
run. When asked, retrieve the full description from the library (with accents)
and present it verbatim.

Do NOT attempt to add accent-stripping to the UDF — it would be lossy (é→e,
ã→a, ç→c) and could cause false-positive collisions between genuinely different
objectives that differ only by accent in some words.

## Mismatch categories — what normalization resolves vs what remains

Starting from 51 "missing" objectives in the GenialCare TO mapper
(`pei_track_to_occupational_therapy_objectives`):

### Resolved by Layer 1 normalization (~38 cases, ~75%)

| Category | Example | Count |
|----------|---------|-------|
| Trailing `.` or `,` | `"...fora de alcance"` vs `"...fora de alcance."` | ~12 |
| Curly quotes `""` vs straight `""` + ellipsis `...?` vs `?` | `"por que?"` vs `"por que?"` | ~25 |
| Misc punctuation/whitespace | `"(ex: ... ),"` vs `"(ex: ... )"` | ~1 |

### Resolved by Layer 2 normalization (~2 cases, ~5%)

| Category | Example | Count |
|----------|---------|-------|
| `etc` vs `etc.` | `"..., alimentos, etc para..."` vs `"..., alimentos, etc. para..."` | 1 |
| `, etc)` filler | `"...pulando, etc)"` vs `"...pulando)"` | 1 |

### Not resolvable by safe normalization (~7 cases, ~14%)

These require human judgment — normalization would risk false positives:

| Category | Example | Count |
|----------|---------|-------|
| Extra/missing words | `"narra o que faz"` vs `"narra o que faz **diariamente**"`; `"um verbo e substantivo"` vs `"um verbo e **um** substantivo"` | 2 |
| Typos in mapper | `"**ao** para mover"` (extra word); `"**preposiçõe**"` (missing 's'); `"**uma** corpo"` (wrong article) | 3 |
| Typos in library | `"**difrentes**"` instead of `"diferentes"` — the library has the typo, not the mapper | 1 |
| Completely different wording | Different phrasing for same concept (e.g. `"demonstra comportamentos de antecipação..."` vs `"ajusta a posição do corpo e membros demonstrando antecipação..."`) | 2 |
| Discarded (exact match exists) | Exact text exists in library but `discarded_at IS NOT NULL` | 1 |
| NULL in mapper | One side of the mapper has NULL value | 1 |

### Remaining after both layers (~9 cases, ~18%)

The 9 remaining cases after Layer 1+2 are: 2 extra/missing words, 3 mapper typos,
1 library typo, 2 different wording, 1 discarded, 1 NULL. Of these, only the
discarded one has an exact match in the library — the rest are genuine data issues
that should be fixed at the source (mapper or library).

## Resolving mapper descriptions to objective IDs (pairs query)

After using the missing-objectives query to validate the mapper, you often need the
actual objective ID pairs — one ID per side of the mapper. Join the mapper with
the library on normalized descriptions and return `DISTINCT` pairs:

```sql
CREATE TEMP FUNCTION normalize_obj(text STRING) AS (
  -- same two-layer normalization UDF as above
);

WITH genial_library_objectives AS (
  SELECT lo.id, lo.tenant_id, lo.description,
         normalize_obj(lo.description) AS description_norm
  FROM `supervision-production-8f1v.intervention.library_objectives` lo
  INNER JOIN `data-kernel-production-4o7n.datakernel.tenants` t ON t.id = lo.tenant_id
  WHERE t.name = "genialcare" AND lo.discarded_at IS NULL
),
mapper_norm AS (
  SELECT
    normalize_obj(mapper.occupational_therapy_objective) AS to_obj_norm,
    normalize_obj(mapper.pei_track_objective) AS pei_obj_norm
  FROM `supervision-production-8f1v.intervention.pei_track_to_occupational_therapy_objectives` mapper
)
SELECT DISTINCT
  pei_track_obj.id AS main_objective_id,
  to_obj.id AS support_objective_id,
  to_obj.tenant_id
FROM mapper_norm
INNER JOIN genial_library_objectives pei_track_obj
  ON mapper_norm.pei_obj_norm = pei_track_obj.description_norm
INNER JOIN genial_library_objectives to_obj
  ON mapper_norm.to_obj_norm = to_obj.description_norm
ORDER BY main_objective_id, support_objective_id
```

Key points:
- Same `normalize_obj` UDF — consistency with the validation query
- `SELECT DISTINCT` because the mapper is N×N (each description can appear in
  multiple rows)
- Include `tenant_id` in the output (genialcare =
  `6f8da042-2dd1-4872-a613-84d371bde78c`)
- This query returns only successfully matched pairs — unmatched descriptions
  are silently dropped (use the missing-objectives query to find those)

## Debugging row count discrepancies

When `missing-objectives` returns empty (all mapper objectives have library matches)
but `mapper-objective-pairs` (with DISTINCT) returns fewer rows than the mapper total,
there are two possible causes:

1. **Duplicate pairs in the mapper** — the N×N mapper can have identical pairs in
   multiple rows. The DISTINCT collapses them. Create a non-DISTINCT variant of the
   pairs query (`mapper-objective-pairs-all.sql`) and compare its count to the mapper
   total.

2. **NULL or empty values in mapper columns** — `normalize_obj(NULL)` = NULL, and
   `NULL INNER JOIN` silently drops the row. Both `missing-objectives` (has `IS NOT NULL`)
   and `pairs` (INNER JOIN drops NULLs) ignore these rows identically. The symptom:
   `pairs_all count < mapper count` even though `missing-objectives` is empty.

   Run a diagnostic query to count NULL/empty rows:
   ```sql
   SELECT
     CASE
       WHEN col_a IS NULL OR TRIM(col_a) = '' THEN 'col_a nulo/vazio'
       WHEN col_b IS NULL OR TRIM(col_b) = '' THEN 'col_b nulo/vazio'
       ELSE 'ambos OK'
     END AS status,
     COUNT(*) AS total
   FROM mapper_table
   GROUP BY status
   ```
   The equation is: `pairs_all + null_rows = mapper_total`.

**Resolution path:**
1. Run `missing-objectives` → should be empty (all have matches)
2. Run `mapper-objective-pairs-all` (no DISTINCT) → should equal mapper total
3. If step 2 < mapper total, run the null-check diagnostic → NULL rows explain the gap
4. Only if all three pass, the DISTINCT in the production query is safe — it's just
   collapsing legitimate duplicate pairs

## External table → native table pipeline (Google Sheets → BigQuery)

When the mapper starts as a federated table backed by Google Sheets (which can't be
queried from CLI/ADC) and you want to convert it to a native BigQuery table with
resolved objective IDs:

### Step 1: Rename the external table and create `_raw`

Create `external-table.sql` with the original CREATE EXTERNAL TABLE DDL but using
a `_raw` suffix:

```sql
CREATE OR REPLACE EXTERNAL TABLE
  `supervision-production-8f1v.intervention.<original_name>_raw` (...)
OPTIONS (format = 'GOOGLE_SHEETS', uris = [...], ...);
```

All existing queries that read from the mapper should reference `<original_name>_raw`.
Save the DDL in a file so it's reproducible.

### Step 2: Update all dependent queries

Search all SQL files referencing `<original_name>` and replace with
`<original_name>_raw`. The queries that used the federated table now read from `_raw`
instead.

### Step 3: Create the native table from `_raw`

The pairs query (`mapper-objective-pairs.sql`) does double duty: it resolves mapper
descriptions to objective IDs AND creates the native table. Wrap the SELECT with
`CREATE OR REPLACE TABLE`:

```sql
CREATE OR REPLACE TABLE
  `supervision-production-8f1v.intervention.<original_name>` AS
WITH ...
SELECT DISTINCT
  pei_track_obj.id AS main_objective_id,
  to_obj.id AS support_objective_id,
  to_obj.tenant_id
FROM mapper_norm
INNER JOIN genial_library_objectives ...
```

Now `<original_name>` holds resolved ID pairs (native table) and
`<original_name>_raw` holds the original text descriptions (federated, for
re-running validation when the Sheet changes).

The order of operations is:
1. Run `external-table.sql` to create `_raw` (or update it if the Sheet changed)
2. Run `missing-objectives-in-mapper.sql` to validate — should return empty
3. Run `mapper-objective-pairs.sql` to create/replace the native table
4. (Optional) Run `mapper-objective-pairs-all.sql` to verify row counts

Queries not listed here continue to use `<original_name>_raw`.

For a complete working example, see:
- `queries/occupational-therapy-mapper/external-table.sql`
- `queries/occupational-therapy-mapper/mapper-objective-pairs.sql`

## Full examples

- `queries/occupational-therapy-mapper/external-table.sql` — CREATE EXTERNAL TABLE
  DDL for the Google Sheets mapper (with `_raw` suffix)
- `queries/occupational-therapy-mapper/missing-objectives-in-mapper.sql` — finds
  descriptions in the mapper that don't match any genialcare library objective
- `queries/occupational-therapy-mapper/mapper-objective-pairs.sql` — resolves
  matched mapper descriptions to objective ID pairs and creates the native table
  via CREATE OR REPLACE TABLE (with DISTINCT, for production)
- `queries/occupational-therapy-mapper/mapper-objective-pairs-all.sql` — same as
  above but without DISTINCT (debugging variant to verify row counts)
- `queries/occupational-therapy-mapper/mapper-null-check.sql` — counts NULL/empty
  values per mapper column (explains row count gaps)
