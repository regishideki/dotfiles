# Migration Cross-Match Pattern

How to compare a CSV import file against production database to determine
which records will be created, updated, or discarded.

## When to use

- Planning a data migration rake task
- Importing objectives, strategies, or other catalog data from a spreadsheet
- User provides a CSV and asks "what will happen when we run this?"

## Steps

### 1. Extract and normalize CSV

```python
import csv, json, unicodedata

def normalize(s):
    return unicodedata.normalize("NFKD", s.lower()).encode("ascii", "ignore").decode()

csv_data = []
with open("data/import.csv") as f:
    for row in csv.DictReader(f):
        csv_data.append({
            "description": row["Column Name"].strip(),
            "desc_norm": normalize(row["Column Name"]),
            # ... other columns
        })
```

### 2. Extract production data via BigQuery

```python
from google.cloud import bigquery
client = bigquery.Client(project="supervision-production-8f1v")

query = """
SELECT id, description, discarded_at, ...
FROM `supervision-production-8f1v.intervention.library_objectives`
WHERE tenant_id = '6f8da042-2dd1-4872-a613-84d371bde78c'  -- GenialCare only
"""
db_data = [{"id": r.id, "description": r.description, "desc_norm": normalize(r.description), ...}
           for r in client.query(query)]
```

**Always filter by tenant_id** — every row appears 2x (GenialCare + Care+Mindplace).

### 3. Cross-match

```python
csv_norms = set(o["desc_norm"] for o in csv_data)
db_active = {o["desc_norm"]: o for o in db_data if o["discarded_at"] is None}

matched = csv_norms & set(db_active.keys())   # UPDATE evolution check
to_create = csv_norms - set(db_active.keys())  # CREATE new
to_discard = set(db_active.keys()) - csv_norms  # DISCARD (soft-delete)
```

### 4. Fuzzy check on "to discard"

Run Levenshtein distance on the discard candidates against CSV norms to catch
near-misses (typos, formatting differences):

```python
for db_norm in to_discard:
    best = min(csv_norms, key=lambda n: levenshtein(db_norm, n))
    dist = levenshtein(db_norm, best)
    if dist <= 12:
        print(f"POSSIBLE MATCH: DB='{db_norm}' vs CSV='{best}' (dist={dist})")
```

Distances ≤12 are worth manual review. Distances ≥20 are genuine discards.

### 5. Check for CSV duplicates

```python
from collections import Counter
dupes = {n: c for n, c in Counter(o["desc_norm"] for o in csv_data).items() if c > 1}
```

**Accent trap:** normalization strips accents. `/e/` and `/é/` become the same
ASCII string but are distinct phonemes in Portuguese. Always compare by
**original** (un-normalized) description in the rake task, not normalized.
Use normalized only for initial matching; the rake must use exact string
comparison on the original text.

### 6. Save results

Save both the cross-match results and a snapshot of production data for future
reference:

```
data/pre-analise-migracao.json   # match/keep/discard breakdown
data/producao-<domain>-<timestamp>.json  # full production snapshot
```

## Pitfalls

- **Tenant duplication:** 2 tenants = 2 copies of every row. Filter by `tenant_id` before matching, otherwise counts are doubled.
- **Table name mapping:** Rails `table_name` != BigQuery table name. Use `INFORMATION_SCHEMA` to list tables rather than guessing.
- **Accent normalization:** Use original strings for the actual migration. Normalized is for analysis only.
- **Decimal serialization:** BigQuery `DECIMAL` values fail `json.dump`. Cast with `float()` before serializing.
