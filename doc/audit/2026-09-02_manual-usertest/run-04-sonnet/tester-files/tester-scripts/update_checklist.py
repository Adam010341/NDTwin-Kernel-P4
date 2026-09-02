#!/usr/bin/env python3
"""Update specific ID-prefixed lines in ~/CHECKLIST.md in place.
Reads replacement lines from stdin as JSON: {"A1": "A1. new text -- WORKS", ...}
"""
import sys, json, os

path = os.path.expanduser("~/CHECKLIST.md")
updates = json.load(sys.stdin)

with open(path) as f:
    lines = f.readlines()

out = []
seen = set()
for line in lines:
    stripped = line.rstrip("\n")
    matched = False
    for key, newtext in updates.items():
        if stripped.startswith(key + ".") or stripped.startswith(key + " "):
            out.append(newtext + "\n")
            seen.add(key)
            matched = True
            break
    if not matched:
        out.append(line)

with open(path, "w") as f:
    f.writelines(out)

missing = set(updates.keys()) - seen
if missing:
    print("WARNING: keys not found:", missing)
else:
    print("All keys updated:", sorted(seen))
