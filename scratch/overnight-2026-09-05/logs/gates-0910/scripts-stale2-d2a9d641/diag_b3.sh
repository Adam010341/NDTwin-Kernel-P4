#!/usr/bin/env bash
# diag_b3.sh <worktree> <out dir> -- round (b3), 09-27: which side of test_l1_shell_scoring's group C
# is wrong? Each of the 12 suites group C flags is RUN (inside the guard, nolab shims first), its
# whole log KEPT, and scored exactly as the L1 lane scores a shell log: l1_unit_tests.sh's own
# shell_summary + the lane's SKIP count + l1_lane_verdict (sourced with NDTWIN_L1_LIB_ONLY=1). The
# scorer's `ran` / `failed` are set beside an independent count of the log's ok / FAILED lines, and
# beside the static heuristic's reading of the suite's source (its last `echo "..."`).
# A scorer MISREAD is: its ran differs from the checks the log shows, or its verdict is not what the
# run was (PASS for a green run, a failure for a red one). [Co-developed with claude code -- Adam]
set -u
WT="$1"; OUT="$2"; cd "$WT" || exit 2
rm -rf "$OUT"; mkdir -p "$OUT"
# its OWN refusing shims first on PATH (09-27: this branch's suites have no probe stubs -- those are
# on fix/probe-suites-stub-0927 -- and test_ndt_honesty's two `sudo ovs-vsctl list-br` landed in the
# driver's tripwire). What they record stays here, in <out>/calls.
bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/make_shims.sh" "$OUT/shims" >/dev/null
export PATH="$OUT/shims:$PATH" NOLAB_LOG="$OUT/calls" NOLAB_SUITE=diag_b3 NOLAB_PASS=R NOLAB_FAKE_FABRIC=0
: > "$NOLAB_LOG"
SUITES=(test_apps_residue test_build_guard test_check_logs_crash_patterns test_guarded_build_reentrant
        test_ndt_honesty test_ndt_ovs_topo_script test_ndt_status_check_baseline test_ndt_up_down_robust
        test_ndt_up_target test_orphans_verdict test_stack_log_rotation test_stop_one_targets_its_argument)
NDTWIN_L1_LIB_ONLY=1 source tools/test_workflow/l1_unit_tests.sh >/dev/null 2>&1
declare -F shell_summary >/dev/null && declare -F l1_lane_verdict >/dev/null \
    || { echo "REFUSE: the lane's scorer did not load"; exit 2; }
cd "$WT"
echo "HEAD $(git rev-parse HEAD)"
printf '%-38s %-3s %-16s %-14s %-12s %s\n' suite rc "scorer ran/fail" "log ok/FAILED" verdict "last output line | static heuristic's last echo"
bad=0
for s in "${SUITES[@]}"; do
    timeout 900 bash "tests/shell/$s.sh" < /dev/null > "$OUT/$s.log" 2>&1; rc=$?
    read -r ran failed <<<"$(shell_summary "$OUT/$s.log")"
    skipped=$(grep -cE "^[[:space:]]*SKIP:" "$OUT/$s.log")
    v="$(l1_lane_verdict "$rc" "${ran:-0}" "${failed:-0}" "${skipped:-0}")"
    nok=$(grep -cE '^ *ok ' "$OUT/$s.log"); nfail=$(grep -cE '^ *FAILED ' "$OUT/$s.log")
    last="$(grep -v '^\s*$' "$OUT/$s.log" | tail -1 | cut -c1-60)"
    stat="$(grep -hoE '^ *echo "[^"]*"' "tests/shell/$s.sh" | tail -1 | sed -e 's/^ *echo "//' -e 's/"$//' | cut -c1-40)"
    misread=""
    (( ran != nok + nfail )) && misread="ran $ran != $((nok + nfail)) checks in the log"
    [[ $rc == 0 && $v != PASS ]] && misread="${misread:+$misread; }a green run scored $v"
    [[ $rc != 0 && $v == PASS ]] && misread="${misread:+$misread; }a red run scored PASS"
    printf '%-38s %-3s %-16s %-14s %-12s %s | %s\n' "$s" "$rc" "$ran/$failed" "$nok/$nfail" "$v" "$last" "$stat"
    [[ -n "$misread" ]] && { echo "      ^ MISREAD: $misread"; bad=1; }
done
echo "calls its own shims recorded (refused): $(cut -d' ' -f3- "$OUT/calls" | /usr/bin/grep -v '^curl .*file://' | sort | uniq -c | sed 's/^ *//' | paste -sd';' -)"
echo "DIAG-B3: $([[ $bad == 0 ]] && echo 'the runtime scorer read every one of the 12 correctly' || echo 'the runtime scorer MISREAD at least one (see ^ MISREAD)')"
exit 0
