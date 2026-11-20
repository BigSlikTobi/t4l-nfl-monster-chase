# 20-card live benchmark

## Scope

Run the current source on 20 existing app front photos and their saved on-device OCR. Use today's saved app snapshot on this Mac. No new iPhone capture or upload timing is included. Never pass existing card analyses, UUIDs, prices or labels into identification.

The selection covers base cards, paper/Chrome, college prospects, inserts, Sandglitter/colored parallels and two known identity conflicts. Saved assignments are comparison references, not verified ground truth. Review photos after the automatic outputs; do not correct or retry cards to improve the score.

## Execution

1. Freeze source hashes and input-photo hashes.
2. Run fresh live CardSight identification on each front; no replay or saved identity.
3. Run the confidence/OCR routing and automatic parallel resolution.
4. Price confirmed identities only through the current sold/ask pipeline. Unresolved cards complete as unpriced.
5. Recompute medians from accepted original listing amounts. Confirm sold/ask separation.
6. Repeat from the same files with the fresh test cache to measure reuse and additional calls.
7. Decode final worker analyses with the real Swift Core models and compare sold/asking summaries.
8. Review identity differences and selected evidence against the photos; flag provisional ground truth.
9. Verify all source input files and the library snapshots are unchanged.

One sequential worker provides per-card latency without artificial parallel speedups. Fresh test caches start empty; the normal 24-hour catalog reuse applies between cards. Live provider keys and the real shared 5,000-call CardSight ledger are reused. The deployed worker, app and collections are unchanged.

## Measurements

For each card: input hash, provider confidence/top UUID, chosen card/parallel UUID, routing outcome, identity and pricing wall time, each external request duration, call counts, listing counts, sold median, asking median, cache repeat time and errors. Preserve every result, including failures. No automatic paid retries.

Speed goals, proposed rather than promised: cold median <=5 seconds, cold p95 <=15 seconds, warm repeat <=1 second with zero external calls. Correctness takes priority: no confirmed wrong player/product/parallel, no prices on unresolved identities, no mixing sales and asks, no invented zero. Report unknown identity accuracy when the reference cannot be verified independently.

Run guardrails: at most 150 CardSight requests and 1,000 Decisions requests. Provider errors stop the affected card; an exhausted shared quota stops network work. These are test limits, not changes to product quota settings.

## Logs

- [Live progress](/tmp/card-benchmark-20/live.log)
- [Per-card results](/tmp/card-benchmark-20/results.jsonl)
- [Redacted requests and responses](/tmp/card-benchmark-20/requests.jsonl)

Saved collection data and original photos stay outside Git. Only photo bytes and OCR enter the test jobs. Source code is frozen during the run; fix proposals follow the report.

## Completed baseline

All 20 completed without manual corrections: 8 confirmed/priced, 12 unpriced.
Total sequential worker time: 120.68 seconds. Priced-card median: 11.34 seconds;
maximum: 16.21 seconds. Warm repeats made zero external calls. The run spent
43 CardSight calls and 160 Decisions calls. All 20 outputs decoded through the
actual app Core models, and sold/listed medians matched the worker. The 20 original
front photo hashes and frozen source hashes stayed unchanged.

The benchmark failed the intended coverage/fast-path behavior: all cards escalated,
eight hit the resolver's 400-entry catalog cap, and pricing evaluated all variants.
Three variant disagreements need independent ground truth. These counts are not
an identity accuracy score. No product fixes or deployment were made during the run.

Private per-card details and logs: [report](/tmp/card-benchmark-20/report.md),
[interactive results](/tmp/card-benchmark-20/report.html). Camera, upload, queue
polling, screen rendering and physical-device acceptance were outside this run.
