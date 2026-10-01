#!/usr/bin/env bash
# Pins every package of one shared family to a released version in a consumer's Directory.Packages.props.
# usage: bump-shared.sh <contracts|building-blocks> <version> <consumer-repo-dir>
# Prints "changed" or "unchanged" so a caller knows whether a pull request is needed.
set -euo pipefail

family="${1:?contracts or building-blocks}"
version="${2:?version, e.g. 0.5.0}"
props="${3:?consumer repo dir}/Directory.Packages.props"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be x.y.z" >&2; exit 2; }
case "$family" in
  contracts) prefix='SwiftBets\.Contracts' ;;
  building-blocks) prefix='SwiftBets\.BuildingBlocks' ;;
  *) echo "unknown family $family" >&2; exit 2 ;;
esac
[[ -f "$props" ]] || { echo "unchanged"; exit 0; }

before="$(sha256sum "$props")"
sed -i -E "s/(Include=\"${prefix}(\.[A-Za-z]+)*\" Version=\")[^\"]+\"/\1${version}\"/" "$props"
[[ "$(sha256sum "$props")" == "$before" ]] && echo "unchanged" || echo "changed"
