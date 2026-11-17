from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock

from card_lookup import CardLookup, RESOLUTION_ERROR_COOLDOWN
from identity_decisions import IdentityResolver
from test_identity_decisions import card


class ValidationCacheTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.job = self.root / "scan"
        self.job.mkdir()
        (self.job / "front.jpg").write_bytes(b"front")
        self.client = Mock()
        self.client.request.return_value = dict(success=True, detections=[dict(card=card(), confidence="High")])

    def lookup(self, resolver):
        lookup = CardLookup(self.root, client=self.client, resolver=resolver)
        self.addCleanup(lookup.executor.shutdown)
        return lookup

    def test_back_changes_recheck_identity_but_reuse_front_recognition(self):
        resolver = Mock()
        resolver.resolve.return_value = {}
        lookup = self.lookup(resolver)
        lookup.identify(self.job, [])
        for pixels in (b"first back", b"retake", b"retake"):
            (self.job / "back.jpg").write_bytes(pixels)
            lookup.identify(self.job, [])
        self.assertEqual(resolver.resolve.call_count, 3)
        self.client.request.assert_called_once()

    def test_new_provider_candidates_invalidate_a_still_fresh_resolution(self):
        resolver = Mock()
        resolver.resolve.return_value = {}
        lookup = self.lookup(resolver)
        lookup.identify(self.job, [])
        path, = lookup.cache.glob("photo-*.json")
        value = json.loads(path.read_text())
        value["expiresAt"] = time.time() - 1
        path.write_text(json.dumps(value))
        self.client.request.return_value = dict(success=False, detectedCount=1, identifiedCount=0)
        lookup.identify(self.job, [])
        self.assertEqual(resolver.resolve.call_count, 2)
        self.assertEqual(resolver.resolve.call_args.args[0], {"noDetection": True})

    def test_decisions_timeout_has_short_cooldown_and_reuses_recognition_on_retry(self):
        def answer(payload):
            q = payload["questions"][0]
            return dict(answers=[dict(name=q["name"], type="choice", choice="unclear", probabilities=[
                dict(value=c["value"], probability=int(c["value"] == "unclear")) for c in q["choices"]])])
        transport = Mock(side_effect=[TimeoutError(), None])
        lookup = self.lookup(IdentityResolver(self.root, transport))
        a = lookup.identify(self.job, [])["analysis"]
        self.assertFalse(a["identityConfirmed"])
        path, = lookup.cache.glob("resolved-*.json")
        failed = json.loads(path.read_text())
        self.assertLessEqual(failed["expiresAt"] - time.time(), RESOLUTION_ERROR_COOLDOWN)
        lookup.identify(self.job, [])
        self.assertEqual(transport.call_count, 1)
        failed["expiresAt"] = time.time() - 1
        path.write_text(json.dumps(failed))
        transport.side_effect = answer
        lookup.identify(self.job, [])
        self.assertEqual(transport.call_count, 2)
        self.client.request.assert_called_once()
        self.assertGreater(json.loads(path.read_text())["expiresAt"] - time.time(), 3600)

    def test_only_unambiguous_empty_recognition_permits_ocr_only_search(self):
        self.assertEqual(CardLookup.foreground(dict(success=False, detectedCount=1, identifiedCount=0)), {"noDetection": True})
        self.assertEqual(CardLookup.foreground(dict(success=True, detections=[])), {"noDetection": True})
        for body in (dict(success=False, detectedCount=2, identifiedCount=0),
                     dict(success=True, detections=[dict(zIndex=0), dict(zIndex=0)]),
                     dict(success=False), dict(success=False, detectedCount=1, identifiedCount=1)):
            self.assertEqual(CardLookup.foreground(body), {})

    def test_independent_workers_share_one_cache_fill_and_cancel_can_exit(self):
        entered = threading.Event()
        release = threading.Event()
        resolver = Mock()
        def wait(*args):
            entered.set()
            self.assertTrue(release.wait(3))
            return {}
        resolver.resolve.side_effect = wait
        first, second = self.lookup(resolver), self.lookup(resolver)
        with ThreadPoolExecutor(max_workers=3) as pool:
            try:
                a = pool.submit(first.identify, self.job, [])
                self.assertTrue(entered.wait(3))
                stop = threading.Event()
                cancelled = pool.submit(second.identify, self.job, [], stop)
                stop.set()
                with self.assertRaises(InterruptedError): cancelled.result(2)
                b = pool.submit(second.identify, self.job, [])
            finally:
                release.set()
            self.assertEqual(a.result(2), b.result(2))
        self.client.request.assert_called_once()
        resolver.resolve.assert_called_once()
