"""Front -> immutable CardSight UUID -> Decisions-matched sold/asking evidence."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from copy import deepcopy
import datetime as dt
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
import hashlib
import json
import re
import sold_search
import statistics
import threading
import time

from analysis import bowman_license_scope, identity_conflict, product_license_evidence, repair_confirmed_bowman_license
from cardsight import Client, MarketError, CACHE_SECONDS, atomic, cache_work, normal, sale_url
from listing_decisions import ListingDecisions, DecisionError
from identity_decisions import IdentityResolver, VERSION as RESOLVER_VERSION
from scout_value import ScoutValueModel, market_scope, snapshot_market

UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
RESOLUTION_ERROR_COOLDOWN = 30
# CardSight's 2026 Topps Flagship Base Set. The unnumbered Football finish and
# each numbered color have different catalog IDs.
FLAGSHIP_2026_BASE_SET = "1d529543-0e41-4bdb-b3ff-437eb41fad2d"
FLAGSHIP_FOOTBALL = "6196df70-218b-420c-aba4-90a50ce27207"


def unique_listings(records):
    """Drop conflicting canonical URLs rather than let provider order choose their meaning."""
    grouped = {}
    for row in records:
        link = sale_url(row.get("url"))
        if link:
            signature = (row.get("parallel_id"), row.get("parallel_name"), row.get("grade_id"), row.get("listing_type"),
                         str(row.get("price")), row.get("currency", "USD"), row.get("date"), row.get("title"))
            grouped.setdefault(link, set()).add(signature)
    return [row for row in records if len(grouped.get(sale_url(row.get("url")), set())) == 1]


def uuid(value):
    return isinstance(value, str) and UUID.fullmatch(value) is not None


def explicit_football_foil(title):
    # "Football" in the release name describes the sport.
    residual = normal(title).replace("topps flagship football", " ")
    return " football foil " in f" {residual} "


def listing_for_finish(a, row):
    identity = a["cardSightIdentity"]
    selected, tagged = identity.get("parallelID"), row.get("parallel_id")
    if identity.get("setID") != FLAGSHIP_2026_BASE_SET or tagged is not None:
        return tagged == selected
    title = row.get("title")
    if not isinstance(title, str) or not explicit_football_foil(title):
        return tagged == selected
    # Only the full catalog-style seller title proves the unnumbered finish.
    # Extra words for a color, grading, lot or serial prevent this fallback.
    if (selected != FLAGSHIP_FOOTBALL or identity.get("parallelName") != "Football"
            or identity.get("numberedTo") is not None or a.get("serialNumber")
            or identity.get("variationOf") or identity.get("autograph")
            or row.get("parallel_name") not in (None, "Football")):
        return False
    expected = f"2026 Topps Flagship Football {a['player']} #{a['cardNumber']} Football Foil".casefold()
    literal = " ".join(title.casefold().split())
    return literal == expected or (a.get("rookie") is True and literal in (expected + " rc", expected + " (rc)"))


class CardLookup:
    def __init__(self, root, client=None, decisions=None, resolver=None):
        self.root = root
        self.cache = root / "card-lookup-cache"
        self.cache.mkdir(mode=0o700, exist_ok=True)
        self.scout_value = ScoutValueModel(root, self.cache, self.cached)
        self.client = client or Client(root)
        self.decisions = decisions or ListingDecisions(root)
        self.resolver = resolver or IdentityResolver(root)
        self.pending_lock = threading.Lock()
        self.pending = set()
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="card-lookup")

    def cached(self, key):
        path = self.cache / (key + ".json")
        try:
            size_limit = 8_000_000 if key.startswith("variants-") else 2_000_000
            value = json.loads(path.read_text()) if path.stat().st_size <= size_limit else {}
            if (not isinstance(value, dict) or value.get("version") != 1 or
                    not time.time() < value.get("expiresAt", 0) <= time.time() + CACHE_SECONDS + 60):
                return None
            if key.startswith(("photo-", "resolved-")) and not isinstance(value.get("detection"), dict):
                return None
            if key.startswith("variants-") and (value.get("pricingVersion") != 5 or
                    value.get("status") not in ("available", "unavailable") or
                    not isinstance(value.get("options"), dict) or not isinstance(value.get("checkedAt"), str) or
                    value["status"] == "available" and not isinstance(value.get("data"), dict)):
                return None
            return value
        except (OSError, ValueError, TypeError, AttributeError): pass
        return None

    def save(self, key, *, ttl=CACHE_SECONDS, **value):
        value.update(version=1, expiresAt=time.time() + ttl)
        if key.startswith("variants-"): value["pricingVersion"] = 5
        atomic(self.cache / (key + ".json"), value)
        return value

    def purge(self):
        self.decisions.purge()
        for path in self.cache.glob("*.json"):
            if self.cached(path.stem) is None:
                with self.work_for(path.stem):
                    if self.cached(path.stem) is None and not (
                            path.stem.startswith("variants-") and self.legacy_offers(path.stem)):
                        path.unlink(missing_ok=True)

    def work_for(self, key, stop=None):
        return cache_work(self.cache / (key + ".lock"), stop)

    @staticmethod
    def foreground(data):
        if not isinstance(data, dict) or type(data.get("success")) is not bool:
            raise MarketError("Kartenerkennung konnte nicht sicher gelesen werden.")
        detections = data.get("detections", [])
        if not isinstance(detections, list) or len(detections) > 20:
            raise MarketError("Kartenerkennung konnte nicht sicher gelesen werden.")
        if not detections:
            # CardSight can report one object, zero identities and omit detections.
            count = data.get("detectedCount")
            identified = data.get("identifiedCount", 0)
            if (("detections" in data or count is not None) and
                    (count is None or type(count) is int and count in (0, 1)) and
                    type(identified) is int and identified == 0):
                return {"noDetection": True}
            return {}
        if not data["success"]:
            return {}
        foreground = [d for d in detections if isinstance(d, dict) and type(d.get("zIndex")) is int and d["zIndex"] == 0]
        if len(detections) == 1 and isinstance(detections[0], dict) and "zIndex" not in detections[0]:
            foreground = detections
        if len(foreground) != 1:
            return {}
        # Provider data cannot supply internal resolution or fallback flags.
        return {k: foreground[0][k] for k in ("card", "confidence", "zIndex", "grading") if k in foreground[0]}

    def identify(self, job_dir, known, stop=None):
        if stop and stop.is_set(): raise InterruptedError("Job stopped")
        refresh = job_dir / "refresh.json"
        previous = json.loads(refresh.read_text()) if refresh.exists() else {}
        if previous.get("analysis", {}).get("assessmentSource") == "cardsight":
            output = deepcopy(previous)
            saved = output["analysis"]
            repair_confirmed_bowman_license(saved)
            saved.pop("unpricedBaseExpiresAt", None)
            saved["insights"]["marketReferences"] = []
            identity = saved.get("cardSightIdentity") or {}
            # Older scans may have offered only Base despite a full parallel checklist.
            # A user-requested reanalysis can verify that finish on the original photos.
            if (saved.get("identityConfirmed") and saved.get("subset") in ("Base", "Chrome Base")
                    and "ordinaryBaseCatalog" not in identity
                    and not any(identity.get(k) for k in ("parallelID", "numberedTo", "variationOf", "slabbed", "autograph"))
                    and not saved.get("parallel") and not saved.get("serialNumber") and self.status(saved) == "no_match"):
                try:
                    checked = self.identify_photos(job_dir, known, stop)["analysis"]
                except InterruptedError:
                    raise
                except (MarketError, ValueError, KeyError, OSError):
                    return output
                proof = checked.get("cardSightIdentity") or {}
                if (checked.get("identityConfirmed") and proof.get("ordinaryBaseCatalog")
                        and "base" in proof.get("eligibleParallelIDs", [])
                        and all(identity.get(k) == proof.get(k) for k in ("cardID", "setID", "parallelID", "slabbed"))):
                    identity.update(ordinaryBaseCatalog=True, eligibleParallelIDs=proof["eligibleParallelIDs"])
                    saved["insights"]["rarityTier"] = checked["insights"]["rarityTier"]
            return output
        return self.identify_photos(job_dir, known, stop)

    def identify_photos(self, job_dir, known, stop):
        image = (job_dir / "front.jpg").read_bytes()
        front_digest = hashlib.sha256(image).hexdigest()
        key = "photo-" + front_digest
        with self.work_for(key, stop):
            cached = self.cached(key)
            if cached is None or (not cached.get("detection") and not cached.get("foregroundChecked")):
                data = self.client.request("POST", "/v1/identify/card/football", body=image)
                if stop and stop.is_set(): raise InterruptedError("Job stopped")
                cached = self.save(key, detection=self.foreground(data), foregroundChecked=True)
        hints = (job_dir / "capture-text.txt").read_bytes()[:8000] if (job_dir / "capture-text.txt").exists() else b""
        back = job_dir / "back.jpg"
        back_digest = hashlib.sha256(back.read_bytes()).hexdigest() if back.is_file() else "absent"
        # A fresh provider response can revise its candidates for the same photo.
        response = json.dumps(cached["detection"], sort_keys=True, separators=(",", ":")).encode()
        evidence = f"{front_digest}:{back_digest}:{hashlib.sha256(hints).hexdigest()}:{hashlib.sha256(response).hexdigest()}"
        for filename in ("surface.jpg", "tilt.jpg"):
            side = job_dir / filename
            if side.is_file():
                evidence += ":" + filename + ":" + hashlib.sha256(side.read_bytes()).hexdigest()
        resolution_key = f"resolved-v{RESOLVER_VERSION}-" + hashlib.sha256(evidence.encode()).hexdigest()
        with self.work_for(resolution_key, stop):
            resolved = self.cached(resolution_key)
            if resolved is None:
                detection = self.resolver.resolve(deepcopy(cached["detection"]), job_dir, self.client, stop)
                if stop and stop.is_set(): raise InterruptedError("Job stopped")
                trace = job_dir / "identity-resolution.json"
                diagnostic = json.loads(trace.read_text()) if trace.is_file() else {}
                ttl = RESOLUTION_ERROR_COOLDOWN if diagnostic.get("error") else CACHE_SECONDS
                resolved = self.save(resolution_key, detection=detection, diagnostic=diagnostic, ttl=ttl)
            elif resolved.get("diagnostic"):
                atomic(job_dir / "identity-resolution.json", dict(resolved["diagnostic"], cacheHit=True))
        output = self.result(resolved["detection"], known, job_dir)
        assignment = job_dir / "identity.json"
        if assignment.exists():
            locked = json.loads(assignment.read_text())
            if any(output["analysis"].get(k) != locked.get(k) for k in ("player", "year", "brand", "setName", "subset", "cardNumber", "parallel")):
                raise MarketError("CardSight bestätigt die gewählte Zuordnung nicht. Bitte Karte und Variante prüfen.")
        return output

    def result(self, detection, known, job_dir):
        card = detection.get("card") or {}
        if not isinstance(card, dict): raise MarketError("Ungültige Kartenmetadaten.")
        text_keys = ("name", "number", "year", "manufacturer", "releaseName", "setName")
        if any(k in card and (not isinstance(card[k], str) or len(card[k]) > 240) for k in text_keys):
            raise MarketError("Ungültige Kartenmetadaten.")
        attributes = card.get("attributes") or []
        if not isinstance(attributes, list) or len(attributes) > 50 or any(not isinstance(v, str) or len(v) > 180 for v in attributes):
            raise MarketError("Ungültige Kartenattribute.")
        year = int(card["year"]) if re.fullmatch(r"\d{4}", card.get("year", "")) else None
        parallels = card.get("parallelSuggestions", [])
        if not isinstance(parallels, list) or len(parallels) > 1000 or any(not isinstance(p, dict) for p in parallels):
            raise MarketError("Ungültige Variantenmetadaten.")
        suggested_count = len(parallels)
        parallels = [p for p in parallels if uuid(p.get("id")) and isinstance(p.get("name"), str)
                     and 0 < len(p["name"]) <= 180 and (not p.get("isPartial") or card.get("id") in (p.get("cards") or []))]
        ranks = {"High": 3, "Medium": 2, "Low": 1}
        parallels.sort(key=lambda p: -ranks.get(p.get("confidence"), 0))
        parallels = list({p["id"]: p for p in reversed(parallels)}.values())
        parallels.sort(key=lambda p: -ranks.get(p.get("confidence"), 0))
        for p in parallels:
            if type(p.get("numberedTo")) is not int or not 0 < p["numberedTo"] <= 1_000_000: p.pop("numberedTo", None)
        variant = parallels[0] if parallels and not detection.get("variantUnresolved") else None
        variant_clear = (not suggested_count and not card.get("isParallelOnly")) or (variant is not None and variant.get("confidence") == "High" and sum(p.get("confidence") == "High" for p in parallels) == 1)
        exact = (detection.get("confidence") == "High" and uuid(card.get("id")) and uuid(card.get("setId"))
                 and year is not None and all(card.get(k) for k in text_keys))
        card_exact = exact
        exact = exact and variant_clear and not detection.get("variantUnresolved")
        eligible = detection.get("eligibleParallels")
        if eligible is None:
            picker = ([] if card.get("isParallelOnly") else [dict(id="base", name="Base", numberedTo=card.get("numberedTo"))]) + parallels
        else:
            if (not isinstance(eligible, list) or len(eligible) > 201 or
                    any(not isinstance(p, dict) or not (uuid(p.get("id")) or p.get("id") == "base")
                        or not isinstance(p.get("name"), str) or not 0 < len(p["name"]) <= 180 for p in eligible)):
                raise MarketError("Ungültige Variantenmetadaten.")
            picker = [p for p in eligible if p["id"] != "base" or not card.get("isParallelOnly")]
            if (variant["id"] if variant else "base") not in {p["id"] for p in picker}:
                exact = False
                variant = None
        confidence = {p["id"]: p.get("confidence") for p in parallels}
        picker_options = [dict(id=p["id"], name=p["name"], numberedTo=p.get("numberedTo"),
                               confidence=confidence.get(p["id"])) for p in picker]
        product, subset = card.get("releaseName"), card.get("setName")
        subset = "Base" if subset == "Base Set" else subset
        if product == "Panini Select" and detection.get("printedLevel"):
            subset = detection["printedLevel"]
        if product == "Bowman" and year == 2026:
            subset = {"Chrome": "Chrome Base", "Prospects": "Paper Prospects"}.get(subset, subset)
        a = dict(player=card.get("name"), year=year, brand=card.get("manufacturer"), setName=product,
                 subset=subset, cardNumber=card.get("number"), parallel=variant["name"] if variant else None,
                 team=None, rookie=True if set(card.get("attributes") or []) & {"RC", "Rookie"} else None, serialNumber=detection.get("observedSerial"), recommendation="Keep", marketLowCents=None,
                 marketHighCents=None, marketCheckedAt=dt.date.today().isoformat(), marketSources=[],
                 confidence=str(detection.get("confidence", "Low")).lower(), conditionNotes="", rationale="",
                 needsReview=not bool(exact), identityConfirmed=bool(exact), licenseScope="unknown",
                 psa10ChanceLow=None, psa10ChanceHigh=None, uncertainties=[], currency="USD", collectionID=None,
                 assessmentSource="cardsight", cardSightIdentity=None,
                 cardSightVariants=picker_options,
                 insights=dict(rarityTier="parallel" if variant else "base" if exact and subset == "Base" and not card.get("variationOf") else "unknown",
                               rarityBullets=[variant["name"][:180]] if variant else [],
                               conditionStatus="not_assessable", conditionIssues=[], conditionLimitations=[],
                               marketBullets=[], marketReferences=[], sourceChecks=[], actionReason=""))
        # Preserve existing, independently sourced binder names and checklist rows.
        from card_prices import catalog_release, catalog_subset, variant_name
        release_name = catalog_release(dict(year=year, brand=a["brand"], setName=product))
        rated_rookie = a["rookie"] is True and product == "Donruss Optic" and year == 2025
        matches = []
        incomplete = []
        for c in known:
            if card.get("variationOf"): continue  # A child UUID must never occupy its parent's base slot.
            probe = dict(year=c["year"], brand=c["brand"], setName=c["name"], subset=c["subset"])
            if (c["year"] == year and c["brand"] == a["brand"] and catalog_release(probe) == release_name
                    and (not detection.get("printedLevel") or c["subset"] == subset)
                    and (catalog_subset(probe) == card.get("setName") or c["subset"] == detection.get("printedLevel"))
                    and variant_name(c.get("parallel"), rated_rookie) == variant_name(a["parallel"], rated_rookie)):
                row = next((r for r in c["cards"] if r["number"] == a["cardNumber"] and normal(r["player"]) == normal(a["player"])), None)
                if row:
                    matches.append((c, row))
                elif (detection.get("finishState") == "verified" and not c.get("checklistComplete")
                      and not any(r["number"] == a["cardNumber"] for r in c["cards"])):
                    incomplete.append(c)
        collection = None
        if len(matches) == 1:
            c, row = matches[0]
            a.update(setName=c["name"], subset=c["subset"], parallel=c.get("parallel"), team=row["team"], rookie=row["rookie"])
            if exact: collection = deepcopy(c)
        if (year, a["brand"], product) == (2026, "Topps", "Bowman"):
            if card_exact:
                scope = bowman_license_scope(year, a["brand"], product, a["subset"], a["cardNumber"])
                if scope: a["licenseScope"] = scope
        else:
            for release in product_license_evidence(job_dir):
                if (release["year"] == year and release["brand"] == a["brand"]
                        and catalog_release(dict(year=year, brand=a["brand"], setName=release["name"])) == release_name):
                    a["licenseScope"] = release["licenseScope"]
        conflict = identity_conflict(a)
        if conflict:
            exact = False; collection = None; a["uncertainties"].append(conflict)
        if card_exact and not conflict:
            a["cardSightIdentity"] = dict(cardID=card["id"], setID=card["setId"], parallelID=variant["id"] if variant else None,
                                           slabbed=bool(detection.get("grading")), releaseName=product, setName=card["setName"],
                                           numberedTo=variant.get("numberedTo") if variant else card.get("numberedTo"),
                                           variationOf=card.get("variationOf"), parallelName=variant["name"] if variant else None,
                                           attributes=attributes,
                                           autograph=card.get("autograph") if type(card.get("autograph")) is bool else None)
            if card.get("isParallelOnly"):
                a["cardSightIdentity"]["isParallelOnly"] = True
            if eligible is not None:
                a["cardSightIdentity"]["eligibleParallelIDs"] = [p["id"] for p in picker_options]
                if "ordinaryBaseCatalog" in card:
                    a["cardSightIdentity"]["ordinaryBaseCatalog"] = card["ordinaryBaseCatalog"] is True
                    if card["ordinaryBaseCatalog"] is True and exact and not variant and subset == "Chrome Base":
                        a["insights"]["rarityTier"] = "base"
            if exact and collection is None and not matches and len(incomplete) == 1:
                collection = deepcopy(incomplete[0])
                collection["cards"].append(dict(number=a["cardNumber"], player=a["player"], team=a["team"] or "",
                                                rookie=a["rookie"] is True, imageURL=None))
                a.update(setName=collection["name"], subset=collection["subset"], parallel=collection.get("parallel"))
            if exact and collection is None:
                # One observed row, never an invented complete checklist.
                collection = dict(id="cardsight-" + card["setId"] + ("-" + variant["id"] if variant else "") + ("-variation-" + card["id"] if card.get("variationOf") else "") + ("-" + normal(detection["printedLevel"]).replace(" ", "-") if detection.get("printedLevel") else ""),
                                  name=a["setName"], year=year, brand=a["brand"], subset=a["subset"], parallel=a["parallel"],
                                  expectedCount=None, checklistComplete=False,
                                  sourceURL="https://api.cardsight.ai/v1/identify/card/football", checkedAt=dt.date.today().isoformat(),
                                  cards=[dict(number=a["cardNumber"], player=a["player"], team=a["team"] or "", rookie=a["rookie"] is True, imageURL=None)])
            if card.get("variationOf") and card.get("description"):
                a["insights"]["rarityBullets"] = [str(card["description"])[:180]]
            a["collectionID"] = collection["id"] if collection else None
        else:
            a["uncertainties"].append("Karte oder Variante nicht eindeutig erkannt.")
        if detection.get("finishPolicy"):
            a["finishPolicy"] = detection["finishPolicy"]
            a["finishState"] = detection["finishState"]
            edition = detection.get("independentEdition")
            if edition and card_exact and not conflict:
                from chrome_finish import SOURCE
                a.update(parallel=edition, cardSightIdentity=None, cardSightVariants=[])
                a["insights"].update(rarityTier="parallel", rarityBullets=[edition])
                collection = dict(id="photo-" + card["setId"] + "-" + normal(edition).replace(" ", "-"),
                                  name=a["setName"], year=year, brand=a["brand"], subset=a["subset"], parallel=edition,
                                  expectedCount=None, checklistComplete=False, sourceURL=SOURCE, checkedAt=dt.date.today().isoformat(),
                                  cards=[dict(number=a["cardNumber"], player=a["player"], team=a["team"] or "", rookie=a["rookie"] is True, imageURL=None)])
                a["collectionID"] = collection["id"]
                exact = True
            if not exact and a["finishState"] == "verified":
                a["finishState"] = "pending"
        a.update(identityConfirmed=bool(exact), needsReview=not bool(exact) or a["licenseScope"] == "unknown")
        return dict(analysis=a, collection=collection,
                    matches=[dict(collectionID=collection["id"], number=a["cardNumber"])] if collection else [],
                    matchNotice="cardsight" if exact else "unknown")

    def key(self, a):
        identity = a.get("cardSightIdentity") or {}
        if not uuid(identity.get("cardID")) or not uuid(identity.get("setID")) or identity.get("slabbed"):
            return None
        parallel = identity.get("parallelID")
        if parallel is not None and not uuid(parallel): return None
        if a.get("identityConfirmed") and not self.allowed_option(
                a, {"id": parallel or "base", "numberedTo": identity.get("numberedTo")}):
            return None
        return "variants-" + identity["cardID"] + "-raw"

    @staticmethod
    def selected_id(a):
        return a["cardSightIdentity"].get("parallelID") or "base"

    @staticmethod
    def price_status(snapshot, variant_id):
        if not snapshot: return "empty"
        if snapshot.get("status") == "unavailable": return "unavailable"
        option = snapshot["options"].get(variant_id, {})
        return option.get("priceStatus", "empty")

    def status(self, a):
        key = self.key(a)
        if not key: return "unsupported"
        if not a.get("identityConfirmed"): return "review"
        variant_id = self.selected_id(a)
        with self.pending_lock:
            if (key, variant_id) in self.pending: return "refreshing"
        return self.price_status(self.snapshot_for(a, self.cached(key)), variant_id)

    def start(self, a):
        key = self.key(a)
        if not key or not a.get("identityConfirmed"): return
        variant_id = self.selected_id(a)
        snapshot = self.snapshot_for(a, self.cached(key))
        status = self.price_status(snapshot, variant_id)
        if status != "empty" and not self.needs_sale_search(a, snapshot) and not (status == "ready" and
                snapshot["options"][variant_id].get("valueMarket") != self.estimation_market(a)):
            return
        task = (key, variant_id)
        with self.pending_lock:
            if task in self.pending or len(self.pending) >= 100: return
            self.pending.add(task)

        def run(analysis):
            try:
                self.lookup(analysis)
                self.find_missing_sales(analysis, key)
            finally:
                with self.pending_lock: self.pending.discard(task)
        try: self.executor.submit(run, deepcopy(a))
        except RuntimeError:
            with self.pending_lock: self.pending.discard(task)
            raise

    def needs_sale_search(self, a, snapshot):
        if not snapshot or snapshot.get("status") != "available" or identity_conflict(a):
            return False
        option = snapshot["options"].get(self.selected_id(a), {})
        if (option.get("priceStatus") not in ("ready", "no_match") or option.get("soldCount")
                or (option.get("saleSearchVersion") == sold_search.VERSION and option.get("saleSearchAfter", 0) > time.time())):
            return False
        return not self.scout_value_for_variant(a["cardSightIdentity"], option, snapshot)

    def search_references(self, a, listing_type):
        query = dict(q=sold_search.query_for(a), period="90d", listing_type=listing_type, limit=25)
        response = self.client.request("GET", "/v1/pricing/search", query)
        if any(response["query"].get(k) != v for k, v in query.items()):
            raise ValueError("Unexpected market search filters")
        rows = response["results"]
        if not isinstance(rows, list) or len(rows) > 25 or not all(isinstance(r, dict) for r in rows):
            raise ValueError("Invalid market search rows")
        eligible = [r for r in unique_listings(rows) if sold_search.possible_sale(a, r, listing_type)]
        return self.checked_references(a, eligible, title_search=listing_type == "auction")

    def find_missing_sales(self, a, key):
        with self.work_for(key):
            snapshot = self.snapshot_for(a, self.cached(key))
            if not self.needs_sale_search(a, snapshot):
                return
            option = snapshot["options"][self.selected_id(a)]
            try:
                refs = self.search_references(a, "auction")
                existing = option.get("references", [])
                if not refs and not existing and self.estimation_market(a):
                    refs = self.search_references(a, "fixed")
                urls = {r["url"] for r in existing}
                additions = [dict(r, expiresAt=snapshot["expiresAt"]) for r in refs if r["url"] not in urls]
                if additions:
                    combined = additions + existing
                    sales = [r for r in combined if r["kind"] == "sold"]
                    asks = [r for r in combined if r["kind"] == "ask"]
                    option.update(priceStatus="ready", references=combined, soldCount=len(sales),
                                  medianCents=self.median(sales), soldShipping="unknown", currency="USD",
                                  askingCount=len(asks), askingMedianCents=self.median(asks),
                                  askingCurrency="USD" if asks else None, askingShipping="unknown" if asks else None,
                                  valueMarket=self.estimation_market(a))
                option["saleSearchAfter"] = snapshot["expiresAt"]
            except (MarketError, DecisionError, ValueError, OSError, KeyError, TypeError):
                option["saleSearchAfter"] = min(time.time() + 1800, snapshot["expiresAt"])
            option["saleSearchVersion"] = sold_search.VERSION
            atomic(self.cache / (key + ".json"), snapshot)

    @staticmethod
    def validate_market_context(a, data, parallel, *, unfiltered=False):
        identity = a["cardSightIdentity"]
        context, query = data["card"], data["query"]
        if (context["card_id"] != identity["cardID"] or context["set"]["set_id"] != identity["setID"]
                or context["set"].get("year") != str(a["year"])
                or context["set"].get("release") != identity["releaseName"] or context["set"].get("name") != identity["setName"]
                or normal(context["name"]) != normal(a["player"]) or context.get("number") != a["cardNumber"]
                or query.get("parallel_id", None if unfiltered else "missing") != parallel or query.get("grade_id", "missing") is not None
                or query.get("period") != "90d" or query.get("listing_type") != "both"):
            raise ValueError("Wrong card or pricing filters")

    def snapshot_for(self, a, snapshot):
        if snapshot and "data" in snapshot:
            try:
                self.validate_market_context(a, snapshot["data"], None, unfiltered=True)
                if (a["cardSightIdentity"]["setID"] == FLAGSHIP_2026_BASE_SET
                        and snapshot.get("footballFoilChecked") is not True):
                    if any(row.get("parallel_id") is None and explicit_football_foil(row.get("title"))
                           for row in snapshot["data"]["raw"]["records"]):
                        for key in ("base", FLAGSHIP_FOOTBALL):
                            option = snapshot["options"].get(key)
                            if option:
                                snapshot["options"][key] = {k: option[k] for k in ("id", "name", "numberedTo") if k in option}
                    snapshot["footballFoilChecked"] = True
            except (KeyError, TypeError, ValueError):
                # A stale/mismatched saved analysis must not contaminate valid results.
                return dict(status="unavailable", options={}, checkedAt=snapshot["checkedAt"])
        return snapshot

    def legacy_offers(self, key, snapshot=None):
        """Keep names previously offered to installed clients until the original v4 expiry."""
        if not key or not key.startswith("variants-"): return {}
        if snapshot is None:
            path = self.cache / (key + ".json")
            try:
                if path.stat().st_size > 8_000_000: return {}
                snapshot = json.loads(path.read_text())
            except (OSError, ValueError): return {}
        if not isinstance(snapshot, dict) or snapshot.get("version") != 1: return {}
        if snapshot.get("pricingVersion") == 4:
            if snapshot.get("status") not in ("ready", "no_match") or snapshot.get("decisionStatus") != "completed":
                return {}
            expires, rows = snapshot.get("expiresAt"), snapshot.get("variants")
        else:
            inherited = snapshot.get("legacyOffers")
            if snapshot.get("pricingVersion") != 5 or not isinstance(inherited, dict): return {}
            expires, rows = inherited.get("expiresAt"), inherited.get("options")
        now = time.time()
        if (type(expires) not in (int, float) or not now < expires <= now + CACHE_SECONDS + 60
                or not isinstance(rows, list) or not 0 < len(rows) <= 1501):
            return {}
        options = {}
        for row in rows:
            if not isinstance(row, dict): return {}
            vid, name, tier = row.get("id"), row.get("name"), row.get("numberedTo")
            if (not (vid == "base" or uuid(vid)) or vid in options or not isinstance(name, str) or not 0 < len(name) <= 180
                    or (tier is not None and (type(tier) is not int or not 0 < tier <= 1_000_000))):
                return {}
            options[vid] = dict(id=vid, name=name, numberedTo=tier)
        return dict(expiresAt=expires, options=list(options.values()))

    def store_snapshot(self, a, key, data):
        # These rows come from one bounded raw-price response. Keep only fields
        # needed to check another chosen variant, with the original expiry.
        self.validate_market_context(a, data, None, unfiltered=True)
        rows = data["raw"]["records"]
        if not isinstance(rows, list) or len(rows) > 500 or any(not isinstance(r, dict) for r in rows):
            raise ValueError("Invalid sales")
        fields = ("parallel_id", "parallel_name", "grade_id", "listing_type", "price",
                  "currency", "date", "title", "source", "url")
        rows = [{k: row[k] for k in fields if k in row} for row in unique_listings(rows)]
        options = {}
        for row in rows:
            pid, name = row.get("parallel_id"), row.get("parallel_name")
            if uuid(pid) and isinstance(name, str) and 0 < len(name) <= 180:
                options.setdefault(pid, dict(id=pid, name=name))
        return self.save(key, status="available", options=options, footballFoilChecked=True, legacyOffers=self.legacy_offers(key),
                         checkedAt=dt.date.today().isoformat(),
                         data=dict(card=data["card"], query=data["query"], raw=dict(records=rows)))

    def failed_snapshot(self, key):
        return self.save(key, status="unavailable", options={}, legacyOffers=self.legacy_offers(key),
                         checkedAt=dt.date.today().isoformat())

    @staticmethod
    def estimation_market(a):
        identity = a["cardSightIdentity"]
        if (identity_conflict(a) or a.get("serialNumber") or any(identity.get(field) for field in
                ("slabbed", "numberedTo", "autograph", "variationOf"))):
            return None
        return market_scope(a)

    def price_selected(self, a, key, snapshot, retry=False):
        snapshot = self.snapshot_for(a, snapshot)
        variant_id = self.selected_id(a)
        previous = self.price_status(snapshot, variant_id)
        identity = a["cardSightIdentity"]
        market = self.estimation_market(a)
        if previous != "empty" and not (retry and previous == "unavailable" and "data" in snapshot):
            if previous == "ready" and snapshot["options"][variant_id].get("valueMarket") != market:
                snapshot["options"][variant_id]["valueMarket"] = market
                atomic(self.cache / (key + ".json"), snapshot)
            return
        option = dict(id=variant_id, name=identity.get("parallelName") or a.get("parallel") or "Base",
                      numberedTo=identity.get("numberedTo"), valueMarket=market)
        source = snapshot["data"]
        pid = identity.get("parallelID")
        view = dict(card=source["card"], query=dict(source["query"], parallel_id=pid), raw=source["raw"])
        try:
            refs = self.references(a, view, limit=500)
            for ref in refs: ref["expiresAt"] = snapshot["expiresAt"]
            sold = [r for r in refs if r["kind"] == "sold"]
            asks = [r for r in refs if r["kind"] == "ask"]
            option.update(priceStatus="ready" if refs else "no_match", references=refs,
                          medianCents=self.median(sold), askingMedianCents=self.median(asks),
                          soldCount=len(sold), askingCount=len(asks), currency="USD", soldShipping="unknown",
                          askingCurrency="USD" if asks else None, askingShipping="unknown" if asks else None,
                          expiresAt=snapshot["expiresAt"])
        except (MarketError, ValueError, TypeError, KeyError, InvalidOperation, OSError):
            option["priceStatus"] = "unavailable"
        snapshot["options"][variant_id] = option
        atomic(self.cache / (key + ".json"), snapshot)

    @staticmethod
    def allowed_option(a, option):
        identity = a["cardSightIdentity"]
        allowed = identity.get("eligibleParallelIDs")
        if allowed is not None and option["id"] not in allowed: return False
        if option["id"] == "base" and identity.get("isParallelOnly"): return False
        serial = re.fullmatch(r"\d+\s*/\s*(\d+)", a.get("serialNumber") or "")
        if serial:
            # Intrinsically numbered cards may have a numbered base.
            return option.get("numberedTo") == int(serial[1])
        return True

    def price_view(self, a, snapshot):
        snapshot = self.snapshot_for(a, snapshot)
        selected = self.selected_id(a)
        option = snapshot["options"].get(selected, {})
        status = self.price_status(snapshot, selected)
        return dict(status=status, variants=[p for p in snapshot["options"].values() if self.allowed_option(a, p)],
                    references=option.get("references", []), medianCents=option.get("medianCents"),
                    askingMedianCents=option.get("askingMedianCents"), currency="USD", checkedAt=snapshot["checkedAt"],
                    decisionStatus="unavailable" if status == "unavailable" else "completed")

    def lookup(self, a):
        key = self.key(a)
        if not key or not a.get("identityConfirmed"): return None
        with self.work_for(key):
            snapshot = self.cached(key)
            if snapshot is None:
                try:
                    data = self.client.request("GET", "/v1/pricing/" + a["cardSightIdentity"]["cardID"],
                                               {"grade_id": "null", "period": "90d", "listing_type": "both", "limit": 500})
                    snapshot = self.store_snapshot(a, key, data)
                except (MarketError, ValueError, TypeError, KeyError, InvalidOperation, OSError):
                    snapshot = self.failed_snapshot(key)
            self.price_selected(a, key, snapshot)
            return self.price_view(a, snapshot)

    @staticmethod
    def median(refs):
        return int(Decimal(str(statistics.median(r["lowCents"] for r in refs))).quantize(Decimal("1"), rounding=ROUND_HALF_UP)) if refs else None

    def lookup_many(self, analyses, retry_unavailable=False):
        """Fetch shared snapshots in batches, then check each requested physical variant."""
        if len(analyses) > 200: raise ValueError("At most 200 cards per refresh")
        groups = {}
        for a in analyses:
            key = self.key(a)
            if key and a.get("identityConfirmed"):
                groups.setdefault(key, {}).setdefault(self.selected_id(a), a)
        keys = sorted(groups)
        results = {}
        for offset in range(0, len(keys), 100):
            batch = keys[offset:offset + 100]
            # Take locks in sorted order. Recognition never acquires a price lock.
            with ExitStack() as locks:
                missing = {}
                for key in batch:
                    snapshot = self.cached(key)
                    if snapshot and not (retry_unavailable and snapshot["status"] == "unavailable"):
                        continue
                    locks.enter_context(self.work_for(key))
                    snapshot = self.cached(key)
                    if snapshot is None or (retry_unavailable and snapshot["status"] == "unavailable"):
                        a = next(iter(groups[key].values()))
                        missing[a["cardSightIdentity"]["cardID"]] = key
                if missing:
                    try:
                        response = self.client.request("POST", "/v1/pricing/", body=dict(
                            card_ids=list(missing), grade_id=None, period="90d", listing_type="both", limit=50))
                        items = response["results"]
                        if (not isinstance(items, list) or len(items) != len(missing)
                                or any(not isinstance(item, dict) for item in items)
                                or {item.get("card_id") for item in items} != set(missing)):
                            raise ValueError("Incomplete or duplicate bulk pricing IDs")
                        by_card = {item["card_id"]: item for item in items}
                    except (MarketError, ValueError, TypeError, KeyError, OSError):
                        by_card = {}
                    for card_id, key in missing.items():
                        try:
                            item = by_card[card_id]
                            if item.get("success") is not True: raise ValueError("Bulk pricing unavailable")
                            self.store_snapshot(next(iter(groups[key].values())), key, item["data"])
                        except (ValueError, TypeError, KeyError, InvalidOperation, OSError):
                            self.failed_snapshot(key)
            # One slow Decisions request must not lock every other card in the batch.
            for key in batch:
                with self.work_for(key):
                    snapshot = self.cached(key)
                    if snapshot is None: continue  # Snapshot expired during the batch.
                    for a in groups[key].values():
                        self.price_selected(a, key, snapshot, retry_unavailable)
                    results[key] = self.price_view(next(iter(groups[key].values())), snapshot)
        return results

    def select(self, result, variant_id, known=()):
        output = self.attach(result)
        a = output["analysis"]
        a.pop("unpricedBaseExpiresAt", None)
        a["insights"].pop("scoutEstimate", None)
        option = next((p for p in a.get("cardSightVariants", []) if p["id"] == variant_id), None)
        if not option or not a.get("cardSightIdentity") or not self.allowed_option(a, option):
            raise ValueError("Unknown or conflicting card variant")
        # Keep the new explicit assignment and the job's own options. Other
        # market/cache discoveries must not become permanent via a revision.
        durable_ids = {p["id"] for p in result["analysis"].get("cardSightVariants", [])} | {variant_id}
        a["cardSightVariants"] = [{k: p[k] for k in ("id", "name", "confidence", "numberedTo") if k in p}
                                  for p in a.get("cardSightVariants", []) if p["id"] in durable_ids]
        identity = a["cardSightIdentity"]
        a["parallel"] = None if variant_id == "base" else option["name"]
        identity.update(parallelID=None if variant_id == "base" else variant_id, parallelName=a["parallel"], numberedTo=option.get("numberedTo"))
        if identity_conflict(a): raise ValueError("Card evidence contradicts selected variant")
        a.update(identityConfirmed=True, needsReview=a.get("licenseScope") == "unknown", uncertainties=[])
        repair_confirmed_bowman_license(a)
        a["insights"].update(rarityTier="base" if variant_id == "base" else "parallel", rarityBullets=[] if variant_id == "base" else [option["name"]])
        a["collectionID"] = "cardsight-" + identity["setID"] + ("-" + variant_id if variant_id != "base" else "") + ("-variation-" + identity["cardID"] if identity.get("variationOf") else "")
        output["collection"] = dict(id=a["collectionID"], name=a["setName"], year=a["year"], brand=a["brand"], subset=a["subset"], parallel=a["parallel"], expectedCount=None, checklistComplete=False,
            sourceURL="https://api.cardsight.ai/v1/identify/card/football", checkedAt=dt.date.today().isoformat(),
            cards=[dict(number=a["cardNumber"], player=a["player"], team=a.get("team") or "", rookie=a.get("rookie") is True, imageURL=None)])
        from card_prices import catalog_release, catalog_subset, variant_name
        if not identity.get("variationOf"):
            candidates = [c for c in known if c["year"] == a["year"] and c["brand"] == a["brand"]
                and catalog_release(dict(year=c["year"], brand=c["brand"], setName=c["name"])) == catalog_release(a)
                and catalog_subset(dict(year=c["year"], brand=c["brand"], setName=c["name"], subset=c["subset"])) == identity["setName"]
                and variant_name(c.get("parallel")) == variant_name(a["parallel"])
                and any(r["number"] == a["cardNumber"] and normal(r["player"]) == normal(a["player"]) for r in c["cards"])]
            if len(candidates) == 1:
                output["collection"] = deepcopy(candidates[0])
                a.update(collectionID=candidates[0]["id"], setName=candidates[0]["name"], subset=candidates[0]["subset"], parallel=candidates[0].get("parallel"))
        output.update(matches=[dict(collectionID=a["collectionID"], number=a["cardNumber"])], matchNotice="cardsight")
        a["insights"]["marketReferences"] = []
        return output

    def references(self, a, data, limit=25):
        identity = a["cardSightIdentity"]
        self.validate_market_context(a, data, identity.get("parallelID"))
        records = data["raw"]["records"]
        if not isinstance(records, list) or len(records) > limit or any(not isinstance(row, dict) for row in records):
            raise ValueError("Invalid listings")
        return self.checked_references(a, [r for r in unique_listings(records) if listing_for_finish(a, r)])

    def checked_references(self, a, records, *, title_search=False):
        identity = a["cardSightIdentity"]
        today = dt.datetime.now(dt.timezone.utc).date()
        seen, candidates, listings = set(), {}, []
        proven = {}
        for row in records:
            title, link = row.get("title"), sale_url(row.get("url"))
            if (row.get("listing_type") not in ("auction", "fixed")
                    or row.get("grade_id") is not None or not link or link in seen or not isinstance(title, str)
                    or not 0 < len(title) <= 2000 or row.get("source") != "ebay"):
                continue
            # CardSight prices are USD; reject explicit incompatible currency metadata.
            if row.get("currency", "USD") != "USD": continue
            try:
                date = dt.date.fromisoformat(row["date"][:10])
                if not 0 <= (today - date).days <= 90: continue
                if isinstance(row["price"], bool): continue
                amount = Decimal(str(row["price"])) * 100
                if not amount.is_finite() or not 0 < amount <= 100_000_000: continue
                cents = int(amount.quantize(Decimal("1"), rounding=ROUND_HALF_UP))
                if cents <= 0: continue
            except (ValueError, TypeError, KeyError, InvalidOperation): continue
            seen.add(link)
            # Stable original-row ID; neither model output order nor invented values can supply a price.
            listing_id = "listing_" + hashlib.sha256(link.encode()).hexdigest()[:24]
            candidates[listing_id] = dict(provider="CardSight", url=link, listingURL=link, title=title[:240],
                kind="sold" if row["listing_type"] == "auction" else "ask", grade="raw", condition=None,
                matchQuality="exact", lowCents=cents, highCents=cents, currency="USD", saleDate=date.isoformat(),
                checkedAt=today.isoformat(), shipping="unknown", expiresAt=time.time() + CACHE_SECONDS)
            if title_search and sold_search.exact_named_parallel(a, row, today):
                proven[listing_id] = "match"
                continue
            listings.append(dict(id=listing_id, title=title, parallelID=row.get("parallel_id"),
                parallelName=row.get("parallel_name"), gradeID=row.get("grade_id"), listingType=row["listing_type"]))
        target = {k: a.get(k) for k in ("player", "year", "brand", "setName", "subset", "cardNumber", "parallel", "serialNumber", "rookie")}
        target.update(cardSightIdentity={k: v for k, v in identity.items() if k not in ("eligibleParallelIDs", "isParallelOnly", "ordinaryBaseCatalog")}, grade="raw", autograph=identity.get("autograph"), attributes=identity.get("attributes", []))
        decisions = {**proven, **self.decisions.classify(target, listings)}
        if set(decisions) != set(candidates) or any(v not in ("match", "different", "unclear") for v in decisions.values()):
            raise DecisionError("Invalid listing decision IDs")
        return [ref for listing_id, ref in candidates.items() if decisions[listing_id] == "match"]

    def attach(self, result):
        output = deepcopy(result)
        a = output.get("analysis")
        if not a: return output
        repair_confirmed_bowman_license(a)
        a.pop("unpricedBaseExpiresAt", None)
        key = self.key(a)
        snapshot = self.snapshot_for(a, self.cached(key)) if key else None
        price = self.price_view(a, snapshot) if snapshot else None
        a["insights"]["marketReferences"] = deepcopy(price["references"]) if price and a.get("identityConfirmed") else []
        a["insights"].pop("scoutEstimate", None)
        identity = a.get("cardSightIdentity") or {}
        confirmed = a.get("identityConfirmed") and not identity_conflict(a)
        # Photo confidence, catalog names and print runs belong to this result.
        # Previous saved prices and another copy's confidence do not.
        options = {p["id"]: {k: p[k] for k in ("id", "name", "confidence", "numberedTo") if k in p}
                   for p in a.get("cardSightVariants", [])} if a.get("cardSightIdentity") else {}
        if price:
            for variant in price["variants"]:
                option = options.setdefault(variant["id"], dict(id=variant["id"], name=variant["name"]))
                for k, v in variant.items():
                    if k not in ("id", "name", "confidence", "references", "priceStatus", "valueMarket") and v is not None:
                        if k == "numberedTo" and option.get(k) is not None: continue
                        option[k] = v
                if confirmed and (value := self.scout_value_for_variant(identity, variant, snapshot)):
                    option["scoutValue"] = value
                    if variant["id"] == self.selected_id(a):
                        a["insights"]["scoutEstimate"] = value
        for old in self.legacy_offers(key, snapshot).get("options", []):
            option = options.setdefault(old["id"], old)
            if "numberedTo" not in option and old.get("numberedTo") is not None:
                option["numberedTo"] = old["numberedTo"]
        if a.get("cardSightIdentity"):
            a["cardSightVariants"] = [p for p in options.values() if self.allowed_option(a, p)]
        a["insights"]["marketBullets"] = []
        status = self.status(a)
        if (status == "no_match" and price and price["status"] == "no_match"
                and a.get("identityConfirmed") and not identity_conflict(a)
                and identity.get("ordinaryBaseCatalog") is True and "base" in identity.get("eligibleParallelIDs", [])
                and not any(identity.get(k) for k in ("parallelID", "parallelName", "slabbed", "variationOf", "numberedTo", "autograph", "isParallelOnly"))
                and a.get("subset") in ("Base", "Chrome Base") and a["insights"].get("rarityTier") == "base"
                and not a.get("serialNumber") and not a.get("parallel")):
            a["unpricedBaseExpiresAt"] = snapshot["expiresAt"]
        a["insights"]["sourceChecks"] = [dict(provider="CardSight", status="found" if status == "ready" else status, url="https://cardsight.ai")]
        if price: a["marketCheckedAt"] = price["checkedAt"]
        return output

    def scout_value_for_variant(self, identity, variant, snapshot):
        market = snapshot_market(snapshot, variant.get("valueMarket"))
        ask = variant.get("askingMedianCents")
        if not market or not ask:
            return None
        try:
            factor = self.scout_value.factor(identity["cardID"], market, (identity["setID"], variant["id"]))
        except OSError:
            return None
        if factor is None:
            return None
        amount = int(Decimal(str(ask * factor)).quantize(Decimal("1"), rounding=ROUND_HALF_UP))
        if 0 < amount <= 100_000_000:
            return dict(amountCents=amount, currency=variant["askingCurrency"], shipping=variant["askingShipping"],
                        checkedAt=snapshot["checkedAt"], expiresAt=snapshot["expiresAt"])
        return None
