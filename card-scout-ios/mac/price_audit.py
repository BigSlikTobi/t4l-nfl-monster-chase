"""Read-only coverage audit of saved card results and transient price evidence.

No network calls, provider retries, queue initialization, or identity changes.
The full per-card report is private; stdout contains aggregate counts only.
"""
import argparse
from collections import Counter
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import time

from card_prices import eligible, identity_key, TTL, MATCHER_VERSION


def audit(root, set_name, year):
    root = Path(root)
    with sqlite3.connect(f'file:{root / "queue.sqlite3"}?mode=ro', uri=True) as db:
        rows = db.execute('SELECT id,status,result FROM jobs ORDER BY id').fetchall()
    digest = hashlib.sha256(json.dumps([(i, r) for i, _, r in rows]).encode()).hexdigest()
    details = []
    for identity, status, raw in rows:
        if status != 'analyzed' or not raw: continue
        a = json.loads(raw).get('analysis') or {}
        if a.get('setName') != set_name or a.get('year') != year: continue
        category = 'identity_review' if not eligible(a) else 'not_checked'
        reason, references = None, []
        path = root / 'card-price-cache' / (identity_key(a) + '.json')
        if eligible(a) and path.exists():
            try:
                v = json.loads(path.read_text()) if path.stat().st_size < 100000 else {}
                if (v.get('matcherVersion') == MATCHER_VERSION and v.get('key') == identity_key(a)
                        and time.time() < v.get('expiresAt', 0) <= time.time() + TTL + 60):
                    reason = v.get('reason')
                    references = v.get('references', [])
                    if references:
                        category = 'exact_sales' if all(r.get('kind') == 'sold' for r in references) else 'guide_estimate'
                    elif reason == 'provider_unavailable':
                        category = 'quota_blocked' if v.get('message', '').startswith(('Gratis-Budget erreicht.', 'API-Budget erreicht.')) else 'provider_blocked'
                    elif reason == 'catalog_not_exact': category = 'catalog_mismatch'
                    elif reason == 'variant_not_exact': category = 'variant_mismatch'
                    elif reason in ('no_sales', 'no_exact_sales'): category = reason
                    elif reason == 'invalid_response': category = 'invalid_response'
            except (OSError, ValueError, TypeError): category = 'invalid_cache'
        details.append(dict(jobID=identity, identityKey=identity_key(a), category=category,
                            reason=reason, references=len(references)))
    return dict(checkedAt=dt.datetime.now(dt.timezone.utc).isoformat(), setName=set_name,
                year=year, total=len(details), eligible=sum(x['category'] != 'identity_review' for x in details),
                categories=dict(Counter(x['category'] for x in details)),
                savedResultsSHA256=digest, providerCalls=0, cards=details)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--set', default='Topps Flagship')
    parser.add_argument('--year', type=int, default=2026)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = audit(args.data, args.set, args.year)
    # Never overwrite another audit or place it in owned-card storage.
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as handle: json.dump(report, handle, indent=2)
    print(json.dumps({k: v for k, v in report.items() if k != 'cards'}))


if __name__ == '__main__': main()
