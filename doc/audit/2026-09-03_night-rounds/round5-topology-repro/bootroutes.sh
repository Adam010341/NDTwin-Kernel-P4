#!/usr/bin/env bash
# One bring-up/read/tear-down cycle. Reads the boot-time routing table of ALL TEN switches
# from the P4 proxy (P4Runtime read, a different process from the kernel that programmed them),
# plus the kernel's own path view. Prints one JSON blob per cycle.
# [Co-developed with claude code -- Adam]
set -u
cd /home/adam/Desktop/NDTwin-Kernel
N="$1"
echo "===== cycle $N : $(date -Is) ====="
setsid env NDT_OWNER=auditor tools/test_workflow/ndt up p4 4 > /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/up_$N.log 2>&1 &
for i in $(seq 1 60); do grep -q "up. ready" /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/up_$N.log 2>/dev/null && break; sleep 2; done
grep -E "paths=|ok  kernel:|up. ready" /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/up_$N.log | head -4
KPID=$(cat .test_run/pids/kernel.child.pid)
echo "kernel pid $KPID exe $(sha256sum /proc/$KPID/exe 2>/dev/null | cut -c1-16)"
sleep 10
python3 - "$N" <<'PY'
import json, sys, urllib.request
n = sys.argv[1]
out = {"cycle": n, "boot_routes": {}, "paths": {}}
for d in range(1, 11):
    try:
        with urllib.request.urlopen("http://127.0.0.1:8081/stats/flow/%d" % d, timeout=25) as r:
            body = json.loads(r.read().decode())
        rows = []
        for _k, es in body.items():
            for e in es:
                rows.append("%s->%s" % (e.get("match", {}).get("nw_dst"), ",".join(e.get("actions", []))))
        out["boot_routes"]["s%d" % d] = sorted(rows)
    except Exception as ex:
        out["boot_routes"]["s%d" % d] = ["_ERR " + repr(ex)[:60]]
for a in range(1, 5):
    for b in range(1, 5):
        if a == b: continue
        try:
            with urllib.request.urlopen(
                "http://127.0.0.1:8000/ndt/get_path_switch_count?ip1=10.0.0.%d&ip2=10.0.0.%d" % (a, b),
                timeout=10) as r:
                out["paths"]["%d->%d" % (a, b)] = json.loads(r.read().decode()).get("data")
        except Exception as ex:
            out["paths"]["%d->%d" % (a, b)] = "_ERR"
print("JSON " + json.dumps(out, sort_keys=True))
print("s1 boot routes: %s" % out["boot_routes"]["s1"])
PY
setsid env NDT_OWNER=auditor tools/test_workflow/ndt down > /tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1e91440a-4a23-4430-8ebf-59aa2d5f7260/scratchpad/down_$N.log 2>&1
for i in $(seq 1 40); do
  [[ "$(ps -eo comm= | grep -c '^simple_switch')" == "0" ]] && [[ "$(ss -ltnH 'sport = :8000' | wc -l)" == "0" ]] && break
  sleep 2
done
sleep 4
echo "torn down: bmv2=$(ps -eo comm= | grep -c '^simple_switch') kernels=$(ps -eo comm= | grep -c '^ndtwin_kernel') tcp8000=$(ss -ltnH 'sport = :8000' | wc -l) udp6343=$(ss -lunH 'sport = :6343' | wc -l)  free=$(free -m | awk '/^Mem/{print $7}')MB"
