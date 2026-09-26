#!/usr/bin/env bash
# 08's H5 sampler fix: gates on the worktree's HEAD. [Co-developed with claude code -- Adam]
# Each via guarded_build (JOBS=1 LOCK_WAIT=10800) into logs/gates-0910/<gate>.p4hbh5-<sha8>.log.
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-08-h5-sampler-0926
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/6e0a568f-9cd4-4ec8-9673-89540b96867b/scratchpad
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
GUARD=$WT/tools/build_guard/guarded_build.sh
sha=$(git -C "$WT" rev-parse --short=8 HEAD); full=$(git -C "$WT" rev-parse HEAD)
tree_state() { git -C "$WT" status --porcelain -- p4_proxy tools tests doc | /usr/bin/grep -v '^??' | head -1; }
[[ -z "$(tree_state)" ]] || { echo "REFUSE: tracked changes in the worktree"; exit 2; }
export TMPDIR="$SP/tmp"; mkdir -p "$TMPDIR"
S="$L/scripts-p4hbh5-$sha"; mkdir -p "$S"
cp "${BASH_SOURCE[0]}" "$SP/live08_sampler_redfirst.sh" "$SP/embedded_sweep.py" "$SP/embedded_cover.py" \
   "$SP/cover_run.sh" "$SP/runtime_check.sh" "$S/"; ( cd "$S" && sha256sum * > SHA256SUMS )
fail=0
run() {
    local name="$1" want="$2" why="$3" cwd="$4" log="$L/$1.p4hbh5-$sha.log" rc
    shift 4
    if [[ -e "$log" ]]; then echo "REFUSE: $log exists"; fail=1; return; fi
    if [[ "$(git -C "$WT" rev-parse HEAD)" != "$full" || -n "$(tree_state)" ]]; then echo "REFUSE: HEAD moved or tracked files changed"; exit 3; fi
    { echo "$full"; echo "# worktree $WT  $(date -u +%FT%TZ)"; echo "# cwd $cwd"; echo "# cmd $*"
      echo "# via JOBS=1 LOCK_WAIT=10800 $GUARD"; [[ "$want" != 0 ]] && echo "# EXPECTED rc=$want: $why"; } > "$log"
    ( cd "$cwd" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; rc=$?
    echo "# rc=$rc" >> "$log"
    printf '%-30s rc=%s%s  %s\n' "$name" "$rc" "$([[ $want != 0 ]] && echo " (expected $want)")" \
        "$(/usr/bin/grep -v -E '^# rc=|^guarded_build: |^files restored' "$log" | tail -1 | cut -c1-150)"
    [[ "$rc" == "$want" ]] || fail=1
}
LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
SPIKE=doc/audit/2026-09-25_p4-heartbeat/spike
run live08_selftest 0 - "$WT" bash "$LIVE/08_heartbeat.sh" --self-test
run live08_sampler_redfirst 0 - "$WT" bash "$S/live08_sampler_redfirst.sh" "$WT"
run mutate_p4_heartbeat_w 0 - "$WT" bash tests/shell/mutate_p4_heartbeat_w.sh
run check_gate_anchors 0 - "$WT" python3 tests/shell/check_gate_anchors.py "$sha"
run embedded_compile 0 - "$WT" python3 "$S/embedded_sweep.py" --strict --py /usr/bin/python3 --py "$WT/p4_proxy/venv/bin/python" \
    "$LIVE/08_heartbeat.sh" "$LIVE/07_roles_basic.sh" "$LIVE/_common.sh" "$SPIKE/S_heartbeat_spike.sh" "$SPIKE/oldcode_selftest.sh"
run embedded_cover 0 - "$WT" bash "$S/cover_run.sh" "$WT" "$SP/tmp/cover_$sha" "$S/embedded_cover.py"
run runtime_check 0 - "$WT" bash "$S/runtime_check.sh" "$WT"
echo "FINAL-GATES $sha: $([ $fail = 0 ] && echo ALL-AS-EXPECTED || echo RED)"
exit $fail
