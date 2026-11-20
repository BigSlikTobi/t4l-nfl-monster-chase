# Listing decisions and separate prices

This change applies to the direct CardSight card lookup. It does not identify
the card again, assess condition, or change an owned card's ID.

## Request path

1. Reuse the identified card UUID and selected parallel UUID.
2. Reuse a fresh private price snapshot, or fetch recent raw listings with
   `period=90d`, `grade_id=null`, and `listing_type=both`. Single requests allow
   500 rows; collection batches allow 100 card UUIDs with 50 rows per card.
3. Validate provider context, structured variant/grade fields, dates, amounts,
   currencies, source URLs, and duplicate records in code.
4. Send the target attributes and listing JSON to `POST /v1/decisions` with
   `gpt-6-luna`. Each listing gets a stable question ID and the choices `match`,
   `different`, or `unclear`. No card photos or image downloads are needed.
5. Include accepted matches only. Code reads the original provider amounts;
   Decisions cannot supply prices or alter card IDs. Failed or invalid Decisions
   responses do not fall back to the old keyword matcher.
6. Keep completed auctions (`sold`) and fixed-price listings (`ask`) separate.
   Compute a median independently for each group and variant. Cache the results
   for 24 hours. An unavailable group stays unknown.

Seller titles are evidence, never instructions. Generic words such as "foil" or
"parallel" no longer reject a listing by themselves. Conflicting variants,
autographs, serial denominators, graded cards and lots still require exclusion.
Missing evidence can produce `unclear`; this is not an accuracy guarantee.

## App presentation

The card market panel shows **Sold for** and **Listed at**, each with its own
median and count. German uses **Verkauft für** and **Angeboten für**. The layout
stacks when there is not enough room for both columns. Source references retain
their sale or listing label, currency, date and shipping basis.

`marketSummary` and `CardSightVariant.medianCents` retain their sold meaning.
The optional asking summary and `askingMedianCents` are separate. Asking prices
do not flow into collection totals, price history, sorting, Burn Count or a
personal price. Old saved analyses decode without the new optional fields.
Provider price evidence remains transient on the phone; original photos and
saved collection data are preserved.

## Limits and activation

The worker needs its existing configured OpenAI API access for Decisions.
CardSight's shared 5,000-call protection remains in place. Keys stay on the
worker. No new key is created or written by this change.

The source must be installed on the worker and the app rebuilt to activate it.
There is no automatic collection-wide regrade or deployment in this change.
Live matching accuracy and physical iPhone acceptance need separate checks.

Contract reference: [OpenAI Decisions guide](https://developers.openai.com/api/docs/guides/decisions).

## Verification

- Worker suite: 323 tests passed, including real local HTTP fixtures.
- Core suite: 205 tests, one existing skip, zero failures.
- Localization: 859 bilingual keys and 99 dynamic templates passed.
- Isolated simulator build and shared-photo regression passed.
- Visual preview: $1 median from four sales and $7 median from three listings
  appeared in separate columns. An asking-only fixture kept sold unknown, and
  accessibility text switched to the stacked layout.
- Synthetic disk comparison preserved two cards/analyses, two collections and
  three original photo files. Additional tests cover separate medians, ask-only
  portfolio exclusion, expiry, old JSON decoding and personal-price preservation.
- Whitespace audit passed.

Decisions responses were mocked in these checks. No live matching accuracy,
worker deployment, physical iPhone install or collection-wide rerun is claimed.
