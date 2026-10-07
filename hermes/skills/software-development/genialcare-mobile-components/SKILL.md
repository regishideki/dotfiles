---
name: genialcare-mobile-components
description: Use when editing React Native components in the mobile repo.
---

# GenialCare Mobile — React Native Component Conventions

Stack do repo `mobile`: React Native + **native-base** (Box, Flex, HStack, VStack, Text) +
**react-native-vector-icons** (Feather) + **react-native-gesture-handler** (ScrollView).
Não confundir com `clinical-panel` (web/Antd) — aquele é outro stack e outro skill
(`create-react-component`).

## Styling — pitfalls que quebram ou sujam o lint

1. **`TouchableOpacity` (react-native) NÃO aceita a prop `flex`.** Escrever
   `<TouchableOpacity flex={1}>` dá erro de tipo TS (`Property 'flex' does not exist`).
   Passe via `style`: `<TouchableOpacity style={styles.tab}>` com `StyleSheet.create`.
2. **`Box`/`Flex` (native-base) aceitam `flex` como prop** normalmente (`<Box flex={1}>`).
   A diferença é entre componentes RN crus vs componentes native-base.
3. **Estilo inline (`style={{...}}`) dispara a warning `react-native/no-inline-styles`.**
   Sempre use `StyleSheet.create` no nível de módulo e referencie por nome. Exemplo:

   ```ts
   import {StyleSheet} from 'react-native';

   const styles = StyleSheet.create({
     tab: {flex: 1},
   });
   ```

## Tab bar com largura igual e sem sobra no fim

Quando há N abas e o espaçamento fixo (`space="24px"`/`space="12px"`) deixa texto cortado
ou sobra espaço no fim, use distribuição uniforme:

```tsx
<HStack borderBottomWidth="1px" borderBottomColor="gray.60">
  {TABS.map(tab => {
    const isActive = tab.key === activeTab;
    return (
      <TouchableOpacity
        key={`tab-${tab.key}`}
        testID={`pei-tab-${tab.key}`}
        style={styles.tab}          // flex: 1 — NÃO `flex={1}` na prop
        onPress={() => setActiveTab(tab.key)}>
        <Box
          pb="8px"
          alignItems="center"       // centraliza o label na célula
          borderBottomWidth="2px"
          borderBottomColor={isActive ? 'primary.500' : 'transparent'}>
          <Text
            fontSize="16px"
            fontWeight={isActive ? 700 : 400}
            color={isActive ? 'primary.500' : 'gray.600'}>
            {tab.label}
          </Text>
        </Box>
      </TouchableOpacity>
    );
  })}
</HStack>
```

Cada aba ocupa 1/N da largura; `alignItems="center"` centraliza o label. Escala para
mais abas sem recalcular espaçamento. Se o label ainda cortar, encurte o texto do label
antes de mexer no layout (ex: "Em manutenção" → "Manutenção").

## Badge / tag de status

Componente reutilizável em `src/components/Badge` (`import {Badge} from 'src/components/Badge'`).
Props `color` (texto) e `bg` (fundo); ex. `color="warning.600" bg="warning.100"` para estados
de aviso/manutenção. `DisciplineBadge` (`src/components/DisciplineBadge`) estende `Badge`
com cores por disciplina (`aba`/`fono`/`to`/`symbolic_play`).

Cores semânticas em `src/styles/theme/colors.ts` — `warning.100` (#FDF5DF) / `warning.600`
(#AA8A35) são o padrão para tags de manutenção/atenção.

## Convenções do projeto (observadas no PeiObjectiveList)

- Tabs declaradas como array de config fora do componente:
  `const TABS: {key: TabKey; label: string}[] = [...]` com `type TabKey` union.
- Mensagens de estado vazio num `Record<TabKey, string>` (`EMPTY_TAB_MESSAGE`).
- Filtrar itens da tab por `statusInfo?.category === activeTab`; usar `React.useMemo`
  para o filtro derivado.
- Fallback temporário de UI (ex: popular uma tab nova com dados aleatórios só para
  pré-visualizar) deve ser marcado com comentário `// TEMPORARY` e removido antes de commitar.

## Testing

- Runner: `yarn jest <path>` (não `npm`). Testes por testID (`findByTestId`,
  `findAllByTestId`, `fireEvent.press`).
- Mocks de query GraphQL: `MockedProvider` do `@apollo/client/testing` +
  `buildApolloClientMock`/`buildGraphQlHandler` de `src/utils/tests/support/graphql`.
- Dados de teste inline (statusInfo, programs) com `__typename` nos programas.

## Node version

`yarn` neste repo exige Node `~20.19.4`. Se `yarn <cmd>` falhar com
`The engine "node" is incompatible`, rode:

```bash
source ~/.nvm/nvm.sh && nvm use 20.19.4 && yarn <cmd>
```
