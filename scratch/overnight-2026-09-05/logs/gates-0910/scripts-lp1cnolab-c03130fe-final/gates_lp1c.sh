#!/usr/bin/env bash
# fix/live-p1-common-5e-nolab-0927: gates on the worktree's HEAD. [Co-developed with claude code -- Adam]
# Each through guarded_build (JOBS=1 LOCK_WAIT=10800) into logs/gates-0910/<gate>.lp1cnolab-<sha8>.log,
# first line the full sha, last line `# rc=<n>`; the scripts that run are the copies in
# logs/gates-0910/scripts-lp1cnolab-<sha8>-<mode>/. PATH starts with the nolab shims (sudo, mnexec,
# iperf, iperf3, ping refused; changing tc/ip/ovs refused; curl refused at :8000/:8081/:8080; ps
# adds a FAKE fabric only where a gate asks for one). The shims' log is the last gate.
#   MODE=sweep  -- only the sweep of every tests/shell/test_*.sh (passes A and B)
#   MODE=final  -- red first, the suite, its mutation gate, the sweep, the tripwire
set -u
MODE="${MODE:-final}"
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-live-p1-common-nolab-0927
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
GUARD=$WT/tools/build_guard/guarded_build.sh
TAG=lp1cnolab
sha=$(git -C "$WT" rev-parse --short=8 HEAD); full=$(git -C "$WT" rev-parse HEAD)
tree_state() { git -C "$WT" status --porcelain -- p4_proxy tools tests doc | /usr/bin/grep -v '^??' | head -1; }
[[ -z "$(tree_state)" ]] || { echo "REFUSE: tracked changes in the worktree"; exit 2; }
S="$L/scripts-$TAG-$sha-$MODE"; mkdir -p "$S"
cp "${BASH_SOURCE[0]}" "$SP/nolab2/make_shims.sh" "$SP/nolab2/nolab_sweep.sh" "$SP/nolab2/redfirst_lp1c.sh" "$S/"
bash "$S/make_shims.sh" "$S/shims" > /dev/null
( cd "$S" && sha256sum *.sh shims/* > SHA256SUMS )
export PATH="$S/shims:$PATH" NOLAB_LOG="$S/tripwire.log" NOLAB_SUITE=gates NOLAB_PASS="$MODE" NOLAB_FAKE_FABRIC=0
unset SELFTEST_PROBE_SUDO NDT_MEASURING
: > "$NOLAB_LOG"
TMP_LONG="$SP/tmp"; mkdir -p "$TMP_LONG"
fail=0
run() {   # run <gate> <expected rc> <why, or -> <cmd...>
    local name="$1" want="$2" why="$3" log="$L/$1.$TAG-$sha.log" rc
    shift 3
    if [[ -e "$log" ]]; then echo "REFUSE: $log exists"; fail=1; return; fi
    if [[ "$(git -C "$WT" rev-parse HEAD)" != "$full" || -n "$(tree_state)" ]]; then echo "REFUSE: HEAD moved or tracked files changed"; exit 3; fi
    { echo "$full"; echo "# worktree $WT  $(date -u +%FT%TZ)"; echo "# cwd $WT  TMPDIR $TMP_LONG"; echo "# cmd $*"
      echo "# via JOBS=1 LOCK_WAIT=10800 $GUARD"; echo "# PATH starts $S/shims (nolab)"
      [[ "$want" != 0 ]] && echo "# EXPECTED rc=$want: $why"; } > "$log"
    ( cd "$WT" && TMPDIR="$TMP_LONG" JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; rc=$?
    echo "# rc=$rc" >> "$log"
    printf '%-24s rc=%s%s  %s\n' "$name" "$rc" "$([[ $want != 0 ]] && echo " (expected $want)")" \
        "$(/usr/bin/grep -v -E '^# rc=|^guarded_build: ' "$log" | tail -1 | cut -c1-150)"
    [[ "$rc" == "$want" ]] || fail=1
}
if [[ "$MODE" == final ]]; then
    run redfirst_lp1c 0 - bash "$S/redfirst_lp1c.sh" "$WT" "$S/shims"
    run test_live_p1_common 0 - bash tests/shell/test_live_p1_common.sh
    run mutate_live_p1_common 0 - bash tests/shell/mutate_live_p1_common.sh
    run check_gate_anchors 0 - python3 tests/shell/check_gate_anchors.py "$sha"
fi
run nolab_sweep 0 - bash "$S/nolab_sweep.sh" "$WT" "$SP/tmp/nolab_sweep_${MODE}_$sha"
run nolab_tripwire 0 - bash -c '
echo "lab commands the gates above made past their own stubs (the sweep logs its own, per suite):"
/usr/bin/grep -E " (sudo|mnexec|iperf|iperf3|ping) |localhost:80[08][01]|127\.0\.0\.1:80[08][01]" "$1" | sed "s/^/  /"
n=$(/usr/bin/grep -cE " (sudo|mnexec|iperf|iperf3|ping) |localhost:80[08][01]|127\.0\.0\.1:80[08][01]" "$1")
echo "NOLAB-TRIPWIRE: $n lab call(s) (all refused)"; (( n == 0 ))' _ "$NOLAB_LOG"
echo "GATES-LP1C $sha ($MODE): $([ $fail = 0 ] && echo ALL-AS-EXPECTED || echo RED)"
exit $fail
