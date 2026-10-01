#!/usr/bin/env bash
# Renders the umbrella chart with the production values and fails on anything that must never reach production:
# a moving image tag, demo users or funded demo wallets, fault injection, demo sign-in, an in-cluster SQL Server or a Development host.
set -euo pipefail

cd "$(dirname "$0")/.."
out="$(mktemp)"
trap 'rm -f "$out"' EXIT

if helm template swiftbets charts/swiftbets -f charts/swiftbets/values-prod.yaml >/dev/null 2>&1; then
  echo "production must refuse to render without a released image tag" >&2
  exit 1
fi

helm template swiftbets charts/swiftbets -f charts/swiftbets/values-prod.yaml --set global.imageTag=0.0.0-ci > "$out"

failures=0
refuse() {
  if grep -nE "$2" "$out"; then
    echo "production values: $1" >&2
    failures=$((failures + 1))
  fi
}

refuse "an image on a moving tag" 'image: ghcr\.io/.*:(main|latest)$'
grep -A1 -E 'name: (FaultInjection__Enabled|Identity__SeedDemoUsers|Migrator__SeedDemo)$' "$out" | grep -q 'value: "true"' \
  && { echo "production values: fault injection or demo users enabled" >&2; failures=$((failures + 1)); }
refuse "demo sign-in configured" 'Gateway__DemoSignIn'
refuse "an in-cluster SQL Server" 'name: sqlserver$'
refuse "a Development host" 'value: "Development"'

if command -v kubeconform >/dev/null; then
  kubeconform -strict -summary -ignore-missing-schemas "$out"
fi

((failures == 0)) || exit 1
echo "production values render cleanly"
