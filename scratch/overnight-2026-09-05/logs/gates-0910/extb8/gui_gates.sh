#!/usr/bin/env bash
# gui_gates.sh -- extb8: GUI v2's suites, the two ndt_serve mutation gates, the page suite and page gate, and
# the ndt status --measuring suite/gate and the anchor check, on B's head after the ndt citation fix.
# Commands as HANDOFF-ndt-serve-1001.md section 3 gives them; extb7's driver with TMPDIR=/tmp/r8 (Chrome's
# 107-byte socket path). The three ndt gates run with extb6m's nolab shims on PATH, as extb6m ran them.
# [Co-developed with claude code -- Adam]
set -u
W=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-external-detect-0927
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910
D=$L/extb8
GUARD=$W/tools/build_guard/guarded_build.sh
sha=$(git -C $W rev-parse --short=8 HEAD); full=$(git -C $W rev-parse HEAD)
P312=/usr/bin/python3.12; P38=$HOME/miniconda3/envs/ryu-env/bin/python3.8
export TMPDIR=/tmp/r8; mkdir -p "$TMPDIR"
unset NDT_MEASURING
bash $D/make_shims.sh $D/shims > /dev/null; : > $D/tripwire.log
SHIMPATH="$D/shims:$PATH"
free_mb() { df --output=avail -BM / | tail -1 | tr -dc 0-9; }
run() {   # run <name> <guard|bare|guard-nolab> <cmd...>
    local name="$1" how="$2" log="$L/$1.extb8-$sha.log" rc; shift 2
    [[ -e "$log" ]] && { echo "REFUSE: $log exists"; exit 2; }
    (( $(free_mb) >= 2048 )) || { echo "DISK-FLOOR: $(free_mb) MB before $name -- stopping"; exit 97; }
    [[ "$(git -C $W rev-parse HEAD)" == "$full" && -z "$(git -C $W status --porcelain | grep -v '^??')" ]] || { echo "REFUSE: HEAD moved or tracked files changed"; exit 3; }
    { echo "$full"; echo "# $(date -u +%FT%TZ) cwd $W TMPDIR $TMPDIR via $how; disk $(free_mb) MB"; echo "# cmd $*"; } > "$log"
    case "$how" in
      guard) ( cd $W && JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; rc=$? ;;
      guard-nolab) ( cd $W && PATH="$SHIMPATH" NOLAB_LOG=$D/tripwire.log NOLAB_SUITE=$name NOLAB_PASS=extb8 NOLAB_FAKE_FABRIC=0 \
                     JOBS=1 LOCK_WAIT=10800 "$GUARD" "$@" ) >> "$log" 2>&1; rc=$? ;;
      bare) ( cd $W && "$@" ) >> "$log" 2>&1; rc=$? ;;
    esac
    echo "# rc=$rc" >> "$log"; printf '%-34s rc=%s  %s\n' "$name" "$rc" "$(grep -vE '^# rc=|^guarded_build: ' "$log" | tail -1 | cut -c1-140)"
}
for t in test_ndt_serve test_ndt_serve_cells test_ndt_serve_gui test_ndt_serve_web; do
    run "gui_${t}_py312" guard env PYTHONDONTWRITEBYTECODE=1 $P312 tests/python/$t.py
    run "gui_${t}_py38" guard env PYTHONDONTWRITEBYTECODE=1 $P38 tests/python/$t.py
done
run check_gate_anchors guard-nolab python3 tests/shell/check_gate_anchors.py "$sha"
run check_gate_anchors_gui guard env PYTHONDONTWRITEBYTECODE=1 $P312 tests/shell/check_gate_anchors.py --gates-from HEAD --gates mutate_ndt_serve.sh mutate_ndt_serve_page.sh -- HEAD
run test_ndt_status_measuring guard-nolab bash tests/shell/test_ndt_status_measuring.sh
run mutate_ndt_status_measuring guard-nolab bash tests/shell/mutate_ndt_status_measuring.sh
run gui_mutate_ndt_serve_py312 guard env PYTHON=$P312 PYTHONDONTWRITEBYTECODE=1 bash tests/shell/mutate_ndt_serve.sh
run gui_mutate_ndt_serve_py38 guard env PYTHON=$P38 PYTHONDONTWRITEBYTECODE=1 bash tests/shell/mutate_ndt_serve.sh
run gui_page_suite guard env PYTHONDONTWRITEBYTECODE=1 python3 tests/browser/test_ndt_serve_page.py
run gui_mutate_ndt_serve_page bare env NODE_BIN=$HOME/.local/node/bin bash tests/shell/mutate_ndt_serve_page.sh
echo "tripwire lines: $(wc -l < $D/tripwire.log)"
echo "GUI-GATES-extb8 $sha done"
