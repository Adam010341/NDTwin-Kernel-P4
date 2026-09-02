#!/usr/bin/env bash
# Paired acceptance test for the cpu_gate.py lifetime fix.
#
# Both gate versions read THE SAME window on THE SAME machine while short-lived processes burn
# CPU.  Paired on purpose: the two versions disagree about the baseline too, so an unpaired
# comparison of one version's churn run against the other version's quiet run would confound the
# treatment with the version.
#
# 🔴 Written as a file rather than typed inline because the first two attempts at this were both
# wrong in the shell, not in the gate: `A; B &` backgrounds only B, so the two gates ran
# sequentially and the second one overlapped the churn for 4 of its 20 seconds; and
# `VAR=x && cmd &` backgrounds the assignment, so $VAR was empty in every later line.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
NEW="$HERE/cpu_gate.py"
# The pre-fix gate is taken from git, not from a copy beside this script: the first run used a
# scratch copy (cpu_gate_OLD.py) that never entered the repo, so the script as archived could
# not be re-run.  6a28e81d9759 is the last commit that touched cpu_gate.py before the lifetime
# change; the acceptance log records its sha256 as 897b8996d9da3b88.
OLD_REF="${OLD_REF:-6a28e81d9759ea8af5909923886427b96315ee84}"
SP="$(mktemp -d)"            # every output of this run lands here, not in the round directory
OLD="$SP/cpu_gate_OLD.py"
git -C "$REPO" show "$OLD_REF:doc/audit/2026-08-31_sampling-ceiling-after-merge/cpu_gate.py" >"$OLD"
grep -q "if pid not in a:" "$OLD" || { echo "REFUSE: $OLD_REF does not carry the pre-fix gate"; exit 2; }
echo "OLD = $OLD_REF (sha256 $(sha256sum "$OLD" | cut -c1-16)), NEW = working tree, outputs in $SP"
WINDOW="${1:-24}"
CHURN=$(( WINDOW + 10 ))

setsid bash "$SP/churn.sh" "$CHURN" > "$SP/acc_churn.txt" 2>&1 &
churn_pid=$!
sleep 3

( python3 "$OLD" --label acc_OLD --window "$WINDOW" --baseline-file "$SP/bl_old.json" \
    > "$SP/acc_old.txt" 2>&1; echo "rc=$?" >> "$SP/acc_old.txt" ) &
old_job=$!
( python3 "$NEW" --label acc_NEW --window "$WINDOW" --baseline-file "$SP/bl_new.json" \
    > "$SP/acc_new.txt" 2>&1; echo "rc=$?" >> "$SP/acc_new.txt" ) &
new_job=$!
wait "$old_job" "$new_job"
wait "$churn_pid" 2>/dev/null || true

echo "=== injection assertion (a null injection must not be read as a null effect) ==="
cat "$SP/acc_churn.txt"
echo
echo "=== OLD (pre-fix), window ${WINDOW}s ==="
cat "$SP/acc_old.txt"
echo
echo "=== NEW (post-fix), same window ==="
cat "$SP/acc_new.txt"
