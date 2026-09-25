#!/usr/bin/env bash
# rerun-OVS-98442add.sh -- orchestrator's reproduction of OVS round 3's gates at the worker head.
# [Co-developed with claude code -- Adam]
set -u
W=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-ndt-ovs-claim-0925
I=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0925
PY=/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python
[[ "$(git -C $W rev-parse --short=8 HEAD)" == 98442add && -z "$(git -C $W status --porcelain | grep -v '^??')" ]] || { echo REFUSE; exit 2; }
cd $W
g() { local name=$1; shift; { echo "# HEAD $(git rev-parse HEAD) $(date -u +%FT%TZ)"; JOBS=1 LOCK_WAIT=10800 PYTHON=$PY tools/build_guard/guarded_build.sh "$@"; echo "# rc=$?"; } > $I/rerun-OVS-98442add.$name.log 2>&1; echo "$name: $(tail -3 $I/rerun-OVS-98442add.$name.log | tr '\n' ' ')"; }
g test_ovs_claim bash tests/shell/test_ndt_ovs_claim.sh
g mutate_ovs_claim bash tests/shell/mutate_ndt_ovs_claim.sh
g test_robust bash tests/shell/test_ndt_up_down_robust.sh
g test_apps_window bash tests/shell/test_ndt_helper_apps_window.sh
g anchors $PY tests/shell/check_gate_anchors.py HEAD
echo "tracked changes after: $(git status --porcelain | grep -v '^??' | wc -l)"
echo DONE
