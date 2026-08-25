#!/usr/bin/env bash
# phase3_b_verify.sh [BOOTS] -- does B hold its invariant, and does the boot still work?
#
# [Co-developed with claude code -- Adam]
#
# READ-OUT IS PRE-REGISTERED in PREREG-B.md sections 1 and 3. Two things are measured and they
# are judged separately:
#
#   1. THE INVARIANT (primary). No synchronous topology request-reply on IntelligentRyu's event
#      loop, asserted by assert_invariant.py against dumps SAMPLED THROUGHOUT the boot. Sampling
#      matters: the claim is that the loop is never parked there, and a single dump taken after
#      the boot settles cannot say anything about the minute before it. Phase 2 has exactly that
#      gap -- fixa1's dump ran after recovery and showed six empty queues.
#
#   2. THE BOOT (secondary). The fidelity pair, edges_down == 0 and hosts_ipv4 == 128, which is
#      the criterion Phase 2 established after `ent >= 10` turned out to measure how often one
#      handler reached a log line rather than whether the boot worked.
#
# The invariant does NOT need the wedge to be summonable, which is why it is primary. Target rate
# is recorded for context and is not a gate here (PREREG-B section 4.4).
#
# INJECTION ASSERTION FIRST, as in Phase 2: no worker heartbeat in the dump means B is not in the
# running router, and the row is not evidence either way.
set -uo pipefail

BOOTS=${BOOTS:-3}
export NDT_OWNER=maindev-0825
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$(cd "$(dirname "$0")" && pwd)"
RAW="$DIR/raw"; mkdir -p "$RAW"
OUT="$DIR/phase3_b_verify.txt"
RYU=http://localhost:8080
KERNEL=http://localhost:8000
RYULOG="$REPO/.test_run/logs/ryu.log"
DUMP=/tmp/ndtwin_ryu_greenlets.txt
CAP=600
SAMPLE_EVERY=6

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
teardown() { local rc=0; ndt down >/dev/null 2>&1 || rc=$?; (( rc==0 )) && say "# torn down (rc=0)" || say "# 🔴 ndt down rc=$rc"; }
trap 'teardown' EXIT INT TERM

for v in NDTWIN_RYU_SETTLE_S NDTWIN_RYU_LLDP_GUARD NDTWIN_RYU_LLDP_BACKOFF \
         NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL NDTWIN_RYU_TOPO_QUERY_TIMEOUT_S \
         NDTWIN_RYU_TOPO_DEADLINE_S; do
    [[ -n "${!v:-}" ]] && { echo "ABORT: $v='${!v}' is set in the environment." >&2; exit 2; }
done

say ""
say "# ============================================================================"
say "# PHASE 3 -- B: rebuild off the event loop. Invariant primary, boot secondary."
say "# ============================================================================"
say "# date:    $(date +%Y-%m-%dT%H:%M:%S%z)   commit: $(git -C "$REPO" rev-parse --short HEAD)"
say "# router:  sha256=$(sha256sum "$REPO/intelligent_router.py" | cut -c1-16)  $(git -C "$REPO" diff --quiet HEAD -- intelligent_router.py && echo "matches HEAD" || echo "MODIFIED vs HEAD")"
say "# boot_id: $(cat /proc/sys/kernel/random/boot_id)  uptime_h=$(awk '{printf "%.2f", $1/3600}' /proc/uptime)"
say "# context: Phase 0 measured the target at 2/3 (uptime 20.09h, same boot_id)"
say "# note:    target rate is CONTEXT here, not a gate -- the invariant does not need the wedge"
say "# boots:   $BOOTS   dump sampled every ${SAMPLE_EVERY}s during boot"

suspends_since() { journalctl -k --since "@$1" --no-pager 2>/dev/null | grep -c "PM: suspend entry"; }

wedge=0; ok=0; void=0; viol=0
for b in $(seq 1 "$BOOTS"); do
    tag="b${b}"
    upout="$RAW/${tag}_up.out"
    ndt down >/dev/null 2>&1; sleep 3
    : > "$DUMP"

    t0=$(date +%s); susp0=$(suspends_since "$t0")
    setsid bash -c "cd '$REPO' && exec ndt up ovs" > "$upout" 2>&1 &
    pg=$!
    capped=0; samples=0; last=0
    while kill -0 "$pg" 2>/dev/null; do
        now=$(date +%s)
        # Sample THROUGHOUT, not at the end. This is the whole difference from Phase 2's dump.
        if (( now - last >= SAMPLE_EVERY )); then
            pid=$(pgrep -f "ryu-manager --observe-links" 2>/dev/null | head -1)
            if [[ -n "$pid" ]]; then kill -USR2 "$pid" 2>/dev/null && samples=$((samples+1)); fi
            last=$now
        fi
        if (( now - t0 >= CAP )); then
            capped=1; say "## $tag: HIT ${CAP}s CAP"
            kill -TERM -"$pg" 2>/dev/null; sleep 5; kill -KILL -"$pg" 2>/dev/null; break
        fi
        sleep 2
    done
    wait "$pg" 2>/dev/null
    wall=$(( $(date +%s) - t0 ))

    cp -f "$DUMP" "$RAW/${tag}_greenlets.txt" 2>/dev/null || true
    cp -f "$RYULOG" "$RAW/${tag}_ryu.log" 2>/dev/null || true
    L="$RAW/${tag}_ryu.log"; D="$RAW/${tag}_greenlets.txt"

    # --- injection assertion, before anything is read as a result ---
    hb=$(grep -c "topology worker heartbeat" "$D" 2>/dev/null); [[ "$hb" =~ ^[0-9]+$ ]] || hb=0
    q=$(grep -c "switch-enter queued for topology rebuild" "$L" 2>/dev/null); [[ "$q" =~ ^[0-9]+$ ]] || q=0
    if (( hb == 0 || q == 0 )); then
        say "## $tag: 🔴 INJECTION NOT ASSERTED (heartbeat=$hb queued-lines=$q) -- B not in the"
        say "     running router; this row is not evidence in either direction"
        void=$((void+1)); continue
    fi
    if [[ "$(suspends_since "$t0")" != "$susp0" ]]; then
        say "## $tag: CONTAMINATED (suspend) -- excluded"; void=$((void+1)); continue
    fi

    # --- 1. the invariant ---
    inv=$(python3 "$DIR/assert_invariant.py" "$D" 2>&1); irc=$?
    loops=$(printf '%s' "$inv" | sed -n 's/.*, \([0-9]*\) event-loop stack(s).*/\1/p')
    hits=$(printf '%s' "$inv" | sed -n 's/.*examined, \([0-9]*\) violation(s).*/\1/p')
    (( irc == 0 )) || viol=$((viol+1))

    # --- 2. the boot ---
    h=$(curl -sf --max-time 5 "$RYU/v1.0/topology/hosts" 2>/dev/null | python3 -c "
import json,sys
try: print(sum(1 for x in json.load(sys.stdin) if x.get('ipv4')))
except Exception: print(-1)" 2>/dev/null); [[ "$h" =~ ^-?[0-9]+$ ]] || h=-1
    g=$(curl -sf --max-time 5 "$KERNEL/ndt/get_graph_data" 2>/dev/null | python3 -c "
import json,sys
try:
    e=json.load(sys.stdin)['edges']; print(len(e), sum(1 for x in e if not x.get('is_up',True)))
except Exception: print('? ?')" 2>/dev/null) || g="? ?"
    edges_down=$(printf '%s' "$g" | awk '{print $2}')
    if [[ "$edges_down" == "0" && "$h" == "128" ]]; then cls="CONVERGED"; ok=$((ok+1))
    else cls="NOT-CONVERGED"; wedge=$((wedge+1)); fi

    rb=$(grep -c "Topology update triggered" "$L"); tto=$(grep -c "topology read did not answer" "$L")
    ab=$(( $(grep -c "Switch list is empty after timeout" "$L") + $(grep -c "Link list unavailable after timeout" "$L") ))
    say "## $tag: $cls  invariant=$( (( irc==0 )) && echo HOLDS || echo 🔴VIOLATED )  wall=${wall}s"
    say "     dumps=$samples  event-loop stacks examined=${loops:-?}  violations=${hits:-?}"
    say "     events_queued=$q  rebuilds=$rb (coalesced $(( q > rb ? q - rb : 0 )))  topo-timeouts=$tto  aborts=$ab"
    say "     hosts_ipv4=$h  edges(total down)=$g"
    printf '%s\n' "$inv" | grep "VIOLATION" | sed 's/^/     /' | tee -a "$OUT"
done

say ""
say "# ---------------------------------------------------------------------------"
say "# RESULT: converged=$ok  not-converged=$wedge  void=$void  invariant-violations=$viol (of $BOOTS)"
n=$(( ok + wedge ))
if (( n == 0 )); then say "# VERDICT: no usable boots -- rerun"
elif (( viol > 0 )); then
    say "# VERDICT: FAIL -- a topology request-reply still ran on the event loop. The frames above"
    say "#          name the call that was missed; B's relocation is incomplete."
elif (( wedge == 0 )); then
    say "# VERDICT: PASS -- invariant held across every sampled dump AND all boots converged."
    say "#          Claim is the invariant, NOT a wedge rate: this says the ring's precondition"
    say "#          cannot arise from this handler, not that no ring can ever form. The"
    say "#          occupation-source census is still not done (PREREG-B section 6)."
else
    say "# VERDICT: PARTIAL -- invariant held but $wedge boot(s) did not converge. That is a"
    say "#          separate defect from the ring and must NOT be recorded as B failing."
fi
say "# (read-out per PREREG-B.md sections 1 and 3; injection asserted before any of it)"
