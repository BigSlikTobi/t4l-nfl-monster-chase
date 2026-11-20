"""Calibrate Card Scout Value from the worker's current, checked listing cache."""
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from math import log
import json
from statistics import fmean, median
import threading
import time

from analysis import bowman_license_scope
from cardsight import atomic, cache_work


INITIAL_WEIGHT = 10
WEIGHTS = (2, 5, INITIAL_WEIGHT, 20, 40, 56, 80, 160)
MIN_MARKET_CARDS = 5
MARKETS = ("college", "nfl", "unspecified")


def snapshot_market(snapshot, market):
    if market != "unspecified":
        return market
    card = snapshot["data"]["card"]
    group = card["set"]
    # The exact release name here comes from CardSight's football pricing endpoint.
    year = 2026 if group.get("year") == "2026" else None
    scope = bowman_license_scope(year, "Topps", group.get("release"), group.get("name"), card.get("number"))
    return {"college": "college", "nfl_and_nflpa": "nfl"}.get(scope, market)


def market_scope(analysis):
    release = (analysis.get("cardSightIdentity") or {}).get("releaseName") or analysis.get("setName") or ""
    license_scope = analysis.get("licenseScope")
    if license_scope == "college" or any(term in release.casefold() for term in
                                       ("college", "university", "bowman u", "draft picks")):
        return "college"
    return "nfl" if license_scope in ("nfl", "nflpa", "nfl_and_nflpa") else "unspecified"


@dataclass(frozen=True)
class Example:
    card: str
    market: str
    group: tuple
    asks: tuple
    sales: tuple

    def ratio(self, cutoff=None):
        asks = [amount for day, amount in self.asks if cutoff is None or day < cutoff]
        sales = [amount for day, amount in self.sales if cutoff is None or day < cutoff]
        return median(sales) / median(asks) if asks and sales else None


def blend(overall, peers, weight):
    if not peers:
        return overall
    return overall + (median(peers) - overall) * len(peers) / (len(peers) + weight)


def tune(examples, current, cutoff):
    """Use earlier listings and sales to estimate later completed sales."""
    training = [(example, ratio) for example in examples if (ratio := example.ratio(cutoff)) is not None]
    errors = defaultdict(list)
    groups = set()
    cards = set()
    for example in examples:
        earlier_asks = [amount for day, amount in example.asks if day < cutoff]
        later_sales = [amount for day, amount in example.sales if day >= cutoff]
        if not earlier_asks or not later_sales:
            continue
        market = [(peer, ratio) for peer, ratio in training
                  if peer.market == example.market and peer.card != example.card]
        if len(market) < MIN_MARKET_CARDS:
            continue
        peers = [ratio for peer, ratio in market if peer.group == example.group]
        if not peers:
            continue
        groups.add((example.market, example.group))
        cards.add(example.card)
        overall = median(ratio for _, ratio in market)
        sale_per_ask = median(later_sales) / median(earlier_asks)
        for weight in WEIGHTS:
            errors[weight].append(abs(log(blend(overall, peers, weight) / sale_per_ask)))
    if len(cards) < 30 or len(groups) < 3:
        return None
    scores = {weight: fmean(values) for weight, values in errors.items()}
    best = min(scores, key=scores.__getitem__)
    return best if scores[current] - scores[best] >= 0.015 else current


class ScoutValueModel:
    def __init__(self, root, cache, read_snapshot):
        self.root = root
        self.cache = cache
        self.read_snapshot = read_snapshot
        self.lock = threading.Lock()
        self.state_path = root / "scout-value-weight.json"
        self.weight = INITIAL_WEIGHT
        self.refresh_at = 0
        self.ratios = {}

    def _load_examples(self):
        # Reuse approved listings only. Pending and rejected options never enter calibration.
        examples = []
        next_expiry = float("inf")
        keys = self.cache.glob("variants-*-raw.json")
        for path in keys:
            snapshot = self.read_snapshot(path.stem)
            if not snapshot or snapshot["status"] != "available":
                continue
            card = snapshot["data"]["card"]
            card_id, set_id = card["card_id"], card["set"]["set_id"]
            for variant, option in snapshot["options"].items():
                market = snapshot_market(snapshot, option.get("valueMarket"))
                if option.get("priceStatus") != "ready" or market not in MARKETS:
                    continue
                asks, sales = [], []
                for ref in option["references"]:
                    if (ref["provider"] != "CardSight" or ref["matchQuality"] != "exact" or ref["grade"] != "raw"
                            or ref["currency"] != "USD" or ref["shipping"] != "unknown"
                            or ref["lowCents"] != ref["highCents"] or ref["lowCents"] <= 0
                            or ref["kind"] not in ("ask", "sold")):
                        continue
                    target = asks if ref["kind"] == "ask" else sales
                    target.append((ref["saleDate"], ref["lowCents"]))
                if asks and sales:
                    next_expiry = min(next_expiry, snapshot["expiresAt"])
                    examples.append(Example(card_id, market, (set_id, variant), tuple(asks), tuple(sales)))
        return examples, next_expiry

    def _refresh(self, now):
        examples, next_expiry = self._load_examples()
        self.refresh_at = min(now + 60, next_expiry)
        today = datetime.fromtimestamp(now, timezone.utc).date()
        ratios = defaultdict(list)
        for example in examples:
            ratios[example.market].append((example.card, example.group, example.ratio()))
        self.ratios = ratios
        with cache_work(self.root / "scout-value-weight.lock"):
            try:
                state = json.loads(self.state_path.read_text())
            except (OSError, ValueError):
                state = {}
            if not isinstance(state, dict) or state.get("weight") not in WEIGHTS:
                state = {}
            self.weight = state.get("weight", INITIAL_WEIGHT)
            if state.get("checkedAt") == today.isoformat():
                return
            weight = tune(examples, self.weight, (today - timedelta(days=30)).isoformat())
            if weight is not None:
                atomic(self.state_path, dict(weight=weight, checkedAt=today.isoformat()))
                self.weight = weight

    def factor(self, card, market, group):
        with self.lock:
            now = time.time()
            if self.refresh_at <= now:
                self._refresh(now)
            examples = [(peer_group, ratio) for peer, peer_group, ratio in self.ratios.get(market, []) if peer != card]
            if len(examples) < MIN_MARKET_CARDS:
                return None
            overall = median(ratio for _, ratio in examples)
            return blend(overall, [ratio for peer_group, ratio in examples if peer_group == group], self.weight)
