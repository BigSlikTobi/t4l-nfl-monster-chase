# Direct card lookup — step one

Variant selection and the shared all-variant snapshot now extend this route.
See [variant search](variant-search-2026-11-17.md) for the current pricing request.

New scans use one provider for recognition and pricing:

1. The phone saves its originals and uploads through the existing paired HTTPS worker.
2. The worker sends only the front image as binary JPEG/PNG to
   `POST https://api.cardsight.ai/v1/identify/card/football`.
3. An exact, high-confidence identification supplies the provider card UUID. A
   unique high-confidence parallel suggestion supplies its separate parallel UUID.
   Ambiguous variants and set-only matches stay open; they do not receive base prices.
4. Look up the private all-variant price cache by card UUID + raw.
5. On a cache miss call `GET /v1/pricing/{card_id}` with `grade_id=null`, `period=90d`, `listing_type=auction`, `limit=500`.
   Omit `parallel_id` and split returned sales into separate variant medians.
6. Validate card/set context, echoed filters, titles, dates, variants and sale URLs.
   Discard asks, graded/lot/damaged listings, conflicting variants and duplicate links.
7. Store accepted USD sale evidence, date and median in the worker cache. Display the
   median through the app's existing raw-sales summary. Missing sales stay unknown.

Normal cold path: two CardSight requests. Another photo of the same card needs one
identification request and reuses the fresh price cache. Reusing identical front
bytes also reuses the identification cache. Accepting the matching scan does not
create a second assessment job. Refreshes with an existing server-owned identity
fetch prices directly by UUID and need no new image identification.

There are no Luna, Decisions, guide-site, title-search or recommendation calls in
this route. Condition and action panels are omitted because this route does not
assess damage or choose Keep/Sell/Grade/Bulk. Slab detections retain metadata but
do not receive a raw-card price. Graded pricing is outside step one.

## Local reuse and preservation

`card-lookup-cache/` contains private JSON records with a 24-hour lifetime,
including unsuccessful price checks. Reopening a screen does not repeat a failed
provider lookup. Expired evidence is not shown as current. Provider identity is
stored separately from the physical owned-card ID. No IDs or original photos are
replaced. Old analyses still decode without the optional provider fields.

Existing source-backed checklist rows and names are reused when they match.
Otherwise an exact identification contributes one explicitly partial provider
collection row. It is not a complete checklist. Known rows are merged rather
than overwritten. NFL/college licensing remains unknown unless the existing
independent local release evidence establishes it; provider recognition does not
invent licensing, serial inscriptions, population counts or condition grades.

The shared CardSight quota ledger and 5,000-call Pro stop apply to both new
endpoints. Keys remain on the worker. No API credentials are added to the phone.
The old workflow remains available for rollback and existing saved analyses.

The collection-wide rerun can defer individual price requests until recognition
finishes, then request up to 100 distinct UUIDs per bulk call, with 50 recent raw
auction records per card. It uses the same per-card and per-variant validators.
See [Pro rerun results](pro-regrade-2026-11-17.md).

## Activation

When `cardSightResearchEnabled` is true, new jobs use direct identification by
default. `cardSightIdentifyEnabled: true` explicitly enables it;
`cardSightIdentifyEnabled: false` explicitly retains the earlier identification
route. Restart the worker after updating its modules/config. Mac and Linux
installers include `card_lookup.py`. This source change does not deploy a worker
or install the updated iPhone app.

API contracts checked against the production OpenAPI schema on 17 November 2026:
[CardSight API documentation](https://api.cardsight.ai/documentation),
[OpenAPI schema](https://api.cardsight.ai/documentation/json).

Step two, independent local metadata recognition, is intentionally not implemented.

## Verification

299 Python tests passed. Swift: 197 tests, one existing skip, zero failures.
Localization, whitespace and shared-image source audits passed. The isolated
simulator photo regression passed. A separate synthetic card-detail preview
built and showed a $1 median for $1/$1/$1/$8, with no condition or action panel.
The preservation script confirmed unchanged synthetic cards/analyses, collections
and three original photo files across disk save/load. These were the initial
local implementation checks; deployment followed separately below.

## Deployment — build 1.1 (48)

The private Linux worker now runs the updated `server.py`, `cardsight.py` and
new `card_lookup.py`. All three deployed SHA-256 hashes matched the checkout at that deployment.
The remaining pricing/batch/guide/analysis dependencies already matched and were
not replaced. `cardSightIdentifyEnabled` is explicitly true. The service and
Caddy are active; authenticated HTTPS health passed with certificate verification.
Configuration other than that flag, the TLS identity, catalogs and the digest of
saved job assessments remained unchanged. Queue counts remained 140 analyzed,
three identified scan drafts and one cancelled. Quota remained 718/720; health
checks did not spend provider calls.

Private rollback files and a SQLite backup are under
`/var/lib/cardscout/data/upgrade-backups/direct-lookup48-20261117T141158Z`.

Signed Release build 1.1 (48) passed strict signature verification and installed
in place on MyApple (iPhone 17 Pro). Fresh device inventory confirms build 48.
The real before/after preservation script passed: all 108 cards and analyses,
60 collections, filters and 220 original photo files stayed unchanged; all
216 referenced photos remain present. Private local snapshots are under
`/tmp/card-lookup-deploy-before` and `/tmp/card-lookup-deploy-after`.

The first post-install file read lost its device connection; its retry and the
full photo comparison succeeded. Automatic app launch was denied because the
iPhone was locked. Launch, updated phone-to-worker connection and a new physical
card scan still need separate confirmation.
