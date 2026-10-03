#!/usr/bin/env bash
# E9 gate through the gateway:
#   1. a settled bet produces an email and an in-app message for its customer;
#   2. today's turnover and GGR in the reporting warehouse reconcile to the wallet ledger;
#   3. a role without a permission cannot see or call the screen (trader1 has no reports.read; admin1 does).
# usage: GATEWAY=http://127.0.0.1:7100 MAILPIT=http://127.0.0.1:7125 SIMULATOR=http://127.0.0.1:7140 scripts/gate-e9.sh
set -euo pipefail

gateway="${GATEWAY:-http://127.0.0.1:7100}"
mailpit="${MAILPIT:-http://127.0.0.1:7125}"
simulator="${SIMULATOR:-http://127.0.0.1:7140}"
sim_key="${PAYMENTS_SIMULATOR_API_KEY:-local-dev-simulator-key}"
demo_password="${DEMO_PASSWORD:-Local-Dev-Demo-1}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
email="gate9-$(date +%s)-$RANDOM@example.com"
password="Gate-Check-Pass-9"

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

# 1. A customer with an email address deposits, bets, and the bet is settled as a win.
expect '20[0-9]' "$(api c POST /auth/register -d "{\"email\":\"$email\",\"password\":\"$password\",\"dateOfBirth\":\"1990-01-01\",\"country\":\"ZA\",\"currency\":\"ZAR\"}")" "a customer registers ($email)"
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
expect '20[04]' "$(api c POST /auth/verify-email -d "{\"token\":\"$(printf '%b' "${token//%/\\x}")\"}")" "the customer verifies their email"
expect 200 "$(api c POST /session/login -d "{\"username\":\"$email\",\"password\":\"$password\"}")" "the customer signs in"
expect 201 "$(api c POST /me/deposits -d '{"amount":10000,"currency":"ZAR"}')" "deposit of R100 started"
reference="$(jq -r '.checkoutUrl' "$work/body" | sed 's#.*/checkout/##')"
expect 200 "$(curl -sS -o "$work/body" -w '%{http_code}' -X POST "$simulator/v1/deposits/$reference/complete" -H "X-Api-Key: $sim_key")" "the customer pays at checkout"
for _ in $(seq 1 30); do
  [[ "$(api c GET /me/balance)" == 200 ]] && (( $(jq -r '.available.minorUnits' "$work/body") >= 10000 )) && break
  sleep 2
done
echo "ok   the deposit reached the balance"

expect 200 "$(api c GET '/fixtures/?limit=60')" "list open fixtures"
fixture="$(jq -r '[.[] | select((.status == "open" or .status == "scheduled") and ((.kickoffAt | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) > (now + 600)))] | .[length / 2 | floor].fixtureId' "$work/body")"
[[ -n "$fixture" && "$fixture" != null ]] || fail "no open fixture"
coupon=""
for _ in $(seq 1 20); do
  api c GET "/fixtures/$fixture" >/dev/null
  leg="$(jq -c '{fixtureId, offerVersion, marketId: (.markets[] | select(.type == "matchResult") | .marketId), selectionId: "home",
    odds: (.markets[] | select(.type == "matchResult") | .selections[] | select(.selectionId == "home") | .odds)}' "$work/body")"
  if [[ "$(api c POST /coupons -H "Idempotency-Key: gate9-$(date +%s%N)" -d "{\"stake\":1000,\"currency\":\"ZAR\",\"legs\":[$leg]}")" == 201 ]]; then
    coupon="$(jq -r '.couponId' "$work/body")"
    break
  fi
  sleep 0.5
done
[[ -n "$coupon" ]] || fail "the bet was not placed: $(head -c 300 "$work/body")"
echo "ok   a R10 single on home is placed"
expect 200 "$(api a POST /session/login -d "{\"username\":\"admin1\",\"password\":\"$demo_password\"}")" "admin signs in"
expect 202 "$(api a POST /admin/trading/drills/results -d "{\"fixtureId\":\"$fixture\",\"version\":1,\"status\":\"official\",\"homeGoals\":2,\"awayGoals\":0}")" "the result 2-0 is published"

for _ in $(seq 1 45); do
  [[ "$(api c GET /me/inbox)" == 200 ]] && jq -e 'any(.[]; .category == "bet-settled" and .title == "Your bet won")' "$work/body" >/dev/null && break
  sleep 2
done
jq -e 'any(.[]; .category == "bet-settled" and .title == "Your bet won")' "$work/body" >/dev/null || fail "no in-app message for the settled bet: $(head -c 300 "$work/body")"
echo "ok   the customer's inbox says: $(jq -r '[.[] | select(.category == "bet-settled")][0].body' "$work/body")"
subject=""
for _ in $(seq 1 30); do
  subject="$(curl -sS "$mailpit/api/v1/search?query=to:$email%20subject:%22Your%20bet%20won%22" | jq -r '.messages[0].Subject // empty')"
  [[ -n "$subject" ]] && break
  sleep 2
done
[[ "$subject" == "Your bet won" ]] || fail "no email for the settled bet"
echo "ok   the customer was emailed: $subject"

# 2. Today's figures reconcile to the ledger once every event has been consumed.
today="$(date -u +%F)"
matched=""
for _ in $(seq 1 30); do
  expect 200 "$(api a POST "/admin/reports/reconciliations/$today")" "reconcile $today" >/dev/null
  if jq -e '.matched' "$work/body" >/dev/null; then matched=yes; break; fi
  sleep 3
done
[[ -n "$matched" ]] || fail "today does not reconcile: $(jq -c '.mismatches' "$work/body")"
echo "ok   $today reconciles to the ledger: $(jq -c '.figures | {coupons, sportsTurnover, sportsPayouts, casinoStaked, casinoReturned, ggr}' "$work/body")"

# 3. A trader has no finance reports: not in their session, refused by the service; an admin has them.
expect 200 "$(api t POST /session/login -d "{\"username\":\"trader1\",\"password\":\"$demo_password\"}")" "trader signs in"
expect 200 "$(api t GET /session)" "read the trader's session"
jq -e '.permissions | index("reports.read") | not' "$work/body" >/dev/null || fail "trader1 carries reports.read"
expect 403 "$(api t GET "/admin/reports/daily?from=$today&to=$today")" "the trader is refused finance reports"
expect 403 "$(api t GET /admin/roles)" "the trader is refused role management"
expect 200 "$(api a GET "/admin/reports/daily?from=$today&to=$today")" "the admin reads finance reports"

echo "E9 gate (settled bet emailed and in the inbox, ledger reconciliation, permissions) passed"
