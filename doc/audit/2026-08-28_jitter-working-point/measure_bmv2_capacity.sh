#!/usr/bin/env bash
# Prerequisite for the jitter round: what is ONE bmv2 link's actual capacity?
#
# WHY THIS CANNOT BE SKIPPED OR BORROWED. The jitter round is only informative at a working point
# that is UDP and just BELOW capacity: above capacity the receiver drops and of course its numbers
# move, which proves nothing. So the working point is defined as a fraction of capacity, and
# nobody has measured capacity on this forwarding plane.
#
# 🔴 DO NOT reuse the 53.1 Gbit/s from ovs-bandwidth-ceiling-measured. That was OVS. bmv2 is a
# software switch on a different datapath, and carrying a number across forwarding planes is the
# same error as carrying a loop period across fabric generations.
#
# METHOD. One host pair on one path class, UDP, a rate ladder, each step short. Record the
# SENDER's offered rate and the RECEIVER's delivered rate and loss separately -- the PREREG asks
# for both because "what iperf displays" means different things at the two ends.
#
# DROP ONSET is the first rung whose loss exceeds LOSS_PCT. The working point for the jitter arms
# is then 70-80% of the last CLEAN rung, not of the rung that broke.
#
# Usage: NDT_OWNER=... measure_bmv2_capacity.sh [outdir]
# [Co-developed with claude code -- Adam]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
OUT="${1:-$HERE/raw/capacity}"; mkdir -p "$OUT"
STEP_S="${STEP_S:-8}"
LOSS_PCT="${LOSS_PCT:-1.0}"
# Start well below any plausible bmv2 ceiling and climb geometrically. A software switch is
# expected in the hundreds of Mbit/s, so the ladder brackets that by two orders of magnitude
# rather than assuming where it sits.
RATES="${RATES:-5 10 20 40 80 160 320 640 1280}"

owner="$(sed -n 's/^owner=//p' "$REPO/.test_run/lab.claim" 2>/dev/null)"
[[ "$owner" == "${NDT_OWNER:-}" ]] || { echo "🔴 lab.claim owner='$owner' != '${NDT_OWNER:-}'"; exit 1; }

# Same namespace lookup as run_flows.sh: exact ps-title match, never pgrep -- its pattern would
# match this script's own argv.
host_pid() { ps -eo pid,args | awk -v h="mininet:$1" '$NF==h{print $1; exit}'; }

C=h1; S=h65                      # s1 -> s3, the same path class the arms use
CP=$(host_pid "$C"); SP=$(host_pid "$S")
[[ -n "$CP" && -n "$SP" ]] || { echo "🔴 host namespaces missing: $C=$CP $S=$SP"; exit 1; }
echo "### bmv2 capacity ladder  $C(pid $CP) -> $S(pid $SP)  step ${STEP_S}s  $(date '+%H:%M:%S')"
echo "rate_mbit offered_mbit delivered_mbit loss_pct jitter_ms" > "$OUT/ladder.tsv"

onset=""; last_clean=""
for r in $RATES; do
    port=$((5201 + RANDOM % 100))
    sudo -n mnexec -a "$SP" iperf3 -s -1 --daemon -p "$port" >/dev/null 2>&1
    sleep 1
    sudo -n mnexec -a "$CP" iperf3 -c "10.0.0.${S#h}" -p "$port" -u -b "${r}M" \
        -t "$STEP_S" -l 1400 --json > "$OUT/step_${r}M.json" 2>&1
    read -r off del loss jit < <(python3 - "$OUT/step_${r}M.json" <<'PY'
import json, sys
try:
    e = json.load(open(sys.argv[1]))["end"]
    # 🔴 NOT end.sum. For UDP, iperf3's `sum` reports the SENDER's bits_per_second with the
    # RECEIVER's loss stats merged into the same object -- a hybrid whose name looks like the
    # answer. Reading it as "delivered" made the first run of this script print 159.98 Mbit
    # delivered while 1.49% was lost, which is arithmetically impossible and went unnoticed
    # because the number looked plausible. sum_sent and sum_received are the two real ends, and
    # the PREREG requires them kept apart precisely because "what iperf shows" differs at each.
    snt, rcv = e["sum_sent"], e["sum_received"]
    print(f'{snt["bits_per_second"]/1e6:.2f} {rcv["bits_per_second"]/1e6:.2f} '
          f'{rcv.get("lost_percent", 0.0):.3f} {e["sum"].get("jitter_ms", 0.0):.3f}')
except Exception:
    # A failed rung is NOT zero loss and NOT zero throughput -- it is no measurement. -1 is a
    # sentinel that cannot be confused with a legal reading, the same rule as divisor_used_s.
    print("-1 -1 -1 -1")
PY
)
    printf '%s\t%s\t%s\t%s\t%s\n' "$r" "$off" "$del" "$loss" "$jit" >> "$OUT/ladder.tsv"
    printf '  %6s Mbit  offered %8s  delivered %8s  loss %6s%%  jitter %s ms\n' \
        "$r" "$off" "$del" "$loss" "$jit"
    if [[ "$loss" == "-1" ]]; then
        echo "  🔴 rung ${r}M produced no measurement -- stopping rather than guessing"; break
    fi
    if awk "BEGIN{exit !($loss > $LOSS_PCT)}"; then
        onset="$r"; echo "  => DROP ONSET at ${r} Mbit (loss ${loss}% > ${LOSS_PCT}%)"; break
    fi
    last_clean="$r"
done

{ echo "drop_onset_mbit=${onset:-none-in-ladder}"
  echo "last_clean_mbit=${last_clean:-none}"
  echo "loss_threshold_pct=$LOSS_PCT"
  echo "step_s=$STEP_S"
  echo "ladder=$RATES"; } > "$OUT/capacity.meta"

if [[ -z "$onset" ]]; then
    echo "⚠️  no rung exceeded ${LOSS_PCT}% loss -- capacity is ABOVE the top of this ladder."
    echo "   The working point cannot be set from this run. Extend RATES and rerun."
else
    lo=$(awk "BEGIN{printf \"%.0f\", $last_clean*0.70}")
    hi=$(awk "BEGIN{printf \"%.0f\", $last_clean*0.80}")
    echo "  last clean rung ${last_clean}M  =>  jitter working point 70-80% = ${lo}-${hi} Mbit"
    echo "working_point_lo_mbit=$lo" >> "$OUT/capacity.meta"
    echo "working_point_hi_mbit=$hi" >> "$OUT/capacity.meta"
fi
echo "### done $(date '+%H:%M:%S')  -> $OUT/ladder.tsv"
