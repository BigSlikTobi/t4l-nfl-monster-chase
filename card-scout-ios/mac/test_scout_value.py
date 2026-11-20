from datetime import datetime, timezone
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from scout_value import Example, INITIAL_WEIGHT, ScoutValueModel, blend, snapshot_market, tune


def examples():
    return [Example(f"card-{group}-{card}", "nfl", (group, "base"), (("2026-10-01", 100),),
                    (("2026-10-01", sold), ("2026-11-01", sold)))
            for group, sold in enumerate((50, 100, 150)) for card in range(12)]


class ScoutValueTests(unittest.TestCase):
    def test_legacy_bowman_snapshot_uses_the_matching_market_only(self):
        for family, number, expected in (
                ("Prospects", "BPP-72", "college"), ("Chrome Prospects", "BCP-43", "college"),
                ("Gen Next", "GN-16", "college"), ("Base Set", "72", "nfl"),
                ("Chrome", "BCV-69", "nfl"), ("Chrome Prospects", "BPP-72", "unspecified"),
        ):
            snapshot = {"data": {"card": {"number": number, "set": {"year": "2026", "release": "Bowman", "name": family}}}}
            self.assertEqual(snapshot_market(snapshot, "unspecified"), expected)
            self.assertIsNone(snapshot_market(snapshot, None))

    def test_variant_weight_shrinks_toward_the_overall_ratio(self):
        self.assertAlmostEqual(blend(0.74, [0.95] * 28, 56), 0.81)
        self.assertAlmostEqual(blend(0.74, [0.95] * 10, INITIAL_WEIGHT), 0.845)
        self.assertEqual(blend(0.74, [], INITIAL_WEIGHT), 0.74)

    def test_tuning_requires_enough_later_sales_and_meaningful_improvement(self):
        data = examples()
        self.assertEqual(tune(data, INITIAL_WEIGHT, "2026-10-19"), 2)
        self.assertEqual(tune(data, 2, "2026-10-19"), 2)
        self.assertIsNone(tune(data[:20], INITIAL_WEIGHT, "2026-10-19"))
        self.assertIsNone(tune(data, INITIAL_WEIGHT, "2026-11-10"))

    def test_tuning_increases_the_weight_when_variant_differences_fade(self):
        data = [Example(row.card, row.market, row.group, row.asks, (row.sales[0], ("2026-11-01", 100)))
                for row in examples()]
        self.assertEqual(tune(data, INITIAL_WEIGHT, "2026-10-19"), 160)

    def test_selected_weight_survives_restart_without_saving_examples(self):
        with TemporaryDirectory() as folder:
            root = Path(folder)
            now = datetime(2026, 11, 18, tzinfo=timezone.utc).timestamp()
            with patch("scout_value.time.time", return_value=now):
                model = ScoutValueModel(root, root, lambda _: None)
                with patch.object(model, "_load_examples", return_value=(examples(), now + 100)):
                    self.assertIsNotNone(model.factor("new-card", "nfl", (0, "base")))
                    self.assertIsNone(model.factor("new-card", "college", (0, "base")))
                self.assertEqual(json.loads(model.state_path.read_text()), {"weight": 2, "checkedAt": "2026-11-18"})
                restarted = ScoutValueModel(root, root, lambda _: None)
                self.assertIsNone(restarted.factor("new-card", "nfl", (0, "base")))
                self.assertEqual(restarted.weight, 2)
