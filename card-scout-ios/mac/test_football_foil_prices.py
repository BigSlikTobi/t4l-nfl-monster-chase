import datetime as dt
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

from card_lookup import CardLookup, FLAGSHIP_2026_BASE_SET, FLAGSHIP_FOOTBALL


class FootballFoilPriceTests(unittest.TestCase):
    title = "2026 Topps Flagship Football Mansoor Delane #348 Football Foil (RC)"
    card = "bdf60723-d64c-4058-8962-3bc9d35238bf"

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.market = Mock()
        self.decisions = Mock()
        self.decisions.classify.side_effect = lambda target, rows: {r["id"]: "match" for r in rows}
        self.lookup = CardLookup(Path(tmp.name), self.market, decisions=self.decisions)
        self.addCleanup(self.lookup.executor.shutdown)
        self.analysis = dict(identityConfirmed=True, player="Mansoor Delane", year=2026,
                             cardNumber="348", rookie=True, parallel="Football",
                             cardSightIdentity=dict(cardID=self.card, setID=FLAGSHIP_2026_BASE_SET,
                                 releaseName="Topps Flagship Football", setName="Base Set",
                                 parallelID=FLAGSHIP_FOOTBALL, parallelName="Football"))
        self.rows = []
        self.market.request.return_value = dict(
            card=dict(card_id=self.card, name="Mansoor Delane", number="348", set=dict(
                set_id=FLAGSHIP_2026_BASE_SET, year="2026", release="Topps Flagship Football", name="Base Set")),
            query=dict(grade_id=None, period="90d", listing_type="both"), raw=dict(records=self.rows))

    def row(self, title, **changes):
        self.rows.append(dict(dict(title=title, listing_type="auction", price=1, source="ebay",
                                   date=dt.date.today().isoformat(), url=f"https://showme.cards/row{len(self.rows)}"),
                              **changes))

    def test_untagged_finish_uses_its_own_decisions_and_never_enters_base(self):
        self.row(self.title)
        self.row(self.title, listing_type="fixed", price=4.99)
        for suffix in (" PSA 10", " lot", " /99", " autograph", " Blue", " variation"):
            self.row(self.title + suffix)
        for phrase in ("Gold Football Foil", "Rainbow Foil", "Football", "Topps Logo Foil"):
            self.row(self.title.replace("Football Foil", phrase))
        self.row(self.title.replace("#348", "#349"))
        self.row(self.title.replace("Mansoor Delane", "Other Player"))
        self.row(self.title, parallel_id="11111111-1111-4111-a111-111111111111")
        self.row(self.title, parallel_name="Green Football")
        self.row(self.title, grade_id="PSA-10")
        self.row(self.title, url=self.rows[-1]["url"])  # same URL with a conflicting grade
        self.row(self.title, parallel_name="Gold Football", url="https://showme.cards/conflict")
        self.row(self.title, url="https://showme.cards/conflict")
        result = self.lookup.lookup(self.analysis)
        self.assertEqual((result["medianCents"], result["askingMedianCents"]), (100, 499))
        target, candidates = self.decisions.classify.call_args.args
        self.assertEqual(target["cardSightIdentity"]["parallelID"], FLAGSHIP_FOOTBALL)
        self.assertEqual([r["parallelID"] for r in candidates], [None, None])
        self.assertTrue(all(r["title"] == self.title for r in candidates))

        base = dict(self.analysis, parallel=None,
                    cardSightIdentity=dict(self.analysis["cardSightIdentity"], parallelID=None, parallelName=None))
        base_result = self.lookup.lookup(base)
        self.assertFalse(any(r["title"] == self.title for r in base_result["references"]))
        self.assertEqual(self.market.request.call_count, 1)

    def test_unconfirmed_listing_decision_stays_unpriced_and_old_result_is_rechecked(self):
        self.row(self.title)
        self.lookup.lookup(self.analysis)
        key = self.lookup.key(self.analysis)
        path = self.lookup.cache / (key + ".json")
        old = json.loads(path.read_text())
        old.pop("footballFoilChecked")
        old["options"]["base"] = dict(id="base", name="Base", priceStatus="ready", medianCents=100)
        path.write_text(json.dumps(old))
        self.assertEqual(self.lookup.status(self.analysis), "empty")
        self.decisions.classify.side_effect = lambda target, rows: {r["id"]: "unclear" for r in rows}
        result = self.lookup.lookup(self.analysis)
        self.assertEqual(result["status"], "no_match")
        self.assertIsNone(result["medianCents"])
        self.assertEqual(self.market.request.call_count, 1)
        self.assertNotIn("priceStatus", self.lookup.cached(key)["options"]["base"])
