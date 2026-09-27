#!/usr/bin/env python3
"""List warning_allowlist.txt entries with no plausible call site in the C++ sources.

Only lists. Nothing is removed. [Co-developed with claude code -- Adam]
"""
import os
import re
import sys

REPO = "/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-contract-0911"
ALLOW = os.path.join(REPO, "tools/contract_test/warning_allowlist.txt")
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')

# Every adjacent-string-literal run in the C++ sources, concatenated, with the spdlog
# placeholders filled in with a handful of stand-ins so an anchored allowlist regex can match.
STANDINS = ["42", "s1-eth1", "routing_lock", "10.0.0.1", "", "some text", "-3"]


def candidates():
    out = []
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in
                   (".git", "build", "venv", "scratch", "node_modules", "doc")]
        for name in files:
            if not name.endswith((".cpp", ".hpp", ".h", ".cc")):
                continue
            path = os.path.join(root, name)
            try:
                src = open(path, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            # runs of adjacent literals
            pos = 0
            while True:
                m = LITERAL.search(src, pos)
                if not m:
                    break
                parts = [m.group(1)]
                pos = m.end()
                while True:
                    tail = src[pos:]
                    stripped = tail.lstrip()
                    if not stripped.startswith('"'):
                        break
                    m2 = LITERAL.match(stripped)
                    if not m2:
                        break
                    parts.append(m2.group(1))
                    pos += (len(tail) - len(stripped)) + m2.end()
                text = "".join(parts).replace('\\"', '"').replace("\\\\", "\\")
                if len(text) >= 8:
                    out.append((os.path.relpath(path, REPO), text))
    return out


def main():
    cands = candidates()
    print(f"scanned {len({c[0] for c in cands})} C++ file(s), "
          f"{len(cands)} string-literal run(s)\n")
    entries = []
    for lineno, raw in enumerate(open(ALLOW, encoding="utf-8"), 1):
        line = raw.strip()
        if not line or line.startswith("#") or " | " not in line:
            continue
        level, pattern, _why = [p.strip() for p in line.split(" | ", 2)]
        entries.append((lineno, level, pattern))

    unmatched = []
    for lineno, level, pattern in entries:
        try:
            rx = re.compile(pattern)
        except re.error as exc:
            print(f"  line {lineno}: UNCOMPILABLE {pattern!r} ({exc})")
            continue
        hit = None
        for path, text in cands:
            for stand in STANDINS:
                probe = re.sub(r"\{[^}]*\}", stand, text)
                if rx.search(probe):
                    hit = (path, text[:70])
                    break
            if hit:
                break
        if not hit:
            unmatched.append((lineno, level, pattern))

    print(f"{len(entries)} rule line(s); {len(entries) - len(unmatched)} matched a "
          f"C++ literal, {len(unmatched)} did not:\n")
    for lineno, level, pattern in unmatched:
        print(f"  warning_allowlist.txt:{lineno:<4} {level:<17} {pattern}")


if __name__ == "__main__":
    sys.exit(main())
