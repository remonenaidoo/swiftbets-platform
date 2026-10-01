#!/usr/bin/env bash
# Validates the Prometheus alert rules and runs their unit tests (tests/*.test.yml) with promtool.
set -euo pipefail

dir="$(cd "$(dirname "$0")/../compose/prometheus" && pwd)"
image="prom/prometheus:v3.15.0"
mapfile -t rules < <(cd "$dir" && find rules -name '*.yml' | sort)
mapfile -t tests < <(cd "$dir/tests" && find . -name '*.test.yml' | sort)

docker run --rm -v "$dir:/p" -w /p --entrypoint promtool "$image" check rules "${rules[@]}"
docker run --rm -v "$dir:/p" -w /p/tests --entrypoint promtool "$image" test rules "${tests[@]}"
