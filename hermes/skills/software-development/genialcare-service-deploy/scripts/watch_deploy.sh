#!/bin/bash
# Watchdog de deploy GenialCare: imprime APENAS quando um GitHub Actions run
# concluir. Silencioso (stdout vazio) enquanto in_progress/queued — padrão
# watchdog do Hermes (no_agent=true): sem output = sem entrega.
#
# Uso:
#   watch_deploy.sh <run_id> [repo] [gh_path]
#   watch_deploy.sh 35234688854
#   watch_deploy.sh 35234688854 GenialCare/core
#
# Para cron job (verifica a cada N min, silencioso até concluir):
#   script=watch_deploy.sh  ->  mas o run_id precisa estar fixo; edite abaixo
#   ou gere um wrapper que passe o run_id fixo.
#
# Para monitor em background na sessão (notificação em tempo real), rode em loop:
#   while true; do watch_deploy.sh "$RUN_ID"; [ $? -eq 0 ] && break; sleep 20; done
#   (saia do loop quando o script imprimir "concluído" — exit 0)

RUN_ID="${1:-}"
REPO="${2:-GenialCare/mobile-bff}"
GH="${3:-/opt/homebrew/bin/gh}"

if [ -z "$RUN_ID" ]; then
  echo "uso: $0 <run_id> [repo] [gh_path]" >&2
  exit 2
fi

status=$("$GH" run view "$RUN_ID" \
  --repo "$REPO" \
  --json status,conclusion \
  --jq '.status + "|" + (.conclusion // "")' 2>/dev/null)

# Imprime (e sai 0 = "concluído") só quando o run terminou.
if [[ "$status" == completed* ]]; then
  echo "Deploy concluído ($REPO, run $RUN_ID): $status"
  exit 0
fi

# Ainda em andamento: silencioso, mas saída 1 sinaliza "ainda não" para o caller.
exit 1
