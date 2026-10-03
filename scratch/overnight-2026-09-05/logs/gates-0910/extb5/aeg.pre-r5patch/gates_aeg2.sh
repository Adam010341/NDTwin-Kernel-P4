#!/usr/bin/env bash
# gates_aeg2.sh -- redfirst_aeg again (the aeg run's proxy half used a bare archive with no setting/,
# so main.py could not import; now the HB W gate's own lay_out) and this run's tripwire.
# fix/rulings-aeg-0927 (Adam's rulings A, E, G, 09-27): red first (HEAD's tests over the base's code),
# 07's self-test, the live-p1 common and 06 suites and gates, the proxy's unit tests, the HB W and roles
# gates, the anchors, the tripwire. [Co-developed with claude code -- Adam]
# RUN ONLY FROM A FROZEN, READ-ONLY COPY. Each gate through guarded_build (JOBS=1 LOCK_WAIT=10800)
# into logs/gates-0910/<gate>.aeg-<sha8>.log (first line the full sha, last `# rc=<n>`); the
# scripts that run are the copies in scripts-aeg-<sha8>/; kept outputs in <gate>.aeg-<sha8>.kept/.
# PATH starts with the nolab shims; their log is the last gate.
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-rulings-aeg-0927
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
GUARD=$WT/tools/build_guard/guarded_build.sh
TAG=aeg2
sha=$(git -C "$WT" rev-parse --short=8 HEAD); full=$(git -C "$WT" rev-parse HEAD)
tree_state() { git -C "$WT" status --porcelain -- p4_proxy tools tests doc | /usr/bin/grep -v '^??' | head -1; }
[[ -z "$(tree_state)" ]] || { echo "REFUSE: tracked changes in the worktree"; exit 2; }
S="$L/scripts-$TAG-$sha"; [[ -e "$S" ]] && { echo "REFUSE: $S exists"; exit 2; }
mkdir -p "$S"
cp "${BASH_SOURCE[0]}" "$S/gates_aeg2.sh"
cp "$SP/aeg/"{redfirst_aeg,redfirst_lib}.sh "$SP/nolab2/make_shims.sh" "$SP/hbsnap.sha256" "$S/"
bash "$S/make_shims.sh" "$S/shims" > /dev/null
( cd "$S" && sha256sum *.sh hbsnap.sha256 shims/* > SHA256SUMS )
export PATH="$S/shims:$PATH" NOLAB_LOG="$S/tripwire.log" NOLAB_SUITE=gates NOLAB_PASS=aeg2 NOLAB_FAKE_FABRIC=0
unset SELFTEST_PROBE_SUDO NDT_MEASURING L1_POLL_S SELFTEST_L1_POLL_S
: > "$NOLAB_LOG"
SNAP="$SP/tmp/hbsnap"
( cd "$SNAP" && sha256sum -c --quiet "$S/hbsnap.sha256" ) || { echo "REFUSE: the snapshot changed"; exit 2; }
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
    printf '%-30s rc=%s%s  %s\n' "$name" "$rc" "$([[ $want != 0 ]] && echo " (expected $want)")" \
        "$(/usr/bin/grep -v -E '^# rc=|^guarded_build: ' "$log" | tail -1 | cut -c1-150)"
    [[ "$rc" == "$want" ]] || fail=1
}
k() { printf '%s' "$L/$1.$TAG-$sha.kept"; }
LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
run redfirst_aeg 0 - bash "$S/redfirst_aeg.sh" "$WT" "$(k redfirst_aeg)"
run nolab_tripwire 0 - bash -c '
echo "lab commands the gates above made past their own stubs:"
/usr/bin/grep -E " (sudo|mnexec|iperf|iperf3|ping|cmake|ninja|make|gcc|g\+\+|c\+\+|cc|clang|clang\+\+) |localhost:80[08][01]|127\.0\.0\.1:80[08][01]" "$1" | sed "s/^/  /"
n=$(/usr/bin/grep -cE " (sudo|mnexec|iperf|iperf3|ping|cmake|ninja|make|gcc|g\+\+|c\+\+|cc|clang|clang\+\+) |localhost:80[08][01]|127\.0\.0\.1:80[08][01]" "$1")
echo "  ($(/usr/bin/grep -c "" "$1") line(s) in the shims log in all)"
echo "NOLAB-TRIPWIRE: $n lab call(s) (all refused)"; (( n == 0 ))' _ "$NOLAB_LOG"
echo "GATES-AEG2 $sha: $([ $fail = 0 ] && echo ALL-AS-EXPECTED || echo RED)"
exit $fail
