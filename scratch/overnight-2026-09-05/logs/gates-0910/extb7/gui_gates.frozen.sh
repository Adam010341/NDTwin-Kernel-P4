#!/usr/bin/env bash
# gui_gates.sh -- GUI v2's suites, page suite and the two ndt_serve mutation gates on B's merged head (round 7, N6),
# as HANDOFF-ndt-serve-1001.md §3 says to run them; one guard per run where the handoff allows one; disk floor 2 GB.
# [Co-developed with claude code -- Adam]
set -u
W=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
GUARD=$W/tools/build_guard/guarded_build.sh
sha=$(git -C $W rev-parse --short=8 HEAD); full=$(git -C $W rev-parse HEAD)
P312=/usr/bin/python3.12; P38=$HOME/miniconda3/envs/ryu-env/bin/python3.8
export TMPDIR=/tmp/claude-1000/g7; mkdir -p "$TMPDIR"
free_mb() { df --output=avail -BM / | tail -1 | tr -dc 0-9; }
run() {   # run <name> <guard|bare> <cmd...>
    local name="$1" how="$2" log="$L/$1.extb7-$sha.log" rc; shift 2
    (( $(free_mb) >= 2048 )) || { echo "DISK-FLOOR: $(free_mb) MB before $name -- stopping"; exit 97; }
    [[ "$(git -C $W rev-parse HEAD)" == "$full" && -z "$(git -C $W status --porcelain | grep -v '^??')" ]] || { echo "REFUSE: HEAD moved or tracked files changed"; exit 3; }
    { echo "$full"; echo "# $(date -u +%FT%TZ) cwd $W TMPDIR $TMPDIR via $how; disk $(free_mb) MB"; echo "# cmd $*"; } > "$log"
    if [[ "$how" == guard ]]; then ( cd $W && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; rc=$?
    else ( cd $W && "$@" ) >> "$log" 2>&1; rc=$?; fi
    echo "# rc=$rc" >> "$log"; printf '%-34s rc=%s  %s\n' "$name" "$rc" "$(grep -vE '^# rc=|^guarded_build: ' "$log" | tail -1 | cut -c1-140)"
}
for t in test_ndt_serve test_ndt_serve_cells test_ndt_serve_gui test_ndt_serve_web; do
    run "gui_${t}_py312" guard env PYTHONDONTWRITEBYTECODE=1 $P312 tests/python/$t.py
    run "gui_${t}_py38" guard env PYTHONDONTWRITEBYTECODE=1 $P38 tests/python/$t.py
done
run gui_mutate_ndt_serve_py312 guard env PYTHON=$P312 PYTHONDONTWRITEBYTECODE=1 bash tests/shell/mutate_ndt_serve.sh
run gui_mutate_ndt_serve_py38 guard env PYTHON=$P38 PYTHONDONTWRITEBYTECODE=1 bash tests/shell/mutate_ndt_serve.sh
run gui_page_suite guard env PYTHONDONTWRITEBYTECODE=1 python3 tests/browser/test_ndt_serve_page.py
run gui_mutate_ndt_serve_page bare env NODE_BIN=$HOME/.local/node/bin bash tests/shell/mutate_ndt_serve_page.sh
echo "GUI-GATES-extb7 $sha done"
