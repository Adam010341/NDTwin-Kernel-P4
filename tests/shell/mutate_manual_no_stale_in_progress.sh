#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_manual_no_stale_in_progress.sh.
#
# [Co-developed with claude code -- Adam]
#
# What is being protected. doc/2026-08-17_testing-manual.md carried three caveats saying `ndt
# clean` and `ndt help` misbehave and that FIX-NDT-6 is working on it. FIX-NDT-6 merged at
# 05:56 on 2026-09-12 (`1656bdba`); one of the three had already been verified wrong by
# FIX-DOC-3 and was left standing because it was out of scope. That is KNOWN-ISSUES G-52's
# shape, and nothing in this repository notices it: a stale caveat stays grammatical forever.
# The test this gate protects asks git instead -- is the merge that fixes the ticket an ancestor
# of HEAD -- so the judgement does not decay. These mutations put each half of the old document
# back, one at a time, and name the case that has to notice.
#
# 🔴 M5 IS THE ONE WORTH READING. It takes `ndt help` away from the TEST. The test's case 1 is
# a NEGATIVE assertion -- help no longer names three ports -- and an empty help text satisfies
# it perfectly, which is the whole trap: an authority that says nothing agrees with every
# document. If case 2 were not standing next to case 1, the tool-side half of that file would be
# a decoration. M5 is how that is shown rather than claimed.
#
# 🔴 M7 IS THE SECOND DIRECTION. The fix that passes a naive "stop calling my processes
# strangers" test is "never say it at all", and that sentence is the only warning before a :8000
# nobody here started. M7 deletes it from a copy of `ndt`; case 4 has to go red.
#
# 🔴 M4 IS THE SUPPRESSION'S OWN TEST. A manual line may quote what the document USED to say --
# FIX-DOC-3 left such a note at §2.8 -- and the test skips lines carrying 原本 or 曾經. M4 takes
# that word away, and case 6 has to see the line again. A suppression nobody can make fire is a
# suppression that covers everything.
#
# C1 at the end is the opposite: an HTML-comment reword, which must leave every case green. A
# gate with no surviving control cannot tell "the suite is sensitive" from "stuck red".
#
# 🔴 ONE MUTATION, ONE ANCHOR. Two mutations sharing an anchor string make
# check_gate_anchors.py's ok(N) count anchor CELLS rather than mutations, and the difference is
# printed nowhere (KNOWN-ISSUES G-56). Every anchor below is distinct.
#
# 🔴 NOTHING IN THE WORKTREE IS WRITTEN. All three files under test are copied into a temp dir
# and the copies are mutated; the test takes MANUAL= and NDT=, and is itself run from a copy for
# M5, so this gate is safe to run while another session is editing this shared tree. Byte
# identity of all three originals is asserted at the end anyway.
#
# Nothing is built, no lab is touched: the test reads a markdown file, reads `ndt`, runs `ndt
# help` (which prints text and exits 2) and asks git about ancestry.
#
# Exit: 0  every mutation caught by the case it names, the control survived, originals intact
#       1  a mutation SURVIVED, or the control went red, or an original changed
#       2  the baseline was already red, or a mutation could not be applied
#
# Usage:  bash tests/shell/mutate_manual_no_stale_in_progress.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
MANUAL="$REPO/doc/2026-08-17_testing-manual.md"
TEST="$REPO/tests/shell/test_manual_no_stale_in_progress.sh"
NDT="$REPO/tools/test_workflow/ndt"
PY="${PY:-/usr/bin/python3}"

BK=$(mktemp -d /tmp/manual-stale-mutate-XXXXXX)
trap 'rm -rf "$BK"' EXIT
MANUAL_SHA=$(sha256sum "$MANUAL" | cut -d' ' -f1)
TEST_SHA=$(sha256sum "$TEST" | cut -d' ' -f1)
NDT_SHA=$(sha256sum "$NDT" | cut -d' ' -f1)

MUTATIONS=0
SURVIVORS=0
UNAPPLIED=0
CONTROLS=0
CONTROLS_RED=0

apply_exact() {   # apply_exact <file to edit in place> <anchor \x1f replacement>
    "$PY" - "$1" "$2" <<'PY'
import sys
p, spec = sys.argv[1], sys.argv[2]
old, new = spec.split("\x1f")
s = open(p, encoding="utf-8").read()
n = s.count(old)
assert n == 1, "anchor is not unique (%d matches): %r" % (n, old[:70])
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
}

# A mutated copy of the manual; prints its path, or an empty string if the anchor missed.
manual_mutant() {   # manual_mutant <tag> <anchor \x1f replacement>
    local out="$BK/manual.$1.md"; cp "$MANUAL" "$out"
    apply_exact "$out" "$2" >&2 || { echo ""; return; }
    echo "$out"
}

# An UNMUTATED copy of the manual, for the mutations applied to the test or to `ndt` instead.
# It is a copy and not "$MANUAL" itself because check_gate_anchors.py reads a declared repo path
# followed by a quoted literal as "anchor in that file", and the case name passed alongside it
# would be reported as a missing anchor in the manual (FIX-DOC-3 §2, 100/101).
manual_copy() {
    local out="$BK/manual.pristine.md"; cp "$MANUAL" "$out"; echo "$out"
}

# A mutated copy of the test itself, run against a pristine copy of the manual.
test_mutant() {   # test_mutant <tag> <anchor \x1f replacement>
    local out="$BK/test.$1.sh"; cp "$TEST" "$out"
    apply_exact "$out" "$2" >&2 || { echo ""; return; }
    echo "$out"
}

# A mutated copy of `ndt`. It still runs: only a string inside cmd_clean is changed.
ndt_mutant() {   # ndt_mutant <tag> <anchor \x1f replacement>
    local out="$BK/ndt.$1"; cp "$NDT" "$out"
    apply_exact "$out" "$2" >&2 || { echo ""; return; }
    echo "$out"
}

run_triple() {   # run_triple <test file> <manual file> <ndt file>
    # REPO_UNDER_TEST pins the tree git is asked about: the M5 mutant runs from $BK, and without
    # this its case 0 would go red because /tmp is not a repository, muddying the one case M5 is
    # about.
    MANUAL="$2" NDT="$3" REPO_UNDER_TEST="$REPO" bash "$1" 2>&1
}

report() {   # report <label> <test file> <manual file> <ndt file> <case that must go red>
    local out rc
    MUTATIONS=$((MUTATIONS + 1))
    if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
        printf '  DID-NOT-APPLY %-54s (anchor missed; nothing was tested)\n' "$1"
        UNAPPLIED=$((UNAPPLIED + 1))
        return
    fi
    out=$(run_triple "$2" "$3" "$4"); rc=$?
    if ! grep -qE '^  (ok|FAILED) ' <<<"$out"; then
        printf '  TEST-DID-NOT-RUN %-51s (mutant broke the file; harness error)\n' "$1"
        sed -n '1,4p' <<<"$out" | sed 's/^/                /'
        UNAPPLIED=$((UNAPPLIED + 1))
        return
    fi
    if [[ "$rc" -ne 0 ]] && grep -q "FAILED   $5" <<<"$out"; then
        printf '  caught        %-54s (%s went red)\n' "$1" "$5"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED      %-54s (%s stayed green -- that case proves nothing)\n' "$1" "$5"
        grep -E '^  (ok|FAILED) ' <<<"$out" | sed 's/^/                /'
    fi
}

control() {   # control <label> <test file> <manual file> <ndt file>
    local out rc
    CONTROLS=$((CONTROLS + 1))
    out=$(run_triple "$2" "$3" "$4"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  SURVIVED      %-54s (control, as required)\n' "$1"
    else
        CONTROLS_RED=$((CONTROLS_RED + 1))
        printf '  🔴 CONTROL WENT RED %-47s\n' "$1" >&2
        grep -E '^  FAILED ' <<<"$out" | sed 's/^/                /' >&2
    fi
}

echo "baseline (unmutated) must be green:"
if run_triple "$TEST" "$MANUAL" "$NDT" | tail -1 | grep -q ' 0 failed'; then
    echo "  ok            baseline green"
else
    echo "  REFUSE: baseline is not green; mutation results would be meaningless"
    run_triple "$TEST" "$MANUAL" "$NDT" | sed 's/^/    /'
    exit 2
fi
echo
echo "mutations:"

PRISTINE=$(manual_copy)

# --- M1: the first caveat goes back to being an open defect -- the ticket itself ---------------
M=$(manual_mutant m1 '🏁 **已修（工具的措辭，2026-09-12 merge `1656bdba`，FIX-NDT-6 ④）'$'\x1f''🔴 **已知（工具的措辭，FIX-NDT-6 在修）')
report "M1: the clean caveat is written back as an open defect" "$TEST" "$M" "$NDT" "case 5a caveat 'clean-calls-your-fabric-residue' is retracted and says what merged it"

# --- M2: a caveat loses its marker, so the sweep cannot be seen ---------------------------------
M=$(manual_mutant m2 '<!-- NDT-MERGED-CAVEAT:BEGIN help-deep-names-three-ports 1656bdba -->
'$'\x1f''')
report "M2: the help caveat's BEGIN marker is deleted" "$TEST" "$M" "$NDT" "case 5b caveat 'help-deep-names-three-ports' is retracted and says what merged it"

# --- M3: a caveat claims a merge that is not in the tree ----------------------------------------
# "Fixed in <sha>" is only worth reading if the sha is reachable from here. A typo, a
# branch-local sha, or a commit that was rebased away must not read as merged.
M=$(manual_mutant m3 'NDT-MERGED-CAVEAT:BEGIN clean-advises-deep-on-your-own 1656bdba'$'\x1f''NDT-MERGED-CAVEAT:BEGIN clean-advises-deep-on-your-own 0123456789ab')
report "M3: a caveat names a merge that is not an ancestor" "$TEST" "$M" "$NDT" "case 5c caveat 'clean-advises-deep-on-your-own' is retracted and says what merged it"

# --- M4: the suppression word is taken off a line that really is stale ---------------------------
# §2.8's note is allowed to quote the old wording because it says 原本. Without that word the
# line is an ordinary claim about a merged ticket, and case 6 has to see it.
M=$(manual_mutant m4 '原本這裡寫「FIX-NDT-6 在修」'$'\x1f''這裡寫的是「FIX-NDT-6 在修」')
report "M4: a stale line loses the word that excuses it" "$TEST" "$M" "$NDT" "case 6  no line calls a ticket unfixed when its merge is already in the tree"

# --- M5: the TEST loses its authority ------------------------------------------------------------
# 🔴 The direction that matters. Case 1 is a negative assertion about `ndt help`; with no help
# text at all it is green, and only case 2 stands between this file and a certificate that means
# nothing.
T=$(test_mutant m5 'HELP="$(bash "$NDT" help 2>&1)"'$'\x1f''HELP=""')
report "M5: the test stops reading 'ndt help'" "$T" "$PRISTINE" "$NDT" "case 2  'ndt help' prints --deep's size out of ports.sh's table"

# --- M6: the sweep takes the measurement with it --------------------------------------------------
# Retracting a caveat is not deleting what was measured under it. The pids are the record.
M=$(manual_mutant m6 'XX  residue: ndtwin_kernel pid 2511227 holding :8000 (tcp)'$'\x1f''XX  residue: 某個行程 holding :8000 (tcp)')
report "M6: the measured record is dropped with the caveat" "$TEST" "$M" "$NDT" "case 9  the measured record inside the third caveat survived the sweep"

# --- M7: the tool is 'fixed' by never warning about a stranger again --------------------------------
N=$(ndt_mutant m7 'err "   this stack did not start it; to kill it too:  ndt down --deep"'$'\x1f''err "   nothing on this machine is worth mentioning"')
report "M7: 'ndt' stops warning about a stranger at all" "$TEST" "$PRISTINE" "$N" "case 4  'ndt' still has the stranger sentence (the fix was not 'never say it')"

# --- C1 (control): a source comment is reworded; nothing about the contract changes -----------------
echo
M=$(manual_mutant c1 '🟠 轉述 KNOWN-ISSUES G-45 與 fix/FIX-NDT-6-SUMMARY.md §1.4：本單沒有開 lab 重跑'$'\x1f''🟠 轉述 KNOWN-ISSUES G-45 與 fix/FIX-NDT-6-SUMMARY.md §1.4；本單並未開 lab 重跑')
if [[ -z "$M" ]]; then
    echo "  DID-NOT-APPLY C1 (control): the comment it rewords is not there" >&2
    UNAPPLIED=$((UNAPPLIED + 1))
else
    control "C1 (control): a source comment is reworded" "$TEST" "$M" "$NDT"
fi

echo
ok=0
if [[ "$(sha256sum "$MANUAL" | cut -d' ' -f1)" == "$MANUAL_SHA" ]]; then
    echo "baseline byte-identical: yes  doc/2026-08-17_testing-manual.md"
else
    echo "🔴 THE MANUAL CHANGED WHILE THIS GATE RAN -- a mutant may be on disk"; ok=1
fi
if [[ "$(sha256sum "$TEST" | cut -d' ' -f1)" == "$TEST_SHA" ]]; then
    echo "baseline byte-identical: yes  tests/shell/test_manual_no_stale_in_progress.sh"
else
    echo "🔴 THE TEST CHANGED WHILE THIS GATE RAN -- a mutant may be on disk"; ok=1
fi
if [[ "$(sha256sum "$NDT" | cut -d' ' -f1)" == "$NDT_SHA" ]]; then
    echo "baseline byte-identical: yes  tools/test_workflow/ndt"
else
    echo "🔴 ndt CHANGED WHILE THIS GATE RAN -- a mutant may be on disk"; ok=1
fi
echo "GATE-SUMMARY mutations=$MUTATIONS survived=$SURVIVORS unapplied=$UNAPPLIED controls=$CONTROLS red=$CONTROLS_RED"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived; $CONTROLS control(s), $CONTROLS_RED went red"
[[ "$SURVIVORS" -eq 0 && "$UNAPPLIED" -eq 0 && "$CONTROLS_RED" -eq 0 && "$ok" -eq 0 ]]
