#!/usr/bin/env bash
# One cycle: bring up, read s3's boot route for 10.0.0.1 from the SWITCH, run h3->h1 traffic,
# and record which edges the twin publishes as carrying it. s3 port 1 = towards s7, port 2 = s8.
# [Co-developed with claude code -- Adam]
set -u
cd /home/adam/Desktop/NDTwin-Kernel
N="$1"; S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad
echo "===== uplink cycle $N : $(date -Is) ====="
setsid env NDT_OWNER=auditor tools/test_workflow/ndt up p4 4 > $S/uup_$N.log 2>&1 &
for i in $(seq 1 60); do grep -q "up. ready" $S/uup_$N.log 2>/dev/null && break; sleep 2; done
grep -q "up. ready" $S/uup_$N.log || { echo "BRING-UP FAILED"; tail -5 $S/uup_$N.log; exit 1; }
sleep 8
H3=$(ps -eo pid=,args= | awk '$NF=="mininet:h3"{print $1}')
H1=$(ps -eo pid=,args= | awk '$NF=="mininet:h1"{print $1}')
setsid sudo -n mnexec -a $H1 iperf3 -s -1 > /dev/null 2>&1 &
sleep 2
setsid sudo -n mnexec -a $H3 iperf3 -c 10.0.0.1 -u -b 20M -l 1400 -t 30 --json > $S/uiperf_$N.json 2>&1 &
sleep 20
python3 - "$N" <<'PY'
import json,sys,urllib.request
n=sys.argv[1]; out={"cycle":n}
with urllib.request.urlopen("http://127.0.0.1:8081/stats/flow/3",timeout=25) as r: b=json.loads(r.read().decode())
rows={}
for _k,es in b.items():
    for e in es: rows[e.get("match",{}).get("nw_dst")]=",".join(e.get("actions",[]))
out["s3_route_to_10.0.0.1"]=rows.get("10.0.0.1")
out["s3_uplink_used"]={"OUTPUT:1":"s7","OUTPUT:2":"s8"}.get(rows.get("10.0.0.1"),"?")
with urllib.request.urlopen("http://127.0.0.1:8000/ndt/get_graph_data",timeout=20) as r: g=json.loads(r.read().decode())
nz={}
for e in g["edges"]:
    u=e.get("link_bandwidth_utilization_percent")
    if isinstance(u,(int,float)) and u>0:
        nz["%s:%s->%s:%s"%(e["src_dpid"],e["src_interface"],e["dst_dpid"],e["dst_interface"])]=round(u,3)
out["nonzero_edges"]=dict(sorted(nz.items()))
with urllib.request.urlopen("http://127.0.0.1:8000/ndt/get_average_link_usage",timeout=10) as r:
    out["avg_link_usage"]=json.loads(r.read().decode())["avg_link_usage"]
print("UJSON "+json.dumps(out,sort_keys=True))
print("  s3 -> 10.0.0.1 via %s (%s) ; edges carrying traffic: %s"%(out["s3_route_to_10.0.0.1"],out["s3_uplink_used"],list(out["nonzero_edges"])))
PY
sleep 14
setsid env NDT_OWNER=auditor tools/test_workflow/ndt down > $S/udown_$N.log 2>&1
for i in $(seq 1 40); do [[ "$(ps -eo comm= | grep -c '^simple_switch')" == "0" ]] && break; sleep 2; done
sleep 4
echo "  torn down: bmv2=$(ps -eo comm= | grep -c '^simple_switch') iperf3=$(ps -eo comm= | grep -cx iperf3) tcp8000=$(ss -ltnH 'sport = :8000' | wc -l) free=$(free -m | awk '/^Mem/{print $7}')MB"
