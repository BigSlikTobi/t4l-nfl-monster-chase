"""Measure the checkerboard and border on rectified 2025 Topps Chrome Football fronts.

Offline research only. Inputs are portrait crops from the same release.
Output describes visible features, never a catalog assignment or a base verdict.
"""

import argparse
import csv
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "mac"))
from surface_grid import measure


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("crops", type=Path, nargs="+")
    args = parser.parse_args()
    writer = csv.writer(sys.stdout)
    writer.writerow(["file", "surface", "border", "x_peak", "y_peak", "x_cycles", "y_cycles"])
    for path in args.crops:
        writer.writerow([path.name, *measure(path)])


if __name__ == "__main__":
    main()
