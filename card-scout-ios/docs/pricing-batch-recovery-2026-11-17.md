# Pricing batch recovery — 17 November 2026

Collection pricing now coalesces queued owned-card requests and sends compatible
CardSight pricing buckets together, up to the API's limit of 100 card IDs.
Each card still passes the existing identity, set, filter, variant, serial, grade,
sale-title and date validators. Partial item failures affect their own card;
missing, duplicate or unexpected bulk IDs invalidate the affected bulk response.
No bulk response becomes an independently stored provider catalog.

The planner keeps request responses only for its bounded in-memory batch and
replays existing per-card validation after each shared response arrives. Catalog
lookups shared by base/parallel copies and free-guide attempts are reused within
the batch. Only cards still missing accepted evidence enter the year fallback or
additional title search. Individual catalog discovery and title search still cost
calls; this change does not claim one API call for an entire collection refresh.
`last_batch_stats` request counters describe request attempts, including requests
that the shared client may satisfy from its account-check cache or reject at quota.
Use transport counters in tests and the live quota ledger to measure API usage.

New scans queue pricing separately, allowing the analysis worker to proceed.
Market rankings wait before new provider requests while owned-card prices are
pending. Near the cap, the planner prices already-resolved cards before spending
its last calls on further discovery. The existing 720/month stop is unchanged.
There is no paid subscription, quota reset, new account or credential migration.
Both Mac and Linux install bundles include the new dependency.

## Checks

272 Python tests passed. Swift: 192 tests, one skipped, zero failures.
Localization and whitespace checks passed. The copied Linux install bundle starts.
New tests cover bulk routing, base/parallel separation, general-bucket reuse,
wrong context/finish rejection, partial and malformed bulk results, year fallback,
queue coalescing/recovery, tight budgets, ranking priority and read-only audits.

A synthetic 41-base-card transport test made 45 actual transport requests:
41 catalog lookups, one account check, two metadata calls and one bulk price call.
The equivalent previous flow with a warm hourly account check and shared metadata
needs 85: the same 44 discovery/account/metadata calls plus 41 pricing calls.
This is 40 fewer requests in that controlled scenario, not measured live coverage.
Parallel groups and cards needing fallback have different costs.

## Live rollout and actual acceptance limit

The runtime modules deployed were `card_prices.py`, `cardsight.py`, `server.py`,
`card_price_batch.py`, and `price_audit.py`. Their hashes matched local files.
Private rollback copies:
`/var/lib/cardscout/data/upgrade-backups/batch-pricing-20261117T122539Z`.
The first deployment import check had a shell-quoting error and automatically
restored the previous modules; the corrected script and import check passed.
Authenticated HTTPS ping returned 200. Card Scout and Caddy remain active.

`price_audit.py` reads SQLite and transient evidence without provider calls or
queue initialization. Its per-card report is private, mode 0600:
`/var/lib/cardscout/data/price-audits/flagship-batch-20261117.json`.

The live audit found 42 completed Flagship scans: 41 eligible and one needing
identity review. Of the 41 eligible cards, two have raw guide estimates and 39
are blocked by the existing CardSight quota. Those 39 are not proven no-sale or
catalog-mismatch results. Calling the installed batch path on these saved cards
reused the views and made zero external requests. The ledger stayed at 720.

Fresh CardSight coverage remains unverified. No budget guard was bypassed to
manufacture a passing acceptance result. Once quota is available, the live batch
must measure fresh exact sales, guides, catalog/variant mismatches, no-sale results,
provider errors, and actual ledger calls consumed before claiming useful coverage.

Saved results retained their SHA-256 digest:
`419da6c6f11227707b536e78ab936c39acd8bfbf6d6edff6d10aea7d511ed878`.
No app reinstall or photo/collection migration occurred. Server evidence is not
physical-iPhone delivery or user acceptance proof.

## Live retry after account clarification and plan upgrade

The user confirmed upgrading the account belonging to the existing deployed key.
The Mac and VPS still had that same key; no account or credential was switched.
A direct authenticated usage check reported 443 provider calls while the local
ledger said 720. Therefore the earlier local stop did not establish exhaustion
of the provider allowance. The initial quota-exhaustion conclusion was incorrect.

The old ledger and 39 quota-failure views were privately backed up under
`/var/lib/cardscout/data/price-retry-backups/20261117T125102Z`.
The ledger was reconciled to a conservative 444 from the provider's 443;
the existing 720 stop stayed in force. Only quota-failure cooldowns were cleared.
The operator batch used the production `lookup_many` path and a separate
150-request-attempt bound. Existing guide references were preserved.

Fresh result for the 41 eligible Flagship cards:

- 19 with exact sold evidence: 40 CardSight sale references.
- Two with exact raw guide estimates from Midpoint.
- Six without an exact catalog variant match.
- Two without an exact catalog card match.
- Twelve with sale candidates but no accepted exact raw sale.

The batch used 39 card-catalog requests, one set request, five parallel requests,
two bulk pricing requests and 21 title searches: 68 actual provider requests.
The account check was served from the reconciled hourly cache. A final direct
provider check reported 511 calls, up from 443, independently confirming the 68.
The conservative local ledger ended at 513 including diagnostic reservations.

Authenticated app API reads independently returned the same 19 exact-sale cards,
two guide cards and 20 without exact references; HTTPS health was 200.
Saved assessments retained the digest above. No iPhone display check was performed.
The private per-card audit is
`/var/lib/cardscout/data/price-audits/flagship-retry-20261117T125102Z.json`.
