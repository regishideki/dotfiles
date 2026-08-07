---
name: ost-method
description: Build OSTs with metric trees for strategic planning.
---

# OST Method — Opportunity-Solution Tree com Árvore de Métricas

Método para construir OSTs (Opportunity-Solution Trees) enriquecidas com árvores de métricas (driver trees). Desenvolvido durante o piloto de capacidade clínica da GenialCare, mas aplicável a qualquer contexto de planejamento estratégico.

## Quando usar

- Quando o time quer migrar de roadmap para modelo baseado em oportunidades
- Quando objetivos atuais são formulados como output ("robustez", "eficiência") e não como outcome
- Quando há gap grande entre outcome e oportunidades (conexões indiretas precisam ser explicitadas via métricas)
- Quando se quer uma OST que vá além do canônico (outcome → ops → soluções) e inclua métricas intermediárias

## Estrutura do método (5 etapas)

### Etapa 1: Coleta de contexto

Reunir tudo que a organização já sabe: OKRs, dados de baseline, evidência de usuário (entrevistas, discovery), iniciativas em andamento. Fontes: Slack, Confluence, docs de discovery, entrevistas. **Não analisar ainda — só coletar.**

### Etapa 2: Análise da evolução do entendimento

Comparar planejamento inicial com descobertas posteriores. Perguntas: objetivos ainda fazem sentido? O que mudou? Quais premissas eram falsas? Quais métricas de baseline são sujas?

**Output:** doc "entendimento inicial" vs "entendimento atual".

### Etapa 3: Análise crítica dos OKRs

Avaliar se objetivos induzem output em vez de outcome. Palavras-alerta: "robustez", "eficiência", "excelência". Reescrever cada objetivo como outcome: mudança mensurável no mundo real, centrada no usuário final.

### Etapa 4: Construção da OST com árvore de métricas

A etapa central. Diferente da OST canônica (Teresa Torres), inclui **métricas intermediárias** entre outcome e oportunidades:

```
Outcome → Métricas nível 1 → Sub-métricas (nível 2, 3...) → Oportunidades → Soluções
```

**4a. Outcome:** único, mensurável, centrado no usuário final, ambicioso mas alcançável.

**4b. Árvore de métricas:** decompor o outcome perguntando "o que precisa acontecer para esta métrica melhorar?" Parar quando a próxima camada seria oportunidade (problema), não métrica (número).

**4c. Posicionar oportunidades:** cada oportunidade do discovery sob a sub-métrica que influencia mais diretamente. Teste: "se resolvêssemos isso, qual sub-métrica mudaria?" Se resposta for "nenhuma diretamente", é oportunidade transversal.

**4d. Linkar soluções:** mapear iniciativas em andamento às oportunidades. Teste: "essa iniciativa ataca qual oportunidade?" Se resposta for "nenhuma", questionar.

### Etapa 5: Uso contínuo

OST é artefato vivo, não documento pontual.

| Frequência | Ação | Pergunta |
|---|---|---|
| Semanal | Olhar sub-métricas ativas | "Números estão movendo?" |
| Quinzenal | Revisitar oportunidades | "Continuam sendo as certas?" |
| Mensal | Retrospectiva da árvore | "Outcome ainda faz sentido?" |
| Por ciclo | Reconstrução/ajuste | "O que aprendemos?" |

**Regra de ouro:** oportunidade com solução em andamento há mais de um ciclo e sub-métrica parada → questione a oportunidade, não adicione mais solução.

## Diagramas — boas práticas

### O que funciona

1. **Visão geral primeiro** — outcome → métricas nível 1 → contagem por ramo. `flowchart LR`, compacto.
2. **Diagramas por ramo** — um por ramo da árvore. Métricas → sub-métricas → oportunidades → soluções. Cores por status: ✅ verde, 🟡 amarelo, ⬜ cinza.
3. **HTML standalone com zoom/pan** — visão completa em tela cheia. Mermaid CDN + CSS transform (zoom no scroll, pan no drag). Controles +/- e reset. Template em `references/ost-html-template.html`.

### O que evitar

- Diagrama único com 40+ nós — fica comprimido e ilegível
- Usar "tema" para agrupar — OST não tem temas. Agrupar com **macro-oportunidades** (espaço do problema) ou com a própria árvore de métricas
- Oportunidades soltas sem conexão com sub-métrica — classificar como transversal

## Terminologia

| Termo | Definição |
|---|---|
| **Outcome** | Mudança mensurável no mundo real, centrada no usuário final |
| **Métrica** | Número que mede progresso em direção ao outcome |
| **Sub-métrica** | Decomposição de uma métrica em componentes mensuráveis |
| **Oportunidade** | Problema/barreira no espaço do problema (não é solução) |
| **Solução** | Iniciativa, feature ou ação que ataca uma oportunidade |
| **Oportunidade transversal** | Afeta múltiplos ramos; não se encaixa em uma única sub-métrica |
| **Lead indicator** | Métrica que sinaliza progresso antes do outcome final |
| **Enabler** | Libera capacidade (ex: tempo da OG) mas não é driver direto |

## Contexto estratégico

Ancorar toda OST no objetivo da empresa, mostrando a cadeia causal:

```
Objetivo empresa → Componentes → Alavancas → Pilares → OST
```

Isso responde "por que estamos fazendo isso?" e conecta o tático ao estratégico.

## Referências

- `references/ost-html-template.html` — Template HTML com zoom/pan para diagrama completo
- Teresa Torres — *Continuous Discovery Habits* (framework OST canônico)
