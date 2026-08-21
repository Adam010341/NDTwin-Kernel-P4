#!/usr/bin/env bash
# beacon_sweep.sh [idle_window_s] [reps] -- KNOWN-ISSUES D-2: sweep the P4 LLDP beacon interval.
#
# [Co-developed with claude code -- Adam]
#
# One cell per beacon interval (5 / 3 / 2 / 1 s), on the full 128-host P4 stack. Per cell:
#
#   1. knob proof   -- NDTWIN_P4_BEACON_S announces itself in the proxy log; set explicitly in
#                      EVERY cell including 5 s, so the plumbing is proven in the control too.
#   2. idle window  -- zero injections; every "[TopologyManager] link down" line is a false
#                      positive. D-2's own text: THIS is the decision number, not detection
#                      time, because detection necessarily improves while every false positive
#                      costs a global path recompute.
#   3. detection    -- ${REPS} real failures via measure_failover.sh (same resolution, netem
#                      assertions and ping-measured outage as every prior failover round, so
#                      the outage numbers compose with 2026-08-19's). Detection time is polled
#                      off the proxy log at 0.2 s (+-0.3 s -- fine against multi-second scales).
#
# Predictions, written down before running (LINK_BEACON_TIMEOUT_S = 3x beacon; detection lands
# between the timeout and timeout + one watchdog interval = 4x):
#     beacon 5: detect 15-20 s (round 4 measured 10.7-14 s -- BELOW this window; that gap is
#               unexplained and D-2 flags it, so watch whether it reappears)
#     beacon 3: detect 9-12 s | beacon 2: 6-8 s | beacon 1: 3-4 s
#     false positives: the risk case is beacon 1 (timeout 3 s) on a shared-CPU -O0 bmv2 fabric.
set -uo pipefail

export NDT_OWNER="${NDT_OWNER:-fable-0821}"
REPO=/home/adam/Desktop/NDTwin-Kernel
PLOG="$REPO/.test_run/logs/p4_proxy.log"
DIR="$REPO/doc/audit/2026-08-21_p4-beacon-sweep"
OUT="$DIR/beacon_sweep.txt"
MEASURE="$REPO/doc/audit/2026-08-17_p4-vs-ovs-matched-topology/measure_failover.sh"
W="${1:-360}"
REPS="${2:-2}"
DST=10.0.0.33

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

: > "$OUT"
say "# P4 LLDP beacon interval sweep (KNOWN-ISSUES D-2), 128 hosts"
say "# date:   $(date -Is)"
say "# commit: $(cd "$REPO" && git rev-parse --short HEAD)"
say "# idle window ${W}s per cell, then ${REPS} real failures via measure_failover.sh"
say ""

for B in 5 3 2 1; do
    say "## beacon=${B}s"
    ndt down > /tmp/beacon_down.out 2>&1 || { say "   DOWN FAILED; aborting"; exit 1; }
    sleep 2
    if ! env NDTWIN_P4_BEACON_S=$B timeout 900 ndt up p4 128 > "/tmp/beacon_up_$B.out" 2>&1; then
        say "   UP FAILED (/tmp/beacon_up_$B.out)"
        tail -4 "/tmp/beacon_up_$B.out" | sed 's/^/     /' | tee -a "$OUT"
        continue
    fi

    if grep -q "NDTWIN: LLDP_BEACON_INTERVAL_S overridden to ${B}" "$PLOG" \
       || grep -q "NDTWIN: LLDP_BEACON_INTERVAL_S overridden to ${B}.0" "$PLOG"; then
        grep "NDTWIN: LLDP" "$PLOG" | head -1 | sed 's/^/   knob: /' | tee -a "$OUT"
    else
        say "   KNOB NOT ANNOUNCED in $PLOG -- this cell was NOT configured; skipping it"
        continue
    fi

    local_switches=$(pgrep -c -f simple_switch_grpc || true)
    say "   fabric: ${local_switches} bmv2 switches"

    base_fp=$(grep -c "\[TopologyManager\] link down" "$PLOG")
    say "   idle window: ${W}s, zero injections ($(date -Is))"
    sleep "$W"
    n_fp=$(grep -c "\[TopologyManager\] link down" "$PLOG")
    say "   false link-down reports during window: $((n_fp - base_fp))"
    if (( n_fp - base_fp > 0 )); then
        grep "\[TopologyManager\] link down" "$PLOG" | tail -n $((n_fp - base_fp)) \
          | sed 's/^/     FP: /' | tee -a "$OUT"
    fi

    for rep in $(seq 1 "$REPS"); do
        pre=$(grep -c "\[TopologyManager\] link down" "$PLOG")
        bash "$MEASURE" p4 "$DST" 60 "/tmp/beacon_ping_${B}_${rep}.log" \
            > "/tmp/beacon_meas_${B}_${rep}.out" 2>&1 &
        mpid=$!

        # measure_failover injects ~10 s in (resolve + ping baseline). Anchor t_inject on the
        # netem actually appearing, not on when the child was forked -- the same "assert the
        # injection, then time from it" rule every round here has ended up needing.
        #
        # Poll `tc qdisc show dev <iface>`, never the bare no-dev form: sudoers only allows
        # specific tc invocations, the bare form is not one of them, and `sudo -n` failing
        # with stderr dropped reads exactly like "no netem anywhere". That misread burned rep
        # 1 of the first run as INVALID while measure_failover itself was printing "netem
        # verified present at every check". The iface comes from measure_failover's own
        # first output line, so this polls the same device the same sudoers-approved way.
        t_inject=""
        iface=""
        deadline=$(( $(date +%s) + 60 ))
        while (( $(date +%s) < deadline )); do
            if [[ -z "$iface" ]]; then
                iface=$(grep -oP 'iface=\K\S+' "/tmp/beacon_meas_${B}_${rep}.out" 2>/dev/null | head -1)
            fi
            if [[ -n "$iface" ]] && sudo -n tc qdisc show dev "$iface" 2>/dev/null | grep -q netem; then
                t_inject=$(date +%s.%N); break
            fi
            kill -0 "$mpid" 2>/dev/null || break
            sleep 0.1
        done
        if [[ -z "$t_inject" ]]; then
            say "   rep $rep  INVALID: netem never appeared (measure_failover output below)"
            wait "$mpid"; sed 's/^/     /' "/tmp/beacon_meas_${B}_${rep}.out" | tee -a "$OUT"
            continue
        fi

        det=""
        deadline=$(( $(date +%s) + 120 ))
        while (( $(date +%s) < deadline )); do
            if (( $(grep -c "\[TopologyManager\] link down" "$PLOG") > pre )); then
                det=$(python3 -c "import time; print(f'{time.time()-$t_inject:.1f}')"); break
            fi
            sleep 0.2
        done
        wait "$mpid"

        # Outage from the ping log's own -D timestamps: the longest gap between consecutive
        # replies. Measured, not inferred, exactly as the 2026-08-19 round computed it.
        outage=$(python3 - "/tmp/beacon_ping_${B}_${rep}.log" <<'PY'
import re, sys
ts = [float(m.group(1)) for line in open(sys.argv[1], errors="replace")
      if (m := re.match(r"\[([\d.]+)\].*bytes from", line))]
print(f"{max((b - a for a, b in zip(ts, ts[1:])), default=0.0):.2f}" if len(ts) > 1 else "n/a")
PY
)
        say "   rep $rep  detection=${det:-NONE within 120s}s (+-0.3)  outage=${outage}s (max ping gap)"
        grep -E "mode=|FATAL|INVALID|netem verified" "/tmp/beacon_meas_${B}_${rep}.out" \
          | sed 's/^/     /' | tee -a "$OUT"
        sleep 30
    done
    say ""
done

ndt down >/dev/null 2>&1
say "sweep complete -> $OUT"
