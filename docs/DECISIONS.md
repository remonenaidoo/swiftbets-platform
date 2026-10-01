# Decisions

Each entry: the decision, the reason, and what it rules out. New decisions are appended; superseded ones are marked, never deleted.

## Design authority

**D30. The brief's betting-domain patterns are the design authority for placement, settlement and payout.** These are:
- transactional outbox with a claiming relay;
- durable saga intents with an orphan sweeper;
- token-guarded atomic Lua progress counters;
- two-stage evaluate → Kafka → settle;
- delta-based payouts with a named-step retry ladder;
- the reconciler.

The PaymentApi / MarketApp money patterns govern the wallet and ledger layer:
- locked row reads with an idempotency key checked under the lock;
- a `WasApplied` result so compensation reverses only real debits;
- atomic claims by conditional `UPDATE` plus a row-count check;
- non-cancellable money writes.

Where the two disagree, the brief wins and the disagreement is recorded under "Conflicts" below.

## Conflicts

| Date | Area | Brief says | Reference pattern says | Resolution |
|---|---|---|---|---|
| 1 Oct 2026 | Delivery order | Customer web in E6, back office in E9 | Vertical slices need a UI in every feature | Web from E1, operator console from E2 (D86) |
| 1 Oct 2026 | Alerting | Alerting and runbooks in E10 | Every money path needs its alert when it ships | Alerts and runbooks ship with each feature (D87) |
| 1 Oct 2026 | Risk | Exposure limits feed placement's risk module (D27 said advisory only) | Placement must never block on a risk call | Compacted topic, enforced locally by placement (D88) |
| 1 Oct 2026 | Repositories | `swiftbets-casino-gateway` and `swiftbets-casino-catalog`; an organisation | One integration surface releases together; repos live under the `remonenaidoo` account | One `swiftbets-casino` repo with three hosts; admin gateway is a host in `swiftbets-gateway` (D89) |
| 1 Oct 2026 | Environments | dev, staging, prod via Helm values and Terraform workspaces | No cloud accounts or budget; workspaces share one credential set | Directory per environment; prod defined and validated only (D91) |
| 1 Oct 2026 | Casino | One adapter against a public sandbox if one exists | Provider sandboxes need a commercial agreement | Two simulated providers with different wallet models (D89) |
| 1 Oct 2026 | Outbox relay | Blueprint: a separate relay service | D51 already gives a multi-instance claiming relay per service | Relay stays in-process (D89) |

## Platform

**D1. .NET 10 LTS, C# latest, nullable enabled, warnings as errors.** .NET 8 leaves support on 10 Nov 2026, and .NET 10 is supported to Nov 2028. Every dependency used here targets `net10.0`.

**D2. Use cases are plain handler interfaces (`I<Verb><Noun>Handler`), with no MediatR.** MediatR is commercially licensed from v13, and direct calls keep the call graph navigable.

**D3. Data access is Dapper. There is one embedded `.sql` resource per query, and no stored procedures.** Logic stays in tested C#. The SQL stays reviewable text and is loaded by resource name through `ISqlResources`. Every statement is parameterised. This rules out the procedure drift seen in the reference systems: `CREATE OR ALTER` copies, filename-prefix ordering, and committed SQL that did not match live.

**D4. Migrations run in DbUp, one migrator per service.**
- Scripts are named `NNNN_description.sql` and tracked in a journal table (`dbo.SchemaVersions`, or `public.schemaversions` on Postgres).
- The migrator runs as a one-shot container in compose and as a Helm `pre-install,pre-upgrade` Job.
- Services never migrate on startup, because two replicas would race.

**D5. Stores.**
- **SQL Server** holds the transactional bet store. It gives row locks with `UPDLOCK`/`READPAST` queue semantics for the outbox and saga claims, and `sp_getapplock` for per-wallet serialisation. There are separate databases (`SbPlacement`, `SbWallet`, `SbSettlement`, `SbPayout`), each with its own login.
- **PostgreSQL** holds the bet-history read model and Steward. It has pgvector, `tsvector` full-text search, and JSONB for reports.
- **Redis** holds the offer store, settlement counters, rate limits and the SignalR backplane. It runs with `maxmemory-policy noeviction`, because an evicted counter is a correctness bug, not a cache miss.

**D6. Money and odds.**
- Amounts are `long` minor units in one currency per deployment (ZAR by default).
- Odds are `decimal(10,3)`.
- One rounding function (round down to the minor unit) is used everywhere a payout is computed.

**D7. Ledger.** The ledger is double-entry and append-only; every movement posts two entries that sum to zero. The account balance is a projection updated in the same transaction and guarded by `CHECK (Available >= 0)`. A reconciler asserts that sum(entries) = balance.

**D8. Events.**
- **Envelope:** JSON with `id`, `type`, `version`, `occurredAt`, `correlationId`, `causationId` and `payload`.
- **Versioning:** the major version is in both the type name and the topic (`.v1`).
- **Schemas:** JSON Schemas are generated from the records, checked in, and snapshot-tested, so a breaking diff fails CI.

**D9. Kafka.**
- Confluent.Kafka 2.15 against Redpanda v26.1.
- Producers use `acks=all` and are idempotent.
- Consumers commit manually, only after success.
- Topics are provisioned from `compose/redpanda/topics.yaml`, and auto-creation is disabled.
- Topic names are `swiftbets.<domain>.<event>.v<N>.<env>`.

**D10. Consumer failure policy.**
- **Poison messages** (validation or deserialisation failure) go to `<topic>.dlq` with the original topic, partition, offset and error headers. The offset is then committed so the partition keeps flowing.
- **Transient failures** pause the partition and retry with backoff, without committing.
- The inbox insert (`consumer`, `eventId`, unique) shares the transaction with the state change.

**D11. Resilience.** Polly v8 through `Microsoft.Extensions.Resilience`, with named pipelines:
- `idempotent-http`
- `keyed-http`
- `keyed-grpc`
- `sql-transient` (1205 and connection errors, plus the Azure SQL transients 40613, 40197, 40501, 49918-49920)
- `kafka-produce`

A non-idempotent call is retried only when it carries an idempotency key.

**D12. Auth.**
- RS256 JWTs are issued by placement's identity module.
- Every other service validates them against `/.well-known/jwks.json`.
- Access tokens last 10 minutes. Refresh tokens last 7 days and are rotated single-use.
- Roles are `Punter`, `Operator` and `Admin`.

**D13. Browser sessions go through the gateway BFF.**
- The session cookie is httpOnly, Secure and `SameSite=Strict`.
- Every mutation must also carry the `X-SwiftBets-Csrf: 1` header.
- The gateway converts the cookie to a bearer token for downstream services and strips inbound identity headers.

**D14. Validation.** FluentValidation runs at the API boundary. Domain invariants are enforced in constructors and factory methods, which return `Result`.

**D15. Observability.**
- **Logs:** Serilog, compact JSON to stdout.
- **Traces:** OpenTelemetry over OTLP to Tempo.
- **Metrics:** prometheus-net `/metrics`, because the OTel Prometheus exporter is still prerelease.
- **Correlation:** a correlation id is carried in `X-Correlation-Id` and in the Kafka `correlation-id` header.
- **Health:** `/health/live` (process) and `/health/ready` (dependencies).

**D16. Tests.**
- **.NET:** xUnit v3, Shouldly (FluentAssertions 8 is commercially licensed), NSubstitute, Testcontainers, Respawn, and NetArchTest for layer rules.
- **Load:** k6.
- **Frontend:** Vitest with Testing Library, and Playwright.
- **Policy:** one positive and one negative test per behaviour. The money paths additionally carry the four named failure scenarios: duplicate message, out-of-order result, reprocessing after crash, and wallet outage.

**D17. Dataset.** A curated historical EPL season: fixtures, opening and closing odds, and results, normalised to JSON inside the offer repo.

**D18. Time.** `TimeProvider` is injected everywhere. The replay feed runs on a compressed clock and loops seasons with id offsets.

**D19. Steward model.**
- It uses the native tool-use Messages API: Sonnet 5.5 for diagnosis and Haiku 4.5 for triage.
- The system prompt and tool definitions are prompt-cached and byte-stable.
- Spend has a hard cap of USD 10 a month.
- CI runs in replay mode only.

**D20. Embeddings.** Ollama `nomic-embed-text` in compose. CI uses a deterministic hashing embedder behind the same `IEmbeddingGenerator` port.

**D21. Frontend.** React 19, Vite, React Router 7, TanStack Query 5, Jotai, Tailwind v4 and clsx.

**D22. Mobile.** Expo (current SDK) with expo-router. The APK is a Gradle release build in Actions, published as a GitHub Release asset.

**D23. Kubernetes.**
- Charts are portable Helm: a library chart, one chart per service, an infra chart and an umbrella chart.
- Ingress is standard `networking.k8s.io/v1`. There are no distribution-specific CRDs.
- Every install is verified on kind in CI and on k3s.

**D24. Infrastructure as code.**
- Terraform with the OCI, `azurerm`, Kubernetes and Helm providers.
- Remote state lives in an OCI Object Storage S3-compatible backend.
- Apply is a manual workflow.

**D25. CI.**
- Every repo calls the reusable workflows in `swiftbets-platform`.
- Gates: Trivy on images, `dotnet list package --vulnerable`, `npm audit`, and CodeQL.
- Images are multi-arch (amd64 + arm64), pushed to GHCR, and tagged by commit SHA and semver. Never `:latest`.

**D26. Landing page.** An Astro static site with no secrets.

**D27. Risk.** Akka.NET 1.5 with one liability actor per fixture and a sharding-ready message extractor. It is advisory only; placement's risk module remains the hard gate.

## Approved changes (30 Sep 2026)

**D28. Bet scope (change 1).**
- In: singles and accumulators, void legs counted at odds 1.00, the price-change policy (accept equal or better, reject worse with the current price in the error), offer version checks, and result versions with priority and resettlement.
- Backlog: system bets (k-from-n) and bankers.
- The domain keeps a `BetType` discriminator and a leg list, so system bets can be added without breaking the contract.

**D29. Wallet transport (change 2).**
- `Wallet.Api` exposes gRPC `swiftbets.wallet.v1.Wallet` (proto in `swiftbets-contracts`), consumed by placement and payout. Every mutating RPC takes an idempotency key.
- The only HTTP surface is the operator top-up, plus health and metrics.
- Everything else in the platform is HTTP plus Kafka.

**D31. Cloud betstore (change 4).**
- The cloud cluster is the Oracle Always Free ARM (Ampere A1) VM running k3s. SQL Server has no arm64 image.
- In the cloud, the betstore is Azure SQL Database (free tier), reached over TLS (`Encrypt=True`) from the OCI cluster and provisioned by the `azurerm` Terraform module.
- Locally, in compose and in CI, the SQL Server container (amd64) is used.
- Connection strings are plain configuration, so environments differ only by env vars and secrets, never by code.
- All SwiftBets images are multi-arch. Postgres, Redis, Redpanda, Tempo, Prometheus, Grafana and every service run on the ARM node.
- The umbrella chart's `values-cloud.yaml` has no SQL Server StatefulSet; `values-local.yaml` keeps it.

**D32. Repositories.** There are 13, each independently buildable, all under `github.com/remonenaidoo`:
- `swiftbets-platform`, `swiftbets-contracts`, `swiftbets-building-blocks`
- `swiftbets-offer`, `swiftbets-placement`, `swiftbets-settlement`, `swiftbets-payout`
- `swiftbets-steward`
- `swiftbets-gateway`, `swiftbets-realtime`
- `swiftbets-dashboard`, `swiftbets-mobile`
- `swiftbets-risk`

**D33. Authorship.** Everything is authored as Remone Naidoo <naidoo.remone@gmail.com>. There is no tool or AI attribution in commits, headers, metadata or docs. Commits follow Conventional Commits.

## Phase 0

**D34. Shared packages are distributed as GitHub Release assets, not through a package registry.**
- `swiftbets-contracts` and `swiftbets-building-blocks` publish `.nupkg` files, and the contracts npm tarball, as assets on a semver-tagged GitHub Release.
- Consumers pin an exact version. CI downloads the pinned assets into a local folder feed (`.packages/`) before restore. Locally, `scripts/pack-local.sh` fills the same folder.
- Reason: GitHub Packages NuGet requires an authenticated token even for public packages, and cross-repo read access for user-owned packages can only be granted in the web UI. Release assets on public repos need no credentials, are immutable per tag, and keep every repo buildable on its own.

**D35. Central package management.** Each repo pins its versions in `Directory.Packages.props`. `Directory.Build.props` sets the target framework, nullable, analyzers, warnings as errors, deterministic builds and SourceLink.

**D36. Container images.**
- Multi-stage builds: the SDK image builds, and the runtime is `mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled-extra`, which is non-root and has no shell.
- Health checks run over HTTP from compose, not from inside the image.
- Every image carries OCI labels, including `org.opencontainers.image.source`.

**D37. Infrastructure image versions.**

| Component | Image |
|---|---|
| Redpanda | v26.1.18 |
| Redpanda Console | v3.12.0 |
| SQL Server | 2025-CU9-ubuntu-24.04 |
| Postgres + pgvector | pgvector 0.8.6, pg17 |
| Redis | 8.6-alpine |
| Prometheus | v3.15.0 |
| Grafana | 13.0.10 |
| Tempo | 3.1.0 |

**D38. Runtime image flavour.** Services use `aspnet`/`runtime:10.0-noble-chiseled-extra`, not plain chiseled. Microsoft.Data.SqlClient refuses to run in invariant-globalization mode, and plain chiseled images have no ICU; `-extra` adds ICU and tzdata and is still non-root and shell-free. The failure only shows inside the container, never under `dotnet test`, so compose is part of the Phase 0 gate.

**D39. Hosts are web hosts.** Workers (settlement, payout, risk) are `WebApplication` hosts too, so every process has the same `/health/*` and `/metrics` surface and the same `--healthcheck` probe.

**D40. Local ports.** SwiftBets binds only to 127.0.0.1, in the 7100-7199 range: gateway 7100, dashboard 7110, Grafana 7130, SQL Server 7133, Postgres 7134, Redis 7135, Redpanda Console 7180, Prometheus 7190, Kafka 7192. Services have no published ports; the gateway is the only API origin.

**D41. Messaging and outbox packages depend on hosting abstractions only.** An earlier draft took a framework reference on ASP.NET Core, which forced the non-web migrators onto the ASP.NET runtime. Only the Observability and Web packages reference ASP.NET Core.

**D42. CI token scopes.** `dotnet.yml` (build, test, scan, images) needs at most `packages: write` and `security-events: write`. Releasing lives in a separate `dotnet-release.yml` whose one job holds `contents: write`, and only the two package repos call it, on `v*` tags. Reusable workflows are referenced `@main` because they live in the same owner's repository and change together with the platform. Pinning them to a commit SHA is the hardening step once the workflows stabilise (Phase 5).

**D43. Image vulnerability exceptions.** Trivy blocks CRITICAL/HIGH findings that have a fix. When the fix exists upstream but the vendor base image has not been rebuilt yet (chiseled images cannot be patched with apt), the finding goes into `security/.trivyignore` with a written reason why it does not apply and an `exp:` date. When the date passes, the gate fails again. First entry: CVE-2026-84782 (openssl DTLS; SwiftBets uses no DTLS), expiring 2026-10-31.

## Phase 1

**D44. Wallet idempotency: the unique index arbitrates, with no range locks.**
- The first design looked the key up with `UPDLOCK, HOLDLOCK`. On a key that does not exist, that takes a key-range lock on the index gap. Coupon ids are time-ordered (UUIDv7), so every new key lands in the same gap, and every reserve in the system serialised: wallet p99 was 1.74 s at 150/s.
- Now the key is looked up without a lock, the account row is locked (`UPDLOCK, ROWLOCK`), and the keyed posting row is inserted first.
- If a concurrent request committed the key first, the unique violation rolls this attempt back and the stored result is replayed.
- The concurrent duplicate-debit test (20 requests, one key, exactly one debit) guards it.

**D45. `READ_COMMITTED_SNAPSHOT` on every SwiftBets SQL Server database.**
- The migrator turns it on, matching Azure SQL's default.
- Readers no longer queue behind writers.
- No money path depends on read blocking: they use explicit `UPDLOCK`/`READPAST` and unique indexes.

**D46. The fixture liability cap is soft and lives in Redis.**
- A SQL counter row per fixture became a hot row: about 20 open fixtures, most coupons touching several of them, and locks held until commit. It pushed p99 to 1.9 s.
- Now the placement check reads a Redis hash and the committed coupon's payout is added with `HINCRBY` after commit. Concurrent placements can overshoot by a few coupons.
- Exact, real-time liability is the risk service's job (Phase 8).

**D47. Saga state `Compensating`.**
- The sweeper's claim moves unfinished, unpersisted intents to `Compensating` in the same statement.
- The live saga advances only by conditional transitions (`Started`→`Reserved`→`Persisted`).
- If the live saga loses that race, it releases its own reservation.
- This closes the window in which a slow reserve could land after the sweeper resolved the intent.

**D48. Top-up opens the wallet account.** A punter's account is created by their first operator top-up, which is a balanced posting from the funding account. Load-test punters are funded this way.

**D49. Gateway rate limits are configuration.**
- Production defaults are 10 logins per IP per minute, 120 placements per user per minute (partitioned by the unverified `sub`), and 600 requests per IP per minute.
- The local stack sets load-test values, because every k6 request arrives from one IP.
- A forged token only buys itself its own rate-limit bucket and a 401 downstream.

**D50. Hot-path resources.**
- Placement, wallet and gateway get 2 CPUs and 512 MB. At 1 CPU, cgroup throttling (11% of scheduler periods on placement) was the entire p99 tail.
- **Measured on one node:** 150 placements/s sustained, p50 14 ms, p95 32 ms, p99 117 ms, no dropped iterations.

**D51. The outbox relay publishes keys in parallel.**
- Up to 16 keys at once; each key strictly in sequence, stopping at the first failure.
- This keeps per-partition order and removes the single-publisher throughput cap (backlog peaked at 291 at 150/s).

**D52. Concurrent duplicates of one placement request.**
- Exactly one request places the coupon.
- The others get either the stored response (`Idempotent-Replay: true`), or `409 placement_in_progress` while the first is still running.
- Either way there is one intent, one reserve and one coupon.

**D53. Bet-history projector moves to Phase 2.** It projects `coupon-settled` and `payout-completed`, which do not exist until Phase 2. Placement's own `GET /coupons/{id}` covers Phase 1.

## Phase 2

**D54. Settlement is two-stage over Kafka, with SQL as the truth and Redis as the gate.**
- The evaluator writes one leg evaluation per (leg, result version) together with a `leg-evaluated` outbox event.
- The settler counts resolved legs in Redis with a Lua script guarded by a token (`legId:resultVersion`). A redelivered evaluation cannot advance a coupon twice.
- When all legs are resolved, the settler reads the latest evaluation of every leg from SQL under a coupon lock. It writes a new settlement version only if the outcome or payout changed.
- If a token is redelivered and the coupon is already complete, the settler still runs as a no-op. That closes the window between the Redis update and the SQL commit.

**D55. The priority gate works on (result version, status).**
- A later version always wins. Within one version the precedence is void > correction > official > provisional.
- Provisional results are recorded but never settled.
- A result equal to or below the stored one is a no-op (duplicate-result gate).

**D56. A result that lands before the coupon is indexed is still settled.**
- The indexer evaluates legs whose result already exists, in the same transaction that indexes them.
- A race where both transactions miss each other is repaired by the reconciler's unevaluated-legs pass, which covers the last hour of results, within one interval. It uses row locks only, with no range locks (see D44 for why).

**D57. The reconciler repairs rather than just reporting.**
- `SettlementPending` is set on every new evaluation and cleared by the settler, including on a no-op. A filtered index keeps the "fully evaluated but unsettled" scan proportional to pending work, not to history.
- Repairs rebuild the Redis progress from SQL, settle, and emit `stuck-coupon`.
- The same path backs the operator's `POST /coupons/{id}/refresh`.

**D58. Payout is delta-based with versioned keys.**
- For each settlement version: `delta = target − paidToDate`, using key `{coupon}_bet1_{WIN|VOID_REFUND|RESETTLE_CREDIT|RESETTLE_DEBIT}_{version}`.
- A stale or repeated version is a no-op (`LastVersion` guard).
- The attempt message carries the settlement outcome, so every retry derives exactly the same key as the first attempt (contracts 0.3.1). Without it, a retried void-refund could be keyed as a win and paid twice.

**D59. There is a per-coupon payout lease.**
- Only one worker moves a coupon's money at a time: a 30-second lease column, with expiry as the crash safety net.
- A contended attempt goes onto the ladder instead of waiting.
- The lease matters because a ladder retry of v1 and a direct v2 can otherwise compute deltas from the same paid-to-date.

**D60. The ladder is named-step, on topics, with no sleeping.**
- The rungs are `payout.retry-5s/1m/15m`. Each attempt carries its `step`, `attempt` and a `retry-due-at` header; the rung's consumer pauses the partition until it is due.
- Past the last rung, a blacklisted wallet or any other refusal goes to `payout.DeadLetters` plus the dead-letter topic, and operators replay it via `POST /dead-letters/{coupon}/{version}/replay`.
- `PublishCompleted` is not a separate step: the completed event is written through the outbox in the same transaction as `RecordPayment`.
- **Measured live:** with the wallet container stopped, 241 attempts took the 5-second rung and 233 the 1-minute rung. After restart everything drained through the 15-minute rung: 41,391 coupons settled and paid, owed = paid = credited = 4,149,873, 0 duplicate keys, 0 dead letters.

**D61. A consumer host never dies of one message** (building-blocks 0.3.1).
- Live testing found that a dead-letter publish to a missing topic threw out of the consume loop and stopped the host. The restart policy then crash-looped it on the same message.
- Anything that escapes processing is now a paused, backed-off redelivery.
- DLQ topics are provisioned as `<topic>.<env>.dlq`, matching `TopicName.DeadLetter()`.

**D62. The replay publishes corrections.** Every 25th match's official result is corrected one slot later with a score that changes the outcome, so resettlement and clawback debits happen continuously in the demo.

**D63. Bet history is a Postgres read model in the placement process.**
- `history.coupons` is fed by the placed, settled and paid events, as idempotent upserts guarded by settlement and payout version.
- A settlement that arrives before its placement converges to a complete row.
- It serves `GET /me/coupons`.
- It matched the payout ledger exactly on 41,391 coupons.

**D64. Steward's model sits behind a port with four providers.**
- `anthropic` calls the API through the official C# SDK, with the system prompt and tool list cached.
- `replay` plays recorded transcripts per scenario and never calls out; CI uses it.
- `disabled` still detects and opens incidents, then records why no diagnosis ran.
- Any provider can be wrapped by a recorder that writes the transcripts replay plays.
- The local default is `disabled` until an API key is supplied.

**D65. A report is accepted only when its evidence checks out.**
- Every evidence excerpt must appear verbatim in the output of the tool call it cites.
- Every runbook citation must be a section that was actually retrieved.
- Every proposed action must be on the allow-list (refresh coupon, suspend market, replay a dead letter).
- One repair round is allowed; after that the incident is stored as a failed diagnosis, with the problems listed.

**D66. Runbook retrieval is hybrid, small-to-big, with a relevance floor.**
- Sections are indexed with pgvector embeddings and Postgres full text, and the two rankings are fused with reciprocal rank fusion.
- The whole parent runbook is returned, with the sections that matched.
- A runbook needs a full-text match or a vector similarity above the floor, so an unrelated query returns nothing rather than the nearest runbook.
- Embeddings come from local Ollama (`nomic-embed-text`) at no cost. CI uses a deterministic hashing embedder.
- Only changed sections are re-embedded, keyed by a content hash.

**D67. Remediation is approval-gated and runs once.**
- Actions are proposed by the model and executed only when an operator approves.
- Approval is a compare-and-set on the action's status, and the action id travels as the idempotency key.
- A second decision on the same action is refused, and every decision is audited.

**D68. Steward's observers start at the latest offset.**
- A new consumer group replaying weeks of history delayed live detection by minutes, which it did in the first drill.
- Building-blocks 0.4.1 adds `StartAtLatest` for new groups. Services that own state keep starting at the earliest offset.

**D69. The four drills exercise real failure paths.**
- Stuck coupon arms the settler drop, and wallet outage arms `wallet.unavailable` for 3,000 calls.
- Poison message publishes a malformed result, and duplicate settlement re-publishes a real settlement under a new event id.
- Drills are refused in Production.
- Live run on 30 Sep: all four opened incidents within seconds of the fault. Stuck coupon waits for the reconciler's pass.

**D70. Contract JSON writes nulls; it never omits them (contracts 0.4.1).**
- Every constructor parameter is required on read. Omitting nulls on write therefore made any nullable field unreadable: `IncidentUpdatedV1` with no root cause was stuck redelivering in realtime.
- `PayoutAttemptV1.LastError` had the same latent defect.
- TypeScript contracts type these fields as `T | null` (0.4.2).

**D71. Realtime is a Kafka-to-SignalR bridge whose groups come from the token.**
- Groups are `ops` (operators), `punter:{sub}` (automatic) and `fixture:{id}` (client-chosen, public prices only).
- Every group has a Redis INCR sequence. A gap, or a reconnect, makes the dashboard re-read over HTTP.
- The Redis backplane fans deltas out across replicas. The Kafka group is per deployment, so each event is pushed once.
- Browsers reach the hub at `/api/hubs/live` through the gateway. The session cookie is scoped to `/api`, so the hub sits under it instead of widening the cookie. Native clients pass `access_token`, on hub paths only.

**D72. Steward's live events are notifications, not the record.**
- A decorator publishes after each stored change. A failed publish is logged and never fails the change.
- The dashboard re-reads the incident over HTTP.

**D73. A signal within 15 minutes of a failed diagnosis folds into that incident.**
- Without this, a wallet still down opened a new incident every 15-second probe.

**D74. Replay is the default local model provider; transcripts are templated.**
- `{{subject}}` becomes the live incident's subject, so the scripted model queries the real incident.
- The evidence validator still checks excerpts against the live tool output, and the executor really runs.
- The E2E and keyless demos exercise the whole pipeline at no cost. `make eval-live` is the gate against the real model.

**D75. Dashboard event types mirror `@swiftbets/contracts` locally.**
- Consuming the npm package in CI would need registry credentials for a public demo.
- The C# contracts stay the source, and their generated TS file is the reference the mirror follows.

**D76. Every .NET repo pins shared packages transitively.**
- Projects that reach contracts only through building-blocks resolved a different version and failed restore on CI (NU1603).

**D77. Charts: one library, one thin chart per service, an infra chart and an umbrella.**
- The library renders the Deployment, Service, probes, HPA, PDB and migration Jobs from values.
- The library also applies the non-root, read-only-capabilities defaults.
- Each Service is named after its chart, so in-cluster addresses match compose (`http://placement:8080`).

**D78. Migrations run as revisioned Jobs, not Helm hooks.**
- Locally the databases live in the same release, and a pre-install hook would run before they exist.
- Each Job is named `<migrator>-r<revision>` and retries until its database answers.
- Services stay unready until their schema exists.

**D79. Redpanda comes from its official chart.**
- It runs as one broker with TLS, SASL and external access off, and topic auto-creation stays disabled.
- The compose topic script runs as a Job against it.
- Compose's init scripts are copied into the infra chart; `scripts/sync-chart-files.sh --check` fails CI on drift.

**D80. Cloud Terraform runs in two applies.**
- The first creates the OCI VM with k3s and Azure SQL. The firewall allows only the node's IP, and each database uses the free offer through azapi, because azurerm has no flag for it.
- The second, once the kubeconfig exists, writes `swiftbets-secrets` and installs the chart.
- State lives in OCI Object Storage over its S3 API.

**D81. The identity signing key is a managed secret.**
- Without one, each placement pod signed with a throwaway key: a restart, or a second replica, invalidated every token. Production refused to start at all.
- Local installs generate the key once and keep it across upgrades (`lookup`). The cloud key comes from Terraform's `tls_private_key`.

**D82. Images carry a moving `main` tag, and deploys need an approval.**
- `deploy.yml` targets the `cloud` environment, which requires a reviewer and accepts only `main`.
- `:main` pulls are `Always` in the cloud, and the deploy restarts deployments onto the current image.
- kind CI installs the full chart on every platform change.
- Measured on single-node kind: 1,274 placements, all accepted, with p99 327 ms through a port-forward.

**D83. Fault drills shape outages by time (building-blocks 0.4.2).**
- `?seconds=` arms a point for a window, and the wallet drill is a 90-second outage.
- A call count was spent in about 75 seconds by placement debits, before any payout reached the ladder.
- Proven live: about 90/94/31 attempts on the 5s/1m/15m rungs, and a wallet-outage incident.

**D84. Rejected service tokens are dropped at once (building-blocks 0.4.3).**
- `ClientCredentialsTokenProvider.Invalidate` drops a token the receiver rejected.
- Payout invalidates on `Unauthenticated` from the wallet and routes the payout to the ladder. Steward invalidates on 401.
- Compose now has a stable signing key in `.env`, generated by `make env`. Before this, a placement restart left payout redelivering with a dead token for up to five minutes.

## Product plan (1 Oct 2026)

**D85. The product plan is approved** (`docs/PRODUCT_PLAN.md`), with the answers recorded in D97-D99 and D91. E1 starts at once, with the D7 wallet reconciler first.

**D86. Every feature ships with its UI.**
- `swiftbets-web` is scaffolded in E1 (register, verify, login, reset, account, sessions); the operator console gains its customer-service view in E2.
- E6 and E9 become completion epics: brands, performance and SEO for the web; trader polish, reporting and notifications for the back office.

**D87. Alerts and runbooks ship with the feature that needs them.**
- Rules live in `compose/prometheus/rules/<area>.yml`, each with a `runbook` annotation naming a runbook in `swiftbets-steward/runbooks`.
- Every rule file has a `<area>.test.yml` promtool unit test; `scripts/check-prometheus.sh` runs both in CI.
- E10 keeps Alertmanager routing, drills, the status page and the load test.

**D88. Risk limits reach placement on a compacted topic, never by a call.** Placement hydrates them to partition end before it reports ready and enforces them locally. Supersedes D27's "advisory only"; placement's risk module stays the hard gate.

**D89. Repositories.**
- Twelve new public repos under `remonenaidoo`: `swiftbets-identity`, `-wallet`, `-compliance`, `-payments`, `-config`, `-bethistory`, `-cashout`, `-casino`, `-web`, `-design-tokens`, `-reporting`, `-notifications`. Public, so release-asset packages need no credentials (D34).
- `swiftbets-casino` holds the gateway, catalog and simulated-provider hosts. Two simulated providers (seamless and transfer wallet) stand in for a real sandbox.
- The admin gateway is a second host in `swiftbets-gateway`, with its own deployment, hostname and permission policies.
- The outbox relay stays in-process (D51), not a separate service.
- A platform workflow opens the pinned bump PR in every consumer when contracts or building-blocks release.

**D90. Store rule (ADR 0001).** SQL Server for services that move money or hold regulated state (identity, wallet, compliance, payments, casino rounds). Postgres for read models and non-money stores (catalogue, bet history, config, reporting, notifications, Steward, risk journal). Building-blocks gains a Postgres outbox for the latter.

**D91. Environments (ADR 0004).**
- **dev:** compose, plus an ephemeral kind install on every platform PR (already in CI).
- **staging:** the existing self-hosted preview.
- **prod:** fully defined in Helm values and a Terraform root; CI runs `helm lint`, kubeconform and `terraform validate`/`plan`. Nothing is applied: there are no cloud accounts and no paid budget yet.
- Terraform uses a directory per environment over shared modules, not CLI workspaces.

**D92. Secrets (ADR 0004).** With no cloud vault available, secrets are SOPS files encrypted to age keys, one per environment (`secrets/<env>.enc.yaml`). The deploy job holds that environment's age key as a GitHub environment secret and decrypts at deploy time; nothing decrypted is written to the repo or an image. External Secrets Operator replaces this once a vault exists, with no change to the services, which read only environment variables.

**D93. Browser sessions are opaque and server-side (ADR 0002).** The gateway cookie carries a random session id; tokens, device and last-seen live in Redis and rotate on refresh. Device sessions can be listed and revoked, and suspension or self-exclusion deletes them at once. No route ever returns a bearer token to JavaScript.

**D94. The customer web renders on the server with React Router 7 framework mode (ADR 0003).** Loaders call the gateway with the session; TanStack Query is seeded from the loader; the Node server mints the CSP nonce per request; brands are chosen at build time from `swiftbets-design-tokens`; modern browsers only, under a bundle budget.

**D95. Migrations ship with rollback scripts (ADR 0005).**
- Each new `Migrations/NNNN_name.sql` has `Rollbacks/NNNN_name.sql`, embedded but never run by DbUp, which reverses the change and deletes its journal row.
- CI proves up-down-up for every new migration. Building-blocks adds `--to <version>`.
- Existing initial schemas (`0001`/`0002`) are not rollbackable: their rollback is dropping the database, and they hold no product data yet. First use: wallet `0004_reconciliation`.

**D96. Responsible-gambling limits are enforced in the wallet transaction (ADR 0006).** Compliance owns limit values and publishes them on a compacted topic; the wallet keeps period counters and refuses a reserve or deposit credit under the same account lock that moves the money.

**D97. Payments: Stripe in test mode only, plus a standalone simulator.**
- The Stripe adapter refuses to start with a live key (`sk_live_`/`rk_live_` prefixes).
- The in-repo simulator implements the full provider port (deposit, withdrawal, signed webhooks, delays, failures) with no Stripe dependency. It is the default in dev, CI and staging, and every payments test runs against it.

**D98. Feed: the replay stays the feed for now.** The real adapter (API-Football) is built behind the feed port when a key is supplied as the `FEED_API_KEY` credential; CI only ever uses recorded responses.

**D99. Jurisdiction, currencies and brands.** South African rules: 18+, limit increases take effect after 24 hours, decreases at once, self-exclusion minimum 6 months. Currencies ZAR (primary) and USD. Brands SwiftBets and SwiftPlay.

**D100. Back office authorises by permission.** Identity maps roles (customer, agent, trader, ops, admin) to permissions and puts a `perm` claim in staff tokens only; the admin gateway authorises each route by permission policy. The current `Punter`/`Operator`/`Admin` roles are accepted alongside for one release.

**D101. The wallet reconciler reports and never repairs (implements D7).**
- Daily by default: punter balances against their entries per bucket, reserved funds against held reservations, every posting balancing, the ledger summing to zero.
- Each check is one statement, so read-committed snapshot gives it one committed state and an in-flight posting cannot appear as drift (proven by a concurrent test).
- House and funding balances are not projected (a hot row on every bet), so the posting and ledger-total checks cover them.
- Runs and drifts are stored, exposed at `GET /reconciliation/latest`, and alerted on (`WalletLedgerDrift`, runbook `ledger-drift`).


**D102. Until the new repositories exist, new hosts live in the nearest existing repository.**
- Creating repositories is refused for this project's GitHub integration (403), so D89's repos cannot be made from a session yet.
- Each new service is still its own host with its own database and images (as the wallet already is), so moving it changes no code: `scripts/split-repo.sh` moves it with its history once the repo exists.
- The identity service is built in `swiftbets-placement`, where the identity module it replaces lives. The customer account screens are built in `swiftbets-mobile`, whose web build is the public site until `swiftbets-web` exists.
- The identity chart was switched on once its image was published from placement's `main`; compose already ran it.

**D103. Coverage is measured in CI with a branch floor on money-path Domain and Application projects.**
- `dotnet.yml` takes `coverage` and `coverage-floors`; tests run with the Microsoft Testing Platform coverage extension and emit Cobertura.
- `scripts/check-coverage.py` merges every report per assembly (a line counts if any test project hit it), posts a table to the job summary and fails under a floor.
- Floors sit a few points under what is measured on adoption and only move up; first set for placement: Wallet Domain and Application 70% branch, Placement Domain 70%, Placement Application 55%, Identity Domain 90%, Identity Application 80%.
- No extra tool is installed: the merge is about 80 lines of Python with its own fixture test in platform CI.

**D104. Demo wallets are funded by a migrator switch, not a migration.**
- `SbWallet` 0003 funded five demo punters in every deployment, production included.
- 0005 removes seeded punters that were never used (balance untouched, no other posting or reservation), so a demo environment with activity keeps its ledger whole; its rollback puts the seed back.
- `Migrator:SeedDemo=true` re-applies the seed idempotently after migrations; compose and the default chart values set it, production values set it to false and `check-prod-values.sh` refuses it.
