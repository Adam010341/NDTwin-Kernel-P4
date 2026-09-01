#!/usr/bin/env bash
#
# Mutation gate for tests/shell/test_ep4_gate_and_abort_evidence.sh.
#
# [Co-developed with claude code -- Adam]
#
# Mutation 1 is the one that matters: it restores the ORIGINAL fail-open, so case 1 has to go red
# for the MISSING-PARTNER case specifically. 8/31 mainDev's warning to whoever took this ticket was
# that the easy mistake is a fix whose force-red fires on some other case -- that would be a second
# hollow guard, indistinguishable from the first until the next round loses a comparison silently.
#
# 🔴 Guards its own baseline: files are snapshotted before the first mutation, an EXIT trap restores
# them on any exit including interrupt, and the run ends by asserting they are byte-identical to the
# snapshot. Baseline is the WORKING TREE, not HEAD, so this runs against an uncommitted fix. These
# files are in a worktree other sessions write to.
#
# Usage:  bash tests/shell/mutate_ep4_gate_and_abort_evidence.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

LIB=doc/audit/2026-08-31_sampling-ceiling-after-merge/lib_e.sh
RUN=doc/audit/2026-08-31_sampling-ceiling-after-merge/run_e.sh
TEST=tests/shell/test_ep4_gate_and_abort_evidence.sh
BK=$(mktemp -d)

cp "$LIB" "$BK/lib" && cp "$RUN" "$BK/run"
restore() { cp "$BK/lib" "$LIB"; cp "$BK/run" "$RUN"; }
trap 'restore; rm -rf "$BK"' EXIT

SURVIVORS=0
run() { bash "$TEST" 2>&1; }
report() {   # $1 = mutation name, $2 = case that must fail
    local out rc
    out=$(run); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -q "FAILED   $2" <<<"$out"; then
        printf '  caught   %-52s (%s went red)\n' "$1" "$2"
    else
        printf '  SURVIVED %-52s (%s stayed green -- that case proves nothing)\n' "$1" "$2"
        grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/             /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

echo "baseline (unmutated) must be green:"
if run | tail -2 | grep -q '0 failed'; then
    echo "  ok       baseline green"
else
    echo "  REFUSE: baseline is not green; mutation results would be meaningless"
    run | sed 's/^/    /'; exit 2
fi
echo
echo "mutations:"

# 1. THE ORIGINAL DEFECT: a missing partner falls through as if nothing were wrong.
perl -0pi -e "s/    if \[\[ -z \"\\\$1\" \]\]; then\n        printf 'MISSING-PARTNER/    if [[ -z \"\\\$1\" ]]; then\n        printf 'OK/" "$LIB"
report "ep4_verdict treats a missing partner as OK (the fail-open)" "case 1"

# 2. The RATIO-MOVED arm stops firing -- the behaviour that already worked must stay tested.
perl -0pi -e "s/    elif \[\[ \"\\\$1\" != \\*SATURATED\\* && \"\\\$2\" == \\*SATURATED\\* \]\]; then/    elif false; then/" "$LIB"
report "ep4_verdict never reports RATIO-MOVED" "case 2"

# 3. ORDER: evidence captured after the restore that destroys it. This is F-24 itself.
perl -0pi -e 's/    say "🔴 ABORT\(\$1\): \$\{\*:2\}"\n    preserve_abort_evidence "\$1"\n/    say "🔴 ABORT(\$1): \$\{*:2\}"\n/' "$LIB"
perl -0pi -e 's/\n    exit 9\n\}/\n    preserve_abort_evidence "\$1"\n    exit 9\n}/' "$LIB"
report "abort captures evidence AFTER restore_production" "case 5"

# 4. The forced branch stops capturing -- back to "the preserving branch is wired to the case
#    that does not need it", which is F-24's actual headline.
perl -0pi -e 's/    preserve_abort_evidence "\$1"\n/    [[ -z "\$\{FORCED_ABORT:-\}" \]\] \&\& preserve_abort_evidence "\$1"\n/' "$LIB"
report "a FORCED abort skips the capture" "case 6"

# 5. The size report describes the wrong capture, so an empty pane reads as captured.
perl -0pi -e 's/    n="\$\{#pane\}"/    n="\$\{#status_out\}"/' "$LIB"
report "the size report measures status, not the pane" "case 7"

# 6. run_e.sh stops asking. A fixed function with no caller is not a fix.
perl -0pi -e 's/    case "\$\(ep4_verdict "\$pv" "\$v"\)" in/    case "OK" in/' "$RUN"
report "run_e.sh no longer calls ep4_verdict" "case 4b"

restore
echo
if cmp -s "$BK/lib" "$LIB" && cmp -s "$BK/run" "$RUN"; then
    echo "baseline restored: both files byte-identical to the pre-run snapshot"
else
    echo "🔴 BASELINE NOT RESTORED -- a mutant is still on disk:"
    diff -u "$BK/lib" "$LIB" | head -20; diff -u "$BK/run" "$RUN" | head -20
    exit 1
fi
[[ "$SURVIVORS" -eq 0 ]]
