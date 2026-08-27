#!/usr/bin/env bash
# Short-lived flow churn for ticket M's churn arms.
#
# WHY THIS EXISTS. A steady 300-second iperf3 workload puts the empty-path fraction at about
# 0.5/300 = 0.17%, which no amount of polling will resolve. Moving the path recompute from 1 kHz
# to 1 Hz costs a flow up to one second without a path, so the regression only becomes visible
# when flows are born and die faster than that. Without this arm the round would pass a test that
# cannot detect what it is testing for -- which this project has already done once, measuring CPU
# and connectivity green while model fidelity was the thing that broke.
#
# WHY THE SCHEDULE IS DETERMINISTIC. Both arms must see the identical workload or the comparison
# is between two different experiments rather than two binaries. The batch times and per-flow
# durations come from a fixed seed, and the resolved schedule is written to disk before any flow
# starts, so the after arm can be checked against the before arm rather than assumed equal.
#
# Usage: run_churn.sh <outdir> [total_s] [batch_every_s] [batch_size]
#        defaults: 180 s, a batch every 5 s, 4 flows per batch
# [Co-developed with claude code -- Adam]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?output directory}"
TOTAL_S="${2:-180}"; EVERY_S="${3:-5}"; BATCH="${4:-4}"
SEED="${SEED:-20260827}"
mkdir -p "$OUT"

# Same namespace lookup as run_flows.sh: match the ps title exactly, because a substring match
# picks up h1 when asked for h1x. Not pgrep -- its pattern would match this script's own argv.
host_pid() { ps -eo pid,args | awk -v h="mininet:$1" '$NF==h{print $1; exit}'; }

# Host pairs kept in the same four path classes run_flows.sh uses, so churn traffic crosses the
# same fabric structure as the steady arms rather than concentrating on one switch pair.
CLIENTS=(); SERVERS=()
for i in $(seq 0 15); do CLIENTS+=("h$((1+i))");  SERVERS+=("h$((65+i))");  done
for i in $(seq 0 15); do CLIENTS+=("h$((33+i))"); SERVERS+=("h$((97+i))");  done
for i in $(seq 0 15); do CLIENTS+=("h$((17+i))"); SERVERS+=("h$((49+i))");  done
for i in $(seq 0 15); do CLIENTS+=("h$((81+i))"); SERVERS+=("h$((113+i))"); done
NPAIR=${#CLIENTS[@]}

# --- the schedule, resolved and written BEFORE anything runs --------------------------------
python3 - "$OUT/churn_schedule.json" "$SEED" "$TOTAL_S" "$EVERY_S" "$BATCH" "$NPAIR" <<'PY'
import json, random, sys
out, seed, total, every, batch, npair = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), \
    int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
rnd = random.Random(seed)
sched = []
for t in range(0, total, every):
    for _ in range(batch):
        # [Co-developed with claude code -- Adam]
        # 1-4 s, mean 2.5, per amendment M-bis. This drew 5-10 s (mean 7.5), which is the
        # ticket's ORIGINAL spec -- M-bis superseded it precisely because 5-10 s cannot reach
        # M-5's predicted 70-90% band, and the script was never updated.
        #
        # The arithmetic, which the pre-flight then confirmed: at a 1 s recompute a flow waits
        # 0.5 s on average for its first path, so the share of its life without one is 0.5/dur.
        # At 7.5 s that is 6.7% -- a ratio near 0.93, and the pre-flight measured 0.94-1.00.
        # At 2.5 s it is 20%, i.e. ~0.80, inside the predicted band. Running the arms on the old
        # spec would have produced ~0.95, read as "the mechanism is refuted" off the read-out
        # table, when what was actually wrong was the flow length.
        sched.append({"at": t, "pair": rnd.randrange(npair), "dur": rnd.randint(1, 4)})
json.dump({"seed": seed, "total_s": total, "every_s": every, "batch": batch,
           "n_flows": len(sched), "flows": sched}, open(out, "w"), indent=1)
print(f"  schedule: {len(sched)} flows, seed={seed}, {total}s, batch of {batch} every {every}s")
PY
[ $? -eq 0 ] || { echo "🔴 schedule generation failed"; exit 1; }

# --- resolve every namespace up front; a missing host stops the run, it does not skip a flow --
declare -A PID
missing=0
for h in "${CLIENTS[@]}" "${SERVERS[@]}"; do
    p=$(host_pid "$h")
    if [ -z "$p" ]; then echo "  MISSING host ns: $h" >&2; missing=$((missing+1)); else PID[$h]=$p; fi
done
if [ "$missing" -gt 0 ]; then
    echo "🔴 FATAL: $missing host namespaces absent -- the fabric is not what this expects" >&2
    exit 1
fi
echo "  all $(( NPAIR * 2 )) host namespaces resolved"

# --- run ------------------------------------------------------------------------------------
STARTED=(); T0=$(date +%s)
mapfile -t ROWS < <(python3 -c "
import json,sys
d=json.load(open('$OUT/churn_schedule.json'))
for f in d['flows']: print(f['at'], f['pair'], f['dur'])
")
echo "  churn start $(date '+%H:%M:%S'), ${#ROWS[@]} flows over ${TOTAL_S}s"
echo "t0=$T0" > "$OUT/churn.meta"

for row in "${ROWS[@]}"; do
    set -- $row; at=$1; pair=$2; dur=$3
    # Wait until this flow's scheduled moment. Absolute, not cumulative: a slow batch must not
    # push every later batch back, or the two arms stop sharing a timeline.
    now=$(( $(date +%s) - T0 ))
    [ "$at" -gt "$now" ] && sleep $(( at - now ))
    c="${CLIENTS[$pair]}"; s="${SERVERS[$pair]}"
    port=$(( 5300 + pair ))
    sudo -n mnexec -a "${PID[$s]}" iperf3 -s -1 --daemon -p "$port" >/dev/null 2>&1
    # [Co-developed with claude code -- Adam]
    # Dial the SERVER's address. This read `10.0.0.${c#h}` -- the client's own -- so every flow
    # connected to itself, where nothing listens. 68 of 69 came back "unable to connect to
    # server" having moved 0 bytes, while the arm reported "result files: 68/72" and looked fine.
    sudo -n mnexec -a "${PID[$c]}" iperf3 -c "10.0.0.${s#h}" -p "$port" -t "$dur" -b 20M \
        --json --logfile "$OUT/f_${at}_${pair}.json" >/dev/null 2>&1 &
    STARTED+=("$!")
done

echo "  all flows launched, waiting for the tail"
for p in "${STARTED[@]}"; do wait "$p" 2>/dev/null; done
echo "t_end=$(date +%s)" >> "$OUT/churn.meta"

# [Co-developed with claude code -- Adam]
# This used to count result files and call that "the assertion that flows actually ran". It is
# not one: a client that cannot reach its server still writes a result file, containing an error.
# The count read 68/72 through a run in which every single flow transferred zero bytes -- the
# guard was written for exactly this failure and could not see it, because a file is not a
# transfer. Count bytes.
n_res=$(ls "$OUT"/f_*.json 2>/dev/null | wc -l)
read -r n_ok n_err bytes < <(python3 - "$OUT" <<'PY'
import glob, json, os, sys
ok = err = 0; total = 0
for f in glob.glob(os.path.join(sys.argv[1], "f_*.json")):
    try:
        d = json.load(open(f))
    except Exception:
        err += 1; continue
    if "error" in d:
        err += 1
    else:
        total += d.get("end", {}).get("sum_sent", {}).get("bytes", 0); ok += 1
print(ok, err, total)
PY
)
echo "  churn done $(date '+%H:%M:%S'); result files: $n_res / ${#ROWS[@]}"
echo "  flows that MOVED DATA: $n_ok  failed: $n_err  total: $(( bytes / 1000000 )) MB"
{ echo "n_result_files=$n_res"; echo "n_flows_transferred=$n_ok"; echo "n_flows_failed=$n_err"
  echo "bytes_sent=$bytes"; } >> "$OUT/churn.meta"
if (( n_ok == 0 )); then
    echo "  🔴 NO FLOW TRANSFERRED ANY DATA -- this arm measured an idle fabric, not churn." >&2
    exit 1
fi
[ "$n_res" -eq 0 ] && { echo "🔴 no flow produced a result -- this is not a churn arm"; exit 1; }
exit 0
