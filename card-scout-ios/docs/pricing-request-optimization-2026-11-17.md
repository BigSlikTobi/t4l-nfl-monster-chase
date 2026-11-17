# Catalog and pricing request optimization — 17 November 2026

Large owned-card batches now resolve compatible product families through bounded
catalog pages. The first exact requested card establishes the release and set IDs.
Seed variations are filtered by the same identity rules as individual discovery.
Only batches with at least eight compatible queries use this path. It reads at
most half the group's query count in pages, capped at 20, plus the seed lookup.
Small groups and insufficient budgets keep targeted discovery.

Every page must have consistent counts and exact release/year/set context.
Pagination retains complete equal-name groups across unstable offset ties. Missing,
duplicate or inconsistent rows cause targeted fallback; partial pages cannot prove
absence or uniqueness. A query shared by two different owned families cannot be
scoped to one. No provider catalog is saved: only requested matches survive in
batch memory, and unrelated rows are discarded. Existing evidence expiry remains.

Collection pricing requests now ask for 50 auction records per card rather than
25 using POST /v1/pricing/. Exact player, number, family, finish, serial, raw-grade,
source and sale-date checks remain. Accepted references are still capped at 25 per
card and mark limited samples. The wider bucket can avoid a fallback when an
acceptable sale follows the first 25 rejected candidates. Ranking requests remain
unchanged. Individual fallback searches still use GET /v1/pricing/search, limit 25.

## Tested and rejected approach

A first live candidate bounded families at eight pages and tried a shared
500-listing fallback search. The real Base Set has 1,400 provider rows, so the
catalog guard correctly fell back to individual discovery. The broad pool
replaced none of this batch's targeted searches. An additional bounded OR probe
also found no usable exact-card evidence. The shared-search path and 500-limit
client allowance were removed; that experiment is not part of the shipped code.
The catalog bound and tests were corrected to cover the actual family size.

## Verification

282 Python tests passed, including 1,400-row families, equal-name page boundaries,
seed variations, partial/duplicate/wrong-release pages, conflicting family queries,
exact-sale discovery after row 25, retained matching filters and reference limits.
Swift: 192 tests, one skipped, zero failures. Localization and diff checks passed.
An isolated 41-card/1,400-row-family test used 20 provider requests, with all cards
priced; this is synthetic validation, not the live market coverage result.

The final three deployed modules were card_price_batch.py, card_prices.py and
cardsight.py. Their live hashes matched local files. Private rollback copies:
`/var/lib/cardscout/data/upgrade-backups/pricing-optimization-20261117T131431Z`.

## Final live comparison on the same 41 eligible cards

| Request type | Previous batch | Final optimized batch |
| --- | ---: | ---: |
| Card catalog | 39 | 19 |
| Set/parallel metadata | 6 | 1 |
| Bulk pricing | 2 | 2 |
| Individual title search | 21 | 21 |
| Total external requests | 68 | 43 |

Twenty requests were saved by grouped catalog resolution. Five more were saved
because metadata was already warm. The account-check request was served by the
hourly cache and did not add a network request. Immediate provider usage snapshots
lagged the completed work; they must not be confused with the batch's 43 actual
request reservations. The live counter stayed within the existing 720 stop.

There were zero exact-price coverage regressions: 19 cards retained exact sales,
two retained guide estimates, six had variant mismatches, two had catalog
mismatches, and 12 had no accepted exact sale. The 50-record window did not reduce
the 21 fallback searches for this particular batch. It adds no extra price call.
No claim is made that every scan, small batch, or future source response saves the
same number of requests.

Private per-card audit:
`/var/lib/cardscout/data/price-audits/flagship-optimization-20261117T131504Z.json`.
Prior price views were backed up before re-fetching under
`/var/lib/cardscout/data/price-retry-backups/optimization-20261117T131504Z`.
Saved assessment digest remained
`419da6c6f11227707b536e78ab936c39acd8bfbf6d6edff6d10aea7d511ed878`.
Authenticated app API coverage and service health were checked separately. No app
reinstall, photo migration, private-data publication or budget increase occurred.
