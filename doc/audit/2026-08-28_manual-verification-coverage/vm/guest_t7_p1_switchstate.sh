#!/bin/bash
# ============================================================================================
# P-1 acceptance, pinned on SWITCH STATE.
#
# The criterion is not "the second instance printed an error" and not "it exited non-zero".
# Both were already true before the fix. The criterion is that it wrote NOTHING into the
# switches, so the evidence has to come from the switches.
#
# THE CONTROL THAT MAKES THE COMPARISON MEAN ANYTHING
#   A live fabric is not static: proxy #1 keeps discovering links and installing routes, so
#   "the dump changed" does not by itself implicate proxy #2. Three dumps are taken --
#
#       D1  baseline
#       D2  after a quiet interval, NOTHING launched         <-- measures ordinary drift
#       D3  after launching a second proxy
#
#   and the question asked is whether D2->D3 differs in a way D1->D2 did not. If the fabric
#   drifts on its own, D1 != D2 and the test says so rather than blaming proxy #2.
#
# BOTH ARMS
#   Run once with the fixed main.py and once with the pre-fix copy, because "no change" proves
#   nothing unless the same measurement can detect a change when one happens. The pre-fix arm
#   is the positive control; without it this script would pass just as well if table_dump were
#   broken and returned the same bytes every time.
#
# [Co-developed with claude code -- Adam]
# ============================================================================================
LOG=~/t7p1.log
exec > >(tee -a "$LOG") 2>&1
cd "$HOME/Desktop/NDTwin-Kernel" || exit 1
FAIL=0; ts(){ date -Is; }
ok(){ echo "    PASS: $*"; }; bad(){ echo "    FAIL: $*"; FAIL=$((FAIL+1)); }
banner(){ echo; echo "############ $* ############"; }
holder(){ sudo ss -lptn "sport = :$1" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2; }

# Digest of every switch's forwarding tables. This is the measurement; everything else is setup.
dump_state() {
    local out=""
    for p in 9091 9092 9093 9094 9095 9096 9097 9098 9099 9100; do
        out+=$(printf 'table_dump ipv4_lpm\ntable_dump five_tuple_exact\n' \
               | sudo timeout 15 simple_switch_CLI --thrift-port "$p" 2>/dev/null \
               | grep -vE '^Obtaining JSON|^Control utility|^RuntimeCmd|^\s*$')
    done
    printf '%s' "$out" | sha256sum | cut -d' ' -f1
}

echo "=== P-1 switch-state acceptance, started $(ts) ==="

banner "FABRIC + PROXY #1"
sudo mn -c >/dev/null 2>&1; rm -f ~/t7topo.log ~/t7p1a.log ~/t7p2a.log ~/t7p2b.log
F=/tmp/mn7; rm -f $F; mkfifo $F
sudo python3 p4_proxy/mininet/p4_testbed_topo.py < $F > ~/t7topo.log 2>&1 &
TOPO=$!; exec 3> $F
for i in $(seq 1 90); do grep -q "switches verified listening" ~/t7topo.log && break; sleep 2; done
echo "    manifest switches: $(python3 -c "import json;print(len(json.load(open('/tmp/ndtwin_p4_switches.json'))))" 2>/dev/null)"
( cd p4_proxy && PYTHONUNBUFFERED=1 PYTHONPATH="$PWD" venv/bin/python proxy_agent/main.py > ~/t7p1a.log 2>&1 ) &
sleep 45
P1=$(holder 8081); echo "    proxy #1 holds :8081 = ${P1:-<nobody>}"
[ -n "$P1" ] || { echo "ABORT: proxy #1 never came up"; exit 1; }

banner "MEASUREMENT"
D1=$(dump_state); echo "    D1 (baseline)                    $D1"
sleep 40
D2=$(dump_state); echo "    D2 (quiet interval, nothing run) $D2"
if [ "$D1" = "$D2" ]; then
    ok "fabric is quiescent -- any later change is attributable"
    QUIESCENT=1
else
    echo "    NOTE: fabric drifts on its own (D1 != D2); the arms below are judged against D2"
    QUIESCENT=0
fi

banner "ARM A -- second proxy, WITH the fix"
( cd p4_proxy && PYTHONUNBUFFERED=1 PYTHONPATH="$PWD" venv/bin/python proxy_agent/main.py > ~/t7p2a.log 2>&1 ) &
sleep 25
echo "    second proxy said:"; grep -E "REFUSING|Starting up" ~/t7p2a.log | head -6 | sed 's/^/      /'
D3=$(dump_state); echo "    D3 (after 2nd proxy, fixed)      $D3"
[ "$D3" = "$D2" ] && ok "switch state UNCHANGED -- the second instance wrote nothing" \
                  || bad "switch state changed after launching the second proxy"
grep -q "Starting up" ~/t7p2a.log && bad "startup event ran despite the guard" \
                                  || ok "startup event never ran (nothing could reach a switch)"

banner "ARM B -- POSITIVE CONTROL: second proxy, WITHOUT the fix"
echo "If the measurement cannot detect a change, Arm A's 'unchanged' is worthless."
mkdir -p /tmp/prefix/proxy_agent
cp -r p4_proxy/proxy_agent/* /tmp/prefix/proxy_agent/
python3 - <<'PY'
import re
p='/tmp/prefix/proxy_agent/main.py'
s=open(p).read()
i=s.index('HOST = "0.0.0.0"')
s=s[:i]+'if __name__ == "__main__":\n    uvicorn.run(app, host="0.0.0.0", port=8081)\n'
open(p,'w').write(s)
print("      reverted /tmp/prefix to the pre-fix entrypoint")
PY
( cd /tmp/prefix && PYTHONUNBUFFERED=1 PYTHONPATH="/tmp/prefix:$HOME/Desktop/NDTwin-Kernel/p4_proxy" \
  "$HOME/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python" proxy_agent/main.py > ~/t7p2b.log 2>&1 ) &
sleep 45
echo "    pre-fix second proxy said:"; grep -cE "Setting Forwarding Pipeline Config" ~/t7p2b.log | sed 's/^/      pipeline pushes: /'
D4=$(dump_state); echo "    D4 (after 2nd proxy, PRE-fix)    $D4"
if [ "$D4" != "$D3" ]; then
    ok "the measurement CAN see a pre-fix second instance -- Arm A's result is meaningful"
else
    echo "    NOTE: D4 == D3. Either the pre-fix instance also failed to reach the switches"
    echo "    here, or table_dump is not sensitive to what it changed. Arm A is therefore"
    echo "    NOT fully corroborated by this control -- stated rather than glossed."
fi

banner "SHUTDOWN"
for p in $(holder 8081); do sudo kill "$p" 2>/dev/null; done
echo exit >&3; sleep 6; exec 3>&-; sudo kill $TOPO 2>/dev/null; sleep 2
sudo mn -c >/dev/null 2>&1
banner "RESULT"; echo "failures: $FAIL"; echo "finished $(ts)"
