#!/usr/bin/env bash
# Live smoke of the wave-2 merged kernel (wt-integrate build) on ovs4, run while the gates hold the
# build lock. Covers, in order: Q12 power-state shape; #82 OVS power off/on (br-exists path);
# #1 delete_group_entry AFTER arm (install-shaped delete body must now really delete, id reusable);
# meter twin; #85 report keys; C-4 (#2) re-run on this binary; #27/#76 shutdown time.
set -uo pipefail
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad
W=$S/wave2-work; CO=$S/wt-integrate; MAIN=/home/adam/Desktop/NDTwin-Kernel; NDT=$CO/tools/test_workflow/ndt
K=http://localhost:8000; RYU=http://localhost:8080; PROBE=$CO/doc/audit/2026-08-31_live-acceptance-batch/probe.py
export NDT_OWNER=auditor
say() { echo "[$(date +%T)] $*"; }
post() { curl -s -o /tmp/smoke_body.$$ -w '%{http_code}' -X POST -H 'Content-Type: application/json' "$1" ${2:+-d "$2"}; echo "  $(cat /tmp/smoke_body.$$ | cut -c1-240)"; }
get()  { curl -s -o /tmp/smoke_body.$$ -w '%{http_code}' "$1"; echo "  $(cat /tmp/smoke_body.$$ | cut -c1-240)"; }
groups() { curl -s $RYU/stats/groupdesc/1 | python3 -c 'import sys,json; d=json.load(sys.stdin); print("   ryu groupdesc dpid1:", sorted(g["group_id"] for v in d.values() for g in v))' 2>&1; }
meters() { curl -s $RYU/stats/meterconfig/1 | python3 -c 'import sys,json; d=json.load(sys.stdin); print("   ryu meterconfig dpid1:", sorted(m["meter_id"] for v in d.values() for m in v))' 2>&1; }
say "=== smoke wave2 :: kernel $(sha256sum $CO/build/bin/ndtwin_kernel | cut -c1-16) tree $(git -C $CO rev-parse --short HEAD) ==="
( cd $MAIN && $MAIN/tools/test_workflow/ndt claim 30 "wave-2 merged-kernel smoke on ovs4 (auditor, from wt-integrate)" ) 2>&1 | sed 's/^/   /'
( cd $CO && $NDT claim 30 "wave-2 smoke (auditor)" ) 2>&1 | sed 's/^/   /'
say "ndt up ovs4 ..."; ( cd $CO && timeout 420 $NDT up ovs4 ) > $W/smoke_up.log 2>&1; rc=$?; say "ndt up rc=$rc"; tail -3 $W/smoke_up.log | sed 's/^/   /'
if [[ $rc -ne 0 ]]; then ( cd $CO && timeout 300 $NDT down ) > $W/smoke_down.log 2>&1; ( cd $CO && $NDT release ); ( cd $MAIN && $MAIN/tools/test_workflow/ndt release ); say "=== SMOKE ABORTED (bring-up failed) ==="; exit 1; fi
sleep 15
say "--- Q12: get_switches_power_state shape ---"
curl -s $K/ndt/get_switches_power_state | python3 -c '
import sys,json; d=json.load(sys.stdin); ok=sum(1 for v in d.values() if isinstance(v,dict) and "admin_state" in v and "reachable" in v)
print("   switches=%d object-shaped=%d sample=%s"%(len(d),ok,json.dumps(dict(list(d.items())[:2]))))'
say "--- #82/Q12: power OFF s4 (192.168.123.14) ---"; post "$K/ndt/set_switches_power_state?ip=192.168.123.14&action=off"; sleep 3
curl -s $K/ndt/get_switches_power_state | python3 -c 'import sys,json; print("   s4 after off:", json.load(sys.stdin).get("192.168.123.14"))'
sudo -n ovs-vsctl br-exists s4; echo "   ovs-vsctl br-exists s4 rc=$? (2 = absent)"
say "--- #82/Q12: power ON s4 ---"; post "$K/ndt/set_switches_power_state?ip=192.168.123.14&action=on"; sleep 3
curl -s $K/ndt/get_switches_power_state | python3 -c 'import sys,json; print("   s4 after on:", json.load(sys.stdin).get("192.168.123.14"))'
sudo -n ovs-vsctl br-exists s4; echo "   ovs-vsctl br-exists s4 rc=$? (0 = present)"
say "--- #1 AFTER: group 801 on dpid 1 ---"
B801='{"dpid":1,"type":"ALL","group_id":801,"buckets":[{"actions":[{"type":"OUTPUT","port":1}]},{"actions":[{"type":"OUTPUT","port":2}]}]}'
say "install (install shape)"; post $K/ndt/install_group_entry "$B801"; groups
say "delete sending the INSTALL-SHAPED body (the caller-reuse case that used to be a silent no-op)"; post $K/ndt/delete_group_entry "$B801"; sleep 1; groups
say "re-install the same id (409 here = id still leaked)"; post $K/ndt/install_group_entry "$B801"; groups
say "delete with the minimal body"; post $K/ndt/delete_group_entry '{"dpid":1,"group_id":801}'; sleep 1; groups
say "delete a group that is not there (pre-check 404 expected)"; post $K/ndt/delete_group_entry '{"dpid":1,"group_id":801}'
say "--- meter 802 twin ---"; post $K/ndt/install_meter_entry '{"dpid":1,"meter_id":802,"flags":"KBPS","bands":[{"type":"DROP","rate":1000}]}'; meters
post $K/ndt/delete_meter_entry '{"dpid":1,"meter_id":802}'; sleep 1; meters
say "--- #85: report keys are all addresses? ---"
curl -s $K/ndt/get_cpu_utilization | python3 -c '
import sys,json,re; d=json.load(sys.stdin); bad=[k for k in d if not re.match(r"^\d+\.\d+\.\d+\.\d+$",k)]; print("   cpu keys=%d non-ip=%s"%(len(d),bad))'
say "--- C-4 (#2) re-run on THIS binary ---"
python3 $PROBE "C-4 wave2 merged kernel, invalid port" 1 10.0.0.241 999 915 25 2>&1 | grep -E 'RESULT|REQUEST-SHAPE|POLLED-SHAPE|HTTP' | sed 's/^/   /'
python3 $PROBE "C-4 wave2 merged kernel, valid port" 1 10.0.0.242 2 916 25 2>&1 | grep -E 'RESULT|REQUEST-SHAPE|POLLED-SHAPE|HTTP' | sed 's/^/   /'
KLOG=$CO/.test_run/logs/kernel.log
say "--- kernel.log ---"; echo "   withholding=$(grep -c withholding $KLOG) not-evidence=$(grep -c 'not evidence' $KLOG) still_present=$(grep -c still_present $KLOG) did-not-take-effect=$(grep -c 'did not take effect' $KLOG) no-management-address=$(grep -c 'carries no management address' $KLOG) outlast=$(grep -ciE 'still (running|stopping)|outlast' $KLOG) lines=$(wc -l < $KLOG)"
grep -nE 'did not take effect|could not be read back|still_present' $KLOG | tail -5 | cut -c1-200 | sed 's/^/   /'
say "--- #27/#76: ndt down timed ---"; t0=$(date +%s.%N); ( cd $CO && timeout 300 $NDT down ) > $W/smoke_down.log 2>&1; rc=$?; t1=$(date +%s.%N)
say "ndt down rc=$rc wall=$(python3 -c "print(round($t1-$t0,2))") s"; tail -3 $W/smoke_down.log | sed 's/^/   /'
grep -nE 'stop|shutdown|Exiting|took' $KLOG | tail -6 | cut -c1-160 | sed 's/^/   /'
cp $KLOG $W/smoke_wave2_kernel.log 2>/dev/null
( cd $CO && $NDT release ) 2>&1 | sed 's/^/   /'; ( cd $MAIN && $MAIN/tools/test_workflow/ndt release ) 2>&1 | sed 's/^/   /'
say "lab after: $(cd $MAIN && $MAIN/tools/test_workflow/ndt status 2>/dev/null | grep -E 'claim|measuring|:8000' | tr -s ' ' | tr '\n' ';')"
say "=== SMOKE DONE ==="
