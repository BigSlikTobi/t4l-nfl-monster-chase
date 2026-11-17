# Automatic confidence routing

Source implementation; not deployed.

The direct scan route now resolves identity before pricing. No operator selects
a candidate in this flow. Existing saved identities and explicit user corrections
retain their server-owned refresh and conflict protections.

- High provider card confidence plus agreeing OCR uses the fast route. A printed
  player, explicit release-year/card-number or paper/Chrome conflict triggers escalation.
  Biography years, copyright years and CMP printing codes are not card-identity fields.
- Medium/low confidence and absent OCR use image-backed Decisions over provider
  candidate UUIDs plus `unclear`. An unambiguous OCR name narrows the candidates;
  the image still has to confirm the candidate.
- Card and parallel checks are separate. A unique high-confidence parallel with
  consistent OCR serial evidence can pass. Otherwise the worker fetches available
  parallels for the resolved set and compares the actual image.
- If OCR cannot supply the serial tier, a focused image question tries to read
  the denominator before the finish check. No serial numerator is invented.
- OCR denominator conflicts veto a parallel choice. Base is an explicit option,
  not the fallback when parallel selection fails.
- Weak/tied choices, unknown UUIDs, invalid responses, provider failures and
  unresolved finishes remain unconfirmed/unpriced. Routing currently requires a
  winning probability of at least 0.5 and a lead of 0.15; these conservative
  defaults are not calibrated accuracy claims. Broader labeled tests are needed.

Requests reuse the configured worker OpenAI key. Images are inline only for
identity checks; listing-price Decisions remain JSON-only. Catalog lookup now uses `GET /v1/catalog/cards/{id}` for the identified card,
validates its exact context and complete parallel count, and allows at most 200
returned parallel definitions / 100 decision choices. There is no release-wide
400-entry gate. Only that card's parallel metadata is cached for 24 hours and
purged by existing maintenance. Image/OCR-keyed resolutions are also cached for 24 hours. The worker
quota ledger still governs every CardSight call. No automatic paid retries.

`identity-resolution.json` records routing outcomes in each private job folder.
It omits photos, OCR, prompts and credentials and is removed with transport data.
The physical card ID, photos, collection state and manual assignments are unchanged.
Installers include `identity_decisions.py`.

The listing prompt also now explicitly treats different serial numerators as
valid comparable copies. It still rejects different denominators. Independent pricing variant checks now overlap through four worker threads.
Identity and listing Decisions share a four-request cap per process. This reduces
waiting without dropping variant checks or changing median math. Weak listing
matches remain unclear. See [quality and parallel requests](quality-and-parallel-requests-2026-11-17.md).

## Verification

The original Tyrone Tracy photo was tested using the recorded low-confidence
Fred Warner identification and recorded parallel catalog responses. Apple Vision
extracted OCR automatically; no names, UUIDs or serial facts were hand-entered.
Two live Decisions calls selected Tyrone's card UUID and Yellow Wave /275, and
the normal result builder marked identity confirmed. This was a provider-response
replay with live model decisions, not a fresh recognition call or phone acceptance.
Earlier no-OCR trials remained ambiguous or weak; those are not counted as success.

The final trace is at `/tmp/card-confidence-live/final-trace.jsonl` on the test Mac.
No collection data was changed and no worker/app deployment was performed.

Final checks: 337 worker tests passed; 205 Core tests passed with one existing
skip. Localization passed for 859 bilingual keys and 99 templates. Python
compilation, installer shell syntax and whitespace checks passed. No app UI or
camera source changed, so a new simulator/device UI check was not run.
