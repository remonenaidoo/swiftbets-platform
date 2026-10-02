#!/usr/bin/env bash
# E6 gate on the live stack: Lighthouse accessibility must be perfect, and the largest paint must stay inside budget.
#   desktop: accessibility 100, LCP <= 2500 ms
#   mobile (simulated slow 4G): accessibility 100, LCP <= ${MOBILE_LCP_MS:-9000} ms (a ratchet, see D147)
# usage: SITE=http://127.0.0.1:7100 scripts/gate-e6.sh
set -euo pipefail

site="${SITE:-http://127.0.0.1:7100}/"
mobile_lcp="${MOBILE_LCP_MS:-9000}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

run() {
  local form="$1" preset=()
  [[ "$form" == desktop ]] && preset=(--preset=desktop)
  npx -y lighthouse@12 "$site" --quiet --chrome-flags="--headless=new --no-sandbox" --only-categories=accessibility,performance \
    "${preset[@]}" --output=json --output-path="$work/$form.json" >/dev/null
}

check() {
  local form="$1" budget="$2"
  # shellcheck disable=SC2016 # the JavaScript's own template strings, not shell expansions
  node -e '
    const r = require(process.argv[1]);
    const [form, budget] = [process.argv[2], Number(process.argv[3])];
    const a11y = r.categories.accessibility.score;
    const lcp = Math.round(r.audits["largest-contentful-paint"].numericValue);
    const failing = Object.entries(r.audits).filter(([id, a]) => a.score !== null && a.score < 1 && r.categories.accessibility.auditRefs.some((x) => x.id === id && x.weight > 0)).map(([id]) => id);
    console.log(`${form}: accessibility ${Math.round(a11y * 100)}, LCP ${lcp} ms (budget ${budget} ms)`);
    if (a11y < 1) { console.error(`FAIL ${form} accessibility: ${failing.join(", ")}`); process.exit(1); }
    if (lcp > budget) { console.error(`FAIL ${form} LCP over budget`); process.exit(1); }
  ' "$work/$form.json" "$form" "$budget"
}

run desktop && check desktop 2500
run mobile && check mobile "$mobile_lcp"
echo "E6 gate (accessibility 100, LCP budgets) passed"
