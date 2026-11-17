# Quality checks and parallel requests

Current source; not deployed. Extends the direct CardSight confidence route.

## Changes

- Fetch available parallels from the exact card endpoint. Validate card, set,
  release, number, subject, year and complete parallel count. The release's 430
  entries no longer encounter our old 400-entry rejection. Partial parallels
  still need applicability evidence. Cache only relevant card metadata for 24 hours.
- Parse OCR identity fields separately from biographies. Printing codes are not
  card numbers; biography dates are not serial numbers; copyright year is not
  necessarily the sports season. Read card numbers after side labels such as
  `Rückseite:`. Explicit release-year/number conflicts and paper/Chrome conflicts
  still escalate instead of accepting a contradictory high-confidence result.
- Recover an omitted candidate through a bounded exact-number lookup within the
  provider release. Validate all returned contexts. Never invent a UUID or use
  an existing owned-card analysis as recognition evidence.
- Keep a resolved card when only parallel metadata fails. Unconfirmed finishes
  remain unpriced. Use an already-saved back image as additional evidence when
  escalation needs it; do not require an operator to choose a result.
- Run independent pricing-variant checks with four threads. Identity/listing
  Decisions share a bounded semaphore of four in-flight requests per process.
  Provider fetches and cache writes retain their existing serialization. This
  is request concurrency, not additional simultaneous collection mutations.
- Preserve stable row IDs, provider prices, variant/grade boundaries and separate
  sold/ask medians. Listing matches below 0.75 probability or a 0.20 lead become
  unclear. These routing defaults are not calibrated accuracy guarantees.
- Version identity, price and Decisions caches so prior-policy results are not
  silently reused. No new keys, purchases, automatic paid retries or changes to
  the shared 5,000-call CardSight protection.

## Final 20-card benchmark

Same app snapshots/photos/OCR as the initial baseline, empty test cache, fresh
live requests, no manual candidate/parallel corrections. Source stayed frozen
during each run. Intermediate runs remain in private local artifacts.

| Measure | Initial | Final |
| --- | ---: | ---: |
| Resolved identity and parallel | 8/20 | 19/20 |
| Cards with sold or asking evidence | 8/20 | 17/20 |
| High-confidence card fast path | 0/20 | 18/20 |
| Cold priced-card median | 11.34 s | 5.18 s |
| Slowest priced card | 16.21 s | 8.09 s |
| Total sequential run | 120.68 s | 102.75 s |
| CardSight / Decisions calls | 43 / 160 | 58 / 269 |
| Peak in-flight Decisions | 1 | 4 |

The final run does more work: 19 resolved cards instead of eight. Higher total
call counts do not imply higher per-card waiting time. All warm repeats used
zero external calls. Camera, phone upload, queue polling and UI rendering are
outside these worker measurements.

An independent deterministic audit joined 1,177 accepted references back to
provider rows and verified original amounts, raw grade, parallel ID and sold/ask
classification. All 20 outputs decoded through actual Swift Core models with
matching medians. Input photo and source hashes were unchanged. This validates
evidence handling and calculations, not every seller description or chosen finish.

Alex Perry's card UUID was recovered from the incorrect Donte Lee candidate,
but its finish remained unclear and unpriced. Two resolved cards returned zero
raw market records. Saved labels for three other parallels disagree with current
results and are not independently verified ground truth. A 19/20 resolution rate
must not be presented as a 95% exact-identity accuracy result.

Private final [results and logs](/tmp/card-benchmark-20-v4/report.html),
[written report](/tmp/card-benchmark-20-v4/report.md) and
[request events](/tmp/card-benchmark-20-v4/requests.jsonl) remain outside Git.
Collection data, deployed worker modules and the iPhone app were not changed.

## Checks

345 worker tests passed. Swift Core: 205 tests, one existing skip, zero failures.
Localization passed for 859 bilingual keys and 99 templates. Python compilation,
installer shell syntax and whitespace checks passed. New cases
cover real-field OCR, biography dates, season/copyright distinctions, exact-number
candidate recovery, wrong card metadata, retained identity and bounded concurrency.
No app UI/photo-loading source changed.
