# Pro cap and saved-front rerun

The user authorized raising the shared CardSight stop from 720 to 5,000 and
reprocessing every saved front photo. No subscription purchase or call pack was
made. Provider errors, the locked quota ledger and pre-transport reservations
remain enforced. Previous usage counters were retained.

The installed build 1.1 (49) queued 105 completed cards through the existing
idempotent saved-photo maintenance action. Three existing scan drafts were
requeued through the authenticated retry API. All 108 front images were sent
to CardSight; backs were not sent to the provider. Capture originals were reused.

The first credential became inactive: CardSight returned HTTP 403 with
`AUTHENTICATION_ERROR`. The provider halt stopped subsequent analysis requests.
The user supplied a replacement through a one-use loopback password form.
Subscription validation returned HTTP 200 before activation. The old credential
was backed up privately; the validated key replaced it on the VPS and Mac.
Staged key copies were removed. No key, token or pairing value was printed.

The 17 provider-blocked jobs were retried. The user also requested fresh retries
of both identity conflicts; only those two identification-cache entries were
bypassed. Their explicit manual assignments were retained when the new provider
results still disagreed.

## Results

| Outcome | Physical cards |
| --- | ---: |
| Saved fronts included | 108 |
| Completed analyses | 106 |
| Remaining manual identity conflicts | 2 |
| Price for the currently identified variant | 25 |
| Other/uncertain variant prices only | 15 |
| No accepted price among completed analyses | 66 |

The 40 cards with at least one variant price include the 25 with a price for
their identified variant. These counts must not be added to claim 65 priced
cards. Missing prices are unknown, not zero. The collection is not fully valued.
Of the 106 completed results, 80 identities are confirmed and 26 need identity
or variant review. These are provider recognition and pricing results, not
condition grades or grading-profit recommendations.

Bulk pricing covered 89 distinct eligible card UUIDs in one request. An audit
then exposed optional omitted `parallel_id` fields on base sales. The parser now
treats omission like null while retaining the strict title, parallel-name and
serial checks. A numbered or explicitly named parallel cannot enter base prices.
Price-cache parser version 2 invalidated earlier price views without repeating
identification. One new bulk request rebuilt the prices; an individual full
snapshot was used for the audit. Each variant keeps its own median.

Normal pricing scheduling was restored after the batch. The worker and Caddy
are active. The final replacement-key subscription check returned HTTP 200,
27 provider calls used, and the six-request-per-second rate header. The local
ledger is deliberately conservative and also retains attempts from the prior key.
Private per-card results are under
`/var/lib/cardscout/data/batch-runs/pro-regrade-20261117/report.json`.

## Preservation and checks

310 worker tests passed. Swift: 198 tests, one existing skip, zero failures.
Localization passed with 851 bilingual keys; whitespace checks passed.
No iPhone rebuild was needed for the backend cap/batch changes.

The phone received 106 completed analyses and two conflict results. The before
and after check retained all 108 physical card IDs, front/back references, notes,
locations, personal prices, favorite/Collectible flags, draft roles and purchases.
All original binder IDs remained present. The 220 original photo files matched
their pre-rerun SHA-256 hashes. Analyses and collection assignments were allowed
to change where the new identification was accepted. Private local snapshots
are under `/tmp/card-pro-regrade-before`, `/tmp/card-pro-regrade-after` and
`/tmp/card-pro-regrade-final`.

The app was relaunched to load the price caches. Phone-side price delivery and
physical screen acceptance are separate from the server coverage counts above.
