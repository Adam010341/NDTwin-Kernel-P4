#!/usr/bin/env bash
# Is the cliff at ~40-100 Mbit/s a BITRATE limit or a FLOW-COUNT limit?
#
# Why this has to be answered before the real run. At the loss-free point the ladder found
# (scale 0.1) every flow runs at 0.1-2 Mbit/s, i.e. entirely BELOW F-9's ~3 Mbit/s quantisation
# threshold, so every host edge would read zero and the reconciliation would have no signal on
# 256 of 288 edges. Trading concurrency for per-flow rate is the only way out -- but only if the
# limit is flow count. If it is bitrate, fewer-and-fatter flows lose just as much and the run has
# to be designed around the loss instead.
#
# Three points at the SAME offered bitrate (~102 Mbit/s, the load that lost 42% at 64 flows) and
# three different flow counts. Same total, same path mix, only concurrency varies.
#
# Usage: discriminate.sh [seconds]
# [Co-developed with claude code -- Adam]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DUR="${1:-20}"
OUT="$HERE/raw/discrim"
mkdir -p "$OUT"

printf '%-8s %-8s %-11s %-10s %-9s %-9s %s\n' \
       flows scale offered_Mb per_flow_Mb loss_p50 loss_p90 note | tee "$OUT/table.txt"

run_one() {   # flows scale
    local n="$1" sc="$2" d="$OUT/f${1}_s${2}"
    rm -rf "$d"; mkdir -p "$d"
    FLOW_LIMIT="$n" RATE_SCALE="$sc" bash "$HERE/run_flows.sh" "$d" "$DUR" >"$d/flows.log" 2>&1
    python3 - "$d" "$n" "$sc" <<'PY' | tee -a "$OUT/table.txt"
import glob, json, os, sys
d, n, sc = sys.argv[1:]
loss, offered, ok, bad = [], 0.0, 0, 0
for p in sorted(glob.glob(os.path.join(d, "iperf", "cli_*.json"))):
    try:
        s = json.load(open(p))["end"]["sum"]
    except Exception:
        bad += 1; continue
    ok += 1; offered += s["bits_per_second"] / 1e6
    loss.append(s.get("lost_percent", 0.0))
loss.sort()
q = lambda f: loss[min(len(loss)-1, int(len(loss)*f))] if loss else float("nan")
note = "clean" if loss and q(.9) < 2 else ("marginal" if loss and q(.5) < 2 else "LOSSY")
print(f"{n:<8} {sc:<8} {offered:<11.1f} {offered/max(1,ok):<10.2f} "
      f"{q(.5):<9.1f} {q(.9):<9.1f} {note}  ({ok}/{ok+bad} flows)")
PY
    sleep 3
}

# ~102 Mbit/s each, three concurrencies. The rate ladder scales so the shape is preserved.
run_one 16 1
run_one 32 0.5
run_one 64 0.25

# and the control the ladder already established, re-run here so all four sit in one table
run_one 64 0.1

echo
echo "read-out: loss rising with flow count at constant bitrate => flow-count limit, and the"
echo "          real run can trade concurrency for per-flow rate. Flat => bitrate limit."
