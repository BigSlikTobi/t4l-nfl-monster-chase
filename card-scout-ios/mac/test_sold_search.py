import datetime as dt
import unittest

import test_card_lookup
from sold_search import possible_sale


class SoldSearchTests(unittest.TestCase):
    def test_physical_finish_and_serial_cannot_be_replaced_by_a_neighbor_or_ask(self):
        a = dict(year=2025, player="Sample Player", parallel="White Prizm Shock", subset="Club Level",
                 serialNumber="7/799", cardNumber="263", cardSightIdentity=dict(releaseName="Panini Select", parallelID="id"))
        row = dict(title="2025 Select Sample Player Club Level #263 White Shock Prizm 5/799",
                   source="ebay", listing_type="auction")
        self.assertTrue(possible_sale(a, row))
        for old, new in [("799", "899"), ("White", "Gold"), ("263", "2630"), ("Club Level", "PSA 10")]:
            self.assertFalse(possible_sale(a, dict(row, title=row["title"].replace(old, new))))
        self.assertFalse(possible_sale(a, dict(row, listing_type="fixed")))

    def test_missing_price_uses_exact_sale_and_negative_cache(self):
        fixture = test_card_lookup.LookupTests(); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        lookup = fixture.lookup
        result = lookup.result(fixture.detect["detections"][0], [], fixture.job)
        a = result["analysis"]
        fixture.prices["raw"]["records"] = []
        lookup.lookup(a)
        query_calls = []
        def search(method, path, params):
            query_calls.append(path)
            return dict(query=params, results=[dict(title="2025 Donruss Optic Isiah Pacheco #147", price=2.8,
                date=dt.datetime.now(dt.timezone.utc).date().isoformat(), listing_type="auction",
                source="ebay", url="https://www.ebay.com/itm/123456789999")])
        lookup.client.request = search
        for _ in range(2):
            lookup.find_missing_sales(a, lookup.key(a))
        self.assertEqual(query_calls, ["/v1/pricing/search"])
        refs = lookup.attach(result)["analysis"]["insights"]["marketReferences"]
        self.assertEqual([(r["kind"],r["lowCents"]) for r in refs], [("sold",280)])

    def test_holo_foil_print_run_is_not_a_physical_serial_and_other_finishes_require_one(self):
        from sold_search import exact_named_parallel
        today = dt.datetime.now(dt.timezone.utc).date()
        a = dict(year=2026, player="Fixture Player", parallel="Pink Holo Foil", subset="Base", cardNumber="40",
                 cardSightIdentity=dict(releaseName="Topps Flagship Football", setName="Base Set",
                 setID="1d529543-0e41-4bdb-b3ff-437eb41fad2d", parallelID="pink", parallelName="Pink Holo Foil", numberedTo=1200))
        row = dict(title="2026 Topps Flagship Fixture Player #40 Pink Holo Foil", listing_type="auction",
                   source="ebay", price=3.25, date=today.isoformat(), url="https://www.ebay.com/itm/123456789012")
        self.assertTrue(exact_named_parallel(a, row, today))
        for term in ("Pink Diamante Foil", "Pink Holo Foil PSA 10", "Pink Holo Foil /99"):
            self.assertFalse(exact_named_parallel(a, dict(row, title=row["title"].replace("Pink Holo Foil", term)), today))

    def test_fixed_search_stays_an_ask_and_conflicting_provider_identity_is_rejected(self):
        fixture = test_card_lookup.LookupTests(); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        lookup = fixture.lookup
        result = lookup.result(fixture.detect["detections"][0], [], fixture.job)
        a = result["analysis"]
        fixture.prices["raw"]["records"] = []
        lookup.lookup(a)
        types = []
        def search(method, path, params):
            types.append(params["listing_type"])
            row = dict(title="2025 Donruss Optic Isiah Pacheco #147", price=1.99, source="ebay",
                       listing_type="fixed", date=dt.datetime.now(dt.timezone.utc).date().isoformat(),
                       url="https://www.ebay.com/itm/123456789998")
            wrong = dict(row, url="https://www.ebay.com/itm/123456789997", matched_card=dict(card_id="other"))
            return dict(query=params, results=[row, wrong] if params["listing_type"] == "fixed" else [])
        lookup.client.request = search
        lookup.find_missing_sales(a, lookup.key(a))
        self.assertEqual(types, ["auction", "fixed"])
        refs = lookup.attach(result)["analysis"]["insights"]["marketReferences"]
        self.assertEqual([(r["kind"],r["lowCents"]) for r in refs], [("ask",199)])
