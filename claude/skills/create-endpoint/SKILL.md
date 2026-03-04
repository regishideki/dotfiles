---
name: create-endpoint
description: Guia completo para criar novos endpoints no projeto core (Rails), seguindo as boas práticas identificadas nos controllers, policies e specs existentes. Use quando o usuário pedir para criar um novo endpoint, adicionar uma action a um controller existente, ou perguntar sobre padrões de controllers e testes de request.
---

# Skill: Create Endpoint (core)

Guia baseado na análise dos controllers, policies e request specs existentes no projeto.

---

## Boas práticas identificadas no projeto

### Controllers
- **Controllers finos**: delegam lógica de negócio a use cases (Trailblazer); nenhuma regra de negócio inline
- **`before_action` default sem `only:` (seguro por padrão)**: o before_action que carrega e autoriza o contexto pai (ex: `clinical_case`) deve ser default — se uma nova action for adicionada sem ser explicitamente excluída, ela herda a proteção automaticamente
- **`only:` quando necessário por duas razões**: (1) o before_action precisa de params que não existem em todas as actions (ex: `params[:id]` só existe em rotas de membro); (2) o before_action é mais restritivo do que o que algumas actions permitem — se um before_action default bloquear usuários que deveriam ter acesso via outro caminho de autorização (ex: `index?` bloqueia "clínico via sessão" que `show?` permitiria), ele deve ser restrito com `only:`
- **Autorização em camadas**: o before_action default protege o acesso ao contexto pai; o before_action com `only:` adiciona proteção específica ao recurso filho (o usuário passa pelos dois para actions de membro)
- **Pundit para autorização**: sempre via `authorize record, :method?, policy_class: Policy` — nunca `raise UserAccessDenied` inline no controller
- **Named routes**: toda rota nova deve ter `as: :nome_da_rota`
- **Rota `index` antes de rotas com parâmetros**: para evitar conflito de matching (`/registries` antes de `/registries/:id`)
- **`query_params` para params com notação de ponto**: Rails não parseia dot-notation nativamente. Sempre que o endpoint aceitar params estruturados como `context.type` ou `subject.planning.statuses`, chamar `query_params([...])` no início da action com os caminhos dot-notation. Params simples (strings, inteiros, arrays top-level) não precisam.
- **Preferir filtros que recebem array a filtros que recebem string**: um filtro de array com um único elemento equivale ao filtro de string, mas também aceita múltiplos valores — mais flexibilidade com pouco esforço extra. Ex: `status: []` em vez de `status: :string`

### Policies
- **Uma policy por recurso**: methods nomeados pela action que autorizam (`index?`, `show?`, `create?`)
- **Sempre levantar `UserAccessDenied` dentro da policy** via `.tap { |ok| raise UserAccessDenied unless ok }` — nunca no controller
- **`initialize` flexível**: quando a mesma policy serve para actions com records diferentes (ex: `index` recebe `ClinicalCase`, `show` recebe `Registry`), usar `record.respond_to?(:clinical_case) ? record.clinical_case : record`

### Testes de request
- **AAA sem comentários inline**: blocos arrange/act/assert separados por linha em branco
- **Erros primeiro, sucesso no final**: 401 → 403 → 200
- **Casos intermediários além dos extremos**: não só "sem permissão" e "admin" — testar o caso de usuário normal sem vínculo (403) E com vínculo (200)
- **Verificar atributos relevantes da resposta**, não só o status code — ao menos `id`, `status` e campos de data relevantes
- **`mock_valid_auth_headers(user)`** para autenticação nas requests
- **`JSON.dump` para params com notação de ponto**: quando o endpoint usa `query_params` para um param dot-notation, o teste deve passar esse param como `"param.dot.path": JSON.dump(value)`. Sem isso, o teste não simula o caminho real da produção e vira falso positivo. Params simples e arrays top-level são passados normalmente.
- **Sem `let`/`before`/`after`**: setup explícito dentro de cada `it`
- **URL com `.json`**: sempre explícito no path da request

---

## Más práticas observadas (evitar)

- `before_action` sem `only:` em controllers com múltiplas actions
- Levantar exceção de autorização diretamente no controller em vez de usar Pundit
- Testes que verificam apenas o status code sem checar o corpo da resposta
- Testes que só cobrem o caso extremo (`full_privileges`) sem cobrir usuário normal com e sem acesso
- Ordenar testes com sucesso antes dos erros
- Usar `let`/`before` para setup de dados mutáveis entre exemplos
- Esquecer o `as:` na rota
- Adicionar rota com parâmetros dinâmicos antes de rota estática que pode colidir

---

## Estrutura de um endpoint novo

### 1. Rota (`config/routes.rb`)

```ruby
# Dentro do scope do recurso pai (ex: resources :clinical_cases)
# Rotas estáticas ANTES de rotas com parâmetros
get "speech_therapy_assessments/registries",
    to: "assessments/speech_therapy_assessments_registries#index",
    as: :clinical_case_speech_therapy_assessments_registries

get "speech_therapy_assessments/registries/:id",
    to: "assessments/speech_therapy_assessments_registries#show",
    as: :clinical_case_speech_therapy_assessments_registry
```

### 2. Controller

```ruby
module Assessments
  class SpeechTherapyAssessmentsRegistriesController < ApplicationController
    include Pundit::Authorization

    before_action :authorize_clinical_case          # default: protege todas as actions
    before_action :authorize_registry, only: [:show] # only: porque params[:id] só existe em rotas de membro

    # GET /clinical_cases/:clinical_case_id/speech_therapy_assessments/registries
    def index
      @registries = Assessments::SpeechTherapy::Registry
        .where(clinical_case: @clinical_case)
        .order(created_at: :desc)
    end

    # GET /clinical_cases/:clinical_case_id/speech_therapy_assessments/registries/:id
    def show
    end

    private

    def authorize_clinical_case
      @clinical_case = ClinicalCase.find(params[:clinical_case_id])
      authorize @clinical_case, :index?, policy_class: AssessmentsRegistryPolicy
    end

    def authorize_registry
      @clinical_case = ClinicalCase.find(params[:clinical_case_id])
      @registry = Assessments::SpeechTherapy::Registry.find(params[:id])
      authorize @registry, :show?, policy_class: AssessmentsRegistryPolicy
    end
  end
end
```

**Regras do controller:**
- Cada `before_action` privado: carrega o(s) recurso(s) necessário(s) + chama `authorize`
- Para actions de coleção (`index`): o record passado ao Pundit é o pai (ex: `ClinicalCase`)
- Para actions de membro (`show`, `update`, `destroy`): o record é o próprio recurso
- Delegates para use case quando há mutação ou lógica de negócio

### 3. Policy

```ruby
class AssessmentsRegistryPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
    # Flexível: funciona com Registry (que tem .clinical_case) e com ClinicalCase diretamente
    @clinical_case = record.respond_to?(:clinical_case) ? record.clinical_case : record
  end

  def index?
    (user_in_clinical_case? || @user.full_privileges?).tap do |has_access|
      raise UserAccessDenied unless has_access
    end
  end

  def show?
    (user_in_assessments_sessions? || user_in_clinical_case? || @user.full_privileges?).tap do |has_access|
      raise UserAccessDenied unless has_access
    end
  end

  private

  def user_in_clinical_case?
    return false if @user.clinician.nil?
    @clinical_case.clinicians.include?(@user.clinician)
  end

  def user_in_assessments_sessions?
    return false if @record.nil? || @user.clinician.nil?
    @record.assessment_sessions.any? { |as| as.general_session.clinicians.include?(@user.clinician) }
  end
end
```

**Regras da policy:**
- Sempre `raise UserAccessDenied` (não `Pundit::NotAuthorizedError`) — o `ApplicationController` trata ambos, mas o padrão do projeto é `UserAccessDenied`
- Method name = nome da action + `?` (ex: `index?`, `show?`, `create?`)
- Extrair condições para métodos privados nomeados semanticamente

### 4. View (jbuilder)

```ruby
# index.json.jbuilder
json.array! @registries do |registry|
  json.partial! "assessments/speech_therapy_assessments_registries/registry", registry: registry
end

# show.json.jbuilder
json.partial! "assessments/speech_therapy_assessments_registries/registry", registry: @registry

# _registry.json.jbuilder (partial)
json.extract! registry,
  :id,
  :status,
  :started_at,
  :completed_at,
  :created_at,
  :updated_at
```

### 5. Spec de request

```ruby
require "rails_helper"

RSpec.describe "/clinical_cases/:clinical_case_id/speech_therapy_assessments/registries", type: :request do
  # ── index ────────────────────────────────────────────────────────────────────
  describe "GET .../registries" do
    # ERROS PRIMEIRO
    context "when user is not logged in" do
      it "returns 401" do
        clinical_case = create(:clinical_case)

        get "/clinical_cases/#{clinical_case.id}/speech_therapy_assessments/registries.json", headers: {}

        expect(response).to have_http_status(401)
      end
    end

    context "when user is logged in but is not a clinician of the case and has no full privileges" do
      it "returns 403" do
        user = create(:user_as_therapist)
        create(:clinician, user: user)
        clinical_case = create(:clinical_case)

        get "/clinical_cases/#{clinical_case.id}/speech_therapy_assessments/registries.json",
          headers: mock_valid_auth_headers(user)

        expect(response).to have_http_status(403)
      end
    end

    # SUCESSO NO FINAL
    context "when user is a clinician of the clinical case" do
      it "returns the list of registries with their attributes" do
        user = create(:user_as_therapist)
        clinician = create(:clinician, user: user)
        clinical_case = create(:clinical_case)
        create(:clinical_case_clinician, clinical_case: clinical_case, clinician: clinician)
        registry = create(:assessment_speech_therapy_registry, clinical_case:)

        get "/clinical_cases/#{clinical_case.id}/speech_therapy_assessments/registries.json",
          headers: mock_valid_auth_headers(user)

        expect(response).to have_http_status(200)
        response_body = JSON.parse(response.body)
        expect(response_body.length).to eq(1)
        expect(response_body.first).to include(
          "id" => registry.id,
          "status" => registry.status,
          "started_at" => registry.started_at.as_json,
          "completed_at" => registry.completed_at
        )
      end
    end

    context "when user has full privileges" do
      it "returns the list of registries with their attributes" do
        user = create(:user_as_developer)
        clinical_case = create(:clinical_case)
        registry = create(:assessment_speech_therapy_registry, clinical_case:)

        get "/clinical_cases/#{clinical_case.id}/speech_therapy_assessments/registries.json",
          headers: mock_valid_auth_headers(user)

        expect(response).to have_http_status(200)
        response_body = JSON.parse(response.body)
        expect(response_body.length).to eq(1)
        expect(response_body.first).to include(
          "id" => registry.id,
          "status" => registry.status,
          "started_at" => registry.started_at.as_json,
          "completed_at" => registry.completed_at
        )
      end
    end
  end

  # ── show ─────────────────────────────────────────────────────────────────────
  describe "GET .../registries/:id" do
    context "when user is not logged in" do
      it "returns 401" do
        clinical_case = create(:clinical_case)
        registry = create(:assessment_speech_therapy_registry, clinical_case:)

        get "/clinical_cases/#{clinical_case.id}/speech_therapy_assessments/registries/#{registry.id}.json",
          headers: {}

        expect(response).to have_http_status(401)
      end
    end

    context "when user is logged in but has no permission" do
      it "returns 403" do
        user = create(:user_as_therapist)
        create(:clinician, user: user)
        clinical_case = create(:clinical_case)
        registry = create(:assessment_speech_therapy_registry, clinical_case:)

        get "/clinical_cases/#{clinical_case.id}/speech_therapy_assessments/registries/#{registry.id}.json",
          headers: mock_valid_auth_headers(user)

        expect(response).to have_http_status(403)
      end
    end

    context "when user is a clinician of the clinical case" do
      it "returns the registry" do
        user = create(:user_as_therapist)
        clinician = create(:clinician, user: user)
        clinical_case = create(:clinical_case)
        create(:clinical_case_clinician, clinical_case: clinical_case, clinician: clinician)
        registry = create(:assessment_speech_therapy_registry, clinical_case:)

        get "/clinical_cases/#{clinical_case.id}/speech_therapy_assessments/registries/#{registry.id}.json",
          headers: mock_valid_auth_headers(user)

        expect(response).to have_http_status(200)
        response_body = JSON.parse(response.body)
        expect(response_body).to include(
          "id" => registry.id,
          "status" => registry.status
        )
      end
    end

    context "when user has full privileges" do
      it "returns the registry" do
        user = create(:user_as_developer)
        clinical_case = create(:clinical_case)
        registry = create(:assessment_speech_therapy_registry, clinical_case:)

        get "/clinical_cases/#{clinical_case.id}/speech_therapy_assessments/registries/#{registry.id}.json",
          headers: mock_valid_auth_headers(user)

        expect(response).to have_http_status(200)
        response_body = JSON.parse(response.body)
        expect(response_body).to include(
          "id" => registry.id,
          "status" => registry.status
        )
      end

      context "when registry is not found" do
        it "returns 404" do
          user = create(:user_as_developer)
          clinical_case = create(:clinical_case)

          get "/clinical_cases/#{clinical_case.id}/speech_therapy_assessments/registries/non_existent_id.json",
            headers: mock_valid_auth_headers(user)

          expect(response).to have_http_status(404)
        end
      end
    end
  end
end
```

---

## Checklist antes de abrir o PR

- [ ] Rota estática declarada antes de rotas com parâmetros dinâmicos
- [ ] Rota tem `as: :nome_da_rota`
- [ ] Controller tem `include Pundit::Authorization`
- [ ] Cada `before_action` tem `only:` explícito
- [ ] Autorização via `authorize record, :method?, policy_class: Policy` (não inline)
- [ ] Policy tem method `action?` correspondente que levanta `UserAccessDenied`
- [ ] `initialize` da policy usa `respond_to?(:clinical_case)` se necessário
- [ ] View jbuilder usa partial para o objeto serializado
- [ ] Spec cobre: 401 (sem auth), 403 (sem permissão), 200 para usuário vinculado, 200 para `full_privileges?`
- [ ] Casos de erro no topo, casos de sucesso no final do spec
- [ ] Atributos relevantes verificados no corpo da resposta (não só status code)
- [ ] Setup explícito dentro de cada `it` (sem `let`/`before` para dados mutáveis)
- [ ] URLs das requests com `.json` explícito
