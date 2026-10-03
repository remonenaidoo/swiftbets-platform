#!/usr/bin/env bash
# E3 gate through the gateway against the simulated provider: an unverified customer cannot withdraw; a deposit whose
# webhooks arrive twice and out of order credits once; after KYC a small withdrawal pays and a large one waits for an
# operator; a settlement only the provider knows is flagged by reconciliation and opens a Steward incident.
# usage: GATEWAY=http://localhost:7100 MAILPIT=http://localhost:7125 SIMULATOR=http://localhost:7140 scripts/gate-e3.sh
set -euo pipefail

gateway="${GATEWAY:-http://localhost:7100}"
mailpit="${MAILPIT:-http://localhost:7125}"
simulator="${SIMULATOR:-http://localhost:7140}"
sim_key="${PAYMENTS_SIMULATOR_API_KEY:-local-dev-simulator-key}"
demo_password="${DEMO_PASSWORD:-Local-Dev-Demo-1}"
work="$(mktemp -d)"
trap 'rm -rf "$work"; curl -sS -o /dev/null -X PUT "$simulator/__faults" -H "Content-Type: application/json" -d "{}" || true' EXIT
email="gate3-$(date +%s)-$RANDOM@example.com"
password="Gate-Check-Pass-3"

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
available() { api c GET /me/wallet/accounts >/dev/null; jq -r '[.[] | select(.currency == "ZAR") | .available] | first // 0' "$work/body"; }
# Polls a GET until the jq filter prints "true", up to about 60 seconds.
until_true() {
  local jar="$1" path="$2" filter="$3" step="$4"
  for _ in $(seq 1 30); do
    if [[ "$(api "$jar" GET "$path")" == 200 ]] && [[ "$(jq -r "$filter" "$work/body")" == "true" ]]; then
      echo "ok   $step"
      return
    fi
    sleep 2
  done
  fail "$step: last answer $(head -c 400 "$work/body")"
}

# A new customer with a confirmed email.
code="$(api c POST /auth/register -d "{\"email\":\"$email\",\"password\":\"$password\",\"dateOfBirth\":\"1990-01-01\",\"country\":\"ZA\",\"currency\":\"ZAR\"}")"
expect '20[0-9]' "$code" "register ($email)"
token=""
for _ in $(seq 1 30); do
  id="$(curl -sS "$mailpit/api/v1/search?query=to:$email" | jq -r '.messages[0].ID // empty')"
  if [[ -n "$id" ]]; then
    token="$(curl -sS "$mailpit/api/v1/message/$id" | jq -r '.Text' | grep -oE 'token=[^[:space:]&"]+' | head -n 1 | cut -d= -f2-)"
    [[ -n "$token" ]] && break
  fi
  sleep 2
done
[[ -n "$token" ]] || fail "verification email never reached Mailpit"
token="$(printf '%b' "${token//%/\\x}")"
expect '20[04]' "$(api c POST /auth/verify-email -d "{\"token\":\"$token\"}")" "verify email"
expect 200 "$(api c POST /session/login -d "{\"username\":\"$email\",\"password\":\"$password\"}")" "customer signs in"
expect 200 "$(api o POST /session/login -d "{\"username\":\"operator1\",\"password\":\"$demo_password\"}")" "operator signs in"

# 1. No withdrawal before KYC.
expect 422 "$(api c POST /me/withdrawals -d '{"amount":10000,"currency":"ZAR"}')" "unverified customer's withdrawal is refused"
[[ "$(jq -r '.code' "$work/body")" == "kyc_required" ]] || fail "refusal code was $(jq -r '.code' "$work/body"), wanted kyc_required"

# 2. A deposit whose webhooks are duplicated and reordered credits once.
expect 200 "$(curl -sS -o "$work/body" -w '%{http_code}' -X PUT "$simulator/__faults" -H 'Content-Type: application/json' -d '{"duplicateWebhooks":true,"reverseOrder":true}')" "simulator duplicates and reorders webhooks"
before="$(available)"
expect 201 "$(api c POST /me/deposits -d '{"amount":1000000,"currency":"ZAR"}')" "deposit of R10 000 started"
deposit_id="$(jq -r '.paymentId' "$work/body")"
reference="$(jq -r '.checkoutUrl' "$work/body" | sed 's#.*/checkout/##')"
expect 200 "$(curl -sS -o "$work/body" -w '%{http_code}' -X POST "$simulator/v1/deposits/$reference/complete" -H "X-Api-Key: $sim_key")" "customer pays at checkout"
until_true c "/me/deposits/$deposit_id" '.status == "succeeded"' "deposit succeeded"
sleep 5
after="$(available)"
[[ $((after - before)) -eq 1000000 ]] || fail "balance moved by $((after - before)), wanted exactly 1000000 once"
echo "ok   credited exactly once despite duplicate and out-of-order webhooks"
curl -sS -o /dev/null -X PUT "$simulator/__faults" -H 'Content-Type: application/json' -d '{}'

# 3. KYC, then a small withdrawal pays and a large one waits for an operator.
# Documents go to the review queue, an operator approves, then a bank account in that name verifies.
printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\0\x01\0\0\0\x01\x08\x06\0\0\0\x1f\x15\xc4\x89' > "$work/id.png"
printf '%%PDF-1.4\n%%%%EOF\n' > "$work/poa.pdf"
code="$(curl -sS -o "$work/body" -w '%{http_code}' -b "$work/c" -c "$work/c" -X POST "$gateway/api/me/kyc/documents" -H 'X-SwiftBets-Csrf: 1' \
  -F documentType=idDocument -F documentNumber=8001015009087 -F 'legalName=Gate Three' -F "identity=@$work/id.png;type=image/png" -F "proofOfAddress=@$work/poa.pdf;type=application/pdf")"
expect '20[01]' "$code" "KYC documents uploaded"
expect 200 "$(api c GET /profile)" "customer profile" && cp "$work/body" "$work/profile"
expect 200 "$(api o GET /admin/kyc/queue)" "operator sees the KYC queue"
case_id="$(jq -r --arg u "$(jq -r '.userId' "$work/profile")" '[.[] | select(.userId == $u)][0].caseId' "$work/body")"
expect '20[04]' "$(api o POST "/admin/kyc/cases/$case_id/approve" -d '{"reason":"gate check"}')" "operator approves KYC"
until_true c /me/compliance '.kycStatus == "verified"' "KYC verified"
expect 200 "$(api c PUT /me/bank-account -d '{"bankCode":"fnb","accountHolder":"G Three","accountNumber":"62000001234","accountType":"cheque"}')" "bank account saved"
[[ "$(jq -r '.status' "$work/body")" == "verified" ]] || fail "bank account is $(jq -r '.status' "$work/body"), wanted verified"
sleep 3
expect 201 "$(api c POST /me/withdrawals -d '{"amount":20000,"currency":"ZAR"}')" "small withdrawal accepted"
small="$(jq -r '.withdrawalId' "$work/body")"
until_true c /me/payments "[.[] | select(.id == \"$small\")][0].status == \"paid\"" "small withdrawal paid"
expect 201 "$(api c POST /me/withdrawals -d '{"amount":600000,"currency":"ZAR"}')" "large withdrawal accepted"
large="$(jq -r '.withdrawalId' "$work/body")"
[[ "$(jq -r '.status' "$work/body")" == "awaitingApproval" ]] || fail "large withdrawal is $(jq -r '.status' "$work/body"), wanted awaitingApproval"
echo "ok   large withdrawal waits for an operator"
expect 200 "$(api o GET /admin/payments/withdrawals)" "operator sees the approval queue"
jq -e --arg id "$large" 'any(.[]; .withdrawalId == $id)' "$work/body" >/dev/null || fail "the large withdrawal is not in the queue"
expect 200 "$(api o POST "/admin/payments/withdrawals/$large/approve")" "operator approves"
until_true c /me/payments "[.[] | select(.id == \"$large\")][0].status == \"paid\"" "approved withdrawal paid"
[[ "$(available)" -eq $((after - 620000)) ]] || fail "balance after withdrawals is $(available), wanted $((after - 620000))"
echo "ok   both withdrawals left the balance"

# 4. Drift: the provider settles a payment we never saw; reconciliation flags it and Steward opens an incident.
day="$(TZ=Africa/Johannesburg date +%F)"
ghost="dep_gate$(date +%s)"
expect 202 "$(curl -sS -o "$work/body" -w '%{http_code}' -X POST "$simulator/__settlements" -H 'Content-Type: application/json' -d "{\"reference\":\"$ghost\",\"amount\":4200,\"currency\":\"ZAR\"}")" "provider settles an unknown deposit"
expect 200 "$(api o POST "/admin/payments/reconciliation/simulator/run?day=$day")" "reconciliation run for $day"
jq -e --arg ref "$ghost" 'any(.drifts[]; .reference == $ref)' "$work/body" >/dev/null || fail "reconciliation did not flag $ghost: $(head -c 400 "$work/body")"
echo "ok   drift flagged"
until_true o "/steward/incidents?limit=20" "any(.[]; ((.kind | tostring | ascii_downcase | test(\"paymentdrift\")) and (.subject | test(\"simulator\"))))" "Steward opened a payment drift incident"

echo "E3 gate passed"
