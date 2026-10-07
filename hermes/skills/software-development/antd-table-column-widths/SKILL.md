---
name: antd-table-column-widths
description: Use for Antd Table column widths and Tag status colors.
---

# Antd Table — larguras de coluna e tags de status (clinical-panel)

## Larguras de coluna com colunas condicionais

Quando uma tabela tem colunas que aparecem/somem conforme um boolean (ex: `showObjectives`),
não use `width: showObjectives ? '40%' : '60%'` inline e não use `flex`. Em vez disso, extraia
um objeto de configuração `COLUMN_WIDTHS` com dois estados, cada um com percentuais
**explícitos somando exatamente 100%**:

```tsx
const COLUMN_WIDTHS = {
  base: { items: '60%', response: '40%' },
  withObjectives: { items: '40%', response: '20%', objectives: '40%' },
} as const;

// no componente:
const widths = showObjectives ? COLUMN_WIDTHS.withObjectives : COLUMN_WIDTHS.base;

const columns = useMemo(() => [
  { title: t('...items'), dataIndex: 'label', width: widths.items },
  { title: t('...response'), width: widths.response },
  ...(showObjectives
    ? [{ title: t('relatedObjectives.toggle'), width: COLUMN_WIDTHS.withObjectives.objectives }]
    : []),
], [t, showObjectives, objectivesByItem]);
```

### Regras
- **Os DOIS estados somam exatamente 100%** — verifique cada um. Bug comum: o estado `base`
  esquece de redistribuir o espaço da coluna condicional que some (fica <100%, ex: somando 85%).
- Colunas numéricas/curtas também entram no config com percentual explícito — não deixar em `auto`.
- Use `tableLayout="fixed"` no `<Table>` (com `scroll.x`/`scroll.y`) para os percentuais valerem.
- `flex` em coluna dá MENOS controle por coluna (o usuário rejeitou essa abordagem — prefere
  percentuais explícitos que ele consiga enxergar e ajustar individualmente).

### Aplicar em TODAS as instâncias
Quando o usuário pede para melhorar a legibilidade de um padrão repetido (larguras, cores,
layout), **refatore todas as instâncias do padrão de uma vez**, não só a primeira encontrada.
O usuário espera consistência entre as sub-avaliações/tabelas — reclamou explicitamente quando
foi feita apenas uma ("era para ter feito todas desde o começo").

## Tags de status — cores consistentes com o PeiTrack

As cores de status dos objetivos seguem `TAGS_BY_OBJECTIVE_STATUS` do PeiTrack
(`src/pages/PEI/PEITrack/components/ObjectivesTable/StatusIndicator/Tag.tsx`). Mantenha a
consistência entre páginas — o usuário pede explicitamente isso.

| Status         | Cor Antd     |
|----------------|--------------|
| completed      | `success`    |
| validated      | `processing` |
| pending        | `red`        |
| rejected       | `orange`     |
| in_maintenance | `blue`       |
| to_do          | `warning`    |
| blocked        | `default`    |

Erros comuns de inconsistência: `pending`/`rejected` invertidos (pendente = `red`, rejeitado =
`orange`) e `validated` usando `cyan` em vez de `processing`.

## Tag com largura fixa

A Tag do Antd v5 é `inline-flex`. Para largura fixa + texto centralizado, use CSS (não prop):

```css
.objectiveRow :global(.ant-tag) {
  width: 110px;
  justify-content: center;
  margin-inline-end: 0;
}
```

## Verificação

- `yarn types` (tsc --noEmit) limpo.
- `yarn eslint <arquivos>` limpo (rode `--fix` se o prettier quebrar linha longa de config).
- Testes direcionados: há `.spec.tsx` por componente em `src/pages/Users/Session/__tests__/`
  (ex: `AtypicalProcessesScore.spec.tsx`, `CommunicationSkillsAssessment.spec.tsx`). Rode os
  specs dos componentes alterados, não a suíte inteira (a suíte full estoura timeout).
