#!/usr/bin/env bash
# Creates (or aligns) every topic in topics.yaml for one environment. Idempotent.
set -euo pipefail

file="${1:-/topics/topics.yaml}"
environment="${SWIFTBETS_ENV:?SWIFTBETS_ENV is required}"
brokers="${REDPANDA_BROKERS:-redpanda:9092}"
admin="${REDPANDA_ADMIN:-redpanda:9644}"

rpk cluster config set auto_create_topics_enabled false -X admin.hosts="$admin" >/dev/null
echo "auto_create_topics_enabled=false"

default_partitions=$(awk '/^defaults:/{d=1;next} d && /partitions:/{print $2; exit}' "$file")
default_retention=$(awk '/^defaults:/{d=1;next} d && /retention.ms:/{print $2; exit}' "$file")

awk '
  /^  - name:/ { if (name) print name "|" parts "|" ret "|" cfg; name=$3; parts=""; ret=""; cfg="" }
  /^    partitions:/ { parts=$2 }
  /^    retention.ms:/ { ret=$2 }
  /^    config:/ { sub(/^    config: *\{ */, ""); sub(/ *\} *$/, ""); gsub(/: /, "="); cfg=$0 }
  END { if (name) print name "|" parts "|" ret "|" cfg }
' "$file" | while IFS='|' read -r name partitions retention config; do
  # Dead-letter queues follow the code's naming: <topic>.<env>.dlq
  if [[ "$name" == *.dlq ]]; then topic="${name%.dlq}.$environment.dlq"; else topic="$name.$environment"; fi
  partitions="${partitions:-$default_partitions}"
  retention="${retention:-$default_retention}"
  args=(-c "retention.ms=$retention")
  [[ -n "$config" ]] && args+=(-c "$config")
  if rpk topic describe "$topic" -X brokers="$brokers" >/dev/null 2>&1; then
    rpk topic alter-config "$topic" --set "retention.ms=$retention" -X brokers="$brokers" >/dev/null
    echo "exists  $topic"
  else
    # rpk reports a refused topic in its table, not its exit code alone; show it so a failure is never silent.
    out="$(rpk topic create "$topic" -p "$partitions" -r 1 "${args[@]}" -X brokers="$brokers" 2>&1)" || { echo "$out" >&2; exit 1; }
    echo "created $topic (p=$partitions)"
  fi
done
