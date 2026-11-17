from copy import deepcopy
import datetime as dt
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from card_lookup import CardLookup
from cardsight import Client, MarketError, MONTHLY_CAP
from server import Repository, Worker, IdentificationWorker
from test_pipeline import PHOTO, IDENTITY

CARD = "11111111-1111-4111-a111-111111111111"
SET = "22222222-2222-4222-a222-222222222222"
PARALLEL = "33333333-3333-4333-a333-333333333333"


def detection():
    return dict(confidence="High", zIndex=0,
                card=dict(id=CARD, setId=SET, year="2025", manufacturer="Panini", releaseName="Donruss Optic",
                          setName="Base Set", name="Isiah Pacheco", number="147"))


def pricing(parallel=None):
    day = dt.date.today().isoformat()
    return dict(card=dict(card_id=CARD, name="Isiah Pacheco", number="147", set=dict(set_id=SET, year="2025", release="Donruss Optic", name="Base Set")),
                query=dict(parallel_id=parallel, grade_id=None, period="90d", listing_type="both"),
                raw=dict(records=[dict(title="2025 Donruss Optic Isiah Pacheco #147" + (" Orange" if parallel else ""),
                     price=p, date=day, source="ebay", listing_type="auction", parallel_id=parallel,
                     parallel_name="Orange" if parallel else None, url=f"https://www.ebay.com/itm/{123456789000+i}")
                     for i, p in enumerate([1, 1, 1, 8])]))


class LookupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.job = self.root / "jobs" / CARD
        self.job.mkdir(parents=True)
        (self.job / "front.jpg").write_bytes(b"\xff\xd8\xffsynthetic-front")
        (self.job / "back.jpg").write_bytes(b"\xff\xd8\xffsynthetic-back")
        self.calls = []
        self.detect = dict(success=True, requestId="fixture", detections=[detection()])
        self.prices = pricing()
        self.status = 200
        def transport(method, path, params, body):
            self.calls.append((method, path, params, body))
            return self.status, deepcopy(self.detect if method == "POST" else self.prices)
        self.client = Client(self.root, transport)
        self.decisions = unittest.mock.Mock()
        self.decisions.classify.side_effect = lambda target, rows: {r["id"]: "match" for r in rows}
        self.resolver = unittest.mock.Mock()
        self.resolver.resolve.side_effect = lambda d, *args: d
        self.lookup = CardLookup(self.root, self.client, decisions=self.decisions, resolver=self.resolver)

    def tearDown(self):
        self.lookup.executor.shutdown(wait=True)
        self.temp.cleanup()

    def analysis(self): return self.lookup.identify(self.job, [])["analysis"]

    def test_front_identification_then_exact_uuid_price_and_median(self):
        a = self.analysis()
        self.assertEqual(a["cardSightIdentity"]["cardID"], CARD)
        self.assertEqual(a["assessmentSource"], "cardsight")
        self.assertEqual(a["licenseScope"], "unknown")
        self.assertEqual(a["insights"]["actionReason"], "")
        self.assertEqual(a["insights"]["conditionStatus"], "not_assessable")
        value = self.lookup.lookup(a)
        self.assertEqual(value["medianCents"], 100)
        self.assertEqual(len(value["references"]), 4)
        self.assertEqual([(c[0], c[1]) for c in self.calls], [("POST", "/v1/identify/card/football"), ("GET", "/v1/pricing/" + CARD)])
        self.assertEqual(self.calls[0][3], (self.job / "front.jpg").read_bytes())
        self.assertEqual(self.calls[1][2], dict(grade_id="null", period="90d", listing_type="both", limit=500))

    def test_cache_reused_across_jobs_and_process_restart(self):
        a = self.analysis(); self.lookup.lookup(a)
        restarted = CardLookup(self.root, self.client, decisions=self.decisions, resolver=self.resolver)
        try:
            other = self.root / "jobs" / SET; other.mkdir()
            (other / "front.jpg").write_bytes((self.job / "front.jpg").read_bytes())
            b = restarted.identify(other, [])["analysis"]
            self.assertEqual(restarted.lookup(b)["medianCents"], 100)
            self.assertEqual(len(self.calls), 2)
            self.assertEqual(restarted.attach(dict(analysis=b))["analysis"]["insights"]["marketReferences"][0]["currency"], "USD")
        finally: restarted.executor.shutdown(wait=True)

    def test_different_front_still_reuses_card_price(self):
        a = self.analysis(); self.lookup.lookup(a)
        (self.job / "front.jpg").write_bytes(b"\xff\xd8\xffanother-copy")
        self.lookup.lookup(self.analysis())
        self.assertEqual([c[0] for c in self.calls], ["POST", "GET", "POST"])

    def test_expired_price_fetches_by_saved_uuid_without_identification(self):
        a = self.analysis(); self.lookup.lookup(a)
        path = self.lookup.cache / (self.lookup.key(a) + ".json")
        old = json.loads(path.read_text()); old["expiresAt"] = time.time() - 1; path.write_text(json.dumps(old))
        self.lookup.lookup(a)
        self.assertEqual([c[0] for c in self.calls], ["POST", "GET", "GET"])

    def test_parallel_is_part_of_request_and_cache_key(self):
        base = self.analysis(); self.lookup.lookup(base)
        self.detect["detections"][0]["card"]["parallelSuggestions"] = [dict(id=PARALLEL, name="Orange", confidence="High")]
        (self.job / "front.jpg").write_bytes(b"\xff\xd8\xfforange-copy")
        orange = self.analysis(); self.prices = pricing(PARALLEL)
        value = self.lookup.lookup(orange)
        self.assertIsNone(value["medianCents"])  # The shared snapshot only had base sales.
        self.assertEqual(value["status"], "no_match")
        self.assertEqual(self.lookup.key(base), self.lookup.key(orange))
        self.assertEqual(len([c for c in self.calls if c[0] == "GET"]), 1)

    def test_ambiguous_parallel_or_low_confidence_never_prices_base(self):
        for change in [dict(confidence="Medium"), dict(card=dict(detection()["card"], parallelSuggestions=[dict(id=PARALLEL, name="Orange", confidence="Medium")])), dict(card=dict(detection()["card"], id="not-a-uuid"))]:
            with self.subTest(change=change):
                value = self.lookup.result(dict(detection(), **change), [], self.job)
                self.assertFalse(value["analysis"]["identityConfirmed"])
                if value["analysis"].get("cardSightIdentity"):
                    self.lookup.lookup(value["analysis"])
                    attached = self.lookup.attach(value)
                    self.assertEqual(attached["analysis"]["insights"]["marketReferences"], [])
                else:
                    self.assertIsNone(self.lookup.lookup(value["analysis"]))
        self.assertEqual(self.calls, [])

    def test_no_card_and_multiple_cards_are_not_assigned_arbitrarily(self):
        for detections in [[], [dict(detection(), zIndex=-1)], [dict(detection(), zIndex=-1), dict(detection(), zIndex=-2)]]:
            self.detect["detections"] = detections
            for p in self.lookup.cache.glob("photo-*"): p.unlink()
            a = self.analysis()
            self.assertFalse(a["identityConfirmed"])
            self.assertIsNone(self.lookup.key(a))

    def test_slab_is_not_priced_as_raw(self):
        d = detection(); d["grading"] = dict(company=dict(name="PSA"))
        a = self.lookup.result(d, [], self.job)["analysis"]
        self.assertTrue(a["identityConfirmed"])
        self.assertIsNone(self.lookup.lookup(a))

    def test_variation_does_not_merge_into_base_binder(self):
        base = self.lookup.result(detection(), [], self.job)
        d = detection()
        d["card"].update(id=PARALLEL, variationOf=CARD, description="Image variation")
        variation = self.lookup.result(d, [base["collection"]], self.job)
        self.assertNotEqual(variation["collection"]["id"], base["collection"]["id"])
        self.assertEqual(variation["analysis"]["cardSightIdentity"]["variationOf"], CARD)
        self.assertNotEqual(self.lookup.key(base["analysis"]), self.lookup.key(variation["analysis"]))

    def test_existing_checklist_identity_and_rows_are_preserved(self):
        original = self.lookup.result(detection(), [], self.job)["collection"]
        original.update(id="existing-optic-binder", cards=original["cards"] + [dict(number="148", player="Other Player", team="", rookie=False, imageURL=None)])
        value = self.lookup.result(detection(), [original], self.job)
        self.assertEqual(value["analysis"]["collectionID"], "existing-optic-binder")
        self.assertEqual(value["collection"], original)
        self.assertEqual(len(value["collection"]["cards"]), 2)
        chosen = self.lookup.select(value, "base", [original])
        self.assertEqual(chosen["collection"], original)

    def test_bulk_prices_deduplicate_ids_and_reuse_normal_variant_validation(self):
        a = self.analysis()
        calls = []
        original = self.client.transport
        def transport(method, path, params, body):
            calls.append((method, path, body))
            return 200, {"results": [{"card_id": CARD, "success": True, "data": pricing()}]}
        self.client.transport = transport
        values = self.lookup.lookup_many([a, deepcopy(a)])
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0:2], ("POST", "/v1/pricing/"))
        self.assertNotIn("parallel_id", calls[0][2])
        self.assertEqual(calls[0][2]["card_ids"], [CARD])
        self.assertEqual(calls[0][2]["limit"], 50)
        self.assertEqual(values[self.lookup.key(a)]["medianCents"], 100)
        self.lookup.lookup_many([a])
        self.assertEqual(len(calls), 1)
        self.assertIs(self.lookup.client, self.client)
        self.client.transport = original

    def test_incomplete_bulk_response_cannot_create_a_price(self):
        a = self.analysis()
        self.client.transport = lambda *args: (200, {"results": []})
        values = self.lookup.lookup_many([a])
        self.assertEqual(values[self.lookup.key(a)]["status"], "unavailable")
        self.assertIsNone(values[self.lookup.key(a)]["medianCents"])
        self.assertIs(self.lookup.client, self.client)

    def test_optional_base_parallel_field_keeps_exact_base_but_rejects_numbered_sale(self):
        a = self.analysis()
        data = pricing()
        for row in data["raw"]["records"]: row.pop("parallel_id", None)
        self.assertEqual(len(self.lookup.references(a, data)), 4)
        data["raw"]["records"][0]["title"] += " /2026"
        self.decisions.classify.side_effect = lambda target, rows: {r["id"]: "different" if "/2026" in r["title"] else "match" for r in rows}
        self.assertEqual(len(self.lookup.references(a, data)), 3)

    def test_wrong_pricing_context_or_filters_rejected(self):
        a = self.analysis()
        for field, value in [("card_id", SET), ("name", "Joe Burrow"), ("number", "148")]:
            data = pricing(); data["card"][field] = value
            with self.assertRaises(ValueError): self.lookup.references(a, data)
        for field, value in [("parallel_id", PARALLEL), ("grade_id", SET), ("listing_type", "invalid"), ("period", "1y")]:
            data = pricing(); data["query"][field] = value
            with self.assertRaises(ValueError): self.lookup.references(a, data)

    def test_asks_wrong_variants_grades_lots_dates_and_duplicates_excluded(self):
        a = self.analysis()
        mutations = [dict(listing_type="invalid"), dict(parallel_id=PARALLEL), dict(grade_id=SET),
                     dict(price=True), dict(price=float("nan")), dict(currency="EUR"),
                     dict(date=(dt.date.today() - dt.timedelta(days=91)).isoformat()),
                     dict(date=(dt.date.today() + dt.timedelta(days=1)).isoformat())]
        for mutation in mutations:
            data = pricing(); data["raw"]["records"] = [dict(data["raw"]["records"][0], **mutation)]
            with self.subTest(mutation=mutation): self.assertEqual(self.lookup.references(a, data), [])
        data = pricing(); data["raw"]["records"].append(data["raw"]["records"][0])
        self.assertEqual(len(self.lookup.references(a, data)), 4)

    def test_empty_and_unavailable_prices_do_not_become_zero_or_repeat(self):
        a = self.analysis()
        self.prices["raw"]["records"] = []
        value = self.lookup.lookup(a)
        self.assertEqual(value["status"], "no_match"); self.assertIsNone(value["medianCents"])
        self.lookup.lookup(a); self.assertEqual(len(self.calls), 2)
        (self.lookup.cache / (self.lookup.key(a) + ".json")).unlink()
        self.status = 429
        value = self.lookup.lookup(a)
        self.assertEqual(value["status"], "unavailable"); self.assertIsNone(value["medianCents"])
        self.lookup.lookup(a); self.assertEqual(len(self.calls), 3)

    def test_confirmed_unpriced_base_carries_snapshot_expiry_without_market_evidence(self):
        d = detection()
        d["eligibleParallels"] = [dict(id="base", name="Base"), dict(id=PARALLEL, name="Silver")]
        d["card"].update(ordinaryBaseCatalog=True, attributes=["RC"])
        result = self.lookup.result(d, [], self.job)
        a = result["analysis"]
        self.assertTrue(a["rookie"])
        self.assertNotIn("unpricedBaseExpiresAt", self.lookup.attach(result)["analysis"])
        self.prices["raw"]["records"] = []
        self.lookup.lookup(a)
        attached = self.lookup.attach(result)["analysis"]
        snapshot = self.lookup.cached(self.lookup.key(a))
        self.assertEqual(attached["unpricedBaseExpiresAt"], snapshot["expiresAt"])
        self.assertEqual(attached["insights"]["marketReferences"], [])
        self.assertIsNone(self.lookup.price_view(a, snapshot)["medianCents"])
        self.assertNotIn("unpricedBaseExpiresAt", self.lookup.select(dict(analysis=attached), PARALLEL)["analysis"])
        for changes in [dict(identityConfirmed=False), dict(serialNumber="1/99"), dict(parallel="Silver"),
                        dict(subset="Paper Prospects"), dict(cardSightIdentity=dict(a["cardSightIdentity"], variationOf=SET)),
                        dict(cardSightIdentity=dict(a["cardSightIdentity"], ordinaryBaseCatalog=False)),
                        dict(cardSightIdentity=dict(a["cardSightIdentity"], autograph=True)),
                        dict(cardSightIdentity=dict(a["cardSightIdentity"], slabbed=True))]:
            with self.subTest(changes=changes):
                self.assertNotIn("unpricedBaseExpiresAt", self.lookup.attach(dict(analysis=dict(attached, **changes)))["analysis"])
        key = self.lookup.key(a)
        with patch("card_lookup.time.time", return_value=snapshot["expiresAt"] + 2):
            self.assertNotIn("unpricedBaseExpiresAt", self.lookup.attach(dict(analysis=attached))["analysis"])
        self.lookup.failed_snapshot(key)
        self.assertNotIn("unpricedBaseExpiresAt", self.lookup.attach(dict(analysis=attached))["analysis"])
        rows = pricing()
        for row in rows["raw"]["records"]:
            row["listing_type"] = "fixed"
        self.lookup.store_snapshot(a, key, rows)
        self.assertEqual(self.lookup.lookup(a)["askingMedianCents"], 100)
        fresh = self.lookup.attach(dict(analysis=attached))["analysis"]
        self.assertNotIn("unpricedBaseExpiresAt", fresh)
        self.assertEqual({r["kind"] for r in fresh["insights"]["marketReferences"]}, {"ask"})

    def test_saved_unpriced_base_gets_allowance_only_after_matching_photo_reinspection(self):
        old = self.lookup.result(detection(), [], self.job)
        (self.job / "refresh.json").write_text(json.dumps(old))
        self.prices["raw"]["records"] = []
        self.lookup.lookup(old["analysis"])
        self.assertNotIn("unpricedBaseExpiresAt", self.lookup.attach(old)["analysis"])
        d = detection()
        d.update(eligibleParallels=[dict(id="base", name="Base")])
        d["card"]["ordinaryBaseCatalog"] = True
        self.resolver.resolve.side_effect = lambda *args: deepcopy(d)
        refreshed = self.lookup.identify(self.job, [])
        self.assertIn("unpricedBaseExpiresAt", self.lookup.attach(refreshed)["analysis"])
        self.assertEqual(refreshed["collection"], old["collection"])
        self.assertEqual([c[0] for c in self.calls], ["GET", "POST"])
        # The same card with a different visible finish must retain its prior
        # assignment and receive no accounting allowance.
        d["card"]["parallelSuggestions"] = [dict(id=PARALLEL, name="Silver", confidence="High")]
        d["eligibleParallels"].append(dict(id=PARALLEL, name="Silver"))
        (self.job / "front.jpg").write_bytes(b"\xff\xd8\xffother-test-front")
        refreshed = self.lookup.identify(self.job, [])
        self.assertEqual(refreshed["analysis"]["cardSightIdentity"], old["analysis"]["cardSightIdentity"])
        self.assertNotIn("unpricedBaseExpiresAt", self.lookup.attach(refreshed)["analysis"])

    def test_selected_variant_first_then_switch_from_same_snapshot(self):
        result = self.lookup.result(detection(), [], self.job)
        orange_rows = pricing(PARALLEL)["raw"]["records"]
        for i, row in enumerate(orange_rows):
            row["price"] *= 9
            row["url"] = f"https://www.ebay.com/itm/{123456789600+i}"
        self.prices["raw"]["records"] += orange_rows
        self.prices["query"].pop("parallel_id")  # Actual unfiltered CardSight response.
        self.lookup.lookup(result["analysis"])
        attached = self.lookup.attach(result)["analysis"]
        self.assertEqual({p["id"]: p.get("medianCents") for p in attached["cardSightVariants"]},
                         {"base": 100, PARALLEL: None})
        self.assertEqual([call.args[0]["parallel"] for call in self.decisions.classify.call_args_list], [None])
        chosen = self.lookup.select(result, PARALLEL)
        self.assertEqual(self.lookup.status(chosen["analysis"]), "empty")
        self.assertEqual(self.lookup.attach(chosen)["analysis"]["insights"]["marketReferences"], [])
        value = self.lookup.lookup(chosen["analysis"])
        self.assertEqual(value["medianCents"], 900)
        self.assertEqual({p["id"]: p.get("medianCents") for p in value["variants"]}, {"base": 100, PARALLEL: 900})
        self.assertEqual(len(self.lookup.attach(chosen)["analysis"]["insights"]["marketReferences"]), 4)
        self.lookup.lookup(chosen["analysis"])
        self.assertEqual(len(self.calls), 1)
        self.assertEqual([call.args[0]["parallel"] for call in self.decisions.classify.call_args_list], [None, "Orange"])
        with self.assertRaises(ValueError): self.lookup.select(result, SET)

    def test_cached_market_evidence_still_checks_card_context(self):
        a = self.analysis()
        self.assertEqual(self.lookup.lookup(a)["medianCents"], 100)
        wrong = deepcopy(a)
        wrong["cardNumber"] = "148"
        self.assertEqual(self.lookup.status(wrong), "unavailable")
        self.assertIsNone(self.lookup.lookup(wrong)["medianCents"])
        self.assertEqual(self.lookup.attach(dict(analysis=wrong))["analysis"]["insights"]["marketReferences"], [])
        self.assertEqual(self.lookup.lookup(a)["medianCents"], 100)
        self.assertEqual(len(self.calls), 2)

    def test_parallel_only_catalog_and_serial_constraints_filter_shared_discovery(self):
        result = self.lookup.result(detection(), [], self.job)
        self.prices["raw"]["records"] = pricing(PARALLEL)["raw"]["records"]
        self.lookup.lookup(result["analysis"])
        a = result["analysis"]
        a["cardSightIdentity"]["eligibleParallelIDs"] = ["base"]
        self.assertEqual([p["id"] for p in self.lookup.attach(result)["analysis"]["cardSightVariants"]], ["base"])
        with self.assertRaises(ValueError): self.lookup.select(result, PARALLEL)
        a["cardSightIdentity"]["isParallelOnly"] = True
        self.assertEqual(self.lookup.attach(result)["analysis"]["cardSightVariants"], [])
        with self.assertRaises(ValueError): self.lookup.select(result, "base")
        del a["cardSightIdentity"]["eligibleParallelIDs"]
        a["serialNumber"] = "5/25"
        with self.assertRaises(ValueError): self.lookup.select(result, PARALLEL)

    def test_pricing_another_variant_does_not_extend_snapshot_expiry(self):
        result = self.lookup.result(detection(), [], self.job)
        self.prices["raw"]["records"] = pricing(PARALLEL)["raw"]["records"]
        self.lookup.lookup(result["analysis"])
        path = self.lookup.cache / (self.lookup.key(result["analysis"]) + ".json")
        snapshot = json.loads(path.read_text())
        expires = time.time() + 300
        snapshot["expiresAt"] = expires
        path.write_text(json.dumps(snapshot))
        chosen = self.lookup.select(result, PARALLEL)
        view = self.lookup.lookup(chosen["analysis"])
        self.assertEqual(json.loads(path.read_text())["expiresAt"], expires)
        self.assertTrue(view["references"])
        self.assertTrue(all(ref["expiresAt"] == expires for ref in view["references"]))

    def test_listing_work_does_not_block_new_recognition_and_same_variant_coalesces(self):
        from concurrent.futures import ThreadPoolExecutor
        a = self.analysis()
        new_job = self.root / "other"
        new_job.mkdir()
        (new_job / "front.jpg").write_bytes(b"\xff\xd8\xffconcurrent")
        entered, release = threading.Event(), threading.Event()

        def classify(target, rows):
            entered.set()
            if not release.wait(3): raise AssertionError("Blocked listing validation")
            return {r["id"]: "match" for r in rows}

        self.decisions.classify.side_effect = classify
        with ThreadPoolExecutor(max_workers=3) as pool:
            first = pool.submit(self.lookup.lookup, a)
            try:
                self.assertTrue(entered.wait(1))
                second = pool.submit(self.lookup.lookup, a)
                lookup = pool.submit(self.lookup.identify, new_job, [])
                self.assertTrue(lookup.result(timeout=1)["analysis"]["identityConfirmed"])
            finally: release.set()
            self.assertEqual(first.result()["medianCents"], second.result()["medianCents"])
        self.assertEqual(self.decisions.classify.call_count, 1)
        self.assertEqual([c[0] for c in self.calls], ["POST", "GET", "POST"])

    def test_queued_legacy_variant_edits_survive_purge_and_v5_price_refresh(self):
        from http.server import ThreadingHTTPServer
        import urllib.request
        from server import handler

        repo = Repository(self.root)
        repo.card_lookup.executor.shutdown(wait=True)
        repo.card_lookup = self.lookup
        self.addCleanup(repo.card_prices.executor.shutdown)
        repo.submit(dict(id=IDENTITY, front=PHOTO, pipeline="match"))
        original = self.lookup.identify(repo.jobroot / IDENTITY, [])
        repo.finish(IDENTITY, original)
        a = original["analysis"]
        path = self.lookup.cache / (self.lookup.key(a) + ".json")
        cutoff = time.time() + 120
        # These were visible to the previous worker's variant picker but never
        # part of the durable recognition result. Do not migrate the prices.
        rows = [dict(id=PARALLEL, name="Orange", medianCents=99999, confidence="High", references=[]),
                dict(id=SET, name="Silver", medianCents=99999, references=[])]
        path.write_text(json.dumps(dict(version=1, pricingVersion=4, expiresAt=cutoff, status="ready",
                                        decisionStatus="completed", variants=rows)))
        self.lookup.purge()
        self.assertTrue(path.exists())
        for refresh_first in (False, True):
            if refresh_first:
                self.lookup.lookup(a)
                self.assertEqual(json.loads(path.read_text())["pricingVersion"], 5)
            offered = self.lookup.attach(original)["analysis"]["cardSightVariants"]
            legacy = next(p for p in offered if p["id"] == PARALLEL)
            self.assertIsNone(legacy.get("medianCents"))
            self.assertIsNone(legacy.get("confidence"))
        restricted = deepcopy(original)
        restricted["analysis"]["cardSightIdentity"]["eligibleParallelIDs"] = ["base"]
        with self.assertRaises(ValueError): self.lookup.select(restricted, PARALLEL)
        numbered = deepcopy(original)
        numbered["analysis"]["serialNumber"] = "3/24"
        with self.assertRaises(ValueError): self.lookup.select(numbered, PARALLEL)
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler(repo, "fixture-token"))
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        revision = "44444444-4444-4444-a444-444444444444"
        try:
            data = json.dumps(dict(id=revision, front=PHOTO, refreshOf=IDENTITY, variantID=PARALLEL)).encode()
            request = urllib.request.Request(f"http://127.0.0.1:{httpd.server_port}/v1/jobs", data=data,
                        headers={"Authorization": "Bearer fixture-token", "Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=3) as response:
                self.assertEqual(response.status, 202)
                self.assertEqual(json.load(response)["id"], revision)
        finally:
            httpd.shutdown(); httpd.server_close(); thread.join(2)
        selected = self.lookup.identify(repo.jobroot / revision, [])["analysis"]
        self.assertEqual(selected["cardSightIdentity"]["parallelID"], PARALLEL)
        self.assertNotIn(SET, {p["id"] for p in selected["cardSightVariants"]})
        self.assertEqual(selected["insights"]["marketReferences"], [])
        with patch("card_lookup.time.time", return_value=cutoff + 1):
            self.assertNotIn(PARALLEL, {p["id"] for p in self.lookup.attach(original)["analysis"]["cardSightVariants"]})
            with self.assertRaises(ValueError): self.lookup.select(original, PARALLEL)

    def test_failed_variant_cannot_remove_a_successful_sibling_price(self):
        result = self.lookup.result(detection(), [], self.job)
        rows = pricing(PARALLEL)["raw"]["records"]
        for i, row in enumerate(rows): row.update(url=f"https://www.ebay.com/itm/{123456789600+i}")
        self.prices["raw"]["records"] += rows
        self.lookup.lookup(result["analysis"])
        orange = self.lookup.select(result, PARALLEL)["analysis"]
        self.decisions.classify.side_effect = OSError("temporary disruption")
        self.assertEqual(self.lookup.lookup(orange)["status"], "unavailable")
        self.assertEqual(self.lookup.status(result["analysis"]), "ready")
        self.assertEqual(self.lookup.lookup(result["analysis"])["medianCents"], 100)
        self.decisions.classify.side_effect = lambda target, rows: {row["id"]: "match" for row in rows}
        self.lookup.lookup_many([orange], retry_unavailable=True)
        self.assertEqual(self.lookup.status(orange), "ready")
        self.assertEqual(len(self.calls), 1)

    def test_bulk_two_owned_variants_share_fetch_and_have_distinct_results(self):
        base = self.lookup.result(detection(), [], self.job)["analysis"]
        d = detection()
        d["card"]["parallelSuggestions"] = [dict(id=PARALLEL, name="Orange", confidence="High")]
        orange = self.lookup.result(d, [], self.job)["analysis"]
        entries = pricing(PARALLEL)["raw"]["records"]
        for i,row in enumerate(entries):
            row.update(price=3, url=f"https://www.ebay.com/itm/{123456789600+i}")
        self.prices["raw"]["records"] += entries
        request = unittest.mock.Mock(return_value=dict(results=[dict(card_id=CARD, success=True, data=self.prices)]))
        self.lookup.client.request = request
        self.lookup.lookup_many([base, orange, base])
        self.assertEqual(self.lookup.lookup(base)["medianCents"], 100)
        self.assertEqual(self.lookup.lookup(orange)["medianCents"], 300)
        self.assertEqual(request.call_count, 1)
        self.assertEqual(self.decisions.classify.call_count, 2)

    def test_unique_high_suggestion_wins_regardless_of_provider_order(self):
        d = detection()
        d["card"]["parallelSuggestions"] = [dict(id=SET, name="Blue", confidence="Low"), dict(id=PARALLEL, name="Orange", confidence="High")]
        a = self.lookup.result(d, [], self.job)["analysis"]
        self.assertTrue(a["identityConfirmed"])
        self.assertEqual(a["cardSightIdentity"]["parallelID"], PARALLEL)
        d["card"]["parallelSuggestions"][0]["confidence"] = "High"
        self.assertFalse(self.lookup.result(d, [], self.job)["analysis"]["identityConfirmed"])

    def test_wrong_context_rejects_every_variant_and_invalid_suggestions_do_not_become_base(self):
        a = self.analysis()
        self.prices["card"]["card_id"] = SET
        self.assertEqual(self.lookup.lookup(a)["status"], "unavailable")
        d = detection(); d["card"]["parallelSuggestions"] = [dict(id="bad", name="Orange", confidence="High")]
        self.assertFalse(self.lookup.result(d, [], self.job)["analysis"]["identityConfirmed"])

    def test_variant_revision_uses_server_owned_identity_and_same_photos(self):
        repo = Repository(self.root)
        repo.card_lookup.executor.shutdown(wait=True)
        repo.card_lookup = self.lookup
        try:
            self.detect["detections"][0]["card"]["parallelSuggestions"] = [dict(id=PARALLEL, name="Orange", confidence="Medium")]
            repo.submit(dict(id=IDENTITY, front=PHOTO, pipeline="match"))
            original = self.lookup.identify(repo.jobroot / IDENTITY, [])
            self.lookup.lookup(original["analysis"])
            repo.finish(IDENTITY, original)
            new_id = "44444444-4444-4444-a444-444444444444"
            repo.submit(dict(id=new_id, front=PHOTO, refreshOf=IDENTITY, variantID=PARALLEL))
            selected = self.lookup.identify(repo.jobroot / new_id, [])
            self.assertEqual(selected["analysis"]["cardSightIdentity"]["parallelID"], PARALLEL)
            self.assertTrue(selected["analysis"]["identityConfirmed"])
            repo.finish(new_id, selected)
            self.lookup.lookup(selected["analysis"])
            self.assertEqual(len(self.calls), 2)
            self.assertEqual(repo.get(IDENTITY)["analysis"]["identityConfirmed"], False)
            with self.assertRaises(ValueError): repo.submit(dict(id=SET, front=PHOTO, refreshOf=IDENTITY, variantID=SET))
            with self.assertRaises(ValueError): repo.submit(dict(id=SET, front=PHOTO, variantID=PARALLEL))
            with self.assertRaises(ValueError): repo.submit(dict(id=SET, front=PHOTO, back=PHOTO, refreshOf=IDENTITY, variantID=PARALLEL))
            self.assertFalse((repo.jobroot / SET).exists())
        finally: repo.card_prices.executor.shutdown(wait=True)

    def test_cached_variant_confidence_does_not_transfer_to_another_photo(self):
        d = detection()
        d["card"]["parallelSuggestions"] = [dict(id=PARALLEL, name="Orange", confidence="High")]
        result = self.lookup.result(d, [], self.job)
        self.prices = pricing(PARALLEL); self.prices["query"]["parallel_id"] = None
        self.lookup.lookup(result["analysis"])
        other = self.lookup.attach(self.lookup.result(detection(), [], self.job))
        orange = next(p for p in other["analysis"]["cardSightVariants"] if p["id"] == PARALLEL)
        self.assertIsNone(orange.get("confidence"))
        self.assertEqual(other["analysis"]["insights"]["marketReferences"], [])
        self.assertEqual(self.lookup.status(other["analysis"]), "empty")
        self.assertEqual(self.lookup.lookup(other["analysis"])["status"], "no_match")

    def test_shared_quota_also_blocks_identification(self):
        self.client.ledger_path.write_text(json.dumps(dict(month=dt.datetime.now(dt.timezone.utc).strftime("%Y-%m"), calls=MONTHLY_CAP, daily=0)))
        with self.assertRaises(MarketError): self.analysis()
        self.assertEqual(self.calls, [])

    def test_cancelled_upload_does_not_identify(self):
        stop = threading.Event(); stop.set()
        with self.assertRaises(InterruptedError): self.lookup.identify(self.job, [], stop)
        self.assertEqual(self.calls, [])

    def test_new_routes_reject_unbounded_or_mixed_price_queries(self):
        params = dict(parallel_id="null", grade_id="null", period="90d", listing_type="auction", limit=25)
        for change in [dict(listing_type="invalid"), dict(grade_id=SET), dict(limit=500), dict(parallel_id="bad")]:
            with self.assertRaises(MarketError): self.client.request("GET", "/v1/pricing/" + CARD, dict(params, **change))
        with self.assertRaises(MarketError): self.client.request("POST", "/v1/identify/card/football", body=b"not-an-image")
        self.assertEqual(self.calls, [])


class DirectPipelineTests(unittest.TestCase):
    def test_both_worker_lanes_bypass_models_and_deliver_cached_prices(self):
        for pipeline, cls in [("full", Worker), ("match", IdentificationWorker), ("fast", IdentificationWorker)]:
            with self.subTest(pipeline=pipeline), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                (root / "config.json").write_text(json.dumps(dict(cardSightIdentifyEnabled=True)))
                repo = Repository(root)
                calls = []
                def transport(method, path, params, body):
                    calls.append(path)
                    return 200, dict(success=True, detections=[detection()]) if method == "POST" else pricing()
                repo.card_lookup.client = Client(root, transport)
                repo.card_lookup.resolver = unittest.mock.Mock()
                repo.card_lookup.resolver.resolve.side_effect = lambda d, *args: d
                repo.card_lookup.decisions = unittest.mock.Mock()
                repo.card_lookup.decisions.classify.side_effect = lambda target, rows: {r["id"]: "match" for r in rows}
                repo.submit(dict(id=IDENTITY, front=PHOTO, pipeline=pipeline))
                stop = threading.Event()
                with patch("server.run_codex", side_effect=AssertionError("Unexpected model call")), patch("server.run_identification", side_effect=AssertionError("Unexpected model call")), patch("server.rank_matches", side_effect=AssertionError("Unexpected Decisions call")):
                    worker = cls(repo, {}, stop); worker.start()
                    try:
                        deadline = time.monotonic() + 4
                        while repo.get(IDENTITY).get("priceStatus") != "ready" and time.monotonic() < deadline: stop.wait(.02)
                        job = repo.get(IDENTITY)
                        self.assertEqual(job["status"], "analyzed")
                        self.assertEqual(job["priceStatus"], "ready")
                        self.assertEqual(len(job["analysis"]["insights"]["marketReferences"]), 4)
                        self.assertEqual(calls, ["/v1/identify/card/football", "/v1/pricing/" + CARD])
                        # Durable job assessments contain identity, not transient sales.
                        with repo.db() as db: saved = json.loads(db.execute("SELECT result FROM jobs WHERE id=?", (IDENTITY,)).fetchone()[0])
                        self.assertEqual(saved["analysis"]["insights"]["marketReferences"], [])
                        self.assertEqual(saved["analysis"]["cardSightIdentity"]["cardID"], CARD)
                    finally:
                        stop.set(); worker.join(timeout=3)
                        repo.card_lookup.executor.shutdown(wait=True)
                        repo.card_prices.executor.shutdown(wait=True)


if __name__ == "__main__": unittest.main()
