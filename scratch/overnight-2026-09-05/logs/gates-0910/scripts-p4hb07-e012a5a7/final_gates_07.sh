#!/usr/bin/env bash
# The 07 heartbeat-links fix's gate run, on the worktree's HEAD. [Co-developed with claude code -- Adam]
# Every gate runs through guarded_build (JOBS=1 LOCK_WAIT=10800) and writes
# logs/gates-0910/<gate>.p4hb07-<sha8>.log: first line the full sha, last line `# rc=<n>`.
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-07-hb-links-0926
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
GUARD=$WT/tools/build_guard/guarded_build.sh
sha=$(git -C "$WT" rev-parse --short=8 HEAD); full=$(git -C "$WT" rev-parse HEAD)
tree_state() { git -C "$WT" status --porcelain -- p4_proxy tools tests doc | /usr/bin/grep -v '^??' | head -1; }
[[ -z "$(tree_state)" ]] || { echo "REFUSE: tracked changes in the worktree"; exit 2; }
export TMPDIR="$SP/tmp"; mkdir -p "$TMPDIR"
S="$L/scripts-p4hb07-$sha"; mkdir -p "$S"
cp "${BASH_SOURCE[0]}" "$SP/live07_redfirst.sh" "$S/"; ( cd "$S" && sha256sum * > SHA256SUMS )
fail=0
run() {   # run <gate> <expected rc> <why, or -> <cwd> <cmd...>
    local name="$1" want="$2" why="$3" cwd="$4" log="$L/$1.p4hb07-$sha.log" rc
    shift 4
    if [[ -e "$log" ]]; then echo "REFUSE: $log exists"; fail=1; return; fi
    if [[ "$(git -C "$WT" rev-parse HEAD)" != "$full" || -n "$(tree_state)" ]]; then echo "REFUSE: HEAD moved or tracked files changed"; exit 3; fi
    { echo "$full"; echo "# worktree $WT  $(date -u +%FT%TZ)"; echo "# cwd $cwd"; echo "# cmd $*"
      echo "# via JOBS=1 LOCK_WAIT=10800 $GUARD"; [[ "$want" != 0 ]] && echo "# EXPECTED rc=$want: $why"; } > "$log"
    ( cd "$cwd" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; rc=$?
    echo "# rc=$rc" >> "$log"
    printf '%-32s rc=%s%s  %s\n' "$name" "$rc" "$([[ $want != 0 ]] && echo " (expected $want)")" \
        "$(/usr/bin/grep -v -E '^# rc=|^guarded_build: ' "$log" | tail -1)"
    [[ "$rc" == "$want" ]] || fail=1
}
PREP_DIR=doc/audit/2026-09-04_p4-tutorial-exercise-prep
run live07_selftest 0 - "$WT" bash "$PREP_DIR/live-p1/07_roles_basic.sh" --self-test
run live07_redfirst 0 - "$WT" bash "$S/live07_redfirst.sh" "$WT"
run check_gate_anchors 0 - "$WT" python3 tests/shell/check_gate_anchors.py "$sha"
run mutate_roles_binding 0 - "$WT" bash tests/shell/mutate_roles_binding.sh
echo "FINAL-GATES $sha: $([ $fail = 0 ] && echo ALL-AS-EXPECTED || echo RED)"
exit $fail
