"""Find raw completed sales missed by the provider's catalog link."""
import re

from cardsight import AUTO, PARALLEL, SERIAL, UNSAFE, normal
from card_prices import matching_variant_sale

VERSION = 3


def query_for(a):
    identity = a["cardSightIdentity"]
    release = re.sub(r"\b(?:Football|Panini)\b", "", identity["releaseName"]).strip() or identity["releaseName"]
    subject = a["player"]
    if " / " in subject:
        subject = " ".join(person.split()[-1] for person in subject.split(" / "))
    subject = re.sub(r" Combo Card$", "", subject, flags=re.I)
    tier = (a.get("serialNumber") or "").partition("/")[2]
    return " ".join(str(term) for term in (a["year"], release, subject, a["cardNumber"],
                                            tier or a.get("parallel")) if term)[:300]


def possible_sale(a, row, listing_type="auction"):
    """A search hit has no catalog binding. Require the title to support the edition before Decisions."""
    identity = a["cardSightIdentity"]
    title = row.get("title")
    if (not isinstance(title, str) or len(title) > 1000 or UNSAFE.search(title)
            or row.get("listing_type") != listing_type or row.get("source") != "ebay"
            or row.get("grade_id") is not None or identity.get("autograph") or identity.get("variationOf")
            or row.get("parallel_id") not in (None, identity.get("parallelID"))):
        return False
    matched = row.get("matched_card")
    if matched is not None and (not isinstance(matched, dict) or matched.get("card_id") != identity.get("cardID")
                                or not isinstance(matched.get("set"), dict) or matched["set"].get("set_id") != identity.get("setID")):
        return False
    if row.get("grade"):
        return False
    text = normal(title)
    tokens = set(text.split())
    release = set(normal(identity["releaseName"]).split()) - {"football", "panini"}
    if not release <= tokens or str(a["year"]) not in tokens:
        return False
    number = r"[-\s]*".join(map(re.escape, normal(a["cardNumber"]).split()))
    if not re.search(r"(?<![a-z0-9])" + number + r"(?![a-z0-9])", title.lower()):
        return False
    names = set(normal(a["player"]).split()) - {"jr", "sr", "ii", "iii", "combo", "card"}
    if not names <= tokens:
        subjects = a["player"].split(" / ")
        if len(subjects) < 2 or not all(normal(s).split()[-1] in tokens for s in subjects) or "leaders" not in tokens:
            return False
    if identity["releaseName"] == "Bowman":
        if tokens & {"university", "u", "sapphire", "draft", "best", "sterling", "inception", "baseball"}:
            return False
        if ("chrome" in tokens) != ("Chrome" in identity["setName"]):
            return False
    serial = (a.get("serialNumber") or "").partition("/")[2]
    printed = re.findall(r"/\s*(\d+)\b", title)
    if serial and (not printed or any(int(t) != int(serial) for t in printed)):
        return False
    if not serial and SERIAL.search(title):
        return False
    finish = set(normal(a.get("parallel") or "").split())
    if identity.get("parallelID") and (not finish or not finish <= tokens):
        return False
    remainder = tokens - names - finish - set(normal(a["subset"]).split())
    return not PARALLEL.search(" ".join(sorted(remainder))) and not AUTO.search(text)

def exact_named_parallel(a, row, today):
    """Confirm a fully named catalog parallel with the same audited sold-title validator used for raw guides."""
    ident = a["cardSightIdentity"]
    if not ident.get("parallelID") or not possible_sale(a, row):
        return False
    tier = ident.get("numberedTo")
    # This retail finish has a catalog production run, but no physical serial stamp.
    # Other numbered editions still require the seller's matching denominator.
    if (ident.get("setID"), ident.get("parallelName"), a.get("serialNumber")) == (
            "1d529543-0e41-4bdb-b3ff-437eb41fad2d", "Pink Holo Foil", None):
        tier = None
    card = dict(name=a["player"], number=a["cardNumber"], releaseName=ident["releaseName"],
                releaseYear=str(a["year"]), setName=ident["setName"], attributes=ident.get("attributes", []))
    variant = dict(id=ident["parallelID"], name=ident["parallelName"])
    variants = [p["name"] for p in a.get("cardSightVariants", [])]
    return matching_variant_sale(card, row, variant, tier, (), today, variants) is not None
