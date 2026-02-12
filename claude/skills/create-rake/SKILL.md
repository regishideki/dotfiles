# Skill: Create Rake Tasks

Esta skill fornece orientações para criar rake tasks seguindo os padrões estabelecidos no projeto.

## Quando usar

- Criar tarefas de migração de dados
- Operações em lote (bulk operations)
- Importação/exportação de dados
- Tarefas administrativas pontuais
- Correções de dados

## Estrutura Básica

```ruby
namespace :domain do
  desc "Brief description of what this task does"
  task task_name: :environment do
    puts "========== STARTED TASK NAME =========="

    # Task implementation here

    puts "========== FINISHED TASK NAME =========="
  end
end
```

## Componentes Essenciais

### 1. User System

Para tarefas que criam/atualizam registros, sempre defina um usuário do sistema:

```ruby
dev_user = User.system_user

if dev_user.blank?
  puts "System user not found."
  exit 1
end
```

### 2. Multi-tenancy

Para tarefas que devem rodar em um tenant específico:

```ruby
ActsAsTenant.current_tenant = Tenant.find_genial_tenant
```

Para processar todos os tenants:

```ruby
Tenant.find_each do |tenant|
  ActsAsTenant.with_tenant(tenant) do
    # Task logic here
  end
end
```

### 3. Progress Indicators

Use progress indicators para feedback visual:

```ruby
data.each do |item|
  if process(item)
    print "."  # Success
  else
    print "e"  # Error
  end
end
puts "\n"  # New line after progress
```

Convenção:
- `.` = sucesso
- `e` = erro (minúsculo)
- `F` = falha (maiúsculo)
- `U` = would update (dry run)

### 4. Error Collection

Sempre acumule erros para reportar ao final:

```ruby
errors = []
items_not_found = []

data.each do |item|
  record = Model.find_by(id: item[:id])

  if record.blank?
    items_not_found << item[:id]
    print "e"
    next
  end

  begin
    record.update!(attributes)
    print "."
  rescue ActiveRecord::RecordInvalid => e
    errors << { id: item[:id], error: e.message }
    print "e"
  end
end

# Report errors at the end
puts "\n========== ERRORS =========="
puts "Items not found: #{items_not_found.count}"
puts items_not_found.join("\n") if items_not_found.any?

puts "\nUpdate errors: #{errors.count}"
puts errors.join("\n") if errors.any?
```

### 5. Summary

Sempre inclua um resumo ao final:

```ruby
puts "\n========== SUMMARY =========="
puts "Total processed: #{total_count}"
puts "Successful: #{success_count}"
puts "Errors: #{error_count}"
puts "Skipped: #{skipped_count}"
```

## Padrões Avançados

### 1. DRY_RUN Mode

Para tarefas destrutivas ou críticas, implemente modo dry run:

**Via ENV variable:**

```ruby
dry_run = ENV["DRY_RUN"].to_s == "1"

puts "========== STARTED TASK NAME =========="
puts "DRY_RUN: #{dry_run}"

if dry_run
  puts "[DRY] Would process #{records.count} records"
  # Show what would happen without actually doing it
else
  # Actually perform the operation
end

puts "\nTo execute for real, run: DRY_RUN=0 rake namespace:task_name"
```

**Via task argument:**

```ruby
task :task_name, [:confirmation] => :environment do |_, args|
  confirmation = args[:confirmation] == "true"

  puts "Confirmation: #{confirmation}"

  unless confirmation
    puts "Dry-run mode. Re-run with confirmation=true to apply changes."
    # Preview mode
    return
  end

  # Execute actual changes
end

# Usage: rake namespace:task_name[true]
```

**Generating reports in DRY_RUN:**

```ruby
if dry_run
  csv_path = "tmp/reports/task_name_#{Date.current}.csv"
  FileUtils.mkdir_p(File.dirname(csv_path))

  CSV.open(csv_path, "w") do |csv|
    csv << ["header1", "header2", "header3"]
    results.each { |row| csv << row }
  end

  puts "[DRY RUN] Report generated at #{csv_path}"
end
```

### 2. BYPASS_ERRORS

Para ambientes não produtivos onde você precisa forçar a execução mesmo com erros:

```ruby
task :task_name, [:confirmation, :bypass_errors] => :environment do |_, args|
  confirmation = args[:confirmation] == "true"
  bypass_errors = args[:bypass_errors] == "true"

  puts "Bypass errors: #{bypass_errors}"

  # Validate data
  validation_errors = validate_data(data)

  if validation_errors.any? && !bypass_errors
    puts "Validation errors found. Aborting (use bypass_errors=true to force)."
    puts validation_errors.join("\n")
    return
  end

  if validation_errors.any? && bypass_errors
    puts "WARNING: Bypassing #{validation_errors.count} validation errors"
  end

  # Proceed with execution
end

# Usage: rake namespace:task_name[true,true]
```

### 3. Transactions

**Quando usar:**
- Operações que devem ser atômicas (tudo ou nada)
- Múltiplos registros relacionados
- Dados críticos onde rollback é necessário

**Quando NÃO usar:**
- Operações que podem falhar parcialmente sem problemas
- Importações grandes onde progresso parcial é aceitável
- Quando a operação pode ser retomada facilmente

**Com ActiveRecord:**

```ruby
errors = []

ActiveRecord::Base.transaction do
  data.each do |item|
    record = Model.create(item)

    if record.valid?
      record.save
      print "."
    else
      errors << record.errors.full_messages
      print "F"
    end
  end

  # Rollback if any errors
  if errors.any?
    puts "\n#{errors.count} errors found. Rolling back transaction."
    raise ActiveRecord::Rollback
  end
end

if errors.any?
  puts "\nTransaction rolled back. Fix errors and try again."
  puts errors.join("\n")
end
```

**Com UseCases:**

UseCases não lançam exceptions por padrão, apenas retornam `ctx.success?`. Para usar em transactions, você precisa lançar exception manualmente:

```ruby
ActiveRecord::Base.transaction do
  data.each do |item|
    ctx = SomeNamespace::UseCases::DoSomething.call(
      params: { data: item },
      current_user: dev_user
    )

    unless ctx.success?
      # UseCase failed - raise exception to trigger rollback
      error_msg = ctx[:errors].map { |e| "#{e[:code]}: #{e[:message]}" }.join(", ")
      raise StandardError, error_msg
    end

    print "."
  end
end
```

**Sem transaction (progresso parcial aceitável):**

```ruby
# No transaction block - each operation commits independently
success_count = 0
error_count = 0

data.each do |item|
  begin
    record = Model.create!(item)
    success_count += 1
    print "."
  rescue ActiveRecord::RecordInvalid => e
    error_count += 1
    errors << { item: item, error: e.message }
    print "e"
  end
end

puts "\nProcessed with partial success:"
puts "Success: #{success_count}"
puts "Errors: #{error_count}"
```

### 4. File Reading

Sempre valide se o arquivo existe:

```ruby
file_path = ENV["FILE_PATH"] || "lib/tasks/data/import_data.csv"

unless File.exist?(file_path)
  puts "\nFILE NOT FOUND: #{file_path}"
  exit 1
end

CSV.foreach(file_path, headers: true) do |row|
  # Process row
end
```

Para JSON:

```ruby
if File.exist?(file_path)
  data = JSON.parse(File.read(file_path))
else
  puts "\nFILE NOT FOUND: #{file_path}"
  exit 1
end
```

### 5. Argumentos Configuráveis

```ruby
task :task_name, [:arg1, :arg2] => :environment do |_, args|
  # With defaults
  arg1 = args[:arg1] || "default_value"
  arg2 = args[:arg2].to_i

  puts "Arg1: #{arg1}"
  puts "Arg2: #{arg2}"
end

# Usage: rake namespace:task_name[value1,42]
```

Via ENV:

```ruby
task task_name: :environment do
  value = ENV.fetch("VALUE", "default")
  number = ENV.fetch("NUMBER", "10").to_i

  puts "VALUE: #{value}"
  puts "NUMBER: #{number}"
end

# Usage: VALUE=something NUMBER=20 rake namespace:task_name
```

## Exemplos Completos

### Exemplo 1: Rake Task Simples (sem controles especiais)

Para operações simples e facilmente reversíveis:

```ruby
namespace :update do
  desc "Update field X on all records"
  task update_field_x: :environment do
    puts "========== STARTED UPDATING FIELD X =========="

    ActsAsTenant.current_tenant = Tenant.find_genial_tenant
    dev_user = User.system_user

    records = Model.where(field_x: nil)
    total = records.count
    updated = 0

    puts "Found #{total} records to update"

    records.find_each do |record|
      record.update(field_x: "new_value", updated_by: dev_user)
      updated += 1
      print "."
    end

    puts "\n========== SUMMARY =========="
    puts "Updated: #{updated}/#{total}"
    puts "========== FINISHED =========="
  end
end
```

### Exemplo 2: Rake Task com DRY_RUN

Para operações destrutivas ou críticas:

```ruby
namespace :finance do
  desc "Adjust pricing for all collaborators"
  task adjust_pricing: :environment do
    dry_run = ENV["DRY_RUN"].to_s == "1"
    percentage = ENV.fetch("PERCENTAGE", "10").to_f / 100

    puts "========== STARTED PRICING ADJUSTMENT =========="
    puts "DRY_RUN: #{dry_run}"
    puts "PERCENTAGE: #{(percentage * 100).to_f}%"

    ActsAsTenant.current_tenant = Tenant.find_genial_tenant
    dev_user = User.system_user

    collaborators = People::Collaborator.active
    summary = Hash.new(0)
    csv_rows = []

    collaborators.find_each do |collaborator|
      current_price = collaborator.hourly_rate
      new_price = (current_price * (1 + percentage)).round(2)

      if dry_run
        summary["would_update"] += 1
        csv_rows << [collaborator.id, collaborator.name, current_price, new_price]
        print "U"
      else
        if collaborator.update(hourly_rate: new_price, updated_by: dev_user)
          summary["updated"] += 1
          print "."
        else
          summary["failed"] += 1
          print "e"
        end
      end
    end

    if dry_run
      csv_path = "tmp/pricing_adjustment_preview.csv"
      FileUtils.mkdir_p(File.dirname(csv_path))
      CSV.open(csv_path, "w") do |csv|
        csv << ["ID", "Name", "Current Price", "New Price"]
        csv_rows.each { |row| csv << row }
      end
      puts "\n[DRY RUN] Preview generated at #{csv_path}"
      puts "\nTo execute: DRY_RUN=0 rake finance:adjust_pricing"
    end

    puts "\n========== SUMMARY =========="
    summary.each { |k, v| puts "#{k}: #{v}" }
    puts "========== FINISHED =========="
  end
end
```

### Exemplo 3: Rake Task com Transaction e Bypass Errors

Para migrações complexas onde atomicidade é importante:

```ruby
require "csv"

namespace :migrate do
  desc "Migrate legacy data to new structure"
  task :legacy_data, [:confirmation, :bypass_errors] => :environment do |_, args|
    confirmation = args[:confirmation] == "true"
    bypass_errors = args[:bypass_errors] == "true"

    puts "========== STARTED LEGACY DATA MIGRATION =========="
    puts "Confirmation: #{confirmation}"
    puts "Bypass errors: #{bypass_errors}"

    ActsAsTenant.current_tenant = Tenant.find_genial_tenant
    dev_user = User.system_user

    file_path = "lib/tasks/data/legacy_data.csv"
    unless File.exist?(file_path)
      puts "FILE NOT FOUND: #{file_path}"
      exit 1
    end

    # Phase 1: Validate data
    validation_errors = []
    data_to_migrate = []

    CSV.foreach(file_path, headers: true) do |row|
      old_record = OldModel.find_by(id: row["old_id"])

      if old_record.blank?
        validation_errors << { row: row.to_h, reason: "Old record not found" }
        next
      end

      data_to_migrate << {
        old_record: old_record,
        new_attributes: {
          name: row["name"],
          value: row["value"]
        }
      }
    end

    puts "\n========== VALIDATION =========="
    puts "Valid records: #{data_to_migrate.count}"
    puts "Validation errors: #{validation_errors.count}"

    if validation_errors.any?
      puts "\nError details:"
      validation_errors.each { |e| puts "  - #{e[:reason]}: #{e[:row]}" }

      unless bypass_errors
        puts "\nAborting. Use bypass_errors=true to force migration with errors."
        return
      end

      puts "\nWARNING: Bypassing #{validation_errors.count} validation errors"
    end

    unless confirmation
      puts "\nDry-run mode. Run with confirmation=true to execute."
      return
    end

    # Phase 2: Execute migration
    errors = []
    success_count = 0

    ActiveRecord::Base.transaction do
      data_to_migrate.each do |data|
        begin
          new_record = NewModel.create!(
            data[:new_attributes].merge(
              created_by: dev_user,
              updated_by: dev_user
            )
          )

          # Link old to new
          data[:old_record].update!(new_model_id: new_record.id)

          success_count += 1
          print "."
        rescue ActiveRecord::RecordInvalid => e
          errors << {
            old_id: data[:old_record].id,
            error: e.message
          }
          print "e"
        end
      end

      if errors.any?
        puts "\n\nErrors found during migration. Rolling back transaction."
        raise ActiveRecord::Rollback
      end
    end

    puts "\n========== SUMMARY =========="
    puts "Total records: #{data_to_migrate.count}"
    puts "Successfully migrated: #{success_count}"
    puts "Errors: #{errors.count}"

    if errors.any?
      puts "\nError details:"
      errors.each { |e| puts "  Old ID #{e[:old_id]}: #{e[:error]}" }
    end

    puts "========== FINISHED =========="
  end
end

# Usage:
# Dry run: rake migrate:legacy_data
# With validation: rake migrate:legacy_data[true]
# Bypass errors: rake migrate:legacy_data[true,true]
```

### Exemplo 4: Rake Task com UseCase em Transaction

Para operações que usam UseCases e precisam de rollback:

```ruby
namespace :clinical_case do
  desc "Add clinicians from CSV"
  task :add_clinicians, [:file_path, :confirmation] => :environment do |_, args|
    confirmation = args[:confirmation] == "true"
    file_path = args[:file_path] || "lib/tasks/data/add_clinicians.csv"

    puts "========== STARTED ADDING CLINICIANS =========="
    puts "File: #{file_path}"
    puts "Confirmation: #{confirmation}"

    unless File.exist?(file_path)
      puts "FILE NOT FOUND: #{file_path}"
      exit 1
    end

    ActsAsTenant.current_tenant = Tenant.find_genial_tenant
    dev_user = User.system_user

    errors = []
    success_count = 0

    # UseCases don't raise exceptions, so we need to track errors
    # and decide if we want to use transactions

    # Option 1: Without transaction (partial success OK)
    CSV.foreach(file_path, headers: true) do |row|
      next unless confirmation

      ctx = ClinicalCases::UseCases::AddClinician.call(
        params: {
          clinical_case_id: row["clinical_case_id"],
          clinician_id: row["clinician_id"],
          clinician_role: row["role"]
        },
        current_user: dev_user
      )

      if ctx.success?
        success_count += 1
        print "."
      else
        errors << {
          row: row.to_h,
          errors: ctx[:errors]
        }
        print "e"
      end
    end

    # Option 2: With transaction (all-or-nothing)
    # ActiveRecord::Base.transaction do
    #   CSV.foreach(file_path, headers: true) do |row|
    #     next unless confirmation
    #
    #     ctx = ClinicalCases::UseCases::AddClinician.call(
    #       params: { ... },
    #       current_user: dev_user
    #     )
    #
    #     unless ctx.success?
    #       # Force rollback by raising exception
    #       error_msg = ctx[:errors].map { |e| "#{e[:code]}: #{e[:message]}" }.join(", ")
    #       raise StandardError, "Failed to add clinician: #{error_msg}"
    #     end
    #
    #     print "."
    #   end
    # end

    unless confirmation
      puts "\nDry-run mode. Run with confirmation=true to execute."
      return
    end

    puts "\n========== SUMMARY =========="
    puts "Successful: #{success_count}"
    puts "Errors: #{errors.count}"

    if errors.any?
      puts "\nError details:"
      errors.each do |e|
        puts "Row: #{e[:row]}"
        puts "Errors: #{e[:errors]}"
        puts "---"
      end
    end

    puts "========== FINISHED =========="
  end
end
```

### Exemplo 5: Rake Task Iterando Múltiplos Tenants

```ruby
namespace :multi_tenant do
  desc "Process all tenants"
  task process_all: :environment do
    puts "========== STARTED PROCESSING ALL TENANTS =========="

    dev_user = User.system_user
    summary_by_tenant = {}

    Tenant.find_each do |tenant|
      ActsAsTenant.with_tenant(tenant) do
        puts "\nProcessing tenant: #{tenant.name} (#{tenant.id})"

        records = Model.where(some_condition: true)
        processed = 0

        records.find_each do |record|
          record.update(field: "value", updated_by: dev_user)
          processed += 1
          print "."
        end

        summary_by_tenant[tenant.name] = {
          total: records.count,
          processed: processed
        }
      end
    end

    puts "\n\n========== SUMMARY BY TENANT =========="
    summary_by_tenant.each do |tenant_name, stats|
      puts "#{tenant_name}: #{stats[:processed]}/#{stats[:total]}"
    end

    puts "========== FINISHED =========="
  end
end
```

## Checklist

Antes de criar uma rake task, pergunte-se:

- [ ] **Reversibilidade**: A operação é fácil de reverter? Se não, use DRY_RUN
- [ ] **Atomicidade**: Precisa ser tudo-ou-nada? Se sim, use transaction
- [ ] **Validação**: Há validações complexas? Considere bypass_errors para dev/staging
- [ ] **Progresso parcial**: É aceitável sucesso parcial? Se sim, pode não precisar de transaction
- [ ] **Multi-tenant**: Precisa rodar em múltiplos tenants ou apenas um?
- [ ] **UseCases**: Se usar UseCases em transaction, lembre de lançar exceptions manualmente
- [ ] **Erros**: Como os erros serão reportados? Acumule-os em arrays
- [ ] **Progress**: Usuário precisa ver progresso? Use print "."
- [ ] **Summary**: Sempre inclua um resumo ao final

## Guidelines de Transactions

| Cenário | Use Transaction? | Motivo |
|---------|-----------------|--------|
| Migração de dados críticos | ✅ Sim | Rollback necessário se algo falhar |
| Importação de milhares de registros | ❌ Não | Progresso parcial é aceitável |
| Criação de registros relacionados | ✅ Sim | Consistência entre tabelas |
| Atualização de um campo simples | ❌ Não | Cada update é independente |
| Operação com UseCases | ⚠️ Depende | Lembre de lançar exceptions manualmente |
| Operação facilmente reversível | ❌ Não | Não precisa de rollback |

## Boas Práticas

1. **Sempre teste em dry-run primeiro**
2. **Use progress indicators para feedback visual**
3. **Acumule erros e mostre ao final, não durante**
4. **Inclua sempre um summary**
5. **Valide dados antes de processar quando possível**
6. **Use namespaces descritivos**
7. **Documente com `desc` claro**
8. **Para operations destrutivas, exija confirmação explícita**
9. **Gere relatórios/CSVs em dry-run para review**
10. **Use `User.system_user` ao invés de hardcoded user_id**

## Anti-patterns a Evitar

❌ **Usar transaction para tudo**
```ruby
# Desnecessário para operações independentes
ActiveRecord::Base.transaction do
  1000.times { |i| Model.create!(name: "Item #{i}") }
end
```

❌ **Não reportar erros**
```ruby
# Sem feedback de erros
records.each { |r| r.update(field: value) rescue nil }
```

❌ **Não usar dry-run para operações críticas**
```ruby
# Perigoso - deleta dados sem confirmação
task :delete_old_records do
  OldRecord.where("created_at < ?", 1.year.ago).delete_all
end
```

❌ **Usar UseCase em transaction sem exception**
```ruby
# Não vai fazer rollback!
ActiveRecord::Base.transaction do
  ctx = UseCase.call(params: {})
  # ctx.success? == false não causa rollback!
end
```

✅ **Correto:**
```ruby
ActiveRecord::Base.transaction do
  ctx = UseCase.call(params: {})
  unless ctx.success?
    error_msg = ctx[:errors].map { |e| e[:message] }.join(", ")
    raise StandardError, error_msg
  end
end
```

## Localização de Arquivos

- Rake tasks devem ficar em `lib/tasks/`
- Use subdiretórios para organizar: `lib/tasks/finance/`, `lib/tasks/operational/`
- Arquivos de dados em `lib/tasks/data/`
- Nomeie o arquivo com o namespace: `lib/tasks/namespace/task_name.rake`
