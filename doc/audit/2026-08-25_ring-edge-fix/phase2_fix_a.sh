#!/usr/bin/env bash
# phase2_fix_a.sh [BOOTS] -- does bounding :791/:818 break the ring?
#
# [Co-developed with claude code -- Adam]
#
# GATE, NOT A RESULT. Pre-registered in PREREG.md before this ran. The fix arm (Phase 2) does not
# run unless this says the target is alive, because a fix arm measured against a cold target
# proves nothing -- that is exactly how 2026-08-24's round burned a day (§5-Q: same commit, 6/10
# then 10/10, and both fixes went unverified).
#
# The target decays and NOT monotonically: same boot_id, 17.48h uptime -> 4/4 wedge, 18.43h -> 1/4.
# So the rate has to be measured now, not looked up.
#
# STOP CONDITION, written down before the first boot:
#   >=2/3 wedge -> target alive, Phase 2 may run
#     0/3       -> STOP. Do not run the fix arm.
#     1/3       -> extend to 6 boots and re-judge.
#
# WHY THIS IS NOT ring_fix_verify.sh's defaults ARM. That script asserts the async banner is
# ABSENT in its defaults arm, which was correct when async was opt-in and became wrong the moment
# 1b25cda flipped the default. §5-R offers two legitimate reruns; this is the second one -- drop
# the check and RENAME the arm -- because the question here is "what is the CURRENT defaults rate"
# and current defaults means async ON. The old raws still mean what they meant; they measured a
# different arm, which is why it gets a different name.
#
# The banner assertion is therefore INVERTED rather than deleted: the banner MUST be present, or
# this is not running current defaults and the row is not evidence.
#
# CLASSIFICATION is by the rule pre-registered in PREREG.md and validated against 47 archived ryu
# logs (P1 47/47, P2 zero violations) BEFORE this script existed:
#   P1  "Complete get_link" count == "Switch entered:" count           (code order, no blocking between)
#   P2  triggered - "Complete get_switch" == 1  <=> parked in get_switch
#                                        == 0 and gsw > glk <=> parked in get_link
#                                        == 0 and gsw == glk <=> handler completed; blocked downstream
# A P1 violation means the rule is wrong and the run must be read by dump only -- it is printed
# loudly rather than swallowed.
set -uo pipefail

BOOTS=${BOOTS:-3}
export NDT_OWNER=maindev-0825
REPO=/home/adam/Desktop/NDTwin-Kernel
DIR="$(cd "$(dirname "$0")" && pwd)"
RAW="$DIR/raw"; mkdir -p "$RAW"
OUT="$DIR/phase2_fix_a.txt"
RYU=http://localhost:8080
KERNEL=http://localhost:8000
RYULOG="$REPO/.test_run/logs/ryu.log"
DUMP=/tmp/ndtwin_ryu_greenlets.txt
CAP=600

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

teardown() { local rc=0; ndt down >/dev/null 2>&1 || rc=$?; (( rc==0 )) && say "# torn down (rc=0)" || say "# 🔴 ndt down rc=$rc"; }
trap 'teardown' EXIT INT TERM

# An env var left over from a previous experiment would silently redefine "defaults".
for v in NDTWIN_RYU_SETTLE_S NDTWIN_RYU_LLDP_GUARD NDTWIN_RYU_LLDP_BACKOFF \
         NDTWIN_RYU_ASYNC_TOPOLOGY_INSTALL NDTWIN_RYU_TOPO_FILE NDTWIN_CLONE_DISABLE; do
    [[ -n "${!v:-}" ]] && { echo "ABORT: $v='${!v}' is set in the environment." >&2; exit 2; }
done

say ""
say "# ============================================================================"
say "# PHASE 2 -- fix A: bounded get_switch/get_link (PREREG 5-bis read-out)"
say "# ============================================================================"
say "# date:    $(date +%Y-%m-%dT%H:%M:%S%z)   commit: $(git -C "$REPO" rev-parse --short HEAD)"
say "# router:  sha256=$(sha256sum "$REPO/intelligent_router.py" | cut -c1-16)  $(git -C "$REPO" diff --quiet HEAD -- intelligent_router.py && echo "matches HEAD" || echo "MODIFIED vs HEAD")"
say "# boot_id: $(cat /proc/sys/kernel/random/boot_id)  uptime_h=$(awk '{printf "%.2f", $1/3600}' /proc/uptime)"
say "# arm:     CURRENT defaults (async ON since 1b25cda) -- NOT ring_fix_verify's 'defaults'"
say "# gate:    Phase 0 said TARGET ALIVE 2/3 at uptime 20.09h, same boot_id
# read:    BREAK / RELOCATE / FALSIFY -- but ONLY after the injection assertion"
say "# boots:   $BOOTS"

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
        # e27283a: the queue census. This is the line that turns "IR's queue must be the full one"
        # from elimination into observation. Printed here so it is in the transcript too, not only
        # in the archived dump.
        if grep -q "app event queues" "$RAW/${tag}_greenlets.txt"; then
            say "     --- queue census (last dump) ---"
            awk '/app event queues/{f=1} f&&/^    [a-zA-Z]/{print "     " $0} /greenlet object\(s\)/{f=0}' \
                "$RAW/${tag}_greenlets.txt" | tail -20 | tee -a "$OUT" >/dev/null
            awk '/app event queues/{f=1} f&&/^    [a-zA-Z]/{print "     " $0} /greenlet object\(s\)/{f=0}' \
                "$RAW/${tag}_greenlets.txt" | tail -20
        else
            say "     🔴 no queue census in dump -- e27283a not in the running router?"
        fi
    else
        say "     dump empty"
    fi
}

wedge=0; ok=0; void=0
for b in $(seq 1 "$BOOTS"); do
    tag="fixa${b}"
    upout="$RAW/${tag}_up.out"
    ndt down >/dev/null 2>&1; sleep 3

    t0=$(date +%s); susp0=$(suspends_since "$t0")
    setsid bash -c "cd '$REPO' && exec ndt up ovs" > "$upout" 2>&1 &
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

    ent=$(grep -c "Switch entered:" "$RYULOG" 2>/dev/null); [[ "$ent" =~ ^[0-9]+$ ]] || ent=0
    if (( capped == 0 )) && (( ent < 10 )); then grab_dump "$tag"; fi
    cp -f "$RYULOG" "$RAW/${tag}_ryu.log" 2>/dev/null || true
    L="$RAW/${tag}_ryu.log"

    # Assert we are running CURRENT defaults. Inverted from ring_fix_verify on purpose (see header).
    banner=$(grep -c "run OFF the event handler" "$L" 2>/dev/null); [[ "$banner" =~ ^[0-9]+$ ]] || banner=0
    if (( banner == 0 )); then
        say "## $tag: 🔴 async banner ABSENT -- this is not current defaults; row is not evidence"
        void=$((void+1)); continue
    fi

    if [[ "$(suspends_since "$t0")" != "$susp0" ]]; then
        say "## $tag: CONTAMINATED (suspend) -- excluded"; void=$((void+1)); continue
    fi

    # PREREG 5-bis R1: the cumulative rule is INVALID here -- fix A makes the abort path normal
    # and the abort path has the same cumulative signature as a park. Three legs instead.
    verdict=$(python3 "$DIR/classify_boot.py" "$L")
    state=$(printf '%s' "$verdict" | awk -F': *' '/verdict/{print $2}')
    chain=$(printf '%s' "$verdict" | awk -F': *' '/last chain/{print $2}')
    tto=$(grep -c "topology read did not answer" "$L")
    ab1=$(grep -c "Switch list is empty after timeout" "$L")
    ab2=$(grep -c "Link list unavailable after timeout" "$L")
    to=$(grep -c "host-table read did not answer" "$L")
    trig=$(grep -c "Topology update triggered" "$L"); gsw=$(grep -c "Complete get_switch" "$L")
    glk=$(grep -c "Complete get_link" "$L")

    # PREREG 5-bis R2: injection assertion runs BEFORE the three-way read-out. A boot that is not
    # healthy and shows zero timeout lines has not tested the fix -- it means the fix was not in
    # the binary, which is a different finding from the fix not working.
    if (( ent < 10 )) && (( tto == 0 )); then
        say "## $tag: 🔴 INJECTION NOT ASSERTED -- not healthy yet zero 'topology read did not answer'"
        say "     this row does NOT count as FALSIFY; check the running router carries the fix"
        void=$((void+1)); continue
    fi

    # 🔴 CORRECTED 2026-08-25 after fixa1: `ent >= 10` is NOT a success test. It counts how
    # often ONE handler ran to its log line; fixa1 scored 3 while its twin converged completely.
    # The twin's state comes from the kernel POLLING Ryu, not from anything ent measures.
    # Success is the fidelity pair, and the ring is judged separately from it.
    edges_total=$(printf '%s' "$g" | awk '{print $1}'); edges_down=$(printf '%s' "$g" | awk '{print $2}')
    if [[ "$edges_down" == "0" && "$h" == "128" ]]; then
        cls="CONVERGED ($state)"; ok=$((ok+1))
    else
        cls="NOT-CONVERGED ($state)"; wedge=$((wedge+1))
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

    say "## $tag: $cls  wall=${wall}s  chain=$chain  trig=$trig gsw=$gsw glk=$glk ent=$ent"
    say "     topo-timeouts=$tto  aborts=${ab1}+${ab2}  host-timeouts=$to  hosts_ipv4=$h  edges(total down)=$g"
done

say ""
say "# ---------------------------------------------------------------------------"
say "# RESULT: wedge=$wedge  healthy=$ok  void=$void  (of $BOOTS)"
n=$(( wedge + ok ))
say "# Phase 0 baseline, same boot_id ~1h earlier: ring 2/3, converged 1/3"
say "# NOTE success = fidelity pair (edges_down==0 and hosts_ipv4==128), NOT ent>=10"
if (( n == 0 )); then
    say "# VERDICT: no usable boots -- rerun"
elif (( wedge == 0 )); then
    say "# VERDICT: BREAK candidate ($ok/$n healthy). Claim is limited to '#1/#2 were the CURRENT"
    say "#          ring edges' (PREREG 5-bis R3). Small N does NOT close the occupation-source"
    say "#          question -- check the fidelity columns above before calling this a fix."
else
    say "# VERDICT: still wedging $wedge/$n -- read the per-boot state above:"
    say "#          WEDGE:PARKED@get_switch/get_link  -> FALSIFY (mechanism wrong)"
    say "#          any other parked site             -> RELOCATE (mechanism right, fix partial)"
fi
say "# (read-out per PREREG.md 5-bis; injection asserted before any of this)"
