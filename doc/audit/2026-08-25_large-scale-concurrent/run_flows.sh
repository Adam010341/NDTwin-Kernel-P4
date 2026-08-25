#!/usr/bin/env bash
# 64 concurrent UDP flows across all 128 hosts, laid out so every one of the ten switches
# carries load.
#
# WHY UDP AT A FIXED RATE. The question is telemetry accuracy, not throughput. TCP would
# rate-adapt to whatever the fabric allows, so the offered load would become an unknown and
# every reconciliation ratio would carry it. `-b <rate>` makes offered load a constant this
# script chooses, which is what lets a ratio mean something.
#
# WHY THIS PAIRING. A single flow h1->h33 crosses s1 -> {s5|s6} -> s2: three of ten switches,
# which is why every prior 128-host measurement left seven switches unmodelled under load.
#   pod A = s1(h1-32) + s2(h33-64)      pod B = s3(h65-96) + s4(h97-128)
#   32 cross-pod flows  (A -> B)  force the spine, s9/s10  -- five switches each
#   32 same-pod flows   (s1->s2, s3->s4)                   -- three switches each
# Every host is used exactly once, as a client or a server, never both.
#
# RATE LADDER, deliberately spanning F-9's threshold: 8 flows at 1 Mbit/s sit BELOW the ~3
# Mbit/s the twin quantises to zero, 48 at 5 and 8 at 20 sit above it. If F-9 is real at this
# scale, those eight edges read zero against real bytes on the veth.
#
# Usage: run_flows.sh <outdir> <flow_seconds>
# [Co-developed with claude code -- Adam]
set -uo pipefail
OUT="${1:?outdir}"; DUR="${2:?flow seconds}"
# Absolutised: iperf3 runs under `sudo mnexec`, and a relative --logfile path there fails to
# create the file, so the server never starts and the guard below reports 0/64 with no other
# clue. Cost me a run on 2026-08-25 when I called this directly instead of via run_plane.sh.
mkdir -p "$OUT/iperf"
OUT="$(cd "$OUT" && pwd)"

host_pid() {
    # "mininet:<host>" with $NF, so h1 does not match h12 the way a substring grep would.
    ps -eo pid,args | awk -v h="mininet:$1" '$NF==h{print $1; exit}'
}

# --- the pairing, written out rather than computed, so it can be read and checked -----------
CLIENTS=(); SERVERS=()
for i in $(seq 0 15); do CLIENTS+=("h$((1+i))");  SERVERS+=("h$((65+i))");  done   # s1 -> s3
for i in $(seq 0 15); do CLIENTS+=("h$((33+i))"); SERVERS+=("h$((97+i))");  done   # s2 -> s4
for i in $(seq 0 15); do CLIENTS+=("h$((17+i))"); SERVERS+=("h$((49+i))");  done   # s1 -> s2
for i in $(seq 0 15); do CLIENTS+=("h$((81+i))"); SERVERS+=("h$((113+i))"); done   # s3 -> s4

# RATE_SCALE multiplies every rung. The ladder's SHAPE (one rung below F-9's ~3 Mbit/s
# threshold, one well above) is what the pre-registration depends on, so it scales rather than
# being replaced -- at scale 0.25 the 20/5/1 ladder becomes 5/1.25/0.25 and the threshold still
# falls inside it.
RATE_SCALE="${RATE_SCALE:-1}"
rate_for() {
    local base
    case $(( $1 % 8 )) in 0) base=20;; 4) base=1;; *) base=5;; esac
    python3 -c "print(f'{$base * $RATE_SCALE:g}')"
}

# FLOW_LIMIT keeps every Kth pair rather than the first K, so all four path types (s1->s3,
# s2->s4, s1->s2, s3->s4) stay represented at any flow count. Taking a prefix would have
# dropped whole path classes and made a flow-count sweep unreadable.
FLOW_LIMIT="${FLOW_LIMIT:-0}"
if [ "$FLOW_LIMIT" -gt 0 ] && [ "$FLOW_LIMIT" -lt "${#CLIENTS[@]}" ]; then
    step=$(( ${#CLIENTS[@]} / FLOW_LIMIT ))
    KC=(); KS=()
    for i in $(seq 0 $((FLOW_LIMIT-1))); do
        KC+=("${CLIENTS[$((i*step))]}"); KS+=("${SERVERS[$((i*step))]}")
    done
    CLIENTS=("${KC[@]}"); SERVERS=("${KS[@]}")
fi

N=${#CLIENTS[@]}
echo "flows: $N   duration: ${DUR}s"

# --- resolve every pid up front; a missing host must stop the run, not skip a flow ----------
declare -A PID
missing=0
for h in "${CLIENTS[@]}" "${SERVERS[@]}"; do
    p=$(host_pid "$h")
    if [ -z "$p" ]; then echo "  MISSING host ns: $h" >&2; missing=$((missing+1)); else PID[$h]=$p; fi
done
if [ "$missing" -gt 0 ]; then
    echo "FATAL: $missing of $(( N * 2 )) host namespaces absent -- the fabric is not what this expects" >&2
    exit 1
fi
echo "  all $(( N * 2 )) host namespaces resolved"

# --- clear stale servers. A leftover would accept a flow and make this measure something else.
for h in "${SERVERS[@]}"; do sudo -n mnexec -a "${PID[$h]}" pkill -f iperf3 >/dev/null 2>&1; done
for h in "${CLIENTS[@]}"; do sudo -n mnexec -a "${PID[$h]}" pkill -f iperf3 >/dev/null 2>&1; done
sleep 2

# --- servers ---------------------------------------------------------------------------------
for i in $(seq 0 $((N-1))); do
    s=${SERVERS[$i]}
    sudo -n mnexec -a "${PID[$s]}" iperf3 -s -1 --daemon \
        --logfile "$OUT/iperf/srv_${s}.log" >/dev/null 2>&1
done
sleep 3
# -x on the process NAME, not -f on the command line: `pgrep -f "iperf3 -s -1"` matches any
# shell whose argv contains that text, including the command doing the counting. Measured on
# 2026-08-25 with exactly one server running: -f said 2, -x said 1, ps said 1.
up=$(pgrep -c -x iperf3 || true)
echo "  servers listening: $up / $N"
if [ "$up" -lt "$N" ]; then
    echo "FATAL: only $up of $N servers came up; a client hitting a dead server logs an error and" >&2
    echo "       contributes no bytes, which would silently shrink the offered load." >&2
    exit 1
fi

# --- clients ---------------------------------------------------------------------------------
# --json so the client's own measured bitrate can be read back: a flow that ran at a different
# rate than requested, or not at all, must be visible per flow and not inferred from the total.
mapfile -t RATES < <(for i in $(seq 0 $((N-1))); do rate_for "$i"; done)
echo "  rate ladder: $(printf '%s\n' "${RATES[@]}" | sort -n | uniq -c | tr '\n' ' ')"

t0=$(date +%s.%N)
for i in $(seq 0 $((N-1))); do
    c=${CLIENTS[$i]}; s=${SERVERS[$i]}; r=${RATES[$i]}
    sip=$(printf '10.0.0.%d' "${s#h}")
    sudo -n mnexec -a "${PID[$c]}" iperf3 -c "$sip" -u -b "${r}M" -t "$DUR" -l 1400 --json \
        > "$OUT/iperf/cli_${c}_to_${s}_${r}M.json" 2>&1 &
done
echo "  $N clients launched at $t0; waiting ${DUR}s + drain"
wait
echo "  all clients returned at $(date +%s.%N)"

# --- report what actually ran, per flow ------------------------------------------------------
python3 - "$OUT/iperf" <<'PY'
import glob, json, os, sys
d = sys.argv[1]
ok = bad = 0; total = 0.0
for p in sorted(glob.glob(os.path.join(d, "cli_*.json"))):
    try:
        j = json.load(open(p))
        bps = j["end"]["sum"]["bits_per_second"]
        lost = j["end"]["sum"].get("lost_percent", 0.0)
    except Exception as e:
        # iperf3 writes {"error": "..."} INSTEAD of a result, so the reason is in the file and
        # must be quoted rather than reduced to "KeyError" -- a control-socket failure and a
        # malformed file are different problems with different fixes.
        try:
            err = json.load(open(p)).get("error", f"unparseable ({type(e).__name__})")
        except Exception:
            err = f"unparseable ({type(e).__name__})"
        print(f"  🔴 {os.path.basename(p)}: {err}")
        bad += 1; continue
    ok += 1; total += bps
    if lost and lost > 5:
        print(f"  ⚠️  {os.path.basename(p)}: {bps/1e6:.2f} Mbit/s, {lost:.1f}% lost")
print(f"\n  flows with a result: {ok}, without: {bad}")
print(f"  offered total: {total/1e6:.1f} Mbit/s")
PY
