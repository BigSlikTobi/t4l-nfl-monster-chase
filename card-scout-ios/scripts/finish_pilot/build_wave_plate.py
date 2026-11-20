"""Make an offline comparison of repeated waves and common lookalikes from public fronts."""
import hashlib
import json
from pathlib import Path
import sys

from PIL import Image, ImageDraw, ImageFont, ImageOps

from build_reference_sheet import region

MAYFIELD = dict(file="mayfield.jpg", sha256="ee9651819b53cb3566e4669db396cff35da8e527020f040cd7bb6cd9ad919336",
                source="https://www.ebay.com/itm/227353140180",
                image="https://i.ebayimg.com/images/g/8aQAAeSwZqJqD0mW/s-l1600.jpg")
EXAMPLES = [("RayWave", MAYFIELD, (.22, .085, .823, .909)),
            ("RayWave", "RayWave Refractor", None), ("Neon Pulse", "Neon Pulse Refractor", None),
            ("Pulsar", "Pulsar Refractor", None), ("Prism", "Prism Refractor", None),
            ("Smooth Refractor", "Refractor", None)]


def build(source, destination):
    rows = json.loads(Path(__file__).with_name("reference-sources.json").read_text())
    records = {r["finish"]: r for r in rows if r["subset"] == "Base"}
    plate = Image.new("RGB", (900, 570), "white")
    draw = ImageDraw.Draw(plate)
    font = ImageFont.load_default(size=19)
    for i, (label, key, bounds) in enumerate(EXAMPLES):
        record = records[key] if isinstance(key, str) else key
        path = source / record["file"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != record["sha256"]:
            raise ValueError("Unexpected reference: " + path.name)
        with Image.open(path) as original:
            card = ImageOps.exif_transpose(original).convert("RGB")
            if bounds:
                card = card.crop(tuple(round(v * (card.width if j % 2 == 0 else card.height)) for j, v in enumerate(bounds)))
            x, y = (i % 3) * 300, (i // 3) * 285
            draw.text((x + 5, y + 2), label, fill="black", font=font)
            plate.paste(ImageOps.contain(card, (174, 250)), (x + 2, y + 30))
            plate.paste(region(card, (.72, .06, .99, .83), (116, 250)), (x + 178, y + 30))
    plate.save(destination, quality=89, subsampling=0, optimize=True)


if __name__ == "__main__":
    build(Path(sys.argv[1]), Path(sys.argv[2]))
