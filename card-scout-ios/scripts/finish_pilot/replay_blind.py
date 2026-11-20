"""Run the worker's recognition entry point on anonymized captures, with an empty result cache."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile

from card_lookup import CardLookup
from cardsight import Client
from catalog_supplement import load_all
from identity_decisions import IdentityResolver


def replay(inputs, work, service, public_data, workers):
    if work.exists():
        raise ValueError("A blind run needs a fresh output directory")
    cases = sorted(case for case in inputs.iterdir() if not case.name.startswith("._"))
    allowed = {"front.jpg", "back.jpg", "surface.jpg", "tilt.jpg", "capture-text.txt"}
    for case in cases:
        names = {f.name for f in case.iterdir() if not f.name.startswith("._")}
        if not case.is_dir() or not {"front.jpg", "back.jpg"} <= names <= allowed:
            raise ValueError("Unexpected replay inputs")
    work.mkdir(mode=0o700)
    with tempfile.TemporaryDirectory(dir=work) as temporary:
        scratch = Path(temporary)
        # Configuration stays on the paired service. Only its public product catalogs
        # and the usual rate-limited API client are shared with production.
        (scratch / "config.json").symlink_to((service / "config.json").resolve())
        for name in ("chrome-checklist-supplement.json", "reference-images.json",
                     "chrome-finish-surfaces.jpg", "chrome-insert-surfaces.jpg", "chrome-standard-layouts.jpg", "chrome-wave-comparison.jpg"):
            (scratch / name).symlink_to((public_data / name).resolve(strict=True))
        catalog, _ = load_all([], public_data)
        lookup = CardLookup(scratch, client=Client(service), resolver=IdentityResolver(scratch))
        output = work / "predictions"
        output.mkdir()
        def predict(case):
            job = scratch / "jobs" / case.name
            job.mkdir(parents=True)
            for name in allowed:
                if (case / name).is_file():
                    shutil.copyfile(case / name, job / name)
            try:
                result = lookup.identify(job, catalog)
                a = result["analysis"]
                record = {k: a.get(k) for k in ("player", "cardNumber", "year", "setName", "subset",
                          "identityConfirmed", "parallel", "finishState", "finishPolicy")}
                trace = job / "identity-resolution.json"
                if trace.exists():
                    d = json.loads(trace.read_text())
                    record["diagnostic"] = {k: d[k] for k in ("foilShape", "referenceSurface", "referenceInspection", "backMark", "field", "surfaceMeasurement",
                                            "tiltCandidates", "error", "lattice") if k in d}
            except Exception as error:
                record = {"errorType": type(error).__name__}
            (output / (case.name + ".json")).write_text(json.dumps(record, sort_keys=True))
        try:
            with ThreadPoolExecutor(workers) as pool:
                list(pool.map(predict, cases))
        finally:
            lookup.executor.shutdown()
        frozen = {case.name: json.loads((output / (case.name + ".json")).read_text()) for case in cases}
        data = json.dumps(frozen, sort_keys=True).encode()
        (work / "predictions.json").write_bytes(data)
        print(len(frozen), "predictions; sha256", hashlib.sha256(data).hexdigest(), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("inputs", "output", "service", "public_data"):
        parser.add_argument(arg, type=Path)
    parser.add_argument("--workers", type=int, choices=range(1, 5), default=3)
    args = parser.parse_args()
    os.umask(0o077)
    replay(args.inputs, args.output, args.service, args.public_data, args.workers)
