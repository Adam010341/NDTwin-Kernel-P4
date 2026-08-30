#!/bin/bash
# ============================================================================================
# T-5: prove the three documentation fixes BEFORE they are written into the pages.
#
# The instruction was explicit and is the whole point: the flag form has not been exercised on
# the OVS path -- only on the P4 page -- so it must not be documented on the strength of a
# sibling page doing it. Same binary, different arguments, different topology model: that is a
# reason to test, not a reason to assume.
#
# THE ACCEPTANCE QUESTION, applied to each fix: "if this change had no effect, would this step
# go red?"
#
#   A / M-4  Flag form on the OVS path. Red if the kernel prompts anyway, exits non-zero, or
#            loads a topology other than the OVS one. Run headless ON PURPOSE here: with no
#            terminal a prompting kernel exits with usage, so "it did not prompt" is proven by
#            the run succeeding, not asserted by me reading the output.
#
#   B / M-3  Two-sided, because the OLD wording's whole failure was printing PASS on a fabric
#            where every switch was unreachable. So the replacement must FIRE against a
#            genuinely dead fabric and stay SILENT against a live one. One side alone proves
#            nothing: a string that never matches passes the negative test perfectly.
#
#   C / M-5  Only the wording changes, so what is checked is that waiting on the message rather
#            than on a number is actually available -- i.e. the message exists and is greppable.
#
# [Co-developed with claude code -- Adam]
# ============================================================================================
LOG=~/t5.log
exec > >(tee -a "$LOG") 2>&1
cd "$HOME/Desktop/NDTwin-Kernel" || exit 1
FAIL=0; ts(){ date -Is; }
ok(){ echo "    PASS: $*"; }; bad(){ echo "    FAIL: $*"; FAIL=$((FAIL+1)); }
banner(){ echo; echo "############ $* ############"; }
holder(){ sudo ss -lptn "sport = :$1" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2; }

echo "=== T-5 fix verification, started $(ts) ==="
sudo mn -c >/dev/null 2>&1; rm -f ~/ryu5.log ~/mn5.log ~/k5.log ~/proxy5.log

# =============================================================================================
banner "B / M-3 NEGATIVE SIDE FIRST -- proxy against a fabric that is NOT running"
echo "No BMv2 switches exist right now. The proxy must fail to reach them, and the string the"
echo "page tells a reader to look for must actually appear. Old wording: ECONNREFUSED."
( cd p4_proxy && PYTHONUNBUFFERED=1 PYTHONPATH="$PWD" venv/bin/python proxy_agent/main.py > ~/proxy5.log 2>&1 ) &
sleep 20
P5=$(holder 8081); echo "    pid holding :8081 = ${P5:-<nobody>}"
old=$(grep -c "ECONNREFUSED" ~/proxy5.log)
new=$(grep -c "Connection refused" ~/proxy5.log)
echo "    occurrences of 'ECONNREFUSED'      (what the page says today): $old"
echo "    occurrences of 'Connection refused' (what the software prints): $new"
[ "$old" -eq 0 ] && ok "old wording finds NOTHING on a completely dead fabric -- M-3 confirmed" \
                 || bad "old wording matched; M-3 would be wrong"
[ "$new" -gt 0 ] && ok "replacement wording FIRES on a dead fabric ($new hits)" \
                 || bad "replacement wording does not match either -- do not document it"
[ -n "$P5" ] && sudo kill "$P5" 2>/dev/null
sleep 3

# =============================================================================================
banner "A / M-4 -- the flag form, on the OVS path, which has never been tested"
echo "Terminal 1: Ryu"
setsid bash -lc 'source ~/miniconda3/etc/profile.d/conda.sh && conda activate ryu-env && \
  exec ryu-manager intelligent_router.py ryu.app.rest_topology ryu.app.ofctl_rest \
       --ofp-tcp-listen-port 6633 --observe-link' > ~/ryu5.log 2>&1 &
sleep 25
RY=$(holder 6633); echo "    :6633 held by ${RY:-<nobody>}"
[ -n "$RY" ] && ok "Ryu up" || bad "Ryu not up -- the rest of A is meaningless"

echo "Terminal 2: Mininet"
FIFO=/tmp/mn5; rm -f "$FIFO"; mkfifo "$FIFO"
sudo python3 testbed_topo.py < "$FIFO" > ~/mn5.log 2>&1 &
TOPO=$!; exec 3> "$FIFO"
echo "    waiting for the page's named message (C / M-5 also depends on this existing)"
seen=0
for i in $(seq 1 48); do
    if grep -qi "all.destination paths installed" ~/ryu5.log ~/mn5.log 2>/dev/null; then
        echo "    $(ts)  message appeared after ~$((i*5))s"; seen=1; break; fi
    [ -d /proc/$TOPO ] || { echo "    topology gone"; break; }
    sleep 5
done
[ "$seen" = "1" ] && ok "C / M-5: the message exists and is greppable, so 'wait for the message' is actionable" \
                  || bad "C / M-5: the message never appeared -- 'wait for the message' would be unusable advice"

echo
echo "Terminal 3, FLAG FORM, deliberately HEADLESS:"
echo "  a kernel that still wants to prompt exits with usage when stdin is not a terminal,"
echo "  so success here IS the proof that the flags removed the prompting."
cd build
export OPENAI_API_KEY="any-random-string-here"
setsid sudo -E ./bin/ndtwin_kernel --mode mininet \
    --topology ../setting/StaticNetworkTopologyMininet_10Switches.json \
    --no-ai --loglevel info > ~/k5.log 2>&1 < /dev/null &
cd ..
sleep 30
echo "    --- first lines ---"; head -8 ~/k5.log | sed 's/\x1b\[[0-9;]*m//g;s/^/      /'
if grep -qiE "usage|Enter environment choice|Enter topology choice" ~/k5.log; then
    bad "M-4 flag form still prompts or prints usage -- DO NOT document it"
else
    ok "no prompt, no usage message"
fi
grep -q "StaticNetworkTopologyMininet_10Switches.json" ~/k5.log \
    && ok "loaded the OVS topology the flag named" || bad "did not load the named topology"
grep -qi "IntentTranslator is disabled" ~/k5.log && ok "--no-ai took effect" || echo "    (no explicit AI-disabled line)"
K=$(holder 8000); echo "    :8000 held by ${K:-<nobody>}"
if [ -n "$K" ]; then
    code=$(curl -s -m 5 -o /tmp/g5.json -w '%{http_code}' http://localhost:8000/ndt/get_graph_data)
    echo "    GET /ndt/get_graph_data -> HTTP $code"
    [ "$code" = "200" ] && ok "kernel answers on the OVS path with the flag form" || bad "HTTP $code"
    python3 -c "import json;d=json.load(open('/tmp/g5.json'));print('      twin: nodes=%d edges=%d'%(len(d.get('nodes',[])),len(d.get('edges',[]))))" 2>/dev/null
else
    bad "kernel never listened on 8000 with the flag form"
fi

# =============================================================================================
banner "B / M-3 POSITIVE SIDE -- same string against a LIVE fabric must stay silent"
echo "If 'Connection refused' also appeared on a healthy run, the new wording would be a false"
echo "alarm and would be no better than the old one."
echo "    NOTE: this OVS run has no BMv2 proxy, so the honest statement is that the positive"
echo "    side was established in the T-2 investigation run, where proxy2.log against a live"
echo "    BMv2 fabric contained ZERO 'Connection refused' while reporting links=32 paths=12."
echo "    Recorded here rather than re-derived, and marked as such."

banner "SHUTDOWN"
[ -n "$K" ] && sudo kill "$K" 2>/dev/null; sleep 3
echo "exit" >&3; sleep 6; exec 3>&-
sudo kill $TOPO 2>/dev/null; sleep 2
[ -n "$RY" ] && kill "$RY" 2>/dev/null
sudo mn -c >/dev/null 2>&1
banner "T-5 RESULT"; echo "failures: $FAIL"; echo "finished $(ts)"
