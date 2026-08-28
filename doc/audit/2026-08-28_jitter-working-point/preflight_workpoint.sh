#!/usr/bin/env bash
# Does the proposed working point actually stay below capacity with the REAL arm workload?
#
# WHY THIS EXISTS INSTEAD OF AN ARGUMENT. The capacity ladder gives a per-FLOW number, and the
# arms run 16 flows over four path classes, so roughly four share each inter-switch link. Whether
# the working point means per-flow or per-link changes it fourfold, and the PREREG does not say.
# Rather than pick a definition and defend it, this measures the thing the definition is a proxy
# for: with the whole workload running, does loss stay in the noise?
#
# Loss in the noise => the sender's rate is faithfully carried => any jitter in the reported
# series can only come from H1 or H2, which is the entire premise of the round. Loss above the
# noise => the working point is over capacity and the round would measure drops.
#
# 🔴 Also records host load, because the PREREG wants the machine saturated while the LINK is
# not. Those are different conditions and only one of them is a confounder.
#
# Usage: NDT_OWNER=... preflight_workpoint.sh <per_flow_mbit> [outdir]
# [Co-developed with claude code -- Adam]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
RATE="${1:?per-flow rate in Mbit}"
OUT="${2:-$HERE/raw/preflight_${RATE}M}"; mkdir -p "$OUT"
DUR="${DUR:-20}"

owner="$(sed -n 's/^owner=//p' "$REPO/.test_run/lab.claim" 2>/dev/null)"
[[ "$owner" == "${NDT_OWNER:-}" ]] || { echo "🔴 lab.claim owner='$owner' != '${NDT_OWNER:-}'"; exit 1; }

host_pid() { ps -eo pid,args | awk -v h="mininet:$1" '$NF==h{print $1; exit}'; }

# The same 16 pairs run_flows.sh keeps at FLOW_LIMIT=16: every 4th of the 64, so all four path
# classes stay represented. Using a different set would preflight a different experiment.
CLIENTS=(); SERVERS=()
for i in $(seq 0 15); do CLIENTS+=("h$((1+i))");  SERVERS+=("h$((65+i))");  done
for i in $(seq 0 15); do CLIENTS+=("h$((33+i))"); SERVERS+=("h$((97+i))");  done
for i in $(seq 0 15); do CLIENTS+=("h$((17+i))"); SERVERS+=("h$((49+i))");  done
for i in $(seq 0 15); do CLIENTS+=("h$((81+i))"); SERVERS+=("h$((113+i))"); done
KC=(); KS=()
for i in $(seq 0 15); do KC+=("${CLIENTS[$((i*4))]}"); KS+=("${SERVERS[$((i*4))]}"); done

echo "### preflight: 16 flows x ${RATE} Mbit for ${DUR}s  (=$((16*RATE)) Mbit offered total)"
echo "load1_before=$(cut -d' ' -f1 /proc/loadavg)" > "$OUT/meta"

for i in $(seq 0 15); do
    s="${KS[$i]}"; sp=$(host_pid "$s")
    [[ -z "$sp" ]] && { echo "🔴 missing ns $s"; exit 1; }
    sudo -n mnexec -a "$sp" iperf3 -s -1 --daemon -p $((5600 + i)) >/dev/null 2>&1
done
sleep 2
for i in $(seq 0 15); do
    c="${KC[$i]}"; s="${KS[$i]}"; cp=$(host_pid "$c")
    sudo -n mnexec -a "$cp" iperf3 -c "10.0.0.${s#h}" -p $((5600 + i)) -u -b "${RATE}M" \
        -t "$DUR" -l 1400 --json > "$OUT/f_${c}_${s}.json" 2>&1 &
done
sleep $((DUR / 2)); echo "load1_mid=$(cut -d' ' -f1 /proc/loadavg)" >> "$OUT/meta"
wait
echo "load1_after=$(cut -d' ' -f1 /proc/loadavg)" >> "$OUT/meta"

python3 - "$OUT" "$RATE" <<'PY'
import glob, json, os, statistics, sys
d, rate = sys.argv[1], float(sys.argv[2])
loss, sent, recv, bad = [], 0.0, 0.0, 0
for p in sorted(glob.glob(os.path.join(d, "f_*.json"))):
    try:
        e = json.load(open(p))["end"]
        s, r = e["sum_sent"], e["sum_received"]
    except Exception:
        bad += 1; continue
    loss.append(r.get("lost_percent", 0.0))
    sent += s["bits_per_second"] / 1e6
    recv += r["bits_per_second"] / 1e6
if not loss:
    print("  🔴 no flow produced a result -- not a preflight"); raise SystemExit(1)
loss.sort()
print(f"  flows {len(loss)} ok, {bad} unusable")
print(f"  offered total {sent:.0f} Mbit   delivered total {recv:.0f} Mbit")
print(f"  per-flow loss: median {statistics.median(loss):.3f}%  max {max(loss):.3f}%")
# The gate is the same 0.5% the capacity ladder's noise floor showed, fixed before this ran.
if max(loss) <= 0.5:
    print(f"  ✅ every flow at or below the 0.5% noise floor => working point is BELOW capacity")
else:
    print(f"  🔴 {sum(1 for x in loss if x > 0.5)} flow(s) above 0.5% => OVER capacity here.")
    print(f"     Lower the per-flow rate; do not run arms at this point.")
PY
cat "$OUT/meta" | sed 's/^/  /'
