#!/usr/bin/env bash
# rerun-HB-b22e88ed.sh -- orchestrator's reproduction of HB round 2's gates at the worker head.
# [Co-developed with claude code -- Adam]
set -u
W=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-heartbeat-0925
I=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0925
PY=/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python
[[ "$(git -C $W rev-parse --short=8 HEAD)" == b22e88ed && -z "$(git -C $W status --porcelain | grep -v '^??')" ]] || { echo REFUSE; exit 2; }
cd $W
g() { local name=$1; shift; { echo "# HEAD $(git rev-parse HEAD) $(date -u +%FT%TZ)"; JOBS=1 LOCK_WAIT=10800 PYTHON=$PY tools/build_guard/guarded_build.sh "$@"; echo "# rc=$?"; } > $I/rerun-HB-b22e88ed.$name.log 2>&1; echo "$name: $(tail -3 $I/rerun-HB-b22e88ed.$name.log | tr '\n' ' ')"; }
g test_heartbeat bash tests/shell/test_ndtwin_lab_heartbeat.sh
g test_g7 bash tests/shell/test_ndtwin_lab_config.sh
g mutate_heartbeat bash tests/shell/mutate_ndtwin_lab_heartbeat.sh
g mutate_g7 bash tests/shell/mutate_g7_ndtwin_lab_config.sh
echo "tracked changes after: $(git status --porcelain | grep -v '^??' | wc -l)"
echo DONE
