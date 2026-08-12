---
name: rake
description: Use when creating or modifying rake tasks.
category: software-development
---

# rake

Rake tasks in this project follow specific conventions. This skill covers task structure, common pitfalls, and the k8s execution pattern.

## Task structure

- Use a namespace that reflects the domain: `namespace :speech_therapy do ... end`
- **Use ENV vars, not positional args**, when running in k8s. ENV vars are injected via `bash -c`:
  ```
  task import_objectives: :environment do
    file_path = ENV.fetch("FILE_PATH")
    dry_run = ENV.fetch("DRY_RUN", "false") == "true"
  ```
- **Dry-run pattern**: show what WOULD happen without writing. Use `DRY_RUN=true`. Exit early with `next` (not `return`).
- **Transaction**: wrap all tenant writes in a SINGLE `ActiveRecord::Base.transaction`. If any tenant fails, rollback everything:
  ```ruby
  ActiveRecord::Base.transaction do
    tenants.each { |t| execute_tenant(t, ...) }
    raise ActiveRecord::Rollback if errors.any?
  end
  ```
- **Per-tenant dry-run**: show output and summary for each tenant separately, not aggregated.
- **Dry-run output format**: use the `- Objetivo:` structure with indented bullets:
  ```
  === OBJECTIVES TO CREATE (42) ===
    - Objetivo: Description here
      - requisites:
        - Requirement 1
        - Requirement 2

  === OBJECTIVES TO UPDATE (8) ===
    - Objetivo: Description here
      - current (v3):
        - Old requirement
      - new (v4):
        - New requirement

  === OBJECTIVES TO DISCARD (30) ===
    - Objetivo: Description here
  ```
  Parse multi-line instructions with `.split(/\r?\n/).flat_map { |l| l.split(/\s+-\s+/) }` (handles bullets sharing a line), stripping leading dashes and trailing `;`/`.`. End each tenant section with a count summary.

## Common pitfalls

### `return` in task blocks → LocalJumpError
Rake tasks use blocks. Use `next` to exit early, never `return`.

### Constant maps → NameError AND Lint/ConstantDefinitionInBlock
Maps (e.g. `DOMAIN_MAP`/`SUBDOMAIN_MAP`) at namespace/file level load before Rails autoloads app constants → `NameError: uninitialized constant Enum`. But a CONSTANT inside the `task` block trips `Lint/ConstantDefinitionInBlock`. Use lowercase local variables with `.freeze` inside the task — evaluated at run time, not load time, so both pitfalls are avoided:
```ruby
task import_objectives: :environment do
  domain_map = { "Fala" => Enum::Domains::SPEECH }.freeze
  subdomain_map = { "Aquisição de som" => Enum::Subdomains::SOUND_ACQUISITION }.freeze
end
```

### Alignment whitespace → standardrb violation
No extra spaces aligning `=` across lines. Write `x = 1` not `x    = 1`.

### `kubectl cp` → no parent directories
`kubectl cp` does not create parent dirs. Run `kubectl exec ... -- mkdir -p` first.

### `kubectl cp` → source file missing
The CSV used in `kubectl cp` must exist locally. Copy it into `custom_gitignore/migrations/<name>/` before the cloud blocks.

## EvolutionCheckConfiguration

When creating or updating `EvolutionCheckConfiguration` records, always include these fields:

```ruby
req_count = csv_obj[:requisites].size
Intervention::Evolution::Library::EvolutionCheckConfiguration.create!(
  version: 1,  # or current_version + 1 for updates
  library_objective:,
  configuration_type: Intervention::Evolution::Library::Enum::EvolutionCheckConfigurationTypes::CHECKLIST,
  requisites: csv_obj[:requisites],
  instructions: "",
  completion_threshold: req_count,
  unit_of_measurement: "quantidade",
  max_measurements: req_count,
  created_by: dev_user
)
```

- **`requisites`** — pass a PLAIN array of hashes `[{name: "..."}]`, NOT `RequisiteList.build(...)`. The JSONB serializer (`Serializers::JsonbSerializerType#serialize` → `Oj.dump`) cannot serialize the custom `RequisiteList` object and the `create!` fails silently inside the transaction. Factories and specs all pass plain hashes — match them.
- **`instructions`** — the column is `null: false` in `db/schema.rb`. It MUST be set (even to `""`) when the checklist data lives in `requisites`; leaving it `nil` raises `PG::NotNullViolation`, which aborts the transaction and cascades into `PG::InFailedSqlTransaction` on every later statement.
- **`completion_threshold`** = number of requisites
- **`unit_of_measurement`** = `"quantidade"`
- **`max_measurements`** = number of requisites

### Parsing requisites from CSV

CSV bullet-point text must be normalized into `[{name: "..."}]` hashes:

```ruby
def parse_requisites(text)
  return [] if text.blank?

  text.strip
    .split(/\r?\n/)                                   # split lines
    .flat_map { |line| line.split(/\s+-\s+/) }        # split bullets on the SAME line
    .map { |part| part.strip.sub(/^-\s*/, "").sub(/[;.]$/, "").strip }
    .reject(&:blank?)
    .map { |name| {name: name.sub(/^([a-zà-ú])/) { $1.upcase }} }
end
```

Rules:
- Split bullets that share a line (separated by `\s+-\s+`) — `.each_line` alone leaves them glued with trailing spaces
- Strip leading `-` and whitespace
- Strip trailing `;` and `.`
- Capitalize first letter (including accented chars: `à` → `À`)
- Reject blank lines

### Comparing requisites for updates

Requisites are ordered by name for comparison, not by raw array equality:

```ruby
new_req_names = csv_obj[:requisites].map { |r| r[:name] }.sort
current_req_names = current_config&.requisites&.map { |r| r.name }&.sort || []
next if new_req_names == current_req_names
```

**Critical — two different types, two different accessors:**

- `csv_obj[:requisites]` (CSV-parsed side) IS a plain array of hashes → `r[:name]` is correct.
- `current_config.requisites` (read back from the DB) is deserialized by `Serializers::JsonbSerializerType` into **`Requisite` OBJECTS** (a `RequisiteList` of `Requisite` instances), NOT hashes → use `r.name`. `r[:name]` / `r["name"]` raise `NoMethodError: undefined method '[]' for an instance of Intervention::Evolution::Library::Requisite`.

Same rule anywhere a JSONB custom-typed attribute is read back: DB-read → `.name` (object accessor); CSV-parsed → `[:name]` (hash key).

## K8s execution

See `references/k8s-shell-snippet.md` for the standard kubectl cp + bash -c pattern.
