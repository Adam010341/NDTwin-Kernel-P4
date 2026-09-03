#!/usr/bin/env python3
"""Comment- and string-stripped scan for every process-creation call site in the C++ tree.

grep over raw source over-reports (every doc comment that says "popen()") and under-reports
(a call reached through a wrapper, or a name built by string concatenation). This strips
comments and string literals first, so what is left is code, and reports the call sites of the
libc process-creation entry points plus the two in-tree wrappers.
"""
import re
import sys
import pathlib

ROOT = pathlib.Path(sys.argv[1]).resolve()

PRIMITIVES = [
    "popen", "system", "fork", "vfork", "execl", "execlp", "execle",
    "execv", "execvp", "execvpe", "execve", "execveat", "posix_spawn",
    "posix_spawnp", "daemon", "clone",
]
WRAPPERS = ["execCommand", "execArgv", "runSsh", "sshExec"]

TOKEN = re.compile(r"\b(" + "|".join(PRIMITIVES + WRAPPERS) + r")\s*\(")


def strip(text):
    """Blank out comments and string/char literals, keeping line structure intact."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
        elif c == "/" and nxt == "*":
            out.append("  ")
            i += 2
            while i < n and not (text[i] == "*" and i + 1 < n and text[i + 1] == "/"):
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            out.append("  ")
            i += 2
        elif c in "\"'":
            quote = c
            out.append(" ")
            i += 1
            while i < n and text[i] != quote:
                if text[i] == "\\":
                    out.append(" ")
                    i += 1
                    if i < n:
                        out.append(" ")
                        i += 1
                    continue
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            out.append(" ")
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


hits = []
for path in sorted(ROOT.rglob("*")):
    if path.suffix not in (".cpp", ".hpp", ".h", ".cc"):
        continue
    rel = path.relative_to(ROOT)
    if rel.parts[0] not in ("src", "include", "tests", "tools", "libs"):
        continue
    try:
        raw = path.read_text(errors="replace")
    except OSError:
        continue
    code = strip(raw)
    for lineno, line in enumerate(code.splitlines(), 1):
        for m in TOKEN.finditer(line):
            name = m.group(1)
            # "system(" preceded by "." or "::" that is not std:: is a member call, keep anyway.
            hits.append((str(rel), lineno, name, raw.splitlines()[lineno - 1].strip()[:110]))

for rel, lineno, name, text in hits:
    print(f"{rel}:{lineno}\t{name}\t{text}")
print(f"\n--- {len(hits)} call sites ---", file=sys.stderr)
