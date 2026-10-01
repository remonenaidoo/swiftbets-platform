#!/usr/bin/env bash
# Decrypts secrets/<env>.enc.env and prints it as the swiftbets-app-secrets Kubernetes Secret, for kubectl apply -f -.
# Needs sops and the environment's age key in SOPS_AGE_KEY. Prints nothing to disk.
set -euo pipefail

env="${1:?environment, e.g. prod}"
file="$(cd "$(dirname "$0")/.." && pwd)/secrets/${env}.enc.env"
[[ -f "$file" ]] || { echo "no $file yet; see secrets/README.md" >&2; exit 2; }
: "${SOPS_AGE_KEY:?set SOPS_AGE_KEY to the age private key of the environment}"

sops --decrypt --input-type dotenv --output-type dotenv "$file" |
  kubectl create secret generic swiftbets-app-secrets --namespace swiftbets --from-env-file=/dev/stdin --dry-run=client -o yaml
