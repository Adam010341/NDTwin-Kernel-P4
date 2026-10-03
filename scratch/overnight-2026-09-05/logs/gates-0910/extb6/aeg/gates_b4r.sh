#!/usr/bin/env bash
# gates_b4r.sh -- the rest of round 4 after the scratchpad was lost to the reboot: gates_b4.sh was stopped (by the worker, Adam's
# quota ran out) while queued for mutate_app_package; the 21 gates before it are rc 0 in *.extb4-faf6eb41.log. This runs the 5 it did
# not run -- mutate_app_package, mutate_ndt_app_package, mutate_heartbeat_drop_check, check_gate_anchors -- and the tripwire, on the
# same head, one guard per gate. Only changes from gates_b4.sh: this header, SP (the old scratchpad -> logs/gates-0910/extb4r-1001),
# TAG default extb4r, the cp name, and the 22 run lines for the gates already done removed.
# gates_b4.sh -- feat/external-detect-only-0927 round 4 (Adam's 09-28 ruling: no guessed destination paths
# on an external control plane; its heartbeat only after the offline drop check; trunk 08f67b7a merged):
# redfirst_b4, test_heartbeat_drop_check and mutate_heartbeat_drop_check added; the drop check's throwaway
# simple_switch runs through a wrapper that records every launch in the tripwire log as ALLOWED-LAUNCH
# (the orchestrator's conditions, 09-28), and the tripwire gate checks each launched pid is gone.
# gates_b3.sh -- feat/external-detect-only-0927 round 3 (the external judge on 14921f98: M1-M3, S1-S4, m1-m3; trunk
# 85bec430 merged): redfirst_b3 added (round 3's cells red first against 14921f98), 07's self-test (_common.sh's traps
# changed under it), mutate_ndt_app_package (its M28 anchors changed), and trunk's two ndt suites over the merged ndt
# (test_ndt_sudo_surface, test_ndt_status_check_baseline: the merge check); otherwise gates_b2.sh's cells.
# gates_b2.sh -- after the 09-28 judges (external F1-F9, AEG N-1..N-11): redfirst_b2 added;
# otherwise gates_b.sh's cells. feat/external-detect-only-0927 (external control planes run the heartbeat, detect only;
# live-p1 venv fingerprints; external_evidence.py): red first against the AEG head it merged, the
# proxy suite file by file, the ndt, live-p1 and drive_exercise suites B's files feed, 08's self-test,
# the mutation gates of every source B changed, the anchors, the tripwire.
# One guard per gate (per cell), never one around the batch. [Co-developed with claude code -- Adam]
# RUN ONLY FROM A FROZEN, READ-ONLY COPY. Each gate through guarded_build (JOBS=1 LOCK_WAIT=10800)
# into logs/gates-0910/<gate>.<tag>-<sha8>.log (first line the full sha, last `# rc=<n>`); the
# scripts that run are the copies in scripts-<tag>-<sha8>/; kept outputs in <gate>.<tag>-<sha8>.kept/.
# PATH starts with the nolab shims; their log is the last gate.
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927
SP=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/extb4r-1001
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
GUARD=$WT/tools/build_guard/guarded_build.sh
TAG=${TAG:-extb4r}
sha=$(git -C "$WT" rev-parse --short=8 HEAD); full=$(git -C "$WT" rev-parse HEAD)
tree_state() { git -C "$WT" status --porcelain -- p4_proxy tools tests doc | /usr/bin/grep -v '^??' | head -1; }
[[ -z "$(tree_state)" ]] || { echo "REFUSE: tracked changes in the worktree"; exit 2; }
S="$L/scripts-$TAG-$sha"; [[ -e "$S" ]] && { echo "REFUSE: $S exists"; exit 2; }
mkdir -p "$S"
cp "${BASH_SOURCE[0]}" "$S/gates_b4r.sh"
cp "$SP/aeg/"{redfirst_b,redfirst_b2,redfirst_b3,redfirst_b4,redfirst_lib,proxy_unit}.sh "$SP/nolab2/make_shims.sh" "$SP/hbsnap.sha256" "$S/"
bash "$S/make_shims.sh" "$S/shims" > /dev/null
#: [Co-developed with claude code -- Adam] The drop check's throwaway switch: allowed (orchestrator, 09-28),
#: and recorded -- every launch is a line in the tripwire log, with the pid it runs as (exec keeps it).
mkdir -p "$S/hbcheck"
cat > "$S/hbcheck/simple_switch" <<'WRAP'
#!/usr/bin/env bash
printf '%s ALLOWED-LAUNCH simple_switch pid=%s argv0=%s args=%s\n' "$(date +%s.%N)" "$$" "${NDT_HB_CHECK_ARGV0:-?}" "$*" >> "$NOLAB_LOG"
exec -a "${NDT_HB_CHECK_ARGV0:-ndt-hbdrop-bmv2}" /usr/local/bin/simple_switch "$@"
WRAP
chmod +x "$S/hbcheck/simple_switch"
( cd "$S" && sha256sum *.sh hbsnap.sha256 shims/* hbcheck/* > SHA256SUMS )
export PATH="$S/shims:$PATH" NOLAB_LOG="$S/tripwire.log" NOLAB_SUITE=gates NOLAB_PASS=$TAG NOLAB_FAKE_FABRIC=0
export NDT_HB_CHECK_BMV2="$S/hbcheck/simple_switch"
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
run mutate_app_package 0 - bash tests/shell/mutate_app_package.sh
run mutate_ndt_app_package 0 - bash tests/shell/mutate_ndt_app_package.sh
run mutate_heartbeat_drop_check 0 - bash tests/shell/mutate_heartbeat_drop_check.sh
run check_gate_anchors 0 - python3 tests/shell/check_gate_anchors.py "$sha"
run nolab_tripwire 0 - bash -c '
echo "lab commands the gates above made past their own stubs:"
pat=" (sudo|mnexec|iperf|iperf3|ping|cmake|ninja|make|gcc|g\+\+|c\+\+|cc|clang|clang\+\+) |localhost:80[08][01]|127\.0\.0\.1:80[08][01]"
/usr/bin/grep -v " ALLOWED-LAUNCH " "$1" | /usr/bin/grep -E "$pat" | sed "s/^/  /"
n=$(/usr/bin/grep -v " ALLOWED-LAUNCH " "$1" | /usr/bin/grep -cE "$pat")
a=$(/usr/bin/grep -c " ALLOWED-LAUNCH " "$1")
echo "  ($(/usr/bin/grep -c "" "$1") line(s) in the shims log in all; $a of them the drop check'"'"'s allowed simple_switch launches)"
alive=0
for pid in $(sed -n "s/.* ALLOWED-LAUNCH simple_switch pid=\([0-9]*\) .*/\1/p" "$1" | sort -un); do
    if [[ -r /proc/$pid/cmdline ]] && [[ "$(tr "\0" " " < /proc/$pid/cmdline)" == ndt-hbdrop-bmv2* ]]; then
        echo "  🔴 allowed launch pid $pid is STILL running: $(tr "\0" " " < /proc/$pid/cmdline | cut -c1-120)"; alive=$((alive+1))
    fi
done
echo "  allowed launches still running at the end: $alive"
echo "NOLAB-TRIPWIRE: $n lab call(s) (all refused); $a allowed launch(es), $alive left running"; (( n == 0 && alive == 0 ))' _ "$NOLAB_LOG"
echo "GATES-$TAG $sha: $([ $fail = 0 ] && echo ALL-AS-EXPECTED || echo RED)"
exit $fail
