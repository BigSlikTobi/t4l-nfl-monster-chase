import base64
from io import BytesIO
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import edition_review
from card_lookup import CardLookup
from test_card_lookup import CARD, SET, PARALLEL


class EditionReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.resolver = Mock()
        self.lookup = CardLookup(self.root)
        self.addCleanup(self.lookup.executor.shutdown)

    def finish(self, release, answers, options, text="", serial=None, tilt=False):
        year, brand, name = edition_review.RELEASES[release]
        card = dict(id=CARD, releaseId=release, setId=SET, name="Fixture Player", number="17",
                    setName="Base Set", year=year, manufacturer=brand, releaseName=name)
        self.resolver.parallels.return_value = dict(parallelOnly=False, numberedTo=None, options=options)
        self.resolver.choose.reset_mock()
        self.resolver.choose.side_effect = answers if isinstance(answers, list) else None
        self.resolver.choose.return_value = answers if isinstance(answers, str) else "unclear"
        (self.root / "back.jpg").write_bytes(b"fixture back")
        if tilt:
            (self.root / "tilt.jpg").write_bytes(b"fixture")
        retained = dict(confidence="High", card=card, eligibleParallels=[], variantUnresolved=True, observedSerial=serial)
        return edition_review.resolve(self.resolver, Mock(), self.root, b"fixture", card, retained,
                                      {int(serial.split("/")[1])} if serial else set(), text, {}, None)

    def test_numbered_select_requires_photo_and_printed_level_and_survives_result_mapping(self):
        options = {PARALLEL: dict(id=PARALLEL, name="White Prizm Shock", numberedTo=799)}
        result = self.finish(edition_review.SELECT, PARALLEL, options, "Back: No. 17\nCLUB LEVEL", "3/799")
        self.assertEqual(set(self.resolver.choose.call_args.args[3]), {PARALLEL})
        output = self.lookup.result(result, [], self.root)
        self.assertTrue(output["analysis"]["identityConfirmed"])
        self.assertEqual(output["collection"]["subset"], "Club Level")
        self.assertEqual(output["analysis"]["serialNumber"], "3/799")
        self.assertEqual(self.finish(edition_review.SELECT, "unclear", options, "Back: CLUB LEVEL", "3/799")["finishState"], "pending")
        self.assertEqual(self.finish(edition_review.SELECT, PARALLEL, options, "Back: No. 17", "3/799")["finishState"], "pending")

    def test_full_catalog_even_without_suggestions_and_optical_tilt_only_once(self):
        options = {PARALLEL: dict(id=PARALLEL, name="Pink Holo Foil", numberedTo=1200)}
        result = self.finish(edition_review.FLAGSHIP, PARALLEL, options)
        self.assertEqual(result["card"]["parallelSuggestions"][0]["id"], PARALLEL)
        self.assertEqual(self.finish(edition_review.BOWMAN, "unclear", options)["finishState"], "pending")
        self.assertEqual(self.finish(edition_review.FLAGSHIP, ["unclear", "tilt"], options)["finishState"], "tilt")
        self.finish(edition_review.FLAGSHIP, "unclear", options, tilt=True)
        self.assertNotIn("tilt", self.resolver.choose.call_args.args[3])

    def test_card_back_number_is_independent_of_keyboard_jersey_and_statistics(self):
        for sample, expected in [("Back:\n40\nYEAR\n2025", "40"), ("Rückseite: Name\nВСР•143", "BCP-143"),
                                 ("Back: No. 263\nCLUB LEVEL\n736/799", "263"), ("Back: Name\nBPPº66", "BPP-66"),
                                 ("Back: Name\nNFLS-37", "NFLS-37"), ("Back: Card No. TP-14A", "TP-14A"),
                                 ("Back: 91TF-\n35", "91TF-35"), ("Back: 91TF–24", "91TF-24"),
                                 ("Back: 09-12", None), ("Back: 91TF-\n2025", None),
                                 ("Back: COLLEGE\n2025\n68", None), ("Back: 40\nBCV-40", None)]:
            with self.subTest(sample=sample):
                self.assertEqual(edition_review.printed_number("Front: CCT-190\n" + sample), expected)

    def test_bowman_back_is_independent_of_an_unrelated_front_stock_code(self):
        from identity_decisions import ocr_conflicts
        card = dict(releaseId=edition_review.BOWMAN, releaseName="Bowman", setName="Base Set", year="2026", number="102")
        self.assertFalse(ocr_conflicts(card, "Front: Player\nCCT 190\nBack: 102\nBOWMAN BRIEFING"))
        self.assertTrue(ocr_conflicts(card, "Front: Card number 103\nBack: 102\nBOWMAN BRIEFING"))

    def test_flagship_narrows_large_catalog_by_pattern_and_can_recover_outside_shortlist(self):
        names = ["Pink Diamante Foil", "Green Diamante Foil", "Pink Holo Foil", "Green Holo Foil",
                 "Gold Football", "Football", "Aqua Rainbow Foil", "Rainbow Foil", "Camo", "Canvas"]
        options = {f"{i:08x}-1111-4111-a111-111111111111": dict(
            id=f"{i:08x}-1111-4111-a111-111111111111", name=name, numberedTo=None) for i, name in enumerate(names)}
        first = next(iter(options))
        calls = self.resolver.choose
        result = self.finish(edition_review.FLAGSHIP, ["holo", "unclear", first], options)
        self.assertEqual([call.args[-1] for call in calls.call_args_list], ["finish_family", "catalog_finish", "catalog_retry"])
        self.assertEqual({option["name"] for option in calls.call_args_list[1].args[3].values()},
                         {"Pink Holo Foil", "Green Holo Foil"})
        self.assertEqual(result["card"]["parallelSuggestions"][0]["id"], first)
        self.assertEqual(len(result["eligibleParallels"]), 11)
        self.assertEqual(self.finish(edition_review.FLAGSHIP, ["holo", "unclear", "unclear"], options)["finishState"], "pending")

    def test_physical_stamp_filters_both_attempts_and_back_designation_is_rechecked(self):
        gold = "22222222-2222-4222-a222-222222222222"
        options = {PARALLEL: dict(id=PARALLEL, name="Pink Holo Foil", numberedTo=250),
                   gold: dict(id=gold, name="Gold Football", numberedTo=50)}
        result = self.finish(edition_review.FLAGSHIP, ["unclear", "unclear"], options, "Back: Pink Holo Foil", "3/50")
        for call in self.resolver.choose.call_args_list:
            self.assertEqual(set(call.args[3]), {gold})
        self.assertTrue(result["variantUnresolved"])
        self.finish(edition_review.FLAGSHIP, ["unclear", "unclear"], options, "Back: Pink Holo Foil")
        self.assertEqual(set(self.resolver.choose.call_args_list[0].args[3]), {PARALLEL})
        self.assertIn(gold, self.resolver.choose.call_args_list[1].args[3])

    def test_reviewed_reference_requires_exact_release_subset_and_finish(self):
        card = dict(releaseId=edition_review.FLAGSHIP, releaseName="Topps Flagship Football",
                    manufacturer="Topps", year="2026", setName="Base Set", name="Fixture Player", number="17")
        base = dict(year=2026, brand="Topps", product="Topps Flagship", subset="Base", parallel=None,
                    player="Fixture Player", number="17")
        scopes = [dict(base, number="18"), dict(base, year=2025), dict(base, subset="NFL Stars"),
                  dict(base, parallel="Pink Holo Foil"), base]
        rows = [dict(identity=scope) for scope in scopes]
        with patch("reference_images.load", return_value={"records": rows}), patch(
            "scan_matches.reviewed_front", return_value={"type": "input_image", "image_url": "fixture"}
        ) as fetch:
            result = edition_review.reviewed_examples(self.root, card, {"base": {"name": "Base"}})
        fetch.assert_called_once_with(rows[-1])
        self.assertIn("same card", result[0]["text"])

    def test_retry_crops_show_the_outer_regions_without_changing_original(self):
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Pillow is installed with the worker")
        path = self.root / "card.png"
        image = Image.new("RGB", (300, 420), "black")
        image.paste("red", (0, 0, 300, 105))
        image.paste("blue", (0, 315, 300, 420))
        image.save(path)
        original = path.read_bytes()
        for back, expected_size in [(True, (300, 218)), (False, (158, 420))]:
            _, content = edition_review.edge_detail(path, back=back)
            pixels = base64.b64decode(content["image_url"].split(",", 1)[1])
            with Image.open(BytesIO(pixels)) as crop:
                self.assertEqual(crop.size, expected_size)
                self.assertGreater(crop.getpixel((20, 20))[0], 240)
                self.assertGreater(crop.getpixel((20, crop.height - 20))[2], 240)
        self.assertEqual(path.read_bytes(), original)
