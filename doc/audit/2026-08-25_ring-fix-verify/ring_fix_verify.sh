#!/usr/bin/env bash
# ring_fix_verify.sh [pairs] -- does 72fbae6 (async install) prevent the ring?
#
# [Co-developed with claude code -- Adam]
#
# THE RUN §5-P ASKED FOR, finally possible: the ring is reproducible again (quiet boots wedged
# 4/4 in 2026-08-25_host-learning-curve at ~18h uptime, after 24h of being unsummonable).
#
# HALF THE QUESTION IS ALREADY ANSWERED, from the curve run's archived logs and at no cost:
# d1d973d's timeout FIRED ~40 times in every one of those 4 wedged boots. It does exactly what it
# was built to do -- the gate's get_all_host() no longer hangs forever -- AND THE BOOT WEDGES
# ANYWAY. The live dump agrees: the blocked population is 12 event emitters in
# _events_sem.acquire plus 51 REST handlers in an untimed reply_q.get(), and the gate greenlet is
# not among them.
#
#   => Cutting edge 4 is NOT sufficient. §5-P's "cut any one edge and the ring cannot close" is
#      refuted by measurement, not by argument.
#
# So this round tests the remaining fix: 72fbae6, NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL=1, which
# spawns load_static_topology off the EventSwitchEnter handler and so cuts edge 1 -- the handler
# blocking that fills the 128-slot buffer in the first place.
#
# INTERLEAVED defaults/async, because the wedge rate is exactly what is being compared and machine
# condition drifts with uptime. A blocked design would let that drift impersonate the fix.
#
# Reading the result:
#   async wedges too      -> edge 1 is not sufficient either; the ring survives both fixes
#                            individually, and the next question is whether BOTH together help
#   async is clean        -> 72fbae6 is the fix, and the default should flip on THAT evidence
#                            rather than on the boot-time argument used so far
#   defaults stop wedging -> the machine state moved mid-run; the whole comparison is void and
#                            must be rerun. This is why defaults is an arm and not an assumption.
set -uo pipefail

PAIRS=${PAIRS:-4}
export NDT_OWNER=maindev-v3
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$(cd "$(dirname "$0")" && pwd)"
RAW="$DIR/raw"; mkdir -p "$RAW"
OUT="$DIR/ring_fix_verify.txt"
RYU=http://localhost:8080
KERNEL=http://localhost:8000
RYULOG="$REPO/.test_run/logs/ryu.log"
DUMP=/tmp/ndtwin_ryu_greenlets.txt
CAP=600

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

teardown() { local rc=0; ndt down >/dev/null 2>&1 || rc=$?; (( rc==0 )) && say "# torn down (rc=0)" || say "# 🔴 ndt down rc=$rc"; }
trap 'teardown' EXIT INT TERM     # armed before any exit path -- probe_persistence lesson

for v in NDTWIN_RYU_SETTLE_S NDTWIN_RYU_LLDP_GUARD NDTWIN_RYU_LLDP_BACKOFF \
         NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL; do
    [[ -n "${!v:-}" ]] && { echo "ABORT: $v='${!v}' is set in the environment." >&2; exit 2; }
done

say ""
say "# ring fix verification: does 72fbae6 (async install) prevent the wedge?"
say "# date:    $(date +%Y-%m-%dT%H:%M:%S%z)   commit: $(git -C "$REPO" rev-parse --short HEAD)"
say "# router:  sha256=$(sha256sum "$REPO/intelligent_router.py" | cut -c1-16)  $(git -C "$REPO" diff --quiet HEAD -- intelligent_router.py && echo "matches HEAD" || echo "MODIFIED vs HEAD")"
say "# boot_id: $(cat /proc/sys/kernel/random/boot_id)  uptime_h=$(awk '{printf "%.2f", $1/3600}' /proc/uptime)"
say "# baseline: quiet boots wedged 4/4 at uptime 18.0h (2026-08-25_host-learning-curve)"
say "# NOTE d1d973d's timeout fired ~40x in each of those 4 wedges -- edge 4 alone is not enough"
say "# $PAIRS pairs interleaved: defaults vs ASYNC=1"

suspends_since() { journalctl -k --since "@$1" --no-pager 2>/dev/null | grep -c "PM: suspend entry"; }

grab_dump() {
    local tag="$1" pid
    pid=$(pgrep -f "ryu-manager --observe-links" 2>/dev/null | head -1)
    [[ -z "$pid" ]] && { say "     (no ryu -- no dump)"; return; }
    : > "$DUMP"; kill -USR2 "$pid" 2>/dev/null; sleep 4
    if [[ -s "$DUMP" ]]; then
        cp -f "$DUMP" "$RAW/${tag}_greenlets.txt"
        local sem rq
        sem=$(grep -c "_events_sem.acquire" "$RAW/${tag}_greenlets.txt")
        rq=$(grep -c "reply_q.get()" "$RAW/${tag}_greenlets.txt")
        say "     dump: $(wc -l < "$RAW/${tag}_greenlets.txt") lines, ${sem} in _events_sem.acquire, ${rq} in reply_q.get"
    else
        say "     dump empty"
    fi
}

dwedge=0; dok=0; awedge=0; aok=0
for p in $(seq 1 "$PAIRS"); do
for arm in defaults async; do
    tag="${arm}_p${p}"
    upout="$RAW/${tag}_up.out"
    ndt down >/dev/null 2>&1; sleep 3

    t0=$(date +%s); susp0=$(suspends_since "$t0")
    if [[ "$arm" == "async" ]]; then
        setsid bash -c "cd '$REPO' && NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL=1 exec ndt up ovs" > "$upout" 2>&1 &
    else
        setsid bash -c "cd '$REPO' && exec ndt up ovs" > "$upout" 2>&1 &
    fi
    pg=$!
    capped=0
    while kill -0 "$pg" 2>/dev/null; do
        if (( $(date +%s) - t0 >= CAP )); then
            capped=1; say "## $tag: HIT ${CAP}s CAP -- dumping first"; grab_dump "$tag"
            kill -TERM -"$pg" 2>/dev/null; sleep 5; kill -KILL -"$pg" 2>/dev/null; break
        fi
        sleep 2
    done
    wait "$pg" 2>/dev/null
    wall=$(( $(date +%s) - t0 ))

    # Dump BEFORE teardown while the evidence still exists. A wedged boot leaves ryu alive.
    ent=$(grep -c "Switch entered:" "$RYULOG" 2>/dev/null); [[ "$ent" =~ ^[0-9]+$ ]] || ent=0
    stc=$(grep -c "connected (EventOFPStateChange)" "$RYULOG" 2>/dev/null); [[ "$stc" =~ ^[0-9]+$ ]] || stc=0
    if (( capped == 0 )) && (( ent < 10 )); then grab_dump "$tag"; fi
    cp -f "$RYULOG" "$RAW/${tag}_ryu.log" 2>/dev/null || true

    # Assert the injection landed. Without this an async boot that silently ran WITHOUT the flag
    # would be scored as "the fix did not help" -- the exact failure §5-P item 5.1 warns about.
    banner=$(grep -c "load_static_topology will run OFF the event handler" "$RAW/${tag}_ryu.log" 2>/dev/null); [[ "$banner" =~ ^[0-9]+$ ]] || banner=0
    if [[ "$arm" == "async" && "$banner" -eq 0 ]]; then
        say "## $tag: 🔴 ASYNC BANNER ABSENT -- ran WITHOUT the fix; row is not evidence"
    elif [[ "$arm" == "defaults" && "$banner" -ne 0 ]]; then
        # 🔴 STALE AS OF 2026-08-25: the async default was flipped OFF -> ON (d807798's sibling
        # commit), so "plain defaults" now RUNS ASYNC and this check would abort every defaults
        # boot. It was correct for the run it was written for -- that run's raws are recorded at
        # the old default -- and it is left in place with this note rather than silently rewritten,
        # because the results above were produced under the assumption it encodes.
        #
        # A rerun must EITHER pin NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL=0 in the defaults arm (making
        # it a "pre-flip defaults" control, which is what the recorded comparison actually was)
        # OR drop this check and rename the arm. Do not just delete the check: the two choices
        # answer different questions.
        say "## $tag: 🔴 async banner present in the DEFAULTS arm -- environment leak; aborting"
        say "     (if this fired after 2026-08-25, see the note above: the default flipped)"
        exit 3
    fi

    if [[ "$(suspends_since "$t0")" != "$susp0" ]]; then
        say "## $tag: CONTAMINATED (suspend) -- excluded"; continue
    fi

    h=$(curl -sf --max-time 5 "$RYU/v1.0/topology/hosts" 2>/dev/null | python3 -c "
import json,sys
try: print(sum(1 for x in json.load(sys.stdin) if x.get('ipv4')))
except Exception: print(-1)" 2>/dev/null); [[ "$h" =~ ^-?[0-9]+$ ]] || h=-1
    g=$(curl -sf --max-time 5 "$KERNEL/ndt/get_graph_data" 2>/dev/null | python3 -c "
import json,sys
try:
    e=json.load(sys.stdin)['edges']; print(len(e), sum(1 for x in e if not x.get('is_up',True)))
except Exception: print('? ?')" 2>/dev/null) || g="? ?"

    if (( ent < 10 )); then cls="RING-WEDGE"
    elif [[ "$h" == "128" ]]; then cls="HEALTHY"
    else cls="FLAT-ZERO"; fi

    if [[ "$cls" == "RING-WEDGE" ]]; then
        [[ "$arm" == "async" ]] && awedge=$((awedge+1)) || dwedge=$((dwedge+1))
    else
        [[ "$arm" == "async" ]] && aok=$((aok+1)) || dok=$((dok+1))
    fi
    say "## $tag: $cls  wall=${wall}s  hosts=${h}/128  graph=${g}  entered=${ent}/10 statechange=${stc}/10  banner=${banner}"
done
done

say "# DEFAULTS: $dwedge wedged of $((dwedge+dok))    ASYNC: $awedge wedged of $((awedge+aok))"
say "done -> $OUT"
