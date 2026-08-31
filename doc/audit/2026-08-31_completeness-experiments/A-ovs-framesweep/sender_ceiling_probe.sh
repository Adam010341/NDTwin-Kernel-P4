#!/usr/bin/env bash
# §A design probe — DOES THE SENDER MANUFACTURE H1?
# [Co-developed with claude code -- Adam]
#
# 🔴 WHY THIS RUNS BEFORE ANY §A DATA.
# §A.2 caught that the htb 1 Gbit cap's pps signature (0.10) sits inside H2's registered
# interval, so a shaped fabric would manufacture a fake H2.  The fix was "run unshaped".
# But removing the fabric cap promotes the NEXT bound to be the binding one, and on an
# unshaped fabric that is the SENDER.  If the sender is per-packet-cost dominated -- which
# is exactly the hypothesis under test, one layer up -- its own pps is near-constant across
# frame size, i.e. P(1024)/P(64) ~ 1, which lands inside H1's registered interval
# (0.65-1.30).  H1 is the direction FAVOURABLE to the paper.
#
# So the instrument can manufacture either verdict, and which one it manufactures depends
# only on which cap we removed.  This probe measures the sender's own ratio FIRST, with no
# fabric in the path at all (loopback, root netns).  The number it produces is a property
# of iperf3 + this kernel + this CPU, not of any switch.
#
# Registered reading BEFORE the data (this is the whole point of running it first):
#   R_gate = P_gate(1024)/P_gate(64), computed from loopback pps.
#     * R_gate inside (0.65, 1.30)  -> 🔴 the sender's signature IS H1's signature.
#                                      §A cannot distinguish H1 from a sender artefact.
#                                      => §A must not be run in this form.
#     * R_gate outside that interval, AND every §A cell's achieved pps <= 0.80 * gate pps
#       at the same frame size -> the sender is not binding; §A is readable.
#     * anything else -> per-cell "sender-bound", not admissible.
#
# 🔑 The 0.80 headroom factor is registered here, before data, and is deliberately strict:
# a cell at 0.9 of the gate is already being shaped by the sender's own cost curve.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/raw_probe"; mkdir -p "$OUT"
REPS="${REPS:-3}"
DUR="${DUR:-5}"

echo "=== §A sender-ceiling probe  $(date -Is) ==="
echo "host: $(uname -r)  iperf3: $(iperf3 --version 2>&1 | head -1)"
echo "load at start: $(awk '{print $1,$2,$3}' /proc/loadavg)"
echo ""

# one server per payload size, serial -- concurrency here would measure scheduling, not cost
for L in 64 256 1024; do
  for rep in $(seq 1 "$REPS"); do
    port=$((5400 + L / 64 * 10 + rep))
    iperf3 -s -1 --daemon -p "$port" >/dev/null 2>&1
    sleep 0.4
    iperf3 -c 127.0.0.1 -p "$port" -u -b 0 -t "$DUR" -l "$L" --json \
      > "$OUT/gate_l${L}_rep${rep}.json" 2>&1
  done
done

python3 - "$OUT" <<'PY'
import json, os, sys, statistics
out = sys.argv[1]
res = {}
for L in (64, 256, 1024):
    pps, mbit = [], []
    for rep in (1, 2, 3):
        p = os.path.join(out, f"gate_l{L}_rep{rep}.json")
        try:
            d = json.load(open(p))
            s = d["end"]["sum"]
            pkts, secs = s["packets"], s["seconds"]
            pps.append(pkts / secs)
            mbit.append(s["bits_per_second"] / 1e6)
        except Exception as e:
            print(f"  🔴 l={L} rep={rep}: {e}")
    if pps:
        res[L] = (statistics.median(pps), statistics.median(mbit))

print("")
print("  payload  frame   loopback pps      loopback Mbit")
for L, (p, m) in sorted(res.items()):
    print(f"  {L:>5} B  {L+42:>5} B  {p:>12,.0f}      {m:>10,.0f}")

if 64 in res and 1024 in res:
    r = res[1024][0] / res[64][0]
    print("")
    print(f"  🔑 R_gate = P_gate(1024)/P_gate(64) = {r:.3f}")
    if 0.65 <= r <= 1.30:
        print("  🔴 VERDICT: the sender's own signature lands INSIDE H1's registered")
        print("     interval (0.65-1.30).  A §A run on an unshaped fabric would report")
        print("     H1 whether or not OvS has that property.  §A is NOT readable in this")
        print("     form -- the finding would be an instrument artefact, and it would be")
        print("     the artefact that FLATTERS the paper.")
    elif 0.03 <= r <= 0.12:
        print("  🔴 VERDICT: sender signature lands inside H2's interval instead.")
        print("     Same problem, opposite direction.")
    else:
        print("  ✅ VERDICT: sender signature is outside BOTH registered intervals.")
        print(f"     Per-cell admission bound (registered): achieved pps <= 0.80 x gate pps")
        for L, (p, m) in sorted(res.items()):
            print(f"       l={L:>4} B : admissible up to {0.80*p:>12,.0f} pps"
                  f"  ({0.80*p*(L+42)*8/1e6:>8,.0f} Mbit at frame {L+42} B)")
    json.dump({str(k): {"pps": v[0], "mbit": v[1]} for k, v in res.items()},
              open(os.path.join(out, "gate_summary.json"), "w"), indent=2)
PY
echo ""
echo "=== probe done  $(date -Is) ==="
