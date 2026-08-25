#!/usr/bin/env bash
# Find the offered load at which this fabric forwards without loss, before measuring anything.
#
# The pre-registration's stop condition 1 fired on the first smoke run: 58-91% UDP loss at 316
# Mbit/s offered, on EVERY path type including three-hop. A reconciliation run at that load
# would measure the ceiling, not the telemetry. This walks the load down until loss is
# negligible, and records machine CPU alongside, because "the fabric dropped it" and "64 iperf3
# processes could not keep up on one box" produce the same loss number and need different fixes.
#
# Usage: calibrate.sh [seconds_per_rung]
# [Co-developed with claude code -- Adam]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DUR="${1:-20}"
OUT="$HERE/raw/calib"
mkdir -p "$OUT"

printf '%-8s %-10s %-12s %-9s %-9s %-9s %s\n' \
       scale offered_Mb flows_ok loss_p50 loss_p90 cpu_busy note | tee "$OUT/ladder.txt"

for scale in 1 0.5 0.25 0.1 0.05; do
    d="$OUT/s$scale"; rm -rf "$d"; mkdir -p "$d"

    # whole-machine CPU across the rung, from /proc/stat -- idle vs total, not per-process
    read -r _ u1 n1 s1 i1 w1 rest1 < /proc/stat
    t1=$((u1+n1+s1+i1+w1)); b1=$((u1+n1+s1))

    RATE_SCALE="$scale" bash "$HERE/run_flows.sh" "$d" "$DUR" > "$d/flows.log" 2>&1

    read -r _ u2 n2 s2 i2 w2 rest2 < /proc/stat
    t2=$((u2+n2+s2+i2+w2)); b2=$((u2+n2+s2))
    cpu=$(python3 -c "print(f'{100*($b2-$b1)/max(1,$t2-$t1):.0f}%')")

    python3 - "$d" "$scale" "$cpu" <<'PY' | tee -a "$OUT/ladder.txt"
import glob, json, os, sys
d, scale, cpu = sys.argv[1:]
loss, offered, ok, bad = [], 0.0, 0, 0
for p in sorted(glob.glob(os.path.join(d, "iperf", "cli_*.json"))):
    try:
        s = json.load(open(p))["end"]["sum"]
    except Exception:
        bad += 1; continue
    ok += 1
    offered += s["bits_per_second"] / 1e6
    loss.append(s.get("lost_percent", 0.0))
loss.sort()
q = lambda f: loss[min(len(loss) - 1, int(len(loss) * f))] if loss else float("nan")
note = "USABLE" if loss and q(.9) < 2.0 else ("marginal" if loss and q(.5) < 2.0 else "over")
print(f"{scale:<8} {offered:<10.1f} {f'{ok}/{ok+bad}':<12} "
      f"{q(.5):<9.1f} {q(.9):<9.1f} {cpu:<9} {note}")
PY
    sleep 3
done
echo
echo "read-out rule (pre-registered): the run uses the highest scale whose p90 loss is under 2%."
