#!/usr/bin/env bash
set -euo pipefail

# Dumps a remote Postgres database (e.g. GCP Cloud SQL) via kubectl exec on a
# running app pod, brings the dump to the local machine via kubectl cp, and
# restores it into a local Postgres (docker-compose "db" service).
#
# Does not require any cloudsql.client / Cloud SQL Auth Proxy IAM permission:
# it reuses the DATABASE_URL env var the pod already has.
#
# Supported source environments: development, staging.
# production is explicitly NOT supported and is hard-blocked below — never
# relax this without an explicit, separate user request and its own review.
#
# No confirmation prompt: this always DROPs and recreates TARGET_DATABASE.
# The downloaded dump is always deleted at the end of the run (success or
# failure) to avoid piling up local disk usage. Only add a confirm/retention
# gate back in if a user explicitly asks for one — don't default to it.
#
# Basic usage:
#   ./import_remote_db_locally.sh
#   SOURCE_ENV=staging ./import_remote_db_locally.sh
#
# Environment variables:
#   SOURCE_ENV=development              Remote environment to pull from (allowlist: development, staging)
#   TARGET_DATABASE=core_development    Local database name to recreate
#   KUBE_CONTEXT=<SOURCE_ENV>           kubectl context (defaults to SOURCE_ENV; must also be in the allowlist)
#   KUBE_NAMESPACE=core                 Namespace
#   KUBE_POD_REGEX=^web-                Target pod regex
#   KUBE_CONTAINER=web                  Target container

ALLOWED_SOURCE_ENVS=("development" "staging")

SOURCE_ENV="${SOURCE_ENV:-development}"
KUBE_CONTEXT="${KUBE_CONTEXT:-$SOURCE_ENV}"
KUBE_NAMESPACE="${KUBE_NAMESPACE:-core}"
KUBE_POD_REGEX="${KUBE_POD_REGEX:-^web-}"
KUBE_CONTAINER="${KUBE_CONTAINER:-web}"
TARGET_DATABASE="${TARGET_DATABASE:-core_development}"
DOWNLOAD_RETRIES="${DOWNLOAD_RETRIES:-3}"
DOWNLOAD_RETRY_SLEEP_SECONDS="${DOWNLOAD_RETRY_SLEEP_SECONDS:-2}"
REMOTE_DUMP_PATH="${REMOTE_DUMP_PATH:-/tmp/remote_db_dump_$(date +%s).pgdump}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOCAL_DUMP_DIR="${LOCAL_DUMP_DIR:-$PWD/tmp/remote_db_dumps}"
LOCAL_DUMP_PATH="$LOCAL_DUMP_DIR/remote_db_dump_$TIMESTAMP.pgdump"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "Required command not found: $1" >&2; exit 1; }
}

is_allowed_env() {
  local candidate="$1" env
  for env in "${ALLOWED_SOURCE_ENVS[@]}"; do
    [[ "$candidate" == "$env" ]] && return 0
  done
  return 1
}

# Hard block: production is never valid here, no matter which variable a
# caller sets (typo, CI override, copy-pasted value). Check every variable
# that influences the target, and reject substring matches too (e.g.
# "core-production"), not just an exact "production" string.
for value in "$SOURCE_ENV" "$KUBE_CONTEXT"; do
  if [[ "$value" == "production" || "$value" == *prod* ]]; then
    echo "Refusing to run against '$value'. This script never runs against production." >&2
    exit 1
  fi
done

if ! is_allowed_env "$SOURCE_ENV"; then
  echo "Unsupported SOURCE_ENV '$SOURCE_ENV'. Allowed values: ${ALLOWED_SOURCE_ENVS[*]}." >&2
  exit 1
fi

if ! is_allowed_env "$KUBE_CONTEXT"; then
  echo "Unsupported KUBE_CONTEXT '$KUBE_CONTEXT'. Allowed values: ${ALLOWED_SOURCE_ENVS[*]}." >&2
  exit 1
fi

require_command kubectl
require_command docker

KUBECTL_CONTEXT_ARGS=()
if kubectl config use-context "$KUBE_CONTEXT" >/dev/null 2>&1; then
  :
else
  KUBECTL_CONTEXT_ARGS=(--context "$KUBE_CONTEXT")
fi

kctl() {
  if [[ ${#KUBECTL_CONTEXT_ARGS[@]} -gt 0 ]]; then
    kubectl "${KUBECTL_CONTEXT_ARGS[@]}" "$@"
  else
    kubectl "$@"
  fi
}

find_target_pod() {
  kctl get pods -n "$KUBE_NAMESPACE" --no-headers | awk -v regex="$KUBE_POD_REGEX" '$1 ~ regex && $3 == "Running" { print $1; exit }'
}

POD_NAME="${POD_NAME:-$(find_target_pod)}"

if [[ -z "$POD_NAME" ]]; then
  echo "No pod found matching regex '$KUBE_POD_REGEX' in namespace '$KUBE_NAMESPACE' (context $KUBE_CONTEXT)." >&2
  exit 1
fi

log "Source environment: $SOURCE_ENV"
log "Target pod: $POD_NAME (namespace=$KUBE_NAMESPACE, context=$KUBE_CONTEXT)"

log "Generating remote dump at $REMOTE_DUMP_PATH"
kctl exec -n "$KUBE_NAMESPACE" -c "$KUBE_CONTAINER" "$POD_NAME" -- \
  sh -c "pg_dump \"\$DATABASE_URL\" -Fc --no-owner --no-privileges -f '$REMOTE_DUMP_PATH'"

mkdir -p "$LOCAL_DUMP_DIR"

# Single cleanup handler for EVERYTHING that must happen on exit, success or
# failure: always delete the local dump, and always bring the app service
# back up if this script stopped it. Bash keeps only the LAST `trap ... EXIT`
# registered — combine every exit-time action into one function instead of
# calling `trap` more than once, or an earlier trap silently gets dropped.
APP_WAS_RUNNING="false"

cleanup() {
  if [[ -f "$LOCAL_DUMP_PATH" ]]; then
    log "Removing local dump ($LOCAL_DUMP_PATH)"
    rm -f "$LOCAL_DUMP_PATH"
  fi
  if [[ "$APP_WAS_RUNNING" == "true" ]]; then
    log "Starting the app service back up"
    docker compose start app >/dev/null
  fi
}
trap cleanup EXIT

attempt=1
while [[ $attempt -le $DOWNLOAD_RETRIES ]]; do
  log "Downloading dump via kubectl cp (attempt $attempt/$DOWNLOAD_RETRIES)"
  if kctl cp -n "$KUBE_NAMESPACE" -c "$KUBE_CONTAINER" "$POD_NAME:$REMOTE_DUMP_PATH" "$LOCAL_DUMP_PATH"; then
    break
  fi
  warn "Failed to download dump on attempt $attempt."
  attempt=$((attempt + 1))
  sleep "$DOWNLOAD_RETRY_SLEEP_SECONDS"
  [[ $attempt -gt $DOWNLOAD_RETRIES ]] && { echo "Could not download the dump after $DOWNLOAD_RETRIES attempts." >&2; exit 1; }
done

log "Removing remote dump from the pod"
kctl exec -n "$KUBE_NAMESPACE" -c "$KUBE_CONTAINER" "$POD_NAME" -- rm -f "$REMOTE_DUMP_PATH"

DUMP_SIZE="$(du -h "$LOCAL_DUMP_PATH" | cut -f1)"
log "Local dump ready: $LOCAL_DUMP_PATH ($DUMP_SIZE)"

log "Copying dump into the local Postgres container"
docker compose cp "$LOCAL_DUMP_PATH" db:/tmp/remote_db_dump_import.pgdump

# The "app" service holds open connections to the target database (Rails
# server, background workers, etc). DROP DATABASE fails while those are
# active, so stop it for the duration of the restore; the cleanup trap above
# brings it back up regardless of how this script exits.
if [[ "$(docker compose ps -q app)" != "" ]] && docker compose ps app --status running --format json 2>/dev/null | grep -q .; then
  APP_WAS_RUNNING="true"
  log "Stopping the app service to release database connections"
  docker compose stop app >/dev/null
fi

log "Terminating any remaining connections to '$TARGET_DATABASE'"
docker compose exec -T db psql -U root -h localhost -d postgres -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$TARGET_DATABASE' AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true

log "Recreating local database '$TARGET_DATABASE'"
docker compose exec -T db psql -U root -h localhost -d postgres -c "DROP DATABASE IF EXISTS \"$TARGET_DATABASE\";"
docker compose exec -T db psql -U root -h localhost -d postgres -c "CREATE DATABASE \"$TARGET_DATABASE\";"

log "Restoring dump into '$TARGET_DATABASE' (orphan FK warnings from the remote database are expected and ignored)"
docker compose exec -T db pg_restore -U root -h localhost -d "$TARGET_DATABASE" --no-owner --no-privileges -j 4 /tmp/remote_db_dump_import.pgdump || true

docker compose exec -T db rm -f /tmp/remote_db_dump_import.pgdump

log "Done. Local database '$TARGET_DATABASE' updated with '$SOURCE_ENV' data."
