# Interactive Drill-Down Dashboards (crossfilter cascade + staircase)

Pattern for dashboards where the user drills down level by level (e.g. vocábulo → transcrição → processo → caso), each card revealing the next. Contrasts with the Single-RAW-via-model architecture: this pattern NEEDS template-tag filters, so the RAW can't be a model (pitfall #11) — you end up with native SQL per card (or a shared BigQuery view as the base).

## 1. Staircase empty-state via sentinel default

Make a card show NOTHING until its upstream filter is set — a clean empty state, not the "required filter" error.

Tag carries a sentinel default; the SQL uses an UNCONDITIONAL `WHERE col = {{tag}}` (NOT the `[[ ]]` optional form):

```python
SENTINEL = "__none__"
def tag(name, display, sentinel=False):
    t = {"name": name, "display_name": display, "type": "text"}
    if sentinel:
        t["default"] = SENTINEL   # value that never matches a real row
    return t
```

```sql
WHERE vocabulo = {{vocabulo}}   -- unconditional, NOT [[AND vocabulo = {{vocabulo}}]]
```

When the dashboard filter is empty, Metabase substitutes the sentinel → `col = '__none__'` → 0 rows. When set, it filters normally. Distinct from pitfall #16 (that one is `required:true` + numeric guard `> 0` to stop a card *breaking*; this one is a deliberate *empty-state*).

Cumulative staircase — each level's WHERE includes ALL upstream tags unconditionally:

- L2: `WHERE vocabulo = {{vocabulo}}`
- L3: `WHERE vocabulo = {{vocabulo}} AND transcricao = {{transcricao}}`
- L4: `WHERE ... AND EXISTS (SELECT 1 FROM t WHERE word_id = b.word_id AND LOWER(TRIM(name)) = {{processo}})`

A bottom "reference" card (raw data) keeps OPTIONAL tags (no sentinel, `[[ ]]` form) so it shows ALL data when nothing is selected but narrows as filters apply.

## 2. Crossfilter cascade (click a column → filter the next card)

Each card's `click_behavior` sets a parameter that the NEXT card consumes. Repeat per level:

```python
viz["column_settings"]['["name","vocabulo"]'] = {
  "click_behavior": {"type": "crossfilter",
    "parameterMapping": {"vocabulo": {
      "source": {"type": "column", "id": "vocabulo", "name": "vocabulo"},
      "target": {"type": "parameter", "id": "vocabulo"}, "id": "vocabulo"}}}}
```

Each downstream card gets one parameter_mapping per upstream filter:

```python
[{"parameter_id": "vocabulo", "card_id": X, "target": ["variable", ["template-tag", "vocabulo"]]},
 {"parameter_id": "transcricao", "card_id": X, "target": ["variable", ["template-tag", "transcricao"]]}]
```

## 3. Remove redundant context columns

In a staircase the upstream filter IS the context, so drop the columns that would repeat it (drop "vocabulo" from every card after the selector; drop "transcricao" from cards after the transcription card). Keep the column in the CTE for the WHERE, just don't SELECT it.

## 4. Merge a grouped table + detail table into one (inline detail column)

Instead of a separate detail table, list per-row details in a single column via STRING_AGG with a newline delimiter:

```sql
STRING_AGG(
  CONCAT('Caso ', b.caso, ' (#', b.avaliacao_num, ') — ', b.responsavel),
  '\\n' ORDER BY b.caso, b.avaliacao_num
) AS detalhes
```

This collapses a "grouped summary" + "case detail" pair into one table (group + inline detail), letting you delete the detail table AND its click parameter.

## 5. Removing a card / parameter cleanly

- Archive the dropped card: `PUT /api/card/{id}` with `{"archived": true}`.
- Remove its dashcard from the dashboard `dashcards` list.
- Drop the now-unused parameter from `parameters` AND purge its `parameter_mappings` + `click_behavior` from every remaining card (a dangling parameter shows up as a stray filter).

## Worked example (GenialCare phonological imitation)

Drill chain: vocábulo → transcrição → processo. The "vocabulo" selector card is the only one with a click on `vocabulo`; "Consistência" clicks `transcricao_normalizada`; "Processos" (merged with case detail via STRING_AGG) is terminal. The raw-data card follows vocabulo + transcricao via optional tags. See `code-snippets/queries/assessment/speech_therapy/speech-therapy-phonological-imitation.sql` for the domain base query.
