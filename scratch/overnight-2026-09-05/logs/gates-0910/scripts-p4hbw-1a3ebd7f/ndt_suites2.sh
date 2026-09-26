#!/usr/bin/env bash
# Every shell suite that sources or drives ndt, one line per suite; a red one prints its FAILED checks. [Co-developed with claude code -- Adam]
set -u
cd "$1"
red=0
for t in tests/shell/test_ndt_*.sh tests/shell/test_apps_residue.sh tests/shell/test_apps_stop_kills_the_group.sh tests/shell/test_stop_one_targets_its_argument.sh tests/shell/test_supervise_exit_status.sh tests/shell/test_mutate_gate_dead_mutant.sh tests/shell/test_lab_handoff.sh; do
    [[ -f "$t" ]] || continue
    out="$(timeout 900 bash "$t" 2>&1)"; rc=$?
    last="$(printf '%s\n' "$out" | grep -E '^Ran |checks|passed|failed|PASS|FAIL' | tail -1)"
    printf '%-58s rc=%s  %s\n' "$t" "$rc" "$last"
    (( rc == 0 )) || { red=$((red+1)); printf '%s\n' "$out" | grep -E -A1 '^  FAILED|^FAIL|^ERROR|SURVIVED' | head -12 | sed 's/^/      /'; }
done
echo "suites red: $red"
exit $red
