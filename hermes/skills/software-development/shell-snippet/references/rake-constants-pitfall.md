# Rake Task: Common Pitfalls

## 1. Constants at Namespace Level → `NameError` (and inside the task → `Lint/ConstantDefinitionInBlock`)

Defining constants (maps, defaults) at the `namespace` level in a `.rake` file causes
`NameError: uninitialized constant` at load time because Rails' autoloader hasn't
initialized `Enum::*` classes yet when rake loads the file. But a CONSTANT inside the
`task` block trips `Lint/ConstantDefinitionInBlock`. Use lowercase local variables with
`.freeze` inside the task — evaluated at run time, so both pitfalls are avoided:

```ruby
# ❌ WRONG — namespace level: evaluated at load time, before autoloader
namespace :speech_therapy do
  DOMAIN_MAP = {
    "Fala" => Enum::Domains::SPEECH  # NameError!
  }.freeze

  task import_objectives: :environment do
  end
end

# ❌ WRONG — constant inside the task block: Lint/ConstantDefinitionInBlock
namespace :speech_therapy do
  task import_objectives: :environment do
    DOMAIN_MAP = { "Fala" => Enum::Domains::SPEECH }.freeze
  end
end

# ✅ CORRECT — local var (lowercase) with .freeze, evaluated after Rails boots
namespace :speech_therapy do
  task import_objectives: :environment do
    domain_map = { "Fala" => Enum::Domains::SPEECH }.freeze
  end
end
```

## 2. `return` in Task Block → `LocalJumpError`

Rake tasks are blocks, not methods. Using `return` inside a task block causes
`LocalJumpError: unexpected return`. Use `next` instead.

```ruby
# ❌ WRONG
task my_task: :environment do
  if dry_run
    puts "Dry-run done."
    return   # LocalJumpError!
  end
end

# ✅ CORRECT
task my_task: :environment do
  if dry_run
    puts "Dry-run done."
    next
  end
end
```

## 3. Transaction Scope: all tenants, not per-tenant

When a rake iterates over multiple tenants and makes writes, wrap the ENTIRE loop
in a single transaction so any failure reverts everything — not just the failing tenant.

```ruby
# ❌ WRONG — per-tenant transaction, partial writes survive
tenants.each do |tenant|
  ActiveRecord::Base.transaction do
    execute_tenant(tenant)
  end
end

# ✅ CORRECT — single transaction for all tenants
ActiveRecord::Base.transaction do
  tenants.each do |tenant|
    execute_tenant(tenant)   # rescues errors and raises ActiveRecord::Rollback
  end
  raise ActiveRecord::Rollback if errors.any?
end
```

The `execute_tenant` method should rescue individual operation errors and
`raise ActiveRecord::Rollback` to propagate up to the outer transaction.
