#!/usr/bin/env python3
"""Has the TRUTH side of the structural reconciliation drifted from the raw it was taken from?

[Co-developed with claude code -- Adam]

tests/fixtures/real_run_inventory.json is committed, and test_real_shape.py trusts it. Nothing
re-extracts it (ruling 37(6b)), so someone could edit it to make the structural test green and no
gate would notice. This re-extracts an inventory from a run directory with the same
tests/inventory.py and compares it with the committed file, entry by entry, both directions.
Round 9 did this once by hand and kept only the output (ruling 39(9b)); this is that check as a
file. It is not a gate yet: the raw it needs is not in the repository.

Usage:  tests/check_inventory_fresh.py <run directory> [<committed inventory json>]
Exit:   0 no difference, 1 differences (listed), 2 usage.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import inventory                                    # noqa: E402


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__.split("Usage:")[1].strip(), file=sys.stderr)
        return 2
    committed_path = argv[2] if len(argv) == 3 else os.path.join(HERE, "fixtures",
                                                                  "real_run_inventory.json")
    with open(committed_path) as fh:
        committed = json.load(fh)
    fresh = json.loads(json.dumps(inventory.inventory(argv[1])))
    differences = 0
    for section in sorted(set(committed) | set(fresh)):
        mine, theirs = fresh.get(section, {}), committed.get(section, {})
        keys = sorted(set(mine) | set(theirs))
        bad = [key for key in keys if mine.get(key) != theirs.get(key)]
        differences += len(bad)
        print("  %-18s %3d entries compared, %s"
              % (section, len(keys), "all equal" if not bad else "%d DIFFER" % len(bad)))
        for key in bad:
            print("      %s\n        committed: %s\n        fresh:     %s"
                  % (key, theirs.get(key), mine.get(key)))
    print("\nDIFFERENCES BETWEEN THE COMMITTED INVENTORY AND A FRESH EXTRACTION: %d" % differences)
    return 1 if differences else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
