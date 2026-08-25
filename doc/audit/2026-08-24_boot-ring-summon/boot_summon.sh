#!/usr/bin/env bash
# boot_summon.sh [pairs]  -- can CPU contention summon the boot wedge?
#
# [Co-developed with claude code -- Adam]
#
# WHY THIS AND NOT "dirty vs cold". The 6/10 wedge was measured in boot session -1
# (Aug 21 21:14 -> Aug 24 16:46, ~67h uptime). Every clean run since -- 30 boots across
# three arms, including the baseline commit itself -- is in boot session 0 (Aug 24 17:01+,
# <4h uptime). The machine was rebooted in the gap. That, not "leftover P4 state", is what
# changed: teardown was verified clean (0 netns, 0 OVS bridges, 0 orphans) and 30 fabric
# cycles in one evening did not reproduce it.
#
# 67h of uptime cannot be manufactured. What can be tested is the PROXIMATE mechanism the
# frame dump already established: the ring closes when load_static_topology blocks inside
# EventSwitchEnter long enough for the app's 128-slot queue to fill. Anything that slows
# that walk widens the window -- and a long-uptime, thermally-throttled, fragmented machine
# is one such thing. So: does CPU contention summon it?
#
#   summoned     -> mechanism confirmed as timing; d1d973d and 72fbae6 finally become testable
#   not summoned -> timing/contention is ruled out and the trigger is something else about
#                   long uptime; do not keep tuning against it
#
# INTERLEAVED, not blocked. Loaded and quiet alternate boot-by-boot, so a drift in machine
# condition over the run cannot masquerade as the treatment effect. That is the error the
# 12:23-vs-18:00 comparison fell into.
set -uo pipefail

PAIRS=${PAIRS:-8}
export NDT_OWNER=maindev-v3
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$(cd "$(dirname "$0")" && pwd)"
RAW="$DIR/raw"; mkdir -p "$RAW"
OUT="$DIR/boot_summon.txt"
RYU=http://localhost:8080
KERNEL=http://localhost:8000
RYULOG="$REPO/.test_run/logs/ryu.log"
DUMP=/tmp/ndtwin_ryu_greenlets.txt
CAP=600
WORKERS=$(nproc)

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

for v in NDTWIN_RYU_SETTLE_S NDTWIN_RYU_LLDP_GUARD NDTWIN_RYU_LLDP_BACKOFF \
         NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL; do
    if [[ -n "${!v:-}" ]]; then
        echo "ABORT: $v='${!v}' is set -- this must run at plain defaults." >&2; exit 2
    fi
done

say ""
say "# summoning run: does CPU contention reproduce the boot wedge?"
say "# date:    $(date +%Y-%m-%dT%H:%M:%S%z)   commit: $(git -C "$REPO" rev-parse --short HEAD)"
say "# router:  sha256=$(sha256sum "$REPO/intelligent_router.py" | cut -c1-16)  $(git -C "$REPO" diff --quiet HEAD -- intelligent_router.py && echo "matches HEAD" || echo "MODIFIED vs HEAD")"
# The covariate that actually separates the failing population from every clean run so far.
say "# boot_id: $(cat /proc/sys/kernel/random/boot_id)  uptime_h=$(awk '{printf "%.2f", $1/3600}' /proc/uptime)"
say "# wedge was seen at uptime ~67h in a PRIOR boot session; all clean runs are this session"
say "# load arm: $WORKERS busy-loop workers (nproc); interleaved L/Q, $PAIRS pairs"

# --- load lifecycle ---------------------------------------------------------------------
#
# Three defects were found here on the first live run; all three are the reason this looks
# more paranoid than "spawn some busy loops" warrants.
#
#  1. DEADLOCK. `workers_up=$(load_start)` hung forever: command substitution waits for every
#     background child to close stdout, and the busy loops inherit that pipe. The first run
#     sat 18 minutes without starting a single boot. Fixed by redirecting the children to
#     /dev/null AND returning through a global instead of $(...).
#  2. `$!` IS NOT THE WORKER. `setsid cmd &` sets $! to *setsid*, which forks the real child
#     and exits. So `kill -0 $!` reports dead immediately and `kill -TERM $!` kills nothing;
#     the busy loop survives, reparented to init. Two smoke runs each reported "0 still
#     alive" while leaking 14 workers apiece. Never track these by $!.
#  3. NO QUIET-ARM GUARD. Leaked workers from a loaded boot would silently run through the
#     next quiet boot, which would destroy the comparison rather than merely noise it.
#
# So: workers carry a unique argv marker, and every count is a fresh scan for that marker
# rather than a check on a remembered pid. Living in a script file makes the marker immune
# to the pgrep-matches-my-own-command-line trap.
LOADMARK="ndtwin_summon_busyloop_$$"
LOAD_ALIVE=0
LOAD_LEFT=0

# `pgrep -c` prints "0" AND exits non-zero when nothing matches, so the obvious
# `pgrep -c ... || echo 0` emits "0\n0" and every arithmetic test on it dies with
# "integer expression expected" -- i.e. the quiet-arm guard would error instead of guarding.
# Also note this MUST live in a script file: pgrep -f matches the caller's own argv, and run
# from an interactive shell the pattern appears in the wrapper's command line and self-matches
# (measured: a pattern matching nothing real returned 1, then 3). The script's argv is
# `bash ./boot_summon.sh`, which cannot contain LOADMARK.
load_count() {
    local n
    n=$(pgrep -c -f "$LOADMARK" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    echo "$n"
}

load_start() {
    local i
    for i in $(seq "$WORKERS"); do
        setsid bash -c "while :; do :; done # $LOADMARK" >/dev/null 2>&1 &
    done
    sleep 2
    LOAD_ALIVE=$(load_count)
}

load_stop() {
    local p tries=0
    while [ "$(load_count)" -gt 0 ] && [ "$tries" -lt 5 ]; do
        for p in $(pgrep -f "$LOADMARK" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
        sleep 1; tries=$((tries+1))
    done
    LOAD_LEFT=$(load_count)
}

# Kill leaked workers on any exit path, including the 600s cap and Ctrl-C. Without this an
# aborted run leaves the machine loaded for whoever measures next.
trap 'load_stop >/dev/null 2>&1' EXIT INT TERM

suspends_since() { journalctl -k --since "@$1" --no-pager 2>/dev/null | grep -c "PM: suspend entry"; }

twin_read() {
    local h g
    h=$(curl -sf --max-time 5 "$RYU/v1.0/topology/hosts" | python3 -c "
import json,sys
hs=json.load(sys.stdin)
print(sum(1 for x in hs if x.get('ipv4')))" 2>/dev/null || echo "?")
    g=$(curl -sf --max-time 5 "$KERNEL/ndt/get_graph_data" | python3 -c "
import json,sys
e=json.load(sys.stdin)['edges']
print(len(e), sum(1 for x in e if not x.get('is_up',True)))" 2>/dev/null || echo "? ?")
    echo "$h $g"
}

grab_dump() {
    local upout="$1" tag="$2" pid
    pid=$(grep -oP 'started ryu \(pid \K[0-9]+' "$upout" | head -1)
    [[ -z "$pid" ]] && { say "     (no ryu pid -- no dump)"; return; }
    kill -0 "$pid" 2>/dev/null || { say "     (ryu pid $pid gone -- no dump)"; return; }
    : > "$DUMP"; kill -USR2 "$pid" 2>/dev/null; sleep 3
    if [[ -s "$DUMP" ]]; then
        cp -f "$DUMP" "$RAW/${tag}_greenlets.txt"
        say "     dump: $(wc -l < "$RAW/${tag}_greenlets.txt") lines, $(grep -c "_events_sem.acquire" "$RAW/${tag}_greenlets.txt") in _events_sem.acquire"
    else
        say "     dump empty -- check ryu.log for the SIGUSR2 banner"
    fi
}

lf=0; lo=0; qf=0; qo=0; contaminated=0
for p in $(seq 1 "$PAIRS"); do
for mode in loaded quiet; do
    tag="${mode}_p${p}"
    upout="$RAW/${tag}_up.out"

    ndt down >/dev/null 2>&1
    sleep 3

    if [[ "$mode" == "loaded" ]]; then
        load_start
        # An injection that does not assert its own success is a no-op you will read as a
        # negative result -- the exact failure this project has logged repeatedly.
        if [[ "$LOAD_ALIVE" -ne "$WORKERS" ]]; then
            say "## $tag: ABORT -- only $LOAD_ALIVE/$WORKERS load workers alive"
            load_stop; ndt down >/dev/null 2>&1; exit 3
        fi
    else
        # The quiet arm is only quiet if the previous loaded boot's workers really died.
        # Assert it rather than trusting load_stop's own report -- that report was wrong twice.
        stray=$(load_count)
        if [[ "$stray" -ne 0 ]]; then
            say "## $tag: ABORT -- $stray load workers survived into the quiet arm"
            load_stop; ndt down >/dev/null 2>&1; exit 3
        fi
    fi

    t0=$(date +%s); susp0=$(suspends_since "$t0")
    setsid bash -c "cd '$REPO' && exec ndt up ovs" > "$upout" 2>&1 &
    pg=$!
    if [[ "$(ps -o pgid= -p "$pg" 2>/dev/null | tr -d ' ')" != "$pg" ]]; then
        say "     🔴 pgid mismatch -- cap cannot kill the tree; aborting"
        kill -TERM "$pg" 2>/dev/null; [[ "$mode" == "loaded" ]] && load_stop >/dev/null
        ndt down >/dev/null 2>&1; exit 3
    fi

    capped=0
    while kill -0 "$pg" 2>/dev/null; do
        if (( $(date +%s) - t0 >= CAP )); then
            capped=1; say "## $tag: HIT THE ${CAP}s CAP -- dumping before the kill"
            grab_dump "$upout" "$tag"
            kill -TERM -"$pg" 2>/dev/null; sleep 5; kill -KILL -"$pg" 2>/dev/null; break
        fi
        sleep 2
    done
    wait "$pg" 2>/dev/null
    wall=$(( $(date +%s) - t0 ))

    # ryu.log is archived for EVERY boot, not just failures. Last round kept logs only on
    # failure, there were no failures, and the "no timeout warning fired" claim ended up
    # resting on a single spot-check (review note N-1).
    cp -f "$RYULOG" "$RAW/${tag}_ryu.log" 2>/dev/null || true

    # The discriminator from the N-2 reconciliation. One string, two emitters:
    #   "Switch entered:"                 <- EventSwitchEnter handler, notify at :763
    #   "connected (EventOFPStateChange)" <- _state_change_handler,    notify at :857
    # The wedge truncates ONLY the enter side (2 of 10) while state-change stays 10/10.
    # A merely slow machine would not show that asymmetry, so this separates "summoned the
    # wedge" from "made everything slow".
    # `grep -c || echo 0` emits "0\n0" on no-match -- grep -c PRINTS 0 and exits 1, so the
    # fallback appends a second zero and any arithmetic on it dies. This is the identical defect
    # documented and fixed in load_count above, reintroduced 150 lines away in the SAME commit,
    # and found by the post-commit shadow review rather than by me. Fixing the instance you are
    # debugging is not fixing the bug: grep the file for every occurrence of the shape.
    ent=$(grep -c "Switch entered:" "$RAW/${tag}_ryu.log" 2>/dev/null); [[ "$ent" =~ ^[0-9]+$ ]] || ent=0
    stc=$(grep -c "connected (EventOFPStateChange)" "$RAW/${tag}_ryu.log" 2>/dev/null); [[ "$stc" =~ ^[0-9]+$ ]] || stc=0

    if [[ "$mode" == "loaded" ]]; then
        load_stop
        [[ "$LOAD_LEFT" -gt 0 ]] && say "     🔴 $LOAD_LEFT load workers would not die -- next quiet boot is not quiet"
    fi

    if [[ "$(suspends_since "$t0")" != "$susp0" ]]; then
        say "## $tag: CONTAMINATED (suspend) wall=${wall}s -- excluded"
        contaminated=$((contaminated+1)); continue
    fi

    xx=$(grep -cE '^\s+XX' "$upout" || true)
    read -r hosts edges down <<< "$(twin_read)"
    if (( capped == 0 )) && [ "$xx" -eq 0 ] && [ "$hosts" = "128" ] && [ "$down" = "0" ]; then
        verdict="CONVERGED"
    else
        sleep 20
        read -r hosts edges down <<< "$(twin_read)"
        if (( capped == 0 )) && [ "$xx" -eq 0 ] && [ "$hosts" = "128" ] && [ "$down" = "0" ]; then
            verdict="CONVERGED (t+20)"
        else
            verdict="FAILED"; (( capped == 0 )) && grab_dump "$upout" "$tag"
        fi
    fi

    # Classify, don't just pass/fail. The PAIRS=1 smoke produced two boots that both read
    # "FAILED" and were nothing alike: one was the settle/host-learning failure (256 down,
    # hosts 0/128) and the other was a healthy fabric with a transient switch-state read at
    # verify time (288e/0d, hosts 128/128, forwarding ok). A reviewer reading only the verdict
    # column would score those the same, and the whole point of this run is to tell failures
    # apart. Discriminators are §5-P's, plus the N-2 enter/state-change decomposition.
    case "1" in
      1)
        if [ "$down" = "288" ] && [ "${ent:-10}" -lt 10 ]; then
            class="RING-WEDGE"          # the defect we are trying to summon
        elif [ "$down" = "256" ] || { [ "$hosts" = "0" ] && [ "$down" != "0" ]; }; then
            class="SETTLE-HOSTS"        # host learning missed its window; twin blind to hosts
        elif [ "$hosts" = "128" ] && [ "$down" = "0" ] && [ "$xx" -gt 0 ]; then
            class="HEALTHY-XX"          # fabric fine, a verify probe blipped
        elif [ "$hosts" = "128" ] && [ "$down" = "0" ]; then
            class="HEALTHY"
        else
            class="OTHER"
        fi ;;
    esac
    say "     class=$class"

    if [ "${verdict%% *}" = "CONVERGED" ]; then
        [[ "$mode" == "loaded" ]] && lo=$((lo+1)) || qo=$((qo+1))
    else
        [[ "$mode" == "loaded" ]] && lf=$((lf+1)) || qf=$((qf+1))
    fi
    say "## $tag: $verdict  wall=${wall}s  XX=$xx  hosts=${hosts}/128  graph=${edges}e/${down}d  entered=${ent}/10 statechange=${stc}/10"
done
done

ndt down >/dev/null 2>&1
say "# LOADED: $lf of $((lf+lo)) failed    QUIET: $qf of $((qf+qo)) failed    (contaminated: $contaminated)"
say "# wedge signature to look for: entered truncated (<10) while statechange=10/10"
say "done -> $OUT"
