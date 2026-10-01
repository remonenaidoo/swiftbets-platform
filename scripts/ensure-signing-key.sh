#!/usr/bin/env bash
# Gives the local identity service one stable RS256 key (D81): without it, every placement restart signs with a new
# throwaway key and every token other services hold stops validating. Generated once into compose/.env.
set -euo pipefail
env_file="$(cd "$(dirname "$0")/.." && pwd)/compose/.env"
grep -q '^IDENTITY_SIGNING_KEY_PEM=' "$env_file" && exit 0
key="$(openssl genrsa 2048 2>/dev/null | openssl rsa -traditional 2>/dev/null)"
{ echo; echo '# Identity RS256 signing key (generated once; keeps tokens valid across restarts).'; printf 'IDENTITY_SIGNING_KEY_PEM="%s"\n' "$key"; } >> "$env_file"
echo "generated IDENTITY_SIGNING_KEY_PEM in compose/.env"
