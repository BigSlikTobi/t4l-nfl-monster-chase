"""Build the original, single-use T4L BURN COUNT jersey lettering with FontTools."""
from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

# Jersey-block outlines in a 32-unit cap grid. Each outline after the first is a counter.
outlines = {
    ".notdef": ["0,0 18,0 18,32 0,32", "4,4 14,4 14,28 4,28"],
    "space": [],
    "T": ["0,0 24,0 24,7 16,7 16,32 8,32 8,7 0,7"],
    "four": ["12,0 21,0 21,18 24,18 24,24 21,24 21,32 14,32 14,24 0,24 0,18",
             "14,8 7,18 14,18"],
    "L": ["0,0 8,0 8,25 21,25 21,32 0,32"],
    "B": ["0,0 17,0 22,5 22,12 18,16 23,20 23,27 18,32 0,32",
          "8,6 13,6 15,8 15,11 13,13 8,13", "8,19 14,19 16,21 16,24 14,26 8,26"],
    "U": ["0,0 8,0 8,23 10,25 14,25 16,23 16,0 24,0 24,26 18,32 6,32 0,26"],
    "R": ["0,0 17,0 23,6 23,15 18,20 25,32 16,32 10,21 8,21 8,32 0,32",
          "8,6 13,6 16,9 16,12 13,15 8,15"],
    "N": ["0,0 8,0 16,17 16,0 23,0 23,32 15,32 7,15 7,32 0,32"],
    "C": ["6,0 18,0 24,6 24,11 16,11 16,9 14,7 10,7 8,9 8,23 10,25 14,25 16,23 16,21 24,21 24,26 18,32 6,32 0,26 0,6"],
    "O": ["6,0 18,0 24,6 24,26 18,32 6,32 0,26 0,6",
          "10,7 14,7 16,9 16,23 14,25 10,25 8,23 8,9"],
}

def make_glyph(contours):
    pen = TTGlyphPen(None)
    right = 0
    for index, outline in enumerate(contours):
        points = [tuple(map(int, pair.split(','))) for pair in outline.split()]
        right = max(right, *(x for x, y in points))
        # TrueType outer contours run clockwise in a y-up coordinate system.
        shape = [(round(24 * x + 3.8 * (32 - y)) + 20, 24 * (32 - y)) for x, y in points]
        area = sum(x * v - u * y for (x, y), (u, v) in zip(shape, shape[1:] + shape[:1]))
        if (area > 0) == (index == 0):
            shape.reverse()
        pen.moveTo(shape[0])
        for point in shape[1:]:
            pen.lineTo(point)
        pen.closePath()
    return pen.glyph(), 24 * (right + 3) if contours else 235

font = FontBuilder(1000, isTTF=True)
font.setupGlyphOrder(list(outlines))
font.setupCharacterMap({ord(letter): {" ": "space", "4": "four"}.get(letter, letter)
                        for letter in set("T4L BURN COUNT")})
drawn = {name: make_glyph(contours) for name, contours in outlines.items()}
glyphs = {name: glyph for name, (glyph, advance) in drawn.items()}
font.setupGlyf(glyphs)
font.setupHorizontalMetrics({name: (advance, getattr(glyph, "xMin", 0))
                             for name, (glyph, advance) in drawn.items()})
font.setupHorizontalHeader(ascent=860, descent=-140)
font.setupNameTable({"familyName": "T4L End Zone", "styleName": "Black Italic",
                     "uniqueFontIdentifier": "T4L-EndZone-BlackItalic-1.0",
                     "fullName": "T4L End Zone Black Italic", "psName": "T4LEndZone-BlackItalic",
                     "version": "Version 1.0"})
font.setupOS2(usWeightClass=900, sCapHeight=768, sTypoAscender=860, sTypoDescender=-140,
              usWinAscent=860, usWinDescent=140, fsSelection=33)
font.setupPost(italicAngle=-9)
font.font["head"].macStyle = 3
font.font.recalcTimestamp = False
font.font["head"].created = font.font["head"].modified = 3800000000
target = Path(__file__).resolve().parents[2] / "card-scout-ios/App/T4LEndZone-BlackItalic.ttf"
font.save(target)
