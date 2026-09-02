#!/usr/bin/env bash
set -u
cd /home/adam/Desktop/NDTwin-Kernel
R=doc/audit/2026-09-03_night-rounds/round5-topology-repro
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad
# tear down whatever cycle 1 left
setsid env NDT_OWNER=auditor tools/test_workflow/ndt down > $S/udown_1.log 2>&1
for i in $(seq 1 40); do [[ "$(ps -eo comm= | grep -c '^simple_switch')" == "0" ]] && break; sleep 2; done
sleep 4
echo "  cycle 1 torn down: bmv2=$(ps -eo comm= | grep -c '^simple_switch') iperf3=$(ps -eo comm= | grep -cx iperf3)" >> $R/24_uplink_race_moves_measurement.log
for n in 2 3 4 5 6 7 8; do
    bash $R/uplink_cycle.sh $n >> $R/24_uplink_race_moves_measurement.log 2>&1
done
echo "ALL-CYCLES-DONE $(date -Is)" >> $R/24_uplink_race_moves_measurement.log
