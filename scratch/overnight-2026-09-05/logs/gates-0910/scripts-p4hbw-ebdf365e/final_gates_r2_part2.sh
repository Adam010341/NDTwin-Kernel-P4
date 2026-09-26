#!/usr/bin/env bash
# Segment W round 2, part 2: class_scan_probe again after its own instrument error (it typed NEW_CLASSES and went stale), on the worktree's HEAD. [Co-developed with claude code -- Adam]
#
# Every gate runs through tools/build_guard/guarded_build.sh with JOBS=1 LOCK_WAIT=10800 and writes
# logs/gates-0910/<gate>.p4hbw-<sha8>.log whose FIRST line is the full sha and whose LAST line is the
# real rc (`# rc=<n>`). A gate with a known non-zero rc is declared with that rc and why; the summary
# says ALL-AS-EXPECTED or RED. Before every gate HEAD and the tracked files are re-checked.
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-heartbeat-w-0926
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
PY=$WT/p4_proxy/venv/bin/python
GUARD=$WT/tools/build_guard/guarded_build.sh
ONLY="${ONLY:-}"
sha=$(git -C "$WT" rev-parse --short=8 HEAD)
full=$(git -C "$WT" rev-parse HEAD)
tree_state() { git -C "$WT" status --porcelain -- p4_proxy tools tests doc | /usr/bin/grep -v '^??' | head -1; }
[[ -z "$(tree_state)" ]] || { echo "REFUSE: tracked changes in the worktree; the gates must run on a commit"; exit 2; }
export TMPDIR="$SP/tmp"; mkdir -p "$TMPDIR"
S="$L/scripts-p4hbw-$sha"; mkdir -p "$S"
cp "${BASH_SOURCE[0]}" "$S/final_gates_r2_part2.sh" 2>/dev/null; cp "$SP/class_scan_probe.sh" "$S/class_scan_probe_fixed.sh" 2>/dev/null
( cd "$S" && sha256sum * > SHA256SUMS )
fail=0
run() {   # run <gate> <expected rc> <why, or -> <cwd> <cmd...>
    local name="$1" want="$2" why="$3" cwd="$4" log="$L/$1.p4hbw-$sha.log" rc
    shift 4
    [[ -n "$ONLY" && " $ONLY " != *" $name "* ]] && return
    if [[ -e "$log" ]]; then echo "REFUSE: $log exists (never overwrite a round)"; fail=1; return; fi
    if [[ "$(git -C "$WT" rev-parse HEAD)" != "$full" || -n "$(tree_state)" ]]; then
        echo "REFUSE: HEAD moved or tracked files changed under the round"; exit 3
    fi
    find "$WT/p4_proxy" "$WT/tools" "$WT/tests" "$WT/doc" -name __pycache__ -type d -not -path '*/venv/*' \
        -prune -exec rm -rf {} + 2>/dev/null
    { echo "$full"
      echo "# worktree $WT  $(date -u +%FT%TZ)"
      echo "# cwd $cwd"; echo "# cmd $*"
      echo "# via JOBS=1 LOCK_WAIT=10800 $GUARD"
      [[ "$want" != 0 ]] && echo "# EXPECTED rc=$want: $why"; } > "$log"
    ( cd "$cwd" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; rc=$?
    echo "# rc=$rc" >> "$log"
    printf '%-40s rc=%s%s  %s\n' "$name" "$rc" "$([[ $want != 0 ]] && echo " (expected $want)")" \
        "$(/usr/bin/grep -v -E '^# rc=|^guarded_build: |ResourceWarning|^  for index|^ResourceWarning' "$log" | tail -1)"
    [[ "$rc" == "$want" ]] || fail=1
}
EMPTYHOME="$SP/emptyhome"; mkdir -p "$EMPTYHOME"
MODS=$(ls "$WT"/p4_proxy/tests/test_*.py | sed 's#.*/tests/##; s#\.py$##; s#^#tests.#' | tr '\n' ' ')
PREP_DIR=doc/audit/2026-09-04_p4-tutorial-exercise-prep

run class_scan_probe_fixed 0 - "$WT" bash "$S/class_scan_probe_fixed.sh" "$WT"
echo "FINAL-GATES-2 $sha: $([ $fail = 0 ] && echo ALL-AS-EXPECTED || echo RED)"
exit $fail
