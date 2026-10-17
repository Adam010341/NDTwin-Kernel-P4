#!/usr/bin/env bash
D=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-port-guard-offline/r3; C=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/clone-pg-r3; PY=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/clone-pg-r3/p4_proxy/venv/bin/python; M=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/clone-pg-r3/p4_proxy/mininet
P=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/healthcut2/pr-cut2/p4lane.sh
g() { "$D/gated4.sh" "$@"; }
cd $C
rm -rf $D/pkg; mkdir -p $D/pkg
$PY $C/tools/p4_exercise/convert.py $C/tools/p4_exercise/tests/fixtures/firewall --topology pod-topo/topology.json --p4 basic.p4 --out $D/pkg/firewall > $D/convert.log 2>&1; echo "convert rc=$?" >> $D/convert.log
g green_new $C $C/p4_proxy $PY -m unittest -v tests.test_port_guard
g knobs_all_set $C $C/p4_proxy bash -c "echo $D/pkg/firewall > $M/app_package_override; echo 128 > $M/host_count_override; echo none > $M/telemetry_override; $PY -m unittest -v tests.test_port_guard; rc=\$?; echo knobs-were: \$(cat $M/app_package_override $M/host_count_override $M/telemetry_override | tr '\n' ' '); rm -f $M/app_package_override $M/telemetry_override; git -C $C checkout -- p4_proxy/mininet/host_count_override; exit \$rc"
rm -f $M/app_package_override $M/telemetry_override; git -C $C checkout -- p4_proxy/mininet/host_count_override
mv $C/p4_proxy/p4_src/build $C/p4_proxy/p4_src/build.away
g p4lane_nobuild $C $C bash $P $C
mv $C/p4_proxy/p4_src/build.away $C/p4_proxy/p4_src/build
g p4lane $C $C bash $P $C
echo seq4 done > $D/seq4.done
