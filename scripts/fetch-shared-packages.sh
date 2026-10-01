#!/usr/bin/env bash
# Downloads the SwiftBets.* packages pinned in Directory.Packages.props from their GitHub releases into .packages/.
set -euo pipefail

owner="${SWIFTBETS_OWNER:-remonenaidoo}"
root="${1:-.}"
feed="$root/.packages"
mkdir -p "$feed"

props="$root/Directory.Packages.props"
[[ -f "$props" ]] || { echo "no Directory.Packages.props in $root"; exit 0; }

{ grep -oE 'Include="SwiftBets\.[A-Za-z.]+" Version="[^"]+"' "$props" || true; } |
  sed -E 's/Include="([^"]+)" Version="([^"]+)"/\1 \2/' |
  while read -r package version; do
    case "$package" in
      SwiftBets.Contracts*) repo="swiftbets-contracts" ;;
      SwiftBets.BuildingBlocks*) repo="swiftbets-building-blocks" ;;
      *) echo "unknown shared package $package"; exit 1 ;;
    esac
    echo "$repo v$version"
  done | sort -u |
  while read -r repo tag; do
    echo "fetching $repo $tag"
    # GitHub's release-asset API answers 5xx now and then; three tries with backoff before giving up.
    for attempt in 1 2 3; do
      gh release download "$tag" --repo "$owner/$repo" --pattern '*.nupkg' --dir "$feed" --clobber && break
      ((attempt < 3)) || exit 1
      echo "retrying $repo $tag (attempt $((attempt + 1)))"
      sleep $((attempt * 5))
    done
  done
