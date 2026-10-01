#!/usr/bin/env bash
# E1 gate through the gateway: a new visitor registers, verifies by the emailed link, signs in on two devices, sees both,
# revokes the other one, and that device is signed out; the account page renders on the site; a seeded user still signs in.
# usage: GATEWAY=http://localhost:7100 MAILPIT=http://localhost:7125 scripts/gate-e1.sh
set -euo pipefail

gateway="${GATEWAY:-http://localhost:7100}"
mailpit="${MAILPIT:-http://localhost:7125}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
email="gate-$(date +%s)-$RANDOM@example.com"
password="Gate-Check-Pass-1"

api() {
  local jar="$1" method="$2" path="$3"
  shift 3
  curl -sS -o "$work/body" -w '%{http_code}' -b "$work/$jar" -c "$work/$jar" -X "$method" "$gateway/api$path" \
    -H 'Content-Type: application/json' -H 'X-SwiftBets-Csrf: 1' "$@"
}
expect() {
  local want="$1" got="$2" step="$3"
  [[ "$got" == "$want" ]] || { echo "FAIL $step: HTTP $got, wanted $want: $(head -c 400 "$work/body")" >&2; exit 1; }
  echo "ok   $step"
}

code="$(api a POST /auth/register -d "{\"email\":\"$email\",\"password\":\"$password\",\"dateOfBirth\":\"1990-01-01\",\"country\":\"ZA\",\"currency\":\"ZAR\"}")"
[[ "$code" =~ ^20[0-9]$ ]] || expect 202 "$code" "register"
echo "ok   register ($email)"

code="$(api a POST /auth/register -d "{\"email\":\"minor-$email\",\"password\":\"$password\",\"dateOfBirth\":\"$(date -u -d '-17 years' +%F)\",\"country\":\"ZA\",\"currency\":\"ZAR\"}")"
[[ "$code" =~ ^4[0-9][0-9]$ ]] || { echo "FAIL age gate: a 17-year-old got HTTP $code" >&2; exit 1; }
echo "ok   age gate refuses under 18 (HTTP $code)"

token=""
for _ in $(seq 1 30); do
  id="$(curl -sS "$mailpit/api/v1/search?query=to:$email" | jq -r '.messages[0].ID // empty')"
  if [[ -n "$id" ]]; then
    token="$(curl -sS "$mailpit/api/v1/message/$id" | jq -r '.Text' | grep -oE 'token=[^[:space:]&"]+' | head -n 1 | cut -d= -f2-)"
    [[ -n "$token" ]] && break
  fi
  sleep 2
done
[[ -n "$token" ]] || { echo "FAIL verification email never reached Mailpit" >&2; exit 1; }
token="$(printf '%b' "${token//%/\\x}")"
echo "ok   verification email delivered"

code="$(api a POST /auth/verify-email -d "{\"token\":\"$token\"}")"
[[ "$code" =~ ^20[04]$ ]] || expect 204 "$code" "verify email"
echo "ok   verify email"
expect 200 "$(api a POST /session/login -H 'User-Agent: gate-laptop' -d "{\"username\":\"$email\",\"password\":\"$password\"}")" "sign in on device one"
expect 200 "$(api b POST /session/login -H 'User-Agent: gate-phone' -d "{\"username\":\"$email\",\"password\":\"$password\"}")" "sign in on device two"

expect 200 "$(api a GET /profile)" "profile"
[[ "$(jq -r '.emailVerified' "$work/body")" == "true" ]] || { echo "FAIL profile does not show the email as verified" >&2; exit 1; }

expect 200 "$(api a GET /session/devices)" "list devices"
[[ "$(jq 'length' "$work/body")" == "2" ]] || { echo "FAIL expected two devices: $(cat "$work/body")" >&2; exit 1; }
other="$(jq -r '.[] | select(.current | not) | .id' "$work/body")"

expect 204 "$(api a DELETE "/session/devices/$other")" "revoke device two"
expect 401 "$(api b GET /profile)" "device two is signed out"
expect 200 "$(api a GET /profile)" "device one is still signed in"

page="$(curl -sS -o "$work/page" -w '%{http_code}' -b "$work/a" "$gateway/account")"
expect 200 "$page" "account page renders on the site"
grep -q "$email" "$work/page" || { echo "FAIL account page does not show the signed-in email" >&2; exit 1; }

expect 200 "$(api c POST /session/login -d '{"username":"punter1","password":"'"${DEMO_PASSWORD:-Local-Dev-Demo-1}"'"}')" "seeded user signs in against identity"
echo "E1 gate passed"
