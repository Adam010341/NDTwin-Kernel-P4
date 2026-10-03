#!/usr/bin/env python3
"""variant.py <file> <old> <new> -- replace <old> with <new> in <file>, refusing unless <old>
occurs exactly once. Prints what it did. [Co-developed with claude code -- Adam]"""
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
n = s.count(old)
if n != 1:
    print("variant: refused, %r occurs %d time(s) in %s" % (old[:60], n, path)); sys.exit(2)
open(path, "w").write(s.replace(old, new, 1))
print("variant: %s: replaced %r -> %r" % (path, old[:70], new[:70]))
