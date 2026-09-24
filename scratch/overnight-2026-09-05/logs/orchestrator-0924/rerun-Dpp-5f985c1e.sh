#!/usr/bin/env bash
# rerun-Dpp-5f985c1e.sh -- orchestrator's reproduction of D''s gates at the worker head (ruling 7).
# [Co-developed with claude code -- Adam]
set -u
W=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ecn-0925
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924
PY=/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python
cd "$W" || exit 9
[[ "$(git rev-parse --short=8 HEAD)" == 5f985c1e && -z "$(git status --porcelain | grep -v '^??')" ]] || { echo REFUSE; exit 2; }
n0=$(ls /tmp | grep -c '^drv-')
{ echo "# HEAD $(git rev-parse HEAD) $(date -u +%FT%TZ)"; JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh $PY -m unittest discover -s doc/audit/2026-09-04_p4-tutorial-exercise-prep/tests -t doc/audit/2026-09-04_p4-tutorial-exercise-prep/tests; echo "# rc=$?"; } > $L/rerun-Dpp-5f985c1e.unit.log 2>&1
echo "unit: $(grep -E '^Ran|^OK|^FAILED' $L/rerun-Dpp-5f985c1e.unit.log | tr '\n' ' ')"
{ echo "# HEAD $(git rev-parse HEAD) $(date -u +%FT%TZ)"; JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh bash tests/shell/mutate_drive_exercise.sh; echo "# rc=$?"; } > $L/rerun-Dpp-5f985c1e.mutate.log 2>&1
echo "mutate: $(grep -E 'mutation gate|# rc=' $L/rerun-Dpp-5f985c1e.mutate.log | tail -2 | tr '\n' ' ')"
echo "byte-identical: $(git status --porcelain | grep -v '^??' | wc -l) tracked changes; drv dirs $n0 -> $(ls /tmp | grep -c '^drv-')"
echo DONE
