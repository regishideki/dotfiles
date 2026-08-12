# K8s shell snippet pattern

Standard pattern for running rake tasks in k8s environments. Append to `custom_gitignore/snippets/snippets.sh`.

## Template

```bash
# descriptive comment (pt-BR or English)
feature_name="short_name"
local_directory="custom_gitignore/migrations/${feature_name}"
mkdir -p "${local_directory}"

# copy CSV into ${local_directory}/data.csv before running cloud blocks
# cp path/to/original.csv "${local_directory}/data.csv"

## local (dry-run)
FILE_PATH="${local_directory}/data.csv" TENANT_NAMES="t1,t2" DRY_RUN=true bundle exec rake namespace:task | tee "${local_directory}/output-local.txt"

## dry-run (development)
env="development"
podId=$(kubectl get pods --no-headers -n core -o custom-columns=":metadata.name" --field-selector=status.phase=Running | grep web | head -n 1)

kubectl exec -it "${podId}" -n core -- mkdir -p lib/tasks/subdir
kubectl cp lib/tasks/subdir/file.rake "core/${podId}:lib/tasks/subdir/file.rake" -n core
kubectl cp "${local_directory}/data.csv" "core/${podId}:data.csv" -n core

kubectl exec -it "${podId}" -n core -- bash -c '
  FILE_PATH=data.csv \
  TENANT_NAMES=t1,t2 \
  DRY_RUN=true \
  bundle exec rake namespace:task
' | tee "${local_directory}/output-${env}.txt"

## execucao (development)
kubectl exec -it "${podId}" -n core -- bash -c '
  FILE_PATH=data.csv \
  TENANT_NAMES=t1,t2 \
  DRY_RUN=false \
  bundle exec rake namespace:task
' | tee "${local_directory}/output-${env}-confirmed.txt"

## dry-run (staging)
env="staging"
kubectl config use-context ${env}
podId=$(kubectl get pods --no-headers -n core -o custom-columns=":metadata.name" --field-selector=status.phase=Running | grep web | head -n 1)

kubectl exec -it "${podId}" -n core -- mkdir -p lib/tasks/subdir
kubectl cp lib/tasks/subdir/file.rake "core/${podId}:lib/tasks/subdir/file.rake" -n core
kubectl cp "${local_directory}/data.csv" "core/${podId}:data.csv" -n core

kubectl exec -it "${podId}" -n core -- bash -c '
  FILE_PATH=data.csv \
  TENANT_NAMES=t1,t2 \
  DRY_RUN=true \
  bundle exec rake namespace:task
' | tee "${local_directory}/output-${env}.txt"

## execucao (staging)
... (same pattern with DRY_RUN=false)

## dry-run (production)
... (same pattern)

## execucao (production)
... (same pattern with DRY_RUN=false)
```

## Rules

1. **Rake args**: use ENV vars via `bash -c`, not positional args like `rake namespace:task[arg1,arg2]`
2. **kubectl cp dirs**: always `mkdir -p` on the pod before `kubectl cp` to a subdirectory
3. **CSV files**: copy them into `${local_directory}/` first, then `kubectl cp` with a simple name
4. **kubectl cp destination**: use a simple relative name (e.g. `data.csv`) — it resolves to the pod's working directory (`/app`)
5. **Output**: use `| tee` in the dry-run blocks and confirmed execucao blocks to see output while saving
6. **Context switch**: `kubectl config use-context ${env}` before each new environment
7. **Each env gets dry-run + execucao**: always provide both blocks per environment
