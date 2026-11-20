from copy import deepcopy
import datetime as dt
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from card_prices import PriceResearch, identity_key
from cardsight import Client, MONTHLY_CAP, atomic
from test_pipeline import result


class BatchPriceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.calls = []
        self.overrides = {}
        self.catalog_size = 41
        self.cards = [self.analysis(n) for n in range(1, 42)]
        self.client = Client(self.root, self.transport)
        self.prices = PriceResearch(self.root, self.client)
        mock = patch('raw_guides.fetch_guide', return_value=None)
        self.guide = mock.start(); self.addCleanup(mock.stop)

    def tearDown(self):
        self.prices.executor.shutdown(wait=True)
        self.tmp.cleanup()

    def analysis(self, n):
        a = result()['analysis']
        a.update(player=f'Player {n}', year=2026, brand='Topps', setName='Topps Flagship',
                 subset='Base', cardNumber=str(n), parallel=None, serialNumber=None,
                 identityConfirmed=True, confidence='high')
        return a

    def entry(self, n):
        return dict(id=f'card-{n}', name=f'Player {n}', number=str(n), setName='Base Set',
                    setId='base', releaseId='release', releaseName='Topps Flagship Football',
                    releaseYear='2026')

    def price(self, identity, body):
        n = int(identity.split('-')[1])
        entry = dict(card_id=identity, success=True, data=dict(
            query={k: body[k] for k in ('parallel_id', 'grade_id', 'period', 'listing_type')},
            card=dict(card_id=identity, set=dict(set_id='base')),
            raw=dict(records=[dict(title=f'2026 Topps Flagship Football Player {n} #{n}',
                price=1.25, date=dt.datetime.now(dt.timezone.utc).isoformat(),
                source='ebay', listing_type='auction', url=f'https://showme.cards/batch{n}')])))
        return self.overrides.get(identity, lambda entry, body: entry)(entry, body)

    def transport(self, method, path, params, body):
        self.calls.append((method, path, deepcopy(params), deepcopy(body)))
        if path == '/v1/subscription/': return 200, dict(calls=0)
        if path == '/v1/catalog/cards':
            if params.get('setId'):
                rows = sorted([self.entry(n) for n in range(1, self.catalog_size + 1)], key=lambda r: r['name'])
                return 200, dict(cards=rows[params['skip']:params['skip'] + params['take']], total_count=len(rows))
            n = int(params['number'])
            return 200, dict(cards=[self.entry(n)], total_count=1)
        if path == '/v1/catalog/sets': return 200, dict(sets=[dict(name='Base Set')], total_count=1)
        if path == '/v1/catalog/parallels': return 200, dict(parallels=[], total_count=0)
        if path == '/v1/pricing/': return 200, dict(results=[self.price(i, body) for i in body['card_ids']])
        if path == '/v1/pricing/search': return 200, dict(query=params, results=[])
        raise AssertionError(path)

    def test_41_cards_share_one_price_call_and_keep_per_card_identity(self):
        original = deepcopy(self.cards)
        values = self.prices.lookup_many(self.cards)
        self.assertEqual(len(values), 41)
        self.assertTrue(all(v['status'] == 'ready' for v in values.values()))
        pricing = [c for c in self.calls if c[1] == '/v1/pricing/']
        self.assertEqual(len(pricing), 1)
        self.assertEqual(len(pricing[0][3]['card_ids']), 41)
        self.assertEqual(len(self.calls), 6)  # Seed + family page + usage + 2 metadata + bulk pricing.
        self.assertEqual(self.client.ledger()['calls'], 6)
        self.assertEqual(self.guide.call_count, 41)  # Never repeated during planner replay.
        self.assertEqual(self.cards, original)
        self.assertEqual(values[identity_key(self.cards[0])]['references'][0]['lowCents'], 125)
        self.assertEqual(self.prices.last_batch_stats['pricingRequests'], 1)
        self.prices.lookup_many(self.cards)
        self.assertEqual(len(self.calls), 6)
        self.assertEqual(self.prices.last_batch_stats['requests'], 0)

    def test_single_card_failure_does_not_discard_other_bulk_results(self):
        self.overrides['card-2'] = lambda entry, body: dict(card_id='card-2', success=False)
        values = self.prices.lookup_many(self.cards[:3])
        self.assertEqual(values[identity_key(self.cards[0])]['status'], 'ready')
        self.assertEqual(values[identity_key(self.cards[1])]['reason'], 'invalid_response')
        self.assertEqual(values[identity_key(self.cards[2])]['status'], 'ready')

    def test_duplicate_bulk_result_is_rejected_for_every_affected_card(self):
        transport = self.client.transport
        def duplicate(method, path, params, body):
            code, value = transport(method, path, params, body)
            if path == '/v1/pricing/': value['results'][1] = deepcopy(value['results'][0])
            return code, value
        self.client.transport = duplicate
        values = self.prices.lookup_many(self.cards[:2])
        self.assertTrue(all(v['reason'] == 'invalid_response' for v in values.values()))
        self.assertTrue(all(not v['references'] for v in values.values()))

    def test_wrong_context_and_parallel_titles_stay_rejected(self):
        def wrong_context(entry, body):
            entry['data']['card']['set']['set_id'] = 'wrong'
            return entry
        def wrong_finish(entry, body):
            entry['data']['raw']['records'][0]['title'] += ' Gold'
            return entry
        self.overrides.update({'card-2': wrong_context, 'card-3': wrong_finish})
        values = self.prices.lookup_many(self.cards[:3])
        self.assertEqual(values[identity_key(self.cards[0])]['status'], 'ready')
        self.assertEqual(values[identity_key(self.cards[1])]['reason'], 'invalid_response')
        self.assertEqual(values[identity_key(self.cards[2])]['reason'], 'no_exact_sales')
        pricing = [c[3] for c in self.calls if c[1] == '/v1/pricing/']
        self.assertEqual([len(b['card_ids']) for b in pricing], [3, 1])
        self.assertEqual(pricing[1]['card_ids'], ['card-3'])

    def test_empty_recent_buckets_share_year_fallback(self):
        def only_year(entry, body):
            if body['period'] == '90d': entry['data']['raw']['records'] = []
            return entry
        self.overrides.update({f'card-{n}': only_year for n in range(1, 4)})
        values = self.prices.lookup_many(self.cards[:3])
        self.assertTrue(all(v['status'] == 'ready' for v in values.values()))
        self.assertEqual([c[3]['period'] for c in self.calls if c[1] == '/v1/pricing/'], ['90d', '1y'])
        self.assertEqual(self.guide.call_count, 3)

    def test_quota_stop_never_calls_transport_or_mislabels_as_no_sales(self):
        ledger = self.client.ledger(); ledger['calls'] = MONTHLY_CAP
        atomic(self.client.ledger_path, ledger)
        values = self.prices.lookup_many(self.cards)
        self.assertEqual(self.calls, [])
        self.assertTrue(all(v['reason'] == 'provider_unavailable' for v in values.values()))
        self.assertEqual(self.client.ledger()['calls'], MONTHLY_CAP)
        self.assertIs(self.prices.client, self.client)

    def test_start_coalesces_requests_and_cleans_pending(self):
        with patch.object(self.prices, 'lookup_many', wraps=self.prices.lookup_many) as batch:
            for a in self.cards[:5]: self.prices.start(a)
            self.prices.executor.shutdown(wait=True)
            self.assertEqual(batch.call_count, 1)
        self.assertEqual(len([c for c in self.calls if c[1] == '/v1/pricing/']), 1)
        self.assertFalse(self.prices.pending)
        self.assertFalse(self.prices.drain_scheduled)

    def test_batch_limit_and_duplicate_owned_identity(self):
        with self.assertRaises(ValueError): self.prices.lookup_many(self.cards * 3)
        values = self.prices.lookup_many([self.cards[0], self.cards[0]])
        self.assertEqual(len(values), 1)
        pricing = [c for c in self.calls if c[1] == '/v1/pricing/']
        self.assertEqual(pricing[0][3]['card_ids'], ['card-1'])

    def test_rankings_wait_before_consuming_calls_while_owned_prices_pending(self):
        from cardsight import Market, MarketError, PRODUCTS
        market = Market(self.root, self.client)
        market.owned_prices_pending = lambda: True
        with patch.object(market.stop, 'wait', return_value=True):
            with self.assertRaises(MarketError): market.scan(next(iter(PRODUCTS)))
        self.assertEqual(self.calls, [])

    def test_failed_drain_releases_scheduler_for_next_refresh(self):
        with patch.object(self.prices, 'lookup_many', side_effect=ValueError('internal failure')):
            self.prices.start(self.cards[0])
            self.prices.executor.shutdown(wait=True)
        self.assertFalse(self.prices.pending)
        self.assertFalse(self.prices.drain_scheduled)
        self.assertFalse(self.prices.queued)

    def test_audit_reports_budget_blocks_separately_from_missing_sales(self):
        import sqlite3
        from price_audit import audit
        with sqlite3.connect(self.root / 'queue.sqlite3') as db:
            db.execute('create table jobs(id text,status text,result text)')
            for n, a in enumerate(self.cards[:3]):
                db.execute('insert into jobs values(?,?,?)', (str(n), 'analyzed', json.dumps(dict(analysis=a))))
        ledger = self.client.ledger(); ledger['calls'] = MONTHLY_CAP
        atomic(self.client.ledger_path, ledger)
        self.prices.lookup_many(self.cards[:3])
        before = (self.root / 'queue.sqlite3').read_bytes()
        report = audit(self.root, 'Topps Flagship', 2026)
        self.assertEqual(report['categories'], {'quota_blocked': 3})
        self.assertEqual(report['providerCalls'], 0)
        self.assertEqual(self.calls, [])
        self.assertEqual((self.root / 'queue.sqlite3').read_bytes(), before)

    def test_tight_budget_prices_resolved_cards_before_more_discovery(self):
        ledger = self.client.ledger(); ledger['calls'] = MONTHLY_CAP - 7
        atomic(self.client.ledger_path, ledger)
        values = self.prices.lookup_many(self.cards[:3])
        self.assertEqual(sum(v['status'] == 'ready' for v in values.values()), 2)
        self.assertEqual(sum(v.get('reason') == 'provider_unavailable' for v in values.values()), 1)
        self.assertEqual(self.client.ledger()['calls'], MONTHLY_CAP - 1)
        self.assertEqual(len([c for c in self.calls if c[1] == '/v1/pricing/']), 1)

    def test_parallel_group_shares_bulk_calls_and_reuses_general_bucket(self):
        variant_id = '11111111-1111-4111-8111-111111111111'
        variant = dict(id=variant_id, name='Football Leather Foil', setId='base', releaseId='release', numberedTo=None)
        transport = self.client.transport
        def parallel_transport(method, path, params, body):
            if path == '/v1/catalog/parallels':
                self.calls.append((method, path, deepcopy(params), deepcopy(body)))
                return 200, dict(parallels=[variant], total_count=1)
            code, value = transport(method, path, params, body)
            if path == '/v1/pricing/' and body['parallel_id'] == variant_id:
                for item in value['results']:
                    item['data']['card']['parallel'] = dict(parallel_id=variant_id)
                    for record in item['data']['raw']['records']: record['title'] += ' Football Leather Foil'
            return code, value
        self.client.transport = parallel_transport
        base = deepcopy(self.cards[0])
        parallels = [dict(a, parallel='Football Leather Foil') for a in self.cards[:3]]
        with patch.object(self.prices, 'metadata', return_value=(['Base Set'], ['Football Leather Foil'])):
            values = self.prices.lookup_many([base] + parallels)
        self.assertTrue(all(v['status'] == 'ready' for v in values.values()))
        pricing = [c[3] for c in self.calls if c[1] == '/v1/pricing/']
        # One first base bucket, three exact parallel buckets, then only the two
        # outstanding general buckets; the shared card-1 base is never repeated.
        self.assertEqual(len(pricing), 3)
        self.assertEqual(sorted(len(b['card_ids']) for b in pricing), [1, 2, 3])
        self.assertEqual(len([c for c in self.calls if c[1] == '/v1/catalog/cards']), 3)
        self.assertEqual(len([c for c in self.calls if c[1] == '/v1/catalog/parallels']), 1)
        self.assertNotIn('Leather', values[identity_key(base)]['references'][0]['title'])
        self.assertTrue(all('Leather' in values[identity_key(a)]['references'][0]['title'] for a in parallels))

    def test_large_family_retains_only_requested_rows_and_checks_full_coverage(self):
        self.catalog_size = 400
        values = self.prices.lookup_many(self.cards)
        self.assertTrue(all(v['status'] == 'ready' for v in values.values()))
        self.assertEqual(len(self.calls), 10)  # Seed + five tie-safe pages + usage + metadata + bulk.
        self.assertEqual(len([c for c in self.calls if c[1] == '/v1/catalog/cards']), 6)
        # The only persistent provider catalog metadata remains bounded vocabulary.
        stored = [json.loads(p.read_text()) for p in self.prices.cache.glob('*.json')]
        self.assertFalse(any('cards' in v for v in stored))
        self.assertEqual(len([v for v in stored if v.get('references')]), 41)

    def test_incomplete_family_page_falls_back_without_proving_missing_identity(self):
        transport = self.client.transport
        def broken(method, path, params, body):
            code, value = transport(method, path, params, body)
            if path == '/v1/catalog/cards' and params.get('setId'):
                value['cards'] = value['cards'][:-1]
            return code, value
        self.client.transport = broken
        values = self.prices.lookup_many(self.cards)
        self.assertTrue(all(v['status'] == 'ready' for v in values.values()))
        self.assertEqual(len([c for c in self.calls if c[1] == '/v1/catalog/cards' and c[2].get('setId')]), 1)
        self.assertEqual(len([c for c in self.calls if c[1] == '/v1/catalog/cards' and c[2].get('number')]), 41)

    def test_wrong_release_family_page_is_discarded_before_any_bulk_price(self):
        transport = self.client.transport
        def wrong(method, path, params, body):
            code, value = transport(method, path, params, body)
            if path == '/v1/catalog/cards' and params.get('setId'):
                value['cards'][0]['releaseName'] = 'Topps Chrome'
            return code, value
        self.client.transport = wrong
        values = self.prices.lookup_many(self.cards)
        self.assertTrue(all(v['status'] == 'ready' for v in values.values()))
        self.assertTrue(all('Chrome' not in r['title'] for v in values.values() for r in v['references']))


    def shared_record(self, n):
        return dict(title=f'2026 Topps Flagship Football Player {n} #{n}', price=1.25,
                    date=dt.datetime.now(dt.timezone.utc).isoformat(), source='ebay',
                    listing_type='auction', url=f'https://showme.cards/shared{n}')





    def test_same_catalog_query_for_two_families_is_never_scoped_to_one(self):
        from card_price_batch import BatchClient
        from card_prices import catalog_release, catalog_subset
        batch = BatchClient(self.client)
        batch.configure_catalog(self.cards + [dict(self.cards[0], subset='Insert')], catalog_release, catalog_subset)
        params = dict(name='Player 1', number='1', releaseName='Topps Flagship Football', year='2026', take=100)
        key = batch.key('GET', '/v1/catalog/cards', params, None)
        self.assertIsNone(batch.catalog_queries[key])
        self.assertTrue(all(key not in group for group in batch.catalog_groups.values()))

    def test_catalog_pages_keep_equal_name_groups_intact(self):
        self.catalog_size = 400
        original_entry = self.entry
        self.entry = lambda n: dict(original_entry(n), name=f'Player {(n - 1) // 30}')
        for n, a in enumerate(self.cards, 1): a['player'] = self.entry(n)['name']
        for n in range(1, 42):
            def rename(entry, body, n=n):
                entry['data']['raw']['records'][0]['title'] = f"2026 Topps Flagship Football {self.entry(n)['name']} #{n}"
                return entry
            self.overrides[f'card-{n}'] = rename
        values = self.prices.lookup_many(self.cards)
        self.assertTrue(all(v['status'] == 'ready' for v in values.values()))
        pages = [c[2] for c in self.calls if c[1] == '/v1/catalog/cards' and c[2].get('setId')]
        self.assertGreater(len(pages), 1)
        self.assertEqual(pages[1]['skip'], 90)  # Discard the incomplete trailing player group.
        self.assertLessEqual(len(pages), 8)

    def test_catalog_duplicate_ids_do_not_create_false_absence(self):
        transport = self.client.transport
        def duplicate(method, path, params, body):
            code, value = transport(method, path, params, body)
            if path == '/v1/catalog/cards' and params.get('setId'):
                value['cards'][1] = deepcopy(value['cards'][0])
            return code, value
        self.client.transport = duplicate
        values = self.prices.lookup_many(self.cards)
        self.assertTrue(all(v['status'] == 'ready' for v in values.values()))
        self.assertEqual(len([c for c in self.calls if c[1] == '/v1/catalog/cards' and c[2].get('number')]), 41)

    def test_live_sized_family_with_1400_rows_uses_bounded_pages(self):
        self.catalog_size = 1400
        values = self.prices.lookup_many(self.cards)
        self.assertTrue(all(v['status'] == 'ready' for v in values.values()))
        self.assertEqual(len([c for c in self.calls if c[1] == '/v1/catalog/cards']), 16)
        self.assertEqual(len(self.calls), 20)

    def test_ambiguous_seed_variations_are_filtered_before_group_resolution(self):
        transport = self.client.transport
        def variations(method, path, params, body):
            code, value = transport(method, path, params, body)
            if path == '/v1/catalog/cards' and params.get('number'):
                base = value['cards'][0]
                value['cards'] += [dict(base, id=base['id']+'-variation', variationOf=base['id']),
                                   dict(base, id=base['id']+'-described', description='Image variation')]
                value['total_count'] = len(value['cards'])
            return code, value
        self.client.transport = variations
        values = self.prices.lookup_many(self.cards)
        self.assertTrue(all(v['status'] == 'ready' for v in values.values()))
        self.assertEqual(len([c for c in self.calls if c[1] == '/v1/catalog/cards']), 2)

    def test_wider_bulk_bucket_avoids_title_search_for_exact_sale_after_row_25(self):
        def extended(entry, body):
            bad = [dict(self.shared_record(1), grade_id='graded', url=f'https://showme.cards/graded{n}') for n in range(25)]
            entry['data']['raw']['records'] = (bad + [self.shared_record(1)])[:body['limit']]
            return entry
        self.overrides['card-1'] = extended
        value = self.prices.lookup_many(self.cards[:1])[identity_key(self.cards[0])]
        self.assertEqual(value['status'], 'ready')
        pricing = [c[3] for c in self.calls if c[1] == '/v1/pricing/']
        self.assertEqual(len(pricing), 1)
        self.assertEqual(pricing[0]['limit'], 50)
        self.assertNotIn('/v1/pricing/search', [c[1] for c in self.calls])
        self.assertEqual(len(value['references']), 1)

    def test_wider_bucket_still_caps_published_references_and_marks_sample(self):
        def extended(entry, body):
            entry['data']['raw']['records'] = [dict(self.shared_record(1), price=1+n/100,
                                                   url=f'https://showme.cards/accepted{n}') for n in range(50)]
            return entry
        self.overrides['card-1'] = extended
        value = self.prices.lookup_many(self.cards[:1])[identity_key(self.cards[0])]
        self.assertEqual(value['status'], 'ready')
        self.assertEqual(len(value['references']), 25)
        self.assertTrue(value['sampleLimited'])
