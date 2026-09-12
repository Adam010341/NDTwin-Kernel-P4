#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_manual_rc_table.sh.
#
# [Co-developed with claude code -- Adam]
#
# What is being protected. doc/2026-08-17_testing-manual.md glosses the exit codes of `ndt up`,
# `ndt down` and `ndt clean`, and `ndt help` is the only place those codes are defined. Before
# FIX-NDT-8 the two agreed; after it they did not, in three places, and the manual went on
# telling readers that a restored lab answers `ndt clean` with rc 0 when that state now answers
# 3 (KNOWN-ISSUES G-53). Nothing failed. A document is not compiled, so the only way a stale
# gloss becomes loud is a gate like this one.
#
# M1-M6 and M8-M9 put a piece of the OLD manual back, one at a time, and name the case that has
# to notice. M7 is the other direction and is the one worth reading: it takes `ndt help` away
# from the TEST. A test that only asks "is every sentence the manual quotes also in the help
# text" is perfect on an empty help text -- the authority that says nothing contradicts nothing
# -- so if case 1 stayed green under M7 the whole file would be a decoration. M9 mutates the
# sentence case 14 (the control) reads, which is how this gate shows the control is load-bearing
# rather than a case that is green because it asks nothing.
#
# C1 at the end is the opposite: an HTML-comment reword, which must leave every case green. A
# gate with no surviving control cannot tell "the suite is sensitive" from "the suite is stuck
# red".
#
# 🔴 ONE MUTATION, ONE ANCHOR. Two mutations sharing an anchor string make
# check_gate_anchors.py's ok(N) count anchor CELLS rather than mutations, and the difference is
# printed nowhere (AUDIT-SCAN-1 §7-5 / KNOWN-ISSUES G-56). Every anchor below is distinct.
#
# 🔴 NOTHING IN THE WORKTREE IS WRITTEN. Both files under test are copied into a temp dir and
# the copies are mutated; the test takes MANUAL= and NDT= (and is itself run from a copy for
# M7), so this gate is safe to run while another session is editing this shared tree. Byte
# identity of both originals is asserted at the end anyway.
#
# Nothing is built, no lab is touched: the test reads a markdown file and runs `ndt help`.
#
# Exit: 0  every mutation caught by the case it names, the control survived, originals intact
#       1  a mutation SURVIVED, or the control went red, or an original changed
#       2  the baseline was already red, or a mutation could not be applied
#
# Usage:  bash tests/shell/mutate_manual_rc_table.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
MANUAL="$REPO/doc/2026-08-17_testing-manual.md"
TEST="$REPO/tests/shell/test_manual_rc_table.sh"
NDT="$REPO/tools/test_workflow/ndt"
PY="${PY:-/usr/bin/python3}"

BK=$(mktemp -d /tmp/manual-rc-mutate-XXXXXX)
trap 'rm -rf "$BK"' EXIT
MANUAL_SHA=$(sha256sum "$MANUAL" | cut -d' ' -f1)
TEST_SHA=$(sha256sum "$TEST" | cut -d' ' -f1)

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

# A mutated copy of the test itself, run against the REAL manual.
test_mutant() {   # test_mutant <tag> <anchor \x1f replacement>
    local out="$BK/test.$1.sh"; cp "$TEST" "$out"
    apply_exact "$out" "$2" >&2 || { echo ""; return; }
    echo "$out"
}

run_pair() {   # run_pair <test file> <manual file>
    MANUAL="$2" NDT="$NDT" bash "$1" 2>&1
}

report() {   # report <label> <test file> <manual file> <case that must go red>
    local out rc
    MUTATIONS=$((MUTATIONS + 1))
    if [[ -z "$2" || -z "$3" ]]; then
        printf '  DID-NOT-APPLY %-54s (anchor missed; nothing was tested)\n' "$1"
        UNAPPLIED=$((UNAPPLIED + 1))
        return
    fi
    out=$(run_pair "$2" "$3"); rc=$?
    if ! grep -qE '^  (ok|FAILED) ' <<<"$out"; then
        printf '  TEST-DID-NOT-RUN %-51s (mutant broke the file; harness error)\n' "$1"
        sed -n '1,4p' <<<"$out" | sed 's/^/                /'
        UNAPPLIED=$((UNAPPLIED + 1))
        return
    fi
    if [[ "$rc" -ne 0 ]] && grep -q "FAILED   $4" <<<"$out"; then
        printf '  caught        %-54s (%s went red)\n' "$1" "$4"
    else
        SURVIVORS=$((SURVIVORS + 1))
        printf '  SURVIVED      %-54s (%s stayed green -- that case proves nothing)\n' "$1" "$4"
        grep -E '^  (ok|FAILED) ' <<<"$out" | sed 's/^/                /'
    fi
}

control() {   # control <label> <test file> <manual file>
    local out rc
    CONTROLS=$((CONTROLS + 1))
    out=$(run_pair "$2" "$3"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  SURVIVED      %-54s (control, as required)\n' "$1"
    else
        CONTROLS_RED=$((CONTROLS_RED + 1))
        printf '  🔴 CONTROL WENT RED %-47s\n' "$1" >&2
        grep -E '^  FAILED ' <<<"$out" | sed 's/^/                /' >&2
    fi
}

echo "baseline (unmutated) must be green:"
if run_pair "$TEST" "$MANUAL" | tail -1 | grep -q ' 0 failed'; then
    echo "  ok            baseline green"
else
    echo "  REFUSE: baseline is not green; mutation results would be meaningless"
    run_pair "$TEST" "$MANUAL" | sed 's/^/    /'
    exit 2
fi
echo
echo "mutations:"

# --- M1: the rc 3 row goes back to being an rc 0 row -- the defect itself -------------------
M=$(manual_mutant m1 '| 3 | **沒有東西可量**——閒置的機器、已經收掉的 lab | `THERE WAS NOTHING TO JUDGE` |'$'\x1f''| 0 | 乾淨 | `the teardown finished and the machine verified clean` |')
report "M1: the rc 3 row is written back as an rc 0 row" "$TEST" "$M" "case 6  the rc table has a row for rc 3"

# --- M2: the refusal row disappears, so 5 goes back to being indistinguishable from 1 -------
M=$(manual_mutant m2 '| 5 | **守衛拒絕，機器一個 byte 都沒動** | `A GUARD REFUSED and nothing was torn down` |
'$'\x1f''')
report "M2: the rc 5 row is deleted" "$TEST" "$M" "case 6  the rc table has a row for rc 5"

# --- M3: the restore criterion asks for rc 0 again ------------------------------------------
# This is the one that scored a restored lab as not restored. It must not be quietly re-enterable.
M=$(manual_mutant m3 '1. **`ndt clean` 回 0 或 3。**'$'\x1f''1. **`ndt clean` 回 rc 0。**')
report "M3: the restore criterion demands rc 0 again" "$TEST" "$M" "case 12a the restore criterion accepts rc 3 from 'ndt clean' as restored"

# --- M4: a second rc table appears ----------------------------------------------------------
# Two copies of the codes is the shape of the original defect: one of them goes stale alone.
M=$(manual_mutant m4 '<!-- NDT-RC-TABLE:END -->'$'\x1f''<!-- NDT-RC-TABLE:END -->

<!-- NDT-RC-TABLE:BEGIN 第二份 -->

| rc | 意思 | `ndt help` 的原句 |
|---|---|---|
| 0 | 乾淨 | `the teardown finished and the machine verified clean` |

<!-- NDT-RC-TABLE:END -->')
report "M4: a second rc table is added" "$TEST" "$M" "case 5  the manual carries exactly one rc table (BEGIN/END)"

# --- M5: the table quotes a sentence `ndt help` does not print -------------------------------
M=$(manual_mutant m5 '`THERE WAS NOTHING TO JUDGE`'$'\x1f''`NOTHING TO JUDGE, SO IT IS CLEAN`')
report "M5: the table attributes an invented sentence to ndt help" "$TEST" "$M" "case 7a every quote in the rc table is verbatim from 'ndt help'"

# --- M6: the criterion reads the orphans rc instead of the verdict ---------------------------
# `ndt apps orphans` answers 5 for "processes clean, residue could not be checked" -- a different
# 5 from this table's. Reading its rc is exactly the confusion the criterion has to avoid.
M=$(manual_mutant m6 '**`orphans_verdict.sh` 印 `VERDICT: CLEAN`**'$'\x1f''**`ndt apps orphans` 回 rc 0**')
report "M6: the criterion reads the orphans rc, not its VERDICT" "$TEST" "$M" "case 13 the restore criterion reads orphans_verdict.sh's VERDICT, not a rc"

# --- M7: the TEST loses its authority --------------------------------------------------------
# 🔴 The direction that matters. With no help text every "the manual agrees with help" case is
# vacuously green; case 1 is the only thing standing between this file and a certificate that
# means nothing.
T=$(test_mutant m7 'HELP="$(bash "$NDT" help 2>&1)"'$'\x1f''HELP=""')
report "M7: the test stops reading 'ndt help'" "$T" "$MANUAL" "case 1  'ndt help' still prints a block for 'up' (>= 5 lines)"

# --- M8: a command comment gets its own rc gloss back ----------------------------------------
M=$(manual_mutant m8 'ndt clean           # 驗收；怎麼讀它的 exit code 見 §2.1 那張表'$'\x1f''ndt clean           # 證明真的乾淨了；exit 1 = 沒有')
report "M8: a code-block comment glosses an rc on its own again" "$TEST" "$M" "case 10 no 'ndt up/down/clean' command comment carries its own rc gloss"

# --- M9: the sentence the CONTROL reads is taken away -----------------------------------------
# Without this, case 14 could be green because it asks nothing. It has to be able to go red.
M=$(manual_mutant m9 'fabric 活著時 `ndt clean` 回 rc 1 是正常的'$'\x1f''fabric 活著時 `ndt clean` 會抱怨')
report "M9: the control's sentence is removed" "$TEST" "$M" "case 14 CONTROL"

# --- C1 (control): a comment is reworded; nothing about the contract changes -------------------
echo
M=$(manual_mutant c1 '這是整份手冊唯一一段教人怎麼判「還原了沒」的文字。'$'\x1f''這一段是唯一講「還原了沒」怎麼判的文字。')
if [[ -z "$M" ]]; then
    echo "  DID-NOT-APPLY C1 (control): the comment it rewords is not there" >&2
    UNAPPLIED=$((UNAPPLIED + 1))
else
    control "C1 (control): an HTML comment is reworded" "$TEST" "$M"
fi

echo
ok=0
if [[ "$(sha256sum "$MANUAL" | cut -d' ' -f1)" == "$MANUAL_SHA" ]]; then
    echo "baseline byte-identical: yes  doc/2026-08-17_testing-manual.md"
else
    echo "🔴 THE MANUAL CHANGED WHILE THIS GATE RAN -- a mutant may be on disk"; ok=1
fi
if [[ "$(sha256sum "$TEST" | cut -d' ' -f1)" == "$TEST_SHA" ]]; then
    echo "baseline byte-identical: yes  tests/shell/test_manual_rc_table.sh"
else
    echo "🔴 THE TEST CHANGED WHILE THIS GATE RAN -- a mutant may be on disk"; ok=1
fi
echo "GATE-SUMMARY mutations=$MUTATIONS survived=$SURVIVORS unapplied=$UNAPPLIED controls=$CONTROLS red=$CONTROLS_RED"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived; $CONTROLS control(s), $CONTROLS_RED went red"
[[ "$SURVIVORS" -eq 0 && "$UNAPPLIED" -eq 0 && "$CONTROLS_RED" -eq 0 && "$ok" -eq 0 ]]
