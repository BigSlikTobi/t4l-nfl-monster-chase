# Card validation optimization

## CardSight finish routing (worker version 7)

After card identification, an empty finish suggestion list defaults to the standard finish if the card catalog and any printed serial allow it. When the worker corrects the card ID, it uses suggestions attached to the selected ID only. A single compatible High variant goes straight to pricing. If only weak suggestions remain, or two High suggestions compete, one Decisions request compares the photos with the eligible suggested IDs and base when allowed. Missing or contradictory options leave the finish open. The worker records the route in the job trace. Version 7 invalidates older photo decisions while preserving the separate recognition and catalog caches.

In an offline replay of 108 saved scans, 94 defaulted to base (17 after a card correction), four accepted a High variant, five needed a new finish answer, one had incompatible finish evidence, and four stopped at card identification. The previous full run used 199 serial and finish Decisions calls. The new route requested five. The replay reused archived responses and made zero live API calls. It reproduced a market price on 73 scans and a separate €0 collection allowance on five. Four default-base results previously had parallel labels for the same card UUID. The physical finishes of those four and a live end-to-end price rate remain unverified.

## Local implementation and replay

The revised worker retains card-scoped partial finishes, requires OCR corroboration for the fast card route, and tries a bounded catalog search when recognition returns only a set. Verified football releases also support recovery from an empty recognition result when the two sides independently supply enough evidence. Explicit membership exclusions and serial conflicts close the relevant choices. Slabs retain their grade marker. The resolver keeps the card UUID when the finish remains unclear.

The worker checks the chosen finish's listings first. A variant switch reuses the same short-lived market snapshot. Concurrent jobs share cache writes per key, and one of the four Decisions slots stays available for recognition. Front recognition is reusable when the back changes. The back, OCR and policy version participate in the final resolution key. A transient resolution error has a 30-second cooldown before a new submission can try again.

| Offline check on recorded provider traffic | Result |
| --- | --- |
| Baseline identity and finish replay | 108/108 original outcomes reproduced |
| Exact-card catalog parser | 94 responses accepted. Applicable rows increased from 1,023 to 2,655. All 41 previously empty lists gained alternatives. |
| Pricing the same 89 previously confirmed identities | All statuses, sold/ask medians and 5,983 accepted references matched. Listing Decisions calls fell from 912 to 188. CardSight pricing fetches stayed at 89. |
| Opening other finishes on the saved analyses | 358 eligible variant switches reproduced the previous medians with zero additional CardSight fetches. Five incompatible switches on a numbered card were rejected. |

The pricing comparison holds card identities fixed. Newly offered finishes and revised prompts need fresh model answers and independent labels. No revised accuracy or live latency estimate follows from this replay. Every one of the 41 corrected lists contains a numbered option, so none qualifies for the serial-call shortcut. Separate serial and finish calls remain necessary when one answer determines the choices for the next.

Existing confirmed assignments keep their saved identity on a price refresh. Applying the new resolver to previously saved photos is a separate reinspection. The implementation did not bulk regrade the library or deploy the worker.

An unexpired offer from the previous pricing cache can still be selected after the upgrade. If the worker rejects a queued variant revision, the app returns to the previous analysis and stops resending that revision. Provider timeouts and quota responses keep their existing network handling.

The final local checks passed 370 Python tests. Swift Core ran 207 tests with one skip and zero failures. The iOS Simulator build and localization check passed. Two synthetic DiskStore save/load comparisons preserved the full library and original photo hashes. Both the original and revised replay modules were checked by hash. Only five full identity outcomes could reuse every recorded request under the new policy. The other 103 require new model answers or catalog responses.

## Unpriced cards and collection totals

The live run found a sold or asking price for 78 of 108 scans (72.2%). Twenty-eight had sales and asks, and 50 had asks alone. Of the 30 remaining scans, 10 lacked a confirmed card ID, nine lacked a confirmed finish, and 11 reached pricing. Those 11 contained six ordinary main-checklist base candidates, three inserts or prospect cards, and two parallels.

After a completed raw-card lookup with no exact market match, the local worker can issue a temporary €0 collection allowance for a confirmed ordinary base. A main-checklist rookie can qualify. With worker version 7, a catalog-eligible default base can also qualify under the ordinary-base rules. A missing price, failed lookup, or legacy base label alone supplies no allowance. The app keeps sold and asking prices empty, gives personal and researched values priority, and excludes the allowance from market appreciation. The allowance expires with its pricing snapshot.

For an older base assignment with a fresh empty price result, a user-requested reanalysis can verify the original photos. The worker adds eligibility only if the card UUID and finish still match the saved assignment. Reading the price or collection total makes no new recognition request.

An offline check held the recorded answers fixed where the choices still agreed. Two of the six candidates qualified. The other four need new identity or finish answers. This accounts for 80 of 108 cards using the historical market results and two collection allowances. The app and worker need deployment before devices use this change.

The pricing replay also uncovered two untagged listings named Football Foil for the 2026 Topps Flagship Football base checklist. The worker now forwards exact unnumbered Football Foil titles to Decisions for that catalog parallel and excludes them from the standard base card. The archived auction and ask remain candidates pending a new listing decision. This change supplies no new measured market-price percentage.

## Original shortlist defect

In the 108-card baseline, CardSight returned partial parallels for 41 Topps Flagship cards. The worker removed all 1,632 of those rows because their summaries omitted the list of applicable card IDs. The finish question offered only `base` and `unclear`. Forty cards were confirmed as base. One stayed unresolved after the confidence check.

Four of those base results disagree with saved finish labels. All four saved finishes were present in the corresponding card-detail responses. This establishes a candidate-selection defect. The actual finishes still need independent verification. Raising the model confidence threshold alone cannot recover a choice the worker removed.

## Baseline

The 108-card baseline used saved front/back photos and on-device OCR, withheld previous assignments, and made fresh recognition requests with no manual corrections. Its four recognition and pricing modules matched the checkout before these changes. These are worker timings from a sequential run. Phone capture, upload, queue wait and rendering need separate measurements.

| Measure | Observed |
| --- | ---: |
| Card UUID resolved | 98/108 |
| Card and finish auto-confirmed | 89/108 (82.4%) |
| Card unresolved / card known but finish unresolved | 10 / 9 |
| Identity median / p95 | 3.54 s / 5.15 s |
| Whole worker operation median / p95 | 4.71 s / 6.89 s |
| CardSight identify / candidate search / card detail / price calls | 108 / 11 / 94 / 89 |
| Decisions card / serial / finish / listing calls | 17 / 93 / 94 / 912 |
| Request errors / additional calls on identical warm repeats | 0 / 0 |

The independent exact-match rate is unknown. Fifteen of the 89 confirmed cases differ from the saved comparison on at least one field. A saved label can also be wrong. Twenty photos occurred in the earlier 20-card run with identical front, back and OCR inputs. All twenty kept the same confirmation state and card/parallel IDs. Count each physical card once in an accuracy test.

## Implementation order

### 1. Keep plausible finishes available and guard confirmation

- Validate card, release and set context on `GET /v1/catalog/cards/{id}`. Keep the card-detail `isParallelOnly` flag. It makes base ineligible.
- The exact-card endpoint describes its summaries as finishes available for that card. Keep those candidates when the optional membership list is omitted. Honor explicit exclusions. Carry the verified card scope through both the identity resolver and the second partial-parallel filter in `CardLookup.result`. A release-wide list needs separate membership evidence. If a winning partial has conflicting context, use at most one `GET /v1/catalog/parallels/{id}` to check it. Reuse fresh, card-scoped evidence.
- Give Decisions an explicit way to say that a visible finish is missing or unreadable. Require visible positive evidence for base. Keep the card UUID and withhold a finish and price when the relevant choices are incomplete or the photo cannot distinguish them.
- A single High provider suggestion for a numbered parallel currently passes when OCR contains no serial. A weak serial decision can also be followed by a numbered finish choice. Require supporting tier evidence before confirming a numbered finish. Distinguish an unreadable stamp from a visibly unnumbered card. Several finishes can share a denominator.
- Carry provider slab evidence through both successful and partial resolution. An offline full-path test showed the current worker accepting a raw-price key for a provider-detected slab.

The provider documents card-scoped parallel summaries and a dedicated endpoint for partial membership. [CardSight API reference](https://api.cardsight.ai/documentation)

### 2. Recover card candidates from the printed evidence

- Three unresolved scans returned a valid release and set with no card UUID. Each had a usable printed number (`GN-16`, `RR-17`, `ROY-11`). The current resolver exits before candidate recovery. Try one exact, scoped catalog search, then verify the name, number, subset and photo against the returned UUIDs. Permit an unresolved outcome.
- Three other unresolved scans had no foreground detection. When OCR supplies a clear name and number, test one bounded catalog lookup. A candidate still needs corroborating product evidence and the image check, especially across college/NFL, paper/Chrome, inserts and variations. An ambiguous result stays open.
- Preserve OCR side and line position. One actual scan printed card number 87 on the back and mentioned the player's jersey in a biography as “Wears #13”. The worker treated 13 as a hard veto. Two other misses used a Cyrillic lookalike in a checklist prefix and a space in `BPP 66`. Normalize within plausible card-number fields and verify against the catalog. Keep weak OCR as a search hint.
- On 73 of 85 high-confidence card routes, the parser found neither a checklist number nor an explicit release year. Keep the fast route for corroborated evidence. Measure the name-only group separately before deciding whether any product family can safely skip verification.

### 3. Cut waits without weakening validation

- Of 912 listing Decisions calls, 188 checked the selected finish and 724 checked other finishes. Validate the selected finish's listings first. Reuse the permitted short-lived price snapshot if another finish is opened. Keep separate sold and asking evidence, all existing listing checks and explicit cache state per variant. A deferred variant must remain unevaluated until checked.
- The normal server already finishes identity before starting background pricing. Background prices can still hold the same lock needed by new scans. Deduplicate identical work by evidence key and give interactive recognition priority within the existing shared request limit. First remove the bulk path's temporary replacement of the shared CardSight client.
- Forty-one serial calls offered only `none` and `unclear`. All 41 came from the broken shortlist above. Recompute after fixing candidate construction. When a complete shortlist genuinely has no numeric tier, ask about visible contradictory numbering during the finish check. Where both questions can be constructed in advance, test serial and finish together on the same photos. Reject inconsistent answers. Keep dependent card and finish choices in sequence.
- Key resolved identities by the front, optional back, OCR and resolver policy version. Keep front-only CardSight recognition reusable. Distinguish genuine visual uncertainty from a timeout or invalid provider response. Use a short error cooldown and allow a later request to resume the failed stage. Preserve quota accounting and deduplicate concurrent requests.

The 724 other-finish calls represent 79.4% of listing requests and 64.9% of all Decisions requests on this trace. They contained 3,409 of 10,628 listing questions. Token costs and latency can change by different amounts. Measure both on the revised path.

## Verification and rollout

1. **Offline regression.** Cover the actual shape of a partial summary with omitted membership, an explicitly inapplicable parallel, a parallel-only card, a slab, an unreadable serial, release-only recovery, a biography number, a changed back image and a transient error. Exercise the full path from provider detection through the price gate. Simulate a new scan arriving while pricing is busy. Check cancellation, duplicate requests and quota reservations.
2. **Blind labeling.** Review the 41 restricted-choice cards, all 19 abstentions and a random sample of agreements. Record player, year, product, subset, number, variant and serial tier from the photos and independent checklist evidence. Use a second reviewer for disputed finishes. Mark illegible or unverifiable fields unknown. Keep training and threshold-tuning cards out of the final validation set, including other photographs of the same copy.
3. **Paired comparison.** On a fresh representative set, compare baseline and candidate on the same physical cards. Report wrong automatic confirmations divided by all verified confirmations, correct automatic matches divided by all legible labeled scans, and avoidable misses divided by legible labeled scans. Break misses down by missing catalog candidate, wrong selection, abstention and technical failure. Report manual intervention separately. Include candidate recall before Decisions so a shortlist regression is visible.
4. **Proposed acceptance criteria.** Zero known wrong automatic confirmations on the regression set. For a target below 1% false confirmations, zero errors among 299 independent, representative, blind-verified confirmations gives a one-sided 95% binomial upper bound below 1%. Require improved correct automatic coverage on legible cards as well. Compare p50 and p95 identity, time to first price, requests per scan and quota consumption on identical inputs. Use 5.15 s as the observed worker identity p95 baseline. Measure capture-to-result p95 separately on iPhone, including a stack scan while pricing is active.

The candidate filter, OCR rules and finish selection live in the [identity resolver](../mac/identity_decisions.py). Photo caching, slab handling, price eligibility and the shared lock live in [card lookup](../mac/card_lookup.py). The [worker](../mac/server.py) schedules price work after identity completes. The [listing classifier](../mac/listing_decisions.py) shares the in-flight limit with image decisions.

The original audit passed 57 focused worker tests, then reproduced the slab and cache defects through the full worker path. Regression tests now cover those defects. The blind accuracy study and capture-to-result timing on an iPhone remain open.
