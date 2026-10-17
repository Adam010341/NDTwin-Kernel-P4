#!/usr/bin/env bash
D=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-port-guard-offline/r2; C=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/clone-pg-r2; PY=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/clone-pg-r2/p4_proxy/venv/bin/python; K=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/clone-pg-r2/p4_proxy/mininet/app_package_override; T=$C/p4_proxy/tests
P=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/healthcut2/pr-cut2/p4lane.sh
g() { "$D/gated2.sh" "$@"; }
cd $C
# converted package, built the way test_foreign_pipeline.py:362-366 does
rm -rf $D/pkg; mkdir -p $D/pkg
$PY $C/tools/p4_exercise/convert.py $C/tools/p4_exercise/tests/fixtures/firewall --topology pod-topo/topology.json --p4 basic.p4 --out $D/pkg/firewall > $D/convert.log 2>&1; echo "convert rc=$?" >> $D/convert.log
# 1 green: new test, shipped state
g green_new $C $C/p4_proxy $PY -m unittest -v tests.test_port_guard
# 2 knob: old version red, new version green, with the knob naming the converted package
$PY $D/mk_mut.py $C oldversion > $D/mk_oldversion.log 2>&1
g knob_old_version $C $C/p4_proxy bash -c "echo $D/pkg/firewall > $K; $PY -m unittest -v tests.test_pg_mut_oldversion; rc=\$?; echo knob-was: \$(cat $K); rm -f $K; exit \$rc"
g knob_new_version $C $C/p4_proxy bash -c "echo $D/pkg/firewall > $K; $PY -m unittest -v tests.test_port_guard; rc=\$?; echo knob-was: \$(cat $K); rm -f $K; exit \$rc"
rm -f $K
# 3 kernel URL dropped: must go red naming 8000
$PY $D/mk_mut.py $C nokernelurl > $D/mk_nokernelurl.log 2>&1
g red_nokernelurl $C $C/p4_proxy $PY -m unittest -v tests.test_pg_mut_nokernelurl.PortFreeTest
# 4 base moved out of the block: guard must refuse
$PY $D/mk_mut.py $C base100 > $D/mk_base100.log 2>&1
g red_base100 $C $C/p4_proxy $PY -m unittest -v tests.test_pg_mut_base100.PortFreeTest
# 5 main.py through grpc_ports.grpc_port(dpid) (default bound at import): dials 30051.. -> refused
cp $C/p4_proxy/proxy_agent/main.py $D/main.py.orig
sed -i "s#grpc_addr=f'localhost:{port_base + dpid}'#grpc_addr=f'localhost:{__import__(\"grpc_ports\").grpc_port(dpid)}'#" $C/p4_proxy/proxy_agent/main.py
git -C $C diff --stat > $D/mut_main.diffstat.log; git -C $C diff >> $D/mut_main.diffstat.log
g red_mainport $C $C/p4_proxy $PY -m unittest -v tests.test_port_guard.PortFreeTest
git -C $C checkout -- p4_proxy/proxy_agent/main.py
# 6 old _nothing_listens vs the mocked tests (no proxy)
$PY $D/mk_mut.py $C oldlisten > $D/mk_oldlisten.log 2>&1
g red_oldlisten $C $C/p4_proxy $PY -m unittest -v tests.test_pg_mut_oldlisten.NothingListensTest
# 7 CI-shaped: no p4_src/build
mv $C/p4_proxy/p4_src/build $C/p4_proxy/p4_src/build.away
g ci_shape $C $C/p4_proxy $PY -m unittest -v tests.test_port_guard
mv $C/p4_proxy/p4_src/build.away $C/p4_proxy/p4_src/build
rm -f $T/test_pg_mut_*.py
# 8 p4lane
g p4lane $C $C bash $P $C
echo seq2 done > $D/seq2.done
