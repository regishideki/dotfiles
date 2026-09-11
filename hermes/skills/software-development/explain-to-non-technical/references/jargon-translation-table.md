# Jargon translation table (canonical pairs)

Pairs actually applied when rewriting the Checagem de Evolução doc
(`documentations/features/checagem-evolucao/doc.md`) for non-technical readers.
Reuse these before inventing new translations; they are the user-approved vocabulary.

## Systems → roles

| Code name          | Reader-facing role          |
| ------------------ | --------------------------- |
| `clinical-panel`   | Painel do Terapeuta         |
| `clinical-panel-bff` | Camada Intermediária      |
| `core`             | Servidor                    |

## Attributes / code → what the user sees

| Code term             | Reader-facing                  |
| --------------------- | ------------------------------ |
| `was_assessed` true/false | "quando a criança foi/não foi avaliada" |
| `trial_counter`       | "Contagem de Tentativas"       |
| `checklist`           | "Checklist"                    |
| `evolution_scale`     | "escala de evolução"           |
| `prerequisites`       | "pré-requisitos"               |
| `requisites`          | "requisitos"                   |
| `targets`             | "metas"                        |
| `pros` / `cons`       | "o que a criança já faz" / "o que falta" |
| `correlation_id`      | "identificador único"          |
| `checkbox` / `textarea` / `radio` | "opção sim/não" / "campo de texto" / "escala de opções" |
| `tooltip`             | "passar o mouse no ?"          |
| `tag cyan`            | "verde-azulado"                |
| "Symbolic Play"       | "Brincar Simbólico"            |
| "Firestore"           | "o auto-save salva rascunho"   |
| "backend"             | "servidor"                     |
| "config"              | "configuração"                 |
| "migration de outubro/2025" | "tipo checklist foi introduzido em outubro/2025" |

## Delete entirely (reader never needs these)

- GraphQL, mutation, REST, endpoint — protocol/transport vocabulary.
- File paths and rake task names in the narrative (references section only).

## Notes

- The STI/enum distinction (`trial_counter` vs `checklist` vs no-config) maps cleanly to the
  visible "type of card" — this is the strongest single translation move for a subtype model.
- "Não avaliado" is a first-class business state the reader cares about, not just a flag.
