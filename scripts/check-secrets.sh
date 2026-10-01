#!/usr/bin/env bash
# Fails if anything under secrets/ other than the README and the placeholder template is not SOPS ciphertext.
set -euo pipefail

cd "$(dirname "$0")/.."
status=0
while IFS= read -r file; do
  case "$file" in
    secrets/README.md | secrets/example.env) continue ;;
  esac
  if [[ "$file" != *.enc.env ]] || ! grep -q '^sops_mac=' "$file"; then
    echo "$file is not a SOPS-encrypted <env>.enc.env file" >&2
    status=1
  fi
done < <(git ls-files secrets)

if grep -vE '^(#|$)' secrets/example.env | grep -vE '=(sk_test_|whsec_)?replace_me$'; then
  echo "secrets/example.env must hold placeholders only" >&2
  status=1
fi

exit "$status"
