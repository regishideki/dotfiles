# Exemplos de Rake Tasks por Caso de Uso

## 1. Migração Simples de Dados

**Cenário**: Preencher um campo novo em registros existentes

```ruby
namespace :backfill do
  desc "Backfill tenant_id for records with NULL values"
  task tenant_id: :environment do
    puts "========== STARTED BACKFILLING TENANT_ID =========="

    genial = Tenant.find_genial_tenant
    unless genial
      puts "Error: Genial tenant not found"
      exit 1
    end

    records = Model.where(tenant_id: nil)
    total = records.count

    puts "Found #{total} records to update"

    updated = 0
    records.find_each do |record|
      record.update_column(:tenant_id, genial.id)
      updated += 1
      print "."
    end

    puts "\n========== SUMMARY =========="
    puts "Updated: #{updated}/#{total}"
    puts "========== FINISHED =========="
  end
end
```

## 2. Importação de CSV

**Cenário**: Importar dados de arquivo CSV

```ruby
require "csv"

namespace :import do
  desc "Import data from CSV file"
  task :from_csv, [:file_path, :confirmation] => :environment do |_, args|
    file_path = args[:file_path] || "lib/tasks/data/import.csv"
    confirmation = args[:confirmation] == "true"

    puts "========== STARTED CSV IMPORT =========="
    puts "File: #{file_path}"
    puts "Confirmation: #{confirmation}"

    unless File.exist?(file_path)
      puts "FILE NOT FOUND: #{file_path}"
      exit 1
    end

    ActsAsTenant.current_tenant = Tenant.find_genial_tenant
    dev_user = User.system_user

    errors = []
    imported = 0

    CSV.foreach(file_path, headers: true) do |row|
      unless confirmation
        puts "Would import: #{row.to_h}"
        next
      end

      begin
        Model.create!(
          name: row["name"],
          value: row["value"],
          created_by: dev_user
        )
        imported += 1
        print "."
      rescue ActiveRecord::RecordInvalid => e
        errors << { row: row.to_h, error: e.message }
        print "e"
      end
    end

    unless confirmation
      puts "\nDry-run mode. Run with confirmation=true to import."
      return
    end

    puts "\n========== SUMMARY =========="
    puts "Imported: #{imported}"
    puts "Errors: #{errors.count}"

    if errors.any?
      puts "\nError details:"
      errors.each { |e| puts "#{e[:row]} - #{e[:error]}" }
    end

    puts "========== FINISHED =========="
  end
end

# Usage: rake import:from_csv[lib/tasks/data/file.csv,true]
```

## 3. Operação em Lote com Dry Run

**Cenário**: Atualizar preços com aumento percentual

```ruby
namespace :pricing do
  desc "Apply percentage increase to all prices"
  task increase: :environment do
    dry_run = ENV["DRY_RUN"].to_s == "1"
    percentage = ENV.fetch("PERCENTAGE", "10").to_f / 100

    puts "========== STARTED PRICE INCREASE =========="
    puts "DRY_RUN: #{dry_run}"
    puts "PERCENTAGE: #{(percentage * 100).to_f}%"

    ActsAsTenant.current_tenant = Tenant.find_genial_tenant
    dev_user = User.system_user

    pricings = Finance::Pricing.active
    summary = { would_update: 0, updated: 0, errors: 0 }
    preview_data = []

    pricings.find_each do |pricing|
      old_price = pricing.amount
      new_price = (old_price * (1 + percentage)).round(2)

      if dry_run
        summary[:would_update] += 1
        preview_data << {
          id: pricing.id,
          old_price: old_price,
          new_price: new_price,
          difference: new_price - old_price
        }
        print "U"
      else
        if pricing.update(amount: new_price, updated_by: dev_user)
          summary[:updated] += 1
          print "."
        else
          summary[:errors] += 1
          print "e"
        end
      end
    end

    if dry_run
      puts "\n\n[DRY RUN] Preview of changes:"
      preview_data.first(10).each do |item|
        puts "ID #{item[:id]}: #{item[:old_price]} -> #{item[:new_price]} (+#{item[:difference]})"
      end
      puts "... and #{preview_data.count - 10} more" if preview_data.count > 10

      puts "\nTo execute: DRY_RUN=0 PERCENTAGE=10 rake pricing:increase"
    end

    puts "\n========== SUMMARY =========="
    summary.each { |k, v| puts "#{k}: #{v}" }
    puts "========== FINISHED =========="
  end
end

# Usage:
# Preview: DRY_RUN=1 PERCENTAGE=5 rake pricing:increase
# Execute: DRY_RUN=0 PERCENTAGE=5 rake pricing:increase
```

## 4. Migração com Transaction e Validação

**Cenário**: Migrar dados complexos com rollback

```ruby
namespace :migrate do
  desc "Migrate legacy contracts to new structure"
  task :contracts, [:confirmation, :bypass_errors] => :environment do |_, args|
    confirmation = args[:confirmation] == "true"
    bypass_errors = args[:bypass_errors] == "true"

    puts "========== STARTED CONTRACT MIGRATION =========="
    puts "Confirmation: #{confirmation}"
    puts "Bypass errors: #{bypass_errors}"

    ActsAsTenant.current_tenant = Tenant.find_genial_tenant
    dev_user = User.system_user

    # Phase 1: Validation
    legacy_contracts = LegacyContract.all
    validation_errors = []
    valid_data = []

    legacy_contracts.each do |legacy|
      child = People::Child.find_by(legacy_id: legacy.child_id)

      if child.blank?
        validation_errors << {
          legacy_id: legacy.id,
          reason: "Child not found"
        }
        next
      end

      if legacy.start_date.blank?
        validation_errors << {
          legacy_id: legacy.id,
          reason: "Missing start_date"
        }
        next
      end

      valid_data << {
        legacy: legacy,
        child: child
      }
    end

    puts "\n========== VALIDATION =========="
    puts "Valid contracts: #{valid_data.count}"
    puts "Validation errors: #{validation_errors.count}"

    if validation_errors.any?
      puts "\nValidation errors:"
      validation_errors.each { |e| puts "  Legacy ID #{e[:legacy_id]}: #{e[:reason]}" }

      unless bypass_errors
        puts "\nAborting. Use bypass_errors=true to continue with valid records only."
        return
      end

      puts "\nWARNING: Bypassing #{validation_errors.count} errors. Processing #{valid_data.count} valid records."
    end

    unless confirmation
      puts "\nDry-run mode. Run with confirmation=true to migrate."
      return
    end

    # Phase 2: Migration with transaction
    errors = []
    migrated = 0

    ActiveRecord::Base.transaction do
      valid_data.each do |data|
        contract = People::Contract.new(
          child: data[:child],
          start_date: data[:legacy].start_date,
          contracting_model: data[:legacy].contracting_model,
          created_by: dev_user,
          updated_by: dev_user
        )

        if contract.valid?
          contract.save
          data[:legacy].update!(migrated: true, new_contract_id: contract.id)
          migrated += 1
          print "."
        else
          errors << {
            legacy_id: data[:legacy].id,
            errors: contract.errors.full_messages
          }
          print "e"
        end
      end

      if errors.any?
        puts "\n\nErrors during migration. Rolling back."
        raise ActiveRecord::Rollback
      end
    end

    puts "\n========== SUMMARY =========="
    puts "Total legacy contracts: #{legacy_contracts.count}"
    puts "Valid for migration: #{valid_data.count}"
    puts "Successfully migrated: #{migrated}"
    puts "Validation errors: #{validation_errors.count}"
    puts "Migration errors: #{errors.count}"

    if errors.any?
      puts "\nMigration error details:"
      errors.each { |e| puts "  Legacy ID #{e[:legacy_id]}: #{e[:errors].join(', ')}" }
    end

    puts "========== FINISHED =========="
  end
end

# Usage:
# Dry run: rake migrate:contracts
# Execute: rake migrate:contracts[true]
# Bypass validation: rake migrate:contracts[true,true]
```

## 5. Operação com UseCase

**Cenário**: Cancelar sessões usando UseCase

```ruby
namespace :sessions do
  desc "Cancel sessions by IDs from file"
  task :cancel_from_file, [:file_path] => :environment do |_, args|
    file_path = args[:file_path] || "lib/tasks/data/sessions_to_cancel.txt"

    puts "========== STARTED CANCELLING SESSIONS =========="
    puts "File: #{file_path}"

    unless File.exist?(file_path)
      puts "FILE NOT FOUND: #{file_path}"
      exit 1
    end

    ActsAsTenant.current_tenant = Tenant.find_genial_tenant
    dev_user = User.system_user

    session_ids = File.readlines(file_path).map(&:strip).reject(&:blank?)
    puts "Found #{session_ids.count} sessions to cancel"

    cancelled = []
    errors = []

    session_ids.each do |session_id|
      ctx = General::Sessions::UseCases::CancelSession.call(
        params: {
          session_id: session_id,
          reason: "operational_error",
          in_advance: true,
          requested_by_role: "genial",
          comment: "Bulk cancellation via rake task",
          user_id: dev_user.id
        }
      )

      if ctx.success?
        cancelled << session_id
        print "."
      else
        errors << {
          session_id: session_id,
          errors: ctx[:errors]
        }
        print "e"
      end
    end

    puts "\n========== SUMMARY =========="
    puts "Total sessions: #{session_ids.count}"
    puts "Cancelled: #{cancelled.count}"
    puts "Errors: #{errors.count}"

    if errors.any?
      puts "\nError details:"
      errors.each do |e|
        error_msgs = e[:errors].map { |err| "#{err[:code]}: #{err[:message]}" }.join(", ")
        puts "  Session #{e[:session_id]}: #{error_msgs}"
      end
    end

    puts "========== FINISHED =========="
  end
end
```

## 6. Multi-Tenant Operation

**Cenário**: Processar dados em todos os tenants

```ruby
namespace :multi_tenant do
  desc "Update settings for all tenants"
  task update_settings: :environment do
    puts "========== STARTED MULTI-TENANT UPDATE =========="

    dev_user = User.system_user
    summary = {}

    Tenant.find_each do |tenant|
      puts "\nProcessing tenant: #{tenant.name}"

      ActsAsTenant.with_tenant(tenant) do
        settings = Setting.where(needs_update: true)
        updated = 0

        settings.find_each do |setting|
          setting.update(
            value: "new_value",
            needs_update: false,
            updated_by: dev_user
          )
          updated += 1
          print "."
        end

        summary[tenant.name] = {
          total: settings.count,
          updated: updated
        }
      end
    end

    puts "\n\n========== SUMMARY BY TENANT =========="
    summary.each do |tenant_name, stats|
      puts "#{tenant_name}: #{stats[:updated]}/#{stats[:total]}"
    end

    total_updated = summary.values.sum { |s| s[:updated] }
    total_records = summary.values.sum { |s| s[:total] }
    puts "\nGrand total: #{total_updated}/#{total_records}"

    puts "========== FINISHED =========="
  end
end
```

## 7. Rake com Relatório CSV

**Cenário**: Gerar relatório de inconsistências

```ruby
require "csv"

namespace :reports do
  desc "Generate inconsistencies report"
  task inconsistencies: :environment do
    puts "========== STARTED INCONSISTENCIES REPORT =========="

    ActsAsTenant.current_tenant = Tenant.find_genial_tenant

    # Find inconsistencies
    inconsistencies = []

    People::Child.includes(:contracts).find_each do |child|
      # Check for multiple open contracts
      open_contracts = child.contracts.select(&:open?)
      if open_contracts.count > 1
        inconsistencies << {
          type: "multiple_open_contracts",
          child_id: child.id,
          child_name: child.full_name,
          details: "#{open_contracts.count} open contracts",
          contract_ids: open_contracts.map(&:id).join(", ")
        }
      end

      # Check for missing insurance when contracting model requires it
      if child.insurance_health_plan? && child.insurance_health_plan.blank?
        inconsistencies << {
          type: "missing_insurance",
          child_id: child.id,
          child_name: child.full_name,
          details: "Contracting model requires insurance but none set",
          contract_ids: ""
        }
      end

      print "." if (child.id % 100).zero?
    end

    # Generate CSV report
    csv_path = "tmp/reports/inconsistencies_#{Date.current}.csv"
    FileUtils.mkdir_p(File.dirname(csv_path))

    CSV.open(csv_path, "w") do |csv|
      csv << ["Type", "Child ID", "Child Name", "Details", "Contract IDs"]
      inconsistencies.each do |inc|
        csv << [
          inc[:type],
          inc[:child_id],
          inc[:child_name],
          inc[:details],
          inc[:contract_ids]
        ]
      end
    end

    puts "\n\n========== SUMMARY =========="
    puts "Total children checked: #{People::Child.count}"
    puts "Inconsistencies found: #{inconsistencies.count}"

    # Group by type
    by_type = inconsistencies.group_by { |i| i[:type] }
    puts "\nBy type:"
    by_type.each do |type, items|
      puts "  #{type}: #{items.count}"
    end

    puts "\nReport saved to: #{csv_path}"
    puts "========== FINISHED =========="
  end
end
```

## 8. Rake com Correção de Dados

**Cenário**: Corrigir dados inconsistentes com opção de dry-run

```ruby
namespace :fix do
  desc "Fix invalid professional numbers"
  task :professional_numbers, [:confirmation] => :environment do |_, args|
    confirmation = args[:confirmation] == "true"

    puts "========== STARTED FIXING PROFESSIONAL NUMBERS =========="
    puts "Confirmation: #{confirmation}"

    ActsAsTenant.current_tenant = Tenant.find_genial_tenant
    dev_user = User.system_user

    # Find records with invalid professional numbers
    collaborators = People::Collaborator.where.not(professional_number: nil)

    invalid_numbers = []
    fixes = []

    collaborators.find_each do |collaborator|
      # Remove non-numeric characters
      cleaned = collaborator.professional_number.gsub(/[^0-9]/, "")

      if cleaned != collaborator.professional_number
        invalid_numbers << collaborator

        fixes << {
          id: collaborator.id,
          name: collaborator.name,
          old_value: collaborator.professional_number,
          new_value: cleaned
        }
      end
    end

    puts "\nFound #{invalid_numbers.count} collaborators with invalid numbers"

    if invalid_numbers.empty?
      puts "Nothing to fix!"
      return
    end

    unless confirmation
      puts "\n[DRY RUN] Would fix:"
      fixes.first(10).each do |fix|
        puts "  #{fix[:name]}: '#{fix[:old_value]}' -> '#{fix[:new_value]}'"
      end
      puts "  ... and #{fixes.count - 10} more" if fixes.count > 10

      puts "\nRun with confirmation=true to apply fixes."
      return
    end

    # Apply fixes
    fixed = 0
    errors = []

    invalid_numbers.each do |collaborator|
      cleaned = collaborator.professional_number.gsub(/[^0-9]/, "")

      if collaborator.update(professional_number: cleaned, updated_by: dev_user)
        fixed += 1
        print "."
      else
        errors << {
          id: collaborator.id,
          error: collaborator.errors.full_messages
        }
        print "e"
      end
    end

    puts "\n========== SUMMARY =========="
    puts "Invalid numbers found: #{invalid_numbers.count}"
    puts "Fixed: #{fixed}"
    puts "Errors: #{errors.count}"

    if errors.any?
      puts "\nError details:"
      errors.each { |e| puts "  ID #{e[:id]}: #{e[:error].join(', ')}" }
    end

    puts "========== FINISHED =========="
  end
end

# Usage:
# Dry run: rake fix:professional_numbers
# Execute: rake fix:professional_numbers[true]
```

## 9. Rake com Argumentos Múltiplos

**Cenário**: Criar registros em lote com parâmetros configuráveis

```ruby
namespace :seed do
  desc "Create test data. Usage: rake seed:test_data[10,staging]"
  task :test_data, [:count, :environment_name] => :environment do |_, args|
    count = (args[:count] || 10).to_i
    env_name = args[:environment_name] || Rails.env

    unless env_name.in?(%w[development staging])
      puts "ERROR: Can only run in development or staging"
      puts "Current environment: #{Rails.env}"
      exit 1
    end

    puts "========== STARTED CREATING TEST DATA =========="
    puts "Count: #{count}"
    puts "Environment: #{env_name}"

    ActsAsTenant.current_tenant = Tenant.find_genial_tenant
    dev_user = User.system_user

    created = 0

    count.times do |i|
      child = People::Child.create(
        full_name: "Test Child #{i + 1}",
        document_type: "cpf",
        document_number: "#{11111111111 + i}",
        birth_date: Date.current - rand(2..10).years,
        diagnosed: [true, false].sample,
        contracting_model: "private_contracting",
        created_by: dev_user
      )

      if child.persisted?
        created += 1
        print "."
      else
        print "e"
      end
    end

    puts "\n========== SUMMARY =========="
    puts "Requested: #{count}"
    puts "Created: #{created}"
    puts "========== FINISHED =========="
  end
end

# Usage: rake seed:test_data[50,staging]
```

## 10. Rake com Processamento em Batches

**Cenário**: Processar milhares de registros em lotes

```ruby
namespace :process do
  desc "Process records in batches"
  task :in_batches, [:batch_size] => :environment do |_, args|
    batch_size = (args[:batch_size] || 100).to_i

    puts "========== STARTED BATCH PROCESSING =========="
    puts "Batch size: #{batch_size}"

    ActsAsTenant.current_tenant = Tenant.find_genial_tenant
    dev_user = User.system_user

    records = Model.where(processed: false)
    total = records.count
    processed = 0
    errors = 0
    batch_count = 0

    puts "Total records to process: #{total}"

    records.find_in_batches(batch_size: batch_size) do |batch|
      batch_count += 1
      puts "\nProcessing batch #{batch_count} (#{batch.size} records)..."

      batch.each do |record|
        begin
          # Process record
          record.update!(
            processed: true,
            processed_at: Time.current,
            processed_by: dev_user
          )
          processed += 1
          print "."
        rescue => e
          errors += 1
          print "e"
        end
      end

      # Optional: Sleep between batches to avoid overwhelming the system
      sleep 1 if batch_count % 10 == 0
    end

    puts "\n\n========== SUMMARY =========="
    puts "Total records: #{total}"
    puts "Processed: #{processed}"
    puts "Errors: #{errors}"
    puts "Batches: #{batch_count}"
    puts "========== FINISHED =========="
  end
end

# Usage: rake process:in_batches[500]
```
