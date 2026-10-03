#!/usr/bin/env bash
# gates_aeg6.sh -- aeg5's gates after its red-first (redfirst_aeg5.aeg5-f7e2a128, rc 0), rerun under a
# new tag once the disk floor was set to 1.5 GB for gates that build no C++ (aeg5 stopped at 2.4 GB
# free, before its second gate got the lock). On the fixes of the AEG judge's round on ebe17f7c (F1 08's early exits, F2 the proxy's
# startup log, N1 02's heartbeat assertion, N2 docs, N4 E1b and the proxy_unit runner): red first
# against ebe17f7c, 08's self-test, the proxy suite file by file (skips apart, all-skipped = not OK),
# the HB W and roles gates, the live-p1 common suite and its gate, the anchors, the tripwire.
# One guard per gate (per cell), never one around the batch. [Co-developed with claude code -- Adam]
# RUN ONLY FROM A FROZEN, READ-ONLY COPY. Each gate through guarded_build (JOBS=1 LOCK_WAIT=10800)
# into logs/gates-0910/<gate>.aeg5-<sha8>.log (first line the full sha, last `# rc=<n>`); the
# scripts that run are the copies in scripts-aeg5-<sha8>/; kept outputs in <gate>.aeg5-<sha8>.kept/.
# PATH starts with the nolab shims; their log is the last gate.
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-rulings-aeg-0927
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
GUARD=$WT/tools/build_guard/guarded_build.sh
TAG=aeg6
sha=$(git -C "$WT" rev-parse --short=8 HEAD); full=$(git -C "$WT" rev-parse HEAD)
tree_state() { git -C "$WT" status --porcelain -- p4_proxy tools tests doc | /usr/bin/grep -v '^??' | head -1; }
[[ -z "$(tree_state)" ]] || { echo "REFUSE: tracked changes in the worktree"; exit 2; }
S="$L/scripts-$TAG-$sha"; [[ -e "$S" ]] && { echo "REFUSE: $S exists"; exit 2; }
mkdir -p "$S"
cp "${BASH_SOURCE[0]}" "$S/gates_aeg6.sh"
cp "$SP/aeg/"{redfirst_aeg5,redfirst_lib,proxy_unit}.sh "$SP/nolab2/make_shims.sh" "$SP/hbsnap.sha256" "$S/"
bash "$S/make_shims.sh" "$S/shims" > /dev/null
( cd "$S" && sha256sum *.sh hbsnap.sha256 shims/* > SHA256SUMS )
export PATH="$S/shims:$PATH" NOLAB_LOG="$S/tripwire.log" NOLAB_SUITE=gates NOLAB_PASS=aeg6 NOLAB_FAKE_FABRIC=0
unset SELFTEST_PROBE_SUDO NDT_MEASURING L1_POLL_S SELFTEST_L1_POLL_S
: > "$NOLAB_LOG"
SNAP="$SP/tmp/hbsnap"
( cd "$SNAP" && sha256sum -c --quiet "$S/hbsnap.sha256" ) || { echo "REFUSE: the snapshot changed"; exit 2; }
TMP_LONG="$SP/tmp"; mkdir -p "$TMP_LONG"
fail=0
#: [Co-developed with claude code -- Adam] The disk floor (orchestrator, 09-28): these gates build no
#: C++, so 1.5 GB free on / is enough -- checked before each gate is queued AND again inside the
#: guard, once the lock is held, right before the gate runs (the wait can be long). Under it: rc 97,
#: the gate does not run, and the driver stops.
FLOOR_MB=1536
free_mb() { df --output=avail -BM / | tail -1 | tr -dc 0-9; }
run() {   # run <gate> <expected rc> <why, or -> <cmd...>
    local name="$1" want="$2" why="$3" log="$L/$1.$TAG-$sha.log" rc
    shift 3
    if [[ -e "$log" ]]; then echo "REFUSE: $log exists"; fail=1; return; fi
    if [[ "$(git -C "$WT" rev-parse HEAD)" != "$full" || -n "$(tree_state)" ]]; then echo "REFUSE: HEAD moved or tracked files changed"; exit 3; fi
    if (( $(free_mb) < FLOOR_MB )); then echo "DISK-FLOOR: $(free_mb) MB free on / before $name (floor $FLOOR_MB MB) -- stopping"; exit 97; fi
    { echo "$full"; echo "# worktree $WT  $(date -u +%FT%TZ)"; echo "# cwd $WT  TMPDIR $TMP_LONG"; echo "# cmd $*"
      echo "# via JOBS=1 LOCK_WAIT=10800 $GUARD"; echo "# PATH starts $S/shims (nolab)"
      echo "# disk: $(free_mb) MB free on / when queued; floor $FLOOR_MB MB, checked again under the lock"
      [[ "$want" != 0 ]] && echo "# EXPECTED rc=$want: $why"; } > "$log"
    ( cd "$WT" && TMPDIR="$TMP_LONG" JOBS=1 LOCK_WAIT=10800 "$GUARD" bash -c \
        'a=$(df --output=avail -BM / | tail -1 | tr -dc 0-9); echo "# disk under the lock: $a MB free"; (( a >= $0 )) || { echo "DISK-FLOOR: $a MB < $0 MB -- not run"; exit 97; }; exec "$@"' \
        "$FLOOR_MB" "$@" ) >> "$log" 2>&1; rc=$?
    echo "# rc=$rc" >> "$log"
    printf '%-30s rc=%s%s  %s\n' "$name" "$rc" "$([[ $want != 0 ]] && echo " (expected $want)")" \
        "$(/usr/bin/grep -v -E '^# rc=|^guarded_build: ' "$log" | tail -1 | cut -c1-150)"
    (( rc == 97 )) && { echo "DISK-FLOOR hit under the lock at $name -- stopping"; exit 97; }
    [[ "$rc" == "$want" ]] || fail=1
}
k() { printf '%s' "$L/$1.$TAG-$sha.kept"; }
LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
run selftest_08 0 - bash $LIVE/08_heartbeat.sh --self-test
run proxy_unit 0 - bash "$S/proxy_unit.sh" "$WT"
run mutate_p4_heartbeat_w 0 - bash tests/shell/mutate_p4_heartbeat_w.sh
run mutate_roles_binding 0 - bash tests/shell/mutate_roles_binding.sh
run test_live_p1_common 0 - bash tests/shell/test_live_p1_common.sh
run mutate_live_p1_common 0 - bash tests/shell/mutate_live_p1_common.sh
run check_gate_anchors 0 - python3 tests/shell/check_gate_anchors.py "$sha"
run nolab_tripwire 0 - bash -c '
echo "lab commands the gates above made past their own stubs:"
/usr/bin/grep -E " (sudo|mnexec|iperf|iperf3|ping|cmake|ninja|make|gcc|g\+\+|c\+\+|cc|clang|clang\+\+) |localhost:80[08][01]|127\.0\.0\.1:80[08][01]" "$1" | sed "s/^/  /"
n=$(/usr/bin/grep -cE " (sudo|mnexec|iperf|iperf3|ping|cmake|ninja|make|gcc|g\+\+|c\+\+|cc|clang|clang\+\+) |localhost:80[08][01]|127\.0\.0\.1:80[08][01]" "$1")
echo "  ($(/usr/bin/grep -c "" "$1") line(s) in the shims log in all)"
echo "NOLAB-TRIPWIRE: $n lab call(s) (all refused)"; (( n == 0 ))' _ "$NOLAB_LOG"
echo "GATES-AEG6 $sha: $([ $fail = 0 ] && echo ALL-AS-EXPECTED || echo RED)"
exit $fail
