#!/usr/bin/env bash
# E4b gate through the gateway, the parts landed so far: a trader voids a market from the console and the punter's
# single on it settles as void with the stake returned, visible in bet history.
# usage: GATEWAY=http://localhost:7100 scripts/gate-e4b.sh
set -euo pipefail

gateway="${GATEWAY:-http://localhost:7100}"
demo_password="${DEMO_PASSWORD:-Local-Dev-Demo-1}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

api() {
  local jar="$1" method="$2" path="$3"
  shift 3
  curl -sS -o "$work/body" -w '%{http_code}' -b "$work/$jar" -c "$work/$jar" -X "$method" "$gateway/api$path" \
    -H 'Content-Type: application/json' -H 'X-SwiftBets-Csrf: 1' "$@"
}
expect() {
  local want="$1" got="$2" step="$3"
  [[ "$got" =~ ^($want)$ ]] || { echo "FAIL $step: HTTP $got, wanted $want: $(head -c 400 "$work/body")" >&2; exit 1; }
  echo "ok   $step"
}
fail() { echo "FAIL $*" >&2; exit 1; }

expect 200 "$(api admin POST /session/login -d "{\"username\":\"admin1\",\"password\":\"$demo_password\"}")" "trader signs in"
expect 200 "$(api punter POST /session/login -d "{\"username\":\"punter1\",\"password\":\"$demo_password\"}")" "punter signs in"

# The last open fixture, so earlier gates' bets on the first ones are untouched.
expect 200 "$(api punter GET '/fixtures/?limit=50')" "list open fixtures"
jq -c '[.[] | select(.status == "open" or .status == "scheduled") | {fixtureId, offerVersion, market: (.markets[] | select(.status == "open"))}] | last |
  {fixtureId, offerVersion, marketId: .market.marketId, selectionId: .market.selections[0].selectionId, odds: .market.selections[0].odds}' "$work/body" > "$work/leg"
[[ "$(jq -r '.marketId // empty' "$work/leg")" != "" ]] || fail "no open market to bet on"
leg="$(jq -c '{fixtureId, marketId, selectionId, odds, offerVersion}' "$work/leg")"

expect 201 "$(api punter POST /coupons -H "Idempotency-Key: gate4b-$(date +%s%N)" -d "{\"stake\":1000,\"currency\":\"ZAR\",\"legs\":[$leg]}")" "a single is placed"
coupon="$(jq -r '.couponId' "$work/body")"

void="$(jq -c '{scope: "market", action: "void", fixtureId, marketId, reason: "E4b gate: market abandoned"}' "$work/leg")"
expect 202 "$(api admin POST /admin/trading/manual-results -d "$void")" "trader voids the market"
[[ "$(jq -r '.operatorId' "$work/body")" != "00000000-0000-0000-0000-000000000000" ]] || fail "the void carries no operator"

for _ in $(seq 1 30); do
  if [[ "$(api punter GET '/me/coupons?limit=50')" == 200 ]] &&
    jq -e --arg id "$coupon" 'any(.[]; .couponId == $id and .status == "void" and .payout == 1000)' "$work/body" >/dev/null; then
    echo "ok   the single settled as void with the stake returned"
    echo "E4b gate (manual void) passed"
    exit 0
  fi
  sleep 2
done
fail "coupon $coupon never settled as void: $(jq -c --arg id "$coupon" '.[] | select(.couponId == $id)' "$work/body")"
