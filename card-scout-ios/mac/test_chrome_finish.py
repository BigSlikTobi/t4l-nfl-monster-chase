import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import chrome_finish as chrome


class ChromeFinishTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.job = Path(self.tmp.name)
        (self.job / "back.jpg").write_bytes(b"saved back")
        self.card = dict(id="c", name="Player", year="2025", number="147", releaseName="Topps Chrome", setName="Base")
        self.rows = {"silver": dict(id="silver", name="X-Fractor", numberedTo=None),
                     "pink": dict(id="pink", name="Hot Pink X-Fractor", numberedTo=None),
                     "numbered": dict(id="numbered", name="Football Leather Green Refractor", numberedTo=99)}
        self.catalog = dict(parallelOnly=False, options=self.rows, numberedTo=None)
        self.resolver = Mock()
        self.resolver.parallels.return_value = self.catalog

    def run_surface(self, answers, grid=None, text="", tiers=None):
        self.resolver.choose.side_effect = answers
        retained = dict(variantUnresolved=True, finishState="pending")
        with patch.object(chrome, "grid_hint", return_value=grid):
            return chrome.resolve_surface(self.resolver, None, self.job, b"front", self.card, retained,
                                          tiers or set(), text, {}, None)

    def test_positive_lattice_and_frame_resolve_unnumbered_pink(self):
        result = self.run_surface(["squares"], grid="Hot Pink X-Fractor")
        self.assertEqual(result["finishState"], "verified")
        self.assertEqual(self.card["parallelSuggestions"][0]["id"], "pink")

    def test_measured_grid_without_optical_confirmation_stays_open(self):
        self.assertEqual(self.run_surface(["other"], grid="X-Fractor")["finishState"], "pending")

    def test_no_serial_excludes_numbered_and_printed_refractor_excludes_base(self):
        _, choices = chrome.evidence_choices(self.catalog, self.card, set(), "Back:\nREFRACTOR")
        self.assertNotIn("numbered", choices)
        self.assertNotIn("base", choices)
        _, choices = chrome.evidence_choices(self.catalog, self.card, {99}, "")
        self.assertEqual(set(choices), {"numbered"})

    def test_second_view_only_for_glare_no_repeated_prompt(self):
        self.assertEqual(self.run_surface(["unclear", "glare", "unclear", "angle_glare"])["finishState"], "tilt")
        (self.job / "tilt.jpg").write_bytes(b"second angle")
        self.assertEqual(self.run_surface(["unclear", "glare", "unclear"])["finishState"], "pending")

    def test_plain_fallback_needs_legible_unmarked_back(self):
        self.assertEqual(self.run_surface(["unclear", "plain", "unclear"])["finishState"], "pending")
        self.assertEqual(self.run_surface(["unclear", "plain", "readable_unmarked"])["finishState"], "verified")

    def test_reference_patterns_and_smooth_mark_are_separate(self):
        found = self.run_surface(["Pulsar Refractor"])
        self.assertEqual(found["independentEdition"], "Pulsar Refractor")
        found = self.run_surface(["standard"], text="Back:\nREFRACTOR")
        self.assertEqual(found["independentEdition"], "Refractor")

    def test_missing_evidence_or_pattern_never_prompts_for_tilt(self):
        self.assertEqual(self.run_surface(["other"])["finishState"], "pending")
        (self.job / "back.jpg").unlink()
        self.assertEqual(self.run_surface(["obstructed"])["finishState"], "pending")

    def test_smooth_reference_inspection_requires_agreeing_front_and_back(self):
        options = {"Base": "base", "Refractor": "silver"}
        report = dict(layout="matches_standard_template", frame="matches_standard_frame",
                      field="smooth_ordinary", back="readable_unmarked", serial="no_visible_stamp",
                      frontEvidence="Neutral border and unpatterned field.", backEvidence="Clear number and designation area.")
        self.assertEqual(chrome.smooth_edition(report, options, ""), "base")
        self.assertEqual(chrome.smooth_edition(report, options, "Back:\nREFRACTOR"), "unclear")
        self.assertEqual(chrome.smooth_edition(dict(report, back="printed_refractor"), options, ""), "silver")
        for key, value in (("back", "unreadable"), ("field", "repeated_or_textured"), ("field", "smooth_spectral"),
                           ("frame", "distinctive_parallel_frame"), ("layout", "different"),
                           ("serial", "visible_stamp"), ("frontEvidence", "")):
            self.assertEqual(chrome.smooth_edition(dict(report, **{key: value}), options, ""), "unclear")

    def test_shape_comparison_recovers_wave_from_unconfirmed_grid(self):
        (self.job / "surface.jpg").write_bytes(b"rectified")
        self.rows["wave"] = dict(id="wave", name="RayWave Refractor", numberedTo=None)
        found = self.run_surface(["other", "nested_bands"], grid="X-Fractor")
        self.assertEqual(found["finishState"], "verified")
        self.assertEqual(self.card["parallelSuggestions"][0]["id"], "wave")

    def test_other_shapes_do_not_become_wave_or_request_a_tilt(self):
        (self.job / "surface.jpg").write_bytes(b"rectified")
        self.resolver.inspect_smooth_finish.return_value = {}
        for shape in ("rays", "regular_tiles", "smooth_or_printed", "obscured", "unclear"):
            with self.subTest(shape=shape):
                result = self.run_surface(["other", shape])
                self.assertEqual(result["finishState"], "pending")
        result = self.run_surface(["unclear"], tiers={99})
        self.assertEqual(result["finishState"], "pending")

    def test_second_inspection_must_agree_with_tilt_prompt(self):
        (self.job / "surface.jpg").write_bytes(b"rectified")
        self.resolver.inspect_smooth_finish.return_value = {"field": "repeated_or_textured"}
        result = self.run_surface(["obstructed", "unclear", "angle_glare", "obscured"])
        self.assertEqual(result["finishState"], "pending")
        self.resolver.inspect_smooth_finish.return_value = {"field": "obscured_by_reflection"}
        result = self.run_surface(["obstructed", "unclear", "angle_glare", "obscured"])
        self.assertEqual(result["finishState"], "tilt")
