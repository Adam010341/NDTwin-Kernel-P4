#!/usr/bin/env bash
# One arm of ②: bmv2's clean forwarding rate at a fixed Ethernet frame size.
#
# Design is PREREG.md; read that first. The parts that are easy to get wrong:
#
#   * FRAME size, not payload. iperf3 -l is UDP payload; frame = payload + 42 (14 Ethernet + 20 IP
#     + 8 UDP). 64/256/1024 B frames are -l 22/214/982. At 64 B, confusing the two is a 66% error,
#     and 08-15's "64 B" row never says which convention it used -- so it may not be reconciled
#     against this round until that is settled from its raw. PREREG section 2.
#
#   * pps is read from delivered datagrams and duration. Never back-derived from a bps figure and
#     a nominal size: that would compute the answer from the assumption. PREREG section 5.
#
#   * The requested rate is set as -b (pps * payload * 8) because iperf3's -b is an application
#     bitrate. The REQUESTED pps is not the measured pps and is never reported as such.
#
#   * The load gate is on FOREIGN CPU, not total. Total busy is dominated by the arm's own
#     forwarding, and at 64 B that is maximal -- gating on total would demand a rerun of exactly
#     the arms carrying the headline, forever. AMENDMENT-1 section 7.2.
#
#   * CPU attribution enumerates processes by exact `comm`, never by a pattern over argv: a
#     pattern matches this script's own command line. `ps -eo pid,comm=` cannot self-match because
#     this script's comm is `bash`.
#
# Usage: NDT_OWNER="..." ./run_size_arm.sh <frame_bytes> <arm_label> [outdir]
# [Co-developed with claude code -- Adam]
set -uo pipefail

FRAME="${1:?usage: run_size_arm.sh <frame_bytes: 64|256|1024> <arm_label> [outdir]}"
ARM="${2:?arm label}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
OUT="${3:-$HERE/raw/$ARM}"; mkdir -p "$OUT"

PAYLOAD=$((FRAME - 42))
(( PAYLOAD > 0 )) || { echo "🔴 frame $FRAME too small (payload would be $PAYLOAD)"; exit 1; }

STEP_S="${STEP_S:-8}"
CLEAN_PCT="${CLEAN_PCT:-0.5}"
AMB_HI="${AMB_HI:-2.0}"
RATES_KPPS="${RATES_KPPS:-1 2 3 5 8 12 20 30 45 70 110 160 240}"   # PREREG 7.5
SAT_STOP_PCT="${SAT_STOP_PCT:-25}"
BURNERS="${BURNERS:-0}"        # positive control only: start N CPU burners partway through

C=h1; S=h65
SIP="10.0.0.${S#h}"

owner="$(sed -n 's/^owner=//p' "$REPO/.test_run/lab.claim" 2>/dev/null)"
[[ -n "${NDT_OWNER:-}" ]] || { echo "🔴 NDT_OWNER unset"; exit 1; }
[[ "$owner" == "$NDT_OWNER" ]] || { echo "🔴 lab.claim owner='$owner' != NDT_OWNER='$NDT_OWNER'"; exit 1; }

host_pid() { ps -eo pid,args | awk -v h="mininet:$1" '$NF==h{print $1; exit}'; }
CP=$(host_pid "$C"); SP=$(host_pid "$S")
[[ -n "$CP" && -n "$SP" ]] || { echo "🔴 host namespaces missing: $C=$CP $S=$SP"; exit 1; }

# bmv2 PIDs, enumerated once and recorded, so the attribution set is auditable after the fact.
mapfile -t SWPIDS < <(ps -eo pid,comm= | awk '$2 ~ /^simple_switch/ {print $1}')
(( ${#SWPIDS[@]} > 0 )) || { echo "🔴 no simple_switch processes found"; exit 1; }

{
  echo "arm=$ARM"
  echo "frame_bytes=$FRAME"
  echo "payload_bytes=$PAYLOAD"
  echo "started=$(date '+%F %T %z')"
  echo "ladder_kpps=$RATES_KPPS"
  echo "step_s=$STEP_S"
  echo "clean_pct=$CLEAN_PCT"
  echo "rep_rule=nonzero-to-${AMB_HI}pct => 3 reps median; exact 0.0000 => 1 rep (3's AMENDMENT-2 11.1)"
  echo "host_pair=${C}->${S} (${SIP})"
  echo "kernel_sha256_start=$(sha256sum "$REPO/build/bin/ndtwin_kernel" 2>/dev/null | cut -c1-8)"
  echo "switch_binary=$(pgrep -af 'simple_switch_g[r]pc' | head -1 | grep -o '/usr/local/[^ ]*simple_switch_grpc' | head -1)"
  echo "switch_count=${#SWPIDS[@]}"
  echo "switch_pids=${SWPIDS[*]}"
  echo "burners=$BURNERS"
  echo "gate=external residual (AMENDMENT-1 7.2), not total busy"
} > "$OUT/arm.meta"

# -------------------------------------------------- AMENDMENT-1 7.2: foreign-residual sampler
# Each line: epoch  busy_jiffies  idle_jiffies  bmv2_jiffies  iperf3_cumulative_jiffies
#
# 🔴 iperf3 needs an ACCUMULATOR, not a snapshot sum. Every rep spawns fresh iperf3 processes that
# then exit, so "sum over currently-alive iperf3" returns to ~0 between reps and last-minus-first
# reads 0 -- caught in the smoke run, where iperf3_share printed 0.0000 while iperf3 had clearly
# burned CPU. Unaccounted generator cost lands in `external`, and it is LARGEST at 64 B (most
# packets per second), which is precisely the treatment. That would rebuild the bug this gate
# exists to remove.
#
# So: track per-PID last-seen jiffies and accumulate each PID's increments. A PID first seen with
# nonzero jiffies contributes all of them (it started at 0). Loss is bounded by whatever a process
# burns in its final sub-second before exiting.
#
# The sampler's own cost lands in `external`, unattributed. That is acceptable and deliberate: it
# is the same 1 Hz loop in every arm regardless of frame size, so it is a constant offset, and the
# gate is relative (vs the median arm), not absolute.
python3 - "$OUT/cpu_${ARM}.tsv" "${SWPIDS[*]}" > /dev/null 2>&1 <<'PY' &
import sys, time, os
path, swpids = sys.argv[1], sys.argv[2].split()
seen, accum = {}, 0
def jiff(p):
    try:
        with open(f"/proc/{p}/stat") as f:
            parts = f.read().rsplit(") ", 1)[1].split()
        return int(parts[11]) + int(parts[12])          # utime, stime
    except Exception:
        return None
with open(path, "w", buffering=1) as out:
    while True:
        with open("/proc/stat") as f:
            c = f.readline().split()
        busy = int(c[1]) + int(c[2]) + int(c[3]); idle = int(c[4])
        sw = sum(v for v in (jiff(p) for p in swpids) if v is not None)
        live = []
        for e in os.listdir("/proc"):
            if not e.isdigit():
                continue
            try:
                if open(f"/proc/{e}/comm").read().strip() == "iperf3":
                    live.append(e)
            except Exception:
                pass
        for p in live:
            v = jiff(p)
            if v is None:
                continue
            accum += v - seen.get(p, 0)
            seen[p] = v
        out.write(f"{int(time.time())} {busy} {idle} {sw} {accum}\n")
        time.sleep(1)
PY
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null; for b in ${BURNER_PIDS:-}; do kill $b 2>/dev/null; done' EXIT

snap() {
  grep -E 's1-eth|s3-eth' /proc/net/dev > "$OUT/netdev_$1.txt" 2>/dev/null
}
snap before

run_rep() {   # $1 = kpps, $2 = rep label -> "<loss> <sent_pps> <recv_pps> <ok>"
    local kpps="$1" rep="$2" bps port
    bps=$(awk -v k="$kpps" -v l="$PAYLOAD" 'BEGIN{printf "%d", k*1000*l*8}')
    port=$((5401 + (RANDOM % 150)))
    sudo -n mnexec -a "$SP" iperf3 -s -1 --daemon -p "$port" >/dev/null 2>&1
    sleep 1
    sudo -n mnexec -a "$CP" iperf3 -c "$SIP" -p "$port" -u -b "$bps" \
        -t "$STEP_S" -l "$PAYLOAD" --json > "$OUT/k${kpps}_rep${rep}.json" 2>&1
    python3 - "$OUT/k${kpps}_rep${rep}.json" <<'PY'
import json, sys
try:
    e = json.load(open(sys.argv[1]))["end"]
    s, r = e["sum_sent"], e["sum_received"]
    # pps from packets and seconds -- NOT from bits_per_second / (size*8).
    sp = s["packets"] / s["seconds"]
    rp = r["packets"] / r["seconds"]
    print(f"{float(r.get('lost_percent', 0.0)):.4f} {sp:.1f} {rp:.1f} 1")
except Exception:
    print("-1 -1 -1 0")     # no measurement is not a low-loss reading
PY
}

median3() { printf '%s\n' "$1" "$2" "$3" | sort -g | sed -n 2p; }

echo "### 2 arm $ARM  frame ${FRAME}B (payload $PAYLOAD)  $C->$S  step ${STEP_S}s  $(date '+%H:%M:%S')"
printf 'kpps_offered\treps\tloss_scored\tloss_reps\tsent_pps\trecv_pps\tclean\n' > "$OUT/ladder.tsv"

BURNER_PIDS=""
best_clean=""; hot=0; rung_i=0
for k in $RATES_KPPS; do
    rung_i=$((rung_i + 1))
    # positive control: burners start partway through, so `external` must visibly step up
    if (( BURNERS > 0 )) && (( rung_i == 4 )) && [[ -z "$BURNER_PIDS" ]]; then
        echo "  ⚡ starting $BURNERS CPU burner(s) -- positive control for the external gate"
        for ((b=0; b<BURNERS; b++)); do
            ( while :; do :; done ) & BURNER_PIDS="$BURNER_PIDS $!"
        done
    fi

    read -r l1 s1 v1 k1 <<<"$(run_rep "$k" 1)"
    scored="$l1"; reps=1; all="$l1"
    if [[ "$l1" != "-1" ]] && awk "BEGIN{exit !($l1 > 0 && $l1 <= $AMB_HI)}"; then
        read -r l2 s2 v2 k2 <<<"$(run_rep "$k" 2)"
        read -r l3 s3 v3 k3 <<<"$(run_rep "$k" 3)"
        if [[ "$l2" == "-1" || "$l3" == "-1" ]]; then scored="-1"; all="$l1,$l2,$l3"
        else
            scored="$(median3 "$l1" "$l2" "$l3")"; all="$l1,$l2,$l3"
            s1="$(awk "BEGIN{printf \"%.1f\", ($s1+$s2+$s3)/3}")"
            v1="$(awk "BEGIN{printf \"%.1f\", ($v1+$v2+$v3)/3}")"
        fi
        reps=3
    fi

    clean=no
    if [[ "$scored" == "-1" ]]; then clean=NO_MEASUREMENT
    elif awk "BEGIN{exit !($scored <= $CLEAN_PCT)}"; then clean=yes; best_clean="$k"; fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$k" "$reps" "$scored" "$all" "$s1" "$v1" "$clean" >> "$OUT/ladder.tsv"
    printf '  %5s kpps  reps %s  loss %8s%%  sent %9s pps  recv %9s pps  clean=%s\n' \
        "$k" "$reps" "$scored" "$s1" "$v1" "$clean"

    if [[ "$scored" != "-1" ]] && awk "BEGIN{exit !($scored > $SAT_STOP_PCT)}"; then
        hot=$((hot + 1))
        if (( hot >= 2 )); then
            echo "  ⚠️  two consecutive rungs above ${SAT_STOP_PCT}% -- stopping the climb at ${k} kpps."
            echo "     Rungs above ${k} kpps were NOT measured; the highest clean rung is already below."
            echo "ladder_truncated_at=$k" >> "$OUT/arm.meta"; break
        fi
    else hot=0; fi
done
grep -q '^ladder_truncated_at=' "$OUT/arm.meta" || echo "ladder_truncated_at=not-truncated" >> "$OUT/arm.meta"

# top-rung re-confirmation, 3's AMENDMENT-2 11.1(b), with walk-down
confirm=""
while [[ -n "$best_clean" ]]; do
    read -r c1 _ _ _ <<<"$(run_rep "$best_clean" c1)"
    read -r c2 _ _ _ <<<"$(run_rep "$best_clean" c2)"
    read -r c3 _ _ _ <<<"$(run_rep "$best_clean" c3)"
    if [[ "$c1" == "-1" || "$c2" == "-1" || "$c3" == "-1" ]]; then
        echo "  🔴 confirmation of ${best_clean} kpps produced no measurement"
        confirm="${confirm}${best_clean}:NO_MEASUREMENT "; break
    fi
    cmed="$(median3 "$c1" "$c2" "$c3")"
    confirm="${confirm}${best_clean}:${c1},${c2},${c3}=>${cmed} "
    if awk "BEGIN{exit !($cmed <= $CLEAN_PCT)}"; then
        echo "  ✅ confirmed ${best_clean} kpps  reps $c1,$c2,$c3  median ${cmed}% <= ${CLEAN_PCT}%"; break
    fi
    echo "  ⚠️  ${best_clean} kpps FAILED confirmation (median ${cmed}% > ${CLEAN_PCT}%) -- walking down"
    best_clean="$(awk -F'\t' -v cur="$best_clean" '$7=="yes" && $1+0 < cur+0 {b=$1} END{print b}' "$OUT/ladder.tsv")"
done

snap after
for b in $BURNER_PIDS; do kill "$b" 2>/dev/null; done

{
  echo "highest_clean_kpps=${best_clean:-none}"
  echo "top_rung_confirmation=$confirm"
  echo "kernel_sha256_end=$(sha256sum "$REPO/build/bin/ndtwin_kernel" 2>/dev/null | cut -c1-8)"
  echo "finished=$(date '+%F %T %z')"
} >> "$OUT/arm.meta"

# ---- the gate quantity, AMENDMENT-1 7.2 --------------------------------------------------
awk 'NR==1{b0=$2;i0=$3;s0=$4;p0=$5}
     {b=$2;i=$3;s=$4;p=$5}
     END{db=b-b0; di=i-i0; ds=s-s0; dp=p-p0; tot=db+di;
         if (tot<=0) {print "external=-1  # no samples"; exit}
         printf "total_busy=%.4f\nbmv2_share=%.4f\niperf3_share=%.4f\nexternal=%.4f\nsamples=%d\n",
                db/tot, ds/tot, dp/tot, (db-ds-dp)/tot, NR}' "$OUT/cpu_${ARM}.tsv" >> "$OUT/arm.meta"
tail -5 "$OUT/arm.meta" | sed 's/^/### /'
