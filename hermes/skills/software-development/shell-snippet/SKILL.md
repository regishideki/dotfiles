---
name: shell-snippet
description: Create shell snippets for rake tasks in snippets.sh.
---

# shell-snippet

Shell snippets are reusable blocks of shell commands in `custom_gitignore/snippets/snippets.sh` (gitignored). Each is a self-contained section for running rake tasks across environments.

## When to use this skill

- User asks to create a snippet in `snippets.sh`
- User wants to run a rake task via kubectl across environments
- User needs a reusable shell block for data migration, import, or maintenance tasks

## Structure

Each snippet follows this pattern:

```bash
# <feature description (pt-BR title)>
feature_name="<snake_case>"
local_directory="custom_gitignore/migrations/${feature_name}"
mkdir -p "${local_directory}"

## local (dry-run)
<ENV_VARS> bundle exec rake <task> | tee "${local_directory}/output-local.txt"

## local (execucao)
<ENV_VARS> bundle exec rake <task> | tee "${local_directory}/output-local-confirmed.txt"

## dry-run (<env>)
env="<env>"
podId=$(kubectl get pods --no-headers -n core -o custom-columns=":metadata.name" --field-selector=status.phase=Running | grep web | head -n 1)

kubectl exec -it "${podId}" -n core -- mkdir -p <dir_of_rake>
kubectl cp <explicit_rake_path> "core/${podId}:<explicit_rake_path>" -n core
kubectl cp "${local_directory}/<csv>.csv" "core/${podId}:/app/<csv>.csv" -n core

kubectl exec -it "${podId}" -n core -- bash -c '
  FILE_PATH=/app/<csv>.csv \
  ENV_VAR=value \
  bundle exec rake <task>
' | tee "${local_directory}/output-${env}.txt"

## execucao (<env>)
kubectl exec -it "${podId}" -n core -- bash -c '
  FILE_PATH=/app/<csv>.csv \
  ENV_VAR=value \
  bundle exec rake <task>
' | tee "${local_directory}/output-${env}-confirmed.txt"
```

Repeat the dry-run + execucao blocks for each environment (development, staging, production).

## Critical rules

### 1. kubectl cp: use explicit paths + mkdir -p, NEVER shell variables

`kubectl cp` does not create parent directories on the destination. If the rake task lives in a subdirectory like `lib/tasks/speech_therapy/`, the subdirectory may not exist on the pod. Using a shell variable hides this path from the reader.

ALWAYS create the directory first, then copy with explicit paths:

```bash
kubectl exec -it "${podId}" -n core -- mkdir -p lib/tasks/speech_therapy
kubectl cp lib/tasks/speech_therapy/import_objectives.rake "core/${podId}:lib/tasks/speech_therapy/import_objectives.rake" -n core
```

Wrong — missing mkdir OR using shell variable:
```bash
rake_file="lib/tasks/speech_therapy/import_objectives.rake"
kubectl cp "${rake_file}" "core/${podId}:${rake_file}" -n core
# => tar: lib/tasks/speech_therapy: Cannot open: No such file or directory

### 2. Rake with ENV vars: use `bash -c` with inline env, not positional args

When the rake task reads from `ENV`, pass env vars inside `bash -c`:

```bash
kubectl exec -it "${podId}" -n core -- bash -c '
  FILE_PATH=/app/de_para_fono.csv \
  TENANT_NAMES=genialcare,careplus_mindplace \
  DRY_RUN=true \
  bundle exec rake speech_therapy:import_objectives
'
```

### 3. TENANT_NAMES: always explicit, never "all"

```bash
TENANT_NAMES="genialcare,careplus_mindplace"
```

### 4. Output: use `tee`, not `>`

So output is visible in terminal AND saved to file:
```bash
... | tee "${local_directory}/output-${env}.txt"
```

### 5. CSV files: simplified name, no spaces

Place CSVs in `custom_gitignore/migrations/<feature_name>/` with clean names:
- Good: `de_para_fono.csv`
- Bad: `De Para Fono - Objetivos Fonos Desmembrados com config..csv`

### 6. Data files in pod: use relative paths matching source filename

`kubectl cp` with a relative destination places the file in the container's working directory (`/app`). `kubectl exec` runs from the same directory, so relative paths work for both operations. Match the destination filename to the source filename — all 50+ existing snippets use this pattern successfully:

```bash
# kubectl cp destination — relative, same filename
kubectl cp "${local_directory}/de_para_fono.csv" "core/${podId}:de_para_fono.csv" -n core

# env var in bash -c — relative
FILE_PATH=de_para_fono.csv
```

Wrong (absolute path — FILE NOT FOUND at runtime because `kubectl cp` to `/app/...` often fails silently):
```bash
kubectl cp "${local_directory}/de_para_fono.csv" "core/${podId}:/app/de_para_fono.csv" -n core
FILE_PATH=/app/de_para_fono.csv   # => FILE NOT FOUND
```

### 7. Local execution

For local, just use `bundle exec rake` with inline ENV vars directly — no kubectl needed:

```bash
FILE_PATH="${local_directory}/de_para_fono.csv" TENANT_NAMES="genialcare,careplus_mindplace" DRY_RUN=true bundle exec rake speech_therapy:import_objectives | tee "${local_directory}/output-local.txt"
```

## Before writing

Read the bottom of `custom_gitignore/snippets/snippets.sh` first — check the last few entries for the current style, then match it.

## Related references

- `references/rake-constants-pitfall.md` — avoid `NameError: uninitialized constant Enum` by placing maps inside the task body, not at namespace level
