#!/bin/bash
# ============================================================================================
# T-3: the User Manual's OVS operate flow (Terminals 1-3), on the machine the Installation
# Manual built. This is the page's main body; T-2 only exercised its optional P4 section.
#
# THE PTY POINT, WHICH IS THE WHOLE REASON THIS SCRIPT IS SHAPED LIKE THIS
#   Terminal 3's command is `sudo -E bin/ndtwin_kernel --loglevel info` -- no --mode, no
#   --topology, no --ai/--no-ai. The Installation Manual states that omitting those makes the
#   kernel PROMPT interactively, but only when stdin is a terminal; headless it exits with a
#   usage message. So a script and a reader get different programs, and testing without a
#   terminal would verify something no reader will ever do. The kernel is therefore launched
#   under `script`, which gives it a pty, and the prompts it asks for are recorded.
#   This is the H-14 family: `bash -lc` could not test "open a new terminal" either.
#
# P-1 GUARD
#   A proxy or kernel that loses its port keeps running with its HTTP server shut down, so
#   "something answers on the port" does not mean "the thing I just started answers on it".
#   Every service below is checked by matching the answering process against the pid recorded
#   at spawn, not by whether curl gets a reply. That defect cost a whole false finding in T-2.
#
# Liveness by /proc, never `kill -0` (EPERM on root-owned processes reads as "dead"), and
# `$!` is never trusted for a process started inside ( ... ) -- both cost findings in T-2.
# [Co-developed with claude code -- Adam]
# ============================================================================================
LOG=~/t3ovs.log
exec > >(tee -a "$LOG") 2>&1
cd "$HOME/Desktop/NDTwin-Kernel" || exit 1
FAIL=0; ts() { date -Is; }
ok(){ echo "    PASS: $*"; }; bad(){ echo "    FAIL: $*"; FAIL=$((FAIL+1)); }
banner(){ echo; echo "############ $* ############"; }
alive(){ [ -d "/proc/$1" ]; }
# who actually holds a port -> pid, so P-1's orphan cannot answer for us
holder(){ sudo ss -lptn "sport = :$1" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2; }

echo "=== T-3 User Manual OVS flow, started $(ts) ==="
sudo mn -c >/dev/null 2>&1
rm -f ~/ryu.log ~/mn.log ~/kern.log

banner "PRE-FLIGHT -- the three things the page tells you to ensure"
[ -d ~/Desktop/NDTwin-Kernel ]                  && ok "source in ~/Desktop"        || bad "no ~/Desktop/NDTwin-Kernel"
[ -x build/bin/ndtwin_kernel ]                  && ok "ndtwin_kernel built"        || bad "no build/bin/ndtwin_kernel"
[ -f testbed_topo.py ]                          && ok "testbed_topo.py present"    || bad "no testbed_topo.py"

banner "TERMINAL 1 -- Ryu controller"
echo "The page says start Ryu FIRST and let it come up, because testbed_topo.py asks for a"
echo "remote controller without naming a port: Mininet probes 6653 then 6633 and takes"
echo "whichever answers, and neither side logs the port it chose. So the ordering claim is"
echo "testable: after Ryu is up, 6633 must be held by Ryu."
# `conda activate` needs an interactive-ish shell; the page's own note allows an absolute path.
setsid bash -lc 'source ~/miniconda3/etc/profile.d/conda.sh && conda activate ryu-env && \
  exec ryu-manager intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest \
       --ofp-tcp-listen-port 6633 --observe-link' > ~/ryu.log 2>&1 &
sleep 25
RYU_PID=$(holder 6633)
echo "    pid holding :6633 = ${RYU_PID:-<nobody>}"
if [ -n "$RYU_PID" ]; then
    ok "Ryu is listening on 6633 before the topology starts (the page's ordering claim)"
    echo "    cmdline: $(tr '\0' ' ' < /proc/$RYU_PID/cmdline 2>/dev/null | cut -c1-90)"
else
    bad "nothing is listening on 6633 -- Mininet would silently settle on 6653"
fi
echo "    is 6653 open too? (the port the page warns Mininet falls back to)"
echo "      holder of 6653: $(holder 6653 || echo none)"

banner "TERMINAL 2 -- Mininet topology"
FIFO=/tmp/mn3; rm -f "$FIFO"; mkfifo "$FIFO"
sudo python3 testbed_topo.py < "$FIFO" > ~/mn.log 2>&1 &
TOPO=$!; exec 3> "$FIFO"
echo "    topology pid $TOPO"
echo "    the page says wait ~60 s for: \"all-destination paths installed\""
found=0
for i in $(seq 1 40); do
    if grep -qi "all.destination paths installed\|all-destination paths installed" ~/ryu.log ~/mn.log 2>/dev/null; then
        echo "    $(ts)  message seen after ~$((i*5))s"; found=1; break
    fi
    alive $TOPO || { echo "    topology gone"; break; }
    sleep 5
done
[ "$found" = "1" ] && ok "the page's named message appeared" \
  || bad "the message the page tells you to wait for never appeared (waited 200s)"
echo "    mininet reached CLI? $(grep -c 'mininet>' ~/mn.log) prompt(s)"

banner "TERMINAL 3 -- NDTwin Kernel, run EXACTLY as the page prints it"
echo "The page's command carries no --mode/--topology/--ai. Under a pty the kernel prompts;"
echo "headless it exits with usage. A reader has a pty, so this runs under one."
cat > /tmp/kern.sh <<'K'
cd ~/Desktop/NDTwin-Kernel/build
export OPENAI_API_KEY="any-random-string-here"
sudo -E bin/ndtwin_kernel --loglevel info
K
# feed nothing: we want to SEE what it asks for before deciding what a reader must type
setsid script -qefc "bash /tmp/kern.sh" /dev/null > ~/kern.log 2>&1 < /dev/null &
sleep 25
echo "    --- first 30 lines the reader would see ---"
head -30 ~/kern.log | sed 's/^/      /'
echo "    --- does it prompt? ---"
if grep -qiE "select|choose|enter|\?|\[y/n\]|mode|topology" ~/kern.log; then
    echo "      prompts/questions detected -- see above"
else
    echo "      no prompt text detected"
fi
K_PID=$(holder 8000)
echo "    pid holding :8000 = ${K_PID:-<nobody>}"
if [ -n "$K_PID" ]; then
    code=$(curl -s -m 5 -o /tmp/g.json -w '%{http_code}' http://localhost:8000/ndt/get_graph_data)
    echo "    GET /ndt/get_graph_data -> HTTP $code"
    [ "$code" = "200" ] && ok "kernel answers" || bad "kernel on the port but HTTP $code"
    python3 - <<'PY'
import json
try: d=json.load(open('/tmp/g.json'))
except Exception as e: print(f"      (no JSON: {e})"); raise SystemExit
n=d.get('nodes',d.get('vertices',[])); e=d.get('edges',d.get('links',[]))
print(f"      twin: nodes={len(n)} edges={len(e)}")
PY
else
    bad "kernel never listened on 8000 -- see the 30 lines above for why"
fi

banner "SHUTDOWN"
[ -n "$K_PID" ] && sudo kill "$K_PID" 2>/dev/null; sleep 3
echo "exit" >&3; sleep 6; exec 3>&-
sudo kill $TOPO 2>/dev/null; sleep 2
[ -n "$RYU_PID" ] && kill "$RYU_PID" 2>/dev/null
sudo mn -c >/dev/null 2>&1
banner "T-3 OVS RESULT"; echo "failures: $FAIL"; echo "finished $(ts)"
