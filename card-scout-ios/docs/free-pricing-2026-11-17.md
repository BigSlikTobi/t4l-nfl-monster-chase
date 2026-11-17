# Free-plan Flagship pricing — 17 November 2026

Both `Topps Flagship` and `Topps Flagship Football` now use one explicit Topps
2026 release alias for CardSight and free guides. Saved identities remain intact.
Midpoint release-name validation accepts both verified spellings. Its published
2026 Flagship base-set page is now a bounded fallback when the ten-result search
misses an exact card. Details still require matching release, player, number,
finish and any serial tier. No fuzzy price matching or graded-to-raw conversion.

Guide version 4 allows previous negative price views to gain a free guide without
repeating CardSight research. Existing guide-first lookup and 24-hour evidence
expiry remain. Guide values are labelled estimates, not verified individual sales.

CardSight account-usage checks now reuse a sanitized one-hour timestamp in the
shared locked usage ledger. This removes repeated subscription requests across
cards and worker clients within that hour. Every actual request is still reserved
before transport. Monthly/daily caps and provider-error halts run before cache
reuse. Monthly ledger rollover also discards the timestamp. No credential-bearing
subscription response is cached. The 720-call stop is unchanged; no paid plan,
quota reset or extra account was introduced.

## Sources checked

- Midpoint's public Flagship set page and structured card detail returned usable
  exact raw guides: https://www.cardcenteringtool.com/sets/football/2026-topps-flagship
- A direct public SportsCardsPro request returned HTTP 403; no bypass or adapter
  was added: https://www.sportscardspro.com/console/football-cards-2026-topps-flagship
- Existing Slabline fallback remains bounded and subject to exact raw-guide checks.

## Verification and rollout

259 Python worker tests passed. Swift: 192 tests, one skipped, zero failures.
Localization and diff-whitespace checks passed. Tests cover both product spellings,
wrong products/variants, release-page fallback, guide retrieval at the CardSight
cap, unchanged identities and quota counters, and cross-client account-check reuse.

Only `raw_guides.py`, `cardsight.py`, and `card_prices.py` were deployed. All three
live hashes match local files. Private rollback copies are under
`/var/lib/cardscout/data/upgrade-backups/free-guides-20261117T111106Z`.
Authenticated HTTPS ping returned 200. Card Scout and Caddy remain active.

The completed, eligible Flagship scans were refreshed through the existing price
API in batches of eight: 41 cards checked, two exact Midpoint raw guides available,
39 without an acceptable exact guide and still blocked from CardSight by quota.
The separate identified-stage scan was not reanalyzed. CardSight usage stayed at
720 before and after the batch. These are server results, not iPhone display proof.
The saved assessment digest stayed unchanged:
`419da6c6f11227707b536e78ab936c39acd8bfbf6d6edff6d10aea7d511ed878`.
