#!/usr/bin/env python3
"""Are regenerated figures byte-identical to the committed ones -- and where not, WHERE do they differ?

[Co-developed with claude code -- Adam]

For every figure file: byte equality; and for a PDF that is not byte-identical, every differing
byte offset, and whether ALL of them lie inside the /CreationDate value (the one field
matplotlib's PDF backend fills from the clock, D:YYYYMMDDHHMMSS+hh'mm'). The lengths must match
too. A PDF that differs anywhere else is reported as a real difference.

Usage: compare_figures.py <committed dir> <regenerated dir> <name> [<name> ...]
"""
import os
import re
import sys

committed, regenerated = sys.argv[1], sys.argv[2]
bad = 0
for name in sys.argv[3:]:
    for ext in ("png", "pdf"):
        a = open(os.path.join(committed, "%s.%s" % (name, ext)), "rb").read()
        b = open(os.path.join(regenerated, "%s.%s" % (name, ext)), "rb").read()
        if a == b:
            print("%-26s BYTE-IDENTICAL (%d bytes)" % ("%s.%s" % (name, ext), len(a)))
            continue
        if ext != "pdf" or len(a) != len(b):
            print("%-26s DIFFERS (%d vs %d bytes)" % ("%s.%s" % (name, ext), len(a), len(b)))
            bad += 1
            continue
        offsets = [i for i in range(len(a)) if a[i] != b[i]]
        match = re.search(rb"/CreationDate \(([^)]*)\)", a)
        lo, hi = match.span(1)
        inside = all(lo <= i < hi for i in offsets)
        mb = re.search(rb"/CreationDate \(([^)]*)\)", b)
        print("%-26s not byte-identical: %d differing byte(s) at offsets %d..%d; /CreationDate value "
              "spans %d..%d; committed %s, regenerated %s; ALL differences inside /CreationDate: %s"
              % ("%s.%s" % (name, ext), len(offsets), offsets[0], offsets[-1], lo, hi - 1,
                 match.group(1).decode(), mb.group(1).decode(), inside))
        bad += not inside
print("real differences (outside /CreationDate): %d" % bad)
sys.exit(1 if bad else 0)
