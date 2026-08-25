#!/usr/bin/env bash
# wedge_watch.sh -- catch the boot ring live and dump its greenlets before teardown.
#
# [Co-developed with claude code -- Adam]
#
# The ring reproduced on quiet_p1 of the host-curve run (2 Switch-entered / 10 state-change,
# 109-byte empty links, 411s, hosts endpoint dead). That is the first time it has appeared since
# the machine rebooted, and 7f7de4a's USR2 dump has still never run against one in THIS session.
#
# host_curve.sh tears down at the start of each next iteration, so the window is short and the
# summary line arrives too late to react to. This watches independently and fires the moment the
# signature is unambiguous, without disturbing the run (one curl per 5s).
#
# Signature, all four required, so a mid-discovery boot cannot trip it:
#   ryu alive  AND  older than 100s  AND  links body empty  AND  switches non-empty
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; RAW="$DIR/raw"; mkdir -p "$RAW"
DUMP=/tmp/ndtwin_ryu_greenlets.txt
n=0
while :; do
    pid=$(pgrep -f "ryu-manager --observe-links" 2>/dev/null | head -1)
    if [[ -n "$pid" ]]; then
        age=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
        if [[ "$age" =~ ^[0-9]+$ ]] && (( age > 100 )); then
            # BUG FIXED MID-RUN: this required `switches` to be NON-empty as a liveness sanity
            # check -- and on a wedge the topology REST app is exactly what is stuck, so switches
            # returns "[]" as well. The sanity check excluded the only case being hunted. Two
            # wedges (quiet_p1, quiet_p2) went by undumped because of it.
            # (Also: the "109 bytes" in ryu.log is "[]" plus HTTP headers, not a 109-byte body --
            # the access log counts the whole response. Live body and log agree.)
            # SECOND fix. v1 required `switches` non-empty as a liveness check -- but on a wedge
            # switches is empty too, so the check excluded the only case being hunted. v2 then
            # required links == "[]" exactly -- but during the wedge the REST endpoints STOP
            # ANSWERING altogether (which is why the host curve records -1, not 0). So the empty
            # body and the dead endpoint are BOTH the signature, and v2 could only see the first.
            #
            # Three attempts at one predicate, each excluding the case it was written to catch.
            # The pattern: I kept encoding "what a healthy boot looks like, negated" instead of
            # "what the failure actually emits". Wedged Ryu: process ALIVE, endpoints silent.
            lnk=$(curl -s --max-time 3 -o /dev/null -w '%{http_code}'                   http://localhost:8080/v1.0/topology/links 2>/dev/null)
            body=$(curl -s --max-time 3 http://localhost:8080/v1.0/topology/links 2>/dev/null | tr -d ' \n')
            if [[ "$lnk" != "200" || "$body" == "[]" ]]; then
                n=$((n+1))
                ts=$(date +%H%M%S)
                echo "[$ts] WEDGE DETECTED pid=$pid age=${age}s links_http=${lnk} body=${body:-<none>} -- dumping"
                : > "$DUMP"; kill -USR2 "$pid" 2>/dev/null; sleep 4
                if [[ -s "$DUMP" ]]; then
                    cp -f "$DUMP" "$RAW/wedge_${ts}_greenlets.txt"
                    echo "[$ts] dump: $(wc -l < "$RAW/wedge_${ts}_greenlets.txt") lines, $(grep -c '_events_sem.acquire' "$RAW/wedge_${ts}_greenlets.txt") in _events_sem.acquire"
                else
                    echo "[$ts] dump EMPTY -- SIGUSR2 handler missing?"
                fi
                curl -sf --max-time 3 http://localhost:8080/v1.0/topology/links > "$RAW/wedge_${ts}_links.json" 2>/dev/null
                # one dump per ryu instance: wait for this pid to go away before arming again
                while kill -0 "$pid" 2>/dev/null; do sleep 5; done
                echo "[$ts] ryu $pid gone; re-armed"
            fi
        fi
    fi
    sleep 5
done
