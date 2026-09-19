#!/usr/bin/env python3
"""Flag a `local` line whose later assignment reads a name assigned EARLIER ON THE SAME LINE.

[Co-developed with claude code -- Adam]

Bash expands every right-hand side on a `local` line before it assigns any of them, so such a
read gets the OUTER value or -- under `set -u` -- `unbound variable` and a dead shell. That is
TICKET-P3 ruling 9 / 12d (D, live-p1/05 and 06) and ruling 21(2) (this round's driver, which
died of it in its first generation).

🔴 IT EXTENDS D'S SCANNER IN THE ONE WAY THAT MATTERS HERE. D's (tests/shell/
test_live_p1_common.sh section 9) looks for `$name`, and would NOT have found this round's
actual bug: `payload=$((frame - 42))` reads `frame` with no `$` in front of it, because inside
an arithmetic expansion a bare word IS a variable reference. Both forms are flagged, and each
has its own positive control in test_drive_e_offline.sh -- a scanner with no positive control
cannot tell "found nothing" from "cannot find anything".
"""
import re
import sys

IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def split_assignments(rest):
    """Token-split a `local`'s argument text, keeping $((...)), $(...) and quotes together.

    A plain `.split()` would cut `payload=$((frame - 42))` at the space and hide the reference,
    which is exactly how the bug survived review.
    """
    tokens, current, depth, quote = [], "", 0, None
    index = 0
    while index < len(rest):
        ch = rest[index]
        if quote:
            current += ch
            if ch == "\\" and quote == '"' and index + 1 < len(rest):
                current += rest[index + 1]
                index += 2
                continue
            if ch == quote:
                quote = None
            index += 1
            continue
        if ch in "\"'":
            quote = ch
            current += ch
            index += 1
            continue
        if rest.startswith("$((", index) or rest.startswith("$(", index):
            start = index + (3 if rest.startswith("$((", index) else 2)
            depth += 1
            current += rest[index:start]
            index = start
            continue
        if ch == "(" and depth:
            depth += 1
            current += ch
            index += 1
            continue
        if ch == ")" and depth:
            depth -= 1
            current += ch
            index += 1
            continue
        if ch.isspace() and not depth:
            if current:
                tokens.append(current)
            current = ""
            index += 1
            continue
        current += ch
        index += 1
    if current:
        tokens.append(current)
    return tokens


def names_read(value):
    """Every variable name `value` reads: $name / ${name}, and bare names inside $(( ))."""
    read = set(re.findall(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)", value))
    for arith in re.findall(r"\$\(\((.*?)\)\)", value, re.S):
        read |= set(IDENT.findall(arith))
    if "$((" in value and "))" not in value:
        read |= set(IDENT.findall(value.split("$((", 1)[1]))
    return read


def scan(paths):
    findings = []
    for path in paths:
        try:
            lines = open(path, errors="replace").read().splitlines()
        except OSError:
            continue
        for number, line in enumerate(lines, 1):
            match = re.match(r"\s*local\s+(.*)$", line)
            if not match:
                continue
            assigned = []
            for token in split_assignments(match.group(1)):
                if "=" not in token:
                    assigned.append(token)
                    continue
                name, value = token.split("=", 1)
                if not IDENT.fullmatch(name):
                    continue
                for earlier in sorted(names_read(value) & set(assigned)):
                    findings.append("%s:%d %s reads $%s" % (path, number, name, earlier))
                assigned.append(name)
    return findings


if __name__ == "__main__":
    # 🔴 EXIT 1 WHEN SOMETHING IS FOUND. This used to `sys.exit(0)` unconditionally, so a saved
    # `rc=0` carried no information at all -- the scanner exited 0 whether the tree was clean or
    # full of hazards, and a log that records that rc was recording nothing. (Ruling 22(3).)
    #   0  scanned, found nothing      1  scanned, FOUND something      2  nothing to scan
    paths = sys.argv[1:]
    if not paths:
        print("hazard_scan.py: give at least one file to scan", file=sys.stderr)
        sys.exit(2)
    rows = scan(paths)
    for row in rows:
        print(row)
    print("# hazard_scan: %d file(s) scanned, %d finding(s)" % (len(paths), len(rows)))
    sys.exit(1 if rows else 0)
