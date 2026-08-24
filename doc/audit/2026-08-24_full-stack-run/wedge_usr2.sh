#!/usr/bin/env bash
# wedge_usr2.sh -- round 3: catch a wedged boot, take TWO SIGUSR2 greenlet dumps (7f7de4a's
# instrument), grep the frame-level verdict, then leave the fabric alone to test the
# ~12-minute self-heal prediction from REPORT.md.
#
# [Co-developed with claude code -- Adam]
#
# Freshness discipline (this file's own history): a boot is only declared wedged if
#   * this attempt's ryu pid exists AND its ryu.log is fresh, and
#   * links stayed empty/unanswerable through t+120.
# Dump discipline: after each USR2, ASSERT the dump file appeared and is fresh before
# copying -- a signal that lands nowhere must not read as "dump taken".
set -uo pipefail
export NDT_OWNER=review-0824
DIR="$(cd "$(dirname "$0")" && pwd)"
RAW="$DIR/raw"; OUT="$DIR/wedge_usr2.txt"
RYU=http://localhost:8080
RYULOG=/home/adam/Desktop/NDTwin-Kernel/.test_run/logs/ryu.log
DUMP=/tmp/ndtwin_ryu_greenlets.txt
say() { printf '%s\n' "$*" | tee -a "$OUT"; }

links_n() { curl -sf --max-time 4 "$RYU/v1.0/topology/links" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "?"; }

take_dump() {  # $1 = label ; echoes dump filepath or FAILED
    local label="$1" before after f
    before=$(stat -c %Y "$DUMP" 2>/dev/null || echo 0)
    kill -USR2 "$RYU_PID" 2>/dev/null || sudo -n mnexec -a 1 kill -USR2 "$RYU_PID"
    sleep 3
    after=$(stat -c %Y "$DUMP" 2>/dev/null || echo 0)
    if [ "$after" -le "$before" ]; then echo "FAILED"; return 1; fi
    f="$RAW/usr2_${label}.txt"
    cp -f "$DUMP" "$f"
    echo "$f"
}

say ""
say "# wedge round 3 (SIGUSR2 + self-heal watch) -- $(date +%H:%M:%S)  commit $(git -C /home/adam/Desktop/NDTwin-Kernel rev-parse --short HEAD)"

for attempt in 1 2 3 4 5; do
    ndt down >/dev/null 2>&1; sleep 3
    say "## attempt $attempt: booting"
    rm -f "$DUMP"
    setsid ndt up ovs > "$RAW/u2_${attempt}_up.out" 2>&1 &
    sleep 25
    RYU_PID=$(grep -m1 -oE '^\([0-9]+\) wsgi starting up' "$RYULOG" 2>/dev/null | grep -oE '[0-9]+' | head -1)
    [ -z "${RYU_PID:-}" ] && RYU_PID=$(pgrep -f 'ryu-manage[r]' | head -1)
    log_age=$(( $(date +%s) - $(stat -c %Y "$RYULOG" 2>/dev/null || echo 0) ))
    if [ -z "${RYU_PID:-}" ] || [ "$log_age" -gt 120 ]; then
        say "   NOT A FRESH BOOT (pid='${RYU_PID:-}', log_age=${log_age}s) -- skipping attempt"
        continue
    fi
    fail=1
    for t in $(seq 30 5 120); do
        sleep 5
        n=$(links_n)
        if [ "$n" != "?" ] && [ "$n" -ge 30 ] 2>/dev/null; then
            say "   t+${t}s links=$n -> HEALTHY, next attempt"
            fail=0; break
        fi
    done
    [ "$fail" = 0 ] && { sleep 40; continue; }

    say "   WEDGE CAUGHT, ryu pid=$RYU_PID -- taking greenlet dumps"
    d1=$(take_dump "attempt${attempt}_d1") || true
    sleep 10
    d2=$(take_dump "attempt${attempt}_d2") || true
    say "   dump1: $d1"
    say "   dump2: $d2"
    if [ "$d1" != "FAILED" ] && [ -f "$d1" ]; then
        say "   VERDICT grep (greenlets parked in a queue put):"
        grep -B6 'queue.py' "$d1" | grep -E 'greenlet|Thread|def |in [a-z_]+$|queue.py' | head -12 | sed 's/^/     /' | tee -a "$OUT" >/dev/null
        nput=$(grep -c 'in put' "$d1" || true)
        say "   greenlets blocked in queue put: $nput"
    fi
    cp -f "$RYULOG" "$RAW/u2_${attempt}_ryu.log" 2>/dev/null || true

    say "## self-heal watch: leaving the wedged fabric alone until t+900s, polling links/30s"
    t0=$(date +%s)
    healed="no"
    while [ $(( $(date +%s) - t0 )) -lt 900 ]; do
        sleep 30
        n=$(links_n)
        el=$(( $(date +%s) - t0 ))
        say "   heal-watch t+${el}s links=$n"
        if [ "$n" != "?" ] && [ "$n" -ge 30 ] 2>/dev/null; then healed="at t+${el}s"; break; fi
    done
    say "   SELF-HEAL: $healed"
    if [ "$healed" != "no" ]; then
        say "   post-heal graph: $(curl -sf --max-time 5 http://localhost:8000/ndt/get_graph_data | python3 -c 'import json,sys; e=json.load(sys.stdin)["edges"]; print(len(e),"edges,",sum(1 for x in e if not x.get("is_up",True)),"down")' 2>/dev/null)"
        d3=$(take_dump "attempt${attempt}_postheal") || true
        say "   post-heal dump: $d3"
    fi
    break
done
ndt down >/dev/null 2>&1
say "done -> $OUT"
