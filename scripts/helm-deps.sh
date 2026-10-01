#!/usr/bin/env bash
# Builds every chart's dependencies, leaves first: the library chart, then each service and infra, then the umbrella.
set -euo pipefail
cd "$(dirname "$0")/../charts"
helm repo add redpanda https://charts.redpanda.com >/dev/null 2>&1 || true
for chart in infra offer placement wallet settlement payout steward realtime risk gateway dashboard swiftbets; do
  helm dependency update "$chart" >/dev/null
done
echo "chart dependencies built"
