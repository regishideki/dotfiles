# Checklist Rápido para Rake Tasks

Use este checklist ao criar uma nova rake task.

## ✅ Estrutura Básica

```ruby
namespace :domain do
  desc "Clear description"
  task task_name: :environment do
    puts "========== STARTED =========="

    # Implementation

    puts "========== FINISHED =========="
  end
end
```

- [ ] Namespace apropriado
- [ ] Descrição clara com `desc`
- [ ] Mensagens de início/fim
- [ ] Task usa `:environment`

## ✅ Setup Inicial

```ruby
ActsAsTenant.current_tenant = Tenant.find_genial_tenant
dev_user = User.system_user

if dev_user.blank?
  puts "System user not found."
  exit 1
end
```

- [ ] Definir tenant (se necessário)
- [ ] Definir user system
- [ ] Validar pré-requisitos

## ✅ Controles Opcionais

### Precisa de confirmação? (operação crítica/destrutiva)

```ruby
# Via args
task :name, [:confirmation] => :environment do |_, args|
  confirmation = args[:confirmation] == "true"
  unless confirmation
    puts "Dry-run mode. Run with [true] to execute."
    return
  end
end

# Via ENV
dry_run = ENV["DRY_RUN"].to_s == "1"
```

- [ ] DRY_RUN via ENV ou args[:confirmation]
- [ ] Mostrar preview em dry run
- [ ] Mensagem clara de como executar

### Precisa de bypass de erros? (para dev/staging)

```ruby
task :name, [:confirmation, :bypass_errors] => :environment do |_, args|
  bypass_errors = args[:bypass_errors] == "true"

  if validation_errors.any? && !bypass_errors
    puts "Errors found. Use bypass_errors=true to force."
    return
  end
end
```

- [ ] Parâmetro bypass_errors
- [ ] Validação antes de processar
- [ ] Mensagem clara quando bloquear

### Precisa de transaction?

**Use SE:**
- ✅ Operação deve ser atômica (tudo ou nada)
- ✅ Dados críticos que precisam de rollback
- ✅ Múltiplos registros relacionados

**NÃO use SE:**
- ❌ Progresso parcial é aceitável
- ❌ Operação facilmente reversível
- ❌ Importação de milhares de registros independentes

```ruby
ActiveRecord::Base.transaction do
  data.each do |item|
    # Process item
    # If error, collect and raise ActiveRecord::Rollback
  end

  if errors.any?
    raise ActiveRecord::Rollback
  end
end
```

- [ ] Transaction se necessário (nem sempre!)
- [ ] `raise ActiveRecord::Rollback` se houver erros
- [ ] Para UseCases: lançar exception manualmente

## ✅ Processamento

### Progress Indicators

```ruby
data.each do |item|
  if success
    print "."
  else
    print "e"
  end
end
puts "\n"
```

- [ ] Progress indicators (`.` = sucesso, `e` = erro)
- [ ] Newline após progress

### Error Handling

```ruby
errors = []
not_found = []

data.each do |item|
  record = Model.find_by(id: item[:id])

  if record.blank?
    not_found << item[:id]
    next
  end

  begin
    record.update!(attributes)
  rescue ActiveRecord::RecordInvalid => e
    errors << { id: item[:id], error: e.message }
  end
end
```

- [ ] Acumular erros em arrays
- [ ] Reportar erros ao final (não durante)
- [ ] Separar tipos de erro (not_found, validation, etc)

### UseCase em Transaction

```ruby
# ❌ ERRADO - não causa rollback
ActiveRecord::Base.transaction do
  ctx = UseCase.call(params: {})
  # ctx.success? == false NÃO FAZ ROLLBACK!
end

# ✅ CORRETO - lança exception
ActiveRecord::Base.transaction do
  ctx = UseCase.call(params: {})
  unless ctx.success?
    error_msg = ctx[:errors].map { |e| e[:message] }.join(", ")
    raise StandardError, error_msg
  end
end
```

- [ ] Se usar UseCase em transaction, lançar exception manualmente

## ✅ Leitura de Arquivos

```ruby
file_path = args[:file_path] || "lib/tasks/data/file.csv"

unless File.exist?(file_path)
  puts "FILE NOT FOUND: #{file_path}"
  exit 1
end

CSV.foreach(file_path, headers: true) do |row|
  # Process row
end
```

- [ ] Validar se arquivo existe
- [ ] `exit 1` se não existir
- [ ] CSV com headers: true

## ✅ Summary/Relatório

```ruby
puts "\n========== SUMMARY =========="
puts "Total: #{total}"
puts "Successful: #{success_count}"
puts "Errors: #{error_count}"

if errors.any?
  puts "\nError details:"
  errors.each { |e| puts "  #{e}" }
end

puts "========== FINISHED =========="
```

- [ ] Summary sempre presente
- [ ] Contadores de sucesso/erro
- [ ] Detalhes dos erros se houver

## ✅ Geração de Relatórios

```ruby
if dry_run
  csv_path = "tmp/reports/task_name_#{Date.current}.csv"
  FileUtils.mkdir_p(File.dirname(csv_path))

  CSV.open(csv_path, "w") do |csv|
    csv << ["Header1", "Header2"]
    data.each { |row| csv << row }
  end

  puts "[DRY RUN] Report: #{csv_path}"
end
```

- [ ] Gerar CSV em dry run para review
- [ ] Criar diretório se não existir
- [ ] Incluir timestamp no nome

## 🚫 Anti-patterns a Evitar

- [ ] ❌ Transaction desnecessária para operações independentes
- [ ] ❌ Rescue sem reportar erro (`rescue nil`)
- [ ] ❌ Operação destrutiva sem dry-run
- [ ] ❌ UseCase em transaction sem exception
- [ ] ❌ Não validar arquivos antes de ler
- [ ] ❌ Hardcoded user_id (use `User.system_user`)
- [ ] ❌ Sem feedback de progresso
- [ ] ❌ Sem summary ao final

## 📁 Localização

- [ ] Rake task em `lib/tasks/`
- [ ] Usar subdiretórios: `lib/tasks/finance/`, `lib/tasks/operational/`
- [ ] Dados em `lib/tasks/data/`
- [ ] Nome do arquivo: `namespace/task_name.rake`

## 🎯 Decision Tree Rápido

### Precisa de DRY_RUN?
- Operação é destrutiva? → **SIM**
- Operação é crítica? → **SIM**
- Operação é facilmente reversível? → NÃO

### Precisa de BYPASS_ERRORS?
- Validações complexas? → **SIM**
- Pode rodar em staging? → **SIM**
- Só produção? → NÃO

### Precisa de TRANSACTION?
- Deve ser tudo-ou-nada? → **SIM**
- Dados relacionados? → **SIM**
- Progresso parcial OK? → NÃO
- Milhares de registros independentes? → NÃO

### Tipo de Error Handling?
- ActiveRecord direto? → `begin/rescue ActiveRecord::RecordInvalid`
- UseCase sem transaction? → Verificar `ctx.success?`
- UseCase com transaction? → Lançar exception se `!ctx.success?`

## ✅ Template Completo

```ruby
require "csv"

namespace :domain do
  desc "Clear description of what this does"
  task :task_name, [:confirmation, :bypass_errors] => :environment do |_, args|
    # 1. Parse arguments
    confirmation = args[:confirmation] == "true"
    bypass_errors = args[:bypass_errors] == "true"

    # 2. Setup
    puts "========== STARTED TASK NAME =========="
    puts "Confirmation: #{confirmation}"
    puts "Bypass errors: #{bypass_errors}"

    ActsAsTenant.current_tenant = Tenant.find_genial_tenant
    dev_user = User.system_user

    if dev_user.blank?
      puts "System user not found."
      exit 1
    end

    # 3. Load and validate data
    file_path = "lib/tasks/data/file.csv"
    unless File.exist?(file_path)
      puts "FILE NOT FOUND: #{file_path}"
      exit 1
    end

    validation_errors = []
    valid_data = []

    CSV.foreach(file_path, headers: true) do |row|
      # Validate row
      if invalid?(row)
        validation_errors << { row: row.to_h, reason: "..." }
        next
      end

      valid_data << row
    end

    # 4. Check validation errors
    puts "\n========== VALIDATION =========="
    puts "Valid: #{valid_data.count}"
    puts "Errors: #{validation_errors.count}"

    if validation_errors.any? && !bypass_errors
      puts "Validation errors found. Use bypass_errors=true to force."
      return
    end

    unless confirmation
      puts "\nDry-run mode. Run with confirmation=true to execute."
      return
    end

    # 5. Process
    errors = []
    success_count = 0

    # Use transaction if needed
    # ActiveRecord::Base.transaction do
      valid_data.each do |item|
        begin
          # Process item
          process(item)
          success_count += 1
          print "."
        rescue => e
          errors << { item: item, error: e.message }
          print "e"
        end
      end

      # If using transaction:
      # if errors.any?
      #   raise ActiveRecord::Rollback
      # end
    # end

    # 6. Summary
    puts "\n\n========== SUMMARY =========="
    puts "Total: #{valid_data.count}"
    puts "Successful: #{success_count}"
    puts "Validation errors: #{validation_errors.count}"
    puts "Processing errors: #{errors.count}"

    if errors.any?
      puts "\nError details:"
      errors.each { |e| puts "  #{e[:error]}" }
    end

    puts "========== FINISHED =========="
  end
end

# Usage:
# Dry run: rake domain:task_name
# Execute: rake domain:task_name[true]
# With bypass: rake domain:task_name[true,true]
```

## 🏁 Antes de Executar

- [ ] Testei em dry-run primeiro?
- [ ] Revisei o preview/relatório?
- [ ] Fiz backup se necessário?
- [ ] Validei em dev/staging primeiro?
- [ ] Entendo o que vai acontecer?
- [ ] Sei como reverter se necessário?
