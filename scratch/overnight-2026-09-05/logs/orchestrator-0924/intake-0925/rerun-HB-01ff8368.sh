#!/usr/bin/env bash
# rerun-HB-01ff8368.sh -- orchestrator's reproduction of HB round 3's spike self-test at the worker head.
# Round 3 touched only the spike script, so the helper suites are not re-run (sha unchanged).
# [Co-developed with claude code -- Adam]
set -u
W=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-heartbeat-0925
I=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0925
[[ "$(git -C $W rev-parse --short=8 HEAD)" == 01ff8368 && -z "$(git -C $W status --porcelain | grep -v '^??')" ]] || { echo REFUSE; exit 2; }
cd $W
unset FAULTS_TC
{ echo "# HEAD $(git rev-parse HEAD) $(date -u +%FT%TZ)"; bash doc/audit/2026-09-25_p4-heartbeat/spike/S_heartbeat_spike.sh --self-test; echo "# rc=$?"; } > $I/rerun-HB-01ff8368.spike_selftest.log 2>&1
echo "spike_selftest: $(grep -c '🔴' $I/rerun-HB-01ff8368.spike_selftest.log) red; $(tail -2 $I/rerun-HB-01ff8368.spike_selftest.log | tr '\n' ' ')"
grep 'evidence:' $I/rerun-HB-01ff8368.spike_selftest.log
echo "helper sha256 at head: $(sha256sum tools/test_workflow/ndtwin-lab | cut -c1-16)"
echo "tracked changes after: $(git status --porcelain | grep -v '^??' | wc -l)"
echo DONE
