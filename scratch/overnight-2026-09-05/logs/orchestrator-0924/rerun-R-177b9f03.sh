#!/usr/bin/env bash
# rerun-R-177b9f03.sh -- the orchestrator's reproduction of R's round-3 gates at the worker head
# (goal (3): "re-run the gates at the worker head"). Same commands as R's final_gates_r3.sh, own
# log names (never overwrite a worker's round), through the guard with JOBS=1.
# [Co-developed with claude code -- Adam]
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-roles-0924
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1d79823a-41f9-4ae4-931e-5766b73d61e4/scratchpad
PY=$WT/p4_proxy/venv/bin/python; GUARD=$WT/tools/build_guard/guarded_build.sh
sha=$(git -C "$WT" rev-parse --short=8 HEAD); [[ "$sha" == 177b9f03 ]] || { echo "REFUSE: HEAD is $sha"; exit 2; }
export TMPDIR="$SP/tmp-orch"; mkdir -p "$TMPDIR"
fail=0
run() { local name="$1" cwd="$2" log="$L/rerun-R-$sha.$1.log" rc; shift 2
  [[ -e "$log" ]] && { echo "REFUSE: $log exists"; fail=1; return; }
  [[ -z "$(git -C "$WT" status --porcelain -- p4_proxy tools tests doc | grep -v '^??')" ]] || { echo "REFUSE: dirty tree"; exit 3; }
  { echo "# worktree $WT HEAD $(git -C "$WT" rev-parse HEAD) $(date -u +%FT%TZ)"; echo "# cmd $*"; } > "$log"
  ( cd "$cwd" && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; rc=$?; echo "# rc=$rc" >> "$log"
  printf '%-24s rc=%s  %s\n' "$name" "$rc" "$(grep -v -E '^# rc=|^guarded_build: |ResourceWarning' "$log" | tail -1)"
  (( rc != 0 )) && fail=1; }
MODS=$(ls "$WT"/p4_proxy/tests/test_*.py | sed 's#.*/tests/##; s#\.py$##; s#^#tests.#' | tr '\n' ' ')
run p4_proxy_suite "$WT/p4_proxy" env PYTHONPATH="$WT/p4_proxy" PYTHONDONTWRITEBYTECODE=1 "$PY" -m unittest $MODS
run live07_selftest "$WT" env SELFTEST_OLD_RUN=/home/adam/Desktop/NDTwin-Kernel/doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/runs/2026-09-19T062604Z_02_app_basic SELFTEST_OLD_TOPO=/home/adam/Desktop/NDTwin-Kernel/.test_run/packages/basic/ndtwin/topology.json bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/07_roles_basic.sh --self-test
run check_gate_anchors "$WT" python3 tests/shell/check_gate_anchors.py "$sha"
run mutate_roles_binding "$WT" bash tests/shell/mutate_roles_binding.sh
echo "ORCH-RERUN $sha: $([ $fail = 0 ] && echo ALL-GREEN || echo RED)"
