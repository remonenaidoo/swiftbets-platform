#!/usr/bin/env bash
# P1 gate (D155): the Pragmatic Play seamless wallet against the simulator's Pragmatic mode, through the live stack:
#   1. a bet sent twice debits once and the repeat gets the original reply byte for byte;
#   2. a refund for a bet never seen is accepted, and that bet arriving later is refused (error 3) and debits nothing;
#   3. a refund naming more than the stake pays back only the recorded stake;
#   4. a callback with a bad hash is refused (error 5);
#   5. a correctly signed callback from an address outside the allowlist is refused (403);
#   6. a free demo game opens with no account;
#   7. a self-excluded (cooling-off) customer's bet is refused (error 6).
# usage: GATEWAY=http://localhost:7100 MAILPIT=http://localhost:7125 scripts/gate-p1.sh
set -euo pipefail

gateway="${GATEWAY:-http://localhost:7100}"
mailpit="${MAILPIT:-http://localhost:7125}"
demo_password="${DEMO_PASSWORD:-Local-Dev-Demo-1}"
secret="${CASINO_PRAGMATIC_SECRET:-local-dev-pragmatic-secret-0123456789abcdef}"
game="vs20sunwolf"
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
balance() { api "$1" GET /api/me/balance >/dev/null; jq -r '.available.minorUnits' "$work/body"; }
# Launches the Pragmatic game for a signed-in customer and prints the session token from the game URL.
launch_token() {
  local jar="$1" code
  for _ in $(seq 1 20); do
    code="$(api "$jar" POST /api/casino/launch -d "{\"gameId\":\"$game\",\"providerId\":\"pragmatic\"}")"
    [[ "$code" == 200 ]] && break
    sleep 2
  done
  [[ "$code" == 200 ]] || fail "launch: HTTP $code $(head -c 300 "$work/body")"
  jq -r '.launchUrl' "$work/body" | grep -oE 'session=[^&]+' | cut -d= -f2-
}
# Runs a simulator drill and leaves its exchanges in $work/drill.
drill() {
  expect 200 "$(api o POST /casino-sim/faults/pragmatic/drill -d "{\"session\":\"$1\",\"scenario\":\"$2\",\"game\":\"$game\",\"amount\":${3:-100}}")" "drill $2" >/dev/null
  cp "$work/body" "$work/drill"
}
error_of() { jq -r ".exchanges[$1].error" "$work/drill"; }

expect 200 "$(api o POST /api/session/login -d "{\"username\":\"operator1\",\"password\":\"$demo_password\"}")" "operator signs in"
expect 200 "$(api a POST /api/session/login -d "{\"username\":\"admin1\",\"password\":\"$demo_password\"}")" "admin signs in"
expect 200 "$(api p POST /api/session/login -d "{\"username\":\"punter1\",\"password\":\"$demo_password\"}")" "punter signs in"

# The provider's game list reaches the lobby with artwork; the sync also runs by itself shortly after start.
found=""
for _ in $(seq 1 30); do
  api a POST /api/admin/casino/providers/pragmatic/sync >/dev/null || true
  if [[ "$(api p GET /api/casino/lobby)" == 200 ]] && jq -e --arg g "$game" 'any(.categories[].games[]; .gameId == $g and .providerId == "pragmatic" and (.imageUrl // "") != "")' "$work/body" >/dev/null; then
    found=1; break
  fi
  sleep 2
done
[[ -n "$found" ]] || fail "the Pragmatic game never reached the lobby: $(head -c 300 "$work/body")"
echo "ok   the Pragmatic catalogue is synced into the lobby with artwork"

session="$(launch_token p)"
[[ -n "$session" ]] || fail "launch returned no session token"
echo "ok   $game launched through the provider's launch API"

# 1. The same bet twice: one debit, identical replies.
before="$(balance p)"
drill "$session" duplicate-bet 100
[[ "$(error_of 0)" == 0 && "$(error_of 1)" == 0 ]] || fail "duplicate bet not accepted: $(head -c 400 "$work/drill")"
[[ "$(jq -r '.exchanges[0].body' "$work/drill")" == "$(jq -r '.exchanges[1].body' "$work/drill")" ]] || fail "the repeat got a different reply: $(head -c 600 "$work/drill")"
sleep 1
[[ "$(balance p)" == "$((before - 100))" ]] || fail "wallet moved $(( $(balance p) - before )), expected -100: the duplicate debited twice"
echo "ok   a bet sent twice debited once and the repeat got the original reply"

# 2. Refund before its bet: marker stored, the late bet refused, no money moved.
before="$(balance p)"
drill "$session" refund-before-bet 100
[[ "$(error_of 0)" == 0 ]] || fail "the unseen refund was not accepted: $(head -c 400 "$work/drill")"
[[ "$(error_of 1)" == 3 ]] || fail "the late bet was not refused with error 3: $(head -c 400 "$work/drill")"
[[ "$(balance p)" == "$before" ]] || fail "the refused bet still moved money"
echo "ok   a refund before its bet left a marker and the late bet was refused (error 3)"

# 3. A refund naming 100 times the stake pays back only the stake.
before="$(balance p)"
drill "$session" refund-inflated 100
[[ "$(error_of 0)" == 0 && "$(error_of 1)" == 0 ]] || fail "bet and refund not accepted: $(head -c 400 "$work/drill")"
[[ "$(balance p)" == "$before" ]] || fail "the inflated refund moved $(( $(balance p) - before )) instead of returning the stake exactly"
echo "ok   an inflated refund paid back the recorded stake only"

# 4. A bad hash is refused.
before="$(balance p)"
drill "$session" bad-hash 100
[[ "$(error_of 0)" == 5 ]] || fail "a bad hash was not refused with error 5: $(head -c 400 "$work/drill")"
[[ "$(balance p)" == "$before" ]] || fail "a bet with a bad hash moved money"
echo "ok   a callback with a bad hash was refused (error 5)"

# 5. A correctly signed callback from outside the allowlist (any other container) is refused before anything is read.
network="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$($compose ps -q casino)")"
fields="amount=1.00&reference=gate-p1-ip-$(date +%s)&roundId=r&userId=00000000-0000-0000-0000-000000000000"
hash="$(printf '%s%s' "$fields" "$secret" | md5sum | awk '{print $1}')"
code="$(docker run --rm --network "$network" curlimages/curl:8.11.1 -sS -o /dev/null -w '%{http_code}' -X POST \
  http://casino:8080/providers/pragmatic/pragmatic/bet.html -d "$fields&hash=$hash")"
[[ "$code" == 403 ]] || fail "a callback from outside the allowlist got HTTP $code"
echo "ok   a correctly signed callback from outside the allowlist was refused (403)"

# 6. Free demo play: no account, no session, a page that loads.
expect 200 "$(api anon POST /api/casino/demo -d "{\"gameId\":\"$game\",\"providerId\":\"pragmatic\"}")" "a demo launch needs no account"
demo="$(jq -r '.launchUrl' "$work/body")"
# Fetched through the gateway: the URL names the public origin, which may sit behind a CDN.
code="$(curl -sS -L -o /dev/null -w '%{http_code}' "$gateway/${demo#*://*/}")"
[[ "$code" == 200 ]] || fail "the demo game did not load: HTTP $code from $demo"
echo "ok   the free demo game loads"

# 7. A customer who takes a break after opening a game cannot bet in it.
email="gatep1-$(date +%s)-$RANDOM@example.com"; password="Gate-Check-Pass-P1"
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
excluded="$(launch_token c)"
[[ -n "$excluded" ]] || fail "the customer could not open the game"
expect '20[0-9]' "$(api c POST /api/me/exclusions -d '{"kind":"coolingOff","days":1,"reason":"P1 gate"}')" "the customer takes a one-day break"
refused=""
for _ in $(seq 1 15); do
  code="$(api o POST /casino-sim/faults/pragmatic/drill -d "{\"session\":\"$excluded\",\"scenario\":\"bet\",\"game\":\"$game\",\"amount\":100}" || true)"
  [[ "$code" == 200 ]] && jq -e '.exchanges[-1].error == 6' "$work/body" >/dev/null && { refused=1; break; }
  sleep 2
done
[[ -n "$refused" ]] || fail "the self-excluded customer's bet was not refused with error 6: $(head -c 400 "$work/body")"
echo "ok   a bet from a customer on a break was refused (error 6)"

echo "P1 gate (Pragmatic: duplicate bet, refund before bet, stored-stake refund, bad hash, allowlist, demo, self-exclusion) passed"
