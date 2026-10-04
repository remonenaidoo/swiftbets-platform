# SwiftBets - Build Backlog

The order is strict: a fully working core platform first, then expansion. Each item ships with its admin screen, one positive and one negative test, and a live check on mobile and desktop. Status: ✅ live, ⏳ next, ☐ to do.

## P0. Core platform: a customer can sign up, fund, bet, get paid and withdraw

| # | Item | Status |
|---|---|---|
| 1 | Sign-up, login, verify, password reset | ✅ |
| 2 | Wallet, deposits, withdrawals, statement | ✅ |
| 3 | Football betting: listing, match page, bet slip, singles, multiples, bankers, system bets | ✅ |
| 4 | Placement, settlement, payout, cash out, my bets | ✅ |
| 5 | Limits, self-exclusion, cool-off, inbox, email notifications | ✅ |
| 6 | Real odds feed live on the preview (API-Football adapter; needs the key) | ⏳ |
| 7 | Core money-loop hardening: end-to-end run of sign-up → deposit → bet → settle → withdraw on the live site, every defect fixed | ⏳ |
| 8 | Bank account verification and saved bank details for withdrawals | ✅ |
| 9 | Identity document upload in the site, review queue in admin | ✅ |
| 10 | Bet history filters, bet detail, downloadable statement | ☐ |
| 11 | Results page | ☐ |
| 12 | Home page: banners, featured matches, quick links, managed from admin | ☐ |
| 13 | Content pages managed from admin: help, FAQ, terms, privacy, responsible gambling, contact | ☐ |
| 14 | Session security: HttpOnly token handling, security headers and CSP enforced, server-side ownership on every customer route | ☐ |

## P1. One casino provider, done perfectly

| # | Item | Status |
|---|---|---|
| 15 | Pragmatic Play seamless-wallet adapter (D155): signed callbacks, IP allowlist, idempotency with original replies, stored-stake refunds, unseen-refund markers, provider error codes | ☐ |
| 16 | Provider simulator speaking the real Pragmatic format, plus free demo games for test runs | ☐ |
| 17 | Casino lobby: categories, search, favourites, recently played, demo play | ☐ |
| 18 | Admin: provider on/off, keys, allowlist, game catalogue, reconciliation | ☐ |

## P2. Sportsbook depth

| # | Item | Status |
|---|---|---|
| 19 | More sports: tennis, rugby, cricket, basketball; outrights | ☐ |
| 20 | In-play betting: live markets, bet delay, suspensions | ☐ |
| 21 | Today's coupon | ☐ |
| 22 | Booking codes and repeat bet | ☐ |
| 23 | Bet builder | ☐ |
| 24 | Accumulator and odds boosts | ☐ |
| 25 | Odds format switch (decimal and fractional) | ☐ |
| 26 | Trader tools: suspend, settle, manual results for every sport | ☐ |

## P3. Account and money extras

| # | Item | Status |
|---|---|---|
| 27 | Bonus wallet: bonus balance, wagering, free bets | ☐ |
| 28 | Promotions opt-in and admin promotion builder | ☐ |
| 29 | Cash vouchers: buy, redeem, print | ✅ |
| 30 | Refer-a-friend | ✅ |
| 31 | Airtime and data from the wallet | ✅ |
| 32 | Push and SMS notifications with regional routing; marketing preferences | ☐ |
| 33 | Device fingerprinting and fraud signals | ☐ |

## P4. Expansion products

| # | Item | Status |
|---|---|---|
| 34 | Horse racing: racecards, results, fixed odds | ☐ |
| 35 | Tote pools: win, place, swinger, exacta, trifecta, quartet, double, jackpot, Pick 6, place accumulator; banker, boxed, floating banker; dividends | ☐ |
| 36 | Lucky Numbers and lotto draws | ☐ |
| 37 | Live games (Betgames, TvBet) when contracted | ☐ |
| 38 | Virtual sports when contracted | ☐ |
| 39 | Further casino providers, each from the P1 template, when contracted | ☐ |
| 40 | Live streaming access | ☐ |
| 41 | Branch finder with map | ☐ |
| 42 | Site-wide search | ☐ |

## Later

| # | Item | Status |
|---|---|---|
| 43 | Risk system on the owner's Akka.NET architecture | paused |
| 44 | E10 operations hardening: status page, retention, load test, key rotation | ☐ |
