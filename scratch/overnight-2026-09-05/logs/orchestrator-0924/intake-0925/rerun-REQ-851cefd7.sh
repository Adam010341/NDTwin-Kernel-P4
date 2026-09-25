#!/usr/bin/env bash
# rerun-REQ-851cefd7.sh -- orchestrator's reproduction: both suites under the venv built fresh from
# requirements.txt at 851cefd7 (venv-aligned2) and under the main venv, same worktree commit.
# [Co-developed with claude code -- Adam]
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4proxy-reqs-0925
GUARD=/home/adam/Desktop/NDTwin-Kernel/tools/build_guard/guarded_build.sh
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0925
[[ "$(git -C $WT rev-parse --short=8 HEAD)" == 851cefd7 && -z "$(git -C $WT status --porcelain | grep -v '^??')" ]] || { echo REFUSE; exit 2; }
MODS=$(ls $WT/p4_proxy/tests/test_*.py | sed 's#.*/tests/##; s#\.py$##; s#^#tests.#' | tr '\n' ' ')
for pair in "aligned2 $WT/scratch/venv-aligned2/bin/python" "mainvenv /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python"; do
  set -- $pair; tag=$1; PY=$2; log=$L/rerun-REQ-851cefd7.$tag.log
  { echo "# HEAD $(git -C $WT rev-parse HEAD) interpreter $PY ($(readlink -f $PY)) $(date -u +%FT%TZ)"
    ( cd $WT/p4_proxy && JOBS=1 LOCK_WAIT=10800 $GUARD env PYTHONPATH=$WT/p4_proxy PYTHONDONTWRITEBYTECODE=1 $PY -m unittest $MODS ); echo "# p4_proxy rc=$?"
    ( cd $WT && JOBS=1 LOCK_WAIT=10800 $GUARD env PYTHONDONTWRITEBYTECODE=1 $PY -m unittest discover -s tools/p4_exercise/tests -t tools/p4_exercise/tests ); echo "# p4_exercise rc=$?"
  } > $log 2>&1
  echo "$tag: $(grep -E '^Ran|^OK|^FAILED|# .* rc=' $log | tr '\n' ' ')"
done
echo DONE
