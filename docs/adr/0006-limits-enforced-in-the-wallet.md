# 0006. Responsible-gambling limits enforced in the wallet

- **Status:** Accepted, 1 Oct 2026 (D96)

## Context

Deposit, stake and loss limits must hold under concurrency. If placement or payments asked a compliance service "may this customer stake R100?", two concurrent requests could both be told yes and together breach the limit. A synchronous check would also make a compliance outage a betting outage.

## Decision

- Compliance owns limit values, restrictions and their history (cooling period on increases, immediate decreases), and publishes the effective values per account on a compacted topic.
- The wallet hydrates that topic and keeps per-account period counters (deposits, stakes, net loss per day, week and month), updated in the same transaction as each posting.
- A reserve or a deposit credit that would breach an effective limit is refused under the same account lock that moves the money, with a typed failure (`stake_limit_reached`, `deposit_limit_reached`, `loss_limit_reached`).
- Self-exclusion and suspension refuse every debit and deposit in the wallet, block login in identity, and end sessions at the gateway (ADR 0002).
- Payments checks deposit headroom before creating a provider intent, so customers are not charged for a deposit the wallet will refuse.

## Consequences

- Limits cannot be raced past, and they keep working while compliance is down.
- The wallet gains period-counter state and a compacted-topic consumer; its readiness waits for hydration.
