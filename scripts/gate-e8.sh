#!/usr/bin/env bash
# E8 gate on the live stack:
#   1. under concurrent placement, every liability change reaches an operator's live connection in under 1 s;
#   2. an exposure cap breach refuses placement within one hydration interval, and lifting it reopens the fixture;
#   3. risk restarted mid-book recovers each fixture from its snapshot plus the journal after it.
# usage: GATEWAY=http://127.0.0.1:7100 scripts/gate-e8.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
gateway="${GATEWAY:-http://127.0.0.1:7100}"
demo_password="${DEMO_PASSWORD:-Local-Dev-Demo-1}"
compose="${COMPOSE:-docker compose --project-directory $here/../compose -f $here/../compose/docker-compose.yml}"
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

# 1. Liability latency under load.
(cd "$here/gate-e8" && npm install --silent --no-audit --no-fund >/dev/null)
GATEWAY="$gateway" DEMO_PASSWORD="$demo_password" node "$here/gate-e8/latency.mjs" | tee "$work/latency"
fixture="$(sed -n 's/^fixture=//p' "$work/latency")"
[[ -n "$fixture" ]] || fail "the latency run named no fixture"

expect 200 "$(api o POST /session/login -d "{\"username\":\"operator1\",\"password\":\"$demo_password\"}")" "operator signs in"
expect 200 "$(api p POST /session/login -d "{\"username\":\"punter1\",\"password\":\"$demo_password\"}")" "punter signs in"
place() {
  api p GET "/fixtures/$fixture" >/dev/null
  local leg
  leg="$(jq -c '{fixtureId, offerVersion, marketId: (.markets[] | select(.type == "matchResult") | .marketId), selectionId: "home",
    odds: (.markets[] | select(.type == "matchResult") | .selections[] | select(.selectionId == "home") | .odds)}' "$work/body")"
  api p POST /coupons -H "Idempotency-Key: gate8-$(date +%s%N)-$RANDOM" -d "{\"stake\":100,\"currency\":\"ZAR\",\"legs\":[$leg]}"
}

# 2. A trader cap of zero suspends the fixture; placement refuses within one hydration interval (seconds), then reopens.
expect 200 "$(api o PUT "/admin/risk/fixtures/$fixture/cap" -d '{"capMinor":0,"reason":"E8 gate: cap breach"}')" "trader caps $fixture at zero"
started=$(date +%s%N); refused=""
for _ in $(seq 1 40); do
  code="$(place)"
  if [[ "$code" == 422 ]] && jq -e '.code == "fixture_exposure_capped"' "$work/body" >/dev/null; then refused=yes; break; fi
  sleep 0.25
done
[[ -n "$refused" ]] || fail "placement still accepted bets on a suspended fixture: HTTP $code $(head -c 300 "$work/body")"
echo "ok   placement refuses the capped fixture after $(( ($(date +%s%N) - started) / 1000000 )) ms"
expect 200 "$(api o PUT "/admin/risk/fixtures/$fixture/cap" -d '{"capMinor":null,"reason":"E8 gate: lifted"}')" "trader returns $fixture to the default cap"
for _ in $(seq 1 40); do code="$(place)"; [[ "$code" == 201 ]] && break; sleep 0.25; done
[[ "$code" == 201 ]] || fail "the fixture did not reopen: HTTP $code $(head -c 300 "$work/body")"
echo "ok   placement takes bets on it again"

# 3. Restart risk; the fixture's actor recovers the same book from its snapshot and the journal after it.
sleep 2
expect 200 "$(api o GET "/admin/risk/fixtures/$fixture")" "read the live book before the restart"
before="$(jq -c '{version, worstCaseMinor}' "$work/body")"
$compose restart risk >/dev/null
for _ in $(seq 1 60); do [[ "$(docker inspect -f '{{.State.Health.Status}}' "$($compose ps -q risk)")" == healthy ]] && break; sleep 2; done
expect 200 "$(api o GET "/admin/risk/fixtures/$fixture")" "read the live book after the restart"
after="$(jq -c '{version, worstCaseMinor}' "$work/body")"
[[ "$before" == "$after" ]] || fail "the book changed across the restart: before $before, after $after"
recovered="$($compose logs --since 2m risk 2>&1 | grep -o "Fixture $fixture recovered at version [0-9]* ([0-9]* from the snapshot, [0-9]* replayed)" | tail -1)"
[[ "$recovered" =~ \(([1-9][0-9]*)\ from\ the\ snapshot ]] || fail "risk did not recover $fixture from a snapshot: '${recovered:-no recovery logged}'"
echo "ok   $recovered; the book is unchanged at $after"

echo "E8 gate (liability under 1 s, cap breach refuses, restart recovers from the snapshot) passed"
