#!/usr/bin/env python3
"""The SHAPE of a run directory: which kinds of directory hold which kinds of file, and which
keys each of those files carries.

[Co-developed with claude code -- Adam]

🔴 WHY THIS EXISTS. Three defects in this round came from the same place, and none of them was
a mistake in the analysis: the fixture and the real raw disagreed about what a run directory
contains, so every test agreed with the code about a tree that never existed.

  * ruling 27  -- the switch manifest's `argv` is one STRING; the stub wrote a LIST, which was
                  the shape the reader assumed, so the suite was green and the first campaign
                  marked every arm invalid.
  * ruling 32(1) -- C3's two throwaway ladder arms are real directories under controls/; the
                  fixture never wrote them, so nothing could see them being pooled into a cell.
  * ruling 35(1) -- a window's `keys` is 32 fabric edges while `per_edge_peak_bps` is the 4 the
                  flow crossed; the fixture wrote 4 and 4, which made `len(keys)` look correct
                  and put five of six sampling-error verdicts in the wrong band.

A fixture shaped like the code's assumption proves nothing. This module extracts a structural
inventory from ANY run directory -- the real one and the synthetic one -- so the two can be
compared by a test instead of by somebody remembering to look.

It reads. It never writes, never imports analyse.py, and knows nothing about what the numbers
mean: only which files exist and which keys they carry.
"""
import json
import os
import re

#: digits are instance identity, not shape: k12_rep1.json and k110_rep3.json are one class.
_DIGITS = re.compile(r"\d+")

#: The files analyse.py opens. Everything else in a run directory is raw the analysis does not
#: read -- it still belongs in the inventory (a reader has to see what is there), but only these
#: have a key set the fixture is required to reproduce.
CONSUMED = ("arm.meta", "control.meta", "window.json", "ladder.tsv", "rungs.tsv", "cpu.jsonl",
            "sflow_rung<N>_before.json", "sflow_rung<N>_after.json", "emitter.log")


def file_class(name):
    """`k110_rep3.json` -> `k<N>_rep<N>.json`; `arm.meta` -> `arm.meta`."""
    return _DIGITS.sub("<N>", name)


def directory_class(path, root):
    """What kind of directory this is, by what it holds and where it sits under the run root."""
    names = set(os.listdir(path))
    relative = os.path.relpath(path, root)
    parts = [] if relative == "." else relative.split(os.sep)
    under_controls = "controls" in parts
    if "arm.meta" in names:
        return "control arm" if under_controls else "ladder arm"
    if "window.json" in names:
        return "sampling window"
    if "control.meta" in names:
        return "control"
    if not parts:
        return "run root"
    if parts == ["controls"]:
        return "controls root"
    return "generation"


def keys_of(path):
    """The key set of one file, by its kind: meta lines, JSON object keys, TSV header columns.

    A file whose keys cannot be read (a log, a binary, an unparseable JSON) reports None, which
    is not the same as "no keys" and is not compared.
    """
    name = os.path.basename(path)
    try:
        if name.endswith(".meta"):
            with open(path) as fh:
                return sorted({line.split("=", 1)[0].strip()
                               for line in fh if "=" in line and not line.startswith("#")})
        if name.endswith(".tsv"):
            with open(path) as fh:
                header = fh.readline().rstrip("\n")
            return sorted(header.split("\t")) if header else []
        if name.endswith(".jsonl"):
            with open(path) as fh:
                first = fh.readline()
            return sorted(json.loads(first)) if first.strip() else []
        if name.endswith(".json"):
            with open(path) as fh:
                document = json.load(fh)
            return sorted(document) if isinstance(document, dict) else None
    except (OSError, ValueError):
        return None
    return None


def cardinalities(path):
    """{key: length} for every top-level key of a JSON file whose value is a list or a dict.

    🔴 A KEY SET IS NOT A SHAPE. ruling 35(1)'s defect was that `keys` holds 32 edges and
    `per_edge_peak_bps` holds 4 -- the key NAMES were identical in the fixture and in the real
    raw, and only their sizes disagreed. A reconciliation that compared names alone would have
    said the fixture was faithful while the analysis divided by the wrong number.
    """
    if not path.endswith(".json") and not path.endswith(".jsonl"):
        return {}
    try:
        with open(path) as fh:
            document = json.loads(fh.readline()) if path.endswith(".jsonl") else json.load(fh)
    except (OSError, ValueError):
        return {}
    if not isinstance(document, dict):
        return {}
    return {key: len(value) for key, value in document.items()
            if isinstance(value, (list, dict))}


def inventory(root):
    """{directory class: [file classes]} and {file class: [keys]} for a whole run directory.

    Where two directories of the same class disagree about their file classes, the UNION is
    reported: a ladder arm that truncated its ladder writes fewer rung files than one that did
    not, and that is instance variation, not a difference in shape. Key sets are unioned the
    same way, and a key that appears in one file of a class is part of that class's shape.
    """
    dirs, files, sizes = {}, {}, {}
    for path, subdirs, names in os.walk(root):
        subdirs.sort()
        if not names:
            continue
        kind = directory_class(path, root)
        classes = dirs.setdefault(kind, set())
        for name in sorted(names):
            cls = file_class(name)
            classes.add(cls)
            if cls in CONSUMED:
                full = os.path.join(path, name)
                keys = keys_of(full)
                if keys is not None:
                    files.setdefault(cls, set()).update(keys)
                for key, length in cardinalities(full).items():
                    low, high = sizes.setdefault(cls, {}).get(key, (length, length))
                    sizes[cls][key] = (min(low, length), max(high, length))
    return {"directory_classes": {k: sorted(v) for k, v in sorted(dirs.items())},
            "file_keys": {k: sorted(v) for k, v in sorted(files.items())},
            # [smallest, largest] seen across every instance of that file class
            "file_sizes": {k: {key: list(value) for key, value in sorted(v.items())}
                           for k, v in sorted(sizes.items())}}


if __name__ == "__main__":                                   # pragma: no cover
    import sys
    if len(sys.argv) != 2:
        print("usage: inventory.py <run directory>", file=sys.stderr)
        raise SystemExit(2)
    print(json.dumps(inventory(sys.argv[1]), indent=2, sort_keys=True))
