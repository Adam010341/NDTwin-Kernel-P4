#!/usr/bin/env bash
# stopsess.sh <session id> <name> <driver log> <step log> : the watchdog's stop. TERM to every process of the session (ps -s), 20 s, then KILL
# to what is left; each pid is signalled by number, nothing by name. [Co-developed with claude code -- Adam]
sid="$1"; name="$2"; D="$3"; log="$4"
echo "$(date -Is) [$name] HUNG past its cap: stopping session $sid: $(ps -o pid=,cmd= -s "$sid" 2>/dev/null | cut -c1-120 | tr '\n' '|')" >> "$D"
echo "HUNG: stopped by the merged-head driver (session $sid)" >> "$log"
for p in $(ps -o pid= -s "$sid" 2>/dev/null); do kill -TERM "$p" 2>/dev/null; done
sleep 20
left=$(ps -o pid= -s "$sid" 2>/dev/null | tr -d ' ' | tr '\n' ' ')
[[ -n "$left" ]] && { for p in $left; do kill -KILL "$p" 2>/dev/null; done; sleep 3; }
echo "$(date -Is) [$name] session $sid left: $(ps -o pid= -s "$sid" 2>/dev/null | tr -d ' ' | tr '\n' ' ')" >> "$D"
