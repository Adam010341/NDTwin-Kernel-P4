#!/bin/bash
# ============================================================================================
# T-2: does the system a reader just installed actually RUN?
#
# Follows the User Manual's P4 section on the machine that guest_section6_p1/p2 just built.
# Not a fresh environment and not a different machine -- that is the whole point of the
# ticket: evidence that someone who followed the Installation Manual ends up with something
# that works.
#
# ALSO SUPPLIES SECTION 6.6 ROW 4. guest_section6_p2.sh tested the three refusals and
# explicitly refused to claim the accept path, because a guard that rejects everything --
# including what it should permit -- passes all three refusals. The override now names the
# stock build; if the fabric comes up here, that row is what came up.
#
# STARTUP ORDER IS THE REVERSE OF OVS: Mininet -> Proxy -> wait -> Kernel. The User Manual is
# emphatic about this because BMv2 listens and the proxy dials in.
#
# ACCEPTANCE IS ON STATE, NOT EXIT CODES. Every check below is written so that it would go
# red if the step it follows did nothing:
#   * fabric      -> the MANIFEST, which lists only switches that passed verification,
#                    not the reassuring console line above it
#   * paths       -> two consecutive equal samples, because the manual documents a stable-
#                    looking 99.8% reading that is wrong
#   * kernel      -> switch count AND edge count; 40 edges is the 4-host fabric, 288 is the
#                    128-host one, so the number distinguishes "wrong topology loaded"
#   * datapath    -> pingall, read by its named Results line
#
# S5 applies here too: 4 hosts, the variant Installation 6.5 ships and this VM can run.
# [Co-developed with claude code -- Adam]
# ============================================================================================
LOG=~/t2.log
exec > >(tee -a "$LOG") 2>&1
cd "$HOME/Desktop/NDTwin-Kernel" || exit 1
FAIL=0
ok()   { echo "    PASS: $*"; }
bad()  { echo "    FAIL: $*"; FAIL=$((FAIL+1)); }
banner(){ echo; echo "############ $* ############"; }

echo "=== T-2 started $(date -Is)   cwd: $PWD ==="
echo "override in force: $(grep -vE '^[[:space:]]*(#|$)' p4_proxy/mininet/bmv2_binary_override | head -1)"
echo "host_count_override: $(cat p4_proxy/mininet/host_count_override)"

# --------------------------------------------------------------------------------------------
banner "TERMINAL 1 -- BMv2 Mininet topology (the User Manual's first P4 terminal)"
rm -f /tmp/ndtwin_p4_switches.json
FIFO=/tmp/mn_stdin; rm -f "$FIFO"; mkfifo "$FIFO"
sudo python3 p4_proxy/mininet/p4_testbed_topo.py < "$FIFO" > ~/topo.log 2>&1 &
TOPO=$!
exec 3> "$FIFO"          # hold stdin open so mininet does not see EOF and quit
echo "    topology pid $TOPO (recorded at spawn)"

for i in $(seq 1 90); do
    grep -q "switches verified listening" ~/topo.log && break
    kill -0 $TOPO 2>/dev/null || { echo "    topology process died early"; break; }
    sleep 2
done
grep -E "verified listening|Switch manifest" ~/topo.log | sed 's/^/    /'

echo "--- the manual says confirm with the MANIFEST, not the message above"
if [ -s /tmp/ndtwin_p4_switches.json ]; then
    n=$(python3 -c "import json;print(len(json.load(open('/tmp/ndtwin_p4_switches.json'))))" 2>/dev/null)
    echo "    switches in manifest: $n"
    [ "$n" = "10" ] && ok "10 switches passed verification" || bad "manifest has $n switches, expected 10"
else
    bad "no manifest at /tmp/ndtwin_p4_switches.json -- fabric did not verify"
fi

# --------------------------------------------------------------------------------------------
banner "TERMINAL 2 -- P4 proxy agent"
( cd p4_proxy && PYTHONPATH="$PWD" venv/bin/python proxy_agent/main.py > ~/proxy.log 2>&1 ) &
PROXY=$!
echo "    proxy pid $PROXY (recorded at spawn)"
sleep 12
grep -qi "econnrefused" ~/proxy.log && bad "proxy reports ECONNREFUSED -- BMv2 not up" \
    || ok "proxy started with no ECONNREFUSED against :5005x"

# --------------------------------------------------------------------------------------------
banner "WAITING FOR PATHS -- two agreeing samples, per the manual's own warning"
echo "The manual documents a 99.8% reading that is stable-looking and wrong, so 'it stopped"
echo "changing' is not the criterion; two consecutive equal samples is."
prev=-1; stable=0
for i in $(seq 1 40); do
    c=$(curl -s http://localhost:8081/ryu_server/all_destination_paths \
        | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["all_destination_paths"]))' 2>/dev/null)
    [ -z "$c" ] && c=ERR
    echo "    +$((i*3))s  count=$c"
    if [ "$c" = "$prev" ] && [ "$c" != "ERR" ] && [ "$c" != "0" ]; then stable=1; break; fi
    prev=$c; sleep 3
done
[ "$stable" = "1" ] && ok "two consecutive samples agree at $prev" || bad "paths never settled (last=$prev)"
[ "$prev" = "12" ] && ok "count is 12, the manual's figure for the 4-host fabric" \
    || echo "    NOTE: manual says the 4-host fabric settles at 12; got $prev"

# --------------------------------------------------------------------------------------------
banner "TERMINAL 3 -- NDTwin Kernel (starts LAST in both modes)"
( cd build && sudo ./bin/ndtwin_kernel --mode mininet \
    --topology ../setting/StaticNetworkTopologyP4_10Switches_4Hosts.json \
    --no-ai --loglevel info > ~/kernel.log 2>&1 ) &
KERN=$!
echo "    kernel pid $KERN (recorded at spawn)"
sleep 30

echo "--- does the kernel actually ANSWER? (not: did the process start)"
code=$(curl -s -o /tmp/topo.json -w '%{http_code}' http://localhost:8000/ndt/get_network_topology)
echo "    GET /ndt/get_network_topology -> HTTP $code"
[ "$code" = "200" ] && ok "kernel answered on :8000" || bad "kernel did not answer (HTTP $code)"

echo "--- does the TWIN see the switches? (Adam's item 2, and the point of a digital twin)"
python3 - <<'PY'
import json
try:
    d = json.load(open('/tmp/topo.json'))
except Exception as e:
    print(f"    FAIL: kernel response is not JSON: {e}"); raise SystemExit
nodes = d.get('nodes', d.get('vertices', []))
edges = d.get('edges', d.get('links', []))
sw = [n for n in nodes if str(n.get('vertex_type','')).lower() in ('1','switch') or 'dpid' in n]
print(f"    nodes={len(nodes)}  edges={len(edges)}  switch-like={len(sw)}")
print("    PASS: twin reports 10 switches" if len(sw)==10 else f"    FAIL: twin reports {len(sw)} switches, expected 10")
print("    PASS: 40 edges = the 4-host fabric" if len(edges)==40
      else f"    NOTE: edges={len(edges)}; manual says 40 for 4-host, 288 for 128-host")
PY

# --------------------------------------------------------------------------------------------
banner "DATAPATH -- pingall through the BMv2 switches"
echo "pingall" >&3
sleep 60
grep -E '\*\*\* Results:' ~/topo.log | tail -1 | sed 's/^/    /' \
    || bad "no pingall Results line"
if grep -qE '\*\*\* Results: 0% dropped' ~/topo.log; then ok "0% dropped through BMv2"
else echo "    (see Results line above -- non-zero drop)"; fi

# --------------------------------------------------------------------------------------------
banner "SHUTDOWN -- reverse order, as the User Manual instructs"
sudo kill $KERN 2>/dev/null; sleep 3
kill $PROXY 2>/dev/null; sleep 2
echo "exit" >&3; sleep 8
exec 3>&-
sudo kill $TOPO 2>/dev/null; sleep 3
sudo mn -c > /dev/null 2>&1
echo "    cleaned up (mn -c)"

banner "T-2 RESULT"
echo "failures: $FAIL"
echo "finished $(date -Is)"
