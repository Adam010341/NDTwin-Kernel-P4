#!/usr/bin/env python3
"""How many edges did the twin see carrying the flow, in each sampling-error window of a run?

[Co-developed with claude code -- Adam]

🔴 WHY THIS IS A FILE (ruling 39(8)). The threat to validity FINDINGS registers -- N counts the
edges the TWIN read non-zero, and the twin is the instrument under evaluation -- was first
written as "all 27 windows read 4", which was wrong; the correction ({0: 9, 4: 18} in the fourth
campaign) was then true only on the strength of one count somebody made by hand. This prints the
count per window, the distribution, and -- because analyse.py's sampling_summary() takes
`links_used` from the FIRST window of a cell (members[0], ruling 37(8)) -- which count each cell
actually used and whether its three windows agree.

It reads window.json files and nothing else, and writes nothing. The "used" column is what
analyse.links_for_prediction returns for the cell's first window -- the analysis' own function,
so a group with no non-zero edge shows the registered 4 it falls back to, not the 0 it read.

Usage:  tests/scan_onpath_edges.py <run directory>
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import analyse                                      # noqa: E402


def windows(root):
    found = []
    for path, dirs, files in os.walk(root):
        dirs.sort()
        if "window.json" in files:
            with open(os.path.join(path, "window.json")) as fh:
                document = json.load(fh)
            if document.get("invalid"):
                continue
            peaks = document.get("per_edge_peak_bps") or {}
            carrying = sorted(key for key, value in peaks.items() if value)
            used = analyse.links_for_prediction(document)[0]
            found.append((path, document.get("group"), document.get("offered_mbit"), carrying,
                          used))
    return sorted(found)          # the order analyse.walk_raw sorts windows in: by directory


def main(argv):
    if len(argv) != 2:
        print("usage: scan_onpath_edges.py <run directory>", file=sys.stderr)
        return 2
    root = argv[1]
    rows = windows(root)
    print("window                              group         Mbit  non-zero edges")
    for path, group, rate, carrying, _used in rows:
        print("  %-34s %-12s %5g  %d  %s" % (os.path.relpath(path, root), group, rate,
                                             len(carrying), " ".join(carrying)))
    overall, by_group = {}, {}
    for _path, group, _rate, carrying, _used in rows:
        overall[len(carrying)] = overall.get(len(carrying), 0) + 1
        by_group.setdefault(group, {})
        by_group[group][len(carrying)] = by_group[group].get(len(carrying), 0) + 1
    print("\nwindows: %d" % len(rows))
    print("distribution of non-zero edge counts, all windows: %s"
          % json.dumps(dict(sorted(overall.items()))))
    for group in sorted(by_group):
        print("  %-12s %s" % (group, json.dumps(dict(sorted(by_group[group].items())))))
    print("\nper cell: the N analyse.py uses (links_for_prediction on its FIRST window, members[0])"
          "\n          against the non-zero count of each of the cell's windows")
    cells, used_by_cell = {}, {}
    for _path, group, rate, carrying, used in rows:
        cells.setdefault((group, rate), []).append(len(carrying))
        used_by_cell.setdefault((group, rate), used)
    disagree = 0
    for (group, rate), counts in sorted(cells.items(), key=lambda kv: (kv[0][0], kv[0][1])):
        agree = len(set(counts)) == 1
        disagree += not agree
        fallback = " (registered fallback: no edge read non-zero)" if counts[0] == 0 else ""
        print("  %-12s %5g Mbit  used %d%s   windows %s  %s"
              % (group, rate, used_by_cell[(group, rate)], fallback, counts,
                 "agree" if agree else "DISAGREE -- the first wins"))
    print("\ncells whose windows disagree on the edge count: %d of %d" % (disagree, len(cells)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
