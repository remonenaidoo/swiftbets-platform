# SwiftBets Demo — Showcase Scope (v0)

**Goal:** a public GitHub repo + live URL that proves senior-level engineering in 90 seconds. Everything here exists to be *shown to companies*. The full platform blueprint (v1.1) remains the roadmap; this is the vertical slice we ship first.

**The 90-second demo:** open the dashboard → bets flowing live → click "inject fault" (wallet outage / stuck bet / poison message) → anomaly fires → **Steward's AI incident report appears: root cause, evidence, runbook citation** → click approve → system recovers. Repo link shows the code behind all of it.

---

## Tech visibly demonstrated

.NET 8 microservices · Kafka (Redpanda) event-driven architecture · transactional outbox · idempotent settlement (Redis Lua + token sets) · two-stage evaluate→settle · retry ladder + dead-letters · gRPC + REST · PostgreSQL + pgvector · Redis · SignalR live dashboard · React + TypeScript · LLM agent with tool-calling + RAG · Docker Compose · GitHub Actions CI · xUnit + Testcontainers · deployed live (Oracle VM now, Azure/KEDA documented as target)

## Services (5 + web) — descoped from the v1.1 map

| Service | Scope for demo | Full-platform features deferred |
|---|---|---|
| **swift-offer** | Recorded-fixture **replay mode only**: streams real historical soccer fixtures/odds/results on a loop; odds read API | Live external feed, cache tiers |
| **swift-placement** | Bets API (singles + accas + bankers); **wallet as internal ledger module** (idempotency keys, reserve/debit); **outbox + relay as hosted service inside** (same pattern, one deployable); durable saga-intent + sweeper | Separate wallet & relay services, vouchers, delegated mode, sessions refresh |
| **swift-settlement** | The crown jewel, near-full: indexer, priority-gated deltas, token-guarded Lua counters, **evaluate → Kafka → settle**, banker shortcut, inbound DLQ, **reconciler + bet-refresh** | Archive job, manual-results suite (one endpoint kept for the demo) |
| **swift-payout** | Delta-based payment to ledger, **named-step retry ladder**, dead-letter, blacklist basics | Tax lines, MTS-style inform |
| **steward** | Detector rules (stuck bet, wallet outage, DLQ arrival, settlement lag) + agent: tool-calling loop, **RAG over runbooks in pgvector**, incident reports, approval-gated remediation (bet-refresh, pause market) | Full rule set, admin gateway |
| **swift-web** | React + TS dashboard: SignalR live bet feed, anomaly timeline, incident report view + approve button, **fault injection panel** | Customer-facing product UI (frontend phase) |

**Cut entirely for demo:** identity (demo users seeded, simple JWT stub), cashout, bethistory service (dashboard reads a small query API on settlement), config service (kill switch = admin endpoint + env). All noted in README as roadmap — *showing you know what you deferred is itself senior signal.*

## Fault injection menu (the demo's heart — all real production failure modes)

1. **Stuck bet** — settlement counter silently skips → reconciler detects drift → Steward diagnoses by the token/counter signature → approve bet-refresh → bet settles
2. **Wallet outage** — payouts fail → retry ladder drains → some dead-letter → Steward reports, proposes re-drive
3. **Poison message** — malformed event → inbound DLQ, partition keeps flowing → Steward explains
4. **Duplicate settlement** — replayed message → no double-pay (idempotency key), Steward confirms money safe

## Repo strategy (what companies see)

- **One public monorepo: `swiftbets`** — one link to share, everything discoverable
- README is the landing page: one-paragraph pitch, architecture diagram (Mermaid), tech badges, **demo GIF**, live URL, "run it yourself: docker compose up"
- `docs/architecture.md` — the design decisions and trade-offs (sanitized, our own words)
- `docs/runbooks/` — visible: they're the RAG corpus AND proof of ops writing
- `docs/roadmap.md` — the v1.1 blueprint lives here (sanitized): shows product thinking
- Green CI badge, tests visible, conventional commits

## Build plan (4 weekend-sized phases)

**D1 — World + bets.** Compose (Redpanda/Postgres/Redis), contracts, offer replay streaming real fixtures, placement with ledger + outbox. *Done:* bets flowing on `swift.coupon.placed`, visible in Redpanda Console.

**D2 — Settlement + payout.** Full settlement slice + payout ladder. *Done:* accas with bankers settle off replayed real results; duplicate replay no-ops; wallet-down test drains clean.

**D3 — Steward.** Detector + runbooks in pgvector + agent loop + fault injection endpoints. *Done:* all four faults produce correct evidence-cited reports.

**D4 — Face + ship.** React dashboard (SignalR feed, incidents, inject panel), CI, README + GIF, deploy to VM. *Done:* live URL, the 90-second demo works end to end.


**D5 (stretch) — Casino slice.** One **simulated game provider** (a tiny service playing a simple slot round via the real callback protocol) + **swift-casino-gateway** exposing the seamless wallet API: launch session → provider calls bet/win/rollback with provider transaction ids → idempotent mapping onto the ledger → rounds visible on the dashboard; fault menu gains "duplicate provider callback" and "rollback for unknown bet." *Why it earns its place: it demonstrates the provider-integration pattern (BET Software experience) and shows the platform is dual-vertical — sports + casino — which is where the industry's money actually is.*

Then: CV Personal Projects section gets the name + link; LinkedIn post; repo pinned on GitHub profile.

## Improvements backlog (after the demo ships)

Not in D1–D4. Each is a self-contained upgrade to add once the 90-second demo works end to end:

- **Customer-facing lite sportsbook UI** (React + TS): fixtures, live odds, betslip, place bet, my bets — the ops dashboard is the demo's face; this is the product's
- **Betslip as a persistent client store** (atom-based, localStorage, hydration-safe pattern)
- **Real-time odds via SignalR** on the customer UI with a connection pool + reference-counted group subscriptions
- **Design tokens + build-time multi-brand theming** (two skins from one codebase)
- Virtualised fixture lists, container queries, semantic z-index scale
- **Security pass:** httpOnly session cookie, CSP with nonces, no secrets in the bundle, 401 handling once in the API client
- **Casino slice (D5):** simulated provider + seamless wallet callbacks
- **Observability:** Grafana dashboard over Prometheus metrics; OpenTelemetry traces
- k6 load script with a published throughput number in the README
- Azure Container Apps + KEDA migration (documented v2 target)
