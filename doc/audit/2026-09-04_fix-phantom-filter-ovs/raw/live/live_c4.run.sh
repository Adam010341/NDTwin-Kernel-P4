#!/usr/bin/env bash
# C-4 (#2) live A/B on ovs4, auditor's version of phantomovs's live_arm.sh. One arm per checkout:
# the checkout's own `ndt` runs the checkout's own build/bin/ndtwin_kernel (components.env:16 derives
# KERNEL_DIR from its own location), so no binary is copied and nothing is rebuilt.
#   BEFORE = main checkout  (a8ba99c2, built 09-03 00:46 -- predates the first wave too; the phantom
#            filter was not touched by any first-wave branch, so it is a fair control for THIS observable)
#   AFTER  = wt-phantomovs  (7b9b7ada, trunk@7de4ef2f + the #2 fix)
set -uo pipefail
S=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad
W=$S/wave2-work; MAIN=/home/adam/Desktop/NDTwin-Kernel; WT=$S/wt-phantomovs
PROBE=$WT/doc/audit/2026-08-31_live-acceptance-batch/probe.py
export NDT_OWNER=auditor
say() { echo "[$(date +%T)] $*"; }
arm() {
  local ARM=$1 CO=$2 NDT=$2/tools/test_workflow/ndt KLOG=$2/.test_run/logs/kernel.log
  say "=== arm $ARM :: checkout $CO :: kernel sha256 $(sha256sum $CO/build/bin/ndtwin_kernel | cut -c1-16) ==="
  ( cd $CO && $NDT claim 30 "C-4 live $ARM arm (auditor)" ) 2>&1 | sed 's/^/   /'
  say "ndt up ovs4 ..."; ( cd $CO && timeout 420 $NDT up ovs4 ) > $W/live_c4_${ARM}_up.log 2>&1; rc=$?
  say "ndt up rc=$rc"; tail -4 $W/live_c4_${ARM}_up.log | sed 's/^/   /'
  if [[ $rc -ne 0 ]]; then say "bring-up failed; tearing down"; ( cd $CO && timeout 300 $NDT down ) > $W/live_c4_${ARM}_down.log 2>&1; say "down rc=$?"; ( cd $CO && $NDT release ); return 1; fi
  sleep 20
  say "--- ARM: invalid port 999 ---"; python3 $PROBE "B-1 OVS arm ($ARM), invalid port" 1 10.0.0.241 999 915 25 2>&1 | sed 's/^/   /'; say "PROBE_RC=${PIPESTATUS[0]}"
  say "--- CONTROL A: valid port 2 ---"; python3 $PROBE "B-1 OVS control ($ARM), valid port" 1 10.0.0.242 2 916 25 2>&1 | sed 's/^/   /'; say "CONTROL_RC=${PIPESTATUS[0]}"
  say "--- Ryu's own view (prio 915/916) ---"
  python3 - <<'PY' 2>&1 | sed 's/^/   /'
import json, urllib.request
try:
    with urllib.request.urlopen("http://localhost:8080/stats/flow/1", timeout=10) as r: data=json.loads(r.read().decode())
    n=0
    for _d,flows in data.items():
        for f in flows:
            if f.get("priority") in (915,916): n+=1; print("ryu: prio=%s match=%s actions=%s"%(f.get("priority"),f.get("match"),f.get("actions")))
    print("(ryu rules with prio 915/916: %d)"%n)
except Exception as ex: print("ryu query failed: %s"%ex)
PY
  say "--- kernel.log ($KLOG) ---"
  if [[ -f $KLOG ]]; then grep -nE "withholding|not evidence|no longer withholding" $KLOG | tail -12 | sed 's/^/   /'; echo "   counts: withholding=$(grep -c withholding $KLOG) not-evidence=$(grep -c 'not evidence' $KLOG) lines=$(wc -l < $KLOG)"; cp $KLOG $W/live_c4_${ARM}_kernel.log; else say "kernel.log not found"; fi
  say "ndt down ..."; ( cd $CO && timeout 300 $NDT down ) > $W/live_c4_${ARM}_down.log 2>&1; say "ndt down rc=$?"; tail -3 $W/live_c4_${ARM}_down.log | sed 's/^/   /'
  ( cd $CO && $NDT release ) 2>&1 | sed 's/^/   /'
  say "=== arm $ARM done ==="
}
say "lab before: $(cd $MAIN && $MAIN/tools/test_workflow/ndt status 2>/dev/null | grep -E 'claim|measuring' | tr -s ' ' | tr '\n' ';')"
arm before $MAIN
sleep 5
# the main checkout's claim is the one other sessions look at (#79): hold it while the AFTER arm runs elsewhere
( cd $MAIN && $MAIN/tools/test_workflow/ndt claim 30 "C-4 live AFTER arm runs from wt-phantomovs (auditor)" ) 2>&1 | sed 's/^/   /'
arm after $WT
( cd $MAIN && $MAIN/tools/test_workflow/ndt release ) 2>&1 | sed 's/^/   /'
say "lab after: $(cd $MAIN && $MAIN/tools/test_workflow/ndt status 2>/dev/null | grep -E 'claim|measuring|:8000' | tr -s ' ' | tr '\n' ';')"
say "=== ALL ARMS DONE ==="
