# clinical-panel Testing Patterns

Padrões de teste específicos do clinical-panel que vão além do básico.

## Testando componentes que dependem do authenticated user

O `test-utils` provê um `authenticatedUserMock` exportável e a opção `customAuthenticatedUser` no `render`. Use quando o componente consome `useAuthenticatedUser()` — roles, tenant, flags de especialidade.

```tsx
import { render, authenticatedUserMock } from 'test-utils';

// Cenário padrão (Genial tenant) — não precisa de customAuthenticatedUser,
// pois o mock padrão já tem isPartOfGenialTenant: true

// Cenário non-Genial (ex: careplus_mindplace)
render(<MyComponent />, {
  customAuthenticatedUser: { ...authenticatedUserMock, isPartOfGenialTenant: false, isPartOfMindplaceTenant: true },
});

// Cenário com role diferente
render(<MyComponent />, {
  customAuthenticatedUser: { ...authenticatedUserMock, isClinicalCaseOwner: true },
});
```

O mock padrão (`authenticatedUserMock`) tem: `isTherapist: true`, `isPartOfGenialTenant: true`, `isPartOfMindplaceTenant: false`, `tenantsCount: 2`, `currentTenant: { name: 'Genial Care', ... }`. Espalhe com `...authenticatedUserMock` e sobrescreva apenas o campo que muda entre cenários.

### Quando usar

- Componentes que selecionam recursos por tenant (ex: dashboards do Metabase com IDs diferentes por tenant)
- Componentes com comportamento condicional por role (terapeuta vs OG vs referência)
- Componentes que usam `isPartOfGenialTenant`, `isPartOfMindplaceTenant`, `isTherapist`, `isClinicalCaseOwner`, etc.

### Padrão isPartOfGenialTenant vs currentTenant.name

O projeto já tem `isPartOfGenialTenant` (boolean) no `AuthenticatedUserContext`, derivado de `tenantId === VITE_AUTH0_GENIAL_ORG_ID`. Prefira este padrão idiomático em vez de comparar `currentTenant.name` com strings hardcoded — é mais robusto (disponível imediatamente via Auth0, não depende da query do Core carregar) e é o padrão estabelecido no codebase.

### Cascade de testes ao adicionar campo em AuthenticatedUserContextType

Quando um novo campo boolean é adicionado a `AuthenticatedUserContextType` (ex: `isPartOfMindplaceTenant`), TODO arquivo de teste que constrói o mock **manualmente** (não via spread de `authenticatedUserMock`) vai quebrar o `tsc --noEmit` com `TS2741: Property 'X' is missing in type`. 

Arquivos típicos que mantêm mocks manuais (verificar com `grep -rl 'isPartOfGenialTenant' src/ --include='*.spec.tsx'` e filtrar os que NÃO têm o novo campo):
- `src/pages/Home/__tests__/Home.spec.tsx` (2 ocorrências — default mock + inline override)
- `src/pages/Home/components/HomeTabs/AlertsTab/__tests__/AlertsTab.spec.tsx`
- `src/pages/Home/components/HomeTabs/ClinicalCasesTab/__tests__/ClinicalCasesTab.spec.tsx`
- `src/components/SideMenu/__tests__/SideMenu.spec.tsx`
- `src/hooks/__tests__/useAuthorizationBasedURL.spec.tsx`
- `src/hooks/__tests__/useAuthorizedComponent.spec.tsx`

**Procedimento**: após adicionar o campo ao tipo e ao `AuthenticatedUserContainer`, rode `yarn tsc --noEmit` e grep por `isPartOf<X>` no output. Cada erro indica um mock manual que precisa do novo campo (valor `false` é o default seguro). Corrija todos antes de commitar.

Comando para encontrar arquivos afetados de uma vez:
```bash
for f in $(grep -rl 'isPartOfGenialTenant' src/ --include='*.tsx' --include='*.ts'); do
  if ! grep -q 'isPartOfMindplaceTenant' "$f"; then
    echo "$f"
  fi
done
```

## Validação por repo

- **clinical-panel**: `yarn vitest run <test-file>`, `yarn lint:fix`, `yarn types` (tsc --noEmit)
- **core (Rails)**: `bundle exec rspec <spec_file>`, `bundle exec rubocop`
- Sempre rode os testes do arquivo alterado, não a suite completa (a suite é grande)
