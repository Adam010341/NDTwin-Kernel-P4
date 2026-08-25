#!/usr/bin/env bash
# phase4_queue_pressure.sh [PAIRS] -- does the LLDP guard move queue pressure, under B?
#
# [Co-developed with claude code -- Adam]
#
# WHY NOT A WEDGE RATE. Adam asked whether our own speed-ups raised the failure rate -- the prime
# suspect being NDTWIN_RYU_LLDP_GUARD 0.05 -> 0.01, which makes LLDP packet-ins arrive ~5x faster
# into the same 128-slot queue that filling was half the ring. That question can no longer be
# answered by counting wedges: B removed them, so both arms would read 0/N and prove nothing.
#
# So this measures the quantity the guard was ever suspected of moving -- how full the queue
# actually gets -- sampled throughout the boot. Pre-B wedges peaked at 128/128 with 12 and 43
# blocked emitters; B's three boots peaked at 1/128. If 0.05 and 0.01 both sit near zero here,
# then ARRIVAL RATE never filled that queue and a stalled event loop did, which is also the first
# real evidence for the occupation-source question no round has touched.
#
# INTERLEAVED, because machine condition drifts with uptime and a blocked design would let drift
# impersonate the effect.
#
# READ-OUT for the invariant and fidelity legs is unchanged from PREREG-B sections 1 and 3:
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

PAIRS=${PAIRS:-3}
export NDT_OWNER=maindev-0825
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$(cd "$(dirname "$0")" && pwd)"
RAW="$DIR/raw"; mkdir -p "$RAW"
OUT="$DIR/phase4_queue_pressure.txt"
RYU=http://localhost:8080
KERNEL=http://localhost:8000
RYULOG="$REPO/.test_run/logs/ryu.log"
DUMP=/tmp/ndtwin_ryu_greenlets.txt
CAP=600
SAMPLE_EVERY=6

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
teardown() { local rc=0; ndt down >/dev/null 2>&1 || rc=$?; (( rc==0 )) && say "# torn down (rc=0)" || say "# 🔴 ndt down rc=$rc"; }
trap 'teardown' EXIT INT TERM

for v in NDTWIN_RYU_SETTLE_S NDTWIN_RYU_LLDP_BACKOFF \
         NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL NDTWIN_RYU_TOPO_QUERY_TIMEOUT_S \
         NDTWIN_RYU_TOPO_DEADLINE_S; do
    [[ -n "${!v:-}" ]] && { echo "ABORT: $v='${!v}' is set in the environment." >&2; exit 2; }
done

say ""
say "# ============================================================================"
say "# PHASE 4 -- guard 0.01 vs 0.05 under B: queue pressure, not wedge rate"
say "# ============================================================================"
say "# date:    $(date +%Y-%m-%dT%H:%M:%S%z)   commit: $(git -C "$REPO" rev-parse --short HEAD)"
say "# router:  sha256=$(sha256sum "$REPO/intelligent_router.py" | cut -c1-16)  $(git -C "$REPO" diff --quiet HEAD -- intelligent_router.py && echo "matches HEAD" || echo "MODIFIED vs HEAD")"
say "# boot_id: $(cat /proc/sys/kernel/random/boot_id)  uptime_h=$(awk '{printf "%.2f", $1/3600}' /proc/uptime)"
say "# context: Phase 0 measured the target at 2/3 (uptime 20.09h, same boot_id)"
say "# note:    target rate is CONTEXT here, not a gate -- the invariant does not need the wedge"
say "# pairs:   $PAIRS interleaved (guard default 0.01 vs 0.05)  dump every ${SAMPLE_EVERY}s"
say "# baseline: pre-B wedges peaked 128/128 (12 and 43 blocked); B boots peaked 1/128"

suspends_since() { journalctl -k --since "@$1" --no-pager 2>/dev/null | grep -c "PM: suspend entry"; }

wedge=0; ok=0; void=0; viol=0
for p in $(seq 1 "$PAIRS"); do
for arm in g001 g005; do
    tag="${arm}_p${p}"
    upout="$RAW/${tag}_up.out"
    ndt down >/dev/null 2>&1; sleep 3
    : > "$DUMP"

    t0=$(date +%s); susp0=$(suspends_since "$t0")
    if [[ "$arm" == "g005" ]]; then
        setsid bash -c "cd '$REPO' && NDTWIN_RYU_LLDP_GUARD=0.05 exec ndt up ovs" > "$upout" 2>&1 &
    else
        setsid bash -c "cd '$REPO' && exec ndt up ovs" > "$upout" 2>&1 &
    fi
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
    gset=$(grep -c "LLDP_SEND_GUARD overridden" "$L" 2>/dev/null); [[ "$gset" =~ ^[0-9]+$ ]] || gset=0
    if [[ "$arm" == "g005" && "$gset" -eq 0 ]]; then
        say "## $tag: 🔴 GUARD OVERRIDE ABSENT -- ran at the default; row is not evidence"
        void=$((void+1)); continue
    fi
    if [[ "$arm" == "g001" && "$gset" -ne 0 ]]; then
        say "## $tag: 🔴 guard override present in the DEFAULT arm -- environment leak; aborting"
        exit 3
    fi
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
    say "     $(python3 "$DIR/queue_pressure.py" "$D" | sed "s|^[^:]*: ||")"
    printf '%s\n' "$inv" | grep "VIOLATION" | sed 's/^/     /' | tee -a "$OUT"
done
done

say ""
say "# ---------------------------------------------------------------------------"
say "# RESULT: converged=$ok  not-converged=$wedge  void=$void  invariant-violations=$viol"
say "# COMPARE the peak-queue lines between g001 and g005 rows above -- that is the question."
n=$(( ok + wedge ))
if (( n == 0 )); then say "# VERDICT: no usable boots -- rerun"
elif (( viol > 0 )); then
    say "# VERDICT: FAIL -- a topology request-reply still ran on the event loop. The frames above"
    say "#          name the call that was missed; B's relocation is incomplete."
elif (( wedge == 0 )); then
    say "# VERDICT: boots healthy in both arms. Guard verdict is the peak-queue comparison,
#          NOT this line. PASS -- invariant held across every sampled dump AND all boots converged."
    say "#          Claim is the invariant, NOT a wedge rate: this says the ring's precondition"
    say "#          cannot arise from this handler, not that no ring can ever form. The"
    say "#          occupation-source census is still not done (PREREG-B section 6)."
else
    say "# VERDICT: PARTIAL -- invariant held but $wedge boot(s) did not converge. That is a"
    say "#          separate defect from the ring and must NOT be recorded as B failing."
fi
say "# (read-out per PREREG-B.md sections 1 and 3; injection asserted before any of it)"
