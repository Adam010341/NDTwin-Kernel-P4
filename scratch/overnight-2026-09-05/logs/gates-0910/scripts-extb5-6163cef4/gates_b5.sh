#!/usr/bin/env bash
# gates_b5.sh -- feat/external-detect-only-0927 round 5 (the round-4 review on faf6eb41: M-1..M-5, S-1..S-9; trunk
# d452d111 merged): every gate of round 4 (gates_b4.sh + gates_b4r.sh: 27) again on the merged head, plus
# redfirst_b5 (round 5's cells red first against faf6eb41), test_l1_shell_scoring and mutate_l1_shell_scoring
# (B now changes the L1 lane), and trunk's eight suites the merge brought in over the merged ndt (the merge
# check). [Co-developed with claude code -- Adam]
# 🔴 THE THROWAWAY SWITCH'S CONDITIONS ARE ENFORCED (round-5 ruling on M-4), twice: the drop check's two binaries
# run through make_hbwrap.sh's wrappers, which REFUSE a launch that breaks a condition and log every call; the
# tripwire gate (tripwire_b5.sh) re-checks every logged launch, fails on any refusal, and checks liveness by pid
# and start time -- over this driver's shim log and every earlier extb5 driver's.
# One guard per gate, never one around the batch. RUN ONLY FROM A FROZEN, READ-ONLY COPY. Each gate through
# guarded_build (JOBS=1 LOCK_WAIT=10800) into logs/gates-0910/<gate>.<tag>-<sha8>.log (first line the full sha,
# last `# rc=<n>`); the scripts that run are the copies in scripts-<tag>-<sha8>/; kept outputs in
# <gate>.<tag>-<sha8>.kept/. PATH starts with the nolab shims; their log is read by the last gate.
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927
SP=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/extb5
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
GUARD=$WT/tools/build_guard/guarded_build.sh
TAG=${TAG:-extb5}
ONLY_GATES="${ONLY_GATES:-}"     # a space-separated subset, for a re-run under another TAG
sha=$(git -C "$WT" rev-parse --short=8 HEAD); full=$(git -C "$WT" rev-parse HEAD)
tree_state() { git -C "$WT" status --porcelain -- p4_proxy tools tests doc | /usr/bin/grep -v '^??' | head -1; }
[[ -z "$(tree_state)" ]] || { echo "REFUSE: tracked changes in the worktree"; exit 2; }
S="$L/scripts-$TAG-$sha"; [[ -e "$S" ]] && { echo "REFUSE: $S exists"; exit 2; }
mkdir -p "$S"
cp "${BASH_SOURCE[0]}" "$S/gates_b5.sh"
cp "$SP/aeg/"{redfirst_b,redfirst_b2,redfirst_b3,redfirst_b4,redfirst_b5,redfirst_lib,proxy_unit,tripwire_b5}.sh \
   "$SP/nolab2/make_shims.sh" "$SP/make_hbwrap.sh" "$SP/hbsnap.sha256" "$S/"
bash "$S/make_shims.sh" "$S/shims" > /dev/null
bash "$S/make_hbwrap.sh" "$S/hbwrap" > /dev/null
( cd "$S" && sha256sum *.sh hbsnap.sha256 shims/* hbwrap/* > SHA256SUMS )
export PATH="$S/shims:$PATH" NOLAB_LOG="$S/tripwire.log" NOLAB_SUITE=gates NOLAB_PASS=$TAG NOLAB_FAKE_FABRIC=0
export NDT_HB_CHECK_BMV2="$S/hbwrap/simple_switch" NDT_HB_CHECK_FABRIC_BMV2="$S/hbwrap/simple_switch_grpc"
unset SELFTEST_PROBE_SUDO NDT_MEASURING L1_POLL_S SELFTEST_L1_POLL_S
: > "$NOLAB_LOG"
SNAP="$SP/tmp/hbsnap"
( cd "$SNAP" && sha256sum -c --quiet "$S/hbsnap.sha256" ) || { echo "REFUSE: the snapshot changed"; exit 2; }
TMP_LONG="$SP/tmp"; mkdir -p "$TMP_LONG"
fail=0
#: The disk floor (orchestrator, 09-28): no C++ here, so 1.5 GB free on / -- checked before each gate is queued AND
#: again inside the guard once the lock is held. Under it: rc 97, the gate does not run, and the driver stops.
FLOOR_MB=1536
free_mb() { df --output=avail -BM / | tail -1 | tr -dc 0-9; }
run() {   # run <gate> <expected rc> <why, or -> <cmd...>
    local name="$1" want="$2" why="$3" log="$L/$1.$TAG-$sha.log" rc
    shift 3
    if [[ -n "$ONLY_GATES" && " $ONLY_GATES " != *" $name "* ]]; then return; fi
    if [[ -e "$log" ]]; then echo "REFUSE: $log exists"; fail=1; return; fi
    if [[ "$(git -C "$WT" rev-parse HEAD)" != "$full" || -n "$(tree_state)" ]]; then echo "REFUSE: HEAD moved or tracked files changed"; exit 3; fi
    if (( $(free_mb) < FLOOR_MB )); then echo "DISK-FLOOR: $(free_mb) MB free on / before $name (floor $FLOOR_MB MB) -- stopping"; exit 97; fi
    { echo "$full"; echo "# worktree $WT  $(date -u +%FT%TZ)"; echo "# cwd $WT  TMPDIR $TMP_LONG"; echo "# cmd $*"
      echo "# via JOBS=1 LOCK_WAIT=10800 $GUARD"; echo "# PATH starts $S/shims (nolab); drop check through $S/hbwrap"
      echo "# disk: $(free_mb) MB free on / when queued; floor $FLOOR_MB MB, checked again under the lock"
      [[ "$want" != 0 ]] && echo "# EXPECTED rc=$want: $why"; } > "$log"
    ( cd "$WT" && TMPDIR="$TMP_LONG" HBDROP_KEEP="$L/$name.$TAG-$sha.kept" JOBS=1 LOCK_WAIT=10800 "$GUARD" bash -c \
        'a=$(df --output=avail -BM / | tail -1 | tr -dc 0-9); echo "# disk under the lock: $a MB free"; (( a >= $0 )) || { echo "DISK-FLOOR: $a MB < $0 MB -- not run"; exit 97; }; exec "$@"' \
        "$FLOOR_MB" "$@" ) >> "$log" 2>&1; rc=$?
    echo "# rc=$rc" >> "$log"
    printf '%-34s rc=%s%s  %s\n' "$name" "$rc" "$([[ $want != 0 ]] && echo " (expected $want)")" \
        "$(/usr/bin/grep -v -E '^# rc=|^guarded_build: ' "$log" | tail -1 | cut -c1-150)"
    (( rc == 97 )) && { echo "DISK-FLOOR hit under the lock at $name -- stopping"; exit 97; }
    [[ "$rc" == "$want" ]] || fail=1
}
k() { printf '%s' "$L/$1.$TAG-$sha.kept"; }
LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
run redfirst_b 0 - bash "$S/redfirst_b.sh" "$WT" "$(k redfirst_b)"
run redfirst_b2 0 - bash "$S/redfirst_b2.sh" "$WT" "$(k redfirst_b2)"
run redfirst_b3 0 - bash "$S/redfirst_b3.sh" "$WT" "$(k redfirst_b3)"
run redfirst_b4 0 - bash "$S/redfirst_b4.sh" "$WT" "$(k redfirst_b4)"
run redfirst_b5 0 - bash "$S/redfirst_b5.sh" "$WT" "$(k redfirst_b5)"
run proxy_unit 0 - bash "$S/proxy_unit.sh" "$WT"
run test_ndt_heartbeat 0 - bash tests/shell/test_ndt_heartbeat.sh
run test_ndt_app_package 0 - bash tests/shell/test_ndt_app_package.sh
run test_ndt_up_down_robust 0 - bash tests/shell/test_ndt_up_down_robust.sh
run test_ndt_sudo_surface 0 - bash tests/shell/test_ndt_sudo_surface.sh
run test_ndt_status_check_baseline 0 - bash tests/shell/test_ndt_status_check_baseline.sh
for t in test_apps_residue test_ndt_app_orphans test_ndt_apps_liveness test_ndt_down_stops_only_ours \
         test_ndt_helper_apps_window test_ndt_ovs_claim test_ndtwin_lab_sweep test_faults_topo_pid; do
    run "$t" 0 - bash "tests/shell/$t.sh"
done
run selftest_08 0 - bash $LIVE/08_heartbeat.sh --self-test
run selftest_07 0 - bash $LIVE/07_roles_basic.sh --self-test
run test_live_p1_common 0 - bash tests/shell/test_live_p1_common.sh
run test_live_p1_thirteen 0 - bash tests/shell/test_live_p1_thirteen.sh
run test_live_p1_external_evidence 0 - bash tests/shell/test_live_p1_external_evidence.sh
run test_heartbeat_drop_check 0 - python3 tests/shell/test_heartbeat_drop_check.py
run test_l1_shell_scoring 0 - bash tests/shell/test_l1_shell_scoring.sh
run test_drive_exercise 0 - p4_proxy/venv/bin/python -m unittest discover -s doc/audit/2026-09-04_p4-tutorial-exercise-prep/tests -t doc/audit/2026-09-04_p4-tutorial-exercise-prep/tests
run mutate_p4_heartbeat_w 0 - bash tests/shell/mutate_p4_heartbeat_w.sh
run mutate_live_p1_common 0 - bash tests/shell/mutate_live_p1_common.sh
run mutate_live_p1_thirteen 0 - bash tests/shell/mutate_live_p1_thirteen.sh
run mutate_live_p1_external_evidence 0 - bash tests/shell/mutate_live_p1_external_evidence.sh
run mutate_roles_binding 0 - bash tests/shell/mutate_roles_binding.sh
run mutate_app_package 0 - bash tests/shell/mutate_app_package.sh
run mutate_ndt_app_package 0 - bash tests/shell/mutate_ndt_app_package.sh
run mutate_heartbeat_drop_check 0 - bash tests/shell/mutate_heartbeat_drop_check.sh
run mutate_l1_shell_scoring 0 - bash tests/shell/mutate_l1_shell_scoring.sh
run check_gate_anchors 0 - python3 tests/shell/check_gate_anchors.py "$sha"
# every extb5 driver's shim log so far, this one's included (an earlier driver's switches are checked too)
run nolab_tripwire 0 - bash "$S/tripwire_b5.sh" $(ls "$L"/scripts-extb5*-*/tripwire.log 2>/dev/null)
echo "GATES-$TAG $sha: $([ $fail = 0 ] && echo ALL-AS-EXPECTED || echo RED)"
exit $fail
