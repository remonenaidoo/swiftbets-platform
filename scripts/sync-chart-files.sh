#!/usr/bin/env bash
# Compose is the source of the infra init scripts; the infra chart carries copies (Helm cannot read outside a chart).
# Run after editing them; CI fails when the copies drift (scripts/sync-chart-files.sh --check).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
pairs=(
  "compose/sqlserver/init.sql:charts/infra/files/sqlserver-init.sql"
  "compose/postgres/10-databases.sh:charts/infra/files/10-databases.sh"
  "compose/redpanda/provision-topics.sh:charts/infra/files/provision-topics.sh"
  "compose/redpanda/topics.yaml:charts/infra/files/topics.yaml"
)
status=0
for pair in "${pairs[@]}"; do
  src="$root/${pair%%:*}"; dst="$root/${pair##*:}"
  if [[ "${1:-}" == "--check" ]]; then
    cmp -s "$src" "$dst" || { echo "drift: ${pair##*:} differs from ${pair%%:*}"; status=1; }
  else
    cp "$src" "$dst"
  fi
done
exit $status
