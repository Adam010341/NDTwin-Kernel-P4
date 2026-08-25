#!/usr/bin/env bash
# host_curve.sh [pairs] -- WHEN do the 128 host IPv4s appear, and what differs under load?
#
# [Co-developed with claude code -- Adam]
#
# WHY THIS TARGET, AND WHY THE PREVIOUS ONE WAS WRONG.
#
# The summoning round concluded "settle=40 is not robust under CPU contention". That attribution
# was retracted (3dcb8ec): intelligent_router.py:975-989 logs a host-learning trace every 10s, and
# all 19 archived ryu.logs -- loaded AND quiet, including every boot that ended perfectly healthy
# at 128/128 -- read byte-identically:
#
#     host discovery: 0/128 after 10s / 20s / 30s / 40s
#     host discovery incomplete after 40s: 0/128 hosts have an IPv4. Installing paths anyway.
#
# The gate is a CONSTANT, not a variable. It times out at 0/128 on every boot. So it cannot be
# what separates the arms, and a settle sweep would have tuned a knob the evidence says is not
# connected to the outcome.
#
# The arms diverge ENTIRELY after the gate gives up: quiet acquires all 128 in that window,
# loaded acquires none, permanently (verified to 11.8h). The gate's own trace cannot show this --
# it samples every 10s and STOPS at the deadline, which is precisely where the interesting part
# begins.
#
# So: poll /v1.0/topology/hosts every 2s from before Ryu is up until well after `ndt up` returns,
# and correlate the curve against the install markers in ryu.log. Interleaved L/Q, because
# blocking the arms lets machine drift impersonate the treatment.
#
# What each outcome would mean:
#   quiet steps 0 -> 128 at one sample     the "learned in a single event" shape memory describes;
#                                          then the question is what that event is, and why load
#                                          suppresses it
#   quiet climbs gradually                 learning is incremental and load merely starves it
#   loaded climbs then stalls partway      partial learning, different defect from "none at all"
#   loaded flat at 0 throughout            confirms the twin never learns, and dates it precisely
set -uo pipefail

PAIRS=${PAIRS:-4}
TAIL_S=${TAIL_S:-120}          # keep polling this long after `ndt up` returns
export NDT_OWNER=maindev-v3
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$(cd "$(dirname "$0")" && pwd)"
RAW="$DIR/raw"; mkdir -p "$RAW"
OUT="$DIR/host_curve.txt"
RYU=http://localhost:8080
KERNEL=http://localhost:8000
RYULOG="$REPO/.test_run/logs/ryu.log"
WORKERS=$(nproc)
LOADMARK="ndtwin_curve_busyloop_$$"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

# Same shape as boot_summon's, and for the same reasons: `pgrep -c` prints 0 AND exits non-zero,
# `$!` after setsid is setsid rather than the worker, and this must live in a script file so the
# marker cannot appear in the caller's own argv.
load_count() { local n; n=$(pgrep -c -f "$LOADMARK" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0; echo "$n"; }
load_start() { local i; for i in $(seq "$WORKERS"); do setsid bash -c "while :; do :; done # $LOADMARK" >/dev/null 2>&1 & done; sleep 2; }
load_stop()  { local p t=0; while [ "$(load_count)" -gt 0 ] && [ "$t" -lt 5 ]; do for p in $(pgrep -f "$LOADMARK" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done; sleep 1; t=$((t+1)); done; }

POLLER_PID=""
stop_poller() { [[ -n "$POLLER_PID" ]] && kill -TERM "$POLLER_PID" 2>/dev/null; POLLER_PID=""; }

# Armed before ANY exit path can fire -- the probe_persistence lesson: a cleanup handler defined
# after the code that can fail is not a cleanup handler.
teardown() {
    local rc=0
    ndt down >/dev/null 2>&1 || rc=$?
    (( rc == 0 )) && say "# fabric torn down (rc=0)" || say "# 🔴 ndt down FAILED rc=$rc -- check 'ndt status'"
}
trap 'stop_poller; load_stop >/dev/null 2>&1; teardown' EXIT INT TERM

for v in NDTWIN_RYU_SETTLE_S NDTWIN_RYU_LLDP_GUARD NDTWIN_RYU_LLDP_BACKOFF \
         NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL; do
    [[ -n "${!v:-}" ]] && { echo "ABORT: $v='${!v}' is set -- must run at plain defaults." >&2; exit 2; }
done

say ""
say "# host-learning curve: when do the 128 IPv4s appear, loaded vs quiet?"
say "# date:    $(date +%Y-%m-%dT%H:%M:%S%z)   commit: $(git -C "$REPO" rev-parse --short HEAD)"
say "# router:  sha256=$(sha256sum "$REPO/intelligent_router.py" | cut -c1-16)  $(git -C "$REPO" diff --quiet HEAD -- intelligent_router.py && echo "matches HEAD" || echo "MODIFIED vs HEAD")"
say "# boot_id: $(cat /proc/sys/kernel/random/boot_id)  uptime_h=$(awk '{printf "%.2f", $1/3600}' /proc/uptime)"
say "# $PAIRS pairs, interleaved; poll 2s; +${TAIL_S}s after ndt up returns; load=$WORKERS workers"

# The poller runs for the WHOLE boot including before Ryu answers. A connection refused is data --
# it dates when the endpoint came up -- so it is recorded as -1 rather than dropped.
poll_hosts() {
    local out="$1" t0="$2"
    printf "elapsed_s\thosts_with_ipv4\n" > "$out"
    while :; do
        local h
        h=$(curl -sf --max-time 2 "$RYU/v1.0/topology/hosts" 2>/dev/null \
            | python3 -c "
import json,sys
try: print(sum(1 for x in json.load(sys.stdin) if x.get('ipv4')))
except Exception: print(-1)" 2>/dev/null)
        [[ "$h" =~ ^-?[0-9]+$ ]] || h=-1
        printf "%s\t%s\n" "$(( $(date +%s) - t0 ))" "$h" >> "$out"
        sleep 2
    done
}

for p in $(seq 1 "$PAIRS"); do
for mode in loaded quiet; do
    tag="${mode}_p${p}"
    ndt down >/dev/null 2>&1; sleep 3

    if [[ "$mode" == "loaded" ]]; then
        load_start
        alive=$(load_count)
        [[ "$alive" -ne "$WORKERS" ]] && { say "## $tag: ABORT -- only $alive/$WORKERS workers"; exit 3; }
    else
        stray=$(load_count)
        [[ "$stray" -ne 0 ]] && { say "## $tag: ABORT -- $stray workers survived into the quiet arm"; exit 3; }
    fi

    t0=$(date +%s)
    poll_hosts "$RAW/${tag}_curve.tsv" "$t0" &
    POLLER_PID=$!

    setsid bash -c "cd '$REPO' && exec ndt up ovs" > "$RAW/${tag}_up.out" 2>&1 &
    pg=$!
    while kill -0 "$pg" 2>/dev/null; do
        (( $(date +%s) - t0 >= 600 )) && { kill -TERM -"$pg" 2>/dev/null; break; }
        sleep 2
    done
    wait "$pg" 2>/dev/null
    up_done=$(( $(date +%s) - t0 ))

    sleep "$TAIL_S"                      # keep polling past the end of bring-up
    stop_poller
    [[ "$mode" == "loaded" ]] && load_stop
    cp -f "$RYULOG" "$RAW/${tag}_ryu.log" 2>/dev/null || true

    # Curve summary: first sample the endpoint answered, first non-zero, first 128, final.
    read -r first_up first_nz first_full final <<< "$(python3 - "$RAW/${tag}_curve.tsv" <<'PY'
import sys
rows=[l.split('\t') for l in open(sys.argv[1]).read().splitlines()[1:] if '\t' in l]
rows=[(int(a),int(b)) for a,b in rows]
up  =next((t for t,h in rows if h>=0), -1)
nz  =next((t for t,h in rows if h>0),  -1)
full=next((t for t,h in rows if h>=128),-1)
print(up, nz, full, rows[-1][1] if rows else -1)
PY
)"
    gate=$(grep -oP "host discovery (in)?complete[^0-9]*\K[0-9]+s: [0-9]+/128" "$RAW/${tag}_ryu.log" 2>/dev/null | head -1)
    inst=$(grep -c "install_all_pair_paths done" "$RAW/${tag}_ryu.log" 2>/dev/null); [[ "$inst" =~ ^[0-9]+$ ]] || inst=0

    say "## $tag: up_done=${up_done}s  endpoint_up=${first_up}s  first_host=${first_nz}s  all128=${first_full}s  final=${final}/128  installs=${inst}  gate='${gate:-none}'"
done
done

say "# curves in raw/*_curve.tsv (elapsed_s, hosts_with_ipv4; -1 = endpoint not answering)"
say "done -> $OUT"
