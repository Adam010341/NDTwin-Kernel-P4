#!/bin/bash
# =================================================================================================
# 50_r5_ovs.sh -- R-5 phase 2: F-1 .. F-5b on the OVS/Ryu stack.
#
# SECOND PHASE BY INSTRUCTION.  P4 is the professor's line and must produce a result first.
# This phase requires the fabric to be torn down and brought back up as OVS, which is why it is
# a separate script and not a flag on 40_r5_p4.sh.
#
# WRITTEN, NOT RUN. `bash -n` only.
#
# WHY THIS ARM MATTERS EVEN THOUGH P4 IS THE PRIORITY
#   Three of the six R-5 findings are OVS findings and CANNOT be reached on P4:
#     F-1  needs an OpenFlow reserved output port (OFPP_CONTROLLER = 0xFFFFFFFD).  It arrives
#          from the table-miss rule that `--observe-links` and the Ryu app install on every
#          switch, and the prio-0 rule matches every flow.
#     F-5  needs the switch to refuse a rule the kernel accepted.  On OVS the write is
#          fire-and-forget, so the refusal arrives later as an asynchronous OFPErrorMsg that
#          nothing listens for.
#     F-5b is the DIFFERENTIAL between the two stacks and is only half-answered by 40_r5_p4.sh.
#   If this phase never runs, those three must be reported as NOT RE-CHECKED -- which is a
#   fourth state, distinct from all three of R-5's verdicts, and must be written as such rather
#   than folded into "no longer reachable".
#
# H-CORRESPONDENCE
#   H-17  /proc via lib.sh `alive()` throughout.  Ryu and the Mininet topology run under sudo, so
#         a signal probe against them returns EPERM and reads as dead.
#   H-18  🔑 M-3 LIVES IN THIS PHASE.  The User Manual tells the reader to grep for
#         `ECONNREFUSED`; the software emits `Failed to connect to remote host: Connection
#         refused` and `[Errno 111] Connection refused`, and a check written from the page
#         printed PASS while all ten switches were unreachable.  The registered pattern here is
#         the emitted text, and `ECONNREFUSED` is its must-NOT-match sample.
#   H-19  every probe keeps curl-rc and HTTP status apart.  Ryu returning 404 for a powered-off
#         switch is Ryu answering (08-18 N-1: `GET /stats/flow/5` -> 404 in 0.9 ms while the
#         bridge was genuinely gone), and that is a fact about the bridge, not about Ryu.
#   H-20  kernel.log and ryu.log are checked against 00_preflight.sh's baseline before use.
#   H-21  pipefail; the F-5 sampler writes counts into a TSV and the verdict is computed from
#         the file with awk into a variable, then tested.  No gate is the tail of a pipeline --
#         which is exactly how the 08-30 pingall assertion became incapable of going red.
#   H-22  nothing is backgrounded and addressed by `$!`; nothing is killed by pattern.
#   H-23  the registry's must-match samples cover the reversed-grep case.
#   H-24  the kernel log is polled by `wait_for_line`, never read once.
#
# A CONFOUND THAT IS REGISTERED RATHER THAN CONTROLLED
#   If 25_apps_energy.sh has already run on this machine's OVS fabric, F-7a means the cycled
#   switches' 1 Gbps ports came back unshaped and nothing in the twin says so.  That does not
#   affect F-1..F-5b, which are about rule installation and diagnostics rather than bandwidth,
#   but it does mean the fabric is not the one the round started with.  Bring OVS up fresh.
#
# [Co-developed with claude code -- Adam]
# =================================================================================================
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
harness_begin 50_r5_ovs

KLOG="$LOG_DIR/kernel.log"
RLOG="$LOG_DIR/ryu.log"
SPEC="$REPO/tools/contract_test/spec.py"
BASELINE="$OUT/artifact-baseline.txt"
sig_of() { [[ -f "$BASELINE" ]] && { grep -P "^\Q$1\E\t" "$BASELINE" 2>/dev/null | head -1 | cut -f2 || true; } || true; }

say "sanity: this is the OVS stack"
[[ -n "$(port_holder 8080)" ]] || die "nothing is listening on :8080. Bring the OVS stack up first:  ndt down && ndt up ovs4   (or 'ndt up ovs' for the 128-host fabric). 08-18's OVS round was the 128-host one; ovs4 is the P4 test bed's layout on OVS, which varies the data plane and nothing else."
[[ -z "$(port_holder 8081)" ]] || bad "the P4 proxy is ALSO on :8081. Two control planes over one machine; tear the P4 stack down before measuring."
require_absent_or_fresh "$KLOG" "$(sig_of "$KLOG")"

# Which OVS fabric is this?  The 08-18 numbers are the 128-host one and are not transferable.
read -r RC_G CODE_G <<<"$(http_probe ovs_graph GET "$NDT_URL/ndt/get_graph_data")"
read -r N_SW N_H N_E <<<"$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sw=[n for n in d["nodes"] if n.get("vertex_type")==0]
print(len(sw), sum(1 for n in d["nodes"] if n.get("vertex_type")==1), len(d["edges"]))' "$OUT/http/ovs_graph.body" 2>/dev/null || echo '? ? ?')"
info "fabric: $N_SW switches, $N_H hosts, $N_E edges  (08-18's OVS round was 10/128/288)"
info "If this is the 4-host layout, do NOT compare any count to the 08-18 OVS figures."

# --- the tooling this phase depends on, checked before it is depended on --------------------------
say "tool availability -- stated up front so a missing tool is not read as a missing rule"
HAVE_OFCTL=0
if command -v ovs-ofctl >/dev/null 2>&1 && sudo -n ovs-ofctl --version >/dev/null 2>&1; then
    HAVE_OFCTL=1; ok "ovs-ofctl is usable without a password -- the switch's own view is available"
else
    skip "ovs-ofctl is not usable without a password. F-5 below drops from THREE independent sources to TWO (Ryu and the kernel). That is a weaker instrument: the whole point of F-5 is that the kernel disagrees with the switch, and without the switch's own view the comparison rests on Ryu as proxy for it. Record this limitation in the write-up."
fi

# -------------------------------------------------------------------------------------------------
say "F-1 -- the punt-to-controller rule, on the fabric where it can actually fire"
F1_SRC="$REPO/src/ndt_core/collection/FlowLinkUsageCollector.cpp"
F1_GUARD="$(grep -cE '0xFFFFFF00|OFPP_CONTROLLER|reservedPort|isReservedPort' "$F1_SRC" 2>/dev/null || true)"
info "reserved-port guard sites in $F1_SRC: ${F1_GUARD:-0}"

# Reachability, verified on a live switch rather than assumed: the prio-0 table-miss rule
# outputs to CONTROLLER and matches every flow (08-18 F-1).
read -r RC_F CODE_F <<<"$(http_probe ovs_flow1 GET "$RYU_URL/stats/flow/1")"
CTRL_RULES="$(grep -o 'CONTROLLER' "$OUT/http/ovs_flow1.body" 2>/dev/null | wc -l || true)"
info "OUTPUT:CONTROLLER rules on s1 (from Ryu): ${CTRL_RULES:-0}  (curl_rc=$RC_F http=$CODE_F)"
F1_HITS="$(count_matches kernel_reserved_port_out "$KLOG")"
ALL_EDGE_MSGS="$(count_matches kernel_edge_not_found "$KLOG")"
info "kernel.log: $ALL_EDGE_MSGS 'edge not found' line(s), of which $F1_HITS name a reserved port"

if [[ "${F1_GUARD:-0}" != "0" ]]; then
    verdict5 F-1 fixed "a reserved-port guard now exists at ${F1_GUARD} site(s) in $F1_SRC. Read them: the fix must test outPort >= 0xFFFFFF00 BEFORE the edge lookup and record its own cause. A guard placed after the lookup changes nothing."
elif [[ "$F1_HITS" != "0" && "$F1_HITS" != "-1" ]]; then
    verdict5 F-1 present "$F1_HITS kernel.log line(s) send the reader to the topology file to look for a link to a reserved port that no topology file can contain. Unchanged from 08-18. Diagnostic-only: no wrong data reaches a consumer."
elif [[ "${CTRL_RULES:-0}" == "0" ]]; then
    verdict5 F-1 unreachable "no OUTPUT:CONTROLLER rule is present on s1, so the branch cannot be entered on this fabric. Check that Ryu was started with --observe-links; without it the LLDP rule is absent and F-1's precondition is gone for a reason unrelated to the defect."
else
    verdict5 F-1 unreachable "the punt rules exist (${CTRL_RULES} on s1) and the code is unguarded, but no flow resolved to a reserved port during this run. The defect is intact and simply did not fire. To reach it, send traffic that has no specific forwarding rule on some switch along its path, so it falls to the prio-0 table-miss."
fi

# -------------------------------------------------------------------------------------------------
say "F-5 -- a rejected rule reported as installed, then silently vanishing"
# 08-18's exact request.  `{"ipv4_dst": ...}` with no eth_type violates an OpenFlow 1.3
# prerequisite, so OVS refuses it -- correct switch behaviour, which is what makes the finding
# sharp rather than weak.
#
# ⚠️ SINCE 08-18 THE KERNEL GAINED A PRE-QUEUE SHAPE CHECK (HttpSession.cpp:913-957, which
# answers 400 with "nothing was queued" for entries that cannot form a rule).  If it now rejects
# this at the front door, the southbound is never entered and F-5's mechanism is UNREACHABLE by
# this route -- which is a real answer, not a fix, and must be recorded as such.

say "  control first: a rule WITH the eth_type prerequisite must install and persist"
CTRL='{"dpid":1,"priority":778,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.97"},"actions":[{"type":"OUTPUT","port":2}]}'
read -r RC_C CODE_C <<<"$(http_probe f5_ovs_control POST "$NDT_URL/ndt/install_flow_entry" "$CTRL")"
info "valid rule -> curl_rc=$RC_C http=$CODE_C  $(head -c 160 "$OUT/http/f5_ovs_control.body" 2>/dev/null || true)"
sleep 8
read -r RC_R CODE_R <<<"$(http_probe f5_ovs_ctrl_ryu GET "$RYU_URL/stats/flow/1")"
CTRL_IN_RYU="$(grep -c '778' "$OUT/http/f5_ovs_ctrl_ryu.body" 2>/dev/null || true)"
if [[ "${CTRL_IN_RYU:-0}" != "0" ]]; then
    ok "CONTROL HOLDS: the valid rule reached the switch (Ryu sees priority 778), so the write path works and the instrument can see a rule that exists"
else
    bad "CONTROL FAILED: the valid rule is not in Ryu's view. Everything below would be produced by an instrument that cannot see any rule. STOP -- do not record an F-5 verdict from this run."
fi

say "  the invalid rule, sampled from three sources every 2 s"
BAD='{"dpid":1,"priority":777,"match":{"ipv4_dst":"10.0.0.99"},"actions":[{"type":"OUTPUT","port":2}]}'
read -r RC_B CODE_B <<<"$(http_probe f5_ovs_invalid POST "$NDT_URL/ndt/install_flow_entry" "$BAD")"
BAD_RESP="$(cat "$OUT/http/f5_ovs_invalid.body" 2>/dev/null || true)"
info "invalid rule -> curl_rc=$RC_B http=$CODE_B  body: $BAD_RESP"

if [[ "$CODE_B" == "400" ]]; then
    verdict5 F-5 unreachable "the kernel now refuses the 08-18 request at its pre-queue shape check (HTTP 400, HttpSession.cpp:913-957): nothing was queued, so the switch never saw it and the ~8 s phantom window cannot open. The 08-18 defect was in what happens AFTER the switch says no; this route no longer gets that far. To re-reach it you need a rule that is shape-valid to the kernel and still refused by OVS. Body: $BAD_RESP"
else
    : > "$OUT/f5_ovs_samples.tsv"
    printf 'elapsed_s\tswitch\tryu\tkernel\tkernel_actions_shape\n' >> "$OUT/f5_ovs_samples.tsv"
    T_START="$(date +%s)"
    for t in 0 2 4 7 9 12 16 20 30 45 60 84; do
        NOW=$(( $(date +%s) - T_START ))
        SW='-'
        if (( HAVE_OFCTL == 1 )); then
            SW="$(sudo -n ovs-ofctl dump-flows s1 2>/dev/null | grep -c 'priority=777' || true)"
        fi
        http_probe "f5_ovs_ryu_t$t"    GET "$RYU_URL/stats/flow/1" >/dev/null
        RY="$(grep -c '777' "$OUT/http/f5_ovs_ryu_t$t.body" 2>/dev/null || true)"
        http_probe "f5_ovs_kern_t$t"   GET "$NDT_URL/ndt/get_switch_openflow_table_entries" >/dev/null
        KE="$(grep -c '777' "$OUT/http/f5_ovs_kern_t$t.body" 2>/dev/null || true)"
        # THE FINGERPRINT.  During the 8 s window the phantom's actions were
        # [{"port": 2, "type": "OUTPUT"}] -- a JSON OBJECT among 130 strings, byte-identical to
        # the POST body.  That shape, not the count, is what proves the kernel is echoing the
        # request rather than reporting the table.  A count alone cannot distinguish an
        # optimistic local insert from a stale poll.
        SHAPE='-'
        if grep -q '"type": *"OUTPUT"' "$OUT/http/f5_ovs_kern_t$t.body" 2>/dev/null; then SHAPE='object'; fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$NOW" "${SW:--}" "${RY:-0}" "${KE:-0}" "$SHAPE" \
            >> "$OUT/f5_ovs_samples.tsv"
        sleep 2
    done
    sed 's/^/      /' "$OUT/f5_ovs_samples.tsv"

    # H-21: compute into variables, then test.
    KMAX="$(awk -F'\t' 'NR>1 && $4>m {m=$4} END{print m+0}' "$OUT/f5_ovs_samples.tsv")"
    RYMAX="$(awk -F'\t' 'NR>1 && $3>m {m=$3} END{print m+0}' "$OUT/f5_ovs_samples.tsv")"
    KLAST="$(awk -F'\t' 'END{print $4+0}' "$OUT/f5_ovs_samples.tsv")"
    OBJ="$(awk -F'\t' 'NR>1 && $5=="object" {c++} END{print c+0}' "$OUT/f5_ovs_samples.tsv")"
    info "max seen -- kernel:$KMAX ryu:$RYMAX ; kernel at end:$KLAST ; samples with object-shaped actions:$OBJ"

    ERRS="$(count_matches kernel_error_line "$KLOG")"
    DISP="$(count_matches kernel_dispatch_failed "$KLOG")"
    info "kernel.log error/critical lines: $ERRS ; 'dispatched ... failed' lines: $DISP"

    if (( KMAX > 0 )) && (( RYMAX == 0 )) && (( KLAST == 0 )); then
        verdict5 F-5 present "the kernel asserted a rule that Ryu never had, then stopped: kernel peaked at $KMAX and ended at $KLAST while Ryu stayed at $RYMAX. Object-shaped actions in $OBJ sample(s) -- the fingerprint that says the kernel is echoing the POST body, not reporting the table. kernel.log error lines this run: $ERRS, dispatch-failure lines: $DISP. The API's own advice ('per-entry outcomes are reported in the kernel log') still points at an empty place if those are 0."
    elif (( KMAX == 0 )); then
        verdict5 F-5 fixed "the kernel never showed the rejected rule at any of the twelve samples between t=0 and t=84 s. Sampling was every 2 s, so an 8 s window could not be missed. Before quoting this: the control above must have held, otherwise this is an instrument that sees nothing."
    elif (( RYMAX > 0 )); then
        verdict5 F-5 unreachable "OVS accepted the rule this time (Ryu peaked at $RYMAX), so it was never rejected and the finding's precondition did not hold. The OpenFlow 1.3 prerequisite may be being supplied upstream now. Find a rule OVS still refuses before re-running."
    else
        verdict5 F-5 present "kernel peaked at $KMAX, ended at $KLAST, Ryu at $RYMAX -- read $OUT/f5_ovs_samples.tsv and describe the shape by hand rather than accepting this automated wording."
    fi
fi

# -------------------------------------------------------------------------------------------------
say "F-5b -- the OVS half of the differential"
# On P4 the kernel logs the rejection because the proxy puts the error inside its 200.  Ryu's
# /stats/flowentry/add is fire-and-forget: 200 before the switch has ruled, rejection arrives
# later as an asynchronous OFPErrorMsg that nothing listens for.  So the check at
# Controller.cpp has nothing to find.
OVS_DISP="$(count_matches kernel_dispatch_failed "$KLOG")"
OVS_ERR="$(count_matches kernel_error_line "$KLOG")"
KLINES="$(wc -l < "$KLOG" 2>/dev/null || echo 0)"
info "over $KLINES kernel.log lines: $OVS_DISP dispatch-failure line(s), $OVS_ERR error/critical line(s)"
if [[ "$CODE_B" == "400" ]]; then
    verdict5 F-5b unreachable "the OVS half could not be exercised: the kernel refused the invalid rule at its shape check, so no southbound write was attempted and there was nothing for the error path to miss. Combine with 40_r5_p4.sh's P4 result only if that one was exercised too -- a differential between an exercised arm and an unexercised one is not a differential."
elif [[ "$OVS_DISP" == "0" || "$OVS_DISP" == "-1" ]]; then
    verdict5 F-5b present "OVS stayed silent about a rejected rule ($OVS_DISP dispatch-failure lines over $KLINES log lines), exactly as 08-18 recorded, while 40_r5_p4.sh's P4 arm logged it. The differential survives. Mechanism unchanged: Controller.cpp:55 detects failure by finding an error INSIDE a 200 body, and Ryu's 200 arrives before the switch has ruled."
else
    verdict5 F-5b fixed "OVS now logs $OVS_DISP dispatch failure(s). Read them: they must correspond to THIS run's rejected rule and not to unrelated traffic, and the mechanism must be identified before this is called a fix -- a rejection surfaced for a different reason is not the same fix."
fi

# -------------------------------------------------------------------------------------------------
say "F-2 / F-3 on OVS -- same shape as the P4 arm, same degraded-fabric requirement"
DOWN_N="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for n in d.get("nodes",[]) if n.get("vertex_type")==0 and not n.get("is_up")))' "$OUT/http/ovs_graph.body" 2>/dev/null || echo 0)"
info "switches down: $DOWN_N"
if (( DOWN_N == 0 )); then
    verdict5 F-2 unreachable "OVS arm: no switch is down. Run 25_apps_energy.sh on this fabric, then re-run this script before 90_restore.sh."
    verdict5 F-3 unreachable "OVS arm: no switch is down, so no -1 sentinel is produced."
else
    RL="$REPO/tools/test_workflow/run_layers.sh"
    set +e
    bash "$RL" api ovs > "$OUT/f2_ovs_run_layers.txt" 2>&1
    RL_RC=$?
    set -e
    SWUP_N="$(grep -c 'switch(es) not up' "$OUT/f2_ovs_run_layers.txt" 2>/dev/null || true)"
    BROKEN_N="$(grep -c 'BROKEN' "$OUT/f2_ovs_run_layers.txt" 2>/dev/null || true)"
    info "run_layers rc=$RL_RC ; BROKEN=$BROKEN_N ; 'switch(es) not up'=$SWUP_N"
    tail -40 "$OUT/f2_ovs_run_layers.txt" | sed 's/^/      /' || true
    if [[ "${SWUP_N:-0}" != "0" ]]; then
        verdict5 F-2 present "OVS arm: the suite calls a correctly degraded network BROKEN (${SWUP_N} line(s)); unchanged from 08-18"
    else
        verdict5 F-2 fixed "OVS arm: the suite did not fail on the powered-down switches (rc=$RL_RC). Confirm the invariants ran before accepting."
    fi
    SENT=0
    for ep in get_cpu_utilization get_memory_utilization; do
        http_probe "f3_ovs_$ep" GET "$NDT_URL/ndt/$ep" >/dev/null
        N1="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for v in (d.values() if isinstance(d,dict) else []) if v == -1))' "$OUT/http/f3_ovs_$ep.body" 2>/dev/null || echo 0)"
        info "$ep keys with -1: $N1"; SENT=$(( SENT + N1 ))
    done
    F3_OLD="$(grep -c 'Num(min=0, max=100)' "$SPEC" 2>/dev/null || true)"
    if (( SENT == 0 )); then
        verdict5 F-3 unreachable "OVS arm: $DOWN_N switch(es) down but no -1 emitted; the schema was not asked the question"
    elif [[ "${F3_OLD:-0}" != "0" ]]; then
        verdict5 F-3 present "OVS arm: schema still rejects -1 at ${F3_OLD} site(s) while $SENT key(s) carry it"
    else
        verdict5 F-3 fixed "OVS arm: schema accepts -1 and $SENT key(s) carry it on a live degraded fabric"
    fi
fi

# F-4 is source-only and fabric-independent; 40_r5_p4.sh already recorded it.
info "F-4 is source-only and fabric-independent -- recorded by 40_r5_p4.sh; not repeated here."

summary
say "R-5 verdict table"
[[ -f "$OUT/r5_verdicts.tsv" ]] && sed 's/^/      /' "$OUT/r5_verdicts.tsv" || info "no verdicts recorded"
info ""
info "Any of F-1..F-5b with no row above was NOT RE-CHECKED. That is a fourth state, distinct"
info "from R-5's three, and the write-up must say so rather than folding it into 'unreachable'."
exit 0
