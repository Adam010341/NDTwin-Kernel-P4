#!/usr/bin/env python3
"""Write a copy of tools/test_workflow/l1_unit_tests.sh that runs only its Python lanes.

  l1_derive.py <l1_unit_tests.sh> <out> [--ci] [--with-3b]

Worker pb5prep (2026-09-26). This worker may not build C++, and l1 builds it (or, under
--no-build, exits 1 when build/bin has no test binaries). So the copy keeps the script's own text
for sections 0 (gate anchors), 0b (test temp paths) and 3 (P4 proxy Python tests), and 3b
(kernel-side Python and shell tests) with --with-3b, and cuts:
  - from `if [[ $DO_BUILD -eq 1 ]]; then` up to `# --- 3. P4 proxy Python tests` (build, test-binary
    discovery, ctest, direct execution) -- all C++;
  - from `# --- 4. cross-check` to the end (ctest vs gtest counts) -- C++; replaced by a two-line
    verdict on FAILURES, the same counter the original's final verdict reads;
  - without --with-3b, section 3b.
HERE is pinned to the original's directory so components.env and every path resolve as they
would for the original. --ci also replaces the literal /home/adam/p4dev-python-venv/bin/python3 in
the P4 interpreter probe with a path that does not exist: CI's runner has no such venv, and on this
machine it would otherwise be picked whenever the interpreter under test fails the probe -- which
is exactly the case the CI emulation is for. Every substitution is asserted to happen exactly once.
[Co-developed with claude code -- Adam]
"""
import os
import sys

src, out = sys.argv[1], sys.argv[2]
ci, with3b = "--ci" in sys.argv[3:], "--with-3b" in sys.argv[3:]
text = open(src).read()


def one(needle):
    n = text.count(needle)
    if n != 1:
        sys.exit(f"expected exactly one {needle!r} in {src}, found {n}")
    return text.index(needle)


here_line = 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"'
one(here_line)
text = text.replace(here_line, f'HERE="{os.path.dirname(os.path.abspath(src))}"')

a, b = one("if [[ $DO_BUILD -eq 1 ]]; then"), one("# --- 3. P4 proxy Python tests")
text = text[:a] + "# [pb5prep] CUT: build, test-binary discovery, ctest, direct execution (C++)\n\n" + text[b:]
if not with3b:
    a, b = one("# --- 3b. kernel-side Python and shell tests"), one("# --- 4. cross-check")
    text = text[:a] + "# [pb5prep] CUT: section 3b\n\n" + text[b:]
a = one("# --- 4. cross-check")
text = text[:a] + (
    "# [pb5prep] CUT: section 4 (ctest vs gtest counts) and the C++ final verdict\n"
    'echo; echo "L1 PYTHON LANES (pb5prep copy): FAILURES=$FAILURES"\n'
    "exit $(( FAILURES > 0 ? 1 : 0 ))\n")
if ci:
    p4dev = "/home/adam/p4dev-python-venv/bin/python3"
    one(p4dev)
    text = text.replace(p4dev, "/nonexistent/ci-has-no/p4dev-python-venv/bin/python3")
open(out, "w").write(text)
os.chmod(out, 0o755)
print(f"wrote {out} (ci={ci}, with_3b={with3b})")
