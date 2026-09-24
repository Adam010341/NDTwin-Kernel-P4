#!/usr/bin/env python3
"""Leaf-by-leaf comparison of two summary.json files.

[Co-developed with claude code -- Adam]

Usage: leafdiff.py A.json B.json [--show N]
Prints counts of identical / changed / only-in-A / only-in-B leaves and lists the changed ones
(path, A, B). Floats are compared exactly (the same code on the same raw must give the same bits).
"""
import json
import sys


def leaves(node, path=""):
    if isinstance(node, dict):
        for key in sorted(node):
            yield from leaves(node[key], "%s/%s" % (path, key))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from leaves(value, "%s[%d]" % (path, index))
    else:
        yield path, node


a = dict(leaves(json.load(open(sys.argv[1]))))
b = dict(leaves(json.load(open(sys.argv[2]))))
show = int(sys.argv[sys.argv.index("--show") + 1]) if "--show" in sys.argv else 10 ** 9
same = [p for p in a if p in b and a[p] == b[p]]
changed = [p for p in a if p in b and a[p] != b[p]]
only_a = [p for p in a if p not in b]
only_b = [p for p in b if p not in a]
print("A: %s\nB: %s" % (sys.argv[1], sys.argv[2]))
print("leaf values identical in both: %d" % len(same))
print("changed: %d   only in A: %d   only in B: %d" % (len(changed), len(only_a), len(only_b)))
for p in changed[:show]:
    print("  CHANGED %s\n      A=%r\n      B=%r" % (p, a[p], b[p]))
for p in only_a[:show]:
    print("  ONLY-A  %s = %r" % (p, a[p]))
for p in only_b[:show]:
    print("  ONLY-B  %s = %r" % (p, b[p]))
