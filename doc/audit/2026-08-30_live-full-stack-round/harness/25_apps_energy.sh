#!/bin/bash
# =================================================================================================
#  ######  ##### ##### ####  #   # #####  ##### #   # ####    #### #   # #####  #####  ##### #   #
#  #    # #     #        #   ##  # #    # #     ##  # #   #  #     #   # #    #   #    #     #   #
#  ######  ###  #####    #   # # # #    # #     # # # #   #   ###  ##### #####    #    #     #####
#  #    #     # #        #   #  ## #    # #     #  ## #   #      # #   # #   #    #    #         #
#  #    # ##### #####    #   #   # #####  ##### #   # ####   ####  #   # #    #   #    ##### #####
#
#            ############################################################
#            #  THIS SCRIPT POWERS REAL SWITCHES OFF.                   #
#            #  IT MUST BE THE LAST PHASE OF THE ROUND.                 #
#            #  NOTHING MEASURED AFTER IT IS COMPARABLE TO ANYTHING     #
#            #  MEASURED BEFORE IT, UNTIL 90_restore.sh HAS RUN.        #
#            ############################################################
#
# 25_apps_energy.sh -- start the Energy-Saving-App, let it act, record what it did, stop it.
#
# RUN STATUS: this line used to read "WRITTEN, NOT RUN. `bash -n` only." That is no longer true
# and is corrected rather than left, because the next reader would take it as a reason to
# distrust FINDING-05 instead of this script. It has been run twice:
#   P4 arm, 2026-08-30 15:30 -- 3 switches powered off (s9, s7, s5), watch 250 s.
#   OVS arm, 2026-08-30 15:53 -- 0 switches powered off, watch 474 s despite requesting 240 s.
# ⚠️ Both watches overlapped `agy` jobs of ~2 cores each, invisible to `ndt status`
#    (CONTAMINATION-agy-runs-i-started-myself.md). CPU contention is a live alternative
#    explanation for the P4/OVS difference and it was heavier on the arm that did nothing, so
#    that comparison is NOT controlled. Its re-run must have zero commits in the window.
#
# WHY IT IS ITS OWN PHASE, WITH ITS OWN SWITCH
#   The Energy-Saving-App reads link utilisation, and on a quiet network it concludes the network
#   is idle and powers switches down -- three of ten within 60 s on 2026-08-18 (F-2 / N-1). That
#   is CORRECT behaviour, and it is also a change to the thing every other measurement in this
#   round is measuring. Running it concurrently with R-2/R-3 sampling would put a treatment
#   effect inside the control period.
#   It is enabled only by an explicit flag, so that running the whole harness top to bottom
#   cannot power the fabric down by accident.
#
# WHAT IT WILL DO, SO NOBODY IS SURPRISED
#   * `sudo -n ndtwin-lab energy-start` (ndt:1564), in a tmux session named `energy`.
#   * The app polls every 60 s (Energy-Saving-App/include/app/settings.hpp:8), sums
#     link_bandwidth_utilization_percent over up+enabled edges (types.cpp:411,427), and when a
#     group is <= LOW_WATER_MARK = 0.40 it calls easy_disable_switch
#     (energy_saving_app.cpp:911,926) -> POST /ndt/set_switches_power_state action=off.
#   * Its power loop is gated by /ndt/acquire_lock (energy_saving_app.cpp:952). PREREG §5 puts
#     that endpoint's three defects OUT OF SCOPE: this round exercises it incidentally and does
#     not test it. Do not write up anything about acquire_lock from this script.
#
# HOW TO PUT IT BACK
#   90_restore.sh. Two routes, in order of preference:
#     1. POST /ndt/set_switches_power_state action=on for each switch it turned off, then verify
#        nodes/edges back to full. Verified working three times (08-18 N-8, within 45 s).
#     2. If that does not restore full counts: `ndt down` then `ndt up <same args>`, which
#        rebuilds the fabric from scratch. This is the guaranteed route and the one to use if
#        anything at all looks wrong.
#   🔑 On OVS, a power off/on cycle does NOT restore link shaping on the cycled switch's 1 Gbps
#      ports (F-7a, corrected: 4 interfaces, not 20). So after an energy phase on OVS the fabric
#      is not bit-identical to before it, and route 2 (full rebuild) is the only true restore.
#      On P4 there is no htb at all (N-4), so this does not apply.
#
# H-CORRESPONDENCE
#   H-17  liveness via /proc only. The app runs under sudo in a tmux session, so `kill -0` from
#         this shell would return EPERM and read as dead -- precisely H-17. Its running state is
#         read from `ndt apps status`, which uses ndt's own lab_session predicate, and from the
#         kernel's view of the network. Never from a signal probe.
#   H-18  the power effect is observed through the kernel graph's own fields (is_up,
#         admin_disabled), not by grepping the app's log for a word we hope it prints.
#   H-19  `ndt status` and the graph fetch are separate observations; a kernel that answers with
#         a degraded graph is answering.
#   H-20  the graph is fetched fresh before and after; nothing is inherited. The BEFORE snapshot
#         is taken in this script rather than reused from 00_preflight.sh, because the round has
#         been running in between and the earlier one would describe a different moment. Two
#         states from two moments is not a comparison (08-18 N-6).
#   H-21  pipefail; gates take pre-computed values.
#   H-22  nothing is backgrounded here; start/stop go through ndt's own NOPASSWD verbs.
#   H-23  see H-18.
#   H-24  n/a.
#
# THE RULE THIS SCRIPT EXISTS TO OBEY
#   Every injection asserts its own success. "energy-start returned 0" is not evidence that
#   anything was powered off; on a fabric carrying traffic the app may correctly decide to power
#   nothing off at all. That outcome is NOT a failure -- it is "no longer reachable this run",
#   and the F-2/F-3 checks downstream must be marked untestable rather than passed.
#
# [Co-developed with claude code -- Adam]
# =================================================================================================
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
harness_begin 25_apps_energy

if [[ "${1:-}" != "--yes-power-switches-off" ]]; then
    cat <<'EOF'

  REFUSING TO RUN WITHOUT AN EXPLICIT FLAG.

  This phase powers real switches down. Re-invoke as:

      ./25_apps_energy.sh --yes-power-switches-off

  Before you do:
    * every other phase of the round must be finished (10, 20, 30, 40, 50)
    * you must be prepared to run 90_restore.sh afterwards
    * on OVS, plan on a full 'ndt down && ndt up' rebuild rather than power-on,
      because F-7a's shaping loss is not undone by powering the switch back on

EOF
    exit 2
fi

graph_counts() {
    # prints: switches up enabled admin_disabled hosts edges edges_down
    local slug="$1"
    http_probe "$slug" GET "$NDT_URL/ndt/get_graph_data" >/dev/null
    python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sw=[n for n in d.get("nodes",[]) if n.get("vertex_type")==0]
ed=d.get("edges",[])
print(len(sw),
      sum(1 for n in sw if n.get("is_up")),
      sum(1 for n in sw if n.get("is_enabled")),
      sum(1 for n in sw if n.get("admin_disabled")),
      sum(1 for n in d.get("nodes",[]) if n.get("vertex_type")==1),
      len(ed),
      sum(1 for e in ed if not e.get("is_up")))' "$OUT/http/$slug.body" 2>/dev/null || printf '? ? ? ? ? ? ?'
}

# util_max <slug> -- the highest link_bandwidth_utilization_percent in the graph body graph_counts
# already fetched, or "?" if the field is absent. No extra request.
#
# [Co-developed with claude code -- Adam]
# This exists so the N/A verdict below can be justified by the MEASURED condition instead of an
# asserted one. FINDING-05: the N/A text told the operator "on a network carrying traffic,
# declining to power down is correct ... stop all traffic generation and re-run this phase" on a
# fabric where utilisation was 0.0 on all 40 edges and `flows` was empty throughout. There was no
# traffic to stop; the suggested remedy was a no-op and the offered explanation was the opposite
# of the measured condition.
# 🔑 The verdict was RIGHT and the explanation attached to it was wrong, which is the more
#    dangerous kind: a reader takes the verdict on trust and inherits the reason with it.
util_max() {
    local slug="$1"
    python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
v=[e.get("link_bandwidth_utilization_percent") for e in d.get("edges",[])]
v=[x for x in v if isinstance(x,(int,float))]
print(max(v) if v else "?")' "$OUT/http/$slug.body" 2>/dev/null || printf '?'
}

down_switch_names() {
    python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(",".join(sorted(n.get("device_name","?") for n in d.get("nodes",[])
      if n.get("vertex_type")==0 and not n.get("is_up"))) or "none")' "$OUT/http/$1.body" 2>/dev/null || printf '?'
}

# -------------------------------------------------------------------------------------------------
say "BEFORE -- one snapshot, taken now, not reused from preflight"
read -r B_SW B_UP B_EN B_AD B_H B_E B_ED <<<"$(graph_counts energy_before)"
info "switches=$B_SW up=$B_UP enabled=$B_EN admin_disabled=$B_AD hosts=$B_H edges=$B_E edges_down=$B_ED"
info "switches currently down: $(down_switch_names energy_before)"
cp -f "$OUT/http/energy_before.body" "$OUT/graph_energy_before.json" 2>/dev/null || true
if [[ "$B_UP" != "$B_SW" ]]; then
    bad "the fabric is ALREADY degraded before energy starts ($B_UP/$B_SW up). Anything this phase attributes to the Energy-App would be confounded. Restore the fabric and re-run."
    summary; exit 1
fi
ok "fabric is intact before the energy phase ($B_UP/$B_SW switches up, $B_E edges, $B_ED down)"

# -------------------------------------------------------------------------------------------------
say "START the Energy-Saving-App"
set +e
"$NDT_BIN" apps energy > "$OUT/app_energy_start.log" 2>&1
set -e
sed 's/^/      /' "$OUT/app_energy_start.log" || true
"$NDT_BIN" apps status > "$OUT/apps_status_with_energy.txt" 2>&1 || true
if grep -qE '^  energy +running' "$OUT/apps_status_with_energy.txt"; then
    ok "energy reports running (via ndt's own lab_session predicate, not a signal probe -- H-17)"
else
    bad "energy did not come up; see $OUT/app_energy_start.log"
    summary; exit 1
fi
date +%s > "$OUT/energy_start_epoch"

# -------------------------------------------------------------------------------------------------
say "WATCH -- the app's cadence is 60 s, so watch for at least three cycles"
# 08-18: three switches off within 60 s. Its loop is 60 s (settings.hpp:8), so 240 s is four
# cycles: enough that "nothing happened" is a statement about the app rather than about our
# patience. Sampling every 10 s so a change and its timestamp are both recorded.
#
# [Co-developed with claude code -- Adam]
# FIXED 2026-08-30 (T-10, FINDING-05). This loop counted ITERATIONS, not seconds: `seq 0
# $((WATCH_S/10))` with a `sleep 10` inside, while each graph_counts query costs ~10 s on OVS and
# ~0 s on P4. The query time was not counted, so the window was whatever the fabric's response
# time made it. Measured on the OVS arm: 25 samples spanning 474 s at a mean interval of 19.8 s,
# reported as "in 240s". The comment stated the intent exactly and the implementation did
# something else.
#
# It happened to stretch here, which is harmless -- more chances for the app to act, and the
# report understates its own patience. 🔑 On a faster path the same construct SHORTENS the window
# silently, and then "nothing happened" is a statement about our patience after all, which is
# precisely what the 240 s was chosen to rule out.
#
# Driven from a deadline now, and the achieved span is reported rather than assumed. This is the
# third instance of an iteration count standing in for a time in this harness (the other two are
# FINDING-02's Defect A, viz and te). It is a house style, not a slip.
WATCH_S=240
: > "$OUT/energy_watch.tsv"
printf 'epoch\tup\tenabled\tadmin_disabled\tedges_down\tutil_max\tdown_names\n' >> "$OUT/energy_watch.tsv"
WATCH_T0="$(date +%s)"
WATCH_END=$(( WATCH_T0 + WATCH_S ))
WATCH_N=0
UTIL_MAX_SEEN=""
while :; do
    read -r W_SW W_UP W_EN W_AD W_H W_E W_ED <<<"$(graph_counts energy_watch)"
    W_UTIL="$(util_max energy_watch)"
    [[ "$W_UTIL" != "?" ]] && UTIL_MAX_SEEN="$(printf '%s\n%s\n' "${UTIL_MAX_SEEN:-0}" "$W_UTIL" | sort -g | tail -1)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$W_UP" "$W_EN" "$W_AD" "$W_ED" "$W_UTIL" "$(down_switch_names energy_watch)" \
        >> "$OUT/energy_watch.tsv"
    WATCH_N=$(( WATCH_N + 1 ))
    (( $(date +%s) >= WATCH_END )) && break
    sleep 10
done
WATCH_ACTUAL=$(( $(date +%s) - WATCH_T0 ))
sed 's/^/      /' "$OUT/energy_watch.tsv"
# Reported, not assumed. The number in the write-up must be the span that happened.
info "watch window: requested ${WATCH_S}s, ACHIEVED ${WATCH_ACTUAL}s over $WATCH_N samples (mean interval $(( WATCH_ACTUAL / (WATCH_N > 1 ? WATCH_N - 1 : 1) ))s)"
info "that is $(( WATCH_ACTUAL / 60 )) full 60 s app cycles, which is the number to quote -- not ${WATCH_S}s."
printf '%s\n' "$WATCH_ACTUAL" > "$OUT/energy_watch_actual_seconds.txt"

# -------------------------------------------------------------------------------------------------
say "AFTER -- and the assertion that the injection actually landed"
read -r A_SW A_UP A_EN A_AD A_H A_E A_ED <<<"$(graph_counts energy_after)"
cp -f "$OUT/http/energy_after.body" "$OUT/graph_energy_after.json" 2>/dev/null || true
A_NAMES="$(down_switch_names energy_after)"
info "switches=$A_SW up=$A_UP enabled=$A_EN admin_disabled=$A_AD edges=$A_E edges_down=$A_ED"
info "switches now down: $A_NAMES"
printf '%s\n' "$A_NAMES" > "$OUT/energy_powered_off.txt"

POWERED_OFF=$(( B_UP - A_UP ))
info "switches powered off by the app: $POWERED_OFF"

if (( POWERED_OFF > 0 )); then
    ok "INJECTION ASSERTED: the Energy-App powered $POWERED_OFF switch(es) off ($A_NAMES). Downstream F-2/F-3 checks are reachable."
    # Corroboration from a second, independent source -- the kernel's own POST log. One reading
    # is a reading; two readings that agree is an observation.
    if [[ -f "$LOG_DIR/kernel.log" ]] && grep -qE 'set_switches_power_state' "$LOG_DIR/kernel.log"; then
        ok "corroborated: the kernel log records set_switches_power_state requests"
    else
        bad "the graph changed but the kernel log has no set_switches_power_state line. Two of our own instruments disagree, which is a finding about the instruments until shown otherwise -- do not write up the graph delta until this is resolved."
    fi
    # The twin's accounting: every down edge should be incident to a down switch (08-18 N-1).
    python3 - "$OUT/graph_energy_after.json" > "$OUT/energy_edge_accounting.txt" 2>&1 <<'PY' || true
import json,sys
d=json.load(open(sys.argv[1]))
down={n["device_name"] for n in d["nodes"] if n.get("vertex_type")==0 and not n.get("is_up")}
dpid={n["dpid"] for n in d["nodes"] if n.get("vertex_type")==0 and not n.get("is_up")}
de=[e for e in d["edges"] if not e.get("is_up")]
unexplained=[e for e in de if e.get("src_dpid") not in dpid and e.get("dst_dpid") not in dpid]
print("down switches:", sorted(down))
print("down edges:", len(de))
print("down edges NOT incident to a down switch:", len(unexplained))
for e in unexplained[:10]:
    print("   ", e.get("src_dpid"), e.get("src_interface"), "->", e.get("dst_dpid"), e.get("dst_interface"))
PY
    sed 's/^/      /' "$OUT/energy_edge_accounting.txt" || true
    if grep -qE 'NOT incident to a down switch: 0$' "$OUT/energy_edge_accounting.txt"; then
        ok "every down edge is incident to a powered-off switch -- the twin's accounting is consistent"
    else
        bad "some down edges are not explained by the powered-off switches; see $OUT/energy_edge_accounting.txt"
    fi
else
    # PREREG §3 R-5's three-valued rule applied to the injection itself. The verdict is the same
    # either way; only the EXPLANATION is conditional, because the wrong explanation attached to a
    # correct verdict is what a reader inherits on trust. See util_max above.
    skip "the Energy-App powered NOTHING off in the ${WATCH_ACTUAL}s actually watched ($(( WATCH_ACTUAL / 60 )) cycles at its 60 s cadence). This is NOT a failure, but F-2 and F-3 are NO LONGER REACHABLE THIS RUN and must be recorded as untestable, not as fixed."
    if [[ "${UTIL_MAX_SEEN:-?}" == "?" || -z "${UTIL_MAX_SEEN:-}" ]]; then
        info "why: NOT ESTABLISHED. link_bandwidth_utilization_percent was not readable from the graph during the watch, so neither the traffic hypothesis nor any other can be checked from this run. Do not write a cause."
    elif awk "BEGIN{exit !($UTIL_MAX_SEEN > 0.40)}" 2>/dev/null; then
        info "why: PLAUSIBLY TRAFFIC. Peak link utilisation during the watch was $UTIL_MAX_SEEN%, above the app's LOW_WATER_MARK of 0.40 (energy_saving_app.cpp:911,926), so declining to power down is the correct decision. To make F-2/F-3 reachable, stop all traffic generation and re-run this phase."
    else
        info "why: NOT TRAFFIC, and the cause is NOT ESTABLISHED. Peak link utilisation during the watch was $UTIL_MAX_SEEN%, far BELOW the app's LOW_WATER_MARK of 0.40 -- the decision chain predicts a shutdown and it did not happen. Do NOT record 'the network was busy'; there was nothing to stop."
        info "     candidates NOT distinguished by this run: the app's grouping may reject these switches for a topology reason; the power loop is gated by /ndt/acquire_lock (energy_saving_app.cpp:952) and lock behaviour was not observed; the OVS path may differ elsewhere. One run per fabric is one run per fabric."
        info "     reaching this needs the app's own output, which needs the ndtwin-lab/ndt session-visibility disagreement resolved first (see 09_t8-t10-evidence.md §4)."
    fi
fi

# -------------------------------------------------------------------------------------------------
say "STOP the Energy-Saving-App"
set +e
"$NDT_BIN" apps stop energy > "$OUT/app_energy_stop.log" 2>&1
set -e
sed 's/^/      /' "$OUT/app_energy_stop.log" || true
"$NDT_BIN" apps status > "$OUT/apps_status_after_energy.txt" 2>&1 || true
if grep -qE '^  energy +running' "$OUT/apps_status_after_energy.txt"; then
    bad "energy is STILL RUNNING after 'ndt apps stop energy'. It will keep powering switches down under every subsequent step. Stop it by hand before doing anything else: sudo ndtwin-lab energy-stop"
else
    ok "energy stopped, verified from ndt apps status (a stop that reports success while the process survives is the failure this repo keeps re-finding)"
fi

info ""
# [Co-developed with claude code -- Adam]
# FIXED 2026-08-30 (T-10, FINDING-05 message 3). This banner used to print UNCONDITIONALLY,
# including immediately after the same script established "switches powered off by the app: 0",
# and with `ndt status` afterwards reading 10 up / 0 admin-disabled / 40 links / 0 down. Nothing
# was degraded.
#
# 🔑 Harmless in isolation; not harmless in combination. The restore it directed the operator to
#    was the one FINDING-04 shows tears the fabric down and stops. Following this instruction on
#    an undegraded OVS fabric would have destroyed a healthy fabric to fix nothing. Two defects
#    that are each survivable compose into one that is not.
#
# Gated on the count this script already computed. Nothing new is measured to decide it.
if (( POWERED_OFF > 0 )); then
    info "🔴 THE FABRIC IS NOW DEGRADED: the app powered $POWERED_OFF switch(es) off ($A_NAMES)."
    info "   Restore before any further measurement:"
    info "     ./90_restore.sh --rebuild '<the same args you used for ndt up>'   (P4: the only route that works)"
    info "     ./90_restore.sh power-on                                          (OVS: cheaper, but F-7a leaves 4 ports unshaped)"
else
    ok "the fabric is NOT degraded: the app powered 0 switches off, and this script changed nothing else."
    info "   Do NOT run ./90_restore.sh. There is nothing to restore, and its rebuild route would"
    info "   tear down a healthy fabric to fix nothing. Verify for yourself:  ndt status --check"
fi
summary
exit 0
