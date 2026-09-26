#!/usr/bin/env bash
# ndt serve anchors fix: gates on the worktree's HEAD. [Co-developed with claude code -- Adam]
# Each through guarded_build (JOBS=1 LOCK_WAIT=10800) into logs/gates-0910/<gate>.ndtserve-<sha8>.log,
# first line the full sha, last line `# rc=<n>`. EXPECT_RED=1 declares the base's known reds.
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ndt-serve-anchors-0926
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
GUARD=$WT/tools/build_guard/guarded_build.sh
sha=$(git -C "$WT" rev-parse --short=8 HEAD); full=$(git -C "$WT" rev-parse HEAD)
tree_state() { git -C "$WT" status --porcelain -- tools tests doc p4_proxy | /usr/bin/grep -v '^??' | head -1; }
[[ -z "$(tree_state)" ]] || { echo "REFUSE: tracked changes in the worktree"; exit 2; }
export TMPDIR="$SP/tmp"; mkdir -p "$TMPDIR"
S="$L/scripts-ndtserve-$sha"; mkdir -p "$S"
cp "${BASH_SOURCE[0]}" "$SP/py_lane.sh" "$S/"; ( cd "$S" && sha256sum * > SHA256SUMS )
fail=0
run() {   # run <gate> <expected rc> <why, or -> <cwd> <cmd...>
    local name="$1" want="$2" why="$3" cwd="$4" log="$L/$1.ndtserve-$sha.log" rc
    shift 4
    if [[ -e "$log" ]]; then echo "REFUSE: $log exists"; fail=1; return; fi
    if [[ "$(git -C "$WT" rev-parse HEAD)" != "$full" || -n "$(tree_state)" ]]; then echo "REFUSE: HEAD moved or tracked files changed"; exit 3; fi
    { echo "$full"; echo "# worktree $WT  $(date -u +%FT%TZ)"; echo "# cwd $cwd"; echo "# cmd $*"
      echo "# via JOBS=1 LOCK_WAIT=10800 $GUARD"; [[ "$want" != 0 ]] && echo "# EXPECTED rc=$want: $why"; } > "$log"
    ( cd "$cwd" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; rc=$?
    echo "# rc=$rc" >> "$log"
    printf '%-28s rc=%s%s  %s\n' "$name" "$rc" "$([[ $want != 0 ]] && echo " (expected $want)")" \
        "$(/usr/bin/grep -v -E '^# rc=|^guarded_build: ' "$log" | tail -1 | cut -c1-150)"
    [[ "$rc" == "$want" ]] || fail=1
}
R="${EXPECT_RED:-0}"
run test_ndt_serve "$R" "the red CI saw on cafd518a: RcProvenance, 11 anchors moved by segment W's +124 ndt lines" "$WT" python3 tests/python/test_ndt_serve.py -v
run test_ndt_serve_cells 0 - "$WT" python3 tests/python/test_ndt_serve_cells.py -v
run mutate_ndt_serve "$(( R ? 2 : 0 ))" "the gate's baseline is the whole suite, which is red on cafd518a" "$WT" bash tests/shell/mutate_ndt_serve.sh
run check_gate_anchors 0 - "$WT" python3 tests/shell/check_gate_anchors.py "$sha"
run py_lane 1 "files CI already lists as problem groups on the previous run (test_grpc_port_block, and any skip-lane file on this interpreter) -- the log names each; the comparison is in the SUMMARY" "$WT" bash "$S/py_lane.sh" "$WT" "$TMPDIR/py_lane_$sha"
echo "FINAL-GATES $sha: $([ $fail = 0 ] && echo ALL-AS-EXPECTED || echo RED)"
exit $fail
