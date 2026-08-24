#!/usr/bin/env bash
# boot_ring_verify.sh <t_only|async>  -- verify the two boot-ring fixes against the 6/10 baseline
#
# [Co-developed with claude code -- Adam]
#
# Two arms, run separately so the variables are separable (§5-P item 5.2): the 6/10 baseline was
# measured at 79cd66a, BEFORE d1d973d made HOST_QUERY_TIMEOUT_S default behaviour. So "defaults
# today" is already one fix ahead of the baseline.
#
#   t_only  defaults. Isolates d1d973d (edge 4, the untimed get_all_host request-reply).
#           THIS is the honest comparison against 6/10.
#   async   t_only + NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL=1. Adds 72fbae6 (edge 1, the walk
#           blocking inside EventSwitchEnter).
#
# Deliberately NOT a rerun of boot_rate.sh, for three reasons found in pre-flight:
#
#   1. boot_rate.sh's raws are `> "$RAW/rate_boot${i}_up.out"` -- truncating. Its header claims
#      C-1 immunity ("numbered, never overwritten") but the numbering only disambiguates within
#      a run. Re-running it destroys the 15 raws behind 6/10. Ours are ARM-prefixed and live in
#      a different directory; the baseline is never touched.
#   2. It hardcodes `export NDT_OWNER=review-0824`, which would claim the lab as another session.
#   3. Its `wall=` is not suspend-safe. Baseline boot 8 read "CONVERGED wall=7626s" because the
#      laptop suspended 13:04:58-15:11:07 (journalctl, 7569s) mid-boot. await_convergence tests
#      success BEFORE the deadline, so a post-resume iteration returns through the success branch
#      without consulting the clock, and 2h of sleep is reported as a clean convergence. Every
#      iteration here is checked against journalctl and marked CONTAMINATED if it straddles a
#      suspend -- contaminated rows are excluded from the rate rather than silently averaged in.
set -uo pipefail

ARM="${1:-}"
case "$ARM" in
    t_only|async) ;;
    # Same-day control: intelligent_router.py reverted to 79cd66a by hand before running this.
    # Discriminates "d1d973d fixed the wedge" from "today's conditions do not trigger it" -- the
    # t_only arm cannot, because its timeout logs nothing on a boot that never needed rescuing.
    # NOTE: the baseline predates 7f7de4a, so SIGUSR2 is absent and dumps will be empty by design.
    baseline) ;;
    *) echo "usage: $0 <t_only|async|baseline>" >&2; exit 2 ;;
esac

export NDT_OWNER=maindev-v3
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$(cd "$(dirname "$0")" && pwd)"
RAW="$DIR/raw"; mkdir -p "$RAW"
OUT="$DIR/boot_ring_${ARM}.txt"
RYU=http://localhost:8080
KERNEL=http://localhost:8000
RYULOG="$REPO/.test_run/logs/ryu.log"
DUMP=/tmp/ndtwin_ryu_greenlets.txt
CAP=600            # Adam's call: hard cap, over => FAILED. Failing boots land ~414s
                   # (CONVERGE_WAIT=400 at ndt:760), so this only fires on something pathological.
N=${BOOTS:-10}    # BOOTS=1 for a harness smoke run -- a new tool's first live run mostly finds
                  # the tool's own defects, so this gets exercised before a full arm is spent.

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

if [[ "$ARM" == "async" ]]; then
    export NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL=1
fi

# Defaults must be defaults. An arm that silently inherited a tuning knob from the shell would be
# measuring something nobody can name later.
for v in NDTWIN_RYU_SETTLE_S NDTWIN_RYU_LLDP_GUARD NDTWIN_RYU_LLDP_BACKOFF; do
    if [[ -n "${!v:-}" ]]; then
        echo "ABORT: $v='${!v}' is set -- both arms must run at plain defaults." >&2; exit 2
    fi
done

say ""
say "# boot-ring verification, arm=$ARM -- ten OVS boots, cap ${CAP}s"
say "# date:   $(date +%Y-%m-%dT%H:%M:%S%z)   commit: $(git -C "$REPO" rev-parse --short HEAD)"
# HEAD is not the independent variable -- the control arm reverts intelligent_router.py alone,
# which leaves HEAD reading 8340367 while the boot path is the baseline's. Record the file.
# `git diff --quiet -- <path>` compares the worktree against the INDEX, not HEAD. `git checkout
# <commit> -- <path>` stages what it writes, so both sides matched and the baseline arm printed
# "matches HEAD" while running the reverted router -- a check whose whole purpose was to catch that.
# `git diff --quiet HEAD --` is the comparison that was meant. The sha256 was correct throughout.
say "# router:  sha256=$(sha256sum "$REPO/intelligent_router.py" | cut -c1-16)  $(git -C "$REPO" diff --quiet HEAD -- intelligent_router.py && echo "matches HEAD" || echo "MODIFIED vs HEAD")"
say "# baseline for comparison: 6 of 10 failed, at 79cd66a (pre-d1d973d)"
say "# env: ASYNC=${NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL:-unset} SETTLE=${NDTWIN_RYU_SETTLE_S:-unset} GUARD=${NDTWIN_RYU_LLDP_GUARD:-unset} BACKOFF=${NDTWIN_RYU_LLDP_BACKOFF:-unset}"

suspends_since() {  # epoch -> count of suspend entries since then
    journalctl -k --since "@$1" --no-pager 2>/dev/null | grep -c "PM: suspend entry"
}

twin_read() {  # -> "hosts edges down"; same criterion as the baseline script, deliberately
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

# Dump greenlet stacks while the wedge is still live. Must be called BEFORE teardown: the frames
# are the evidence and `ndt down` destroys them.
#
# The pid comes from the up.out line ryu itself prints ("started ryu (pid N)"), NOT from pgrep -f
# -- a -f pattern matches this script's own argv, which cost a day on 2026-08-21.
grab_dump() {
    local upout="$1" tag="$2" pid
    pid=$(grep -oP 'started ryu \(pid \K[0-9]+' "$upout" | head -1)
    if [[ -z "$pid" ]]; then
        say "     (no ryu pid in $upout -- no dump)"; return
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        say "     (ryu pid $pid already gone -- no dump)"; return
    fi
    : > "$DUMP"
    kill -USR2 "$pid" 2>/dev/null
    sleep 3
    if [[ -s "$DUMP" ]]; then
        cp -f "$DUMP" "$RAW/${tag}_greenlets.txt"
        # The ring signature is the semaphore, not the queue (§5-P item 7): Ryu's app buffer is a
        # hub.Queue + semaphore pair, and a full buffer parks in the semaphore. Grepping queue.put
        # returns 0 and reads as "no ring", which nearly killed a correct hypothesis.
        local sem; sem=$(grep -c "_events_sem.acquire" "$RAW/${tag}_greenlets.txt")
        say "     dump: $(wc -l < "$RAW/${tag}_greenlets.txt") lines, ${sem} greenlets in _events_sem.acquire"
    else
        say "     dump empty -- check ryu.log for the SIGUSR2 banner (tool may not be installed)"
    fi
}

fails=0; oks=0; contaminated=0
for i in $(seq 1 "$N"); do
    tag="${ARM}_boot${i}"
    upout="$RAW/${tag}_up.out"

    ndt down >/dev/null 2>&1
    sleep 3

    t0=$(date +%s)
    susp0=$(suspends_since "$t0")

    # setsid puts `ndt up` in its own process group so the cap can kill the whole tree. `timeout`
    # alone signals the direct child, and ndt's work happens in subshells and sudo children.
    setsid bash -c "cd '$REPO' && exec ndt up ovs" > "$upout" 2>&1 &
    pg=$!

    # The cap kills a process GROUP, so $! must actually be the group leader. setsid only skips
    # its fork when it is not already a pgroup leader; if that assumption ever breaks, `kill -TERM
    # -$pg` silently signals the wrong group and the cap becomes decorative. Assert, don't assume.
    if [[ "$(ps -o pgid= -p "$pg" 2>/dev/null | tr -d ' ')" != "$pg" ]]; then
        say "     🔴 pgid($pg) != $pg -- the ${CAP}s cap cannot kill the tree; aborting the arm"
        kill -TERM "$pg" 2>/dev/null; ndt down >/dev/null 2>&1; exit 3
    fi

    capped=0
    while kill -0 "$pg" 2>/dev/null; do
        if (( $(date +%s) - t0 >= CAP )); then
            capped=1
            say "## boot $i: HIT THE ${CAP}s CAP -- dumping before the kill"
            grab_dump "$upout" "$tag"
            kill -TERM -"$pg" 2>/dev/null; sleep 5; kill -KILL -"$pg" 2>/dev/null
            break
        fi
        sleep 2
    done
    wait "$pg" 2>/dev/null
    wall=$(( $(date +%s) - t0 ))

    # Did this iteration straddle a suspend? If so its wall is meaningless -- see the header.
    if [[ "$(suspends_since "$t0")" != "$susp0" ]]; then
        say "## boot $i: CONTAMINATED (suspend during the boot) wall=${wall}s -- excluded from the rate"
        contaminated=$((contaminated+1))
        continue
    fi

    xx=$(grep -cE '^\s+XX' "$upout" || true)
    read -r hosts edges down <<< "$(twin_read)"
    if (( capped == 0 )) && [ "$xx" -eq 0 ] && [ "$hosts" = "128" ] && [ "$down" = "0" ]; then
        verdict="CONVERGED"
    else
        sleep 20   # the kernel re-polls every 5s; a t+0 read races it
        read -r hosts edges down <<< "$(twin_read)"
        if (( capped == 0 )) && [ "$xx" -eq 0 ] && [ "$hosts" = "128" ] && [ "$down" = "0" ]; then
            verdict="CONVERGED (at t+20)"
        else
            verdict="FAILED"
            (( capped == 0 )) && grab_dump "$upout" "$tag"
            cp -f "$RYULOG" "$RAW/${tag}_ryu.log" 2>/dev/null || true
        fi
    fi

    [ "${verdict%% *}" = "CONVERGED" ] && oks=$((oks+1)) || fails=$((fails+1))
    say "## boot $i: $verdict  wall=${wall}s  XX=$xx  ryu_hosts=${hosts}/128  graph=${edges}e/${down}d"

    # Assert the injection landed, every iteration, not once at the start (§5-P item 5.1: without
    # the flag you measure the baseline and call the fix ineffective). The banner is printed at
    # intelligent_router.py:213 on import, so its absence means ryu never saw the variable.
    if [[ "$ARM" == "async" ]]; then
        if grep -q "load_static_topology will run OFF the event handler" "$RYULOG" 2>/dev/null; then
            say "     flag asserted: async banner present in ryu.log"
        else
            say "     🔴 ASYNC BANNER ABSENT -- this boot ran WITHOUT the fix; row is not evidence"
        fi
    fi
done

ndt down >/dev/null 2>&1
say "# rate: $fails of $((fails+oks)) failed to converge  (contaminated, excluded: $contaminated)"
say "done -> $OUT"
