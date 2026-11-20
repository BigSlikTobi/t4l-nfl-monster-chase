"""Measure repeating edges and border hue on rectified portrait fronts."""
import numpy as np
from PIL import Image


WIDTH = 384
HEIGHT = 536


def edge_spacing(rgb):
    # Each row votes on how often a vertical edge repeats. A square grid
    # repeats at a similar spacing when measured in the other direction.
    edges = np.linalg.norm(np.diff(rgb, axis=1), axis=2)
    edges = np.minimum(edges, np.quantile(edges, 0.94, axis=1, keepdims=True))
    length = rgb.shape[1]
    interior = edges[:, int(0.08 * length):int(0.92 * length)]
    centered = interior - interior.mean(axis=1, keepdims=True)
    spectrum = abs(np.fft.rfft(centered * np.hanning(interior.shape[1]), axis=1)).mean(axis=0)
    cycles_per_card_width = np.fft.rfftfreq(interior.shape[1]) * WIDTH
    search = (cycles_per_card_width >= 17) & (cycles_per_card_width <= 43)
    peak = np.where(search, spectrum, 0).argmax()
    return spectrum[peak] / max(1, np.median(spectrum[search])), cycles_per_card_width[peak]


def border_color(photo):
    hsv = np.asarray(photo.convert("HSV"), dtype=float) / 255
    strips = [hsv[9:20, 30:-30], hsv[-20:-9, 30:-30], hsv[30:-30, 7:14], hsv[30:-30, -14:-7]]
    votes = []
    for strip in strips:
        hue, saturation, brightness = strip.transpose(2, 0, 1)
        visible = (saturation > 0.43) & (brightness > 0.22)
        pink = np.mean(visible & (hue > 0.83) & (hue < 0.98))
        lime = np.mean(visible & (hue > 0.15) & (hue < 0.30))
        votes.append([pink, lime])
    pink, lime = np.median(votes, axis=0)
    if pink > 0.5:
        return "pink"
    if lime > 0.5:
        return "lime"
    return "no dominant pink or lime"


def measure(path):
    with Image.open(path) as source:
        if max(source.size) > 2400 or not 0.55 <= source.width / source.height <= 0.88:
            return "unsuitable crop", "", "", "", "", ""
        photo = source.convert("RGB").resize((WIDTH, HEIGHT), Image.Resampling.LANCZOS)
    rgb = np.asarray(photo, dtype=float)
    horizontal, x_pitch = edge_spacing(rgb)
    vertical, y_pitch = edge_spacing(rgb.transpose(1, 0, 2))
    # These thresholds were fitted to one print pattern. A grid can support
    # several editions even when its border has a recognizable color.
    grid = (min(horizontal, vertical) >= 1.30 and
            22 <= x_pitch <= 29 and 22 <= y_pitch <= 29 and
            max(x_pitch, y_pitch) / min(x_pitch, y_pitch) <= 1.10)
    color = border_color(photo)
    # A saturated frame corroborates a slightly weaker second-axis peak.
    tinted_grid = (color in ("pink", "lime") and min(horizontal, vertical) >= 1.25
                   and max(horizontal, vertical) >= 1.30 and 22 <= x_pitch <= 29
                   and 22 <= y_pitch <= 29 and max(x_pitch, y_pitch) / min(x_pitch, y_pitch) <= 1.10)
    grid = grid or tinted_grid
    return ("grid" if grid else "no decision", color if grid else "",
            round(horizontal, 3), round(vertical, 3), round(x_pitch, 2), round(y_pitch, 2))
