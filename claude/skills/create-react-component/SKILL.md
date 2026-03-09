---
name: create-react-component
description: >
  Guia de boas práticas para criar componentes React no projeto clinical-panel (GenialCare).
  Use este skill sempre que o usuário pedir para criar um novo componente de página, componente filho,
  provider de contexto, ou teste — especialmente em áreas como PEI, Sessions, Assessments, ou qualquer
  feature nova. Também use quando o usuário perguntar "como criar", "como estruturar", "qual padrão",
  ou pedir para refatorar um componente existente seguindo os padrões do projeto.
---

# Boas Práticas de Componentes — clinical-panel

## Estrutura de pastas

```
src/pages/Feature/SubFeature/
├── index.tsx                        # Componente de página principal (entry point)
├── styles.module.css
├── components/
│   └── ComponentName/
│       ├── index.tsx
│       └── styles.module.css
├── contexts/
│   └── FeatureProvider.tsx          # Context + hook exportados do mesmo arquivo
├── hooks/
│   └── useFeatureHook.ts
└── __tests__/
    └── ComponentName.spec.tsx
```

Regra geral: se um arquivo é o único dentro de uma pasta de componente, pode ser um arquivo simples.
Se a pasta tem múltiplos arquivos (estilos, sub-componentes), use `components/Name/index.tsx`.

---

## Componentes de Página

Toda página segue este esqueleto — na ordem exata:

```tsx
export const MyPage = () => {
  // 1. Extrair params
  const { sessionId } = useParams();

  // 2. Hooks de infraestrutura (toast, navigate, form, i18n)
  const toast = useToast();
  const navigate = useNavigate();
  const { t } = useTranslation('namespace');
  const methods = useForm({ defaultValues: {}, mode: 'onSubmit' });
  const isAuthorized = useAuthorizedComponent();

  // 3. Feature flags
  const isFeatureEnabled = useFeatureFlag(FEATURE_FLAG_NAME);

  // 4. Guard de param obrigatório — TODOS os hooks anteriores devem vir antes deste ponto
  if (!sessionId) throw new Error('Session ID is required');

  // 5. Query Apollo — useQuery do @apollo/client (useAuthorizedQuery está depreciado)
  const { data, loading, refetch } = useQuery(MY_QUERY, {
    fetchPolicy: 'no-cache',          // 'cache-and-network' para listagens; 'no-cache' para formulários
    variables: { sessionId },
    onError: (err) => {
      logError(err, { component: 'MyPage', query: 'MY_QUERY' });
      toast.error(t('errors.loadSession', { message: err.message }));
    },
  });

  // 6. Redirect por feature flag ou permissão
  useEffect(() => {
    if (!isFeatureEnabled || !isAuthorized('permission_key')) {
      navigate(buildURL.toSomePage(sessionId));
    }
  }, [isFeatureEnabled, sessionId, navigate, isAuthorized]);

  // 7. Early returns de estado
  if (loading) return <Loading />;

  if (!data) {
    return (
      <RetryError
        onRetry={(e) => {
          e.preventDefault();
          refetch();
        }}
      />
    );
  }

  // 8. Extração de dados do response
  const session = data.session;

  // 9. JSX com Provider + Layout envolvendo o conteúdo
  return (
    <FeatureProvider sessionId={sessionId}>
      <Layout>
        <Container>
          <FormProvider {...methods}>
            <form onSubmit={methods.handleSubmit(onSubmit)}>
              {/* conteúdo */}
            </form>
          </FormProvider>
        </Container>
      </Layout>
    </FeatureProvider>
  );
};
```

**Regras importantes:**
- `fetchPolicy: 'no-cache'` para páginas de formulário/avaliação; `'cache-and-network'` para listagens
- Use `useQuery` do `@apollo/client` — `useAuthorizedQuery` está depreciado
- Queries tipadas com `TypedDocumentNode` no arquivo da query — sem generics no call site
- `onError` sempre chama `logError()` + `toast.error()` — nunca só um dos dois
- O guard `if (!param) throw` vem ANTES dos hooks de dados (query), mas DEPOIS de todos os hooks de infraestrutura. Isso é um desvio das regras do React (hooks não podem ser chamados após um possível throw), mas é aceitável neste projeto pois params de rota são estáveis entre renders — o número de hooks nunca varia. Se for possível reestruturar o componente para seguir as regras do React sem sacrificar a clareza, prefira fazer isso
- O redirect por feature flag usa `useEffect`, nunca retorno condicional antes dos hooks

---

## Providers de Contexto

O provider e o hook customizado vivem no mesmo arquivo em `contexts/`.

```tsx
// contexts/FeatureProvider.tsx

interface FeatureContextData {
  activeTab: string;
  items: Item[];
  onChangeTab: (tab: string) => void;
}

// Funções puras de transformação fora do componente
const sortItems = (items: Item[]) => [...items].sort((a, b) => /* ... */);

// Constantes de configuração (lookup tables, mapas) também fora do componente
const ITEM_STATUS_LABELS: Record<ItemStatus, string> = {
  active: 'Ativo',
  inactive: 'Inativo',
};

const FeatureContext = createContext<FeatureContextData>({} as FeatureContextData);

export const FeatureProvider = ({ children, data }: FeatureProviderProps) => {
  const [activeTab, setActiveTab] = useState('');
  const isFeatureEnabled = useFeatureFlag(FEATURE_FLAG);

  // useMemo para estado derivado e computações pesadas
  const items = useMemo(() => sortItems(data.items), [data.items]);

  // useEffect para side effects (inicialização, resets entre tabs)
  useEffect(() => {
    if (items.length > 0) setActiveTab(items[0].id);
  }, [items]);

  useEffect(() => {
    setActiveTab('default');
  }, [activeTab]); // reset ao trocar de tab principal

  // Handlers simples definidos inline (sem useMemo/useCallback desnecessário)
  const onChangeTab = (tab: string) => setActiveTab(tab);

  return (
    <FeatureContext.Provider value={{ activeTab, items, onChangeTab }}>
      {children}
    </FeatureContext.Provider>
  );
};

// Hook sempre no mesmo arquivo que o provider
export const useFeature = () => {
  const data = useContext(FeatureContext);
  if (!data) throw new Error('useFeature must be used within a FeatureProvider');
  return data;
};
```

**Regras importantes:**
- Funções puras (sort, transform, format) e constantes (lookup tables) ficam fora do componente — nunca inline no JSX
- Estado derivado usa `useMemo`; side effects (resets entre tabs) usam `useEffect`
- O hook customizado sempre valida com `throw` se está dentro do provider
- Feature flags podem ser consumidas dentro do provider para condicionar os dados expostos

---

## Componentes Filhos

```tsx
// Lookup tables e constantes fora do componente
const ICON_BY_MODULE: Record<string, ComponentType> = {
  module_1: Module1Icon,
  module_2: Module2Icon,
};

// Funções puras de formatação fora do componente
const formatIdentifier = (code: number, description: string) => `${code}) ${description}`;

interface ComponentProps {
  items: Item[];
  clinicalCaseId: string;
  onAction: () => void;
}

export const MyComponent = ({ items, clinicalCaseId, onAction }: ComponentProps) => {
  const { activeTab } = useFeature();           // consome o contexto pai
  const isPeiActionsEnabled = useFeatureFlag(PEI_TRACK_ACTIONS);
  const tokens = theme.useToken();              // tokens de design quando necessário

  // useMemo para computações derivadas de props
  const dataSource = useMemo(
    () => items.map((item) => ({
      key: item.id,
      label: formatIdentifier(item.code, item.description),
    })),
    [items],
  );

  return (
    <div data-testid="my-component" className={styles.container}>
      {isPeiActionsEnabled && <ActionsPanel />}
      <AntdTable columns={columns} dataSource={dataSource} />
    </div>
  );
};
```

**Regras de estilo:**
- Antd: NUNCA desestruturar — use `Typography.Title`, `Typography.Text`, `Input.TextArea`
- Estilo via prop do componente quando disponível (`<Tag color="blue">`); senão CSS Modules
- Para classes condicionais, use o utilitário `cn()` de `utils/styling`: `cn(styles.card, active && styles.cardActive)`
- Nunca `style={{ ... }}` inline — isso inclui ícones e componentes Antd que não expõem prop de tamanho. Nesses casos, use CSS Modules: `className={styles.icon}` com `.icon { font-size: 24px }`. Código existente que usa `style={{}}` é tech debt
- Para valores de cor programáticos em runtime, use `theme.useToken()` — os tokens já retornam os valores do design system do projeto (não hardcode hex)

**Regras de `data-testid`:**
- Adicione nos elementos que os testes precisam encontrar/interagir
- Nomes descritivos: `data-testid="status"`, `data-testid="status-select"`, `data-testid="loading"`

---

## Queries GraphQL — `TypedDocumentNode`

Toda query deve ser tipada com `TypedDocumentNode` diretamente no arquivo da query, em `src/queries/`. Isso permite que o Apollo infira automaticamente os tipos de resultado e variáveis no `useQuery`, sem necessidade de generics no call site.

```ts
// src/queries/feature/getMyItems.ts
import { gql, TypedDocumentNode } from '@apollo/client';
import { MyItemStatus } from 'types';

type GetMyItemsQuery = {
  myItems: {
    id: string;
    status: MyItemStatus;
  }[];
};

type GetMyItemsQueryVariables = {
  clinicalCaseId: string;
};

export const GET_MY_ITEMS: TypedDocumentNode<GetMyItemsQuery, GetMyItemsQueryVariables> = gql`
  query getMyItems($clinicalCaseId: ID!) {
    myItems(clinicalCaseId: $clinicalCaseId) {
      id
      status
    }
  }
`;
```

```tsx
// No componente — sem generics, tipos inferidos automaticamente
const { data, loading, refetch } = useQuery(GET_MY_ITEMS, {
  variables: { clinicalCaseId },
});
// data é tipado como GetMyItemsQuery | undefined automaticamente
```

**Regras:**
- Os tipos da query ficam **junto à definição da query**, não no componente
- Use `useQuery` do `@apollo/client` diretamente — `useAuthorizedQuery` está depreciado
- Solicite apenas os campos que o componente realmente usa — não busque campos "por precaução"
- O tipo completo da entidade (ex: `SpeechTherapyAssessmentsRegistry`) fica em `src/types/` e é usado em páginas de detalhe; a query de listagem define seu próprio tipo enxuto inline

---

## Mutations

```tsx
const { mutate, loading: isMutating } = useAuthorizedMutation(MY_MUTATION, {
  onError: (err) => {
    logError(err, { component: 'MyComponent', mutation: 'MY_MUTATION' });
    toast.error('Mensagem de erro amigável');
  },
  onCompleted: refetchData,  // ou callback de side effect (fechar modal, navegar, etc.)
});

const handleAction = (id: string) => {
  mutate({
    variables: { id, status: newStatus },
  });
};
```

- Use `useAuthorizedMutation` (não `useMutation` diretamente)
- `onError` sempre tem `logError` + `toast.error`
- `onCompleted` para refetch ou navegação pós-sucesso

---

## Lazy loading de sub-componentes pesados

Para componentes que aparecem condicionalmente (modais, dialogs), use `lazy()` com `Suspense`:

```tsx
// No topo do arquivo (nível de módulo, não dentro do componente)
const SelectedItemsDialogBox = lazy(() =>
  import('./SelectedItemsDialogBox').then((m) => ({ default: m.SelectedItemsDialogBox })),
);

// No JSX — renderize condicionalmente dentro de Suspense
{selectedItemsIds.length > 0 && (
  <Suspense>
    <SelectedItemsDialogBox
      selectedItemsIds={selectedItemsIds}
      onSuccess={refetchData}
    />
  </Suspense>
)}
```

Para modais abertos via `useModal`, veja o padrão no `CLAUDE.md` do projeto.

---

## i18n — Textos e Labels

O projeto usa `react-i18next` com namespaces por domínio em `src/i18n/locales/<namespace>/pt-br.json`.

**Regras:**
- Todo texto visível ao usuário (labels de status, nomes de avaliações, mensagens) deve ir para o arquivo i18n do namespace correspondente — nunca strings hardcoded no JSX
- Use `useTranslation('namespace')` nos hooks de infraestrutura do componente (posição 2 no esqueleto de página)
- Chaves de i18n para status de enum usam o valor do enum como sufixo: `t('status.registry.started')`, `t('status.assessment.not_started')`
- Nomes curtos de entidades (para uso em labels, tags) ficam em chave própria: `assessmentName` (nome completo), `shortName` (abreviado para UI)
- **Cores** (valores semânticos do Antd como `'processing'`, `'success'`, `'default'`) NÃO vão para i18n — permanecem como lookup tables locais (`Record<Status, string>`)

```tsx
// ✅ Correto: texto via t(), cores como lookup local
const STATUS_COLORS: Record<MyStatus, string> = {
  [MyStatus.ACTIVE]: 'processing',
  [MyStatus.DONE]: 'success',
};

const { t } = useTranslation('myNamespace');

<Tag color={STATUS_COLORS[item.status]}>
  {t(`status.${item.status}`)}
</Tag>

// ❌ Errado: strings hardcoded no JSX
<Tag color="processing">Iniciada</Tag>
```

---

## Datas — `utils/date`

O projeto tem um módulo `src/utils/date.ts` que configura o dayjs com locale `pt-br`, timezone `America/Sao_Paulo` e todos os plugins necessários.

**Regras:**
- **Nunca** importe `dayjs` diretamente do pacote (`import dayjs from 'dayjs'`) — importe de `utils/date`
- Use `PT_BR_DATE_FORMAT` (`'DD/MM/YYYY'`) da mesma importação em vez de hardcodar o formato

```tsx
// ✅ Correto
import { dayjs, PT_BR_DATE_FORMAT } from 'utils/date';

dayjs(record.createdAt).format(PT_BR_DATE_FORMAT)  // → '06/03/2026'

// ❌ Errado
import dayjs from 'dayjs';
dayjs(record.createdAt).format('DD/MM/YYYY')
```

---

## Design System — `@genialcare/atipico-antd`

O projeto usa um tema Antd customizado que é aplicado globalmente via `ConfigProvider` em `src/index.tsx`:

```tsx
import theme from '@genialcare/atipico-antd';

<ConfigProvider theme={{ cssVar: true, ...theme }}>
  <App />
</ConfigProvider>
```

Esse pacote sobrescreve os tokens semânticos do Antd com as cores do design system da GenialCare. Os valores principais são:

| Token semântico     | Cor resultante          | Uso                              |
|---------------------|-------------------------|----------------------------------|
| `colorPrimary`      | Roxo (`#6b69ad`)        | Ações principais, botões, links  |
| `colorSuccess`      | Ciano (`#7eacb0`)       | Estados de sucesso               |
| `colorError`        | Vermelho (`#ff4d4f`)    | Erros, estados críticos          |
| `colorInfo`         | Roxo (`#6b69ad`)        | Informações, notificações        |

**Regras:**
- Nunca use valores hex diretamente no código (`#6b69ad`, `#7eacb0`, etc.) — use as props semânticas do Antd
- Use as props dos componentes Antd para cores semânticas: `<Tag color="success">`, `<Button type="primary">`, `<Alert type="error">`
- Quando precisar de um valor de cor em runtime (ex: para passar para uma lib que não aceita classes CSS), use `theme.useToken()` do Antd — os tokens já refletem o design system:

```tsx
import { theme } from 'antd';

const { token } = theme.useToken();
// token.colorPrimary → '#6b69ad' (roxo do projeto)
// token.colorSuccess → '#7eacb0' (ciano do projeto)
// token.colorPrimaryHover → '#837dbf'
```

- **Não importe** `@genialcare/atipico-antd/tokens/light.js` diretamente nos componentes — esses valores são privados do pacote de configuração. Acesse-os sempre via `theme.useToken()`
- Para consultar tokens não listados acima (ex: bordas, espaçamentos, tipografia), leia o arquivo de tokens do design system: `/Users/regishattori/workspace/genial/atipico/packages/atipico-antd/tokens/light.js`

---

## Testes

### Estrutura do arquivo

```tsx
import { render, screen, waitFor, fireEvent, enableFlags, renderHook, act } from 'test-utils';
import { MyComponent } from '..';
import { myFactory } from 'factories/feature/myFactory';
import { MY_QUERY } from 'queries';
import { MY_FLAG } from 'constants/flags';

// Mocks de navegação/roteamento — sempre com spread do actual
const mockNavigate = vi.fn();
vi.mock('react-router-dom', async () => ({
  ...(await vi.importActual('react-router-dom')),
  useParams: () => ({ sessionId: 'session-123' }),
  useNavigate: () => mockNavigate,
}));

// Dados de teste via factories (nunca objetos inline)
const session = myFactory.build({ id: 'session-123' });

// Helper para mock de query Apollo
const mockQuery = (data = session) => ({
  request: { query: MY_QUERY, variables: { sessionId: data.id } },
  result: { data: { session: data } },
});

describe('<MyComponent />', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  // Cenário padrão (flag desativada — sem enableFlags)
  describe('when feature flag is disabled', () => {
    it('renders the basic version', async () => {
      render(<MyComponent />, { mocks: [mockQuery()] });

      // Sempre aguardar o loading desaparecer antes de fazer asserções de conteúdo
      await waitFor(() => {
        expect(screen.queryByTestId('loading')).not.toBeInTheDocument();
      });

      expect(screen.getByText(/expected text/i)).toBeInTheDocument();
      expect(screen.queryByText(/feature-only text/i)).not.toBeInTheDocument();
    });
  });

  // Cenário com flag ativada
  describe('when feature flag is enabled', () => {
    beforeEach(() => {
      enableFlags([MY_FLAG]);
    });

    it('renders the enhanced version', async () => {
      render(<MyComponent />, { mocks: [mockQuery()] });
      expect(await screen.findByTestId('enhanced-element')).toBeInTheDocument();
    });
  });
});
```

### Testar provider/hook isoladamente

```tsx
const wrapper = ({ children }: { children: React.ReactNode }) => (
  <FeatureProvider modules={[module]}>{children}</FeatureProvider>
);
const { result } = renderHook(() => useFeature(), { wrapper });

act(() => {
  result.current.onChangeTab('tab-2');
});

expect(result.current.activeTab).toBe('tab-2');
```

### Mockar hook de contexto ao testar componente filho

```tsx
vi.mock('../contexts/FeatureProvider', () => ({
  useFeature: vi.fn(() => ({
    activeTab: 'TO_DO',
    subTabsAllowedToSelectItems: ['TO_DO', 'PENDING'],
  })),
}));

// Para mudar o retorno em um teste específico:
(useFeature as Mock).mockReturnValue({
  activeTab: 'COMPLETED',
  subTabsAllowedToSelectItems: ['COMPLETED'],
});
```

### Testar mutation com callback

```tsx
const mockMutate = vi.fn();
let capturedOnCompleted: (() => void) | undefined;

vi.mock('hooks/useAuthorizedMutation', () => ({
  useAuthorizedMutation: (_mutation: unknown, options: { onCompleted?: () => void }) => {
    capturedOnCompleted = options?.onCompleted;
    return { mutate: mockMutate, loading: false };
  },
}));

// Depois da interação:
expect(mockMutate).toHaveBeenCalledWith({
  variables: { clinicalCaseId: 'case-1', item: { id: 'item-1', status: 'completed_by_genial' } },
});

// Para testar o onCompleted:
capturedOnCompleted?.();
await waitFor(() => expect(refetchMock).toHaveBeenCalled());
```

### Padrões de asserção

```tsx
// Aguardar loading — sempre antes de asserções de conteúdo
await waitFor(() => {
  expect(screen.queryByTestId('loading')).not.toBeInTheDocument();
});

// Asserção de presença/ausência por texto
expect(screen.getByText(/jornada do pei/i)).toBeInTheDocument();
expect(screen.queryByText(/feature-only text/i)).not.toBeInTheDocument();

// Asserções de estilo via classe Antd (para Tags e badges)
expect(screen.getByTestId('status')).toHaveClass('ant-tag-success');
expect(screen.getByTestId('status')).toHaveTextContent('Concluído pela Genial');

// findBy* para elementos que aparecem assincronamente
expect(await screen.findByTestId('module-card')).toBeInTheDocument();
expect(await screen.findAllByTestId('module-card')).toHaveLength(3);

// within() para escopo dentro de um elemento pai
const column = await screen.findByRole('columnheader', { name: /status/i });
expect(within(column).queryByRole('button')).toBeInTheDocument();

// it.each para testar múltiplos itens com o mesmo comportamento
it.each([toDoItem, blockedItem])('enables button for item without objective', (item) => {
  render(<Table items={[item]} ... />);
  expect(screen.getByRole('button', { name: /iniciar/i })).toBeEnabled();
});
```

### Regras de feature flags em testes

- Default = flag **desativada**: nunca chame `enableFlags` no describe principal
- `enableFlags([FLAG])` no `beforeEach` do describe da flag ativada
- `enableFlags` já está mockado globalmente em `test-utils` — nunca mocke `useFeatureFlag` diretamente

### Factories

```tsx
// Usar factories, nunca objetos inline
const item = peiModuleItemFactory.build({ status: PeiModuleItemStatus.TO_DO });
const items = peiModuleItemFactory.buildList(3, { status: PeiModuleItemStatus.PENDING });

// Factories encadeadas quando necessário
const clinicalCase = clinicalCaseFactory
  .withPeiTrack()
  .withVinelandReports()
  .build({ id: 'case-123' });
```

---

## Checklist ao criar um componente novo

- [ ] Estrutura de pastas segue o padrão (`index.tsx`, `styles.module.css`, `__tests__/`)
- [ ] Params obrigatórios têm guard `if (!id) throw new Error(...)` — após todos os hooks de infraestrutura, antes dos hooks de dados
- [ ] Query usa `onError` com `logError` + `toast.error`
- [ ] `<Loading />` e `<RetryError />` como early returns antes do JSX principal
- [ ] Antd não desestruturado (`Typography.Title`, não `const { Title } = Typography`)
- [ ] Estilos via CSS Modules ou prop do componente Antd — sem `style={{}}`
- [ ] Classes condicionais via `cn()` de `utils/styling`
- [ ] `data-testid` nos elementos importantes para os testes
- [ ] Contexto: provider + hook no mesmo arquivo em `contexts/`
- [ ] Funções puras de transformação e lookup tables como constantes fora do componente
- [ ] `useMemo` para computações derivadas de props/estado
- [ ] Textos visíveis via `useTranslation` — nenhuma string hardcoded no JSX
- [ ] Datas formatadas com `dayjs` e `PT_BR_DATE_FORMAT` de `utils/date` (nunca import direto do pacote)
- [ ] Cores de status como lookup table local (`Record<Status, string>`) — não vão para i18n
- [ ] Queries tipadas com `TypedDocumentNode` no arquivo da query; `useQuery` sem generics no componente
- [ ] `useQuery` do `@apollo/client` (não `useAuthorizedQuery` — depreciado)
- [ ] Query solicita apenas os campos usados pelo componente — sem campos "por precaução"
- [ ] Mutations: `useAuthorizedMutation` com `onError` e `onCompleted`
- [ ] Testes usam factories, não objetos inline
- [ ] Flag desativada = comportamento padrão (sem `enableFlags` no describe principal)
- [ ] `vi.clearAllMocks()` no `beforeEach` quando há mocks
- [ ] Mock de `react-router-dom` com spread de `vi.importActual`
