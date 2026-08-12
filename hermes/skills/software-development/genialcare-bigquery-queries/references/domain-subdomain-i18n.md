# Domain/Subdomain i18n Mapping (PT-BR ↔ EN)

Source: `projects/core/config/locales/pt-BR/common.yml` under `pt-BR.activerecord.enum.domain:` and `pt-BR.activerecord.enum.subdomain:`

Use this when:
- Mapping CSV column values (Portuguese) to BigQuery enum values (English)
- Cross-referencing clinical-panel display labels with database values
- Building import rakes that need Portuguese → English de-para

## Domains (Fono-related)

| Portuguese (CSV/i18n) | BQ enum value |
|---|---|
| Fala | `speech` |
| Motricidade Orofacial | `orofacial_motricity` |
| Comunicação Aumentativa e Alternativa | `augmentative_and_alternative_communication` |

## Subdomains (Fono-related)

| Portuguese (CSV/i18n) | BQ enum value |
|---|---|
| Troca fonológica | `phonological_substitution` |
| Vocalização | `vocalization` |
| Controle mandibular | `mandibular_control` |
| Controle labial | `labial_control` |
| Controle de língua | `tongue_control` |
| Prosódia | `prosody` |
| Mastigação | `chewing` |
| Respiração | `breathing` |
| Articulação | `articulation` |
| Comunicação aumentativa alternativa | `augmentative_and_alternative_communication` |
| Inventário fonético | `phonetic_inventory` |
| Configuração de palavras | `word_configuration` |
| Processo fonológico | `phonological_process` |
| Sistema de comunicação | `system_communication` |
| Manipulação do dispositivo | `device_manipulation` |
| Habilidade com dispositivo | `device_skill` |

## Domains (Vineland)

| Portuguese (i18n) | BQ enum value |
|---|---|
| Comunicação | `communication` |
| Atividades de vida diária | `daily_living_skills` |
| Socialização | `socialization` |
| Habilidades motoras | `motor_skills` |

## Domains (Play)

| Portuguese (i18n) | BQ enum value |
|---|---|
| Simples | `simple` |
| Combinado | `combination` |
| Pré-simbólico | `pre_symbolic` |
| Simbólico | `symbolic` |

## Domains (Sensory/OT)

| Portuguese (i18n) | BQ enum value |
|---|---|
| Tátil | `tactile` |
| Olfato e Paladar | `smell_and_taste` |
| Vestibular | `vestibular` |
| Propriocepção | `proprioception` |
| Vestibular e Propriocepção | `vestibular_proprioception` |
| Auditivo | `auditory` |
| Visual | `visual` |
| Práxis | `praxis` |

## Domains (Occupational/ADL)

| Portuguese (i18n) | BQ enum value |
|---|---|
| Alimentação | `feeding` |
| Higiene | `hygiene` |
| Vestuário | `dressing` |
| Uso do banheiro | `toileting` |
| Sono/Descanso | `sleep_rest` |
