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

**D105. Shared packages can be released by a dispatched workflow as well as by a pushed tag.**
- Sessions can push branches but not tags, so the release workflow takes a `version` input and creates the tag through the API on the commit it built.
- Contracts and building-blocks run it with `workflow_dispatch`; a pushed `v*` tag still works exactly as before.

**D106. A repository split merges with a merge commit, not a squash.**
- `split-repo.sh` keeps each moved file's history; squashing the first PR would collapse it into one commit.
- So the first PR into `swiftbets-wallet` and `swiftbets-identity` merged as a merge commit; every later PR squashes as usual.

**D107. Notifications decides delivery from the request and its own projection, and never stores a body.**
- One `deliveries` row per notification id makes a redelivered request a no-op; a send failure records nothing, so the retry sends.
- Marketing goes only to active accounts, from a projection of `AccountStatusChangedV1`; service email (verification, reset) always goes.
- Senders build their own links; a template lists the data keys it needs and a request missing one is rejected, not sent with a hole.
- No SMTP host means requests are recorded as skipped, never as sent, and `NotificationsNotSending` alerts.
- Identity hands account email over with `AccountEmail:Delivery=Notifications`; SMTP from identity stays as the fallback until the chart runs notifications.

**D108. Identity's account events commit in the same transaction as the change.**
- The store enqueues `UserRegisteredV1`, `EmailVerifiedV1`, `AccountStatusChangedV1` and, when an account leaves Active, `SessionRevokedV1` into the outbox inside the write's transaction.
- A refused or repeated change publishes nothing; every event is keyed by user id, so one customer's events stay in order.

**D109. Front-end packages are released as tarballs on GitHub releases.**
- `@swiftbets/design-tokens` is packed by a dispatched release and attached to `v<version>`; consumers depend on the tarball URL, the same way the TypeScript contracts ship.
- No registry account or token is needed, and a version is immutable once released.

**D110. The server-rendered site runs beside the mobile web export until it serves every page.**
- Its image is `swiftbets-site`, because `swiftbets-web` is already the export's package and a new repository cannot publish to it.
- The gateway sends `/account/*`, `/site-assets/*` and `/__manifest` to `site`; everything else still reaches `web`. Each page moves as the site gains it, then the catch-all flips and the export retires (ADR 0003).

**D111. Placement drops its `auth` schema one release after the identity cut-over, not in E1.**
- Migrator Jobs run in parallel in Kubernetes, so a drop in the same release could run before identity's import on an existing install.
- Identity's import now skips when placement holds no `auth` tables. Placement `0003` (drop, with a rollback that recreates the tables empty) ships with the first E2 placement release, after staging has run the import.

**D112. The audit writer ships with the audit service in E2, not in E1 shared tooling.**
- E1 has no consumer of `AuditRecordedV1`; writing the helper beside its first reader (compliance) avoids guessing its shape.
- It lands in building-blocks 0.6.0 alongside contracts 0.6.0.

**D113. The browser session cookie covers the whole site, not just `/api`.**
- Server-rendered pages (`/account` today, every page later) must see the session; a cookie scoped to `/api` never reaches them.
- It stays HttpOnly, Secure and SameSite=Strict; each write and sign-out also expires the old `/api` copy.
- `scripts/gate-e1.sh` proves the E1 gate through the gateway: register, age gate, emailed verification through Mailpit, two devices, revoke one, account page, seeded sign-in. The kind install runs it once identity and wallet publish their own images (they still need package access).

**D114. Contract versions follow semver, not the roadmap table.**
- An additive change takes the next minor even within an epic; the wallet failure codes for limits and restrictions made contracts 0.7.0 during E2.
- The roadmap's later numbers shift by one (payments 0.8.0, and so on); majors stay tied to their epics.

**D115. Compliance runs on SQL Server as `SbCompliance`, the sixth free-offer database.**
- Limits and exclusions are regulated state (D90). Six of the ten databases the free offer allows are now used; payments and casino rounds bring it to eight.
- `compliance.restrictions-changed.v1` is compacted; the wallet reads it to the end before it reports ready, so it never takes a stake against rules it has not seen.

**D116. Session-time limits are enforced by the gateway per browser session; reality checks are shown by the site.**
- The gateway reads compliance's compacted snapshot and ends a browser session once it is older than the customer's limit (401 `session_time_limit`). Signing in again starts a new session; a cool-down between sessions is not a South African requirement and is left out of E2.
- `GET /api/session` reports `startedAt`, `sessionLimitMinutes` and `realityCheckMinutes`; the site opens a "Time check" reminder at each interval, with links to safer gambling and sign-out.
- Building-blocks 0.6.1: a compacted-state reader now waits out an unreachable broker instead of stopping its host.

**D117. Identity verification uses a sandbox provider until a real one is contracted; withdrawals gate on it in E3.**
- `IKycProvider` keeps the provider swappable; the sandbox accepts well-formed SA ID numbers (Luhn) and passports, and rejects numbers ending in 0000 so tests can drive both outcomes.
- Only the document type and last four characters are stored.
- KYC status travels in the compacted snapshot; payments (E3) refuse withdrawals unless it is verified.

**D118. A customer holds one wallet account per currency; the first keeps the user id as its account id.**
- Placement and payout address accounts by user id today. Keeping that id for the first account (`0007_currency_accounts` maps every existing account to (user, its currency)) means neither changes in E3. Betting in a second currency is a later step.
- House and funding accounts exist per supported currency (ZAR, USD), so every posting stays within one currency.
- Responsible-gambling limits are read per user and apply only to accounts in the limit's own currency; blocks apply to every account.
- The bonus bucket exists as a column, a balance field and a reconciliation check. Nothing credits it until promotions arrive.

**D119. Paystack in test mode is the real deposit provider; payouts go through the simulator in v1.**
- Paystack supports ZAR, has a free test mode, and signs webhooks with HMAC-SHA512 of the body. CI never calls it: the adapter is tested against recorded responses.
- Payouts need a contracted provider and a verified business. The simulated provider (its own host, with fault switches for duplicate, reordered, failed and withheld webhooks) stands in until then.
- Providers that need an email get `<user id>@<configured domain>`; the customer's address never leaves the platform.

**D120. A deposit is credited under a key fixed by its id, then completed only if it is still open.**
- So a webhook delivered twice, late or out of order credits once. A crash between the two steps is finished by the sweep, which asks the provider and applies the answer the same way.
- A deposit the wallet refuses after payment (a limit or restriction) fails and is refunded at the provider. Payments does not pre-check limits; the wallet is the one place they are judged.
- A provider success for a different amount is not credited; the daily reconciliation reports it.

**D121. Withdrawals need a verified identity and a wallet hold; above a per-currency threshold an operator decides.**
- KYC status comes from compliance's compacted snapshot (D117). Only a no-withdrawals restriction stops a withdrawal at the wallet; an excluded customer can always take their money out.
- Thresholds: R5 000 and $300. A rejection returns the hold at once.
- The status changes before the wallet is told, and `HoldSettled` records that it was told, so the sweep finishes any step a crash interrupted.

**D122. Reconciliation is daily per provider, SA calendar day, tolerant of midnight; drift opens a Steward incident.**
- A reference only one side lists for the day is looked up on the other side before it counts, so a payment that settles either side of midnight is not drift.
- Drifts are stored, exported as `swiftbets_payments_reconciliation_drifts` (alert `PaymentsReconciliationDrift`), and published as `payments.drift-detected.v1`. Steward opens one `PaymentDrift` incident per provider and day, with the `payment-drift` runbook; remediation stays manual.
- `SbPayments` is the seventh free-offer database (D115).

**D123. The site hands deposits to the provider's hosted checkout; the console decides held withdrawals.**
- The deposit form posts to the site, which redirects to the provider's checkout. The site's CSP `form-action` lists those origins from `CHECKOUT_ORIGINS` (default Paystack checkout; the simulator locally), so the redirect also works without JavaScript. Card details never touch SwiftBets.
- Ops and Admin get `payments.read` and `payments.approve` (identity migration 0007). The console's Finance view shows the approval queue and the latest run per provider.
- Local clusters request 20m CPU per service so the whole platform fits one kind node; production values are unchanged.

**D124. Operational settings live in the config service and travel on one compacted topic.**
- Config contracts ship as contracts 0.9.0, ahead of the 1.0.0 major (envelope context, coupon V2), so E4 can start without the envelope change. The roadmap's 1.0.0 keeps everything else.
- `config.entries.v1` is compacted and keyed by setting; `ConfigKeys` in the contracts names every key and holds the one validator the service enforces and the parsers consumers use. A key never set means the consumer's built-in default, so an empty topic changes nothing.
- `sb_config` is Postgres (D90) and the first user of the Postgres outbox. Changes need a reason, are versioned with history and audited; Admin writes, Ops reads (identity 0008).
- Placement refuses while the kill switch is on or the mode is `closed`, and above per-currency stake and payout limits, before any funds are held. Placement reports ready only once it has read the topic to the end, so a restarted replica cannot miss an active kill switch. `preMatchOnly` waits for the in-play market state.
- Existing local Postgres volumes created before this need `sb_config` added by hand or a fresh volume; the init script runs once.

**D125. The V2 bet model arrives behind a flag and dual-published, and contracts 1.0.0 stays binary compatible.**
- A coupon holds bets; a bet is a set of fold sizes over the non-banker legs, and bankers join every line. `SystemBets` in the contracts gives the lines, so placement prices exactly what settlement pays. Each line rounds down on its own; void legs count at 1.00.
- `EventEnvelope.Context` is an init property and `Create` keeps its 0.x overload, so building-blocks 0.7.0 and every service built on 0.x run unchanged against 1.0.0. The plan called 1.0.0 a breaking major; it ships as a compatible one instead, and the breaks wait for 2.0.0.
- Placement publishes V2 for every coupon and V1 for any coupon V1 can describe. Settlement indexes both, once per coupon, adopting placement's bet id from V2. It publishes `CouponSettledV2` and keeps `CouponSettledV1` with the coupon's total target, so payout and history need no change yet.
- System bets and bankers stay closed behind `flags.system-bets` until settlement on V2 is deployed; an operator turns the flag on from the console.

**D126. Bet history is its own service, swiftbets-bethistory.**
- The read model moves out of placement unchanged: same `sb_history` schema, same consumer groups and the same migration journal names, so an existing database carries over and nothing is replayed. The migrator gains rollbacks.
- Customers read `/me/coupons` (and one coupon) through the gateway; operators look up any punter's coupons under `/admin/history`. Placement keeps its copy read-only (`History:RunProjector=false`) until its History projects are removed.
- History still projects `CouponSettledV1`, which settlement publishes for every coupon; it moves to V2 with the contracts 2.0.0 cleanup.

**D127. E4 closes on its core; trading, cashout and the web sportsbook move to E4b.**
- E4 closes on features 1-3: the V2 bet model with bankers and system bets, the config service with the kill switch, and bet history as its own service. The `live-gate` run is green on every step: kill switch within 5 seconds, banker Trixie as four lines, and bet history showing it as a system bet.
- Features 4-9, contracts 2.0.0 and the gate items they carry (cashout against a late result, manual void from the console, real-feed contract tests, resettlement through the stack) form E4b. E4b runs before E5 with its own `gate-e4b.sh` in `live-gate`.
- Why: the E4 core is what later epics depend on; the rest is a separate slice with its own owner decision (the feed provider key). Closing a working, gated slice is better than leaving the epic half open.
- E4b reverts to E4 if the owner prefers a single epic; nothing built depends on the split.


**D128. A time-void never guesses a placement time.**
- Settlement stores each coupon's placement time from 0004 onwards; a time-void voids legs on coupons placed at or after the trader's cut-off.
- Coupons indexed before 0004 have no stored time. They are left alone, counted and logged, so a trader can void them by coupon if needed. Voiding them on a guess could void bets placed fairly before the event.

**D129. A cashout is a settlement, paid on the normal path.**
- Settlement's `CashOut` takes the coupon lock and sets a final state. It then writes the next settlement version with outcome `CashedOut` at the agreed amount, and publishes it like any other; payout pays the delta under a `CASHOUT` key. There is no second money path.
- The final state is enforced twice. In SQL, the settler refuses a final coupon under its lock. In Redis, the progress script stops counting evaluations once the coupon's final flag is set.
- A manual result touching a cashed-out coupon publishes `ManualResultRejectedV1` (`coupon_cashed_out`) and changes nothing. A cashout racing a late result yields exactly one settlement: whichever commits first under the lock decides.
- Consumers of settlements moved to contracts 1.2.0 before settlement could emit `CashedOut`.

**D130. Cashout quotes are stateless tokens; execute pays the quote within a leeway.**
- The token is an HMAC-SHA256 over the quote id, coupon, punter, amount, currency and issue time, with a 10-second max age; verification is constant-time.
- Live prices are not in the token, unlike the blueprint's wording: execute reprices at live odds anyway, so the signed amount is what needs protecting.
- Execute pays the quoted amount if the live value is no more than 2% below it; otherwise it refuses with a fresh quote. The quote id is the cashout id, so a retried execute pays once.
- v1 cashes out singles and accumulators only (one bet, one line); system bets are refused with `not_single_line`.
- Price: stake × Π(won placed odds) × Π(open placed ÷ live odds) × (1 − 5% margin), void legs at 1.00, capped at the potential payout, rounded down.

**D131. Payout refuses an outcome it does not know.**
- An unknown coupon outcome now throws, so the attempt retries and dead-letters, instead of being treated as a loss. Treating it as a loss would have clawed money back from a `CashedOut` settlement.

**D132. The offer is fed through one port; the replay is its first adapter.**
- `IFeedAdapter` returns the feed's current view per poll, and `FeedSync` applies it idempotently: a fixture is saved and published only when its status or prices change, and each result version is published once. Versioning, suspensions and availability belong to offer, not the feed.
- The recorded-season replay is now `ReplayFeedAdapter` and stays the dev and demo default. A real provider is one more adapter behind a flag.
- Operator suspensions are matched by market id, not position, so a provider that reorders markets cannot reopen one.

**D133. Stale feed data suspends markets automatically and reopens exactly what it suspended.**
- Freshness is the provider's own update time, not our poll time. A scheduled fixture older than `Feed:StaleAfterSeconds` (default 120) has its open markets suspended, with `MarketStatusChangedV1` source `staleness`.
- The guard runs every tick even when the poll failed. Fresh data reopens only the markets staleness suspended, so a trader's suspension is never undone by the feed.

**D134. The catalogue is a Postgres read model, refreshed in one batch per tick.**
- `sb_catalog` holds sports, competitions and fixtures for browsing. Redis stays the live truth for prices and status; placement never reads the catalogue.
- Each tick upserts every polled fixture in one statement; a row only moves forward in `offer_version`, so the catalogue heals itself after an outage and a late write cannot regress it. A catalogue failure is logged and never stops the offer.
- Competition ids are slugs of the provider's competition name, so replay and a real feed share ids for the same league.

**D135. Postgres databases are provisioned idempotently on every compose up.**
- `10-databases.sh` creates each login and database only if missing, and the one-shot `postgres-provision` service reruns it before the migrators. A volume created before a new database (as `sb_config` and `sb_notifications` were, D90) now gets it without a hand step or a fresh volume.
- The infra chart carries the same script; an existing cluster volume can rerun it with `kubectl exec`.

**D136. Gates only bet on fixtures at least two minutes from kickoff.**
- The E4 gate picked the soonest fixtures; on the catalogue PR its first leg kicked off between listing (11:26:58) and placing (11:27:05), and placement rightly refused a market that had gone in play. The gate, not the stack, was wrong.
- `gate-e4.sh` and `gate-e4b.sh` now skip fixtures within 120 seconds of kickoff; the replay lists 20 minutes ahead, so there are always enough.

**D137. In-play seams: placement knows a leg is live, waits the live delay outside the saga, and re-prices.**
- A quote marks a leg live when its fixture is in play; it is tradable only while the feed keeps its market open. Both feeds suspend at kickoff today, so nothing is bettable in play until a live feed says otherwise.
- A coupon with a live leg waits `placement.live-delay-seconds.{sport}` (else `.default`, else 0, capped at 30) before its saga starts, so the wait never eats the saga deadline; the saga's own quote is the refresh that refuses a market suspended or a price moved during the delay. `preMatchOnly` now refuses live legs.
- `POST /coupons/refresh` lets a betslip re-read its legs without placing. Every fixture is football today, so the sport key is `soccer`.
- Offer's market lifecycle makes closed final for traders and feeds alike.

**D138. Bet-history integrity is checked against each owner's digest, not by reading other databases.**
- Placement, settlement and payout each expose an internal, Service-only digest of their own facts; bet-history compares its rows with them every 15 minutes over the last 24 hours and records each run (`sb_history` 0003).
- Events younger than 10 minutes are in flight, not findings. Findings are `missingInHistory`, `placementMismatch`, `settlementBehind` and `paidMismatch`; operators read the latest run at `/admin/history/integrity/cross-store`.
- Why: services own their stores (D-rule since E1); a digest API keeps that boundary and needs no cross-database credentials.

**D139. A high advisory with no fix can be excused per repo, with a reason and an expiry; nothing else gets through.**
- The shared node workflow runs `scripts/npm-audit-gate.mjs` in place of `npm audit --audit-level=high`. Any high or critical runtime advisory fails the build unless the repo's `.audit-allowlist.json` lists its GHSA id with a reason and an `expires` date; an expired entry fails too, forcing a fresh review.
- First use: GHSA-86w9-cpqp-85rv (node-forge, reached only through the Expo CLI's code-signing at build time, absent from the web bundle and the APK, no patched release) in swiftbets-mobile until 2026-11-02.
- Why: the alternatives were switching the gate off or blocking every web and app change until an upstream release; an expiring, reasoned exception keeps the gate meaningful.

**D140. Contracts 2.0.0 removes the V1 coupon events; `swiftbets.wallet.v1` stays.**
- The plan removes `CouponPlacedV1`, `CouponSettledV1` and `swiftbets.wallet.v1` "once no consumer or open coupon uses them". The coupon events meet it: payout, bet history, realtime and steward read V2, placement publishes V2 for every coupon, and settlement stops publishing V1.
- `swiftbets.wallet.v1` is the only wallet API: placement, payout, payments and wallet itself call it and no v2 exists. Its condition is not met, so it stays; a wallet v2 is designed when the wallet contract actually needs to change, not to rename one.

**D141. Traders can look up what became of a manual result; drills publish results in a chosen order.**
- Offer consumes `ManualResultRejectedV1` and serves `GET /admin/trading/manual-results/{id}` with every coupon settlement refused to change and why; the console's live log stays the real-time view.
- `POST /admin/trading/drills/results` publishes a feed result at a chosen version, mapped only where fault injection is on (compose and the live gate; production refuses it). The E4b gate uses it for out-of-order resettlement and the cashout race.

**D142. The casino is one repo with three hosts: gateway, catalogue and simulated providers.**
- The gateway moves money and owns regulated state, so it uses SQL Server `SbCasino`. Its tables are sessions (only a SHA-256 of each token is stored), transactions (unique on provider and provider transaction id), free-spin grants and reconciliation runs.
- The catalogue is a read model in its own Postgres database `sb_casino`, not offer's `sb_catalog`. One database per owning service keeps migrations and grants separate.
- The two simulated providers (seamless wallet and transfer wallet) stand in for real aggregators, which issue sandboxes only under a commercial agreement (C1).

**D143. Providers authenticate every wallet call with an HMAC of the raw body; each callback is applied once.**
- `X-Provider-Signature` is a lower-case hex HMAC-SHA256 of the raw body under the provider's own secret, checked in constant time before the body is parsed.
- The provider's transaction id is the idempotency key and the wallet's posting key (`casino:{provider}:{ptx}`). A duplicate returns the original result and moves no money.
- A rollback for a bet never seen is stored and accepted with amount zero. If that bet arrives later it is refused (`bet_rolled_back`), so a reordered pair can never take the stake.

**D144. Casino launch fails closed on restrictions, and game pages load through the public origin.**
- Launch reads the compacted `compliance.restrictions-changed` topic. An active self-exclusion, cooling-off or no-betting restriction refuses it with `casino_restricted`. Until the topic has loaded, launch refuses with `restrictions_unavailable` rather than guessing.
- Browsers reach the simulator only at `/casino-sim/*` through the gateway, so game pages share the site's origin. The site frames only a session it launched itself, and the frame is sandboxed.

**D145. Casino launch asks compliance directly; the topic is only a fast path to refuse.**
- The E5 gate showed a customer could launch a game in the moment after taking a break, before the compacted topic delivered it. Refusing play has to be strongly consistent.
- Launch refuses at once if the topic already holds a blocking restriction. Otherwise it calls compliance's service-only `GET /internal/users/{id}/restrictions`, with a 3 second timeout. Any failure to get an answer refuses with `restrictions_unavailable`, so a compliance outage stops casino launches, not safer-gambling checks.
- A break also ends the customer's sessions. The gate accepts either outcome: sign-in refused, or launch refused with `casino_restricted`. It fails only if a game opens.

**D146. E6 drops new Playwright coverage; the gate is builds, budgets and Lighthouse.**
- The owner ruled Playwright work out of E6 as poor value. The existing e2e job stays as it is; no new browser tests are written for the second brand or the money flows.
- The E6 gate is now:
  - both brands build in CI;
  - each brand's web JavaScript stays under 400 KB gzipped;
  - Lighthouse accessibility scores 100 on desktop and mobile against the live stack.

**D147. Mobile LCP is a ratchet at 9 s until the site is pre-rendered.**
- Measured on the live stack with Lighthouse's simulated slow 4G: 12.3 s before gzip. With gzip it is 5 to 8 s; desktop is 1.4 s.
- The rest of the wait is render delay. The page draws only after about 355 KB of React Native Web runs and the session check returns. Preloading the banner, and splitting the code by route, were each measured and gave no gain.
- Reaching 2.5 s needs the pages pre-rendered as HTML at build time, so the first paint does not wait for the JavaScript. Until then, desktop is held to 2.5 s and mobile to 9 s, so it cannot get worse.

**D148. The app hands its sign-in to the hosted account pages through a single-use link.**
- Wallet, limits and account pages stay server-rendered on the account site. The Android app opens them in an in-app browser, which has no app tokens.
- The app posts its refresh token to `POST /api/session/handoff`. Identity's `/auth/handoff` rotates the app's own token and issues the browser a separate device family, so signing either out leaves the other signed in.
- The gateway keeps only the SHA-256 hash of a 60-second code in Redis and takes it with GETDEL. A replayed link lands on sign-in. `next` is restricted to the three account pages, so it can't be used as an open redirect.
- The app makes refresh and handoff take turns on the token, because spending a single-use token twice would sign the device out as reuse.

**D149. E7 scope: no Maestro, the web export stays, no biometrics.**
- Maestro smoke tests are cut on the same reasoning as Playwright (D146).
- "Retire the web export" is dropped: the punter site at the link root is that export, under the web-first rule.
- Biometric unlock was the plan's optional cut, and it is cut.
- Proof of the money flows on Android is the signed release APK from the `v*` tag, installed by the owner. Casino on Android opens the provider's launch URL in the in-app browser.

**D150. Risk event-sources each fixture with its own Dapper journal, not Akka.Persistence.**
- `Akka.Persistence.Sql` works through linq2db, and the stack is Dapper only. Each `FixtureActor` journals placed and settled changes to `risk.journal`, keyed by fixture and version and unique per coupon and kind. It snapshots to `risk.snapshots` every 50 changes (10 in compose, so the gate's restart exercises it). On first use it loads the snapshot and replays the journal after it.
- A change is journalled before the actor replies, and the Kafka consumer commits only after every fixture it touches replied. A failed write restarts the actor, which reloads. A coupon seen twice, or a settlement that arrives before its placement, changes nothing.
- Liability counts each coupon's whole potential payout on every outcome it backs. That is conservative for accumulators and system bets, which is the safe side for a cap.
- Pattern windows live in memory, and a restart starts them empty. Alerts are advisory, stored for the console and published.
- The local `FixtureRegion` routes with `FixtureMessageExtractor`, a `HashCodeMessageExtractor`, so a cluster `ShardRegion` can replace it.

**D151. Customer notifications are driven by domain events; addresses stay off Kafka.**
- Notifications consumes settled coupons, successful deposits, limits reached and self-exclusions. Each becomes an in-app inbox message and an email, both with ids derived from the event, so a redelivery sends nothing more. Messages are dated by the event.
- The wallet publishes `wallet.limit-reached.v1` when one of the customer's own limits refuses money. It publishes after the refused transaction rolls back, best effort, at most one notice per limit per day.
- The email address is looked up at send time from identity's service-only contact endpoint. Suspended and self-excluded accounts are still written to (a break must be confirmed); only a closed account is not. Marketing stays filtered separately.
- Customers choose email and inbox per event, except break confirmations, which always go out on both. New consumers start at the newest event, so a first deployment never notifies anyone about the backlog.

**D152. The reporting warehouse reconciles to the ledger, not to its own events.**
- `sb_warehouse` holds facts keyed by their source ids (bets, settlements, payouts, casino transactions) and a daily view. GGR is sports turnover minus payouts, plus casino staked minus returned.
- Each day reconciles against the wallet's own postings (`/reconciliation/daily-totals`): stakes captured, non-casino credits minus debits, and `casino:` debits and credits. Every figure must match to the cent. The wallet publishes no posting events, so the ledger stays the single source of truth.
- Finance reads the daily figures in the console and as CSV; Grafana's Business dashboard reads the warehouse through a read-only login.

**D153. The console shows staff only what their permissions allow; the services enforce it.**
- The session lists the access token's `perm` claims, and the console hides screens without the permission, even at a typed address. Every service still refuses the call.
- Roles and their permissions are managed in the console (`identity.roles.read`/`write`, Admin only). Admin can never lose role management, and nobody can remove their own Admin role. Changes reach staff at their next sign-in.
- Finance reports (`reports.read`) are for Admin and Ops; traders don't get them. `trader1` is the demo trader seat, used by the E9 gate.

**D154. Steward takes every alert, proves its reasoning on replays, and never sees personal data.**
- Alertmanager sends every alert to Steward's webhook with a shared bearer token. A rule table maps each platform alert to an incident kind, with the subject taken from the alert's label; a test fails the build if a platform alert has no rule. The casino's provider reconciliation opens `ProviderDrift` from its topic.
- New tools read the wallet's ledger reconciliation, the casino's provider reconciliation, and customer impact. Customer impact returns counts, never ids.
- New remediations: the kill switch, replaying payment webhooks (the payments sweep run now) and re-driving parked payouts. Each still needs a person's approval and is audited; each target service accepts the Service role for exactly that call.
- A scrubbing decorator sits outermost around the model, so email addresses, phone numbers, card numbers and ID numbers never reach the provider or a recorded transcript.
- CI gates use no model calls:
  - every alert class replays through the real agent loop and validator to an evidence-valid report with the runbook's action;
  - the runbook retrieval evaluation must keep hit@3 at or above 90%. It measured 43% before this work, because full-text search required every word; with any-word matching it measures 97%.
- Where no model key is configured (the preview), a live incident's replay diagnosis fails validation and is stored as failed. Steward proposes nothing it cannot prove.

**D155. Core platform first; one casino provider built to production grade.**
- `docs/BACKLOG.md` is the build order: P0 core money loop, P1 one casino provider, P2 sportsbook depth, P3 account extras, P4 expansion products. Risk stays paused.
- The casino adapter is Pragmatic Play's seamless wallet: the widest catalogue and a public demo mode, so free games cover test runs without a contract. Other providers follow the same template once contracted.
- The adapter fixes what weaker integrations get wrong: every callback is signed and comes from an allowlisted address, a repeat returns the original reply, refunds use the recorded stake, and a refund for an unseen bet leaves a marker that refuses the late bet.
