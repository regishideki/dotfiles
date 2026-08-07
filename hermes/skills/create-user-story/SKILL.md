---
name: create-user-story
description: "Create user story docs from Slack threads or requests."
category: software-development
---

# Create User Story

Fluxo de planejamento: transforma uma thread do Slack, issue do Jira, ou descrição de feature em documentação estruturada de user story em `documentations/user_stories/<yyyyMMdd>-<slug>/`.

## Passo 1: Coletar o contexto

Se a origem for uma thread do Slack:
- Extrair channel_id e message_ts da URL: `https://genial-care.slack.com/archives/<CHANNEL>/p<TIMESTAMP>`
  - Converter timestamp: remover o `p`, inserir `.` após o 10º dígito (ex: `p1782390872587999` → `1782390872.587999`)
- Usar `tool_call` com `mcp__slack__slack_read_thread` para ler a thread completa

Se for descrição textual ou issue do Jira, usar o texto diretamente.

## Passo 2: Criar a estrutura de pastas

Formato: `documentations/user_stories/<yyyyMMdd>-<slug>/`

O slug deve ser curto e descritivo, em kebab-case, capturando a essência da feature.

Criar a pasta com `mkdir -p`.

## Passo 3: Escrever analysis.md

Estrutura do analysis.md:

```markdown
# Analysis: <título>

## Origem
Link da thread/issue, solicitante, data.

## Problema
Descrição clara do problema a ser resolvido.

## Sistemas envolvidos
Lista dos projetos impactados (clinical-panel, clinical-panel-bff, core, etc.)

## Entendimento do domínio
Explicação de como a feature funciona hoje, em linguagem de produto.

## Decisões
Decisões tomadas na thread, se houver.

## Dados técnicos relevantes
Tabelas, endpoints, use cases envolvidos.

## Perguntas em aberto
O que ainda precisa ser investigado ou decidido.
```

## Passo 4: Escrever PRD.md

Estrutura do PRD.md:

```markdown
# PRD: <título>

## Problema
Uma frase resumindo o problema.

## Solução
O que vai ser feito, em alto nível.

## Valor
Por que isso importa — impacto no negócio ou na operação.

## Critérios de aceite
Lista numerada de condições que definem "pronto".

## Fora de escopo
O que explicitamente NÃO faz parte desta user story.
```

## Passo 5 (opcional): Análise cross-repo

Se o usuário pedir para analisar os projetos envolvidos antes de decidir a solução, seguir a metodologia em `references/cross-repo-analysis.md`.

## Pitfalls

- **Slack message_ts**: o formato da URL é `p<unix_microseconds>`. Converter inserindo `.` após o 10º dígito.
- **Skill não existe**: se o comando delegar para uma skill que não existe, fazer manualmente seguindo este workflow. Reportar o gap.
- **Projetos via symlink**: os repos irmãos ficam em `projects/` (symlinks). Rodar `./sync.sh` se não estiverem disponíveis.
- **Escopo claro**: se a discussão original tem múltiplas frentes, confirmar com o usuário quais entram na story e quais ficam de fora. Remover as frentes descartadas dos docs.
- **Não confundir ideal com prático**: quando o problema envolve métricas com duas bases de cálculo (ex: prescrito vs agendado), a story deve deixar claro qual é qual e qual está no escopo. Validar o entendimento com o usuário antes de escrever.
- **Slug descritivo**: evitar slugs genéricos. Se o escopo mudar durante a criação, renomear a pasta (`mv`). Ex: `metrica-hbj-historica` → `hbj-horas-agendadas-painel`.
- **Manter docs sincronizados**: se o escopo mudar, atualizar analysis.md e PRD.md juntos.
