#!/usr/bin/env bash
# One arm of P1-3: bmv2 aggregate capacity at a fixed flow count n.
#
# Design is PREREG.md in this directory; read that first. This file is the instrument only.
# The parts that are easy to get wrong, and why they are written the way they are:
#
#   * n flows, ONE path class, ONE host pair (h1 -> h65, s1 -> s3), distinguished by PORT.
#     Using n different host pairs would change the switch's table occupancy at the same time as
#     the flow count, confounding the variable being swept. PREREG section 2.
#
#   * sum_sent / sum_received, never end.sum. For UDP iperf3's `sum` reports the SENDER's
#     bits_per_second with the RECEIVER's loss merged into the same object -- a hybrid whose name
#     looks like the answer. That misreading once printed 159.98 Mbit delivered alongside 1.49%
#     lost and went unnoticed because the number looked plausible.
#
#   * A failed flow is -1, not 0. Zero loss and zero throughput are legal readings; "no
#     measurement" must not be confusable with either.
#
#   * Namespace lookup is an exact ps-title match, never pgrep -- a pgrep pattern would match this
#     script's own argv.
#
#   * The ladder is walked to the TOP, not stopped at the first dirty rung. Loss on this fabric is
#     non-monotonic (100M measured 0.399% while 140M measured 0.039%), so "first rung over the
#     threshold" does not point at anything. PREREG asks for the HIGHEST clean rung.
#
#   * AMENDMENT-1: a rung whose first rep lands in the ambiguous band is repeated to three and
#     scored on the median, because the 0.5% threshold bisects the noise at the anchor rung.
#
# Usage: NDT_OWNER="..." ./run_flowcount_arm.sh <n_flows> <arm_label> [outdir]
# [Co-developed with claude code -- Adam]
set -uo pipefail

N="${1:?usage: run_flowcount_arm.sh <n_flows> <arm_label> [outdir]}"
ARM="${2:?arm label, e.g. p1_n4_a}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
OUT="${3:-$HERE/raw/$ARM}"; mkdir -p "$OUT"

STEP_S="${STEP_S:-8}"
CLEAN_PCT="${CLEAN_PCT:-0.5}"          # PREREG section 3
# AMENDMENT-2 section 11.1: any NONZERO reading goes to three reps and is scored on the median.
# There is no lower edge to tune -- an exact 0.0000% is the only reading with a hard physical
# floor, and the measured within-rung spread reaches 0.5006 at a rung that is genuinely clean, so
# no nonzero reading is licensed as "safely far from the 0.5% threshold". AMB_HI is an upper cost
# cut only: above it a rung is dirty on one rep and can never be the highest clean rung anyway.
AMB_HI="${AMB_HI:-2.0}"
RATES="${RATES:-1 2 3 5 8 12 20 30 45 70 110 160 240}"   # per-flow offered Mbit
SAT_STOP_PCT="${SAT_STOP_PCT:-25}"     # two consecutive rungs above this ends the climb

C=h1; S=h65
SIP="10.0.0.${S#h}"

# ---------------------------------------------------------------- claim
owner="$(sed -n 's/^owner=//p' "$REPO/.test_run/lab.claim" 2>/dev/null)"
[[ -n "${NDT_OWNER:-}" ]] || { echo "🔴 NDT_OWNER unset"; exit 1; }
[[ "$owner" == "$NDT_OWNER" ]] || { echo "🔴 lab.claim owner='$owner' != NDT_OWNER='$NDT_OWNER'"; exit 1; }

host_pid() { ps -eo pid,args | awk -v h="mininet:$1" '$NF==h{print $1; exit}'; }
CP=$(host_pid "$C"); SP=$(host_pid "$S")
[[ -n "$CP" && -n "$SP" ]] || { echo "🔴 host namespaces missing: $C=$CP $S=$SP"; exit 1; }

# ---------------------------------------------------------------- provenance, recorded not assumed
{
  echo "arm=$ARM"
  echo "n_flows=$N"
  echo "started=$(date '+%F %T %z')"
  echo "ladder=$RATES"
  echo "step_s=$STEP_S"
  echo "clean_pct=$CLEAN_PCT"
  echo "rep_rule=nonzero-to-${AMB_HI}pct => 3 reps median; exact 0.0000 => 1 rep (AMENDMENT-2 11.1)"
  echo "host_pair=${C}->${S} (${SIP}), distinguished by port"
  echo "kernel_sha256_start=$(sha256sum "$REPO/build/bin/ndtwin_kernel" 2>/dev/null | cut -c1-8)"
  echo "switch_binary=$(pgrep -af 'simple_switch_g[r]pc' | head -1 | grep -o '/usr/local/[^ ]*simple_switch_grpc' | head -1)"
  echo "switch_count=$(pgrep -cf 'simple_switch_g[r]pc')"
} > "$OUT/arm.meta"

# ---------------------------------------------------------------- the constant that must be shown constant
# PREREG section 6. Unique filename per arm: a fixed name opened with > destroys the previous
# arm's samples, which has happened on this project before.
( while :; do
    printf '%s %s %s\n' "$(date +%s)" "$(cut -d' ' -f1 /proc/loadavg)" \
      "$(awk '/^cpu /{print $2+$3+$4+$6+$7+$8, $5}' /proc/stat)"
    sleep 2
  done ) > "$OUT/load_${ARM}.tsv" 2>/dev/null &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null' EXIT

# ---------------------------------------------------------------- counters: upstream of every socket
snap() {  # $1 = tag
  grep -E 's1-eth|s3-eth' /proc/net/dev > "$OUT/netdev_$1.txt" 2>/dev/null
  sudo -n tc -s qdisc show                > "$OUT/tcqdisc_$1.txt" 2>&1
  sudo -n mnexec -a "$SP" cat /proc/net/snmp | grep -A1 '^Udp:' > "$OUT/snmp_recv_$1.txt" 2>&1
}
snap before

# ---------------------------------------------------------------- one rep = n concurrent flows
# Returns: "<max_loss> <agg_sent> <agg_recv> <n_ok>"; max_loss -1 if any flow failed to measure.
run_rep() {
  local rate="$1" rep="$2" i port base
  base=$((5201 + (RANDOM % 200) * 20))
  for ((i=0; i<N; i++)); do
    port=$((base + i))
    sudo -n mnexec -a "$SP" iperf3 -s -1 --daemon -p "$port" >/dev/null 2>&1
  done
  sleep 1
  for ((i=0; i<N; i++)); do
    port=$((base + i))
    sudo -n mnexec -a "$CP" iperf3 -c "$SIP" -p "$port" -u -b "${rate}M" \
      -t "$STEP_S" -l 1400 --json > "$OUT/r${rate}M_rep${rep}_f${i}.json" 2>&1 &
  done
  # This bare `wait` is safe despite the never-ending load sampler started above: run_rep is
  # invoked via command substitution, so it executes in a subshell whose job table does not
  # contain the sampler -- `wait` here only waits on the iperf3 clients. Verified empirically
  # 2026-08-28 before the first arm ran (the inline variant DID deadlock for 7 minutes);
  # the probe is preserved as test_wait.sh in this directory. [Co-developed with claude code -- Adam]
  wait
  python3 - "$N" "$OUT" "$rate" "$rep" <<'PY'
import json, sys, glob, os
n, out, rate, rep = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
losses, sent, recv, ok = [], 0.0, 0.0, 0
for i in range(n):
    p = os.path.join(out, f"r{rate}M_rep{rep}_f{i}.json")
    try:
        e = json.load(open(p))["end"]
        # NOT end.sum -- see the header of this script.
        s, r = e["sum_sent"], e["sum_received"]
        losses.append(float(r.get("lost_percent", 0.0)))
        sent += s["bits_per_second"] / 1e6
        recv += r["bits_per_second"] / 1e6
        ok += 1
    except Exception:
        losses.append(None)
if ok != n or any(l is None for l in losses):
    # Partial arm is not a low-loss arm. -1 is the sentinel that cannot be read as a value.
    print(f"-1 -1 -1 {ok}")
else:
    print(f"{max(losses):.4f} {sent:.2f} {recv:.2f} {ok}")
PY
}

median3() { printf '%s\n' "$1" "$2" "$3" | sort -g | sed -n 2p; }

# ---------------------------------------------------------------- the ladder
echo "### P1-3 arm $ARM  n=$N  $C->$S  step ${STEP_S}s  clean<=${CLEAN_PCT}%  $(date '+%H:%M:%S')"
printf 'rate_mbit\treps\tloss_scored\tloss_reps\tagg_sent\tagg_recv\tclean\n' > "$OUT/ladder.tsv"

best_clean=""; hot_streak=0; truncated=""
for r in $RATES; do
    read -r l1 s1 v1 k1 <<<"$(run_rep "$r" 1)"
    scored="$l1"; reps=1; all="$l1"

    if [[ "$l1" != "-1" ]] && awk "BEGIN{exit !($l1 > 0 && $l1 <= $AMB_HI)}"; then
        # AMENDMENT-2 11.1: any nonzero loss goes to three reps, scored on the median.
        read -r l2 s2 v2 k2 <<<"$(run_rep "$r" 2)"
        read -r l3 s3 v3 k3 <<<"$(run_rep "$r" 3)"
        if [[ "$l2" == "-1" || "$l3" == "-1" ]]; then
            scored="-1"; all="$l1,$l2,$l3"
        else
            scored="$(median3 "$l1" "$l2" "$l3")"; all="$l1,$l2,$l3"
            s1="$(awk "BEGIN{printf \"%.2f\", ($s1+$s2+$s3)/3}")"
            v1="$(awk "BEGIN{printf \"%.2f\", ($v1+$v2+$v3)/3}")"
        fi
        reps=3
    fi

    clean=no
    if [[ "$scored" == "-1" ]]; then
        clean=NO_MEASUREMENT
    elif awk "BEGIN{exit !($scored <= $CLEAN_PCT)}"; then
        clean=yes; best_clean="$r"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "$reps" "$scored" "$all" "$s1" "$v1" "$clean" \
        >> "$OUT/ladder.tsv"
    printf '  %5s M/flow  reps %s  loss %8s%%  agg_sent %8s  agg_recv %8s  clean=%s\n' \
        "$r" "$reps" "$scored" "$s1" "$v1" "$clean"

    # Saturated well past any plausible clean rung: stop climbing, and say so rather than
    # letting a silent truncation read as "the ladder was walked".
    if [[ "$scored" != "-1" ]] && awk "BEGIN{exit !($scored > $SAT_STOP_PCT)}"; then
        hot_streak=$((hot_streak + 1))
        if (( hot_streak >= 2 )); then
            truncated="$r"
            echo "  ⚠️  two consecutive rungs above ${SAT_STOP_PCT}% loss -- stopping the climb at ${r}M."
            echo "     Rungs above ${r}M were NOT measured; the highest clean rung is already below."
            break
        fi
    else
        hot_streak=0
    fi
done

# -------------------------------------------------- AMENDMENT-2 11.1(b): confirm the top rung
# An exact 0.0000% read and a 0.5006% read have both come from 160 M/flow, so a single zero does
# not establish that a rung's median is under the threshold. That only changes the answer at the
# highest clean rung -- a rung wrongly called clean lower down is superseded by a higher one. So
# the reported rung, and only it, is re-confirmed at three reps.
confirm_log=""
while [[ -n "$best_clean" ]]; do
    read -r c1 cs1 cv1 ck1 <<<"$(run_rep "$best_clean" c1)"
    read -r c2 cs2 cv2 ck2 <<<"$(run_rep "$best_clean" c2)"
    read -r c3 cs3 cv3 ck3 <<<"$(run_rep "$best_clean" c3)"
    if [[ "$c1" == "-1" || "$c2" == "-1" || "$c3" == "-1" ]]; then
        echo "  🔴 confirmation of ${best_clean}M produced no measurement -- not silently accepting it"
        confirm_log="${confirm_log}${best_clean}:NO_MEASUREMENT "
        best_clean=""; break
    fi
    cmed="$(median3 "$c1" "$c2" "$c3")"
    confirm_log="${confirm_log}${best_clean}:${c1},${c2},${c3}=>${cmed} "
    if awk "BEGIN{exit !($cmed <= $CLEAN_PCT)}"; then
        echo "  ✅ confirmed ${best_clean}M  reps ${c1},${c2},${c3}  median ${cmed}% <= ${CLEAN_PCT}%"
        break
    fi
    echo "  ⚠️  ${best_clean}M FAILED confirmation (median ${cmed}% > ${CLEAN_PCT}%) -- walking down"
    prev=""
    for r in $RATES; do
        [[ "$r" == "$best_clean" ]] && break
        awk -v a="$r" -v b="$best_clean" 'BEGIN{exit !(a<b)}' && \
          grep -q "^$r	.*	yes$" "$OUT/ladder.tsv" && prev="$r"
    done
    best_clean="$prev"
done

snap after
kill $SAMPLER 2>/dev/null

# ---------------------------------------------------------------- the arm's answer
{
  echo "highest_clean_per_flow_mbit=${best_clean:-none}"
  if [[ -n "$best_clean" ]]; then
      echo "aggregate_clean_mbit=$(awk "BEGIN{printf \"%.1f\", $best_clean * $N}")"
  else
      echo "aggregate_clean_mbit=none"
  fi
  echo "ladder_truncated_at=${truncated:-not-truncated}"
  echo "top_rung_confirmation=${confirm_log:-none}"
  echo "kernel_sha256_end=$(sha256sum "$REPO/build/bin/ndtwin_kernel" 2>/dev/null | cut -c1-8)"
  echo "finished=$(date '+%F %T %z')"
  # AMENDMENT-2 section 11.2: the gate is the in-window busy fraction from /proc/stat deltas.
  # load1 is recorded as a coarse pre-screen only -- on a 14-core box it counts D-state and decays
  # over a minute, so it is both lagging and composite, and it rises when the arm works correctly.
  awk 'NR==1{b0=$3; i0=$4} {if($2>m)m=$2; b=$3; i=$4}
       END{db=b-b0; di=i-i0;
           printf "busy_fraction=%.4f\nload1_max=%.2f  # pre-screen only, not a gate\nsamples=%d\n",
                  (db+di>0 ? db/(db+di) : -1), m, NR}' "$OUT/load_${ARM}.tsv" 2>/dev/null
} >> "$OUT/arm.meta"

BF=$(awk 'NR==1{b0=$3;i0=$4} {b=$3;i=$4} END{db=b-b0;di=i-i0; printf "%.4f", (db+di>0?db/(db+di):-1)}' \
      "$OUT/load_${ARM}.tsv" 2>/dev/null)
echo "### $ARM done  highest clean ${best_clean:-none} M/flow  =>  aggregate $(awk "BEGIN{printf \"%.1f\", ${best_clean:-0} * $N}") Mbit"
echo "### busy_fraction $BF  (gate: rerun if > median arm + 0.15 absolute -- decided across arms, not here)"
