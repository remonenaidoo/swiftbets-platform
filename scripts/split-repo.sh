#!/usr/bin/env bash
# Splits projects out of a service repo into a new repo, keeping their full history.
# usage: split-repo.sh <source-repo> <target-dir> <Solution.Name> <images-json> <path>...
# Each <path> is kept with its history (e.g. src/SwiftBets.Wallet.Api); the shared build files at the root come too.
# The result is a commit-ready checkout; pushing it to its new remote is a separate, deliberate step.
set -euo pipefail

source_repo="${1:?source repo}"
target="${2:?target dir}"
solution="${3:?solution name}"
images="${4:?images json, e.g. [{\"name\": \"x\", \"dockerfile\": \"deploy/X.Dockerfile\"}]}"
shift 4
(($# > 0)) || { echo "give at least one path to keep" >&2; exit 2; }
command -v git-filter-repo >/dev/null || { echo "git-filter-repo is required (pip install git-filter-repo)" >&2; exit 2; }
[[ ! -e "$target" ]] || { echo "$target already exists" >&2; exit 2; }

shared=(global.json nuget.config Directory.Build.props Directory.Packages.props .editorconfig .gitignore .dockerignore LICENSE .packages/README.md)
args=()
for path in "$@" "${shared[@]}"; do args+=(--path "$path"); done

git clone --quiet --no-local "$source_repo" "$target"
cd "$target"
git filter-repo --quiet --force "${args[@]}"
git remote remove origin 2>/dev/null || true

{
  echo '<Solution>'
  for folder in src tests; do
    mapfile -t projects < <(find "$folder" -name '*.csproj' 2>/dev/null | sort)
    ((${#projects[@]})) || continue
    echo "  <Folder Name=\"/$folder/\">"
    for project in "${projects[@]}"; do echo "    <Project Path=\"$project\" />"; done
    echo '  </Folder>'
  done
  echo '</Solution>'
} > "$solution.slnx"

mkdir -p .github/workflows
cat > .github/workflows/ci.yml <<YAML
name: ci

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  dotnet:
    uses: remonenaidoo/swiftbets-platform/.github/workflows/dotnet.yml@main
    with:
      images: '$images'
    permissions:
      contents: read
      packages: write
      security-events: write
YAML

git add -A
echo "split into $target: $(git log --oneline | wc -l) commits of history; review, add a README, then commit and push"
