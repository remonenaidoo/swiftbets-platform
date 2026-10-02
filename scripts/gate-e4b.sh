#!/usr/bin/env bash
# E4b gate through the gateway:
#   1. a trader voids a market and the punter's single settles as void with the stake returned;
#   2. a Trixie is resettled through the stack from out-of-order results, and the older result changes nothing;
#   3. a cashout racing a late result settles and pays exactly once;
#   4. a trader's void on a cashed-out bet is rejected explicitly, and the trader can see why.
# Results in a chosen order come from offer's result drill, which exists only where fault injection is enabled.
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

# Open match-result markets at least two minutes from kickoff, latest first, so earlier gates' bets on the first are untouched.
expect 200 "$(api punter GET '/fixtures/?limit=60')" "list open fixtures"
jq -c '[.[] | select((.status == "open" or .status == "scheduled") and ((.kickoffAt | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) > (now + 120)))
  | {fixtureId, offerVersion, market: (.markets[] | select(.status == "open" and .type == "matchResult"))}
  | {fixtureId, offerVersion, marketId: .market.marketId, selectionId: "home", odds: (.market.selections[] | select(.selectionId == "home") | .odds)}] | reverse' "$work/body" > "$work/legs"
(( $(jq length "$work/legs") >= 6 )) || fail "need six open fixtures, found $(jq length "$work/legs")"
leg_at() { jq -c --argjson i "$1" '.[$i]' "$work/legs"; }
leg="$(leg_at 0)"
jq -c '.' <<<"$leg" > "$work/leg"

expect 201 "$(api punter POST /coupons -H "Idempotency-Key: gate4b-$(date +%s%N)" -d "{\"stake\":1000,\"currency\":\"ZAR\",\"legs\":[$leg]}")" "a single is placed"
coupon="$(jq -r '.couponId' "$work/body")"

void="$(jq -c '{scope: "market", action: "void", fixtureId, marketId, reason: "E4b gate: market abandoned"}' "$work/leg")"
expect 202 "$(api admin POST /admin/trading/manual-results -d "$void")" "trader voids the market"
[[ "$(jq -r '.operatorId' "$work/body")" != "00000000-0000-0000-0000-000000000000" ]] || fail "the void carries no operator"

# Waits until bet history shows the coupon matching a jq condition on its row ($c), within a minute.
await_coupon() {
  local id="$1" condition="$2" step="$3"
  for _ in $(seq 1 30); do
    if [[ "$(api punter GET '/me/coupons?limit=50')" == 200 ]] &&
      jq -e --arg id "$id" "any(.[]; .couponId == \$id and ($condition))" "$work/body" >/dev/null; then
      echo "ok   $step"
      return 0
    fi
    sleep 2
  done
  fail "$step: $(jq -c --arg id "$id" '.[] | select(.couponId == $id)' "$work/body")"
}
row() { jq -c --arg id "$1" '.[] | select(.couponId == $id)' "$work/body"; }
drill() { api admin POST /admin/trading/drills/results -d "{\"fixtureId\":\"$1\",\"version\":$2,\"status\":\"$3\",\"homeGoals\":$4,\"awayGoals\":$5}"; }
place() { api punter POST /coupons -H "Idempotency-Key: gate4b-$(date +%s%N)-$RANDOM" -d "$1"; }
single_on() { echo "{\"stake\":1000,\"currency\":\"ZAR\",\"legs\":[$(jq -c '{fixtureId, marketId, selectionId, odds, offerVersion}' <<<"$1")]}"; }

# 1. A market void returns the stake.
await_coupon "$coupon" '.status == "void" and .payout == 1000' "the single settled as void with the stake returned"

# 2. A Trixie resettled from out-of-order results: v4 wins all three, v6 corrects one leg to a loss, a late v5 changes nothing.
config="$(api admin GET /admin/config/ >/dev/null; jq -r '.[] | select(.key == "flags.system-bets") | .value' "$work/body")"
if [[ "$config" != "true" ]]; then
  expect 200 "$(api admin PUT /admin/config/flags.system-bets -d '{"value":"true","reason":"E4b gate: Trixie"}')" "admin opens system bets"
fi
a="$(leg_at 1)"; b="$(leg_at 2)"; c="$(leg_at 3)"
trixie="{\"stake\":400,\"currency\":\"ZAR\",\"legs\":[$(jq -c '{fixtureId, marketId, selectionId, odds, offerVersion}' <<<"$a"),$(jq -c '{fixtureId, marketId, selectionId, odds, offerVersion}' <<<"$b"),$(jq -c '{fixtureId, marketId, selectionId, odds, offerVersion}' <<<"$c")],\"bets\":[{\"name\":\"trixie\",\"unitStake\":100}]}"
for _ in $(seq 1 20); do [[ "$(place "$trixie")" == 201 ]] && break; sleep 0.5; done
[[ "$(jq '.bets[0].lines' "$work/body")" == 4 ]] || fail "the Trixie was not placed as four lines: $(head -c 300 "$work/body")"
trixie_id="$(jq -r '.couponId' "$work/body")"
echo "ok   a Trixie is placed as four lines"
for l in "$a" "$b" "$c"; do expect 202 "$(drill "$(jq -r .fixtureId <<<"$l")" 4 official 2 0)" "result v4 2-0 for $(jq -r .fixtureId <<<"$l")"; done
await_coupon "$trixie_id" '.settlementVersion == 1 and .payout > 400' "every Trixie line won at v4"
first_payout="$(row "$trixie_id" | jq .payout)"
expect 202 "$(drill "$(jq -r .fixtureId <<<"$a")" 6 correction 0 1)" "correction v6 turns one leg into a loss"
expect 202 "$(drill "$(jq -r .fixtureId <<<"$a")" 5 official 3 0)" "an older v5 arrives late"
await_coupon "$trixie_id" ".settlementVersion == 2 and .payout > 0 and .payout < $first_payout" "the Trixie resettled at v6 to the one surviving double"
sleep 6
await_coupon "$trixie_id" '.settlementVersion == 2' "the late v5 changed nothing"
await_coupon "$trixie_id" '.paidToDate == .payout' "payout clawed back to the resettled amount"

# 3. A cashout racing a late result settles once and pays once, whichever wins the coupon lock.
d="$(leg_at 4)"
expect 201 "$(place "$(single_on "$d")")" "a single to cash out is placed"
racing="$(jq -r '.couponId' "$work/body")"
await_coupon "$racing" '.status == "open"' "bet history shows it open"
for _ in $(seq 1 20); do [[ "$(api punter POST /cashout/quote -d "{\"couponId\":\"$racing\"}")" == 200 ]] && break; sleep 1; done
token="$(jq -r '.quoteToken // empty' "$work/body")"
[[ -n "$token" ]] || fail "no cashout quote: $(head -c 300 "$work/body")"
( curl -sS -o "$work/race-cashout" -w '%{http_code}' -b "$work/punter" -X POST "$gateway/api/cashout/execute" -H 'Content-Type: application/json' -H 'X-SwiftBets-Csrf: 1' -d "{\"quoteToken\":\"$token\"}" > "$work/race-cashout.status" ) &
( curl -sS -o "$work/race-result" -w '%{http_code}' -b "$work/admin" -X POST "$gateway/api/admin/trading/drills/results" -H 'Content-Type: application/json' -H 'X-SwiftBets-Csrf: 1' -d "{\"fixtureId\":\"$(jq -r .fixtureId <<<"$d")\",\"version\":4,\"status\":\"official\",\"homeGoals\":2,\"awayGoals\":0}" > "$work/race-result.status" ) &
wait
echo "ok   cashout ($(cat "$work/race-cashout.status")) and late result ($(cat "$work/race-result.status")) raced"
await_coupon "$racing" '(.status == "cashedout" or .status == "won") and .settlementVersion == 1 and .paidToDate == .payout and .payout > 0' "exactly one settlement, paid once"
sleep 6
await_coupon "$racing" '.settlementVersion == 1 and .paidToDate == .payout' "nothing settled or paid a second time"

# 4. A trader's void on a cashed-out bet is rejected explicitly, and the trader sees why.
e="$(leg_at 5)"
expect 201 "$(place "$(single_on "$e")")" "a single is placed"
held="$(jq -r '.couponId' "$work/body")"
await_coupon "$held" '.status == "open"' "bet history shows it open"
for _ in $(seq 1 20); do [[ "$(api punter POST /cashout/quote -d "{\"couponId\":\"$held\"}")" == 200 ]] && break; sleep 1; done
expect 200 "$(api punter POST /cashout/execute -d "{\"quoteToken\":\"$(jq -r .quoteToken "$work/body")\"}")" "the punter cashes it out"
await_coupon "$held" '.status == "cashedout"' "bet history shows it cashed out"
expect 202 "$(api admin POST /admin/trading/manual-results -d "$(jq -c '{scope: "market", action: "void", fixtureId, marketId, reason: "E4b gate: void after cashout"}' <<<"$e")")" "trader voids the cashed-out bet's market"
manual="$(jq -r '.manualResultId' "$work/body")"
for _ in $(seq 1 30); do
  if [[ "$(api admin GET "/admin/trading/manual-results/$manual")" == 200 ]] &&
    jq -e --arg id "$held" 'any(.rejections[]; .couponId == $id and .code == "coupon_cashed_out")' "$work/body" >/dev/null; then
    echo "ok   the trader sees the void rejected: coupon cashed out"
    break
  fi
  sleep 2
done
jq -e --arg id "$held" 'any(.rejections[]?; .couponId == $id)' "$work/body" >/dev/null || fail "no explicit rejection for $held: $(head -c 300 "$work/body")"
await_coupon "$held" '.status == "cashedout" and .settlementVersion == 1' "the cashed-out bet is unchanged"

echo "E4b gate (void, out-of-order resettlement, cashout race, rejection on a cashed-out bet) passed"
