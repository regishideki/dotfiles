# FAQ - Perguntas Frequentes sobre Rake Tasks

## 🤔 Decisões de Design

### Q: Quando devo usar transaction?

**Use transaction quando:**
- A operação deve ser atômica (tudo ou nada)
- Você está criando registros relacionados que dependem uns dos outros
- Dados críticos onde rollback é necessário se algo falhar
- Exemplo: Migrar contratos E atualizar referências no modelo antigo

**NÃO use transaction quando:**
- Progresso parcial é aceitável
- Operações são independentes (ex: atualizar campo em milhares de registros)
- Importação massiva onde você quer ver quantos conseguiu processar
- Operação é facilmente reversível manualmente

**Exemplo prático:**

```ruby
# ✅ BOM - Use transaction
# Criar família com child e caregivers (relacionados)
ActiveRecord::Base.transaction do
  child = Child.create!(...)
  caregiver = Caregiver.create!(...)
  Family.create!(child: child, caregiver: caregiver)
end

# ❌ RUIM - Não precisa de transaction
# Atualizar campo em 10.000 registros independentes
# Se 9.500 funcionarem e 500 falharem, você quer saber quais falharam
# Não quer perder o progresso dos 9.500
Model.all.each { |m| m.update(field: value) }
```

### Q: Como lidar com UseCases em transactions?

**Problema:** UseCases não lançam exceptions, apenas retornam `ctx.success? = false`.

**Solução:**

```ruby
# ❌ ERRADO - Não causa rollback
ActiveRecord::Base.transaction do
  ctx = MyUseCase.call(params: {})
  # Se ctx.success? == false, NÃO ACONTECE ROLLBACK!
end

# ✅ CORRETO - Lança exception manualmente
ActiveRecord::Base.transaction do
  ctx = MyUseCase.call(params: {})

  unless ctx.success?
    error_msg = ctx[:errors].map { |e| "#{e[:code]}: #{e[:message]}" }.join(", ")
    raise StandardError, error_msg
  end
end
```

**Alternativa:** Não use transaction se progresso parcial é OK:

```ruby
# Sem transaction - acumula erros e continua
errors = []

data.each do |item|
  ctx = MyUseCase.call(params: item)

  if ctx.success?
    print "."
  else
    errors << { item: item, errors: ctx[:errors] }
    print "e"
  end
end
```

### Q: DRY_RUN via ENV ou args?

**Via ENV (preferido para rake tasks simples):**

```ruby
task do_something: :environment do
  dry_run = ENV["DRY_RUN"].to_s == "1"
  # ...
end

# Uso: DRY_RUN=1 rake do_something
```

**Vantagens:**
- Sintaxe mais simples
- Não precisa de parâmetros na task
- Fácil combinar com outras ENV vars

**Via args (preferido para rake tasks com múltiplos parâmetros):**

```ruby
task :do_something, [:confirmation, :other_param] => :environment do |_, args|
  confirmation = args[:confirmation] == "true"
  # ...
end

# Uso: rake do_something[true,value]
```

**Vantagens:**
- Agrupa todos os parâmetros
- Mais explícito
- Melhor para tasks com argumentos posicionais

**Escolha:** Use ENV para tasks simples com poucos parâmetros. Use args quando tiver 3+ parâmetros ou quando a ordem importar.

### Q: Como nomear as variáveis de controle?

**Para DRY_RUN/Preview:**
- `dry_run` (booleano) - quando não executa nada
- `confirmation` (booleano) - quando precisa confirmar
- Ambos significam "não executar de verdade", use conforme preferência do time

**Para bypass:**
- `bypass_errors` (booleano) - pular validações/erros

**Para dados:**
- `file_path` (string) - caminho do arquivo
- `start_date`, `end_date` (Date) - datas
- `batch_size` (integer) - tamanho do lote

### Q: Como organizar arquivos de rake tasks?

```
lib/tasks/
├── namespace/
│   ├── task_name.rake          # Task específica
│   └── data/                   # Dados específicos da task
│       └── import_data.csv
├── finance/                    # Tasks de finance
│   ├── adjust_pricing.rake
│   └── generate_invoices.rake
├── operational/                # Tasks operacionais
│   ├── migrate_data.rake
│   └── data/
│       └── collaborators.csv
└── general_task.rake          # Tasks gerais
```

**Regras:**
- Um namespace = um diretório
- Tasks relacionadas no mesmo diretório
- Dados em subdiretório `data/`
- Não misture namespaces diferentes no mesmo arquivo

## 🐛 Problemas Comuns

### Q: Por que minha rake task não está fazendo rollback?

**Causas comuns:**

1. **Usando UseCase sem lançar exception:**
   ```ruby
   # ❌ NÃO FAZ ROLLBACK
   ActiveRecord::Base.transaction do
     ctx = UseCase.call(params: {})
     # ctx.success? == false não causa rollback!
   end
   ```

2. **Rescue escondendo erros:**
   ```ruby
   # ❌ NÃO FAZ ROLLBACK
   ActiveRecord::Base.transaction do
     begin
       Model.create!(...)
     rescue => e
       # Não re-raise = transaction commita!
     end
   end
   ```

3. **Usando `save` ao invés de `save!`:**
   ```ruby
   # ❌ NÃO FAZ ROLLBACK
   ActiveRecord::Base.transaction do
     model = Model.new(...)
     model.save  # Retorna false, não lança exception!
   end
   ```

**Soluções:**

```ruby
# ✅ Lançar exception em UseCases
ActiveRecord::Base.transaction do
  ctx = UseCase.call(params: {})
  raise StandardError, "UseCase failed" unless ctx.success?
end

# ✅ Re-raise após rescue
ActiveRecord::Base.transaction do
  begin
    Model.create!(...)
  rescue => e
    puts "Error: #{e.message}"
    raise  # Re-raise para causar rollback
  end
end

# ✅ Usar métodos bang
ActiveRecord::Base.transaction do
  Model.create!(...)  # Lança exception se falhar
end
```

### Q: Por que meu CSV não está sendo lido corretamente?

**Problemas comuns:**

1. **Encoding errado:**
   ```ruby
   # ✅ Especificar encoding
   CSV.foreach(file_path, headers: true, encoding: "UTF-8") do |row|
   ```

2. **Separador errado:**
   ```ruby
   # ✅ Especificar separador (default é vírgula)
   CSV.foreach(file_path, headers: true, col_sep: ";") do |row|
   ```

3. **Headers não reconhecidos:**
   ```ruby
   # ❌ Headers com espaços: "Name " vs "Name"
   row["Name"]  # nil

   # ✅ Strip ou use símbolos
   CSV.foreach(file_path, headers: true, header_converters: :symbol) do |row|
     row[:name]  # Converte headers para símbolos
   end
   ```

### Q: Como debugar uma rake task?

**1. Adicione logs detalhados:**
```ruby
puts "Processing record #{record.id}"
puts "Attributes: #{attributes.inspect}"
```

**2. Use `binding.pry` (se tiver pry):**
```ruby
require "pry"

task debug_task: :environment do
  data.each do |item|
    binding.pry  # Para aqui
    process(item)
  end
end
```

**3. Limite o processamento:**
```ruby
# Processar apenas primeiros 10 registros
records.limit(10).each do |record|
  # ...
end
```

**4. Use dry-run com logs:**
```ruby
if dry_run
  puts "Would process: #{record.inspect}"
  puts "Would update: #{new_attributes.inspect}"
end
```

### Q: Como fazer uma rake task processar mais rápido?

**1. Use `find_each` ao invés de `each`:**
```ruby
# ❌ Carrega tudo na memória
Model.all.each { |m| process(m) }

# ✅ Processa em batches
Model.find_each { |m| process(m) }
```

**2. Use `update_column(s)` se não precisar de callbacks:**
```ruby
# ❌ Lento - roda validações e callbacks
record.update(field: value)

# ✅ Rápido - pula validações e callbacks
record.update_column(:field, value)
```

**3. Use batch inserts:**
```ruby
# ❌ Lento - um INSERT por vez
data.each { |d| Model.create(d) }

# ✅ Rápido - INSERT múltiplo
Model.insert_all(data)
```

**4. Desabilite logs temporariamente:**
```ruby
old_logger = ActiveRecord::Base.logger
ActiveRecord::Base.logger = nil

# Processar...

ActiveRecord::Base.logger = old_logger
```

## 💼 Casos de Uso Específicos

### Q: Como migrar dados de uma tabela para outra?

```ruby
namespace :migrate do
  desc "Migrate from old_table to new_table"
  task :to_new_table, [:confirmation] => :environment do |_, args|
    confirmation = args[:confirmation] == "true"

    puts "========== MIGRATION STARTED =========="

    ActsAsTenant.current_tenant = Tenant.find_genial_tenant
    dev_user = User.system_user

    old_records = OldModel.all
    errors = []
    migrated = 0

    ActiveRecord::Base.transaction do
      old_records.find_each do |old_record|
        next unless confirmation

        new_record = NewModel.new(
          # Map fields
          field1: old_record.old_field1,
          field2: old_record.old_field2,
          created_by: dev_user
        )

        if new_record.valid?
          new_record.save!

          # Link old to new
          old_record.update_column(:new_model_id, new_record.id)

          migrated += 1
          print "."
        else
          errors << {
            old_id: old_record.id,
            errors: new_record.errors.full_messages
          }
          print "e"
        end
      end

      if errors.any?
        puts "\nErrors found. Rolling back."
        raise ActiveRecord::Rollback
      end
    end

    unless confirmation
      puts "Dry-run. Run with [true] to migrate."
      return
    end

    puts "\n========== SUMMARY =========="
    puts "Total: #{old_records.count}"
    puts "Migrated: #{migrated}"
    puts "Errors: #{errors.count}"

    if errors.any?
      puts "\nError details:"
      errors.each { |e| puts "Old ID #{e[:old_id]}: #{e[:errors].join(', ')}" }
    end

    puts "========== FINISHED =========="
  end
end
```

### Q: Como fazer uma rake task que atualiza registros relacionados?

```ruby
namespace :update do
  desc "Update parent and all children"
  task :parent_and_children, [:confirmation] => :environment do |_, args|
    confirmation = args[:confirmation] == "true"

    ActsAsTenant.current_tenant = Tenant.find_genial_tenant
    dev_user = User.system_user

    parents = Parent.where(needs_update: true)
    updated_parents = 0
    updated_children = 0

    parents.find_each do |parent|
      next unless confirmation

      # Transaction para garantir que parent E children são atualizados juntos
      ActiveRecord::Base.transaction do
        parent.update!(
          status: "processed",
          processed_at: Time.current,
          updated_by: dev_user
        )
        updated_parents += 1

        parent.children.each do |child|
          child.update!(
            parent_status: parent.status,
            updated_by: dev_user
          )
          updated_children += 1
        end
      end

      print "."
    end

    puts "\n========== SUMMARY =========="
    puts "Updated parents: #{updated_parents}"
    puts "Updated children: #{updated_children}"
  end
end
```

### Q: Como criar uma rake task para gerar relatórios recorrentes?

```ruby
require "csv"

namespace :reports do
  desc "Generate monthly activity report"
  task monthly_activity: :environment do
    month = ENV["MONTH"]&.to_date || Date.current.beginning_of_month

    puts "========== GENERATING REPORT FOR #{month.strftime('%B %Y')} =========="

    ActsAsTenant.current_tenant = Tenant.find_genial_tenant

    # Coletar dados
    activities = Activity.where(
      created_at: month.beginning_of_month..month.end_of_month
    )

    # Gerar CSV
    csv_path = "tmp/reports/activity_#{month.strftime('%Y_%m')}.csv"
    FileUtils.mkdir_p(File.dirname(csv_path))

    CSV.open(csv_path, "w") do |csv|
      csv << ["Date", "User", "Activity Type", "Count"]

      activities
        .group(:date, :user_id, :activity_type)
        .count
        .each do |(date, user_id, type), count|
          user = User.find(user_id)
          csv << [date, user.name, type, count]
        end
    end

    puts "Report generated: #{csv_path}"
    puts "Total activities: #{activities.count}"
    puts "========== FINISHED =========="
  end
end

# Pode ser agendado no cron:
# 0 9 1 * * cd /app && rake reports:monthly_activity
```

### Q: Como fazer cleanup de dados antigos?

```ruby
namespace :cleanup do
  desc "Delete old records. Usage: rake cleanup:old_records[true,90]"
  task :old_records, [:confirmation, :days] => :environment do |_, args|
    confirmation = args[:confirmation] == "true"
    days = (args[:days] || 90).to_i

    cutoff_date = days.days.ago

    puts "========== CLEANUP OLD RECORDS =========="
    puts "Confirmation: #{confirmation}"
    puts "Cutoff date: #{cutoff_date.to_date} (#{days} days ago)"

    ActsAsTenant.current_tenant = Tenant.find_genial_tenant

    old_records = Model.where("created_at < ?", cutoff_date)

    puts "Found #{old_records.count} records to delete"

    unless confirmation
      puts "\nDry-run. Run with [true,90] to delete."
      puts "Sample records that would be deleted:"
      old_records.limit(5).each do |record|
        puts "  - ID #{record.id}, created #{record.created_at}"
      end
      return
    end

    deleted_count = old_records.delete_all

    puts "\n========== SUMMARY =========="
    puts "Deleted: #{deleted_count} records"
    puts "========== FINISHED =========="
  end
end
```

## 🔧 Manutenção

### Q: Como atualizar uma rake task existente?

**1. Adicione dry-run se não tiver:**
```ruby
# Antes
task update: :environment do
  Model.all.each { |m| m.update(field: value) }
end

# Depois
task :update, [:confirmation] => :environment do |_, args|
  confirmation = args[:confirmation] == "true"

  unless confirmation
    puts "Dry-run. Total to update: #{Model.count}"
    return
  end

  Model.all.each { |m| m.update(field: value) }
end
```

**2. Adicione error handling:**
```ruby
# Antes
Model.all.each { |m| m.update!(field: value) }

# Depois
errors = []
success = 0

Model.all.each do |m|
  begin
    m.update!(field: value)
    success += 1
    print "."
  rescue => e
    errors << { id: m.id, error: e.message }
    print "e"
  end
end

puts "\nSuccess: #{success}, Errors: #{errors.count}"
```

**3. Adicione summary:**
```ruby
puts "\n========== SUMMARY =========="
puts "Total: #{total}"
puts "Success: #{success}"
puts "Errors: #{errors.count}"
```

### Q: Quando deletar uma rake task antiga?

**Delete quando:**
- ✅ Task foi executada em produção
- ✅ Task era one-off (não recorrente)
- ✅ Passou 3+ meses desde execução
- ✅ Não há necessidade de re-executar

**Mantenha quando:**
- ❌ Task é recorrente (relatórios, cleanup)
- ❌ Task pode ser útil no futuro
- ❌ Task serve de exemplo/referência
- ❌ Menos de 1 mês desde execução

**Alternativa:** Mova para `lib/tasks/archive/` ao invés de deletar.

## 📚 Recursos Adicionais

### Q: Como testar uma rake task?

Não há uma forma padrão de testar rake tasks no projeto. Geralmente:

1. **Teste manual em desenvolvimento:**
   ```bash
   # Sempre comece com dry-run
   rake namespace:task[true]
   ```

2. **Verifique dados antes e depois:**
   ```ruby
   # No rails console
   Model.where(condition).count  # Antes
   # Roda rake
   Model.where(condition).count  # Depois
   ```

3. **Use transaction para testar:**
   ```ruby
   # No rails console
   ActiveRecord::Base.transaction do
     # Execute a lógica da rake task aqui
     raise ActiveRecord::Rollback  # Desfaz tudo
   end
   ```

### Q: Como documentar uma rake task?

```ruby
namespace :domain do
  desc <<~DESC
    Brief one-line description

    Extended description can go here explaining:
    - What this task does
    - When to use it
    - Parameters available

    Usage:
      DRY_RUN=1 rake domain:task_name
      rake domain:task_name[true,param2]

    Examples:
      rake domain:task_name[true,100]  # Process 100 records
  DESC

  task :task_name, [:confirmation, :param2] => :environment do |_, args|
    # Implementation
  end
end
```

### Q: Como listar todas as rake tasks?

```bash
# Todas as tasks
rake -T

# Tasks de um namespace
rake -T namespace

# Com descrições completas
rake -D
```

## ⚠️ Segurança

### Q: Como evitar executar rake tasks em produção por acidente?

```ruby
task dangerous_task: :environment do
  if Rails.env.production?
    puts "ERROR: This task cannot run in production"
    puts "If you really need to run this, set ALLOW_PRODUCTION=1"
    exit 1 unless ENV["ALLOW_PRODUCTION"] == "1"
  end

  # Task logic
end

# Usage em produção:
# ALLOW_PRODUCTION=1 rake dangerous_task
```

### Q: Como garantir que apenas certos ambientes podem rodar a task?

```ruby
task sensitive_task: :environment do
  allowed_envs = %w[development staging]

  unless allowed_envs.include?(Rails.env)
    puts "ERROR: Can only run in: #{allowed_envs.join(', ')}"
    puts "Current environment: #{Rails.env}"
    exit 1
  end

  # Task logic
end
```

### Q: Como adicionar confirmação extra para tasks perigosas?

```ruby
task :delete_all_data, [:confirm_text] => :environment do |_, args|
  expected = "DELETE_ALL_DATA"

  if args[:confirm_text] != expected
    puts "ERROR: Must confirm with exact text: #{expected}"
    puts "Usage: rake delete_all_data[#{expected}]"
    exit 1
  end

  # Dangerous operation
end

# Usage:
# rake delete_all_data[DELETE_ALL_DATA]
```
