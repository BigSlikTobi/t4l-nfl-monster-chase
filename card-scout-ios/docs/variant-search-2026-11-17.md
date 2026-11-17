# Variant search

New CardSight scans fetch one raw-auction snapshot across variants:
`GET /v1/pricing/{card_id}?grade_id=null&period=90d&listing_type=auction&limit=500`.
Omitting `parallel_id` requests all variants. This contract was checked against
[the public schema](https://api.cardsight.ai/documentation/json) on 17 November 2026.

This is one pricing call after identification, not one call for recognition plus
pricing. The shared monthly quota stop still applies. The 500 most recent rows
are a capped snapshot, not proof of a complete variant catalog or price coverage.
Variants without accepted sales have no price. No pagination or per-variant
provider fan-out is triggered.

The worker validates the card context and raw auction filters, splits records by
parallel UUID, validates listing titles and serial tiers, and calculates a
separate median for each variant. Conflicting listing URLs are excluded. The
24-hour cache is shared across copies of the same provider card UUID. Confidence
comes from each photo's identification, not the shared price cache or sale price.

One unique High parallel suggestion is accepted automatically. Other suggestions
are ranked High, Medium, Low, unassessed and remain open for user confirmation.
An unclear parallel never inherits the base price. The picker appears in scan
matching and card details. It has variant-name search, separate available prices,
and “Check for ‘Refractor’ on your card.” when refractors are offered.

A choice queues a new job revision with `variantID` and `refreshOf`. The worker
accepts only choices from its own previous result/cache for identical uploaded
photos. It reuses identification and the same fresh price snapshot. A matching
existing checklist is preserved; otherwise one partial row is created. Owned-card
IDs, notes, personal prices and original photo files are retained. Old job results
cannot overwrite the new revision. Provider option prices stay transient and are
removed from persisted library data.

Verification: worker unit/integration checks, Swift revision/backward-decoding
checks, localization audit, isolated simulator build and photo regression,
synthetic picker layout inspection, and synthetic before/after collection and
original-photo preservation. No live paid-provider request, deployment or physical
iPhone installation was performed.


## Deployment — build 1.1 (49)

On 17 November 2026 the private VPS worker was updated and signed Release build
1.1 (49) was installed in place on MyApple (iPhone 17 Pro). Device inventory
confirmed build 49 and the app launched successfully. Its fresh connection
receipt reported `paired=true`, `connected=true`, `stage=reachable`, and
`trustStage=accepted`.

All 18 worker Python modules were verified against the release manifest. Five
changed modules were replaced: `server.py`, `card_lookup.py`, `cardsight.py`,
`linux.py`, and `setup.py`. Authenticated HTTPS health passed using the existing
certificate. Worker and Caddy remained active. Configuration, TLS files, catalogs,
provider quota and saved assessments stayed unchanged. The queue remained 140
analyzed, three identified and one cancelled. CardSight usage stayed at 718/720.
No live provider request or new physical-card scan was run for this deployment.

Private worker rollback copies and the SQLite backup are under
`/var/lib/cardscout/data/upgrade-backups/variants49-20261117T142930Z`.
Private phone snapshots are `/tmp/card-variant-deploy-before` and
`/tmp/card-variant-deploy-after`. The preservation script confirmed unchanged
108 cards and analyses, 60 collections, filters and 220 original photo files;
all 216 referenced photos remain present. The collection JSON was also
byte-for-byte unchanged immediately after installation and before launch.

Release verification passed 304 Python tests, 198 Swift tests (one existing
skip), the localization audit (851 bilingual keys), strict signature validation,
and the signed device build. The preceding isolated simulator build, picker
layout inspection and photo-loading regression passed. A new real-card scan and
physical use of the variant picker remain untested. This is a local device
installation, not a TestFlight or App Store release.
