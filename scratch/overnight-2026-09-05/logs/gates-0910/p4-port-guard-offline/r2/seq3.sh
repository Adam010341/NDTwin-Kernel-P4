#!/usr/bin/env bash
D=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/p4-port-guard-offline/r2; C=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/clone-pg-r2; PY=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/clone-pg-r2/p4_proxy/venv/bin/python
g() { "$D/gated3.sh" "$@"; }
cd $C
$PY $D/mk_mut.py $C base100 > $D/mk_base100.log 2>&1
g red_base100 $C $C/p4_proxy $PY -m unittest -v tests.test_pg_mut_base100.PortFreeTest
sed -i "s#grpc_addr=f'localhost:{port_base + dpid}'#grpc_addr=f'localhost:{__import__(\"grpc_ports\").grpc_port(dpid)}'#" $C/p4_proxy/proxy_agent/main.py
git -C $C diff > $D/mut_main.diff.log
g red_mainport $C $C/p4_proxy $PY -m unittest -v tests.test_port_guard.PortFreeTest
git -C $C checkout -- p4_proxy/proxy_agent/main.py
rm -f $C/p4_proxy/tests/test_pg_mut_*.py
mv $C/p4_proxy/p4_src/build $C/p4_proxy/p4_src/build.away
g ci_shape $C $C/p4_proxy $PY -m unittest -v tests.test_port_guard
mv $C/p4_proxy/p4_src/build.away $C/p4_proxy/p4_src/build
echo seq3 done > $D/seq3.done
