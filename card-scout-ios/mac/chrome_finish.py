"""Resolve 2025 Chrome Football surfaces independently of the provider's guesses."""
from functools import lru_cache
import base64
import json
from pathlib import Path
import re

from cardsight import normal

RELEASE = "3e03e10a-8fbe-4d3e-b4e7-20553aff89c7"
POLICY = "chrome-football-2025-v3"
SOURCE = "https://cdn.shopify.com/s/files/1/0662/9749/5709/files/2025_Topps_Chrome_Football_Odds.pdf?v=1776193199"
GRID_NAMES = {"pink": "Hot Pink X-Fractor", "lime": "Lime Green X-Fractor",
              "no dominant pink or lime": "X-Fractor"}
PATTERNS = {
    "Base": "Standard issue for this specific subset. Plain factory chrome with ordinary photographic reflection, standard border, no parallel pattern. Insert artwork itself is not a foil pattern.",
    "Refractor": "Smooth continuous rainbow/prismatic sheen, no repeated pattern. A back marked REFRACTOR is positive evidence when the front agrees.",
    "X-Fractor": "Large repeating square checkerboard across the card background, with silver/neutral outer foil border.",
    "Hot Pink X-Fractor": "Same repeating checkerboard with a sustained hot pink outer frame on multiple edges.",
    "Lime Green X-Fractor": "Same repeating checkerboard with a sustained bright lime outer frame on multiple edges.",
    "RayWave Refractor": "Repeated, broad parallel foil bands that bend into nested U or S curves. The bands recur behind the player and along the frame. Look for the same curved contours in multiple exposed areas of neutral foil.",
    "Geometric Refractor": "A repeated angular geometric motif distinct from large regular checkerboard squares.",
    "Prism Refractor": "Distinct faceted prismatic foil across the background, not just light reflected by smooth chrome.",
    "Neon Pulse Refractor": "Many thin, straight colored rays fan outward on the outer frame. The field behind the player does not repeat the same broad curved bands.",
    "Topps Refractor": "A repeating Topps logo motif in the surface.",
    "Pulsar Refractor": "A field of repeated fine pulsating dots/discs in the foil.",
    "Football Leather Refractor": "Distinct football hide or pebbled texture, not photographic grain.",
    "Red/White/Blue Refractor": "Three-colored foil background or framing, independent of the player's uniform.",
}
FEATURE_CHECKS = {
    "lattice": ("Look only at the card surface. Do large regular foil squares alternate across the background on both sides of the player? Ignore the mat, text, logos, tiny dots and photographic pixels.", "surface.jpg"),
    "field": ("Describe the visible background and outer frame of the card. Look away from the uniform and printed colored team-name graphics. Inspect the actual foil texture. Select the observation visible in the card.", "surface.jpg"),
    "backmark": ("Read the card back. Look for a separate, printed REFRACTOR designation. Select readable_unmarked only if the margins and the area near the number are present, legible and have no such designation. Choose unclear if cropped, blurred or obscured.", "back.jpg"),
}
TILT = "tilt_front"
TILT_RULE = ("The existing view has glare or a flat angle that specifically hides the optical difference "
             "between two visually plausible finishes. A slight change of lighting angle would settle them. "
             "Never choose this for missing catalog coverage, wrong card, unreadable text or missing serial.")

def catalog_file(root, filename):
    installed = root / filename
    return installed if installed.is_file() else Path(__file__).parent / "data" / filename

@lru_cache(maxsize=4)
def checklist(root):
    data = json.loads(catalog_file(root, "chrome-checklist-supplement.json").read_text())
    return [(row["player"], row["number"], group["subset"]) for group in data["collections"]
            if not group.get("parallel") for row in group["cards"]]

def printed_row(text, root):
    sides = re.split(r"(?im)^\s*(?:back|rückseite)\s*:\s*", text, maxsplit=1)
    if len(sides) != 2:
        return None
    back = sides[1]
    words = " " + normal(back) + " "
    if "topps chrome" not in words or not re.search(r"\bNFL(?:PA)?\b", back, re.I):
        return None
    lines = {normal(line) for line in back.splitlines()}
    hits = {(name, num, subset) for name, num, subset in checklist(root)
            if normal(num) in lines and " " + normal(name) + " " in words}
    return next(iter(hits)) if len(hits) == 1 else None

def grid_hint(job):
    crop = job / "surface.jpg"
    if not crop.exists():
        return None
    try:
        from surface_grid import measure
        status, color, *_ = measure(crop)
    except (ImportError, OSError, ValueError):
        return None
    return GRID_NAMES.get(color) if status == "grid" else None

def evidence_choices(catalog, card, tiers, text):
    options = dict(catalog["options"])
    if not catalog["parallelOnly"] and not card.get("isParallelOnly"):
        options["base"] = dict(id="base", name="Base", numberedTo=catalog["numberedTo"])
    mark = bool(re.search(r"(?im)^\s*REFRACTOR\s*$", text))
    variants = {}
    for key, row in options.items():
        label, run = row["name"], row.get("numberedTo")
        # Some catalog entries omit the run on known numbered colors.
        if tiers:
            if run not in tiers:
                continue
        elif run is not None or label not in PATTERNS:
            continue
        if mark and key == "base":
            continue
        variants[key] = dict(name=label, numberedTo=run,
                             visualEvidence=PATTERNS.get(label, "Require this printed serial tier and the specific color AND texture, e.g. wave versus smooth."))
    return options, variants

REFERENCE_PATTERNS = ("Pulsar Refractor", "Prism Refractor", "Football Leather Refractor",
                      "Neon Pulse Refractor", "RayWave Refractor")


@lru_cache(maxsize=4)
def reference_plate(root, inserts=False):
    name = "chrome-insert-surfaces.jpg" if inserts else "chrome-finish-surfaces.jpg"
    return jpeg_reference(root, name)


@lru_cache(maxsize=4)
def jpeg_reference(root, name):
    try:
        data = catalog_file(root, name).read_bytes()
    except OSError:
        return None
    if not data.startswith(b"\xff\xd8\xff") or len(data) > 500_000:
        return None
    return dict(type="input_image", image_url="data:image/jpeg;base64," + base64.b64encode(data).decode())


INSPECTION_FIELDS = {
    "layout": ["matches_standard_template", "different", "unclear"],
    "frame": ["matches_standard_frame", "distinctive_parallel_frame", "unclear"],
    "field": ["smooth_ordinary", "smooth_spectral", "repeated_or_textured", "obscured_by_reflection", "unclear"],
    "back": ["readable_unmarked", "printed_refractor", "other_mark", "unreadable"],
    "serial": ["visible_stamp", "no_visible_stamp", "unreadable"],
}
INSPECTION_SCHEMA = dict(type="object", additionalProperties=False,
    properties={**{k: dict(type="string", enum=v) for k, v in INSPECTION_FIELDS.items()},
                "frontEvidence": dict(type="string"), "backEvidence": dict(type="string")},
    required=[*INSPECTION_FIELDS, "frontEvidence", "backEvidence"])


def smooth_edition(report, by_name, text):
    if not isinstance(report, dict) or any(report.get(k) not in v for k, v in INSPECTION_FIELDS.items()):
        return "unclear"
    if (not all(isinstance(report.get(k), str) and report[k].strip() for k in ("frontEvidence", "backEvidence"))
            or report["serial"] != "no_visible_stamp" or report["layout"] != "matches_standard_template"
            or report["frame"] != "matches_standard_frame" or report["field"] not in ("smooth_ordinary", "smooth_spectral")):
        return "unclear"
    if report["back"] == "printed_refractor":
        return by_name.get("Refractor", "unclear")
    if (report["back"] == "readable_unmarked" and report["field"] == "smooth_ordinary"
            and not re.search(r"(?im)^\s*REFRACTOR\s*$", text)):
        return by_name.get("Base", "unclear")
    return "unclear"


def compare_unstamped(resolver, job, image, evidence, by_name, diagnostic):
    # Observe the foil first. A printed REFRACTOR mark distinguishes smooth editions
    # that can have the same appearance under a single light.
    choices = {
        "standard": dict(observation="Exposed smooth ordinary Chrome frame and field match the standard example. "
                         "Printed team graphics, small isolated reflections and insert decoration are normal."),
        "rainbow": dict(observation="Smooth foil with broad continuous spectral diffraction over the surface."),
        "obstructed": dict(observation="A specular reflection specifically obscures the otherwise smooth finish."),
        "other": dict(observation="Another pattern, tinted frame, variant artwork, or insufficient detail."),
    }
    for label in REFERENCE_PATTERNS:
        if label in by_name:
            choices[label] = dict(observation=PATTERNS[label])
    observed = resolver.choose(job, image, evidence, choices, "reference_surface")
    diagnostic["referenceSurface"] = observed
    if observed in REFERENCE_PATTERNS:
        return by_name.get(observed, "unclear")
    if observed == "unclear":
        # A focused comparison omits the competing patterned options.
        field = resolver.choose(job, image, evidence, {
            "plain": dict(appearance="Exposed, ordinary Chrome matches the standard surface and frame in the photos."),
            "rainbow": dict(appearance="Smooth foil with a broad, unbroken spectral band."),
            "pattern": dict(appearance="Repeated texture, colored outer frame or other design."),
            "glare": dict(appearance="A reflection obscures the otherwise smooth foil.")
        }, "field")
        diagnostic["field"] = field
        observed = {"plain":"standard", "glare":"obstructed"}.get(field, field)
    if observed not in ("standard", "rainbow", "obstructed"):
        return "unclear"
    sides = re.split(r"(?im)^\s*(?:back|rückseite)\s*:\s*", evidence["printedText"], maxsplit=1)
    marked = len(sides) == 2 and re.search(r"(?im)^\s*REFRACTOR\s*$", sides[1])
    mark = "marked" if marked else resolver.choose(job, image, evidence, {
        "readable_unmarked": dict(observation="The intact number and designation area are legible; no separate REFRACTOR mark."),
        "marked": dict(observation="A separate printed word REFRACTOR is visible.")
    }, "backmark") if (job / "back.jpg").is_file() else "unclear"
    diagnostic["backMark"] = mark
    if observed in ("standard", "rainbow") and mark == "marked":
        return by_name.get("Refractor", "unclear")
    if observed == "standard" and mark == "readable_unmarked":
        return by_name.get("Base", "unclear")
    # Only offer a tilt to distinguish this particular pair. Missing catalog
    # entries, a missing back or a possible complex pattern cannot trigger it.
    if (observed == "obstructed" and mark != "marked" and (job / "back.jpg").is_file()
            and not (job / "tilt.jpg").exists() and {"Base", "Refractor"} <= by_name.keys()):
        need = resolver.choose(job, image, evidence, {
            "angle_glare": dict(appearance=TILT_RULE + " The two candidates are standard and smooth Refractor."),
            "keep": dict(appearance="Another angle would not distinguish those two candidates here.")
        }, "optics")
        if need == "angle_glare":
            diagnostic["tiltCandidates"] = ["Base", "Refractor"]
            return TILT
    return "unclear"


def resolve_surface(resolver, client, job, image, card, retained, tiers, text, diagnostic, stop):
    catalog = resolver.parallels(client, card, stop)
    options, variants = evidence_choices(catalog, card, tiers, text)
    retained["eligibleParallels"] = [{k:v.get(k) for k in ("id","name","numberedTo")} for v in options.values()]
    card["ordinaryBaseCatalog"] = catalog.get("ordinaryBaseCatalog", False)
    card["isParallelOnly"] = catalog["parallelOnly"] or card.get("isParallelOnly") is True
    if len(variants) > 90:
        return retained
    grid = grid_hint(job)
    visual_options = dict(variants)
    # Reviewed print families exist even when a provider has no UUID for this copy.
    # Record an independent edition only with positive visual evidence; never price it by the base ID.
    main = card["setName"] in ("Base", "Base Set")
    supported = {"Base", "Refractor", "X-Fractor"} if card["setName"] == "Future Stars" else set()
    if main:
        supported = {"Refractor", *GRID_NAMES.values(), *REFERENCE_PATTERNS}
    present = {r["name"] for r in variants.values()}
    if not tiers and not card["isParallelOnly"] and not card.get("variationOf"):
        for label in sorted(supported - present - {"Base"}):
            visual_options["edition-" + label] = dict(name=label, visualEvidence=PATTERNS[label])
    evidence = dict(card={k:card[k] for k in ("name","year","number","releaseName","setName")},
                    printedText=text, observedSerialRuns=sorted(tiers))
    if not visual_options:
        return retained
    by_name = {row["name"]: key for key, row in visual_options.items() if "name" in row}
    if grid and grid in by_name:
        lattice = resolver.choose(job, image, evidence, {
            "squares": dict(appearance="Large repeated two-dimensional checkerboard in the foil."),
            "other": dict(appearance="Other texture, fine dots, printed image, reflections, or smooth foil.")
        }, "lattice")
        diagnostic["lattice"] = lattice
        selected = by_name[grid] if lattice == "squares" else "unclear"
    elif not tiers and not grid and not card.get("variationOf") and (
            main or card["setName"] in ("1975 Topps", "Fortune 15", "Future Stars", "Legends of the Gridiron")):
        selected = compare_unstamped(resolver, job, image, evidence, by_name, diagnostic)
    else:
        selected = resolver.choose(job, image, evidence, visual_options, "surface")
        if visual_options.get(selected, {}).get("name") in GRID_NAMES.values():
            selected = "unclear"
    # A grid spectrum measures spacing, not shape. Curved bands can also be periodic.
    # Reinspect an inconclusive main-set front against whole-card examples.
    wave = "RayWave Refractor"
    if (selected in ("unclear", TILT) and main and not tiers and wave in by_name
            and not card.get("variationOf") and not card["isParallelOnly"] and (job / "surface.jpg").is_file()):
        shape = resolver.choose(job, image, evidence, {
            "nested_bands": dict(observation=PATTERNS[wave] + " No sustained colored border, stamped number or competing motif."),
            "rays": dict(observation=PATTERNS["Neon Pulse Refractor"]),
            "regular_tiles": dict(observation="Squares, facets or repeated dots; edges stay straight or form discrete cells."),
            "smooth_or_printed": dict(observation="Smooth foil, light streak, or waves confined to printed artwork."),
            "obscured": dict(observation="The shape of the foil cannot be seen well enough.")
        }, "foil_shape")
        diagnostic["foilShape"] = shape
        if shape == "nested_bands":
            selected = by_name[wave]
        elif shape in ("rays", "regular_tiles") and selected == TILT:
            selected = "unclear"
    if (selected in ("unclear", TILT) and not tiers and not grid and not card.get("variationOf")
            and (job / "surface.jpg").is_file() and (job / "back.jpg").is_file()
            and (main or card["setName"] in ("1975 Topps", "Fortune 15", "Future Stars", "Legends of the Gridiron"))):
        try:
            inspection = resolver.inspect_smooth_finish(job, card["setName"], stop)
        except InterruptedError:
            raise
        except (OSError, ValueError, KeyError, RuntimeError):
            inspection = {}
        decided = smooth_edition(inspection, by_name, text)
        diagnostic["referenceInspection"] = {k: inspection[k] for k in INSPECTION_FIELDS if isinstance(inspection, dict) and k in inspection}
        if decided != "unclear":
            selected = decided
        elif selected == TILT and diagnostic["referenceInspection"].get("field") != "obscured_by_reflection":
            selected = "unclear"
    diagnostic["surfaceMeasurement"] = grid or "inconclusive"
    if selected == TILT:
        retained["finishState"] = "tilt"
        return retained
    if selected == "unclear":
        return retained
    name = visual_options[selected]["name"]
    if grid and grid != name and diagnostic.get("foilShape") != "nested_bands":
        return retained
    # Unstamped numbered rarities can never enter the unnumbered branch.
    row = options.get(selected)
    if row and row.get("numberedTo") is not None and row["numberedTo"] not in tiers:
        return retained
    result = dict(retained, variantUnresolved=False, finishState="verified")
    if selected.startswith("edition-"):
        result["independentEdition"] = name
    card["parallelSuggestions"] = [dict(row,confidence="High")] if row and selected != "base" else []
    diagnostic.update(parallel="surface_verified", cardID=card["id"], finish=name)
    return result

@lru_cache(maxsize=1)
def standard_references(root):
    from reference_images import load
    manifest = load(catalog_file(root, "reference-images.json"))
    return [row for row in manifest["records"] if row["identity"]["product"] == "Topps Chrome"
            and row["identity"]["year"] == 2025 and row["identity"]["brand"] == "Topps"
            and row["identity"]["parallel"] is None]


@lru_cache(maxsize=12)
def reference_front(root, subset, number, player):
    from scan_matches import reference_content
    records = [row for row in standard_references(root) if row["identity"]["subset"] == subset]
    if not records:
        return []
    exact = next((r for r in records if r["identity"]["number"] == number and normal(r["identity"]["player"]) == normal(player)), None)
    ref = exact or records[0]
    key = ref["identity"]
    entry = dict(player=key["player"], number=key["number"], referenceImage=dict(ref, **key))
    collection = dict(id=key["collectionID"], year=2025, brand="Topps", name="Topps Chrome", subset=subset, cards=[entry])
    blocks = reference_content([(0, dict(collectionID=collection["id"],number=entry["number"]))], [collection], {})
    if blocks:
        blocks[0] = dict(type="input_text", text="Reviewed STANDARD issue reference for the same subset. "
                         + ("Same checklist entry." if exact else "Different player. Compare only surface and frame."))
    return blocks
