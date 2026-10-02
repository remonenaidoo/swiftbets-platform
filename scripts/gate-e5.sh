#!/usr/bin/env bash
# E5 gate through the gateway and the casino's own provider API:
#   1. a duplicated win callback credits once;
#   2. a rollback for a bet never seen is stored and accepted, and that bet arriving later is refused;
#   3. reconciliation flags a mismatch injected into the provider's report;
#   4. a self-excluded (cooling-off) customer cannot launch a game.
# usage: GATEWAY=http://localhost:7100 MAILPIT=http://localhost:7125 scripts/gate-e5.sh
set -euo pipefail

gateway="${GATEWAY:-http://localhost:7100}"
mailpit="${MAILPIT:-http://localhost:7125}"
demo_password="${DEMO_PASSWORD:-Local-Dev-Demo-1}"
seamless_secret="${CASINO_SIM_SEAMLESS_SECRET:-local-dev-sim-seamless-secret-0123456789abcdef}"
compose="${COMPOSE:-docker compose --project-directory $(dirname "$0")/../compose -f $(dirname "$0")/../compose/docker-compose.yml}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

api() {
  local jar="$1" method="$2" path="$3"
  shift 3
  curl -sS -o "$work/body" -w '%{http_code}' -b "$work/$jar" -c "$work/$jar" -X "$method" "$gateway$path" \
    -H 'Content-Type: application/json' -H 'X-SwiftBets-Csrf: 1' "$@"
}
expect() {
  local want="$1" got="$2" step="$3"
  [[ "$got" =~ ^($want)$ ]] || { echo "FAIL $step: HTTP $got, wanted $want: $(head -c 400 "$work/body")" >&2; exit 1; }
  echo "ok   $step"
}
fail() { echo "FAIL $*" >&2; exit 1; }
balance() { api p GET /api/me/balance >/dev/null; jq -r '.available.minorUnits' "$work/body"; }
launch() { api "$1" POST /api/casino/launch -d "{\"gameId\":\"$2\",\"providerId\":\"sim-seamless\"}"; }

# Provider callbacks are internal: sign and post them from a container on the stack's own network.
network="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$($compose ps -q casino)")"
provider_call() {
  local action="$1" body="$2" signature
  signature="$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$seamless_secret" -hex | awk '{print $NF}')"
  docker run --rm --network "$network" curlimages/curl:8.11.1 -sS -X POST "http://casino:8080/providers/sim-seamless/wallet/$action" \
    -H 'Content-Type: application/json' -H "X-Provider-Signature: $signature" -d "$body"
}

expect 200 "$(api o POST /api/session/login -d "{\"username\":\"operator1\",\"password\":\"$demo_password\"}")" "operator signs in"
expect 200 "$(api p POST /api/session/login -d "{\"username\":\"punter1\",\"password\":\"$demo_password\"}")" "punter signs in"
expect 200 "$(api p GET /api/casino/lobby)" "the lobby lists games"
jq -e 'any(.categories[].games[]; .gameId == "sun-temple")' "$work/body" >/dev/null || fail "Sun Temple is not in the lobby"

# 1. A win the provider sends twice credits once.
for _ in $(seq 1 20); do [[ "$(launch p sun-temple)" == 200 ]] && break; sleep 2; done
session="$(jq -r '.sessionToken' "$work/body")"
[[ -n "$session" && "$session" != null ]] || fail "launch returned no session: $(head -c 300 "$work/body")"
echo "ok   Sun Temple launched"
expect 200 "$(api p POST /casino-sim/play/start -d "{\"session\":\"$session\",\"game\":\"sun-temple\"}")" "the game page starts a seamless session"
expect 20[02] "$(api o POST /casino-sim/faults/sim-seamless/duplicate-next-callback)" "the provider will send its next win twice"
before="$(balance)"; spent=0; won=0
for _ in $(seq 1 300); do
  expect 200 "$(api p POST /casino-sim/play/spin -d "{\"session\":\"$session\",\"game\":\"sun-temple\",\"bet\":100}")" "spin" >/dev/null
  [[ "$(jq -r '.status' "$work/body")" == ok ]] || fail "spin refused: $(head -c 300 "$work/body")"
  spent=$((spent + 100)); won=$((won + $(jq -r '.win' "$work/body")))
  (( won > 0 )) && break
done
(( won > 0 )) || fail "no win in 300 spins"
sleep 2
after="$(balance)"
[[ "$after" == "$((before - spent + won))" ]] || fail "wallet moved $((after - before)), expected $((won - spent)) (bets $spent, win $won): a duplicate credited twice"
echo "ok   the duplicated win credited once (bets $spent, win $won)"

# 2. A rollback for a bet never seen is stored and accepted; the bet arriving afterwards is refused and debits nothing.
ptx="gate5-bet-$(date +%s%N)"
reply="$(provider_call rollback "{\"sessionToken\":\"$session\",\"providerTransactionId\":\"rb-$ptx\",\"roundId\":\"r-$ptx\",\"gameId\":\"sun-temple\",\"amount\":0,\"currency\":\"ZAR\",\"referenceTransactionId\":\"$ptx\"}")"
[[ "$(jq -r '.status' <<<"$reply")" == ok ]] || fail "unseen rollback was not accepted: $reply"
echo "ok   a rollback for an unseen bet is stored and accepted"
before="$(balance)"
reply="$(provider_call bet "{\"sessionToken\":\"$session\",\"providerTransactionId\":\"$ptx\",\"roundId\":\"r-$ptx\",\"gameId\":\"sun-temple\",\"amount\":500,\"currency\":\"ZAR\"}")"
[[ "$(jq -r '.status' <<<"$reply")" == bet_rolled_back ]] || fail "the late bet was not refused: $reply"
[[ "$(balance)" == "$before" ]] || fail "the refused bet still moved money"
echo "ok   the bet arriving after its rollback is refused and debits nothing"

# 3. Reconciliation flags a transaction missing from the provider's report.
today="$(date -u +%F)"
expect 20[02] "$(api o POST /casino-sim/faults/sim-seamless/drop-from-report?count=1)" "the provider's next report drops a transaction"
expect 200 "$(api o POST "/api/admin/casino/reconciliation/sim-seamless/$today")" "operator reconciles today"
jq -e '.status == "drift" and .missingOnProviderSide >= 1' "$work/body" >/dev/null || fail "no drift flagged: $(head -c 300 "$work/body")"
echo "ok   reconciliation flagged the injected mismatch"

# 4. A customer on a cooling-off break cannot launch a game.
email="gate5-$(date +%s)-$RANDOM@example.com"; password="Gate-Check-Pass-5"
expect '20[0-9]' "$(api c POST /api/auth/register -d "{\"email\":\"$email\",\"password\":\"$password\",\"dateOfBirth\":\"1990-01-01\",\"country\":\"ZA\",\"currency\":\"ZAR\"}")" "a new customer registers"
token=""
for _ in $(seq 1 30); do
  id="$(curl -sS "$mailpit/api/v1/search?query=to:$email" | jq -r '.messages[0].ID // empty')"
  if [[ -n "$id" ]]; then
    token="$(curl -sS "$mailpit/api/v1/message/$id" | jq -r '.Text' | grep -oE 'token=[^[:space:]&"]+' | head -n 1 | cut -d= -f2-)"
    [[ -n "$token" ]] && break
  fi
  sleep 2
done
[[ -n "$token" ]] || fail "verification email never arrived"
token="$(printf '%b' "${token//%/\\x}")"
expect '20[04]' "$(api c POST /api/auth/verify-email -d "{\"token\":\"$token\"}")" "the customer verifies their email"
expect 200 "$(api c POST /api/session/login -d "{\"username\":\"$email\",\"password\":\"$password\"}")" "the customer signs in"
expect '20[0-9]' "$(api c POST /api/me/exclusions -d '{"kind":"coolingOff","days":1,"reason":"E5 gate"}')" "the customer takes a one-day break"
# Taking a break ends the customer's sessions and keeps them signed out; while any session survives, launch is refused.
outcome=""
for _ in $(seq 1 30); do
  code="$(launch c sun-temple)"
  if [[ "$code" == 403 ]] && jq -e '.code == "casino_restricted"' "$work/body" >/dev/null; then outcome="launch refused (casino_restricted)"; break; fi
  [[ "$code" == 200 ]] && fail "a customer on a break launched a game: $(head -c 300 "$work/body")"
  if [[ "$code" == 401 ]]; then
    login="$(api c POST /api/session/login -d "{\"username\":\"$email\",\"password\":\"$password\"}")"
    [[ "$login" == 401 ]] && { outcome="signed out and refused sign-in"; break; }
  fi
  sleep 2
done
[[ -n "$outcome" ]] || fail "could not establish the break's effect: HTTP $code $(head -c 300 "$work/body")"
echo "ok   a customer on a break cannot launch a game: $outcome"

echo "E5 gate (duplicate win, unseen rollback, reconciliation drift, self-exclusion) passed"
