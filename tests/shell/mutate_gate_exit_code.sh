#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_gate_exit_code_not_tee.sh.
#
# [Co-developed with claude code -- Adam]
#
# A test nobody has seen fail is not delivered. Each mutation below reintroduces one part of the
# defect and names the case that must go red. A mutation that SURVIVES means that case is
# decorative -- which is not hypothetical here: on the first run, mutation 2 survived, because
# case 5 grepped line by line while two of the three call sites that shipped the defect were
# written across a line continuation. The guard could not see the shape the defect actually took.
#
# 🔴 The harness guards its own baseline. Originals are snapshotted before the first mutation, an
# EXIT trap restores them on any exit including interrupt, and the run ends by asserting the files
# are byte-identical to the snapshot. An interrupted mutation run that leaves a mutant on disk is
# worse than no gate at all, and these files live in a worktree other sessions write to.
#
# The baseline is the WORKING TREE, not HEAD: this is meant to be runnable against an uncommitted
# fix, and "restore to HEAD" would silently discard it.
#
# Usage:  bash tests/shell/mutate_gate_exit_code.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

LIB=doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh
GATES=doc/audit/2026-08-31_sampling-ceiling-after-merge/gates_e.sh
TEST=tests/shell/test_gate_exit_code_not_tee.sh
BK=$(mktemp -d)

cp "$LIB" "$BK/lib" && cp "$GATES" "$BK/gates"
restore() { cp "$BK/lib" "$LIB"; cp "$BK/gates" "$GATES"; }
trap 'restore; rm -rf "$BK"' EXIT

run() { bash "$TEST" 2>&1; }

report() {   # $1 = mutation name, $2 = case that must fail
    local out rc
    out=$(run); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "FAILED   $2" <<<"$out"; then
        printf '  caught   %-46s (%s went red)\n' "$1" "$2"
    else
        printf '  SURVIVED %-46s (%s stayed green -- that case proves nothing)\n' "$1" "$2"
        grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}
SURVIVORS=0

echo "baseline (unmutated) must be green:"
if run | tail -2 | grep -q '0 failed'; then
    echo "  ok       baseline green"
else
    echo "  REFUSE: baseline is not green; mutation results would be meaningless"
    run | sed 's/^/    /'
    exit 2
fi
echo
echo "mutations:"

# 1. The fix itself: run_gate stops reporting the gate's code and always says success.
perl -0pi -e 's/(run_gate\(\) \{\n    "\$\@" 2>&1 \| tee -a "\$LOG"\n    return )"\$\{PIPESTATUS\[0\]\}"/${1}0/' "$LIB"
report "run_gate returns 0 instead of PIPESTATUS[0]" "case 2"

# 2. A call site reverts to piping the gate straight into the condition -- as a continuation,
#    which is how two of the three shipped sites were written.
perl -0pi -e 's/    elif run_gate env PYTHONDONTWRITEBYTECODE=1 "\$PY_PLOT" "\$HERE\/ratio_gate\.py" \\\n            --check e_gate_forcered_trunc20 --expect red; then/    elif PYTHONDONTWRITEBYTECODE=1 "\$PY_PLOT" "\$HERE\/ratio_gate.py" \\\n            --check e_gate_forcered_trunc20 --expect red 2>&1 | tee -a "\$LOG"; then/' "$GATES"
report "G6b call site piped back into the condition" "case 5"

# 3. The logging half is dropped: the exit code is right, the transcript is gone.
perl -0pi -e 's/    "\$\@" 2>&1 \| tee -a "\$LOG"\n    return "\$\{PIPESTATUS\[0\]\}"/    "\$\@" >\/dev\/null 2>&1\n    return "\$?"/' "$LIB"
report "run_gate stops writing the gate output to the log" "case 4"

# 4. gates_e.sh gains pipefail. That would make the old construct safe, so case 3's reasoning
#    would no longer hold -- the test must notice the ground moving under it, not just the code.
perl -0pi -e 's/^set -u$/set -uo pipefail/m' "$GATES"
report "gates_e.sh gains pipefail" "case 3b"

restore
echo
if cmp -s "$BK/lib" "$LIB" && cmp -s "$BK/gates" "$GATES"; then
    echo "baseline restored: both files byte-identical to the pre-run snapshot"
else
    echo "🔴 BASELINE NOT RESTORED -- a mutant is still on disk:"
    diff -u "$BK/lib" "$LIB" | head -20
    diff -u "$BK/gates" "$GATES" | head -20
    exit 1
fi
[[ "$SURVIVORS" -eq 0 ]]
