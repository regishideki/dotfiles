# Native-card column rendering, dashcard override & progressive disclosure

Lessons from building a native-SQL drill-down dashboard (fonologia). Applies to any
native-SQL card placed on a dashboard.

## 1. Column settings apply at the DASHCARD level, not the card level

A card on a dashboard has TWO `visualization_settings`:

- the **card's** own — GET/PUT `/api/card/:id`;
- the **dashcard's** — the per-placement copy inside the dashboard's `dashcards[]`
  (GET/PUT `/api/dashboard/:id`).

At render time the dashcard's settings override the card's. A dashcard left with an empty
`column_settings: {}` (e.g. after you edited click_behavior and removed its last entry)
**silently wipes the card's column settings**.

Symptom that bites hard: you PUT a column setting (`markdown_template`, `wrap_text`,
`table.column_formatting`) on the card, GET echoes it back correctly, but the dashboard
renders WITHOUT it. Two separate attempts this session (markdown rendering, then
`wrap_text`) failed for exactly this reason before it was root-caused — the setting was
always on the card, never on the dashcard.

**Fix:** for a card placed on a dashboard, set column-level formatting on the DASHCARD
(edit that dashcard's `visualization_settings.column_settings`), not just the card. Or
strip the empty `column_settings: {}` override from the dashcard so the card's own
settings surface. **Verify by GETting the dashboard** and confirming the dashcard's
`visualization_settings` actually carries the key — not by GETting the card.

```python
# dashcard-level wrap_text
for dc in dash["dashcards"]:
    if dc["card_id"] == CARD_ID:
        vs = dc.setdefault("visualization_settings", {})
        cs = vs.setdefault("column_settings", {})
        cs['["name","detalhes"]'] = {"wrap_text": True}
```

## 2. Rendering `\n` as line breaks in a table cell

Metabase table cells collapse `\n` to a space by default. Two recipes (both must land at
the dashcard level, per §1):

1. **`\n` + `wrap_text`** — aggregate with a real `'\n'` delimiter in SQL (BigQuery
   `STRING_AGG(x, '\n')`), then set `column_settings['["name","col"]'] = {"wrap_text": true}`.
2. **`<br>` + markdown** — aggregate with `'<br>'`, then set
   `column_settings['["name","col"]'] = {"markdown_template": "{{value}}"}`.

The user reports the "wrap text" option (`wrap_text`) is what worked for them on
MBQL/question cards; native cards accept the same `wrap_text` key. `markdown_template`
with `{{value}}` renders the cell through the markdown renderer (so `<br>` becomes a break).

## 3. Progressive-disclosure drill-down ("escadinha")

To make a card render EMPTY (0 rows) until a filter is set — instead of showing all rows —
give the template tag a sentinel `default` and use an **unconditional** WHERE:

```python
tag = {"name": "vocabulo", "display_name": "Vocábulo", "type": "text", "default": "__none__"}
# SQL: WHERE vocabulo = {{vocabulo}}   (NO [[ ]])
```

Empty parameter → sentinel substituted → matches nothing → clean empty state; set
parameter → filters. Contrast with the optional `[[AND col = {{tag}}]]` clause, which
shows ALL rows when the parameter is empty.

This is the pattern for a cascade drill-down (word → transcription → process) where each
downstream card stays blank until the upstream click populates its filter. Each level
adds one required (sentinel) filter; the click_behavior crossfilter on the upstream column
populates the downstream parameter.

## 4. Crossfilter click behavior (recap)

A column becomes a filter source via the dashcard's `visualization_settings`:

```python
vs["column_settings"]['["name","vocabulo"]'] = {
    "click_behavior": {"type": "crossfilter",
        "parameterMapping": {"vocabulo": {
            "source": {"type": "column", "id": "vocabulo", "name": "vocabulo"},
            "target": {"type": "parameter", "id": "vocabulo"}, "id": "vocabulo"}}}}
```

and the target card subscribes via `parameter_mappings`:

```python
[{"parameter_id": "vocabulo", "card_id": TARGET, "target": ["variable", ["template-tag", "vocabulo"]]}]
```

The "processo"-style extra filter on a word-level card uses `EXISTS (SELECT 1 FROM
processes WHERE word_id = b.word_id AND LOWER(TRIM(name)) = {{processo}})`.
