#!/bin/bash
# Bring OVS up, ask Ryu what it knows about hosts, tear down.
# [Co-developed with claude code -- Adam]
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
NDT="$REPO/tools/test_workflow/ndt"
SCRATCH="$(dirname "$0")"
export NDT_OWNER=manual-verify-0821
export TERM="${TERM:-dumb}"

"$NDT" claim 15 "asking Ryu what it knows about hosts" >/dev/null || exit 1
"$NDT" up ovs 2>&1 | tail -4
echo
echo "================ Ryu, right after bring-up ================"
"$REPO/p4_proxy/venv/bin/python" "$SCRATCH/probe_ryu_hosts.py"

echo
echo "(waiting 60s past the kernel's converging window, then asking again)"
sleep 60
echo "================ Ryu, 60s later ================"
"$REPO/p4_proxy/venv/bin/python" "$SCRATCH/probe_ryu_hosts.py"

echo
echo "================ after generating host traffic ================"
h1="$(ps -eo pid=,args= | awk '$0 ~ /mininet:h1$/ {print $1; exit}')"
if [[ -n "$h1" ]]; then
    echo "pinging 10.0.0.2 and 10.0.0.64 from h1 to give Ryu something to learn from"
    sudo -n mnexec -a "$h1" ping -c 3 -W 2 -q 10.0.0.2  2>&1 | tail -2
    sudo -n mnexec -a "$h1" ping -c 3 -W 2 -q 10.0.0.64 2>&1 | tail -2
    sleep 10
    "$REPO/p4_proxy/venv/bin/python" "$SCRATCH/probe_ryu_hosts.py"
else
    echo "no h1 pid found"
fi

echo
"$NDT" down 2>&1 | tail -3
"$NDT" release
