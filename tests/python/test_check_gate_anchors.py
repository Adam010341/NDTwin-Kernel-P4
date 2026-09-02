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

🔴 The load-bearing half of this file is the NEGATIVE direction. A checker that returns "ok" for
everything would pass every _ok case here; each of those is therefore paired with a _drift case
where the anchor has been moved and the checker must go red, and with the loudness cases, where
a gate it genuinely cannot read must exit 2 and say NOT CHECKED rather than shrug.

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

# --- the four target files the synthetic gates mutate -------------------------------------------
TARGETS = {
    "src/alpha.cpp": "void a()\n{\n    int alpha = 1;\n}\n",
    "src/beta.cpp": "void b()\n{\n    long beta = 3;\n}\n",
    "tools/gamma.sh": "#!/bin/sh\ngamma_value=7\necho $gamma_value\n",
    "src/delta.cpp": "void d()\n{\n    short delta = 5;\n}\n",
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

    def __init__(self, alpha="1", beta="3", gamma="7", gates=None):
        self.dir = tempfile.mkdtemp(prefix="anchorcheck_")
        for rel, body in TARGETS.items():
            full = os.path.join(self.dir, rel)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w") as fh:
                fh.write(body)
        os.makedirs(os.path.join(self.dir, "tests", "shell"), exist_ok=True)
        subs = {"ALPHA": alpha, "BETA": beta, "GAMMA": gamma}
        want = gates if gates is not None else ["array", "callback", "packed", "driver"]
        source = {"array": GATE_ARRAY, "callback": GATE_CALLBACK, "packed": GATE_PACKED,
                  "driver": GATE_DRIVER, "unreadable": GATE_UNREADABLE}
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
