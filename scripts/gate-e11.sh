#!/usr/bin/env bash
# E11 gate on the live stack: an alert fired into Alertmanager reaches Steward and opens the incident its rule names,
# with the subject taken from the alert's label; Steward's webhook refuses a caller without the shared token.
# (The replay suite for every alert class and the retrieval eval run in swiftbets-steward's CI.)
# usage: GATEWAY=http://127.0.0.1:7100 ALERTMANAGER=http://127.0.0.1:7193 scripts/gate-e11.sh
set -euo pipefail

gateway="${GATEWAY:-http://127.0.0.1:7100}"
alertmanager="${ALERTMANAGER:-http://127.0.0.1:7193}"
demo_password="${DEMO_PASSWORD:-Local-Dev-Demo-1}"
compose="${COMPOSE:-docker compose --project-directory $(dirname "$0")/../compose -f $(dirname "$0")/../compose/docker-compose.yml}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
provider="gate11-$(date +%s)"

api() {
  local method="$1" path="$2"
  shift 2
  curl -sS -o "$work/body" -w '%{http_code}' -b "$work/jar" -c "$work/jar" -X "$method" "$gateway/api$path" -H 'Content-Type: application/json' -H 'X-SwiftBets-Csrf: 1' "$@"
}
fail() { echo "FAIL $*" >&2; exit 1; }

[[ "$(api POST /session/login -d "{\"username\":\"operator1\",\"password\":\"$demo_password\"}")" == 200 ]] || fail "operator sign-in"
echo "ok   operator signs in"

# 1. A firing alert travels Prometheus-style through Alertmanager to Steward and opens a PaymentsDegraded incident for the provider.
code="$(curl -sS -o "$work/body" -w '%{http_code}' -X POST "$alertmanager/api/v2/alerts" -H 'Content-Type: application/json' \
  -d "[{\"labels\":{\"alertname\":\"PaymentsWebhooksRejected\",\"provider\":\"$provider\",\"severity\":\"warning\"},\"annotations\":{\"summary\":\"E11 gate: webhooks rejected\"}}]")"
[[ "$code" == 200 ]] || fail "Alertmanager refused the alert: HTTP $code $(head -c 200 "$work/body")"
echo "ok   alert PaymentsWebhooksRejected fired into Alertmanager for $provider"
found=""
for _ in $(seq 1 45); do
  if [[ "$(api GET '/steward/incidents?limit=50')" == 200 ]] && jq -e --arg p "$provider" 'any(.[]; .kind == "paymentsDegraded" and .subject == $p)' "$work/body" >/dev/null; then
    found="$(jq -c --arg p "$provider" '[.[] | select(.subject == $p)][0] | {kind, subject, status}' "$work/body")"
    break
  fi
  sleep 2
done
[[ -n "$found" ]] || fail "Steward never opened an incident for the alert"
echo "ok   Steward opened $found"

# 2. The webhook refuses a caller without the shared token.
network="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$($compose ps -q steward)")"
code="$(docker run --rm --network "$network" curlimages/curl:8.11.1 -sS -o /dev/null -w '%{http_code}' -X POST http://steward:8080/alerts/alertmanager \
  -H 'Content-Type: application/json' -H 'Authorization: Bearer wrong' -d '{"alerts":[{"status":"firing","labels":{"alertname":"WalletLedgerDrift"}}]}')"
[[ "$code" == 401 ]] || fail "the webhook accepted a wrong token: HTTP $code"
echo "ok   the webhook refuses a wrong token"

echo "E11 gate (Alertmanager to Steward incident, webhook auth) passed"
