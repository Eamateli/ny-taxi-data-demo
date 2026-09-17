#!/usr/bin/env bash
# Call the local Grafana HTTP API as admin without putting the password on the
# command line. Usage (after `source .env`):
#   scripts/grafana_api.sh GET  /api/health
#   scripts/grafana_api.sh POST /api/ds/query @query.json
#   scripts/grafana_api.sh GET  /api/dashboards/uid/nyc-taxi
set -euo pipefail
: "${GRAFANA_ADMIN_PASSWORD:?source .env first}"
method=$1; path=$2; body=${3:-}
url="${GRAFANA_URL:-http://localhost:3000}${path}"
args=(-sS -X "$method" -H 'Content-Type: application/json' -H 'Accept: application/json')
[ -n "$body" ] && args+=(--data "$body")
# -K - : read curl options from stdin, so the credentials never show up in `ps`
printf 'user = "admin:%s"\n' "$GRAFANA_ADMIN_PASSWORD" | curl "${args[@]}" -K - "$url"
