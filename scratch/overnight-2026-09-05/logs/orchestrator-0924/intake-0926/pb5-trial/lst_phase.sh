#!/usr/bin/env bash
# pb5 trial phase 4: LiveSwitchTest (+ an ad-hoc error-path probe) under BOTH interpreters, on one
# fabric this trial claims. [Co-developed with claude code -- Adam]
#
# LiveSwitchTest skips while anything listens on :8081 (it would share election id (0,1) with the
# proxy), and no ndt verb brings bmv2 up without the proxy. So: `ndt up p4 4` with the proxy on
# venv-cand (which also gives an unhurried /proc look at the candidate proxy), then the proxy --
# and only the proxy -- is stopped the way stack.sh's stop_one stops it: the supervisor pid from
# .test_run/pids/p4_proxy.pid, identity checked in /proc first, TERM to its process group. No
# pkill/pgrep. Then the test and the probe run main-venv first (control), venv-cand second, and
# `ndt down` tears everything down. The claim is KEPT at the end (released after the restore check).
set -uo pipefail
N=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/pb5-trial
REPO=/home/adam/Desktop/NDTwin-Kernel
CAND=$REPO/scratch/overnight-2026-09-05/wt-p4proxy-reqs-0925/scratch/venv-cand/bin/python
MAIN=$REPO/p4_proxy/venv/bin/python
export NDT_OWNER=pb5-trial-0926
unset PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION P4_PROXY_PY
NDT=$REPO/tools/test_workflow/ndt
O=$N/lst
mkdir -p "$O"
cd "$REPO" || exit 2
j() { echo "$(date -u +%FT%TZ) lst: $*" | tee -a "$N/JOURNAL.txt"; }

"$NDT" status > "$O/00_status_before.txt" 2>&1
grep -qE '^  claim +none' "$O/00_status_before.txt" || { j "REFUSED: claim is not none"; exit 2; }
grep -qE '^  measuring +nothing' "$O/00_status_before.txt" || { j "REFUSED: measuring is not nothing"; exit 2; }

"$NDT" claim 40 "pb5 trial: LiveSwitchTest main+cand; the proxy is stopped by pid on purpose" \
    > "$O/01_claim.txt" 2>&1 || { j "claim failed"; cat "$O/01_claim.txt"; exit 2; }
j "claimed 40 min"

echo lstcand > "$N/current_label"
j "ndt up p4 4 with P4_PROXY_PY=venv-cand"
env P4_PROXY_PY="$CAND" "$NDT" up p4 4 > "$O/10_up_cand.txt" 2>&1
UP=$?
j "ndt up rc=$UP"
if (( UP != 0 )); then
    tail -20 "$O/10_up_cand.txt"
    "$NDT" down > "$O/90_down.txt" 2>&1; j "ndt down rc=$? after failed up (claim kept)"
    exit 1
fi

# --- the candidate proxy, read from /proc (read-only) -----------------------------------------
SUP=$(cat .test_run/pids/p4_proxy.pid)
PYPID=""
for d in /proc/[0-9]*; do
    p=${d#/proc/}
    pg=$(awk '{print $5}' "$d/stat" 2>/dev/null) || continue
    [[ "$pg" == "$SUP" ]] || continue
    exe=$(readlink "$d/exe" 2>/dev/null) || continue
    [[ "$(basename "$exe")" == python* ]] && PYPID=$p
done
{
    echo "# $(date -u +%FT%TZ) candidate proxy, read-only /proc"
    echo "supervisor pid $SUP: $(tr '\0' ' ' < /proc/$SUP/cmdline)"
    echo "python pid $PYPID"
    echo "exe      $(readlink /proc/$PYPID/exe)"
    echo "cmdline  $(tr '\0' ' ' < /proc/$PYPID/cmdline)"
    echo "cwd      $(readlink /proc/$PYPID/cwd)"
    echo "--- maps lines naming _upb / protobuf / grpc cython:"
    grep -E '_upb|protobuf|cygrpc' /proc/$PYPID/maps
    echo "--- environ: PROTOCOL_BUFFERS* / P4_PROXY_PY / PYTHON*:"
    tr '\0' '\n' < /proc/$PYPID/environ | grep -E '^(PROTOCOL_BUFFERS|P4_PROXY_PY|PYTHON)' || true
    if tr '\0' '\n' < /proc/$PYPID/environ | grep -q '^PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION='; then
        echo "PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION: PRESENT"
    else
        echo "PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION: absent"
    fi
    echo "--- status"
    grep -E '^(VmRSS|VmHWM|Threads)' /proc/$PYPID/status
} > "$O/20_proc_cand_proxy.txt" 2>&1
cat "$O/20_proc_cand_proxy.txt"

# --- stop the proxy only, as stop_one does -------------------------------------------------------
SUPCMD=$(tr '\0' ' ' < /proc/$SUP/cmdline)
case "$SUPCMD" in
    *supervise.sh*p4_proxy*) ;;
    *) j "REFUSED to stop: supervisor $SUP cmdline is not supervise.sh/p4_proxy: $SUPCMD"
       "$NDT" down > "$O/90_down.txt" 2>&1; j "ndt down rc=$?"; exit 1 ;;
esac
SUPPG=$(awk '{print $5}' /proc/$SUP/stat)
if [[ "$SUPPG" != "$SUP" || -z "$PYPID" ]]; then
    j "REFUSED to stop: supervisor $SUP is not its own process group leader (pgrp $SUPPG) or no python pid"
    "$NDT" down > "$O/90_down.txt" 2>&1; j "ndt down rc=$?"; exit 1
fi
j "stopping the proxy: kill -TERM -- -$SUP (supervisor pgid; python pid $PYPID)"
kill -TERM -- "-$SUP"
for _ in $(seq 1 40); do
    [[ -e /proc/$SUP || -e /proc/$PYPID ]] || break
    sleep 0.5
done
if [[ -e /proc/$SUP || -e /proc/$PYPID ]]; then
    j "proxy did not exit on TERM -- NOT escalating; tearing down"
    "$NDT" down > "$O/90_down.txt" 2>&1; j "ndt down rc=$?"; exit 1
fi
cat .test_run/pids/p4_proxy.exit > "$O/21_proxy_exit.txt" 2>&1
(exec 3<>/dev/tcp/127.0.0.1/8081) 2>/dev/null && { j ":8081 still open -- aborting"; "$NDT" down > "$O/90_down.txt" 2>&1; exit 1; }
j "proxy gone, :8081 closed; bmv2 s1 :30051 $( (exec 3<>/dev/tcp/127.0.0.1/30051) 2>/dev/null && echo open || echo CLOSED)"

# --- the test and the probe, control first -----------------------------------------------------
for arm in main cand; do
    py=$MAIN; [[ $arm == cand ]] && py=$CAND
    j "LiveSwitchTest under $arm ($py)"
    env NDTWIN_LIVE_SWITCH_OPT_IN=1 PYTHONPATH=p4_proxy "$py" -B p4_proxy/tests/test_p4_client.py -v \
        > "$O/30_liveswitchtest_$arm.txt" 2>&1
    j "LiveSwitchTest $arm rc=$? : $(grep -E '^(OK|FAILED)' "$O/30_liveswitchtest_$arm.txt" | tail -1)"
    env PYTHONPATH=p4_proxy "$py" -B "$N/error_path_probe.py" > "$O/31_error_probe_$arm.txt" 2>&1
    j "error_path_probe $arm rc=$?"
done

"$NDT" down > "$O/90_down.txt" 2>&1
j "ndt down rc=$? (claim kept)"
"$NDT" status > "$O/91_status_after.txt" 2>&1
exit 0
