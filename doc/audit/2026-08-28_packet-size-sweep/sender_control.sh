#!/usr/bin/env bash
# PREREG section 3: does the generator itself limit the 64 B result?
#
# "pps is constant across packet size" is exactly what a sender-limited experiment produces, so
# this must run BEFORE any bmv2 arm and its number must be recorded whether it passes or fails.
#
# The run is h1 -> h1 over loopback INSIDE the host namespace, so no packet reaches bmv2. That is
# the point: it measures what the generator can emit at 64 B frames when nothing else is in the
# way. The 08-15 loopback figures do NOT serve here -- they were taken at 1400 B, and small-packet
# generation is bound by per-packet cost, not bandwidth (PREREG section 3).
#
# Frame size vs payload: iperf3 -l is UDP PAYLOAD. Ethernet frame = payload + 42 (14 Ethernet +
# 20 IP + 8 UDP). A 64 B frame is therefore -l 22. Getting this backwards shifts the whole axis by
# 42 bytes, which at 64 B is a 66% error.
#
# Registered threshold: the generator must sustain at least 5x the highest 64 B pps that this round
# later measures through bmv2. 08-15 puts bmv2-fast near 50.8 kpps at small packets, so the working
# target is ~254 kpps. The FINAL pass/fail is decided at analysis time against the measured bmv2
# number, not against that estimate -- this script records the ceiling and says which side of the
# estimate it fell on.
#
# Usage: NDT_OWNER="..." ./sender_control.sh [outdir]
# [Co-developed with claude code -- Adam]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
OUT="${1:-$HERE/raw/sender_control}"; mkdir -p "$OUT"

STEP_S="${STEP_S:-10}"
REPS="${REPS:-3}"
PAYLOAD=22                      # 64 B frame
EST_TARGET_KPPS=254             # from 08-15's 50.8 kpps x 5; NOT the registered threshold itself

owner="$(sed -n 's/^owner=//p' "$REPO/.test_run/lab.claim" 2>/dev/null)"
[[ -n "${NDT_OWNER:-}" ]] || { echo "🔴 NDT_OWNER unset"; exit 1; }
[[ "$owner" == "$NDT_OWNER" ]] || { echo "🔴 lab.claim owner='$owner' != NDT_OWNER='$NDT_OWNER'"; exit 1; }

host_pid() { ps -eo pid,args | awk -v h="mininet:$1" '$NF==h{print $1; exit}'; }
HP=$(host_pid h1)
[[ -n "$HP" ]] || { echo "🔴 h1 namespace missing"; exit 1; }

{
  echo "control=sender_side_64B_loopback"
  echo "started=$(date '+%F %T %z')"
  echo "purpose=PREREG section 3 -- generator pps ceiling at 64 B frames, NOT through bmv2"
  echo "payload_bytes=$PAYLOAD"
  echo "frame_bytes=$((PAYLOAD + 42))"
  echo "path=h1 -> 127.0.0.1 inside h1 netns (loopback; no bmv2 in path)"
  echo "step_s=$STEP_S"
  echo "reps=$REPS"
  echo "estimate_target_kpps=$EST_TARGET_KPPS  # 5x 08-15's 50.8 kpps; final gate is vs THIS round's bmv2 64B pps"
} > "$OUT/control.meta"

echo "### sender-side control: 64 B frames (payload $PAYLOAD), h1 loopback, ${STEP_S}s x $REPS"

for r in $(seq 1 "$REPS"); do
    port=$((5300 + r))
    sudo -n mnexec -a "$HP" iperf3 -s -1 --daemon -p "$port" >/dev/null 2>&1
    sleep 1
    # -b 0 = unlimited: we want the generator's own ceiling, not a requested rate.
    sudo -n mnexec -a "$HP" iperf3 -c 127.0.0.1 -p "$port" -u -b 0 \
        -t "$STEP_S" -l "$PAYLOAD" --json > "$OUT/rep${r}.json" 2>&1
done

python3 - "$OUT" "$REPS" "$EST_TARGET_KPPS" <<'PY'
import json, sys, os, statistics
out, reps, est = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
rows = []
for r in range(1, reps + 1):
    p = os.path.join(out, f"rep{r}.json")
    try:
        e = json.load(open(p))["end"]
        s = e["sum_sent"]
        # pps from delivered datagrams and duration -- never back-derived from bps and a nominal
        # size, which would bake the answer in (PREREG section 5).
        rx = e.get("sum_received", {})
        pkts = rx.get("packets") or s.get("packets")
        secs = rx.get("seconds") or s.get("seconds")
        pps = pkts / secs if pkts and secs else None
        rows.append((r, pkts, secs, pps, s["bits_per_second"] / 1e6))
    except Exception as ex:
        rows.append((r, None, None, None, None))
        print(f"  rep{r}: 🔴 NO MEASUREMENT ({type(ex).__name__})")

good = [x for x in rows if x[3] is not None]
for r, pkts, secs, pps, mbps in rows:
    if pps is None:
        continue
    print(f"  rep{r}: {pkts:>10d} pkt / {secs:6.2f} s = {pps/1000:9.1f} kpps   ({mbps:8.1f} Mbit/s)")

if not good:
    print("\n🔴 CONTROL PRODUCED NO MEASUREMENT -- the round cannot start.")
    open(os.path.join(out, "VERDICT"), "w").write("NO_MEASUREMENT\n")
    sys.exit(1)

med = statistics.median(x[3] for x in good)
print(f"\ngenerator ceiling at 64 B frames (median of {len(good)}): {med/1000:.1f} kpps")
print(f"estimate to clear (5x 08-15's 50.8 kpps): {est:.0f} kpps  -> "
      f"{'above' if med/1000 >= est else 'BELOW'} the estimate")
print("\n🔴 This is NOT the registered pass/fail. The gate is 5x THIS round's highest 64 B pps")
print("   through bmv2, which does not exist yet. Recorded now so it cannot be chosen later.")
with open(os.path.join(out, "VERDICT"), "w") as f:
    f.write(f"generator_ceiling_kpps={med/1000:.1f}\n")
    f.write(f"estimate_kpps={est:.0f}\n")
    f.write(f"vs_estimate={'above' if med/1000 >= est else 'below'}\n")
    f.write("final_gate=pending -- 5x this round's bmv2 64B pps, decided at analysis time\n")
PY

echo "finished=$(date '+%F %T %z')" >> "$OUT/control.meta"
