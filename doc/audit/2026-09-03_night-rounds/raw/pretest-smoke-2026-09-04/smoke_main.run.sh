#!/usr/bin/env bash
# Pre-test smoke of the MAIN checkout's rebuilt kernel on both planes, through the real `ndt`
# path (installed helper). OVS arm: #77 topo provenance, Q12 shape, #82 off/on, #1 group delete,
# #85 keys, #2 phantom probe, N19-Q3 line count, #27/#76 down time. P4 arm: bring-up, graph
# counts, Q12 shape, power off/on, keys, --check, down time. Refuses to run on a stale binary
# or a stale helper. Read-only on the repo; writes only under the scratchpad.
set -uo pipefail
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad
P=$S/pretest; R=/home/adam/Desktop/NDTwin-Kernel; NDT=$R/tools/test_workflow/ndt
K=http://localhost:8000; RYU=http://localhost:8080; PROBE=$R/doc/audit/2026-08-31_live-acceptance-batch/probe.py
KLOG=$R/.test_run/logs/kernel.log
export NDT_OWNER=auditor
say() { echo "[$(date +%T)] $*"; }
post() { curl -s -m 20 -o /tmp/smoke_body.$$ -w '%{http_code}' -X POST -H 'Content-Type: application/json' "$1" ${2:+-d "$2"}; echo "  $(cut -c1-240 /tmp/smoke_body.$$)"; }
get()  { curl -s -m 20 -o /tmp/smoke_body.$$ -w '%{http_code}' "$1"; echo "  $(cut -c1-240 /tmp/smoke_body.$$)"; }
groups() { curl -s -m 10 $RYU/stats/groupdesc/1 | python3 -c 'import sys,json; d=json.load(sys.stdin); print("   ryu groupdesc dpid1:", sorted(g["group_id"] for v in d.values() for g in v))' 2>&1; }
shape() { curl -s -m 10 $K/ndt/get_switches_power_state | python3 -c '
import sys,json; d=json.load(sys.stdin); ok=sum(1 for v in d.values() if isinstance(v,dict) and "admin_state" in v and "reachable" in v)
print("   power_state: switches=%d object-shaped=%d sample=%s"%(len(d),ok,json.dumps(dict(list(d.items())[:1]))))' 2>&1; }
keys() { curl -s -m 10 $K/ndt/get_cpu_utilization | python3 -c '
import sys,json,re; d=json.load(sys.stdin); bad=[k for k in d if not re.match(r"^\d+\.\d+\.\d+\.\d+$",k)]; print("   cpu keys=%d non-ip=%s"%(len(d),bad))' 2>&1; }
graph() { curl -s -m 10 $K/ndt/get_graph_data | python3 -c '
import sys,json; d=json.load(sys.stdin); g=d.get("Graph",d); v=g.get("vertices",g.get("nodes",[])); e=g.get("edges",[])
sw=[x for x in v if str(x.get("vertex_type","")).upper().find("SWITCH")>=0 or x.get("vertex_type")==1]
print("   graph: vertices=%d switches~%d edges=%d reachable_true=%d"%(len(v),len(sw),len(e),sum(1 for x in v if x.get("reachable") is True)))' 2>&1; }
klog() { echo "   kernel.log: lines=$(wc -l < $KLOG 2>/dev/null) withholding=$(grep -c withholding $KLOG) not-evidence=$(grep -c 'not evidence' $KLOG) still_present=$(grep -c still_present $KLOG) unverified=$(grep -c unverified $KLOG) no-mgmt-addr=$(grep -c 'carries no management address' $KLOG) cmd-failed-exit2=$(grep -c 'Command failed (exit code 2)' $KLOG) shutting-down=$(grep -c 'Shutting down' $KLOG) exiting-now=$(grep -c 'exiting now' $KLOG) SIGSEGV=$(grep -ci 'segv\|segmentation' $KLOG)"; }
topo_proc() { for p in $(ps -C python3 -o pid= 2>/dev/null); do c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null); [[ "$c" == *testbed_topo* ]] && echo "   topo pid $p: $(echo "$c" | cut -c1-150)"; done; }
down_timed() { local t0 t1 rc; t0=$(date +%s.%N); ( cd $R && timeout 300 $NDT down ) > $P/smoke_down_$1.log 2>&1; rc=$?; t1=$(date +%s.%N); say "ndt down rc=$rc wall=$(python3 -c "print(round($t1-$t0,2))") s"; tail -2 $P/smoke_down_$1.log | sed 's/^/   /'; }

say "=== pre-test smoke :: main checkout $(git -C $R rev-parse --short HEAD) binary $(sha256sum $R/build/bin/ndtwin_kernel | cut -c1-16) ($(stat -c %y $R/build/bin/ndtwin_kernel | cut -c1-16)) helper $(sha256sum /usr/local/sbin/ndtwin-lab | cut -c1-8) ==="
if [[ "$(sha256sum /usr/local/sbin/ndtwin-lab | cut -c1-8)" != "$(sha256sum $R/tools/test_workflow/ndtwin-lab | cut -c1-8)" ]]; then [[ "${1:-}" == "--allow-stale-helper" ]] && say "!! RUNNING ON THE STALE 08-30 HELPER (288b71cb): #77 provenance check will show NTG, lab fixes G-7/G-9/ports/#77 NOT exercised" || { say "ABORT: installed helper != repo helper (not reinstalled yet); pass --allow-stale-helper to run the kernel-level checks anyway"; exit 3; }; fi
[[ "$(sha256sum $R/build/bin/ndtwin_kernel | cut -c1-8)" != "a8ba99c2" ]] || { say "ABORT: binary is still the 09-03 00:46 build"; exit 3; }
ps -C ndtwin_kernel -o pid= >/dev/null 2>&1 && { say "ABORT: a ndtwin_kernel is already running"; exit 3; }
( cd $R && $NDT claim 45 "pre-test smoke of the rebuilt main-checkout kernel, OVS then P4 (auditor)" ) 2>&1 | sed 's/^/   /'

say "##### OVS arm: ndt up ovs4 (real helper path) #####"
( cd $R && timeout 420 $NDT up ovs4 ) > $P/smoke_up_ovs.log 2>&1; rc=$?; say "ndt up ovs4 rc=$rc"; tail -4 $P/smoke_up_ovs.log | sed 's/^/   /'
if [[ $rc -ne 0 ]]; then down_timed ovs_abort; ( cd $R && $NDT release ); say "=== OVS ARM ABORTED ==="; exit 1; fi
say "--- #77: which testbed_topo.py is running (must be this repo's, not NTG's) ---"; topo_proc
ls $R/.test_run/logs/ 2>/dev/null | tr '\n' ' ' | sed 's/^/   logs: /'; echo
sleep 15
say "--- Q12 shape ---"; shape; graph
say "--- #82: power OFF/ON s4 via br-exists path ---"; post "$K/ndt/set_switches_power_state?ip=192.168.123.14&action=off"; sleep 3
curl -s -m 10 $K/ndt/get_switches_power_state | python3 -c 'import sys,json; print("   s4 after off:", json.load(sys.stdin).get("192.168.123.14"))'
sudo -n ovs-vsctl br-exists s4; echo "   br-exists s4 rc=$? (2=absent)"
post "$K/ndt/set_switches_power_state?ip=192.168.123.14&action=on"; sleep 3
curl -s -m 10 $K/ndt/get_switches_power_state | python3 -c 'import sys,json; print("   s4 after on:", json.load(sys.stdin).get("192.168.123.14"))'
sudo -n ovs-vsctl br-exists s4; echo "   br-exists s4 rc=$? (0=present)"
say "--- #1: group 801 install / delete(install-shaped) / re-install / delete(min) ---"
B801='{"dpid":1,"type":"ALL","group_id":801,"buckets":[{"actions":[{"type":"OUTPUT","port":1}]},{"actions":[{"type":"OUTPUT","port":2}]}]}'
post $K/ndt/install_group_entry "$B801"; groups
post $K/ndt/delete_group_entry "$B801"; sleep 1; groups
post $K/ndt/install_group_entry "$B801"; groups
post $K/ndt/delete_group_entry '{"dpid":1,"group_id":801}'; sleep 1; groups
say "--- #85 keys ---"; keys
say "--- #2: phantom probe (invalid port 999, then valid port 2) ---"
python3 $PROBE "pretest main kernel, invalid port" 1 10.0.0.241 999 915 25 2>&1 | grep -E 'RESULT|REQUEST-SHAPE|POLLED-SHAPE|HTTP' | sed 's/^/   /'
python3 $PROBE "pretest main kernel, valid port" 1 10.0.0.242 2 916 25 2>&1 | grep -E 'RESULT|REQUEST-SHAPE|POLLED-SHAPE|HTTP' | sed 's/^/   /'
say "--- ndt status --check ---"; ( cd $R && $NDT status --check ) > $P/smoke_check_ovs.log 2>&1; echo "   rc=$?"; grep -E '!!|mismatch|ok' $P/smoke_check_ovs.log | head -4 | sed 's/^/   /'
klog
say "--- #27/#76 down ---"; down_timed ovs; klog; cp $KLOG $P/smoke_kernel_ovs.log 2>/dev/null
topo_proc; ps -C ndtwin_kernel,ovs-vswitchd -o pid=,comm= | sed 's/^/   still: /'

say "##### P4 arm: ndt up p4 4 #####"
( cd $R && timeout 600 $NDT up p4 4 ) > $P/smoke_up_p4.log 2>&1; rc=$?; say "ndt up p4 4 rc=$rc"; tail -4 $P/smoke_up_p4.log | sed 's/^/   /'
if [[ $rc -ne 0 ]]; then down_timed p4_abort; ( cd $R && $NDT release ); say "=== P4 ARM ABORTED ==="; exit 1; fi
sleep 25
say "--- graph / Q12 / keys ---"; graph; shape; keys
say "--- P4 power OFF/ON s4 (ndtwin-p4-power path) ---"; post "$K/ndt/set_switches_power_state?ip=192.168.123.14&action=off"; sleep 4
curl -s -m 10 $K/ndt/get_switches_power_state | python3 -c 'import sys,json; print("   s4 after off:", json.load(sys.stdin).get("192.168.123.14"))'
echo "   bmv2 procs: $(ps -C simple_switch_grpc -o pid= | wc -l)"
post "$K/ndt/set_switches_power_state?ip=192.168.123.14&action=on"; sleep 6
curl -s -m 10 $K/ndt/get_switches_power_state | python3 -c 'import sys,json; print("   s4 after on:", json.load(sys.stdin).get("192.168.123.14"))'
echo "   bmv2 procs: $(ps -C simple_switch_grpc -o pid= | wc -l)"
say "--- #2 on P4 (control: polled-shape only) ---"
python3 $PROBE "pretest main kernel P4, valid port" 1 10.0.0.242 2 917 25 2>&1 | grep -E 'RESULT|REQUEST-SHAPE|POLLED-SHAPE|HTTP' | sed 's/^/   /'
say "--- ndt status --check ---"; ( cd $R && $NDT status --check ) > $P/smoke_check_p4.log 2>&1; echo "   rc=$?"
klog
say "--- down ---"; down_timed p4; klog; cp $KLOG $P/smoke_kernel_p4.log 2>/dev/null
ps -C ndtwin_kernel,simple_switch_grpc,ovs-vswitchd -o pid=,comm= | sed 's/^/   still: /'
( cd $R && $NDT release ) 2>&1 | sed 's/^/   /'
say "lab after: $(cd $R && $NDT status 2>/dev/null | grep -E 'claim|measuring' | tr -s ' ' | tr '\n' ';')"
say "=== SMOKE DONE ==="
