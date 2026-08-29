#!/usr/bin/env bash
# One arm of 1: bmv2's UDP zero-loss point on ONE HOP, for one build.
#
# Design is PREREG.md; read that first. The parts that are easy to get wrong:
#
#   * ONE HOP, h1 -> h2, both attached to s1. Verified by counters, not by host numbering or by
#     the topology JSON (which gives every host dpid 0 and cannot answer it): a 20 Mbit probe moved
#     s1-eth3 RX and s1-eth4 TX by 7157 packets each and NO interface on any other switch.
#     AMENDMENT-1 8.1. Re-verified after every fabric restart, because `ndt up` rebuilds it.
#
#   * The readout is the UDP ZERO-LOSS POINT at 1400 B payload, because that is the one metric
#     08-15's "12x" row was measured on. "12-18x" is a range across DIFFERENT metrics, not a
#     confidence interval; comparing against the whole range would let almost any result agree.
#     PREREG section 2.
#
#   * The load gate is on FOREIGN CPU, not total. Total busy is dominated by the arm's own
#     forwarding, and the fast build forwards far more per second -- gating on total would demand
#     a rerun of every fast arm, i.e. the half that carries the effect. AMENDMENT-1 8.3.
#
#   * Build identity is asserted by SYMBOL in BOTH directions at every arm, never by PATH and
#     never inherited across a fabric restart.
#
#   * CPU attribution enumerates processes by exact `comm`, never by a pattern over argv: a
#     pattern matches this script's own command line. `ps -eo pid,comm=` cannot self-match because
#     this script's comm is `bash`.
#
# Usage: NDT_OWNER="..." ./run_build_arm.sh <fast|stock> <arm_label> [outdir]
# [Co-developed with claude code -- Adam]
set -uo pipefail

BUILD="${1:?usage: run_build_arm.sh <fast|stock> <arm_label> [outdir]}"
ARM="${2:?arm label}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
OUT="${3:-$HERE/raw/$ARM}"; mkdir -p "$OUT"

PAYLOAD=1400          # 08-15's 12x row is the UDP zero-loss point at 1400 B; same payload here

STEP_S="${STEP_S:-8}"
CLEAN_PCT="${CLEAN_PCT:-0.5}"
AMB_HI="${AMB_HI:-2.0}"
RATES_MBIT="${RATES_MBIT:-1 2 3 5 8 12 20 30 45 70 110 160 240 360}"   # PREREG section 3
SAT_STOP_PCT="${SAT_STOP_PCT:-25}"
BURNERS="${BURNERS:-0}"        # positive control only: start N CPU burners partway through

C=h1; S=h2            # one hop, verified by counters (AMENDMENT-1 8.1)
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

# ---------------------------------------------------------------- AMENDMENT-1 8.4: build identity
# The running binary is resolved from the process, never from PATH. Identity is asserted by SYMBOL
# in BOTH directions: `EventLogger` is absent from the fast build (--disable-elogger) and present
# in stock, so each binary is the other's negative control. A one-directional check cannot tell
# "the signature matched" from "my grep is broken".
#
# 🔴 The negative control named in section 3 (`3367d0e9`) is an ndtwin_kernel binary answering a
# KERNEL symbol. It cannot test which bmv2 build is running. It is still run and recorded, as a
# control for the kernel identification that this meta also carries. See AMENDMENT-1 8.4.
# 🔴 /proc/<pid>/exe is the kernel's own answer and cannot be spoofed, but the switches run as root
# and this uid has no passwordless sudo for readlink -- so it is NOT available. The next best
# source is the process's own argv, which is what the launcher actually exec'd. Recorded as such:
# argv is the launcher's claim, not kernel-verified provenance. The override file is read as an
# INDEPENDENT second source and the two must agree; disagreement aborts rather than picking one.
SWBIN="$(ps -o args= -p "${SWPIDS[0]}" | grep -o '/[^ ]*simple_switch_grpc' | head -1)"
OVERRIDE="$(grep -v '^[[:space:]]*#' "$REPO/p4_proxy/mininet/bmv2_binary_override" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1 | xargs)"
[[ -x "$SWBIN" ]] || { echo "🔴 cannot resolve running switch binary from argv of ${SWPIDS[0]}"; exit 1; }
[[ "$SWBIN" == "$OVERRIDE" ]] || { echo "🔴 argv says '$SWBIN' but bmv2_binary_override says '$OVERRIDE' -- refusing to guess"; exit 1; }
ELOG=$(nm -DC "$SWBIN" 2>/dev/null | grep -c EventLogger)
case "$BUILD" in
  fast)  (( ELOG == 0 )) || { echo "🔴 BUILD=fast but $SWBIN has $ELOG EventLogger symbols (stock signature)"; exit 1; } ;;
  stock) (( ELOG > 0 ))  || { echo "🔴 BUILD=stock but $SWBIN has 0 EventLogger symbols (fast signature)"; exit 1; } ;;
  *) echo "🔴 BUILD must be fast or stock, got '$BUILD'"; exit 1 ;;
esac
NEGCTL=$(nm -C "$REPO/.test_run/binaries/ndtwin_kernel.3367d0e9" 2>/dev/null | grep -c kFlowPathRecomputeInterval)
POSCTL=$(nm -C "$REPO/.test_run/binaries/ndtwin_kernel.a40e04ce" 2>/dev/null | grep -c kFlowPathRecomputeInterval)
echo "### build asserted: $BUILD  ($SWBIN, EventLogger=$ELOG)  kernel negctl=$NEGCTL posctl=$POSCTL"

{
  echo "arm=$ARM"
  echo "build=$BUILD"
  echo "switch_binary_resolved=$SWBIN  # from argv (launcher's claim); /proc/exe needs root, see AMENDMENT-1 8.5"
  echo "switch_binary_override_agrees=$OVERRIDE"
  echo "switch_binary_sha256=$(sha256sum "$SWBIN" | cut -c1-8)"
  echo "build_signature_EventLogger=$ELOG  # fast=0 stock>0 (--disable-elogger); both directions asserted"
  echo "kernel_negctl_3367d0e9_hits=$NEGCTL  # must be 0"
  echo "kernel_posctl_a40e04ce_hits=$POSCTL  # must be 5"
  echo "payload_bytes=$PAYLOAD"
  echo "started=$(date '+%F %T %z')"
  echo "ladder_mbit=$RATES_MBIT"
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
# is the same 1 Hz loop in every arm regardless of build, so it is a constant offset, and the
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

run_rep() {   # $1 = offered Mbit, $2 = rep label -> "<loss> <sent_pps> <recv_pps> <ok>"
    local mbit="$1" rep="$2" bps port
    bps="${mbit}M"
    port=$((5401 + (RANDOM % 150)))
    sudo -n mnexec -a "$SP" iperf3 -s -1 --daemon -p "$port" >/dev/null 2>&1
    sleep 1
    sudo -n mnexec -a "$CP" iperf3 -c "$SIP" -p "$port" -u -b "$bps" \
        -t "$STEP_S" -l "$PAYLOAD" --json > "$OUT/r${mbit}M_rep${rep}.json" 2>&1
    python3 - "$OUT/r${mbit}M_rep${rep}.json" <<'PY'
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

echo "### 1 arm $ARM  build=$BUILD  payload ${PAYLOAD}B  $C->$S (one hop)  step ${STEP_S}s  $(date '+%H:%M:%S')"
printf 'rate_mbit\treps\tloss_scored\tloss_reps\tsent_pps\trecv_pps\tclean\n' > "$OUT/ladder.tsv"

# ---------------------------------------------------------------- ladder generation
# RATES_MBIT=AUTO is ①b: the ladder has NO FIXED TOP. It climbs x1.5 (rounded to two significant
# figures, which is what the original hand-written sequence already was) and stops ONLY when the
# registered saturation rule fires.
#
# 🔴 Why it must be a rule and not a number. ① ended with both fast arms clean at 360 M -- the top
# rung -- so R = 8.0 was the largest value the instrument could emit, not a measurement. Lengthening
# the ladder can only move R UPWARD, i.e. toward "this build really is 12x faster", which is the
# more publishable direction. If a person picked the new top, that person could pick where R lands.
# Nobody picks it here: the climb ends where loss ends it.
#
# RUNAWAY_MAX is a bug backstop, not a design choice. If it ever fires, the arm says so loudly and
# the result must not be read as a saturation point.
RUNAWAY_MAX="${RUNAWAY_MAX:-40}"
next_rung() { awk -v p="$1" 'BEGIN{
    v = p * 1.5; e = int(log(v)/log(10)); s = 10 ^ (e - 1); printf "%d", int(v / s + 0.5) * s }'; }

# AUTO = ①'s REGISTERED rungs verbatim, then keep going x1.5 past the top until the rule stops it.
# The registered lower rungs are not regenerated -- they are the pre-registered ladder and stay
# byte-identical. Only the extension above 360 M is rule-driven, and that is the part ① never had.
BASE_LADDER="1 2 3 5 8 12 20 30 45 70 110 160 240 360"
if [[ "$RATES_MBIT" == "AUTO" ]]; then
    PENDING="$BASE_LADDER"
    LADDER_MODE="auto: registered rungs then x1.5 with NO fixed top; ends only at the saturation rule"
else
    PENDING="$RATES_MBIT"
    LADDER_MODE="fixed: $RATES_MBIT"
fi
echo "ladder_mode=$LADDER_MODE" >> "$OUT/arm.meta"

BURNER_PIDS=""
best_clean=""; hot=0; rung_i=0; last_k=""
while :; do
    read -r k rest <<<"$PENDING"
    if [[ -z "$k" ]]; then
        [[ "$RATES_MBIT" == "AUTO" ]] || break          # fixed ladder: exhausted, done
        k="$(next_rung "$last_k")"                      # AUTO: rule generates the next rung
        rest=""
        (( rung_i >= RUNAWAY_MAX )) && {
            echo "  🔴 RUNAWAY GUARD at rung $rung_i (${k} M) -- the saturation rule never fired."
            echo "     This is an instrument bug. The highest clean rung below is NOT a saturation point."
            echo "ladder_truncated_at=RUNAWAY_GUARD_${k}" >> "$OUT/arm.meta"; break; }
    fi
    PENDING="$rest"; last_k="$k"
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
    printf '  %5s M     reps %s  loss %8s%%  sent %9s pps  recv %9s pps  clean=%s\n' \
        "$k" "$reps" "$scored" "$s1" "$v1" "$clean"

    if [[ "$scored" != "-1" ]] && awk "BEGIN{exit !($scored > $SAT_STOP_PCT)}"; then
        hot=$((hot + 1))
        if (( hot >= 2 )); then
            echo "  ⚠️  two consecutive rungs above ${SAT_STOP_PCT}% -- stopping the climb at ${k} M."
            echo "     Rungs above ${k} M were NOT measured; the highest clean rung is already below."
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
        echo "  🔴 confirmation of ${best_clean} M produced no measurement"
        confirm="${confirm}${best_clean}:NO_MEASUREMENT "; break
    fi
    cmed="$(median3 "$c1" "$c2" "$c3")"
    confirm="${confirm}${best_clean}:${c1},${c2},${c3}=>${cmed} "
    if awk "BEGIN{exit !($cmed <= $CLEAN_PCT)}"; then
        echo "  ✅ confirmed ${best_clean} M  reps $c1,$c2,$c3  median ${cmed}% <= ${CLEAN_PCT}%"; break
    fi
    echo "  ⚠️  ${best_clean} M FAILED confirmation (median ${cmed}% > ${CLEAN_PCT}%) -- walking down"
    best_clean="$(awk -F'\t' -v cur="$best_clean" '$7=="yes" && $1+0 < cur+0 {b=$1} END{print b}' "$OUT/ladder.tsv")"
done

snap after
for b in $BURNER_PIDS; do kill "$b" 2>/dev/null; done

{
  echo "highest_clean_mbit=${best_clean:-none}"
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
