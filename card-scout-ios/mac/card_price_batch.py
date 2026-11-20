"""Ephemeral request coalescing for one bounded owned-card price batch.

No catalog or provider responses survive the batch. Existing per-card validators
consume each split response; batching never changes identity or sale acceptance.
"""
from copy import deepcopy
import json

from cardsight import MONTHLY_CAP, MarketError, normal


class PricingPending(Exception):
    """Internal suspension, deliberately not a provider or per-card failure."""


class BatchClient:
    def __init__(self, client):
        self.client = client
        self.responses = {}
        self.pending = {}
        self.requests = 0
        self.pricing_requests = 0
        self.catalog_groups = {}
        self.catalog_queries = {}
        self.catalog_attempted = set()

    def configure_catalog(self, analyses, release, subset):
        self.release = release
        for a in analyses:
            params = dict(name=a['player'], number=a['cardNumber'], releaseName=release(a),
                          year=str(a['year']), take=100)
            key = self.key('GET', '/v1/catalog/cards', params, None)
            group = (release(a), str(a['year']), normal(subset(a)))
            if key in self.catalog_queries and self.catalog_queries[key] != group:
                previous = self.catalog_queries[key]
                if previous is not None: self.catalog_groups[previous].pop(key, None)
                self.catalog_queries[key] = None
                continue
            self.catalog_queries[key] = group
            self.catalog_groups.setdefault(group, {})[key] = params

    def prime_catalog(self, key, params):
        group = self.catalog_queries.get(key)
        queries = self.catalog_groups.get(group, {})
        if len(queries) < 8 or group in self.catalog_attempted: return
        # Bounded live resolution for this owned-card batch only. Retain matches
        # for requested identities; discard every unrelated provider row.
        max_pages = min(20, len(queries) // 2)
        if MONTHLY_CAP - self.client.ledger()['calls'] < max_pages + 3: return
        seed = self.direct('GET', '/v1/catalog/cards', params)
        rows = seed.get('cards', [])
        count = seed.get('total_count')
        if (type(count) is not int or not 0 <= count <= 100 or not isinstance(rows, list)
                or len(rows) != count or any(not isinstance(row, dict) for row in rows)): return
        candidates = [row for row in rows if normal(row.get('name')) == normal(params['name'])
                      and str(row.get('number')) == params['number']
                      and row.get('releaseName') == group[0] and str(row.get('releaseYear')) == group[1]
                      and normal(row.get('setName')) == group[2] and row.get('setId') and row.get('releaseId')
                      and not row.get('variationOf') and not row.get('isParallelOnly') and not row.get('description')]
        if len(candidates) != 1: return
        card = candidates[0]
        self.catalog_attempted.add(group)
        matches = {k: [] for k in queries}
        wanted = {}
        for k, query in queries.items():
            wanted.setdefault((normal(query['name']), query['number']), []).append(k)
        total, offset, seen = None, 0, set()
        try:
            for _ in range(max_pages):
                page = self.direct('GET', '/v1/catalog/cards', dict(releaseId=card['releaseId'],
                    setId=card['setId'], take=100, skip=offset, sort='name', order='asc'), cache=False)
                count, rows = page.get('total_count'), page.get('cards')
                if (type(count) is not int or not 0 < count <= max_pages * 100
                        or (total is not None and total != count) or not isinstance(rows, list)
                        or len(rows) != min(100, count - offset)): return
                total = count
                if offset + len(rows) < total:
                    # Preserve whole equal-name groups across unstable tie offsets.
                    last = rows[-1]['name'].casefold()
                    while rows and rows[-1]['name'].casefold() == last: rows.pop()
                    if not rows: return
                for row in rows:
                    if (not isinstance(row.get('id'), str) or row['id'] in seen
                            or row.get('releaseId') != card['releaseId'] or row.get('setId') != card['setId']
                            or row.get('releaseName') != group[0] or str(row.get('releaseYear')) != group[1]
                            or normal(row.get('setName')) != group[2]): return
                    seen.add(row['id'])
                    for k in wanted.get((normal(row.get('name')), str(row.get('number'))), []):
                        matches[k].append(row)
                offset += len(rows)
                if offset == total:
                    if len(seen) != total or card['id'] not in seen: return
                    for k, candidates in matches.items():
                        self.responses[k] = dict(cards=candidates, total_count=len(candidates))
                    return
        except (ValueError, KeyError, TypeError, AttributeError):
            # Incomplete or changing pages cannot prove absence or uniqueness.
            # Fall back to original targeted discovery and its exact validators.
            return

    def __getattr__(self, name):
        return getattr(self.client, name)

    @staticmethod
    def key(method, path, params, body):
        return json.dumps([method, path, params, body], sort_keys=True)

    def request(self, method, path, params=None, body=None):
        key = self.key(method, path, params, body)
        if key in self.responses:
            value = self.responses[key]
            if isinstance(value, Exception): raise value
            return deepcopy(value)
        if method == "POST" and path == "/v1/pricing/":
            if not isinstance(body, dict) or len(body.get("card_ids", [])) != 1:
                raise ValueError("Batch planner needs one-card pricing requests")
            self.pending[key] = deepcopy(body)
            raise PricingPending()
        if path == "/v1/catalog/cards":
            remaining = MONTHLY_CAP - self.client.ledger()["calls"]
            groups = {json.dumps({k: v for k, v in b.items() if k != "card_ids"}, sort_keys=True)
                      for b in self.pending.values()}
            # Price cards already resolved before spending the last calls on
            # more discovery. A new identity needs at least lookup + pricing.
            if self.pending and remaining <= len(groups) + 1:
                raise PricingPending()
            if remaining < 2:
                raise MarketError("Gratis-Budget erreicht. Vorhandene Preise bleiben bis zum Ablauf verfügbar.")
            self.prime_catalog(key, params)
            if key in self.responses:
                return deepcopy(self.responses[key])
        return self.direct(method, path, params, body)

    def direct(self, method, path, params=None, body=None, cache=True):
        key = self.key(method, path, params, body)
        self.requests += 1
        try:
            value = self.client.request(method, path, params, body)
        except Exception as error:
            if cache: self.responses[key] = error
            raise
        if cache: self.responses[key] = deepcopy(value)
        return value

    def flush(self):
        groups = {}
        pending, self.pending = self.pending, {}
        for key, body in pending.items():
            filters = {k: v for k, v in body.items() if k != "card_ids"}
            signature = json.dumps(filters, sort_keys=True)
            groups.setdefault(signature, []).append((key, body))
        for group in groups.values():
            # Different owned finishes can request the same general bucket.
            ids = list(dict.fromkeys(body["card_ids"][0] for _, body in group))
            for start in range(0, len(ids), 100):
                chunk = ids[start:start + 100]
                body = dict(group[0][1], card_ids=chunk)
                self.requests += 1
                self.pricing_requests += 1
                try:
                    response = self.client.request("POST", "/v1/pricing/", body=body)
                    results = response.get("results")
                    if not isinstance(results, list): raise ValueError("Invalid bulk response")
                    by_id = {item["card_id"]: item for item in results}
                    if len(results) != len(chunk) or len(by_id) != len(chunk) or set(by_id) != set(chunk):
                        raise ValueError("Incomplete or ambiguous bulk response")
                except Exception as error:
                    for key, single in group:
                        if single["card_ids"][0] in chunk: self.responses[key] = error
                    continue
                for key, single in group:
                    identity = single["card_ids"][0]
                    if identity in by_id:
                        self.responses[key] = {"results": [deepcopy(by_id[identity])]}
