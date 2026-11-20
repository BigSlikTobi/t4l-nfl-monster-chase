"""Build worker reference plates from independently labeled, hash-checked public scans."""
import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


def region(image, box, size):
    bounds = [round(value * (image.width if i % 2 == 0 else image.height)) for i, value in enumerate(box)]
    return ImageOps.fit(image.crop(bounds), size, method=Image.Resampling.LANCZOS)


def build(source, output):
    records = json.loads(Path(__file__).with_name("reference-sources.json").read_text())
    font = ImageFont.load_default(size=15)
    for inserts, filename in [(False, "chrome-finish-surfaces.jpg"), (True, "chrome-insert-surfaces.jpg")]:
        items = [r for r in records if (r["subset"] != "Base") == inserts]
        sheet = Image.new("RGB", (3 * 272, ((len(items) + 2) // 3) * 160), "white")
        draw = ImageDraw.Draw(sheet)
        for i, record in enumerate(items):
            path = source / record["file"]
            if hashlib.sha256(path.read_bytes()).hexdigest() != record["sha256"]:
                raise ValueError("Reference changed: " + record["file"])
            x, y = (i % 3) * 272, (i // 3) * 160
            with Image.open(path) as photo:
                photo = ImageOps.exif_transpose(photo).convert("RGB")
                # Two pieces of the actual foil: the outer frame and the field behind the player.
                sheet.paste(region(photo, (.013, .05, .18, .58), (70, 132)), (x + 2, y + 25))
                sheet.paste(region(photo, (.66, .20, .987, .55), (194, 132)), (x + 74, y + 25))
            label = record["subset"] + " standard" if inserts else record["finish"]
            draw.text((x + 3, y + 3), label, fill="black", font=font)
        sheet.save(output / filename, quality=89, optimize=True, subsampling=0)

    standards = [r for r in records if r["finish"] == "Base"]
    layout = Image.new("RGB", (len(standards) * 174, 266), "white")
    draw = ImageDraw.Draw(layout)
    for i, r in enumerate(standards):
        with Image.open(source / r["file"]) as image:
            sample = ImageOps.contain(image.convert("RGB"), (168, 238), Image.Resampling.LANCZOS)
            layout.paste(sample, (i * 174 + 3, 25))
        draw.text((i * 174 + 3, 3), r["subset"], fill="black", font=font)
    layout.save(output / "chrome-standard-layouts.jpg", quality=87, optimize=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("references", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    build(args.references, args.output)
