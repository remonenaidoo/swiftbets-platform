# SwiftBets — Backend Platform Blueprint (v1.2)

**SwiftBets** is a soccer-first betting platform built to production standards. **Steward** is its operations brain: an AI copilot that watches the platform, detects incidents, and runs a Stewards' Inquiry on every one.

Architecture derived from a proven high-volume sportsbook reference (1.5M+ bets/day class): inherits its load-bearing patterns, **fixes its six documented weaknesses, and closes one documented residual risk** from day one.

*v1.1: gap audit against the full reference architecture — adds identity, admin gateway, in-play scope decision, placement modes, money-leg abstraction, offer caching, lifecycle jobs, and several smaller items.*

---

## 1. Principles

1. **Money correctness beats everything.** Every money-moving path is idempotent, delta-based, and resumable by name, never by position.
2. **One writer per entity.** A service writes only what it owns; everyone else reads a projection.
3. **Events over calls** for anything that survives a request; **outbox** for anything that must not be lost.
4. **Derived state must be reconcilable.** Any cache/counter that can diverge from its source gets a detector, not just a repair endpoint.
5. **Fail loudly at seams.** Unknown retry step → throw. Unparseable inbound message → dead-letter, never crash-loop.
6. **Operability is a feature.** Structured logs, metrics, health checks, and Steward hooks ship with every service.

## 2. Scope decisions (v1)

- **Pre-match only in v1.** In-play betting is v1.5: it requires live odds streaming, per-market suspension, and configurable bet delays. BUT the seams are built now: placement sessions support an explicit **refresh** operation, validation reads market state (open/suspended) not just price, and a per-identifier `LiveDelay` config key exists from day one so in-play slots in without reshaping placement.
- **Placement modes from day one:** `Normal | Blocked | Delegated`. v1 implements Normal and Blocked (kill-switchable per brand/market). **Delegated (agency/cashier placing for a customer, resolving parent accounts) is v1.5** — the reference platform does ~490K agency bets/day, so the mode enum, the identifier's play-source dimension, and the account parent relationship are modeled now even though the flow ships later.
- **Money-leg abstraction now, vouchers later.** Placement's money step is an interface (`IFundsSource`): v1 ships the wallet implementation (reserve → debit); free bets/vouchers (reserve/redeem semantics, no rollback of redemption) are a second implementation in v2. Schema reserves `intake.freebets`.
- **Deferred:** external risk provider (risk is an internal module behind the same contract), booking codes, leaderboards, FlexiCut-style products, system bets, second cashout path, multi-tenant brands beyond one (but the Identifier travels on every call from day one).

## 3. Tech stack

- **.NET 8**, gRPC between services, REST at the edges
- **Redpanda** (Kafka API) — topics env-suffixed via config (`.dev`, `.prod`)
- **PostgreSQL** — transactional store (betstore), read model, wallet ledger, identity; **pgvector** for Steward's RAG
- **Redis** — offer store, settlement progress, caches
- Docker Compose → Oracle free ARM VM → (v2) Azure Container Apps + KEDA
- xUnit + Testcontainers; k6; migration runner owned like a product (numbered scripts, Testcontainers helper for tests)

## 4. Service map (v1)

| # | Service | Role | Notes |
|---|---------|------|-------|
| 1 | **swift-identity** | Users, authentication (JWT), account status, parent/cashier relationships | Placement reads user details through a cached projection, never raw |
| 2 | **swift-offer** | Feed adapter (fixtures/odds/results) → **Redis offer store** (live truth) + Postgres catalogue; read API with **three cache tiers** (in-process hybrid, Redis output cache, offer store) and **cache-aside + stale-while-revalidate + fail-safe**: price correctness is the feed's job, page availability is ours. Includes **recorded-fixture replay mode** for dev/demo | Feed writes; placement, cashout, offer API only read |
| 3 | **swift-wallet** | Standalone money service: double-entry ledger, **reserve/debit split**, credit, release; idempotency keys with `TransactionAlreadyExists → success` semantics | Owns balances; nobody else holds one |
| 4 | **swift-placement** | Sessions (snapshot + named **refresh** op) → validate vs offer store (price policy + market state) → risk module → funds source reserve → risk ticket → debit → **coupon + selections + outbox + saga-intent in ONE transaction** → coupon-code generator (human-facing correlation key) | Fix #2 built in; concurrent booking-of-independent-work pattern kept |
| 5 | **swift-relay** | Outbox poller → publishes placed + activity events; **row-claiming** (multi-instance safe); **outbox cleanup** procedure keeps the table small | Hot-reloadable batch size/delay |
| 6 | **swift-settlement** | Selection→bet indexer; **priority-gated deltas** + auto-resettlement time window; token-guarded atomic Lua counters; **evaluate → Kafka → settle** two-stage (partitioned by bet id, ordering assumption documented AND tested); **reconciler job** (fix #1); admin **bet-refresh**; cleanup + **settlement archive** job | Banker-lost shortcut; manual results with `IsManual`; manual-on-cashed-out → explicit back-office rejection |
| 7 | **swift-payout** | Delta-based payment; wallet blacklist (owed amounts absorbed first, **IsReady gate**: no processing until bootstrap replay completes); tax as second transaction line; **named-step resumable retry** via **retry ladder topics** (no sleeping workers); risk settle-inform; dead-letter | Fixes #3 & #4 built in |
| 8 | **swift-bethistory** | CQRS read model: coupons/bets/selections/settlements + **fixture and fixture-state projections** (display data) + denormalised open-bet lookups; three audiences (customer-scoped, admin, back-office); **integrity job vs betstore** | Fix #6 built in |
| 9 | **swift-cashout** | Stateless quote: formula over live prices, HMAC(selections, prices, timestamp, bet) with **explicit max-age** (fix #5); execute (authenticated) → re-validate, recompute, leeway-check → gRPC to settlement (final-state lock → evaluated re-entry) | One implementation, no legacy twin |
| 10 | **swift-config** | Compacted-topic config: currency rates (external rate source), event rules, live delays, kill switches; hand-rolled consumers observing **partition EOF** for hydration-complete; tooling package for consumers | Config outage ≠ placement outage |
| 11 | **swift-admin** | Back-office gateway (reverse proxy + policy-based authz): manual results (coupon/market/override/time-voiding), bet-refresh, kill switches, config administration; hosts Steward's approval UI later | The trader/ops door |
| 12 | **steward-detector** | Consumes platform topics + metrics; rolling windows; publishes anomalies (incl. rollback-failure and DLQ arrivals) | |
| 13 | **steward-agent** | On anomaly: tools over events/metrics/bet state, RAG over runbooks (pgvector), incident report, human-approved remediation (bet-refresh, kill switch) | |

**Risk module contract** (internal in v1, provider-shaped): `AssessAsync(ticket) → accepted/rejected + ticketId`, `CancelAsync(ticketId)`, `SettleInformAsync(ticketId, kind: settlement|cashout|void)` — same seams as an external managed trading service, so swapping one in later is an adapter, not a rewrite. Placement wraps it (and the feed) in the **shared resilience policy library** (fix #4): circuit breaker + typed retry, one answer to "what happens when it's down."

## 5. Topic map

| Topic | Producer → Consumers |
|-------|----------------------|
| `feed.market.result` | offer → settlement |
| `feed.fixture`, `feed.fixture.state` | offer → bethistory, offer catalogue |
| `swift.coupon.placed` | relay → settlement, bethistory, steward-detector |
| `swift.bet.activity` | relay, payout → analytics (future), steward-detector. **Every record carries the idempotency key so consumers CAN dedupe — closes the reference's documented residual risk (duplicate activity on redeploy)** |
| `swift.bet.evaluated.won/lost` | settlement → settlement (settle stage) |
| `swift.bet.settled.won/lost` | settlement → payout, bethistory, steward-detector |
| `swift.coupon.settled` | settlement → bethistory |
| `swift.bet.manual.result` | settlement → bethistory |
| `swift.cashout.confirmed` | cashout → settlement |
| `swift.payout.retry.5s / .1m / .15m` | payout → payout (ladder) |
| `swift.payout.deadletter` | payout → steward-detector |
| `swift.settlement.inbound.deadletter` | settlement → steward-detector (inbound DLQ) |
| `swift.placement.rollback.failure` | placement → steward-detector (compensation that could not complete — durable, observable) |
| `swift.wallet.blacklist` | payout → payout (bootstrap replay, IsReady-gated) |
| `swift.config.currency / .eventrules / .livedelay` (compacted) | config → placement, settlement, cashout |
| `steward.anomaly.detected` | detector → agent |
| `steward.incident.report` | agent → admin UI |

## 6. Data ownership & schema sketch

**Postgres `betstore`**
- `intake.coupons` (coupon_code, user_id, identifier: brand/country/business_model/play_source, stake, currency, placed_at, status, placement_mode)
- `intake.bets` (bet_id, coupon_id, bet_type single/acca, potential_return)
- `intake.selections` (selection_id, bet_id, market_id, price_taken, is_banker, result_status, result_priority, resulted_at)
- `intake.freebets` (reserved for v2 voucher leg)
- `intake.outbox` (id, aggregate_id, payload, claimed_by, processed_at) + cleanup proc
- `intake.saga_intents` (intent_id, coupon_code, step_reached, state, created_at) — sweeper compensates orphans
- `settlement.indexer` (selection → bet map, current result, priority, resulted_at)
- `settlement.bets` (bet_id, outcome, settled_amount, settled_at, is_manual, settlement_version)
- `archive.settlement` — retention job moves closed history out of the hot path

**Postgres `wallet`**: `accounts` (account_id, user_id, currency, status, parent_account_id) · `ledger_entries` (signed amount, type reserve/debit/credit/release, idempotency_key UNIQUE, correlation, created_at); balance = SUM, double-entry via house accounts

**Postgres `identity`**: users, credentials, roles, cashier/parent links. Placement consumes a cached projection (hybrid cache, compressed).

**Postgres `bethistory`**: denormalised projections + `open_bets` / `open_coupons` lookups + fixture display tables

**Redis**: `offer:{marketId}` (live truth) · `settle:progress:{betId}` + `settle:tokens:{betId}` (atomic Lua; final-state flag) · output caches
- **Reconciler:** walks bets open > threshold, recomputes expected counters from `settlement.indexer`, drift metric, auto-repair or raise. The stuck-bet signature (tokens > counters) is a first-class detector rule.

## 7. Core flows

**Placement:** session snapshot → validate (price policy + market open) → risk assess → funds reserve → risk ticket → funds debit → single transaction (coupon + selections + outbox + saga-intent) → return coupon code; booked-event via in-process channel. Failure: reverse compensation from the activity log; rollback failure → `swift.placement.rollback.failure`; pod death → sweeper compensates the orphaned intent. Independent work (e.g. future booking codes) overlaps the money leg deliberately.

**Settlement:** result batch → indexer → deltas gated on priority + time window ((0,0) deltas free to replay) → Lua token-checked counter updates → SQL commit → evaluate (banker shortcut; counts vs total) → publish evaluated → consume back → calculators (bet type, bonus, tax) → settle → publish. Malformed inbound → inbound DLQ, partition keeps flowing.

**Payout:** delta = new − previously_won → blacklist absorb → wallet credit/debit with key `{coupon}_{bet}_{type}_{version}` (+ tax line) → activity (with key) → risk inform. Failure → ladder topic with **named** step; unknown name → refuse; exhausted → dead-letter → Steward.

**Cashout:** quote (formula + HMAC + max-age) → execute → re-validate + recompute + leeway → settlement final-state lock → evaluated re-entry (Cashout). Late manual/auto result → rejected at the data layer; manual attempts surface an explicit rejection.

**Manual settlement:** admin gateway (authz) → settlement manual-results endpoints → CanOverride (manual priority wins) → same pipeline, `IsManual`, `BetLevel` / rollback strategies → `swift.bet.manual.result`.

## 8. Steward integration

- **Detector rules v1:** settlement lag; stuck-bet signature / reconciler drift; payout DLQ or ladder depth; wallet error-rate; inbound DLQ; rollback-failure arrival; offer-feed staleness; blacklist-not-ready processing attempts.
- **Agent tools:** `get_recent_events`, `get_bet_state` (intake + settlement + progress + ledger in one view), `get_service_metrics`, `search_runbooks` (pgvector).
- **Runbooks:** sanitized rewrites of real production failure modes: stuck bet, wallet outage, duplicate settlement, poison message, feed staleness, orphaned saga.
- **Loop:** anomaly → investigate → structured incident report (root cause, evidence, runbook citation, confidence, proposed action) → human approval in admin UI → action (bet-refresh, kill switch, ladder re-drive).

## 9. Build phases

**Phase 0 — Foundations.** Repo, compose (Redpanda+Postgres+Redis), shared contracts + Identifier type, migration runner, CI skeleton. *Done:* compose healthy, contracts build, first migration runs.

**Phase 1 — Identity, Offer, Wallet.** Minimal identity (users + JWT); feed adapter with replay mode + offer store + cached read API; wallet ledger with reserve/debit + idempotency. *Done:* login works; live fixtures/odds served; duplicate-debit test passes.

**Phase 2 — Placement + Relay.** Sessions/refresh, validation, risk module, IFundsSource(wallet), durable saga, outbox, claiming relay + cleanup. *Done:* bet lands in Postgres AND on `swift.coupon.placed`; kill-pod-mid-saga test shows sweeper compensating; rollback-failure topic observable.

**Phase 3 — Settlement + Payout.** Indexer, deltas, Lua counters, two-stage, reconciler, inbound DLQ; payout ladder + named steps + blacklist. *Done:* real result settles an acca with a banker; duplicate replay no-ops; wallet-down drains via ladder without double-pay; poison message parks with partition flowing.

**Phase 4 — BetHistory + Cashout + Admin.** Projections + integrity job; quote/execute with max-age; admin gateway with manual results + bet-refresh + kill switches. *Done:* full lifecycle visible in history; stale quote rejected by age; trader can manually void via admin and see explicit rejection on a cashed-out bet.

**Phase 5 — Config + Hardening.** Compacted-topic config + live-delay key + kill switches wired; chaos pass; partition-ordering test; archive job. *Done:* kill switch stops placement in seconds; ordering test green.

**Phase 6 — Steward.** Detector rules, runbooks, agent loop, approval flow in admin UI. *Done:* every injected real-world fault → correct, evidence-cited incident report.

**Phase 7 — Ship.** Oracle VM deploy, GitHub Actions, dashboards, README + architecture doc. *Done:* live URL, one-command deploy, Steward diagnosing in production.

## 10. Inherited weaknesses fixed by design (6 + 1)

1. Redis/SQL settlement divergence → **reconciler with drift metric + repair/alert** (stuck bets detected, not discovered by customers)
2. Non-durable placement saga → **saga-intent row in the placement transaction + orphan sweeper** (no more "charged, no bet")
3. Positional retry steps → **named block resolution, loud failure, mapping under test**
4. Inconsistent resilience posture → **one shared policy library for wallet, feed, risk**
5. Cashout quote without expiry → **explicit max-age**
6. Integrity job's expiring reference → **compares against betstore from day one**
7. *(Residual risk closed)* Duplicate activity events on redeploy → **idempotency key on every activity record so downstream consumers can dedupe**

## 11. Casino vertical (the profit engine)

Sports acquires customers; **casino is where platform revenue concentrates** (the reference group's biggest brands are casino-first). Casino is an *integration* business: providers host the games; the platform provides launch, money, and lobby. This maps directly onto what we already have — the wallet's idempotency semantics are exactly what provider wallet callbacks require.

**Services (v1.5 of the product):**
- **swift-casino-gateway** — the provider integration layer (the aggregator): game launch/session handoff (signed launch URLs, session tokens), the **seamless wallet API** providers call back into (`bet`, `win`, `rollback` — idempotent by provider transaction id, mapped onto swift-wallet with `TransactionAlreadyExists → success`), per-provider adapters behind one port (anti-corruption: provider ids and amounts never trusted, always validated), round/transaction reconciliation per provider
- **swift-casino-catalog** — games, providers, categories, per-brand/market availability (Identifier-gated), lobby read API
- **Bonus engine** — casino bonuses (free spins, wagering requirements) — v2; schema reserved
- **In-house games** (crash/instant-win) — v2+; the gateway treats them as just another provider

**Flow:** player opens lobby (catalog) → launch game (gateway issues session, redirects to provider) → provider calls seamless wallet: bet → win → (rollback on their failure) → gateway validates session + idempotency → wallet ledger moves → activity events → Steward watches provider error rates and reconciliation drift per provider.

**Failure modes inherited from real casino operations (BET Software experience):** duplicate provider callbacks (idempotency), rollback for a bet never seen (store-and-accept semantics), provider timeout ambiguity (their retry, our dedupe), reconciliation drift (daily per-provider report vs our ledger — a Steward detector rule).
