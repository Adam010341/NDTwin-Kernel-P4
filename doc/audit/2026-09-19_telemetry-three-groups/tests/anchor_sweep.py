#!/usr/bin/env python3
"""Every place that names a line of this round's code BY ITS TEXT, and whether it still resolves.

[Co-developed with claude code -- Adam]

🔴 WHY THIS IS A FILE, AND WHY IT HAS TWO SECTIONS (ruling 39(2)). Until round 10 this sweep was
a harness in a scratchpad and only its log survived. Round 8's log had two sections -- the
gate's own anchors AND ten external ones (the gate's --self-test, the offline suite's pre-fix
controls, the red runs' restore anchors) -- and round 9's log had only the first: the ten
external anchors were not scanned and nothing said so. A sweep that can silently shrink is the
same instrument failure it exists to catch, so both sections are now code, and the log prints
how many entries each section held.

Section (1): the mutation gate's anchors. They are extracted by letting BASH PARSE the gate
(its mutation block is sourced into stubs that only record their arguments), not by re-typing
them here -- a re-typed anchor is itself a drift.

Section (2): everything else that names those lines by text, each with the number of hits it
is DECLARED to have (ST-1 is built never to match; the offline suite's slice end occurs twice by
design), plus the text patches this round's red runs apply (tests/red/*.json) and the revision a
red run takes code from with `git show`.

Usage:   tests/anchor_sweep.py [--tree <round directory>]
Exit:    0 every entry resolves as declared, 1 one does not, 2 refused (could not parse).
"""
import argparse
import ast
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def gate_records(tree, block_start, block_end):
    """Run a slice of the gate under stubs; return [(label, file, anchor)] in the gate's order."""
    with open(os.path.join(tree, "tests", "mutate_analyse.sh")) as fh:
        text = fh.read()
    start, end = text.index(block_start), text.index(block_end)
    body = text[start:end]
    with tempfile.TemporaryDirectory() as work:
        out = os.path.join(work, "records")
        harness = os.path.join(work, "harness.sh")
        with open(harness, "w") as fh:
            fh.write('set -u\n'
                     'HERE="%(t)s/tests"; ROUND="%(t)s"\n'
                     'ANALYSE="$ROUND/analyse.py"; PLOT="$ROUND/plot.py"; DRIVER="$ROUND/drive_e.sh"\n'
                     'SCANNER="$HERE/hazard_scan.py"; MANIFEST="$ROUND/manifest.py"\n'
                     'SURVIVORS=0; MUTATIONS=0; DRIFTS=0\n'
                     'record() { printf "%%s\\0%%s\\0%%s\\0" "$1" "$2" "$3" >> "%(o)s"; }\n'
                     'mutant() { record "$1" "$2" "$3"; echo "$1"; }\n'
                     'mutant_tests() { record "$1" "$HERE/$(basename "$2")" "$3"; echo "$1"; }\n'
                     'report() { :; }; report_shell() { :; }; control() { :; }\n'
                     % {"t": tree, "o": out})
            fh.write(body)
        subprocess.run(["bash", harness], check=True, stdout=subprocess.DEVNULL)
        with open(out, "rb") as fh:
            fields = fh.read().decode().split("\0")[:-1]
    return [tuple(fields[i:i + 3]) for i in range(0, len(fields), 3)]


def hits(tree, relative, anchor):
    with open(os.path.join(tree, relative)) as fh:
        return fh.read().count(anchor)


def offline_anchors(tree):
    """The pre-fix controls of tests/test_drive_e_offline.sh section 7, read out of the file."""
    with open(os.path.join(tree, "tests", "test_drive_e_offline.sh")) as fh:
        text = fh.read()
    section = text[text.index("=== 7. THE PRE-FIX CONTROLS"):text.index("=== 7b.")]
    sed = re.search(r"sed 's\|(.*?)\|", section).group(1)
    fixed = re.search(r"fixed = '''(.*?)'''", section, re.S).group(1)
    start = ast.literal_eval(re.search(r"start = s\.index\((.*?)\)\n", section).group(1))
    mid = ast.literal_eval(re.search(r"end = s\.index\((.*?)\)\n", section).group(1))
    tail = ast.literal_eval(re.search(r"tail_end = s\.index\((.*?), end\)", section).group(1))
    grep = re.search(r'grep -cE "(\^\[\[:space:\]\]\*.*? release 2>&1 .*?sed)"', section).group(1)
    # what bash hands grep: inside double quotes a backslash is removed only before $ ` " \ --
    # so `\\\$NDT` is `\$NDT` (a literal dollar to ERE) and `\|` stays `\|`
    pattern = re.sub(r'\\([$`"\\])', r"\1", grep).replace("[[:space:]]", r"\s")
    # 🔴 THE POSITIVE CONTROL. This entry is declared to have 0 hits, and 0 is also what a
    # broken regex gives. The first version of this file had exactly that bug (it unquoted
    # `\\\$` to `\\$`, a literal backslash then end-of-line). The regex must find the pre-fix
    # line the offline suite writes into its copy, or the entry is refused.
    old_shape = ast.literal_eval(re.search(r"old_shape = (\(.*?\))\n", section, re.S).group(1))
    if not re.search(pattern, old_shape.splitlines()[0]):
        raise ValueError("the 7(c) regex %r does not match the pre-fix line %r it exists to find"
                         % (pattern, old_shape))
    return sed, fixed, start, mid, tail, pattern


def main(argv=None):
    parser = argparse.ArgumentParser(description="anchor sweep")
    parser.add_argument("--tree", default=os.path.dirname(HERE), help="the round directory")
    args = parser.parse_args(argv)
    tree = os.path.abspath(args.tree)
    try:
        mutations = gate_records(tree, "# --- the registered intervals",
                                 "# --- nothing underneath the gate moved")
        selftest = gate_records(tree, 'echo "self-test (a)', 'echo "--- self-test expectations"')
        sed, fixed, start, mid, tail, grep_re = offline_anchors(tree)
    except (OSError, ValueError, AttributeError, subprocess.CalledProcessError) as error:
        print("REFUSE: could not extract the anchors (%s) -- no verdict" % error)
        return 2

    bad = 0
    print("--- (1) tests/mutate_analyse.sh: every mutation and control anchor")
    seen = {}
    for label, path, anchor in mutations:
        count = hits(tree, os.path.relpath(path, tree), anchor)
        ok = count == 1
        bad += not ok
        seen.setdefault((path, anchor), []).append(label)
        print("  %-6s %-14s hits=%d  %-4s %s" % (label, os.path.basename(path), count,
                                                  "ok" if ok else "BAD",
                                                  anchor.split("\n")[0][:60]))
    print("  --> %d anchors, %d that do not resolve exactly once" % (len(mutations), bad))
    for (_path, _anchor), labels in sorted(seen.items(), key=lambda kv: kv[1]):
        if len(labels) > 1:
            print("  (%s share one anchor with different replacements; the gate applies each to "
                  "its own copy)" % " and ".join(labels))

    by_label = {label: (path, anchor) for label, path, anchor in mutations}
    external = []
    for label, path, anchor in selftest:
        want = 0 if label == "st_drift" else 1
        name = {"st_drift": "gate --self-test ST-1 (must NOT match, by design)",
                "st_partial": "gate --self-test ST-2 (the status --check FAILURES line)"}[label]
        external.append((name, hits(tree, os.path.relpath(path, tree), anchor), want))
    external += [
        ("offline 7(a) sed anchor", hits(tree, "drive_e.sh", sed), 1),
        ("offline 7(b) the four split locals", hits(tree, "drive_e.sh", fixed), 1),
        ("offline 7(c) slice start", hits(tree, "drive_e.sh", start), 1),
        ("offline 7(c) slice mid (unique; the search starts here)", hits(tree, "drive_e.sh", mid), 1),
        ("offline 7(c) slice end (2 in the file, asserted after the cut)",
         hits(tree, "drive_e.sh", tail), 2),
    ]
    with open(os.path.join(tree, "drive_e.sh")) as fh:
        driver_lines = fh.read().splitlines()
    external.append(("offline 7(c) grep: pre-fix release shape absent from the driver (its regex;"
                     " positive control passed)",
                     sum(1 for line in driver_lines if re.search(grep_re, line)), 0))
    external += [
        ("red-run 35-2b restore anchor (identical to M-E34)",
         hits(tree, "plot.py", by_label["m34"][1]), 1),
        ("red-run 32-2b restore anchor (identical to M-E30)",
         hits(tree, "plot.py", by_label["m30"][1]), 1),
    ]
    exists = subprocess.run(["git", "-C", HERE, "cat-file", "-e",
                             "f51ee88f:doc/audit/2026-09-19_telemetry-three-groups/analyse.py"],
                            capture_output=True).returncode == 0
    external.append(("red-run 35-1 takes analyse.py from f51ee88f by git show (no text anchor)",
                     int(exists), 1))
    red_dir = os.path.join(tree, "tests", "red")
    for name in sorted(os.listdir(red_dir)) if os.path.isdir(red_dir) else []:
        if not name.endswith(".json"):
            continue
        with open(os.path.join(red_dir, name)) as fh:
            for patch in json.load(fh):
                external.append(("red-run 39-3 patch %s (%s)" % (patch["name"], patch["file"]),
                                 hits(tree, patch["file"], patch["anchor"]), 1))
    print("\n--- (2) everything else that names those lines by text")
    wrong = 0
    for name, count, want in external:
        ok = count == want
        wrong += not ok
        print("  %-72s hits=%d want=%d %s" % (name, count, want, "ok" if ok else "BAD"))
    print("  --> %d entries, %d that do not resolve as declared" % (len(external), wrong))
    print("\nsections: (1) %d gate anchors   (2) %d external entries" % (len(mutations), len(external)))
    return 1 if (bad or wrong) else 0


if __name__ == "__main__":
    sys.exit(main())
