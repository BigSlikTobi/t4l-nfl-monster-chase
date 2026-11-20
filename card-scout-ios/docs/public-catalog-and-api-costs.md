# Card Scout public catalog and API costs

Design proposal for a public iPhone release, 19 November 2026.

## What collectors get

Free scanning and collecting are the core product. Pricing is optional. The proposed first releases are 2026 Topps Flagship Football and 2025 Donruss Optic Football. Publish the supported release names in the app as each passes verification. A collector can still save a photo and enter an unsupported card manually.

| Offer to test | Proposed price | What the collector gets |
| --- | ---: | --- |
| Free | €0 | Unlimited scans and saves for supported releases. Three introductory price results per account. |
| Monthly pricing | €4.99 per month | Up to 100 new price results per billing month. Pick cards individually or submit a batch against the same allowance. |
| One-time batch pack | €7.99 | Up to 100 price results, with up to 100 selected collection cards per submission. Available without a subscription. Unused pack credits remain available for another batch. |

The prices, allowances, batch size and one-time introductory offer are pilot assumptions. The paid unit is one recent verified sold-price result for an exact edition in a given condition category. The initial worker supports raw pricing. A price result shows the sale date, currency, shipping basis if known, and evidence. Asking prices can appear separately. An unconfirmed finish, an ask-only result, missing sales or a technical failure costs the collector zero credits. All attempts still count against our internal work limits.

Before submitting a binder, show how many cards are eligible, which duplicates share a result, and the maximum credits needed. Use available introductory or monthly credits before purchased pack credits. Require an explicit purchase when more credits are needed. Reserve credits for the job and settle once per qualifying result. Retries resume the same job. A private receipt records usage without extending the retention of provider market data. Revisiting a fresh result on the same account is free. An explicit refresh after expiry can use another credit if it returns qualifying evidence. Reopening a collection never starts a paid refresh.

## Where the money goes today

The iPhone already reads text from the photos. In the worker’s direct recognition path, the first lookup uses a hash of the front image. The identical file can hit that cache. A new photo of another copy normally misses it. The worker can then call CardSight, ask OpenAI to resolve an identity or finish, and start pricing in the background. Price snapshots already reuse a card UUID for 24 hours. Collection refresh can batch up to 100 distinct card IDs. [iPhone OCR](../App/FastScanView.swift) · [Card lookup](../mac/card_lookup.py) · [Worker](../mac/server.py)

The checked-in CardSight ledger reserves each request before sending it. Both its daily and monthly limits are 5,000, so one busy day can consume the month. It coordinates processes sharing one data directory. OpenAI Decisions has a separate concurrency limit. That limit controls simultaneous requests and leaves total spend open. The current worker uses one private pairing credential. A public service needs quotas and job ownership per account. [CardSight ledger](../mac/cardsight.py) · [Decisions client](../mac/listing_decisions.py) · [Worker authentication](../mac/server.py)

An earlier cold-cache run on 20 saved scans used 58 CardSight calls and 269 Decisions calls. Repeating the same inputs while warm used zero external calls. Later offline work reduced listing Decisions calls from 912 to 188 for 89 fixed identities. Neither sample measures what new collectors with different photos will cost. [20-card run](quality-and-parallel-requests-2026-11-17.md) · [Replay](card-validation-optimization-2026-11-17.md)

## What we can keep

| Store | Contents | Sharing and retention |
| --- | --- | --- |
| Our football catalog | Stable internal IDs for releases, checklist entries and exact editions. Each fact has a source, revision, review status and reuse rights. | Publish reviewed data cleared for commercial use. Distribute versioned release packs to phones. |
| Collector’s library | Existing physical card ID, optional catalog edition ID, original photos, printed serial such as 17/99, condition, notes and personal price. | Private to the collector. Linking a catalog entry preserves the existing record and photos. |
| Provider cache | Limited recent lookup results. Market evidence keeps edition, grading company and grade or raw condition, source, sale date, currency and shipping basis. | Share eligible app results within the source terms. Use expiry, purge and a short cooldown for misses. Keep sales, asks, guides and estimates distinct. |

CardSight permits limited temporary app caching. Its standard terms prohibit building an independent database from its results and require deletion of cached data at the end of the agreement. This also matters for results copied into device storage, backups or exports. The existing 24-hour setting is our implementation choice. A durable market history would need a source with retention rights, such as a licensed sales feed. [CardSight terms, sections 3(b) and 3(c)](https://cardsight.ai/terms)

For our catalog, start with a release checklist, record its version and establish reuse rights for the intended fields and distribution. Treat artwork as a separate permission. Stage changes for review. A checklist row, an applicable parallel and a verified reference photo are separate claims. Collector corrections can flag gaps for review. Keep provider-only matches in the provider flow until independent evidence supports a catalog entry. Topps publishes football checklists and Panini documents its checklist downloads. The repo already has import and review tooling. [Topps checklists](https://www.topps.com/pages/checklists) · [Panini checklist guide](https://assets.paniniamerica.net/resources/Whitepaper_Checklist.pdf) · [Existing catalog workflow](context-catalog-strategy.md)

## Public scan and price flow

1. Save the scan immediately. Use the existing on-device text recognition and a local SQLite index for downloaded releases. Query our server index for other covered releases. Search by printed name, card number, year, release and subset. Compare finish, variation and serial evidence separately. Similar images can rank candidates. A weak finish stays open.
2. Link a verified match to the collector’s copy. If the evidence leaves two finishes, show the choices and allow manual entry or saving an unresolved card. Keep paid-provider calls out of the free scan path. Launching this offer requires removing the private worker’s automatic recognition and background pricing from that path.
3. Serve collection browsing from local data. Fetch market evidence on explicit demand or a separately budgeted refresh. On a price miss, one worker obtains a short-lived job lease. Other requests for the same lookup share its result. Reuse a compatible multi-variant provider response, then validate each selected edition and grade separately. Batch compatible misses. Cache a successful check with no qualifying sales briefly. Give provider errors their own retry cooldown.
4. Before each paid call, reserve the worst-case allowed cost in a shared transactional ledger. Use per-account allowances, per-scan limits, daily and monthly global limits, and separate budgets for CardSight calls and AI spend. Reconcile actual usage and retain the reservation when billing is uncertain. A timeout, retry or second worker must respect the same ceiling. Keep keys server-side and check the account owns every private job.

One Postgres database can initially hold the catalog, source records, cache entries, leased jobs and budget reservations. The phone packs contain only independently sourced, cleared catalog data. Content hashes let phones download just the changed releases.

## What the budget buys

With 1,000 collectors scanning 30 cards each, the proposed scan path makes zero paid recognition or pricing calls across 30,000 scans. Free catalog delivery still costs us money. If all 1,000 are new and redeem their three introductory prices, we owe up to 3,000 successful results. The number of paid attempts can be higher when market coverage is weak. Give the introductory offer a separate acquisition budget and limit new trials before making promises we cannot fund. Protect capacity for paid allowances. Rate-limit distinct misses per account and across the service, even when they consume no customer credit.

Calculate each offer at full redemption. Take the net proceeds for its App Store storefront, reserve the desired contribution margin, and divide the remaining cost budget by the included results. For example, if our net proceeds are €3.50 for the subscription and €5.60 for the pack, a 60% target contribution margin leaves €1.40 and €2.24 respectively for variable costs. At 100 results that gives us **1.40 cents per subscription result** and **2.24 cents per pack result**. These net proceeds and the margin are assumptions. Use actual App Store proceeds after taxes and commission before setting the rate. [Apple proceeds](https://developer.apple.com/help/app-store-connect/getting-paid/view-payments-and-proceeds)

For the pilot, divide **all variable spend** by successful billable results. Include paid misses, AI listing checks, provider calls, attributable infrastructure, and the per-use portion of any data license. Track fixed catalog licensing, review and the free tier separately to check whether total contribution covers them. CardSight lists 5,000 calls for $14.95 per month on Pro. One bulk request can price up to 100 card IDs. Listing validation, variant checks, and unsuccessful searches still have costs. [CardSight pricing](https://cardsight.ai/pricing) · [Bulk price lookup](https://cardsight.ai/solutions/price-data)

### Using a 1,500-request pricing budget

If all 1,500 requests are full pricing batches, they can check 150,000 distinct, already-known CardSight IDs once. Singles, smaller batches, repeat checks and ID discovery reduce unique coverage if they draw from that budget. Raw (ungraded) prices still need accepted sales for the exact finish. One historical 41-card run found exact sales for 19. [Bulk endpoint](https://cardsight.ai/solutions/price-data) · [41-card run](pricing-request-optimization-2026-11-17.md)

Use the 1,500 as a ceiling for collector demand. Display a fresh shared price beside the exact card. When a collector requests one missing raw price and we know the provider ID, fetch just that ID. For a binder, queue only the distinct missing IDs in batches of up to 100. If 80 of 100 requested raw cards have fresh results and the other 20 have known IDs, a single bulk price request covers those 20. Work to validate the resulting sales has a separate AI budget. Expired or absent results trigger a new check only when requested.

Filling 150,000 rows in advance and keeping the resulting prices would require a license expressly covering bulk acquisition, retention and paid in-app display. A table that stores only our computed median beside each card still relies on the provider’s data. With the standard terms, keep the permanent catalog independent and use the shared, expiring results above. Track cache hits, distinct IDs per batch and the share with exact sold evidence to see how far 1,500 calls go for our actual collectors. [CardSight terms, sections 3(b) and 3(c)](https://cardsight.ai/terms)

## First rollout

Start with **2026 Topps Flagship Football**. The checked-in catalog coverage report lists 713 candidate rows for this release. Across the report it lists zero reviewed families and zero variants with reviewed rules. Verify one checklist and its troublesome finishes before expanding to Donruss Optic. Rank later releases by unresolved demand and available rights. Track college, vintage and unlicensed issues separately from modern NFL releases. [Catalog coverage snapshot](context-catalog-coverage.json)

Before a public launch, exercise the normal iPhone scan flow with fresh photos from different collectors and different physical copies. Include base, foil, numbered parallels, ambiguous cards and unsupported sets. Compare blind labels to the local matches. Report local exact-match rate, wrong automatic matches, unresolved finishes, price coverage and paid cost per 100 scans. Report cold, warm and previously unseen releases separately.

Test simultaneous price requests from multiple accounts, retries after a worker restart, access to another account’s private job, provider expiry and a fully exhausted budget. A free scan and a fresh cached price should use zero paid calls. Simultaneous identical price misses should trigger one upstream fetch. Check that retries never double-charge and that an all-miss batch releases every reserved credit. Run representative 100-card binders, including low-value base cards, and compare bulk price coverage to individual lookup on the same cards. Measure exact-sale coverage, total cost per successful result, and full-batch turnaround before choosing the published prices and allowances.
