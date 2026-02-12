# Quick Reference Card - Rake Tasks

## 📋 Template Básico

```ruby
namespace :domain do
  desc "Description"
  task task_name: :environment do
    puts "========== STARTED =========="
    ActsAsTenant.current_tenant = Tenant.find_genial_tenant
    dev_user = User.system_user

    # Logic here

    puts "========== FINISHED =========="
  end
end
```

## 🎛️ Controles Comuns

### DRY_RUN via ENV
```ruby
dry_run = ENV["DRY_RUN"].to_s == "1"
# DRY_RUN=1 rake task
```

### Confirmation via args
```ruby
task :name, [:confirmation] => :environment do |_, args|
  confirmation = args[:confirmation] == "true"
  # rake task[true]
```

### Bypass Errors
```ruby
task :name, [:confirmation, :bypass_errors] => :environment do |_, args|
  bypass_errors = args[:bypass_errors] == "true"
  # rake task[true,true]
```

## 🔄 Progress Indicators

```ruby
print "."  # Success
print "e"  # Error
print "F"  # Failure
print "U"  # Would update (dry-run)
puts "\n"  # Newline after loop
```

## 📊 Error Handling

```ruby
errors = []

begin
  record.save!
  print "."
rescue ActiveRecord::RecordInvalid => e
  errors << { id: record.id, error: e.message }
  print "e"
end

# Report at end
if errors.any?
  puts "\nErrors: #{errors.count}"
  errors.each { |e| puts "  #{e}" }
end
```

## 📝 Summary Template

```ruby
puts "\n========== SUMMARY =========="
puts "Total: #{total}"
puts "Successful: #{success_count}"
puts "Errors: #{error_count}"
puts "Skipped: #{skipped_count}"
puts "========== FINISHED =========="
```

## 🗄️ Transaction

```ruby
ActiveRecord::Base.transaction do
  data.each do |item|
    process(item)
  end

  if errors.any?
    puts "Rolling back..."
    raise ActiveRecord::Rollback
  end
end
```

## 🎯 UseCase em Transaction

```ruby
# ❌ WRONG
ActiveRecord::Base.transaction do
  ctx = UseCase.call(params: {})
  # No rollback!
end

# ✅ CORRECT
ActiveRecord::Base.transaction do
  ctx = UseCase.call(params: {})
  unless ctx.success?
    raise StandardError, ctx[:errors].map { |e| e[:message] }.join(", ")
  end
end
```

## 📁 File Reading

```ruby
file_path = "lib/tasks/data/file.csv"

unless File.exist?(file_path)
  puts "FILE NOT FOUND: #{file_path}"
  exit 1
end

CSV.foreach(file_path, headers: true) do |row|
  # Process
end
```

## 🌍 Multi-tenant

```ruby
# Single tenant
ActsAsTenant.current_tenant = Tenant.find_genial_tenant

# All tenants
Tenant.find_each do |tenant|
  ActsAsTenant.with_tenant(tenant) do
    # Logic
  end
end
```

## 📈 CSV Report

```ruby
csv_path = "tmp/reports/report_#{Date.current}.csv"
FileUtils.mkdir_p(File.dirname(csv_path))

CSV.open(csv_path, "w") do |csv|
  csv << ["Header1", "Header2"]
  data.each { |row| csv << row }
end

puts "Report: #{csv_path}"
```

## ⚡ Performance

```ruby
# ✅ Use find_each
Model.find_each { |m| process(m) }

# ✅ Skip callbacks se possível
record.update_column(:field, value)

# ✅ Batch inserts
Model.insert_all(data)

# ✅ Disable logs
old = ActiveRecord::Base.logger
ActiveRecord::Base.logger = nil
# ...
ActiveRecord::Base.logger = old
```

## 🔍 Debug

```ruby
# Limit records
Model.limit(10).each { |m| ... }

# Detailed logs
puts "Processing: #{record.inspect}"

# Pry
require "pry"
binding.pry
```

## 🛡️ Safety

```ruby
# Production check
if Rails.env.production?
  puts "ERROR: Cannot run in production"
  exit 1 unless ENV["ALLOW_PRODUCTION"] == "1"
end

# Environment check
allowed = %w[development staging]
unless allowed.include?(Rails.env)
  puts "ERROR: Only #{allowed.join(', ')}"
  exit 1
end

# Extra confirmation
expected = "DELETE_ALL"
if args[:confirm] != expected
  puts "Must confirm: #{expected}"
  exit 1
end
```

## 🔑 Common Patterns

### Update with validation
```ruby
errors = []

Model.find_each do |record|
  if record.update(field: value)
    print "."
  else
    errors << record.errors.full_messages
    print "e"
  end
end
```

### Create with error handling
```ruby
begin
  Model.create!(attributes)
  print "."
rescue ActiveRecord::RecordInvalid => e
  errors << { data: attributes, error: e.message }
  print "e"
end
```

### Delete with confirmation
```ruby
unless confirmation
  puts "Would delete #{records.count} records"
  return
end

deleted = records.delete_all
puts "Deleted: #{deleted}"
```

### Import CSV
```ruby
CSV.foreach(file, headers: true) do |row|
  Model.create!(
    field1: row["Field1"],
    field2: row["Field2"]
  )
end
```

### Generate report
```ruby
data = Model.group(:category).count

CSV.open(path, "w") do |csv|
  csv << ["Category", "Count"]
  data.each { |cat, count| csv << [cat, count] }
end
```

## ⚙️ Common Arguments

```ruby
# File path
file_path = args[:file_path] || "lib/tasks/data/file.csv"

# Date
date = args[:date]&.to_date || Date.current

# Number
count = (args[:count] || 100).to_i

# Boolean
enabled = args[:enabled] == "true"

# Percentage
percentage = ENV.fetch("PERCENTAGE", "10").to_f / 100
```

## 📞 Usage Examples

```bash
# Simple task
rake namespace:task_name

# With confirmation
rake namespace:task_name[true]

# Multiple args
rake namespace:task_name[true,100,param3]

# ENV variables
DRY_RUN=1 FILE=data.csv rake namespace:task_name

# Combined
DRY_RUN=1 rake namespace:task_name[true,50]
```

## 🎯 Decision Tree

```
Destrutiva? → DRY_RUN=1
   ↓
Crítica? → confirmation
   ↓
Validações complexas? → bypass_errors
   ↓
Atômica? → transaction
   ↓
UseCase + transaction? → raise exception
```

## 📋 Pre-flight Checklist

- [ ] Namespace apropriado
- [ ] Descrição clara
- [ ] User.system_user
- [ ] Tenant configurado
- [ ] Progress indicators
- [ ] Error handling
- [ ] Summary ao final
- [ ] DRY_RUN se destrutiva
- [ ] Transaction se necessário
- [ ] Exception em UseCase+transaction

## 🚫 Anti-patterns

```ruby
# ❌ Transaction desnecessária
ActiveRecord::Base.transaction do
  1000.times { Model.create!(...) }
end

# ❌ Rescue silencioso
rescue => e
  # Nada

# ❌ UseCase sem exception
ActiveRecord::Base.transaction do
  UseCase.call(...)  # Não rollback!
end

# ❌ Save sem bang
Model.new(...).save  # Não lança exception!

# ❌ Sem file check
CSV.foreach("file.csv")  # Pode não existir!

# ❌ Sem summary
# (Termina sem mostrar resultado)
```

## ✅ Best Practices

```ruby
# ✅ Sempre teste dry-run primeiro
# ✅ Acumule erros, mostre ao final
# ✅ Use find_each para muitos registros
# ✅ User.system_user ao invés de hardcode
# ✅ Valide arquivos antes de ler
# ✅ Summary sempre presente
# ✅ Progress indicators
# ✅ Transaction só quando necessário
# ✅ Exception manual em UseCase+transaction
```

## 📖 File Structure

```
lib/tasks/
├── namespace/
│   ├── task_name.rake
│   └── data/
│       └── input_data.csv
```

## 🔗 Links Rápidos

- **SKILL.md** - Documentação completa
- **examples.md** - 10 exemplos práticos
- **checklist.md** - Checklist detalhado
- **FAQ.md** - Perguntas frequentes
- **README.md** - Índice geral

---

💡 **Dica:** Sempre comece com dry-run!
