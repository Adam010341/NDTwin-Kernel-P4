#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_cell_gate_suspect_wiring.sh.
#
# [Co-developed with claude code -- Adam]
#
# Each mutation removes one part of the wiring that lets cell_cpu_gate_finish see the whole gate
# record, and names the case that must go red. Mutation 2 is the one worth reading: it makes a
# record with no suspect field read as clean, which is the pre-wiring behaviour and the shape of
# the sentinel-equality trap. If case 3 stays green under it, the test is decorative.
#
# 🔴 A mutation that did not APPLY is reported as such and fails the run; it is not a survivor.
# 🔴 Guards its own baseline: snapshot, EXIT-trap restore, byte-identity assertion at the end.
#    Baseline is the WORKING TREE, not HEAD -- this runs against an uncommitted fix, in a worktree
#    other sessions write to.
#
# Usage:  bash tests/shell/mutate_cell_gate_suspect_wiring.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

LIB=doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh
TEST=tests/shell/test_cell_gate_suspect_wiring.sh
BK=$(mktemp -d)

cp "$LIB" "$BK/lib"
restore() { cp "$BK/lib" "$LIB"; }
trap 'restore; rm -rf "$BK"' EXIT

run() { bash "$TEST" 2>&1; }

SURVIVORS=0
NOT_APPLIED=0
report() {   # $1 = mutation name, $2 = case that must fail
    local out rc
    if cmp -s "$BK/lib" "$LIB"; then
        printf '  DID-NOT-APPLY %-52s (pattern missed; nothing was tested)\n' "$1"
        NOT_APPLIED=$((NOT_APPLIED + 1))
        return
    fi
    out=$(run); rc=$?
    # 🔴 A third outcome, found on this harness's first run: the mutant broke the file (a perl
    # replacement that leaked a capture group into the inserted bash), lib_e.sh failed to source,
    # the test died before its first case, and "no case went red" was reported as SURVIVED. A
    # test that never ran has not been beaten. Detected by the absence of ANY case line.
    if ! grep -qE '^  (ok|FAILED)' <<<"$out"; then
        printf '  TEST-DID-NOT-RUN %-49s (mutant broke the file; harness error, not a survivor)\n' "$1"
        sed -n '1,4p' <<<"$out" | sed 's/^/                /'
        NOT_APPLIED=$((NOT_APPLIED + 1))
        restore
        return
    fi
    if [[ "$rc" -ne 0 ]] && grep -q "FAILED   $2" <<<"$out"; then
        printf '  caught        %-52s (%s went red)\n' "$1" "$2"
    else
        printf '  SURVIVED      %-52s (%s stayed green -- that case proves nothing)\n' "$1" "$2"
        grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/                /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

echo "baseline (unmutated) must be green:"
if run | tail -1 | grep -q ' 0 failed'; then
    echo "  ok       baseline green"
else
    echo "  REFUSE: baseline is not green; mutation results would be meaningless"
    run | sed 's/^/    /'
    exit 2
fi
echo
echo "mutations:"

# 1. The listing is dropped: the cell is said to be suspect but nothing durable records it.
perl -0pi -e 's/\n\s+printf .%s %s\\n. "\$1" "\$sus" >>"\$OUT\/cell_cpu\/SUSPECT_CELLS"//' "$LIB"
report "SUSPECT_CELLS never written" "case 1c"

# 2. A record with no suspect field reads as clean -- the pre-wiring behaviour.
perl -0pi -e 's/true\*\|UNKNOWN\*\)/true*)/' "$LIB"
report "missing suspect field treated as not-suspect" "case 3c"

# 3. suspect becomes an abort.  The flag is deliberately not a fourth exit code.
perl -0pi -e 's/(say "       This cell is listed in cell_cpu\/SUSPECT_CELLS and must not be cited as quiet\."\n)/${1}            abort "suspect" "mutated: suspect became an abort"\n/' "$LIB"
report "suspect turned into an abort" "case 1a"

# 4. The SUSPECT line is no longer said, so the transcript reads like a quiet cell.
perl -0pi -e 's/\n\s+say "    🔴 SUSPECT: the verdict above names only the CPU the gate could attribute\."//' "$LIB"
report "SUSPECT line dropped from the transcript" "case 1b"

# 5. The suspect readout line goes, taking unattributed_cores with it.
perl -0pi -e 's/\n\s+say "    suspect:       \$\{sus:-UNREADABLE\}"//' "$LIB"
report "suspect readout line dropped" "case 6"

# 6. UNKNOWN is printed for a missing field but the reader then reads it as false.
perl -0pi -e 's/if .suspect. not in r: print\(.UNKNOWN unattributed=n\/a \(no lifetime accounting in this record\).\)/if "suspect" not in r: print("false unattributed=n\/a")/' "$LIB"
report "missing field printed as false" "case 3b"

restore
echo
if cmp -s "$BK/lib" "$LIB"; then
    echo "baseline restored: lib_e.sh byte-identical to the pre-run snapshot"
else
    echo "🔴 BASELINE NOT RESTORED -- a mutant is still on disk:"
    diff -u "$BK/lib" "$LIB" | head -20
    exit 1
fi
echo "survivors=$SURVIVORS  harness-errors(did-not-apply / test-did-not-run)=$NOT_APPLIED"
[[ "$SURVIVORS" -eq 0 && "$NOT_APPLIED" -eq 0 ]]
