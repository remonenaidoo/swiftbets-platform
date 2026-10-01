#!/usr/bin/env bash
# E4 gate through the gateway, the parts landed so far: the kill switch stops placement within five seconds and lifting
# it reopens placement; with system bets switched on, a banker Trixie is accepted as four lines and bet history shows it.
# usage: GATEWAY=http://localhost:7100 scripts/gate-e4.sh
set -euo pipefail

gateway="${GATEWAY:-http://localhost:7100}"
demo_password="${DEMO_PASSWORD:-Local-Dev-Demo-1}"
work="$(mktemp -d)"
trap 'set_config placement.kill-switch off "gate cleanup" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

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
set_config() { api admin PUT "/admin/config/$1" -d "{\"value\":\"$2\",\"reason\":\"$3\"}"; }
place() { api punter POST /coupons -H "Idempotency-Key: gate4-$(date +%s%N)-$RANDOM" -d "$1"; }

expect 200 "$(api admin POST /session/login -d "{\"username\":\"admin1\",\"password\":\"$demo_password\"}")" "admin signs in"
expect 200 "$(api punter POST /session/login -d "{\"username\":\"punter1\",\"password\":\"$demo_password\"}")" "punter signs in"

# Four different open fixtures, first selection of their first open market each.
expect 200 "$(api punter GET '/fixtures/?limit=50')" "list open fixtures"
jq -c '[.[] | select(.status == "open" or .status == "scheduled") | {fixtureId, market: (.markets[] | select(.status == "open"))} |
  {fixtureId, marketId: .market.marketId, selectionId: .market.selections[0].selectionId, odds: .market.selections[0].odds}] | unique_by(.fixtureId) | .[0:4]' \
  "$work/body" > "$work/legs"
[[ "$(jq 'length' "$work/legs")" -ge 4 ]] || fail "need four open fixtures, found $(jq 'length' "$work/legs")"
cp "$work/body" "$work/fixtures"
leg() {
  local i="$1" banker="${2:-false}"
  jq -c --argjson i "$i" --argjson banker "$banker" --slurpfile fx "$work/fixtures" \
    '.[$i] as $l | {fixtureId: $l.fixtureId, marketId: $l.marketId, selectionId: $l.selectionId, odds: $l.odds,
      offerVersion: ($fx[0][] | select(.fixtureId == $l.fixtureId) | .offerVersion), banker: $banker}' "$work/legs"
}
single="{\"stake\":1000,\"currency\":\"ZAR\",\"legs\":[$(leg 0)]}"

# 1. Kill switch: placement stops within five seconds and reopens when lifted.
expect 201 "$(place "$single")" "a single is placed while betting is open"
expect 200 "$(set_config placement.kill-switch on 'E4 gate drill')" "admin turns the kill switch on"
started=$(date +%s%N)
until [[ "$(place "$single")" == 422 ]] && jq -e '.code == "placement_suspended"' "$work/body" >/dev/null; do
  (( ($(date +%s%N) - started) / 1000000 <= 5000 )) || fail "placement still open five seconds after the kill switch"
  sleep 0.25
done
echo "ok   placement refused $(( ($(date +%s%N) - started) / 1000000 )) ms after the kill switch"
expect 200 "$(set_config placement.kill-switch off 'E4 gate drill over')" "admin turns the kill switch off"
started=$(date +%s%N)
until [[ "$(place "$single")" == 201 ]]; do
  (( ($(date +%s%N) - started) / 1000000 <= 5000 )) || fail "placement still closed five seconds after lifting the kill switch: $(head -c 300 "$work/body")"
  sleep 0.25
done
echo "ok   placement reopened"

# 2. A banker Trixie: refused while system bets are off, four lines once they are on.
trixie="{\"stake\":400,\"currency\":\"ZAR\",\"legs\":[$(leg 0 true),$(leg 1),$(leg 2),$(leg 3)],\"bets\":[{\"name\":\"trixie\",\"unitStake\":100}]}"
current="$(api admin GET /admin/config/ >/dev/null; jq -r '.[] | select(.key == "flags.system-bets") | .value' "$work/body")"
if [[ "$current" != "true" ]]; then
  expect 422 "$(place "$trixie")" "a banker Trixie is refused while system bets are off"
  jq -e '.code == "system_bets_unavailable"' "$work/body" >/dev/null || fail "refusal was $(jq -r .code "$work/body")"
  expect 200 "$(set_config flags.system-bets true 'E4 gate: settlement reads V2')" "admin opens system bets"
fi
started=$(date +%s%N)
until [[ "$(place "$trixie")" == 201 ]]; do
  (( ($(date +%s%N) - started) / 1000000 <= 5000 )) || fail "banker Trixie still refused: $(head -c 300 "$work/body")"
  sleep 0.25
done
[[ "$(jq '.bets[0].lines' "$work/body")" == 4 ]] || fail "the Trixie has $(jq '.bets[0].lines' "$work/body") lines"
[[ "$(jq '[.legs[] | select(.banker)] | length' "$work/body")" == 1 ]] || fail "the banker was not kept"
echo "ok   banker Trixie placed as four lines"
trixie_id="$(jq -r '.couponId' "$work/body")"

# 3. Bet history, served by its own service, shows the Trixie as a system bet.
for _ in $(seq 1 30); do
  if [[ "$(api punter GET '/me/coupons?limit=20')" == 200 ]] &&
    jq -e --arg id "$trixie_id" 'any(.[]; .couponId == $id and .betType == "system" and .stake == 400)' "$work/body" >/dev/null; then
    echo "ok   bet history shows the Trixie as a system bet"
    break
  fi
  sleep 2
done
jq -e --arg id "$trixie_id" 'any(.[]; .couponId == $id)' "$work/body" >/dev/null || fail "bet history never showed $trixie_id: $(head -c 300 "$work/body")"

echo "E4 gate (kill switch, system bets, bet history) passed"
