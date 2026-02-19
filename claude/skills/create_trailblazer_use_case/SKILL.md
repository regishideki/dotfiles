---
name: create_trailblazer_use_case
description: Guia para criar Trailblazer use cases seguindo os padrões do projeto. Use quando o usuário pedir para criar um novo use case, implementar lógica de negócio com Trailblazer, ou perguntar sobre padrões e boas práticas de use cases.
---

# Skill: Create Trailblazer Use Case

Esta skill fornece orientações para criar use cases seguindo os padrões estabelecidos no projeto, baseada na análise dos use cases existentes.

## Quando usar

- Implementar nova regra de negócio
- Orquestrar múltiplas operações com validação, autorização e persistência
- Encapsular fluxos que precisam de monitoramento, transação e eventos

---

## Estrutura Padrão

```ruby
# standard:disable Lint/UnreachableCode
module Domain
  module UseCases
    class ActionName < UseCase::Base
      class Contract < Dry::Validation::Contract
        params do
          required(:field).value(:string).filled
          optional(:other).maybe(:string)
        end
      end

      step Wrap(TrailblazerUseCaseMonitoringWrap) {
        step ::CustomMacros::Contract::Build(contract_class: Contract), fail_fast: true
        step ::CustomMacros::Model.Find(
          retrieve_id: ->(ctx) { ctx[:params][:record_id] },
          model_class: Domain::Record,
          model_key: :record
        ), Output(CustomMacros::Model::IdNotGiven, :not_given) => End(:not_found)
        step Policy::Pundit(Domain::RecordPolicy, :action?),
          In() => ->(ctx, **) { {model: ctx[:record], current_user: ctx[:current_user]} }
        step Wrap(TrailblazerTransactionWrap) {
          step :perform_action
          fail :validation_error, Inject(:model) => ->(ctx, record:, **) { record }
        }
        step :build_event
        step ::Events::Trailblazer::EmitEvent.call
      },
        Output(:not_found) => End(:not_found),
        Output(:fail_fast) => End(:fail_fast)

      private

      def perform_action(ctx, contract:, record:, current_user:, **)
        record.update(contract.to_h.merge(updated_by: current_user))
      end

      def build_event(ctx, record:, event_class: Domain::Events::RecordActioned, **)
        ctx[:events] << event_class.build_from(record)
      end
    end
  end
end
# standard:enable Lint/UnreachableCode
```

---

## Regras Fundamentais

### 1. Sempre herdar de `UseCase::Base`

```ruby
# CORRETO
class MyUseCase < UseCase::Base

# ERRADO — perde monitoring, setup de errors/events, helpers
class MyUseCase < Trailblazer::Activity::Railway
class MyUseCase < Trailblazer::Operation
```

`UseCase::Base` inicializa automaticamente `ctx[:errors] = []`, `ctx[:events] = []` e `ctx[:use_case]`.

### 2. Sempre envolver com `TrailblazerUseCaseMonitoringWrap`

Todo use case deve ter seus steps dentro de `Wrap(TrailblazerUseCaseMonitoringWrap)`. Isso garante traces no Datadog, captura de erros e sinalização do resultado.

```ruby
step Wrap(TrailblazerUseCaseMonitoringWrap) {
  # todos os steps aqui dentro
},
  Output(:not_found) => End(:not_found),
  Output(:fail_fast) => End(:fail_fast)
```

Todos os terminais customizados usados dentro do wrap devem ser propagados para fora dele.

### 3. Contract sempre com `fail_fast: true`

```ruby
step ::CustomMacros::Contract::Build(contract_class: Contract), fail_fast: true
```

Nunca omitir o `fail_fast: true` no contract — sem ele, o fluxo continua mesmo com params inválidos.

### 4. Usar `CustomMacros::Model.Find` para buscar registros

```ruby
step ::CustomMacros::Model.Find(
  retrieve_id: ->(ctx) { ctx[:params][:record_id] },
  model_class: Domain::Record,
  model_key: :record
), Output(CustomMacros::Model::IdNotGiven, :not_given) => End(:not_found)
```

**Nunca usar `Model.find(id)` diretamente** — levanta exceção em vez de seguir o railway pattern. Também não usar `find_by(id:)` sem o macro, pois não há tratamento padronizado de not found.

### 5. Mutations sempre dentro de `TrailblazerTransactionWrap`

```ruby
step Wrap(TrailblazerTransactionWrap) {
  step :create_record
  fail :validation_error, Inject(:model) => ->(ctx, record:, **) { record }
  step :update_related
}
```

O `TrailblazerTransactionWrap` faz rollback automaticamente quando qualquer step falha dentro dele. Usar para qualquer operação que escreva no banco.

### 6. Erros: sempre usar `add_error` ou `validation_error`

O `ctx[:errors]` é inicializado como **array** pelo `UseCase::Base`. Nunca sobrescrever com um hash:

```ruby
# ERRADO — quebra o formato esperado
ctx[:errors] = { code: "VALIDATION_ERROR", message: "..." }

# CORRETO — usa helper da base que também chama set_error_on_span
add_error(ctx, message: "Something went wrong", code: "VALIDATION_ERROR")

# CORRETO — para erros de validação de model ActiveRecord
fail :validation_error, Inject(:model) => ->(ctx, record:, **) { record }
```

`add_error` retorna `false` automaticamente (falha o step) e registra no span do Datadog.

### 7. Todos os métodos de step devem ser `private`

```ruby
step Wrap(TrailblazerUseCaseMonitoringWrap) {
  step :perform_action
  step :build_event
}

private

def perform_action(ctx, **)
  # ...
end

def build_event(ctx, **)
  # ...
end
```

### 8. Lint disable: usar `standard` (não `rubocop`)

```ruby
# CORRETO
# standard:disable Lint/UnreachableCode
# standard:enable Lint/UnreachableCode

# ERRADO
# rubocop:disable Lint/UnreachableCode
```

### 9. Nunca usar bang methods em lógica de negócio

```ruby
# ERRADO
ctx[:record] = Record.create!(attributes)
record.save!
record.update!(attrs)

# CORRETO
ctx[:record] = Record.create(attributes)
ctx[:record].valid?  # retorna false se inválido, step falha
record.save
record.update(attrs)
```

### 10. Injeção de dependência para testabilidade

Sempre que um step chamar um use case, model class ou event class externos, injete como parâmetro com default:

```ruby
def create_record(
  ctx,
  contract:,
  record_class: Domain::Record,
  event_class: Domain::Events::RecordCreated,
  sub_use_case: Other::UseCases::DoSomething,
  **
)
  ctx[:record] = record_class.create(contract.to_h)
  ctx[:record].valid?
end
```

Isso permite substituição em testes sem mocks globais.

---

## Padrões de Composição

### Subfluxos com `Subprocess`

```ruby
step Subprocess(FindContextualizable),
  Output(:not_found) => End(:not_found),
  Output(:context_not_given) => Track(:success)
```

Use `Subprocess` para delegar a outro use case, mapeando os terminais de saída.

### Iteração com `Each`

```ruby
step Each(dataset_from: :get_items, item_key: :item) {
  step Subprocess(ProcessItem), In() => [:item]
}

def get_items(ctx, collection:, **)
  collection
end
```

### Chamar use case externo imperativamente (dentro de um step)

```ruby
def sync_with_external(
  ctx,
  record:,
  current_user:,
  external_use_case: Other::UseCases::Sync,
  **
)
  result = external_use_case.call(params: {id: record.id}, current_user:)
  ctx[:external_result] = result
  result.success?
end

def fail_sync(ctx, external_result:, **)
  errors = external_result[:errors]
  errors.each { |e| add_error(ctx, message: e[:message], code: e[:code]) }
  false
end
```

---

## Estrutura de Arquivos

```
packs/<domain>/app/concepts/<concept>/use_cases/
├── contracts/
│   └── create_record_contract.rb   # Contract extraído se reutilizado
├── subprocess/
│   └── find_record_context.rb      # Subflow reutilizável
├── notifications/
│   └── notify_record_created.rb    # Notificações como use cases separados
└── create_record.rb                # Use case principal
```

O Contract pode ser uma inner class quando é simples e exclusivo do use case. Extrair para `contracts/` apenas quando for reutilizado em múltiplos use cases.

---

## Exemplos Completos

### Exemplo 1: Create (com contract, model find, policy, transaction, evento)

```ruby
# standard:disable Lint/UnreachableCode
module Records
  module UseCases
    class CreateRecord < UseCase::Base
      class Contract < Dry::Validation::Contract
        params do
          required(:title).value(Types::StrippedString).filled
          required(:clinical_case_id).value(:string).filled
          optional(:description).maybe(:string)
        end
      end

      step Wrap(TrailblazerUseCaseMonitoringWrap) {
        step ::CustomMacros::Contract::Build(contract_class: Contract), fail_fast: true
        step ::CustomMacros::Model.Find(
          retrieve_id: ->(ctx) { ctx[:params][:clinical_case_id] },
          model_class: ClinicalCase,
          model_key: :clinical_case
        ), Output(CustomMacros::Model::IdNotGiven, :not_given) => End(:not_found)
        step Policy::Pundit(ClinicalCaseOwnerPolicy, :only_internal),
          In() => ->(ctx, **) { {model: ctx[:clinical_case], current_user: ctx[:current_user]} }
        step Wrap(TrailblazerTransactionWrap) {
          step :create_record
          fail :validation_error, Inject(:model) => ->(ctx, record:, **) { record }
        }
        step :build_event
        step ::Events::Trailblazer::EmitEvent.call
      },
        Output(:not_found) => End(:not_found),
        Output(:fail_fast) => End(:fail_fast)

      private

      def create_record(
        ctx,
        contract:,
        clinical_case:,
        current_user:,
        record_class: Records::Record,
        **
      )
        ctx[:record] = record_class.create(
          contract.to_h.merge(
            clinical_case:,
            created_by: current_user.user,
            updated_by: current_user.user
          )
        )

        ctx[:record].valid?
      end

      def build_event(ctx, record:, event_class: Records::Events::RecordCreated, **)
        ctx[:events] << event_class.build_from(record)
      end
    end
  end
end
# standard:enable Lint/UnreachableCode
```

### Exemplo 2: Update (sem policy, com validação condicional)

```ruby
# standard:disable Lint/UnreachableCode
module Records
  module UseCases
    class UpdateRecord < UseCase::Base
      class Contract < Dry::Validation::Contract
        params do
          required(:record_id).value(:string).filled
          optional(:title).maybe(Types::StrippedString)
          optional(:description).maybe(:string)
        end
      end

      step Wrap(TrailblazerUseCaseMonitoringWrap) {
        step ::CustomMacros::Contract::Build(contract_class: Contract), fail_fast: true
        step ::CustomMacros::Model.Find(
          retrieve_id: ->(ctx) { ctx[:params][:record_id] },
          model_class: Records::Record,
          model_key: :record
        ), Output(CustomMacros::Model::IdNotGiven, :not_given) => End(:not_found)
        step :validate_record_is_editable
        fail :fail_not_editable, Output(:failure) => End(:unprocessable)
        step Wrap(TrailblazerTransactionWrap) {
          step :update_record
          fail :validation_error, Inject(:model) => ->(ctx, record:, **) { record }
        }
        step :build_event
        step ::Events::Trailblazer::EmitEvent.call
      },
        Output(:not_found) => End(:not_found),
        Output(:unprocessable) => End(:unprocessable),
        Output(:fail_fast) => End(:fail_fast)

      private

      def validate_record_is_editable(ctx, record:, **)
        record.editable?
      end

      def fail_not_editable(ctx, record:, **)
        add_error(ctx, message: "Record #{record.id} cannot be edited in status #{record.status}", code: "UNPROCESSABLE")
      end

      def update_record(ctx, record:, contract:, current_user:, **)
        record.update(contract.to_h.except(:record_id).merge(updated_by: current_user.user))
      end

      def build_event(ctx, record:, event_class: Records::Events::RecordUpdated, **)
        ctx[:events] << event_class.build_from(record)
      end
    end
  end
end
# standard:enable Lint/UnreachableCode
```

### Exemplo 3: Delete (com soft-delete e evento)

```ruby
# standard:disable Lint/UnreachableCode
module Records
  module UseCases
    class DeleteRecord < UseCase::Base
      class Contract < Dry::Validation::Contract
        params do
          required(:record_id).value(:string).filled
        end
      end

      step Wrap(TrailblazerUseCaseMonitoringWrap) {
        step ::CustomMacros::Contract::Build(contract_class: Contract), fail_fast: true
        step ::CustomMacros::Model.Find(
          retrieve_id: ->(ctx) { ctx[:params][:record_id] },
          model_class: Records::Record,
          model_key: :record
        ), Output(CustomMacros::Model::IdNotGiven, :not_given) => End(:not_found)
        step Policy::Pundit(Records::RecordPolicy, :destroy?),
          In() => ->(ctx, **) { {model: ctx[:record], current_user: ctx[:current_user]} }
        step Wrap(TrailblazerTransactionWrap) {
          step :delete_record
        }
        step :build_event
        step ::Events::Trailblazer::EmitEvent.call
      },
        Output(:not_found) => End(:not_found),
        Output(:fail_fast) => End(:fail_fast)

      private

      def delete_record(ctx, record:, current_user:, **)
        record.discard
      end

      def build_event(ctx, record:, event_class: Records::Events::RecordDeleted, **)
        ctx[:events] << event_class.build_from(record)
      end
    end
  end
end
# standard:enable Lint/UnreachableCode
```

---

## Checklist antes de criar um use case

- [ ] Herda de `UseCase::Base` (nunca `Trailblazer::Operation` ou `Trailblazer::Activity::Railway`)
- [ ] Todos os steps estão dentro de `Wrap(TrailblazerUseCaseMonitoringWrap)`
- [ ] Todos os terminais customizados internos são propagados para fora do wrap
- [ ] Contract usa `fail_fast: true`
- [ ] Model lookup usa `CustomMacros::Model.Find` (nunca `Model.find(id)`)
- [ ] Mutações estão dentro de `Wrap(TrailblazerTransactionWrap)`
- [ ] Erros usam `add_error` ou `validation_error` — nunca `ctx[:errors] = {...}` com hash
- [ ] Nenhum bang method (`save!`, `create!`, `update!`) em lógica de negócio
- [ ] Todos os steps são `private`
- [ ] Lint comment usa `# standard:disable` (não `rubocop:disable`)
- [ ] Dependências externas injetáveis como parâmetros com default
- [ ] Eventos são construídos em `build_event` e emitidos via `EmitEvent.call`

---

## Anti-patterns a evitar

### Herança errada
```ruby
# ERRADO
class MyUseCase < Trailblazer::Activity::Railway  # sem monitoring, sem error setup
class MyUseCase < Trailblazer::Operation          # idem
```

### Erros como hash em vez de array
```ruby
# ERRADO — sobrescreve o array, quebra consumidores que fazem ctx[:errors].each
ctx[:errors] = { code: "NOT_FOUND", message: "Record not found" }
ctx[:errors] = [{ code: "NOT_FOUND", message: "Record not found" }]  # não chama set_error_on_span

# CORRETO
add_error(ctx, message: "Record not found", code: "NOT_FOUND")
```

### Bang methods em use cases
```ruby
# ERRADO
ctx[:record] = Record.create!(contract.to_h)  # levanta exceção, escapa do railway

# CORRETO
ctx[:record] = Record.create(contract.to_h)
ctx[:record].valid?
```

### Busca de model sem macro
```ruby
# ERRADO — levanta ActiveRecord::RecordNotFound (exceção não tratada)
def find_record(ctx, params:, **)
  ctx[:record] = Record.find(params[:id])
end

# CORRETO
step ::CustomMacros::Model.Find(
  retrieve_id: ->(ctx) { ctx[:params][:id] },
  model_class: Record,
  model_key: :record
), Output(CustomMacros::Model::IdNotGiven, :not_given) => End(:not_found)
```

### Duplicar lógica de `validation_error`
```ruby
# ERRADO — recria o que validation_error já faz
def handle_errors(ctx, record:, **)
  ctx[:errors] += record.errors.map { |e| { code: "VALIDATION_ERROR", message: e.full_message } }
  false
end

# CORRETO
fail :validation_error, Inject(:model) => ->(ctx, record:, **) { record }
```

### Não propagar terminais para fora do wrap
```ruby
# ERRADO — terminais internos ficam presos no wrap
step Wrap(TrailblazerUseCaseMonitoringWrap) {
  step ..., Output(...) => End(:not_found)
}

# CORRETO — propagar explicitamente
step Wrap(TrailblazerUseCaseMonitoringWrap) {
  step ..., Output(...) => End(:not_found)
}, Output(:not_found) => End(:not_found)
```

### Duplo `TrailblazerUseCaseMonitoringWrap`
```ruby
# ERRADO — wrap aninhado gera traces duplicados no Datadog
step Wrap(TrailblazerUseCaseMonitoringWrap) {
  step Wrap(TrailblazerUseCaseMonitoringWrap) {  # desnecessário
    step :do_something
  }
}
```

### Steps públicos
```ruby
# ERRADO — expõe implementação interna
def perform_action(ctx, **)
  # ...
end

# CORRETO
private

def perform_action(ctx, **)
  # ...
end
```
