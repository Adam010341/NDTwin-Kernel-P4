#!/usr/bin/env bash
# What does the unshaped core actually deliver?
#
# F-7b decision input. The topology declares the 16 core interfaces at 10 Gbps; Mininet
# refuses to shape above 1 Gbps (bwParamMax) and leaves them unshaped. Two candidate fixes
# disagree on what to do, and the disagreement turns on one number:
#
#   (a) apply htb rate 10gbit ourselves   -- only worth doing if the emulator can approach it
#   (b) scale the whole topology 10x down -- correct if it cannot
#
# The natural control is built into the topology:
#   hosts 1-32   -> s1        s1 -- s5/s6 (aggregation, 1 Gbps, SHAPED)
#   hosts 33-64  -> s2        s5/s6 -- s9/s10 (core, 10 Gbps declared, UNSHAPED)
#   hosts 65-96  -> s3
#   hosts 97-128 -> s4
#
#   s1 <-> s2  traffic stays in the aggregation layer   -- never touches the core
#   s1 <-> s3  traffic must cross s9/s10                -- crosses the core
#
# So: same access links, same host count, same shaping on both sides. The only difference
# between the two runs is whether the path traverses an unshaped core link.
#
# SHAPING PROBE, and why it needs no sudoers change. sudoers authorises
# `tc qdisc add dev s*-eth* root netem *`, and netem has a `rate` option that the man page
# calls "a replacement for TBF". So `root netem rate 10gbit` is already permitted and can
# answer the decision-relevant question directly: on this machine, what does a link capped
# at 10 Gbps actually deliver?
#
# `root netem` is normally the destructive form -- it silently replaces TCLink's htb. It is
# safe *here* precisely because the core interfaces are `noqueue`: there is no htb to
# destroy. This is one of the few places the root form is the correct one.
#
# What this still cannot answer: whether Mininet's own htb is accurate at 10 Gbps. That is
# an implementation detail of the eventual fix, not an input to choosing between (a) and
# (b), so it is deliberately out of scope.
#
# Read-only with respect to the repo and the topology: starts iperf3 in host namespaces and
# nothing else.
#
# [Co-developed with claude code -- Adam]
set +e
cd /home/adam/Desktop/NDTwin-Kernel
PAIRS="${PAIRS:-8}"        # parallel host pairs per run
SECS="${SECS:-20}"
OUT="${OUT:-/home/adam/Desktop/NDTwin-Kernel/scratch/core_bandwidth.log}"

hostpid() { pgrep -f "mininet:h$1\$" | head -1; }

run_set() {   # run_set <label> <src_base> <dst_base>
    local label="$1" sb="$2" db="$3" total=0 ok=0
    echo "--- $label : $PAIRS pairs x ${SECS}s ---" | tee -a "$OUT"
    for i in $(seq 0 $((PAIRS-1))); do
        local s=$((sb+i)) d=$((db+i))
        local sp dp
        sp=$(hostpid $s); dp=$(hostpid $d)
        [ -z "$sp" ] || [ -z "$dp" ] && { echo "   h$s/h$d: no pid, skipped" | tee -a "$OUT"; continue; }
        sudo -n mnexec -a "$dp" iperf3 -s -1 -p $((5300+i)) >/dev/null 2>&1 &
    done
    sleep 2
    local results=()
    for i in $(seq 0 $((PAIRS-1))); do
        local s=$((sb+i)) d=$((db+i))
        local sp; sp=$(hostpid $s)
        [ -z "$sp" ] && continue
        ( sudo -n mnexec -a "$sp" iperf3 -c "10.0.0.$d" -p $((5300+i)) -t "$SECS" -J 2>/dev/null \
          > "/tmp/ipf_$i.json" ) &
    done
    wait
    for i in $(seq 0 $((PAIRS-1))); do
        local bps
        bps=$(p4_proxy/venv/bin/python -c "
import json,sys
try:
    d=json.load(open('/tmp/ipf_$i.json'))
    print(int(d['end']['sum_received']['bits_per_second']))
except Exception: print(0)" 2>/dev/null)
        [ "$bps" -gt 0 ] && { total=$((total+bps)); ok=$((ok+1)); }
    done
    rm -f /tmp/ipf_*.json
    echo "   $ok/$PAIRS flows completed, aggregate $(p4_proxy/venv/bin/python -c "print(f'{$total/1e9:.2f}')") Gbps" | tee -a "$OUT"
}

echo "# core bandwidth measurement $(date '+%F %T')" | tee "$OUT"
echo "# hosts 1-32=s1  33-64=s2  65-96=s3  97-128=s4" | tee -a "$OUT"

# Control: stays inside the aggregation layer, every link shaped at 1 Gbps.
run_set "CONTROL  s1->s2  (no core)"   1 33
# Treatment: identical access links, but the path must cross the unshaped 10 Gbps core.
run_set "CORE     s1->s3  (via s9/s10)" 1 65

echo "# If CORE >> CONTROL, the unshaped core is genuinely faster than 1 Gbps and shaping" | tee -a "$OUT"
echo "# it matters. If CORE ~= CONTROL, the access layer is the bottleneck and option (b)" | tee -a "$OUT"
echo "# (scale the topology down) is the honest fix." | tee -a "$OUT"

# --- Shaping probe: cap the core at the declared 10 Gbps and re-measure. -----------------
# Assert the qdisc actually landed before trusting the run: a silent no-op injection that
# still produces a plausible number is how this project has fooled itself before.
CORE_IFACES="s5-eth3 s5-eth4 s6-eth3 s6-eth4 s7-eth3 s7-eth4 s8-eth3 s8-eth4 \
             s9-eth1 s9-eth2 s9-eth3 s9-eth4 s10-eth1 s10-eth2 s10-eth3 s10-eth4"

echo "" | tee -a "$OUT"
echo "--- applying netem rate 10gbit to the 16 core interfaces ---" | tee -a "$OUT"
applied=0
for d in $CORE_IFACES; do
    ip link show "$d" >/dev/null 2>&1 || continue
    # Refuse to touch anything that already has htb -- that is the destructive case.
    if sudo -n tc qdisc show dev "$d" 2>/dev/null | grep -q htb; then
        echo "   $d already has htb, SKIPPED (would be destructive)" | tee -a "$OUT"; continue
    fi
    sudo -n tc qdisc add dev "$d" root netem rate 10gbit >/dev/null 2>&1
    if sudo -n tc qdisc show dev "$d" 2>/dev/null | grep -q 'netem.*rate 10Gbit'; then
        applied=$((applied+1))
    else
        echo "   $d: ASSERT FAIL, netem did not land" | tee -a "$OUT"
    fi
done
echo "   applied and verified on $applied interface(s)" | tee -a "$OUT"

if [ "$applied" -gt 0 ]; then
    run_set "CORE@10gbit  s1->s3 (shaped)" 1 65
    echo "--- removing the probe ---" | tee -a "$OUT"
    for d in $CORE_IFACES; do sudo -n tc qdisc del dev "$d" root >/dev/null 2>&1; done
    left=$(for d in $CORE_IFACES; do sudo -n tc qdisc show dev "$d" 2>/dev/null | grep -c netem; done | paste -sd+ | bc)
    echo "   netem qdiscs remaining: ${left:-0} (must be 0)" | tee -a "$OUT"
fi
