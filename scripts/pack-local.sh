#!/usr/bin/env bash
# Packs sibling contracts and building-blocks checkouts into a consumer's .packages/ for unreleased local changes.
set -euo pipefail

consumer="${1:?usage: pack-local.sh <consumer-repo-dir>}"
here="$(cd "$(dirname "$0")/../.." && pwd)"
for repo in swiftbets-contracts swiftbets-building-blocks; do
  [[ -d "$here/$repo" ]] || continue
  dotnet pack "$here/$repo" -c Release -o "$consumer/.packages"
done
