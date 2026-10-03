// E8 gate, part 1: under concurrent placement, every liability change reaches an operator's live connection in under 1 s.
// Prints the fixture it loaded as `fixture=<id>` for the shell gate that follows.
import { HubConnectionBuilder, HttpTransportType, LogLevel } from '@microsoft/signalr';

const gateway = process.env.GATEWAY ?? 'http://127.0.0.1:7100';
const password = process.env.DEMO_PASSWORD ?? 'Local-Dev-Demo-1';
const bets = Number(process.env.E8_BETS ?? 30);
const concurrency = Number(process.env.E8_CONCURRENCY ?? 10);
const budgetMs = Number(process.env.E8_BUDGET_MS ?? 1000);

async function signIn(username) {
  const res = await fetch(`${gateway}/api/session/login`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-SwiftBets-Csrf': '1' }, body: JSON.stringify({ username, password }) });
  if (res.status !== 200) throw new Error(`${username} sign-in: HTTP ${res.status}`);
  return res.headers.getSetCookie().map((c) => c.split(';')[0]).join('; ');
}
const call = (cookie, path, init = {}) => fetch(`${gateway}/api${path}`, { ...init, headers: { 'Content-Type': 'application/json', 'X-SwiftBets-Csrf': '1', Cookie: cookie, ...(init.headers ?? {}) } });

const ops = await signIn('operator1');
const punter = await signIn('punter1');

// A fixture at least ten minutes from kickoff with an open match-result market, so prices and status hold for the run.
const fixtures = await (await call(punter, '/fixtures/?limit=60')).json();
const pick = fixtures
  .filter((f) => (f.status === 'open' || f.status === 'scheduled') && Date.parse(f.kickoffAt) > Date.now() + 600_000)
  .map((f) => ({ f, m: f.markets.find((m) => m.status === 'open' && m.type === 'matchResult') }))
  .filter((x) => x.m)
  .at(-1);
if (!pick) throw new Error('no open fixture far enough from kickoff');
const fixtureId = pick.f.fixtureId;
const marketId = pick.m.marketId;

const seen = []; // [coupons, receivedAt]
let lastDelta = null;
const hub = new HubConnectionBuilder()
  .withUrl(`${gateway}/api/hubs/live`, { headers: { Cookie: ops, 'X-SwiftBets-Csrf': '1' }, transport: HttpTransportType.WebSockets })
  .configureLogging(LogLevel.Warning)
  .build();
hub.on('delta', (delta) => {
  if (delta.type === 'liability-changed' && delta.payload.fixtureId === fixtureId) {
    lastDelta = delta.payload;
    const home = delta.payload.outcomes.find((o) => o.marketId === marketId && o.selectionId === 'home');
    seen.push([home?.coupons ?? 0, performance.now()]);
  }
});
await hub.start();

const before = await (await call(ops, `/admin/risk/fixtures/${encodeURIComponent(fixtureId)}`)).json();
const startCoupons = before.outcomes?.find((o) => o.outcome.marketId === marketId && o.outcome.selectionId === 'home')?.coupons ?? 0;

async function placeOne(i) {
  for (let attempt = 0; attempt < 20; attempt++) {
    const f = await (await call(punter, `/fixtures/${encodeURIComponent(fixtureId)}`)).json();
    const odds = f.markets.find((m) => m.marketId === marketId).selections.find((s) => s.selectionId === 'home').odds;
    const res = await call(punter, '/coupons', {
      method: 'POST',
      headers: { 'Idempotency-Key': `gate8-${Date.now()}-${i}-${attempt}` },
      body: JSON.stringify({ stake: 100, currency: 'ZAR', legs: [{ fixtureId, marketId, selectionId: 'home', odds, offerVersion: f.offerVersion }] }),
    });
    if (res.status === 201) return performance.now();
    const body = await res.json().catch(() => ({}));
    if (body.code !== 'price_changed') throw new Error(`placement ${i}: HTTP ${res.status} ${body.code ?? ''}`);
  }
  throw new Error(`placement ${i}: prices kept moving`);
}

const placedAt = [];
for (let next = 0; next < bets; next += concurrency) {
  const wave = Array.from({ length: Math.min(concurrency, bets - next) }, (_, k) => placeOne(next + k));
  placedAt.push(...(await Promise.all(wave)));
}
await new Promise((r) => setTimeout(r, 3000));
await hub.stop();

// The k-th placement to return is in the book once a delta reports startCoupons + k coupons on home.
placedAt.sort((a, b) => a - b);
const latencies = placedAt.map((at, k) => {
  const arrived = seen.find(([coupons]) => coupons >= startCoupons + k + 1);
  return arrived ? Math.max(0, arrived[1] - at) : Infinity;
});
const sorted = [...latencies].sort((a, b) => a - b);
const p95 = sorted[Math.ceil(sorted.length * 0.95) - 1];
const max = sorted.at(-1);
console.log(`fixture=${fixtureId}`);
console.log(`ok   ${bets} bets at ${concurrency} at a time: ${seen.length} liability deltas; p50 ${sorted[Math.floor(sorted.length / 2)].toFixed(0)} ms, p95 ${p95.toFixed(0)} ms, max ${max.toFixed(0)} ms`);
if (!Number.isFinite(max)) console.error(`no liability delta counted a placement; last delta for ${fixtureId}: ${JSON.stringify(lastDelta)}`);
if (!Number.isFinite(max) || max > budgetMs) {
  console.error(`FAIL liability reached the console in ${max.toFixed(0)} ms at worst; the budget is ${budgetMs} ms`);
  process.exit(1);
}
