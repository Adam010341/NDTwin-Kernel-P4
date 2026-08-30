#!/usr/bin/env bash
# One arm of the OvS flow-count CONTROL. Adapted from ③'s run_flowcount_arm.sh — design is
# PREREG.md in THIS directory; the bmv2 original's design notes still apply. Functional deltas
# from the original (PREREG §5, all four): (a) host pair parameterised (h1->h33 default);
# (b) provenance block swapped to OVS identity (the bmv2 symbol/argv lines are meaningless here);
# (c) snap() covers ALL switches (ECMP spread accounting, PREREG §4.2); (d) load sampler grows a
# softirq column (kernel datapath cost is invisible to per-process attribution, PREREG §4.5).
# Ladder / clean rule / 3-rep median / top-rung confirmation / saturation stop: verbatim from ③.
#
# Usage: NDT_OWNER="..." RATES="..." ./run_ovs_arm.sh <n_flows> <arm_label> [outdir]
# [Co-developed with claude code -- Adam]
set -uo pipefail

N="${1:?usage: run_ovs_arm.sh <n_flows> <arm_label> [outdir]}"
ARM="${2:?arm label, e.g. ovs_n4_a}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
OUT="${3:-$HERE/raw/$ARM}"; mkdir -p "$OUT"

STEP_S="${STEP_S:-8}"
CLEAN_PCT="${CLEAN_PCT:-0.5}"
AMB_HI="${AMB_HI:-2.0}"
RATES="${RATES:?per-flow Mbit ladder, gate-capped by the driver (PREREG §3)}"
SAT_STOP_PCT="${SAT_STOP_PCT:-25}"

C="${SRC_HOST:-h1}"; S="${DST_HOST:-h33}"
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
  echo "plane=ovs (as-wired: Ryu + kernel datapath; shaping state = testbed_topo sha below)"
  echo "n_flows=$N"
  echo "started=$(date '+%F %T %z')"
  echo "ladder=$RATES"
  echo "step_s=$STEP_S"
  echo "clean_pct=$CLEAN_PCT"
  echo "rep_rule=nonzero-to-${AMB_HI}pct => 3 reps median; exact 0.0000 => 1 rep (③ AMENDMENT-2 11.1, inherited)"
  echo "host_pair=${C}->${S} (${SIP}), distinguished by port"
  echo "ovs_version=$(ovs-vsctl --version 2>/dev/null | head -1)"
  echo "ovs_kmod=$(modinfo -F version openvswitch 2>/dev/null || echo unknown)"
  echo "bridges=$(sudo -n ovs-vsctl list-br 2>/dev/null | tr '\n' ' ')"
  echo "controller=$(ps -eo args | grep -E 'ryu|ryu-manager' | grep -v grep | head -1 || echo none-visible)"
  echo "port8080=$(ss -ltn 2>/dev/null | grep -c ':8080 ')"
  echo "topology_sha=$(sha256sum "$REPO/setting/StaticNetworkTopologyOVS_10Switches_64Hosts.json" | cut -c1-8)"
  echo "testbed_topo_sha=$(sha256sum "$REPO/testbed_topo.py" | cut -c1-8)"
  echo "kernel_sha256_start=$(sha256sum "$REPO/build/bin/ndtwin_kernel" 2>/dev/null | cut -c1-8)"
} > "$OUT/arm.meta"

# ---------------------------------------------------------------- load sampler (+softirq column)
( while :; do
    printf '%s %s %s %s\n' "$(date +%s)" "$(cut -d' ' -f1 /proc/loadavg)" \
      "$(awk '/^cpu /{print $2+$3+$4+$6+$7+$8, $5}' /proc/stat)" \
      "$(awk '/^cpu /{print $8}' /proc/stat)"
    sleep 2
  done ) > "$OUT/load_${ARM}.tsv" 2>/dev/null &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null' EXIT

# ---------------------------------------------------------------- counters: ALL switches (ECMP spread)
snap() {  # $1 = tag
  grep -E 's[0-9]+-eth' /proc/net/dev > "$OUT/netdev_$1.txt" 2>/dev/null
  sudo -n tc -s qdisc show                > "$OUT/tcqdisc_$1.txt" 2>&1
  sudo -n mnexec -a "$SP" cat /proc/net/snmp | grep -A1 '^Udp:' > "$OUT/snmp_recv_$1.txt" 2>&1
}
snap before

# ---------------------------------------------------------------- one rep = n concurrent flows
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
  wait
  python3 - "$N" "$OUT" "$rate" "$rep" <<'PY'
import json, sys, os
n, out, rate, rep = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
losses, sent, recv, ok = [], 0.0, 0.0, 0
for i in range(n):
    p = os.path.join(out, f"r{rate}M_rep{rep}_f{i}.json")
    try:
        e = json.load(open(p))["end"]
        s, r = e["sum_sent"], e["sum_received"]   # never end.sum — see ③ runner header
        losses.append(float(r.get("lost_percent", 0.0)))
        sent += s["bits_per_second"] / 1e6
        recv += r["bits_per_second"] / 1e6
        ok += 1
    except Exception:
        losses.append(None)
if ok != n or any(l is None for l in losses):
    print(f"-1 -1 -1 {ok}")
else:
    print(f"{max(losses):.4f} {sent:.2f} {recv:.2f} {ok}")
PY
}

median3() { printf '%s\n' "$1" "$2" "$3" | sort -g | sed -n 2p; }

# ---------------------------------------------------------------- the ladder (verbatim ③ logic)
echo "### OVS arm $ARM  n=$N  $C->$S  step ${STEP_S}s  clean<=${CLEAN_PCT}%  $(date '+%H:%M:%S')"
printf 'rate_mbit\treps\tloss_scored\tloss_reps\tagg_sent\tagg_recv\tclean\n' > "$OUT/ladder.tsv"

best_clean=""; hot_streak=0; truncated=""
for r in $RATES; do
    read -r l1 s1 v1 k1 <<<"$(run_rep "$r" 1)"
    scored="$l1"; reps=1; all="$l1"

    if [[ "$l1" != "-1" ]] && awk "BEGIN{exit !($l1 > 0 && $l1 <= $AMB_HI)}"; then
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

# -------------------------------------------------- top-rung confirmation (verbatim ③ logic)
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
  echo "ladder_top_offered=$(echo $RATES | awk '{print $NF}')  # gate-capped by driver; if == highest_clean, cell is right-censored"
  echo "top_rung_confirmation=${confirm_log:-none}"
  echo "kernel_sha256_end=$(sha256sum "$REPO/build/bin/ndtwin_kernel" 2>/dev/null | cut -c1-8)"
  echo "finished=$(date '+%F %T %z')"
  awk 'NR==1{b0=$3; i0=$4; s0=$5} {if($2>m)m=$2; b=$3; i=$4; s=$5}
       END{db=b-b0; di=i-i0; ds=s-s0;
           printf "busy_fraction=%.4f\nsoftirq_ticks=%d  # kernel datapath cost lives here, not in any process\nload1_max=%.2f  # pre-screen only\nsamples=%d\n",
                  (db+di>0 ? db/(db+di) : -1), ds, m, NR}' "$OUT/load_${ARM}.tsv" 2>/dev/null
} >> "$OUT/arm.meta"

BF=$(awk 'NR==1{b0=$3;i0=$4} {b=$3;i=$4} END{db=b-b0;di=i-i0; printf "%.4f", (db+di>0?db/(db+di):-1)}' \
      "$OUT/load_${ARM}.tsv" 2>/dev/null)
echo "### $ARM done  highest clean ${best_clean:-none} M/flow  =>  aggregate $(awk "BEGIN{printf \"%.1f\", ${best_clean:-0} * $N}") Mbit"
echo "### busy_fraction $BF  softirq recorded  (no validated foreign-load gate this round -- PREREG §4.5)"
