#!/usr/bin/env python3
"""Does the anchor checker actually check every gate -- and say so when it cannot?

[Co-developed with claude code -- Adam]

KNOWN-ISSUES L-3. `check_gate_anchors.py` could not parse four gates, among them
`mutate_lock_lease_all.sh`, the 23-mutation driver that is the entire kernel-side evidence for
A-9. It reported them UNPARSED / NO-ANCHORS and exited 2, which is honest but useless: nobody
reads the difference between "24 gates, 20 ok" and "24 gates, 20 ok and 4 never looked at", and
a mutation gate whose anchors have drifted stops mutating anything while still reporting
success. The checker exists precisely to catch that.

Most cases here run against a SYNTHETIC repository built in a temp directory, one gate per
shape, because the four shapes are the thing under test and the real gates change under other
sessions' hands all night. The last case is the real repo, and it asserts only what cannot drift
out from under it: that those four gates are read at all.

FINDING #78 adds the last two classes, and a different failure. The checker decided which argument
of a gate names a FILE with `"/" in v`, so a gate whose target sits at the repo ROOT --
`TOPO="$REPO/testbed_topo.py"`, which reduces to `testbed_topo.py` -- had all 23 of its anchors
attributed to the only slash-bearing string it declared and was reported MISSING:23. Not
NO-ANCHORS, not UNPARSED: a confident wrong answer, which is the thing every paragraph above is
written to prevent. Its gate is tests/shell/mutate_gate_anchors_root_files.sh.

🔴 The load-bearing half of this file is the NEGATIVE direction. A checker that returns "ok" for
everything would pass every _ok case here; each of those is therefore paired with a _drift case
where the anchor has been moved and the checker must go red, and with the loudness cases, where
a gate it genuinely cannot read must exit 2 and say NOT CHECKED rather than shrug. Recognising a
root file has its own negative half in NotEveryStringIsAFile: a fix that promoted any argument to
a path would satisfy every root-target case here and check nothing at all.

    python3 tests/python/test_check_gate_anchors.py
    CHECKER_UNDER_TEST=/tmp/x/check.py python3 tests/python/test_check_gate_anchors.py
"""
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CHECKER = os.environ.get("CHECKER_UNDER_TEST",
                         os.path.join(REPO, "tests", "shell", "check_gate_anchors.py"))

# --- the target files the synthetic gates mutate -------------------------------------------------
# `epsilon.py` sits at the repo ROOT and is the whole point of the last two classes: it has no
# directory part, so a file-vs-anchor test spelled `"/" in v` cannot see that it is a file.
# `tests/python/test_epsilon.py` is the OTHER path its gate declares and does NOT contain the
# anchor -- it is the file the root target's anchors were misattributed to (finding #78).
TARGETS = {
    "src/alpha.cpp": "void a()\n{\n    int alpha = 1;\n}\n",
    "src/beta.cpp": "void b()\n{\n    long beta = 3;\n}\n",
    "tools/gamma.sh": "#!/bin/sh\ngamma_value=7\necho $gamma_value\n",
    "src/delta.cpp": "void d()\n{\n    short delta = 5;\n}\n",
    "epsilon.py": "epsilon_value = 11\n\n\ndef e():\n    return epsilon_value\n",
    "tests/python/test_epsilon.py": "import epsilon\n\n\ndef test_e():\n    assert epsilon.e()\n",
    # Deliberately holds the SAME line twice: the target for GATE_REPLACE_ALL, whose anchor is
    # meant to match everywhere. A checker that assumes every anchor wants exactly one match
    # would read this as DUP:1 against a gate that is not broken -- see 2026-09-04 note there.
    "src/zeta.cpp": "void z1()\n{\n    int zeta = 1;\n}\n\nvoid z2()\n{\n    int zeta = 1;\n}\n",
}

# --- one gate per shape, each written the way the real gate of that shape is written -------------

# (a) mutate_a2_poll_round.sh / mutate_ryu_rest_topology_bounded.sh: a table built by add() and
#     walked through parallel arrays.
GATE_ARRAY = r"""#!/usr/bin/env bash
set -uo pipefail
SRC=src/alpha.cpp
MUT_LABEL=(); MUT_ANCHOR=(); MUT_REPL=()
add() { MUT_LABEL+=("$1"); MUT_ANCHOR+=("$2"); MUT_REPL+=("$3"); }

add "alpha becomes two" \
    '    int alpha = %(ALPHA)s;' \
    '    int alpha = 99;'

anchor_count() { python3 -c 'import sys;print(open(sys.argv[1]).read().count(sys.argv[2]))' "$1" "$2"; }
mutate() {
    local label="$1" anchor="$2" repl="$3"
    local n; n=$(anchor_count "$SRC" "$anchor")
    [[ "$n" == 1 ]] || { echo "anchor drift"; exit 2; }
}
for i in "${!MUT_LABEL[@]}"; do
    mutate "${MUT_LABEL[$i]}" "${MUT_ANCHOR[$i]}" "${MUT_REPL[$i]}"
done
"""

# (b) mutate_a7_dispatch_status.sh: one table function walked twice through a callback, so the
#     command word of every mutation call is a variable.
GATE_CALLBACK = r"""#!/usr/bin/env bash
set -uo pipefail
DSP=src/beta.cpp
mutate()  { local label="$1" file="$2" anchor="$3" repl="$4"; echo "$label $file $anchor $repl"; }
dry_one() { local label="$1" file="$2" anchor="$3"; echo "$label $file $anchor"; }
each_mutation() {
    local m="$1"
    "$m" "beta becomes four" "$DSP" \
        '    long beta = %(BETA)s;' \
        '    long beta = 99;'
}
each_mutation dry_one
each_mutation mutate
"""

# (c) mutate_ndt_sample_rate_reads_both_bounds.sh: anchor and replacement packed into ONE
#     argument separated by $'\x1f', and the call itself inside a command substitution.
GATE_PACKED = r"""#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
GAMMA="$REPO/tools/gamma.sh"
BK=$(mktemp -d)
mutant() {
    local out="$BK/gamma.$1"; cp "$GAMMA" "$out"
    python3 - "$out" "$2" <<'PY'
import sys
p, spec = sys.argv[1], sys.argv[2]
a, b = spec.split("\x1f")
s = open(p).read(); assert s.count(a) == 1; open(p, "w").write(s.replace(a, b))
PY
    echo "$out"
}
m1=$(mutant m1 'gamma_value=%(GAMMA)s'$'\x1f''gamma_value=99')
echo "$m1"
"""

# (d) mutate_lock_lease_all.sh: a driver with no anchors of its own that runs other gates.
GATE_DRIVER = r"""#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATES=(
    "$HERE/mutate_shape_array.sh"      # the table shape
    "$HERE/mutate_shape_callback.sh"   # the callback shape
)
for gate in "${GATES[@]}"; do
    bash "$gate" || exit 1
done
"""

# (e) a gate whose table this tool genuinely cannot read: the anchor is a variable that is never
#     assigned anywhere in the script, so there is no text to count.
GATE_UNREADABLE = r"""#!/usr/bin/env bash
set -uo pipefail
SRC=src/delta.cpp
TBL=()
addx() { TBL+=("$1"); }
addx "$ANCHOR_FROM_SOMEWHERE_ELSE"
apply_it() { echo "$1 $2"; }
for i in "${!TBL[@]}"; do
    apply_it "$SRC" "${TBL[$i]}"
done
"""

# (m) mutate_harness_instruments.sh's shape: a quoted python ARGUMENT (not a heredoc) whose body
#     is a bare `s.replace(old, new)` -- no count, Python's own default -- so it touches EVERY
#     occurrence of `old` in the file uniformly. 2026-09-04: the checker used to assume every
#     anchor wants exactly one match and reported that gate DUP:1 against src/zeta.cpp's
#     equivalent (FINDING-02 Defect B's hidden-owner sentinel, which collapses at two call sites
#     on purpose). `_replace_call_want` reads a bare two-argument call as "at least one, no upper
#     bound" instead.
GATE_REPLACE_ALL = r"""#!/usr/bin/env bash
set -uo pipefail
SRC=src/zeta.cpp
mutate() { :; }
mutate "m1" "$SRC" '
s = s.replace("    int zeta = %(ZETA)s;", "    int zeta = 99;")
'
"""

# (n) mutate_logger_cli.sh's widen() shape: a named-role applier (`apply`, argument 2 is
#     "anchor") called with a DIFFERENT function's raw, unnamed positional parameters ($1 $2 $3
#     forwarded after a `shift`-loop, never bound to a local). 2026-09-04: "$2" is a parameter
#     reference exactly like "$anchor" is, and was misread as two characters of literal text --
#     see is_whole_param_ref.
GATE_POSITIONAL = r"""#!/usr/bin/env bash
set -uo pipefail
SRC=src/delta.cpp
apply() { local file="$1" anchor="$2" new="$3"; echo "$file $anchor $new"; }
relay() {
    local label="$1"; shift
    while [[ $# -ge 3 ]]; do
        apply "$1" "$2" "$3"
        shift 3
    done
}
relay "delta becomes ninety-nine" "$SRC" '    short delta = 5;' '    short delta = 99;'
"""

# --- the repo-root shapes (finding #78) ----------------------------------------------------------
# Each of these is the SAME gate written four ways, differing only in how the target file is named.
# The target is at the repo root in all four, so `$REPO/epsilon.py` reduces to `epsilon.py` and the
# old `"/" in v` test could not see it. Each shape is one of the four places the tool asks "is this
# string a file or is it the text to search for", so each is separately reddenable.

# (f) mutate_testbed_banner.sh itself: the applier NAMES its arguments, so the file is read off
#     `local ... file="$2" old="$3"` and looked up positionally (path_at).
GATE_ROOT_NAMED = r"""#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ROOTF="$REPO/epsilon.py"
PY_TEST="$REPO/tests/python/test_epsilon.py"
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    echo "$label $file $old $new"
}
mutant m1 "$ROOTF" \
    'epsilon_value = %(EPSILON)s' \
    'epsilon_value = 99'
echo "$PY_TEST" >/dev/null
"""

# (f2) the same shape with a SHORT anchor. 🔴 This is the only gate here that isolates the
#      positional lookup: the generic `<file> then a quoted literal` rule ignores anything under
#      eight characters, so an applier's own named roles are the single route to this anchor's
#      file. Without it, putting the slash-only test back in the positional lookup changes nothing
#      any case can see -- the generic rule reaches the same call line and pins it anyway.
GATE_ROOT_SHORT = r"""#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ROOTF="$REPO/epsilon.py"
PY_TEST="$REPO/tests/python/test_epsilon.py"
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    echo "$label $file $old $new"
}
mutant m1 "$ROOTF" 'def e()' 'def z()'
echo "$PY_TEST" >/dev/null
"""

# (g) the file is baked into the applier's own body and named nowhere on the call line
#     (mutate_topk_recursive_lock.sh's shape) -- read by default_file_of.
GATE_ROOT_BAKED = r"""#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ROOTF="$REPO/epsilon.py"
PY_TEST="$REPO/tests/python/test_epsilon.py"
MUT_LABEL=(); MUT_ANCHOR=(); MUT_REPL=()
add() { MUT_LABEL+=("$1"); MUT_ANCHOR+=("$2"); MUT_REPL+=("$3"); }
add "epsilon becomes 99" \
    'epsilon_value = %(EPSILON)s' \
    'epsilon_value = 99'
mutate() { local label="$1" anchor="$2" repl="$3"; grep -F -- "$anchor" "$ROOTF"; }
for i in "${!MUT_LABEL[@]}"; do
    mutate "${MUT_LABEL[$i]}" "${MUT_ANCHOR[$i]}" "${MUT_REPL[$i]}"
done
echo "$PY_TEST" >/dev/null
"""

# (h) nothing names the file at the call site OR in the applier's body, so the anchor falls back
#     to the UNION of every path the gate declares -- and the root target has to be in that union,
#     or the union is every file the gate declares except the one it mutates.
GATE_ROOT_UNION = r"""#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ROOTF="$REPO/epsilon.py"
PY_TEST="$REPO/tests/python/test_epsilon.py"
MUT_LABEL=(); MUT_ANCHOR=(); MUT_REPL=()
add() { MUT_LABEL+=("$1"); MUT_ANCHOR+=("$2"); MUT_REPL+=("$3"); }
add "epsilon becomes 99" \
    'epsilon_value = %(EPSILON)s' \
    'epsilon_value = 99'
mutate() { local label="$1" anchor="$2" repl="$3"; echo "$label $anchor $repl"; }
for i in "${!MUT_LABEL[@]}"; do
    mutate "${MUT_LABEL[$i]}" "${MUT_ANCHOR[$i]}" "${MUT_REPL[$i]}"
done
echo "$ROOTF $PY_TEST" >/dev/null
"""

# (i) the hand-rolled applier that names no roles at all: `<something> <file> <anchor> <repl>`,
#     read by the generic rule -- an argument that resolves to a path, the quoted text after it.
GATE_ROOT_GENERIC = r"""#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ROOTF="$REPO/epsilon.py"
PY_TEST="$REPO/tests/python/test_epsilon.py"
mutate_must_die() { grep -F -- "$2" "$1" >/dev/null; }
mutate_must_die "$ROOTF" \
    'epsilon_value = %(EPSILON)s' \
    'epsilon_value = 99'
echo "$PY_TEST" >/dev/null
"""

# (j) `python3 - "$FILE" <<PY`: the file is an OPERAND of the interpreter and the anchors are in
#     the heredoc that follows. Read in pass 1, which decides operands the same way.
GATE_ROOT_HEREDOC = r"""#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ROOTF="$REPO/epsilon.py"
PY_TEST="$REPO/tests/python/test_epsilon.py"
python3 - "$ROOTF" <<'PY'
import sys
p = sys.argv[1]
old = "epsilon_value = %(EPSILON)s"
s = open(p).read()
assert s.count(old) == 1
open(p, "w").write(s.replace(old, "epsilon_value = 99"))
PY
echo "$PY_TEST" >/dev/null
"""

# (k) the python body is a quoted ARGUMENT rather than a heredoc, and the file is another argument
#     on the same line. 🔴 This gate also declares a directory (`DOCS`), because the fallback for a
#     bare basename here is "join it to each declared directory" -- for a root target that invents
#     `doc/audit/epsilon.py`, a file in no rev, and the anchors are then reported against it.
GATE_ROOT_INLINE = r"""#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ROOTF="$REPO/epsilon.py"
PY_TEST="$REPO/tests/python/test_epsilon.py"
DOCS="$REPO/doc/audit"
apply_py() { python3 -c "$1" "$2"; }
apply_py 'import sys, pathlib
old = "epsilon_value = %(EPSILON)s"
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(old, "epsilon_value = 99"))
' "$ROOTF"
echo "$PY_TEST $DOCS" >/dev/null
"""

# (l) `mutate <label> <file> <anchor> <repl>` where the applier names no roles and bakes in no
#     file either. The tool has a special case for `mutate` calls that carry NO file (the file is
#     in the function's body) -- if a root target is not seen as a file, this call is mistaken for
#     that shape and the gate is refused outright: "mutate names no file and none is implied".
GATE_ROOT_MUTATE = r"""#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ROOTF="$REPO/epsilon.py"
PY_TEST="$REPO/tests/python/test_epsilon.py"
mutate() { echo "$1 $2 $3 $4"; }
mutate m1 "$ROOTF" 'epsilon_value = %(EPSILON)s' 'epsilon_value = 99'
echo "$PY_TEST" >/dev/null
"""

# (j) 🔴 THE OTHER DIRECTION. Same gate as (f), except the root-shaped name it declares is not in
#     this rev's tree at all. A fix that promoted every filename-shaped word to a path would pin
#     the anchor to it and report a counted verdict; the tool must instead say it could not work
#     out which file this is, and exit 2. `no_such_root_file.py` is the ONLY path this gate
#     declares, so there is nothing for the anchor to be quietly attributed to either.
GATE_ROOT_ABSENT = r"""#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ROOTF="$REPO/no_such_root_file.py"
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    echo "$label $file $old $new"
}
mutant m1 "$ROOTF" \
    'epsilon_value = %(EPSILON)s' \
    'epsilon_value = 99'
"""


def load_checker():
    """The tool itself, imported from whichever copy is under test."""
    spec = importlib.util.spec_from_file_location("cga_under_test", CHECKER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def extracted_anchors(gate_text, gate_name):
    """Just the TEXTS the checker decided it must look for -- the thing an anchor is."""
    anchors, _problems, _delegates = load_checker().extract(
        gate_text, gate_name, "tests/shell/" + gate_name)
    return [t for _f, t, _k, _w, _n in anchors]


def git(repo, *args):
    return subprocess.run(("git", "-C", repo) + args, capture_output=True, text=True)


class Fixture:
    """A throwaway git repo holding the four target files and one gate per shape."""

    def __init__(self, alpha="1", beta="3", gamma="7", epsilon="11", zeta="1", gates=None):
        self.dir = tempfile.mkdtemp(prefix="anchorcheck_")
        for rel, body in TARGETS.items():
            full = os.path.join(self.dir, rel)
            # A repo-ROOT target has no directory part -- os.makedirs("") raises.
            if os.path.dirname(full):
                os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w") as fh:
                fh.write(body)
        os.makedirs(os.path.join(self.dir, "tests", "shell"), exist_ok=True)
        subs = {"ALPHA": alpha, "BETA": beta, "GAMMA": gamma, "EPSILON": epsilon, "ZETA": zeta}
        want = gates if gates is not None else ["array", "callback", "packed", "driver"]
        source = {"array": GATE_ARRAY, "callback": GATE_CALLBACK, "packed": GATE_PACKED,
                  "driver": GATE_DRIVER, "unreadable": GATE_UNREADABLE,
                  "replace_all": GATE_REPLACE_ALL, "positional": GATE_POSITIONAL,
                  "root_named": GATE_ROOT_NAMED, "root_short": GATE_ROOT_SHORT,
                  "root_baked": GATE_ROOT_BAKED,
                  "root_union": GATE_ROOT_UNION, "root_generic": GATE_ROOT_GENERIC,
                  "root_heredoc": GATE_ROOT_HEREDOC, "root_inline": GATE_ROOT_INLINE,
                  "root_mutate": GATE_ROOT_MUTATE, "root_absent": GATE_ROOT_ABSENT}
        for name in want:
            with open(os.path.join(self.dir, "tests", "shell",
                                   "mutate_shape_%s.sh" % name), "w") as fh:
                fh.write(source[name] % subs)
        git(self.dir, "init", "-q")
        git(self.dir, "add", "-A")
        git(self.dir, "-c", "user.email=t@t", "-c", "user.name=t",
            "commit", "-q", "-m", "fixture")

    def run(self, *extra):
        p = subprocess.run([sys.executable, CHECKER, "HEAD", "--repo", self.dir] + list(extra),
                           capture_output=True, text=True)
        return p.returncode, p.stdout, p.stderr

    def extract_gate(self, name):
        """The tool's own reading of one synthetic gate, with the file test wired to this repo.

        `exists` is what the tool asks git in a real run (`git show <rev>:<path>`); against a
        fixture on disk the same question is `is there a file at this repo-relative path`.
        """
        mod = load_checker()
        rel = "tests/shell/mutate_shape_%s.sh" % name
        with open(os.path.join(self.dir, rel)) as fh:
            text = fh.read()
        return mod.extract(text, os.path.basename(rel), rel,
                           lambda p: os.path.isfile(os.path.join(self.dir, p)))

    def cell(self, out, gate):
        for line in out.splitlines():
            if line.startswith("mutate_shape_%s.sh" % gate):
                return line.split(None, 1)[1].strip()
        return "(no row)"

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class ShapesAreChecked(unittest.TestCase):
    """Each shape resolves its anchors -- and goes red when the anchor moves."""

    def test_array_table_ok(self):
        f = Fixture()
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertTrue(f.cell(out, "array").startswith("ok"),
                        "array-table gate: %s\n%s" % (f.cell(out, "array"), out))
        self.assertEqual(0, rc, out + err)

    def test_array_table_drift_is_caught(self):
        f = Fixture(alpha="2")          # the source moved; the gate's anchor did not
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertTrue(f.cell(out, "array").startswith("MISSING"),
                        "a drifted table anchor must be MISSING, got %s\n%s"
                        % (f.cell(out, "array"), out))
        self.assertEqual(1, rc, out + err)

    def test_callback_dispatch_ok(self):
        f = Fixture()
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertTrue(f.cell(out, "callback").startswith("ok"),
                        "callback gate: %s\n%s" % (f.cell(out, "callback"), out))

    def test_callback_dispatch_drift_is_caught(self):
        f = Fixture(beta="4")
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertTrue(f.cell(out, "callback").startswith("MISSING"),
                        "a drifted callback anchor must be MISSING, got %s\n%s"
                        % (f.cell(out, "callback"), out))
        self.assertEqual(1, rc, out + err)

    def test_packed_argument_ok(self):
        f = Fixture()
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertTrue(f.cell(out, "packed").startswith("ok"),
                        "packed-argument gate: %s\n%s" % (f.cell(out, "packed"), out))

    def test_packed_argument_drift_is_caught(self):
        f = Fixture(gamma="8")
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertTrue(f.cell(out, "packed").startswith("MISSING"),
                        "a drifted packed anchor must be MISSING, got %s\n%s"
                        % (f.cell(out, "packed"), out))
        self.assertEqual(1, rc, out + err)

    def test_bare_replace_matches_every_occurrence_and_is_ok(self):
        """`s.replace(old, new)` -- no count argument -- is Python's own "replace all", and
        src/zeta.cpp holds the anchor twice on purpose. Before 2026-09-04 this read DUP:1
        against a gate that is not broken (tests/shell/mutate_harness_instruments.sh)."""
        f = Fixture(gates=["replace_all"])
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertTrue(f.cell(out, "replace_all").startswith("ok"),
                        "bare-replace gate: %s\n%s" % (f.cell(out, "replace_all"), out))
        self.assertEqual(0, rc, out + err)

    def test_bare_replace_drift_is_still_caught(self):
        """The relaxation is "no upper bound", not "anything goes": zero matches is still
        MISSING."""
        f = Fixture(gates=["replace_all"], zeta="2")   # the gate's anchor now matches nothing
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertTrue(f.cell(out, "replace_all").startswith("MISSING"),
                        "a drifted bare-replace anchor must be MISSING, got %s\n%s"
                        % (f.cell(out, "replace_all"), out))
        self.assertEqual(1, rc, out + err)

    def test_an_array_reference_is_never_reported_as_a_literal_anchor(self):
        """`${MUT_ANCHOR[$i]}` is an indirection, not text. Reporting it as a literal is what
        made mutate_ryu_rest_topology_bounded.sh read MISSING against an intact file."""
        anchors = extracted_anchors(GATE_ARRAY % {"ALPHA": "1", "BETA": "3", "GAMMA": "7"},
                                    "mutate_shape_array.sh")
        self.assertTrue(anchors, "the array-table gate yielded no anchors at all")
        for text in anchors:
            self.assertIsNone(
                re.search(r"\$\{?[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\}", text),
                "an unexpanded parameter was recorded as the text to search for: %r" % text)
        self.assertIn("    int alpha = 1;", anchors,
                      "the array's real anchor was not among %r" % (anchors,))

    def test_bare_numbered_parameters_are_whole_param_refs(self):
        """is_whole_param_ref's own docstring already claimed "$1" as an example; before
        2026-09-04 the regex disagreed with it -- the name part required a letter or underscore
        FIRST, so a bare numbered positional parameter never matched."""
        mod = load_checker()
        for word in ("$1", "$2", "$9", "${1}", "${10}", "$anchor", "${MUT_ANCHOR[$i]}"):
            self.assertTrue(mod.is_whole_param_ref(word, '"'),
                            "%r must be recognised as a parameter reference" % word)
        for word in ("value=$1", "$1x", "plain text"):
            self.assertFalse(mod.is_whole_param_ref(word, '"'),
                             "%r is not WHOLLY a parameter reference" % word)

    def test_a_relayed_positional_parameter_is_not_read_as_literal_anchor_text(self):
        """tests/shell/mutate_logger_cli.sh's widen() relays its OWN "$1" "$2" "$3" into
        apply(), whose signature names argument 2 "anchor" -- the same shape as GATE_POSITIONAL
        below. Before the fix above, "$2" was recorded as two characters of literal text and
        reported MISSING against every file the gate declares, since nothing spells out "$2"."""
        anchors, problems, _delegates = load_checker().extract(
            GATE_POSITIONAL, "mutate_shape_positional.sh",
            "tests/shell/mutate_shape_positional.sh")
        self.assertEqual([], problems, problems)
        texts = [t for _f, t, _k, _w, _n in anchors]
        self.assertNotIn("$2", texts,
                         "a relayed positional parameter must never be read as literal anchor "
                         "text: %r" % (anchors,))
        self.assertIn("    short delta = 5;", texts,
                      "the real anchor, reached through relay()'s own literal call site, must "
                      "still be found: %r" % (anchors,))

    def test_positional_relay_gate_is_ok_end_to_end(self):
        f = Fixture(gates=["positional"])
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertTrue(f.cell(out, "positional").startswith("ok"),
                        "positional-relay gate: %s\n%s" % (f.cell(out, "positional"), out))
        self.assertEqual(0, rc, out + err)


class DriverInheritsItsDelegatesVerdict(unittest.TestCase):
    """mutate_lock_lease_all.sh has no anchors of its own. NO-ANCHORS was honest and useless;
    'ok' would be a lie. Its verdict has to be its delegates'."""

    def test_driver_is_ok_when_every_delegate_is(self):
        f = Fixture()
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertTrue(f.cell(out, "driver").startswith("ok-via"),
                        "driver gate: %s\n%s" % (f.cell(out, "driver"), out))

    def test_driver_is_not_ok_when_a_delegate_anchor_has_drifted(self):
        f = Fixture(beta="4")           # only the callback delegate is broken
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertFalse(f.cell(out, "driver").startswith("ok"),
                         "the driver reported ok while a gate it runs cannot apply its "
                         "mutation:\n" + out)
        self.assertNotEqual(0, rc, out + err)

    def test_a_delegate_that_was_not_checked_is_not_inherited_as_ok(self):
        f = Fixture()
        self.addCleanup(f.close)
        rc, out, err = f.run("--gates", "mutate_shape_driver.sh")
        self.assertFalse(f.cell(out, "driver").startswith("ok"),
                         "the driver reported ok on delegates nobody checked:\n" + out)
        self.assertEqual(2, rc, out + err)


class CouldNotCheckIsNeverAPass(unittest.TestCase):
    """🔴 The whole point of L-3: a gate this tool cannot read must be impossible to mistake for
    a gate it read and liked."""

    def test_an_unreadable_gate_exits_2_and_says_so(self):
        f = Fixture(gates=["array", "unreadable"])
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertEqual(2, rc, "an unreadable gate must exit 2, got %d\n%s%s" % (rc, out, err))
        self.assertIn("NOT checked", out, out)
        self.assertFalse(f.cell(out, "unreadable").startswith("ok"),
                         "unreadable cell: %s" % f.cell(out, "unreadable"))

    def test_the_count_of_unchecked_cells_is_printed_and_repeated_on_stderr(self):
        """A run whose stdout is teed into a log still has to shout on the error stream."""
        f = Fixture(gates=["array", "unreadable"])
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertIn("NOT CHECKED AT ALL", out, out)
        self.assertIn("COULD NOT BE CHECKED", err,
                      "nothing on stderr said the run checked less than it printed:\n" + err)

    def test_a_clean_run_does_not_claim_anything_was_unchecked(self):
        """The control: the loud path must not fire on a healthy tree, or it says nothing."""
        f = Fixture()
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertEqual(0, rc, out + err)
        self.assertIn("0 not ok, of which 0 were NOT CHECKED AT ALL", out, out)
        self.assertEqual("", err.strip(), err)


class ATargetAtTheRepoRootIsAFile(unittest.TestCase):
    """Finding #78. `TOPO="$REPO/testbed_topo.py"` reduces to `testbed_topo.py`, which has no
    slash in it, and `"/" in v` was the whole of the file-vs-anchor test. The first gate in this
    repo whose target sits at the root (mutate_testbed_banner.sh) therefore had all 23 of its
    anchors attributed to the only slash-bearing string it declares -- the python test path, where
    none of them are -- and was reported MISSING:23.

    🔴 That is the one failure this tool is built to make impossible: not NO-ANCHORS, not UNPARSED,
    but a CONFIDENT WRONG ANSWER. A reader of that cell would go looking for 23 drifted anchors
    that had not drifted. Each case below is one of the four places the tool asks the question.
    """

    def assert_pinned(self, gate):
        """Which file did the tool decide these anchors live in?

        🔴 The sharpest form of the finding, and the only form that separates the four routes to a
        file from one another. Reaching the right count through the declared-path UNION is the
        tool's own honest weakening, and it hides a broken route: an anchor the union happens to
        find still reads ok(1). These cases therefore assert the anchor was PINNED -- a single
        path, spelled `epsilon.py` -- and not a tuple of everything the gate declares.
        """
        f = Fixture(gates=[gate])
        self.addCleanup(f.close)
        anchors, problems, _delegates = f.extract_gate(gate)
        self.assertEqual([], problems, problems)
        self.assertTrue(anchors, "gate %s yielded no anchors at all" % gate)
        for target, text, _kind, _where, _want in anchors:
            self.assertEqual("epsilon.py", target,
                             "the root target's anchor %r was attributed to %r"
                             % (text, target))

    def test_a_named_root_target_resolves(self):
        """(f) end to end, the shape mutate_testbed_banner.sh is written in: the applier names
        its own arguments (`local ... file="$2" old="$3"`) and the file is looked up by
        position. This is the cell that read MISSING:23 in the real repo."""
        f = Fixture(gates=["root_named"])
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertTrue(f.cell(out, "root_named").startswith("ok"),
                        "a gate whose target is at the repo root: %s\n%s"
                        % (f.cell(out, "root_named"), out))
        self.assertEqual(0, rc, out + err)

    def test_a_named_root_targets_anchor_is_pinned_to_the_root_file(self):
        """(f) the whole call line, reached by every rule that can read it."""
        self.assert_pinned("root_named")

    def test_a_short_anchors_root_target_is_pinned_by_the_appliers_named_roles(self):
        """(f2) the positional lookup ON ITS OWN. The generic rule skips anchors under eight
        characters, so this is the one gate here whose file has a single route to it."""
        self.assert_pinned("root_short")

    def test_a_baked_in_root_targets_anchor_is_pinned_to_the_root_file(self):
        """(g) the file is named only inside the applier's body."""
        self.assert_pinned("root_baked")

    def test_a_generic_appliers_root_target_is_pinned_to_the_root_file(self):
        """(i) `mutate_must_die "$FILE" '<anchor>' '<repl>'` -- an argument that resolves to a
        path, the quoted text right after it."""
        self.assert_pinned("root_generic")

    def test_a_heredoc_appliers_root_target_is_pinned_to_the_root_file(self):
        """(j) the file is an operand of `python3 - "$FILE" <<PY`."""
        self.assert_pinned("root_heredoc")

    def test_an_inline_python_appliers_root_target_is_pinned_to_the_root_file(self):
        """(k) the python body is a quoted argument and the file is another argument beside it.
        The fallback here is worse than the union: a bare basename gets joined to every directory
        the gate declares, so the anchors are reported against a path in no rev at all."""
        self.assert_pinned("root_inline")

    def test_a_root_target_is_in_the_union_an_unpinned_anchor_falls_back_to(self):
        """(h) nothing names the file at the call site or in the body, so the anchor is counted
        across every path the gate declares. Leaving the root target out of that union makes it
        every file the gate declares EXCEPT the one it mutates."""
        f = Fixture(gates=["root_union"])
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertTrue(f.cell(out, "root_union").startswith("ok"),
                        "root target reached through the declared-path union: %s\n%s"
                        % (f.cell(out, "root_union"), out))
        self.assertEqual(0, rc, out + err)

    def test_a_bare_mutate_call_with_a_root_target_is_read_not_refused(self):
        """(l) `mutate <label> <file> <anchor> <repl>` is mistaken for the shape whose file lives
        in the function body when the root target is not seen as a file -- and that shape, with no
        file in the body either, is refused outright. Not a wrong count this time: a whole gate
        reported unreadable because its target has no directory part."""
        f = Fixture(gates=["root_mutate"])
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertTrue(f.cell(out, "root_mutate").startswith("ok"),
                        "a `mutate` call naming a root target: %s\n%s"
                        % (f.cell(out, "root_mutate"), out))
        self.assertEqual(0, rc, out + err)

    def test_a_root_targets_drift_is_still_caught(self):
        """🔴 The control for this whole class. Every case above is satisfied by a tool that
        answers ok to everything; this one is not. The anchor and the file disagree, and the
        cell has to go red -- in the root file, which is now where it is being counted."""
        f = Fixture(epsilon="12", gates=["root_named"])
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertTrue(f.cell(out, "root_named").startswith("MISSING"),
                        "a drifted anchor in a repo-root file must be MISSING, got %s\n%s"
                        % (f.cell(out, "root_named"), out))
        self.assertEqual(1, rc, out + err)


class NotEveryStringIsAFile(unittest.TestCase):
    """🔴 The relaxing direction. Recognising a repo-root file must not become "any argument is a
    file": a string that neither carries a directory part nor names something this rev's tree
    actually holds is NOT a path, and an anchor whose file could not be worked out stays
    unresolved -- reported as NOT checked, exit 2, never counted against a file somebody guessed.
    """

    def test_a_root_target_that_is_not_in_the_tree_is_not_checked(self):
        f = Fixture(gates=["root_absent"])
        self.addCleanup(f.close)
        rc, out, err = f.run()
        self.assertFalse(f.cell(out, "root_absent").startswith("ok"),
                         "a target nobody can resolve read as a pass: %s\n%s"
                         % (f.cell(out, "root_absent"), out))
        self.assertIn("NOT checked", out, out)
        self.assertEqual(2, rc, "an unresolvable target must exit 2 (NOT CHECKED), not 1 "
                                "(checked and found wanting):\n%s%s" % (out, err))
        self.assertIn("COULD NOT BE CHECKED", err, err)

    def test_a_bare_name_is_a_path_only_when_the_tree_holds_one(self):
        """git's answer, not the string's shape. Both directions, on the same name."""
        is_path = load_checker().is_repo_path
        self.assertTrue(is_path("epsilon.py", lambda p: True))
        self.assertFalse(is_path("epsilon.py", lambda p: False),
                         "a filename-shaped word was called a path with no tree holding it")
        self.assertFalse(is_path("epsilon.py"),
                         "with no way to ask, a bare name must not be guessed at")

    def test_anchor_text_is_never_promoted_to_a_file(self):
        """The control at the predicate itself: even a tree that answers yes to everything must
        not turn the text a gate searches for into the file it searches in."""
        is_path = load_checker().is_repo_path
        yes = lambda p: True
        for text in ("    int alpha = 1;", "epsilon_value = 11", "def e():",
                     "        return (self.expected > 0\n                and self.ok)",
                     "OK | sFlow reachability: OK", "", "epsilon_value"):
            self.assertFalse(is_path(text, yes),
                             "anchor text was accepted as a file: %r" % text)

    def test_a_path_with_a_directory_part_still_needs_no_permission(self):
        """The slash rule is unchanged: it never asked the tree and still does not, or every
        gate in the repo would change its verdict on a rev that moved a file."""
        is_path = load_checker().is_repo_path
        self.assertTrue(is_path("src/alpha.cpp"))
        self.assertTrue(is_path("src/alpha.cpp", lambda p: False))


class TheRealGatesAreRead(unittest.TestCase):
    """The four gates L-3 names, in this repo, at HEAD.

    Deliberately NOT asserting that their anchors all resolve: another session may legitimately
    move one tonight, and that is a MISSING -- a checked verdict. What must never come back is
    UNPARSED or NO-ANCHORS, which mean the gate was not examined at all.
    """

    FOUR = ["mutate_a2_poll_round.sh", "mutate_a7_dispatch_status.sh",
            "mutate_lock_lease_all.sh", "mutate_ndt_sample_rate_reads_both_bounds.sh",
            "mutate_ryu_rest_topology_bounded.sh"]
    # The driver's three delegates. They have to be in the same run: a driver whose delegates
    # nobody checked is VIA-UNCHECKED, which is correct and is not a verdict on the driver.
    DELEGATES = ["mutate_lock_lease_expiry.sh", "mutate_lock_ownership.sh",
                 "mutate_lock_renew_expiry.sh"]

    def setUp(self):
        if not os.path.isdir(os.path.join(REPO, ".git")):
            self.skipTest("not a git checkout")

    def test_none_of_the_five_is_unreadable(self):
        p = subprocess.run([sys.executable, CHECKER, "HEAD", "--repo", REPO,
                            "--gates"] + self.FOUR + self.DELEGATES,
                           capture_output=True, text=True)
        rows = {}
        for line in p.stdout.splitlines():
            if line.startswith("mutate_"):
                name, _, rest = line.partition(" ")
                rows[name] = rest.strip()
        for gate in self.FOUR:
            self.assertIn(gate, rows, p.stdout)
            self.assertNotIn(rows[gate], ("UNPARSED", "NO-ANCHORS", "VIA-UNCHECKED",
                                          "PENDING-VIA"),
                             "%s is still not being checked: %s\n%s"
                             % (gate, rows[gate], p.stdout))

    def test_the_a9_driver_names_the_gates_it_delegates_to(self):
        mod = load_checker()
        rel = "tests/shell/mutate_lock_lease_all.sh"
        text = subprocess.run(["git", "-C", REPO, "show", "HEAD:" + rel],
                              capture_output=True, text=True).stdout
        anchors, problems, delegates = mod.extract(text, os.path.basename(rel), rel)
        self.assertEqual([], problems, problems)
        self.assertEqual(3, len(delegates),
                         "the A-9 driver runs three gates; the checker found %r" % (delegates,))
        for d in delegates:
            self.assertTrue(d.startswith("tests/shell/mutate_"), d)


if __name__ == "__main__":
    unittest.main(verbosity=2)
