---
name: ost-methodology
description: Build OSTs with metric cascades and driver trees.
---

# OST Methodology — Opportunity-Solution Trees com métricas em cascata

## Quando usar

- Transformar um roadmap baseado em features em uma árvore de oportunidades
- Conectar OKRs/objetivos de negócio a oportunidades táticas do time
- Preparar uma sessão de planejamento com OST
- O usuário mencionar "OST", "opportunity-solution tree", "árvore de oportunidades", "driver tree", "métricas em cascata", ou "Teresa Torres"

## Método em 5 etapas

### 1. Coleta de contexto
Reunir tudo que a organização já sabe: OKRs atuais, documentos de planejamento, discovery com usuários, entrevistas, dados de baseline. **Não analisar ainda — só coletar.**

### 2. Análise da evolução do entendimento
Comparar o planejamento inicial com o que foi descoberto depois. Perguntas: as premissas ainda valem? O que mudou? Quais métricas são sujas?

### 3. Análise crítica dos OKRs
Avaliar se os objetivos medem output (% da feature pronta) ou outcome (melhora no problema real). Sinal de alerta: palavras como "robustez", "eficiência", "excelência". Reescrever como outcome centrado no usuário final.

### 4. Construção da OST com árvore de métricas
Nesta ordem:
- **4a. Outcome** — um, mensurável, centrado no usuário
- **4b. Driver tree** — decompor o outcome em sub-métricas perguntando "o que precisa acontecer para esta métrica melhorar?" até chegar no nível onde oportunidades aparecem
- **4c. Oportunidades** — posicionar cada dor/barreira sob a sub-métrica que influencia mais diretamente
- **4d. Soluções** — linkar iniciativas existentes às oportunidades, com status (pronto/andamento/não iniciado)

### 5. Uso contínuo
A OST é artefato vivo. Cadência: semanal (olhar sub-métricas), quinzenal (revisitar oportunidades), mensal (retrospectiva da árvore).

## Princípios

- **Outcome sobre output.** O progresso é medido pela sub-métrica se movendo, não pelo % da feature concluída.
- **Problema antes de solução.** Oportunidades são dores/barreiras no espaço do problema. Soluções vêm depois.
- **Árvore, não grafo.** Cada nó deve ter um pai só no diagrama. Oportunidades que afetam múltiplas métricas ficam no ramo de impacto primário; cross-links são documentados no texto, não no diagrama.
- **Métricas sujas primeiro.** Se o baseline não é confiável, a primeira solução é instrumentação, não feature.
- **"Robustez" é armadilha.** Objetivos formulados como "robustez no processo X" medem output. Reescreva como outcome: "crianças com PEI aderente em X dias", não "processo de escolha de objetivos robusto".

## Visualização com Mermaid

Para OSTs com 50+ nós, use HTML standalone com Mermaid + zoom/pan. Template completo em `references/mermaid-zoom-tree.html`. Regras:

- `flowchart TD` + subgrafos por ramo de métrica
- Fundo claro (#f5f5f8), arestas 2.5px cinza (#666)
- Labels em linha única, ≤35 caracteres — Mermaid não lida bem com `<br/>`
- `htmlLabels: true` + script pós-render forçando `foreignObject` com `width: 300` e `overflow: visible`
- Zoom inicial ~50%, mouse wheel + click-drag para navegar

## Pitfalls

- **Labels com `<br/>` cortam texto.** Use linha única. Contexto extra vai no documento, não no nó.
- **Arestas cruzando subgrafos.** Cada nó em um subgrafo só. Impactos secundários documentados no texto.
- **Cache do browser.** Se o diagrama não atualizar, renomeie o arquivo ou use `Cmd+Shift+R`.
- **Sem métricas intermediárias, oportunidades ficam soltas.** A pergunta guia: "o que precisa acontecer para esta métrica melhorar?"

## Exemplo de referência

OST de Capacidade Clínica (GenialCare, H2-2026) em `references/example-capacidade-clinica.md`.
