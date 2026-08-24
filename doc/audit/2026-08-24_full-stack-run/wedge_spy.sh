#!/usr/bin/env bash
# wedge_spy.sh -- catch one more failing boot and py-spy the Ryu process in the wedged state.
#
# [Co-developed with claude code -- Adam]
#
# The queue-cycle hypothesis (phase1_diagnosis_notes.md) predicts, at wedge time:
#   * the Switches app's event-loop greenlet parked in a blocking Queue.put
#     (send_event into IntelligentRyu's full 128-slot queue), and
#   * IntelligentRyu's event-loop greenlet inside _await_host_discovery / the
#     switch-wait loop of the enter handler.
# A stack dump that shows both is the confirmation; a dump that shows neither kills it.
# py-spy shows thread stacks; eventlet greenlets share one thread, so two dumps 10 s
# apart are taken -- a *parked* greenlet is off-stack, but a *blocking put* executed by
# the running greenlet chain shows up, and the gate's hub.sleep polling reappears
# across dumps if it is live.
set -uo pipefail
export NDT_OWNER=review-0824
DIR="$(cd "$(dirname "$0")" && pwd)"
RAW="$DIR/raw"; OUT="$DIR/wedge_spy.txt"
RYU=http://localhost:8080
PYSPY=/home/adam/miniconda3/bin/py-spy
say() { printf '%s\n' "$*" | tee -a "$OUT"; }

links_now() { curl -sf --max-time 4 "$RYU/v1.0/topology/links" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "?"; }

say ""
say "# wedge spy -- $(date +%H:%M:%S)"
for attempt in 1 2 3 4; do
    ndt down >/dev/null 2>&1; sleep 3
    say "## attempt $attempt: booting"
    setsid ndt up ovs > "$RAW/spy${attempt}_up.out" 2>&1 &
    fail=1
    for t in $(seq 10 5 120); do
        sleep 5
        n=$(links_now)
        if [ "$n" != "?" ] && [ "$n" -ge 30 ] 2>/dev/null; then
            say "   t+${t}s links=$n -> HEALTHY, next attempt"
            fail=0; break
        fi
    done
    if [ "$fail" = 0 ]; then sleep 45; continue; fi

    RYULOG=/home/adam/Desktop/NDTwin-Kernel/.test_run/logs/ryu.log
    RYU_PID=$(grep -m1 -oE '^\([0-9]+\) wsgi starting up' "$RYULOG" 2>/dev/null | grep -oE '[0-9]+' | head -1)
    [ -z "${RYU_PID:-}" ] && RYU_PID=$(pgrep -f 'ryu-manage[r]' | head -1)
    say "   WEDGE CAUGHT (links=$(links_now) at t+120), ryu pid=${RYU_PID:-unknown}"
    if [ -n "${RYU_PID:-}" ]; then
        sudo -n mnexec -a 1 "$PYSPY" dump --pid "$RYU_PID" --nonblocking > "$RAW/spy${attempt}_dump1.txt" 2>&1
        sleep 10
        sudo -n mnexec -a 1 "$PYSPY" dump --pid "$RYU_PID" --nonblocking > "$RAW/spy${attempt}_dump2.txt" 2>&1
        say "   dumps -> raw/spy${attempt}_dump{1,2}.txt"
        grep -m1 -A6 'Thread' "$RAW/spy${attempt}_dump1.txt" | sed 's/^/   DUMP1: /' | head -8 | tee -a "$OUT" >/dev/null
    fi
    cp -f /home/adam/Desktop/NDTwin-Kernel/.test_run/logs/ryu.log "$RAW/spy${attempt}_ryu.log" 2>/dev/null || true
    break
done
ndt down >/dev/null 2>&1
say "done -> $OUT"
