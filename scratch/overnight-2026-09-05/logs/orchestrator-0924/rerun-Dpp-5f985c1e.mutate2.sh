#!/usr/bin/env bash
# the first try refused (no venv in the worktree; rerun-Dpp-5f985c1e.mutate.log kept) -- PYTHON= as D'' did.
# [Co-developed with claude code -- Adam]
set -u
W=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-ecn-0925
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924
cd "$W" || exit 9
{ echo "# HEAD $(git rev-parse HEAD) $(date -u +%FT%TZ)"; PYTHON=/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh bash tests/shell/mutate_drive_exercise.sh; echo "# rc=$?"; } > $L/rerun-Dpp-5f985c1e.mutate2.log 2>&1
echo "mutate: $(grep -E 'mutation gate|# rc=' $L/rerun-Dpp-5f985c1e.mutate2.log | tail -2 | tr '\n' ' ')"
echo "tracked changes after: $(git status --porcelain | grep -v '^??' | wc -l); drv dirs $(ls /tmp | grep -c '^drv-')"
echo DONE
