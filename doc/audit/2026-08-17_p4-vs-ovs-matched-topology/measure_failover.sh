#!/usr/bin/env bash
# measure_failover.sh <p4|ovs> <dst-ip> <fault-seconds> <out-log>
#
# One failover measurement, identical across cells:
#   * continuous ping from h1 at 5/s with -D timestamps (so the outage is measured, not inferred)
#   * the injected link is resolved at run time, because a previous run's reroute moves the path
#     and a hard-coded interface would inject into a link nothing is using -- which looks exactly
#     like "recovered instantly"
#   * the netem is re-read every 5 s while the fault is up, so a silent revert cannot be mistaken
#     for a fast recovery
#   * recovery is only credited if it happens while the netem is still present
#
# [Co-developed with claude code -- Adam]
set -uo pipefail

MODE="$1"; DST="$2"; FSECS="${3:-90}"; OUT="$4"

H1=$(ps -eo pid,args | awk '$NF ~ /^m[i]ninet:h1$/{print $1}')
[ -z "$H1" ] && { echo "FATAL: no h1"; exit 1; }

# --- resolve the on-path egress port of s1 toward DST ---
if [ "$MODE" = ovs ]; then
    PORT=$(sudo -n mnexec -a 1 ovs-ofctl dump-flows s1 2>/dev/null \
           | grep -oP "nw_dst=${DST//./\\.} actions=output:\K[0-9]+" | head -1)
else
    PORT=$(curl -s --max-time 5 http://localhost:8081/ryu_server/all_destination_paths \
           | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for p in d.get('all_destination_paths',[]):
    if p and p[0][0]=='10.0.0.1' and p[-1][0]=='$DST':
        print(p[1][1]); break
")
fi
[ -z "${PORT:-}" ] && { echo "FATAL: could not resolve on-path port toward $DST"; exit 1; }
IFACE="s1-eth${PORT}"

# --- pick the tc form: parent under htb where the topology shapes, root where it does not ---
if sudo -n tc qdisc show dev "$IFACE" 2>/dev/null | head -1 | grep -q htb; then
    CLS=$(sudo -n mnexec -a 1 tc class show dev "$IFACE" 2>/dev/null \
          | grep -oP 'class htb \K[0-9]+:[0-9]+' | head -1)
    [ -z "${CLS:-}" ] && { echo "FATAL: htb present but no class found on $IFACE"; exit 1; }
    ADD=(sudo -n tc qdisc add dev "$IFACE" parent "$CLS" netem loss 100%)
    DEL=(sudo -n tc qdisc del dev "$IFACE" parent "$CLS")
    FORM="parent $CLS"
else
    ADD=(sudo -n tc qdisc add dev "$IFACE" root netem loss 100%)
    DEL=(sudo -n tc qdisc del dev "$IFACE" root)
    FORM="root"
fi

echo "mode=$MODE dst=$DST iface=$IFACE form=$FORM fault=${FSECS}s"

sudo -n mnexec -a "$H1" ping -i 0.2 -D "$DST" > "$OUT" 2>&1 &
PP=$!
sleep 8
base=$(grep -c 'bytes from' "$OUT")
[ "$base" -lt 10 ] && { echo "FATAL: no baseline traffic ($base replies)"; kill $PP; exit 1; }

"${ADD[@]}" || { echo "FATAL: injection failed"; kill $PP; exit 1; }

missing=0
for ((i=1; i*5<=FSECS; i++)); do
    sleep 5
    sudo -n tc qdisc show dev "$IFACE" 2>/dev/null | grep -q netem || missing=$((missing+1))
done
"${DEL[@]}"
sleep 12
kill $PP 2>/dev/null; sleep 1

if [ "$missing" -gt 0 ]; then
    echo "INVALID: netem absent at $missing of the checks -- discard this run"
    exit 1
fi
echo "netem verified present at every check"
