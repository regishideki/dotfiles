# Mensagens de erro do core → painel: pipeline pt-BR e gaps conhecidos

Como mensagens de erro de negócio fluem do core (Rails) para o clinical-panel, o padrão
I18n pt-BR implantado em set/2026, e os gaps a verificar em qualquer story que toque
mensagens de erro. Fonte: investigação da user story
`20260930-amil-nova-regra-carga-horaria` (30/09/2026), código verificado no repo.

## O pipeline completo (camada por camada)

1. **Core — padrão I18n** (commits `4e612a0de5` + `c0067bc54c`, set/2026): use cases
   trocam strings literais por `I18n.t("<dominio>.errors.<chave>", <interpolações>,
   default: "<string em inglês>")`. O `default:` garante inglês quando o locale não é
   pt-BR (default_locale é `:en`) — nunca vira "translation missing".
   - Chaves em ymls de **domínio** em `config/locales/pt-BR/<dominio>.yml` sob
     `errors:` (decisão de review: NÃO num `use_case_errors.yml` centralizado).
   - Onde a mensagem também alimenta fingerprint/span do Datadog:
     `UseCase::ErrorsHelper#add_error(ctx, message:, user_message:)` separa o texto
     estável em inglês (Datadog) do texto do usuário (traduzível) — evita fragmentar o
     fingerprint por idioma.
   - Locale do request: `around_action :switch_locale` no `ApplicationController`,
     lê o header `Accept-Language` (ActiveAdmin força pt-BR).
2. **Painel**: `ApolloProviderWithAuth` SEMPRE envia `Accept-Language: pt-BR` ao BFF
   (`src/api/ApolloProviderWithAuth.tsx`, constante `ACCEPT_LANGUAGE` exportada —
   mesmo padrão do operational-panel).
3. **BFF**: `BaseDataSource#willSendRequest` repassa `customHeaders` ao core — mas o
   context (`src/index.js` ~linha 56) só popula `x-forwarded-for`, `x-request-id`,
   `Authorization`. **`Accept-Language` NÃO era repassado** (gap em 30/09/2026) —
   adicionar `'accept-language': context.req.headers['accept-language']` ao
   customHeaders ativa o pipeline para TODAS as chamadas do painel (benefício global,
   mudança de 1 linha + teste).
4. **Exibição no painel**: `notifyErrorMessages`/`build-error-message.ts` extrai
   `extensions.response.body.details[0].errors[0].message || body.message` e mostra
   toast. O caminho `businessErrors` nas extensions existe no util mas NENHUMA fonte
   no BFF gera `businessErrors` (legado/expectativa não realizada).
   - Erros REST viram GraphQLError pelo `@apollo/datasource-rest`
     (`errorFromResponse`): `extensions.response.body` carrega o body do core;
     404/403 viram NOT_FOUND/FORBIDDEN; 422 passa com body intacto.
   - **Formato padrão de erro do core**: `{details: [{name:, errors: [{code:,
     message:}]}]}` (`HttpErrorFormat`, `app/infra/http_error_format.rb`) — é esse
     shape que o painel sabe ler.

## Bugs/padrões a verificar em stories que tocam erro de API

- **Branch JSON de erro com copy-paste de variável de outro domínio**: ex.
  `ClinicalCaseWorkloadsController#create` renderizava
  `{errors: @skill_acquisition_note_form.errors.messages.to_json}` (variável nil de
  outro controller) → NoMethodError → o painel recebia 500 genérico em vez do 422 com
  a mensagem. A mensagem de limite "nunca chegou" ao usuário — ninguém percebeu porque
  o caminho de falha não tinha request spec. Ao tocar um endpoint, testar o caminho de
  FALHA (request spec com payload inválido), não só o de sucesso.
- **Use case monta `ctx[:errors]` na mão** (`{code:, message:}`) em vez de usar
  `add_error` do `ErrorsHelper` — padrão antigo que perde log/span e não ganha tradução
  automaticamente. Novas mensagens: usar `I18n.t` com `default:` desde o início.
- **Interpolação de arrays na mensagem**: juntar IDs com `.join(", ")` antes de
  interpolar (senão vira `["id1", "id2"]` cru — corrigido no review dos ymls de domínio).

## Checklist para uma story que cria/altera mensagem de erro

1. Usar `I18n.t("<dominio>.errors.<chave>", ..., default: "<inglês>")` no use case.
2. Chave pt-BR no yml de domínio (`config/locales/pt-BR/<dominio>.yml` → `errors:`).
3. Controller renderiza a falha no formato `{details: [...]}` (via `format_errors`) —
   conferir que não há copy-paste de variável errada no branch de erro.
4. BFF: se o fluxo ainda não repassa `Accept-Language`, incluir o repasse no escopo
   (1 linha em `src/index.js`) — sem isso a tradução nunca ativa para o painel.
5. Request spec cobrindo os dois idiomas (com e sem `Accept-Language: pt-BR`).
6. Mensagem actionable: incluir os valores que o usuário precisa (limites, totais,
   remanescentes), não só "valor inválido".
