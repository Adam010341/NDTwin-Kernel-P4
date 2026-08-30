#!/bin/bash
# =================================================================================================
# 40_r5_p4.sh -- R-5 phase 1: re-check F-1 .. F-5b on the P4/bmv2 stack.
#
# P4 FIRST, BY INSTRUCTION: the professor's line is P4, so the P4 arm must produce a result even
# if the OVS arm never runs.
#
# WRITTEN, NOT RUN. `bash -n` only.
#
# THE THREE-VALUED RULE (PREREG §3 R-5)
#   still present / fixed / NO LONGER REACHABLE.  The third branch exists so that a finding
#   which merely became untestable is not scored as fixed.  Two of the six below are expected
#   to land there on P4 for structural reasons, and saying so out loud is the point:
#     F-1 needs an OpenFlow reserved output port; P4 has no OFPP_CONTROLLER.
#     F-5 needs OVS to reject a rule the kernel accepted; the P4 proxy writes synchronously.
#   "Not applicable here" is a reachability statement, not a fix.
#
# SUBCOMMANDS
#   (none)        the full P4 arm on a healthy fabric
#   --f2f3-only   ONLY the F-2/F-3 live half, which requires a DEGRADED fabric and must
#                 therefore be run after 25_apps_energy.sh and before 90_restore.sh
#
# H-CORRESPONDENCE
#   H-17  every liveness test is /proc via lib.sh `alive()`.  The bmv2 switches and the topology
#         run as root; `kill -0` against them returns EPERM, which is what made run 1 of T-2 call
#         a live fabric dead and start the proxy before any switch was listening.
#   H-18  🔑 the kernel-log patterns here are the ones that matter most, and they are the ones
#         most easily got wrong.  `dispatched install failed` does NOT appear in the source: the
#         source has a format string, `"dispatched {} failed for dpid {} ..."`
#         (Controller.cpp:55-62), and a literal grep for the runtime phrase over src/ returns
#         nothing while the runtime log contains it.  Every pattern used here is registered in
#         lib.sh with the reconstructed emitted line and is self-tested before this script does
#         anything.  Calibrate them against a real kernel.log after the first run.
#   H-19  every probe records curl-rc and HTTP status separately.  A 404 from a renamed endpoint
#         is "the kernel answered", not "the kernel is down" -- that exact confusion is H-19.
#   H-20  the manifest and the kernel log are checked against 00_preflight.sh's baseline before
#         any conclusion is drawn from them.  A root-owned manifest from a previous run cannot
#         be deleted by this user and would otherwise be read as this run's.
#   H-21  pipefail from lib.sh; every gate takes a pre-computed value.  In particular the
#         pingall-style assertions here compute a count into a variable and then test it, rather
#         than ending in `grep ... | tail -1 || bad`, which can never go red.
#   H-22  nothing is started with `( ... ) &` and then addressed by `$!`.  Nothing is killed by
#         pattern.  This script starts no long-lived process at all.
#   H-23  covered by the registry's must-match samples; the reversed-grep case that read
#         `Discovered link` as zero links is in the registry as its own entry.
#   H-24  the kernel log is polled with `wait_for_line`, never read once and concluded from.
#
# THE CONTROL DISCIPLINE THIS SCRIPT IS BUILT ON
#   Every "the system did not do X" check is paired with a control that makes the same
#   instrument show X.  Without it, an instrument that can see nothing at all reports every
#   finding as confirmed.  On 08-30 the only destructive control in the chaos harness never
#   touched the system and reported success; on 08-18 the F-5 finding was only sharp BECAUSE the
#   valid-rule control installed and persisted.
#
# [Co-developed with claude code -- Adam]
# =================================================================================================
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
harness_begin 40_r5_p4

MODE="${1:-full}"
KLOG="$LOG_DIR/kernel.log"
PLOG="$LOG_DIR/p4_proxy.log"
SPEC="$REPO/tools/contract_test/spec.py"
BASELINE="$OUT/artifact-baseline.txt"
sig_of() { [[ -f "$BASELINE" ]] && { grep -P "^\Q$1\E\t" "$BASELINE" 2>/dev/null | head -1 | cut -f2 || true; } || true; }

# -------------------------------------------------------------------------------------------------
if [[ "$MODE" != "--f2f3-only" ]]; then

say "sanity: this really is the P4 stack, and the fabric is the one we think it is"
[[ -n "$(port_holder 8081)" ]] || die "nothing is listening on :8081. This script is the P4 arm; on OVS run 50_r5_ovs.sh."
[[ -z "$(port_holder 8080)" ]] || bad "Ryu is ALSO listening on :8080. Two control planes over one fabric is the P-1 shape at a larger scale; resolve before measuring."
BMV2_N="$(ps -eo comm= 2>/dev/null | grep -cx 'simple_switch_g' || true)"
info "bmv2 processes: ${BMV2_N:-0}"
gate "bmv2 switches are running" "$( [[ "${BMV2_N:-0}" -gt 0 ]] && echo 0 || echo 1 )" "${BMV2_N:-0}"

# H-20. The manifest contains only switches that PASSED verification, which is why it is the
# thing to judge on rather than the reassuring console line above it -- but only if it is ours.
require_absent_or_fresh "$P4_MANIFEST" "$(sig_of "$P4_MANIFEST")"
if [[ -f "$P4_MANIFEST" ]]; then
    # [Co-developed with claude code -- Adam]
    # FIXED 2026-08-30 (T-10). This read `d.get("switches", [])` for the non-list case. The
    # manifest is NOT shaped that way: p4_testbed_topo.py:458-469 writes a dict keyed by switch
    # name -- {"s1": {...}, ..., "s10": {...}} -- with no "switches" key anywhere. So `.get`
    # returned its default, `len([])` gave a confident **0**, and that 0 was fed straight into a
    # gate. A missing key produced a number rather than an error, and the number was then
    # compared to the bmv2 process count as if it had been measured.
    # 🔑 The dangerous half is not the wrong answer, it is that `.get(k, default)` converts
    #    "this file is not what I think it is" into "the value is zero".
    # The shape is now read explicitly and anything unrecognised RAISES.
    MAN_N="$(python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
if isinstance(d, list):
    # Legacy shape. Kept because an old manifest on disk must not silently score 0.
    print(len(d))
elif isinstance(d, dict) and "switches" in d:
    print(len(d["switches"]))
elif isinstance(d, dict) and not d:
    # An empty manifest is a REAL state, not a broken one: p4_testbed_topo.py writes only the
    # switches that passed verification, so {} means "none did". It must not be silently
    # equivalent to the unrecognised-shape case below, and it must not be quietly compared to a
    # nonzero process count as if it had been read successfully.
    raise SystemExit("manifest is an empty object: ZERO switches passed verification. "
                     "This is a fabric result, not a parse failure -- every bmv2 process that "
                     "is running is one the topology script declined to vouch for.")
elif isinstance(d, dict) and all(isinstance(v, dict) and "pid" in v for v in d.values()):
    # The shape p4_testbed_topo.py actually writes: name -> {pid, device_id, grpc_port, ...}
    print(len(d))
else:
    raise SystemExit("unrecognised manifest shape: %s with keys %r -- refusing to guess a count"
                     % (type(d).__name__, list(d)[:5] if hasattr(d, "__iter__") else d))
' "$P4_MANIFEST" 2>"$OUT/manifest_shape_error.txt" || echo '?')"
    if [[ "$MAN_N" == "?" ]]; then
        bad "the manifest at $P4_MANIFEST could not be counted -- its shape is not one this script recognises. This is NOT 'zero switches'; it is 'the file is not what we think it is'. See $OUT/manifest_shape_error.txt. Do not draw a conclusion about the fabric from it."
    else
        info "manifest lists $MAN_N switch(es)"
        gate "manifest count matches running bmv2 count" "$( [[ "$MAN_N" == "${BMV2_N:-0}" ]] && echo 0 || echo 1 )" "manifest=$MAN_N procs=${BMV2_N:-0}"
    fi
fi
require_absent_or_fresh "$KLOG" "$(sig_of "$KLOG")"

# The data plane must actually forward before any finding about rule installation means
# anything.  T2-1 was retracted because the instrument, not the fabric, was broken; the fabric
# forwarded the whole time.  Establish that first.
say "the fabric forwards -- established before anything is concluded from it"
read -r RC_P CODE_P <<<"$(http_probe p4_paths GET "$P4_PROXY_URL/ryu_server/all_destination_paths")"
PATHS_N="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get("all_destination_paths",[])))' "$OUT/http/p4_paths.body" 2>/dev/null || echo '?')"
info "proxy destination paths: $PATHS_N (curl_rc=$RC_P http=$CODE_P)"
DISC_N="$(count_matches proxy_link_discovered "$PLOG")"
info "proxy 'Discovered link' lines: $DISC_N"
info "  (H-23: the 08-30 harness grepped 'link (add|up|discover)' here, which cannot match"
info "   'Discovered link', and read zero hits as zero links.  The pattern above is registered"
info "   with that exact line as its must-match sample.)"
if [[ "$PATHS_N" != "?" && "$PATHS_N" -gt 0 ]]; then
    ok "the control plane reports $PATHS_N destination paths"
else
    bad "the proxy reports no destination paths. Before writing this up as a system fault, check the proxy log for a bind failure -- P-1: a second proxy runs its whole startup, installs rules, and only then discovers the port is taken, and every sample you take is then answered by the first one."
    PBIND="$(count_matches proxy_bind_failed "$PLOG")"
    [[ "$PBIND" != "0" && "$PBIND" != "-1" ]] && bad "the proxy log DOES contain a bind failure ($PBIND line(s)) -- this reading is an orphan's, not this run's"
fi

# -------------------------------------------------------------------------------------------------
say "F-1 -- a punt-to-controller rule diagnosed as a missing topology link"
# Two questions, kept apart: is the CODE still like that, and can it FIRE on this fabric?
F1_SRC="$REPO/src/ndt_core/collection/FlowLinkUsageCollector.cpp"
F1_MSG="$(grep -c 'edge not found by dpid/port' "$F1_SRC" 2>/dev/null || true)"
F1_GUARD="$(grep -cE '0xFFFFFF00|OFPP_CONTROLLER|reservedPort|isReservedPort' "$F1_SRC" 2>/dev/null || true)"
info "message sites in $F1_SRC: ${F1_MSG:-0};  reserved-port guard sites: ${F1_GUARD:-0}"
F1_HITS="$(count_matches kernel_reserved_port_out "$KLOG")"
info "kernel.log lines naming a reserved out-port: $F1_HITS"
if [[ "${F1_GUARD:-0}" == "0" && "${F1_MSG:-0}" != "0" ]]; then
    if [[ "$F1_HITS" != "0" && "$F1_HITS" != "-1" ]]; then
        verdict5 F-1 present "no reserved-port guard in $F1_SRC AND $F1_HITS log line(s) name a reserved out-port on this run"
    else
        # P4's data plane has no OpenFlow reserved ports; ntg_bmv2_topo.py installs no
        # table-miss-to-controller rule, so the branch cannot be entered.  That is a
        # reachability fact about the fabric, not a fix in the kernel.
        verdict5 F-1 unreachable "the diagnostic code is unchanged (guard sites: 0), but no reserved out-port occurred on this P4 run: P4 has no OFPP_CONTROLLER equivalent. The defect is intact and simply cannot fire here -- 50_r5_ovs.sh is where it is reachable."
    fi
else
    verdict5 F-1 fixed "reserved-port handling now present in $F1_SRC (${F1_GUARD} guard site(s)); read them and confirm they precede the edge lookup before accepting this"
fi

# -------------------------------------------------------------------------------------------------
say "F-4 -- the stale comment in the contract spec (source-only; there is nothing live to run)"
F4_OLD="$(grep -c 'may be an int or an explanatory string' "$SPEC" 2>/dev/null || true)"
F4_STR="$(grep -c 'OneOf(Num(), Str())' "$SPEC" 2>/dev/null || true)"
info "old comment present: ${F4_OLD:-0};  OneOf(Num(), Str()) sites: ${F4_STR:-0}"
if [[ "${F4_OLD:-0}" != "0" ]]; then
    verdict5 F-4 present "spec.py still carries the comment describing a string return the kernel no longer emits"
else
    verdict5 F-4 fixed "the comment is gone; the Str() branch survives at ${F4_STR} site(s) but is now documented as deliberate back-compat for kernels older than 04b8933, not as current behaviour. Read the replacement comment before quoting this."
fi
# The live half of F-4: the Str() branch should be provably dead.
if [[ -n "$(port_holder 8000)" ]]; then
    read -r RC_T CODE_T <<<"$(http_probe f4_temperature GET "$NDT_URL/ndt/get_temperature")"
    if [[ "$RC_T" == "0" && "$CODE_T" == "200" ]]; then
        STRS="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for v in (d.values() if isinstance(d,dict) else []) if isinstance(v,str)))' "$OUT/http/f4_temperature.body" 2>/dev/null || echo '?')"
        gate "get_temperature returns no strings (the Str() branch is dead in practice)" \
             "$( [[ "$STRS" == "0" ]] && echo 0 || echo 1 )" "string values: $STRS"
    else
        skip "get_temperature: curl_rc=$RC_T http=$CODE_T -- the live half of F-4 was not observed"
    fi
fi

# -------------------------------------------------------------------------------------------------
say "F-5b -- the differential: does the write path catch a rejected rule on P4?"
# 08-18: P4 logs `dispatched install failed ... HTTP 200 -- P4 proxy agent reported an error in
# a 200 response: {"status":"error","message":"Failed to add route"}` because the proxy writes
# synchronously and puts the error inside its 200.  Reproduce with the same shape: OUTPUT to a
# port that does not exist.
#
# ORDER MATTERS: the control goes FIRST.  If a valid rule cannot be installed, the invalid-rule
# result is uninterpretable, and running the control afterwards means discovering that only
# after writing the finding down.
KLOG_LINES_BEFORE="$(wc -l < "$KLOG" 2>/dev/null || echo 0)"
info "kernel.log is $KLOG_LINES_BEFORE lines before the experiment (all counts below are deltas)"

say "  control first: a VALID rule must install and persist"
CTRL_BODY='{"dpid":1,"priority":902,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.97"},"actions":[{"type":"OUTPUT","port":2}]}'
read -r RC_C CODE_C <<<"$(http_probe f5b_control POST "$NDT_URL/ndt/install_flow_entry" "$CTRL_BODY")"
info "valid rule -> curl_rc=$RC_C http=$CODE_C  body: $(head -c 200 "$OUT/http/f5b_control.body" 2>/dev/null || true)"
sleep 8
read -r RC_TC CODE_TC <<<"$(http_probe f5b_ctrl_table GET "$NDT_URL/ndt/get_switch_openflow_table_entries")"
CTRL_SEEN="$(grep -c '902' "$OUT/http/f5b_ctrl_table.body" 2>/dev/null || true)"
if [[ "${CTRL_SEEN:-0}" != "0" ]]; then
    ok "CONTROL HOLDS: the valid rule (priority 902) is visible in the kernel's table view, so the instrument can see a rule that exists"
else
    bad "CONTROL FAILED: a valid rule is not visible. Every 'rule not present' result below would be produced by an instrument that cannot see any rule at all. STOP -- do not record an F-5/F-5b verdict from this run."
fi

say "  now the invalid rule"
# OUTPUT to port 999: shape-valid (so it passes the kernel's pre-queue shape check at
# HttpSession.cpp:913-957) but no such port exists on the switch, so the southbound write fails.
BAD_BODY='{"dpid":1,"priority":901,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.98"},"actions":[{"type":"OUTPUT","port":999}]}'
read -r RC_B CODE_B <<<"$(http_probe f5b_invalid POST "$NDT_URL/ndt/install_flow_entry" "$BAD_BODY")"
BAD_RESP="$(cat "$OUT/http/f5b_invalid.body" 2>/dev/null || true)"
info "invalid rule -> curl_rc=$RC_B http=$CODE_B  body: $BAD_RESP"
if [[ "$CODE_B" == "400" ]]; then
    # The kernel now shape-checks before queueing (added after 08-18). If it rejects this at the
    # front door, the southbound never sees it and F-5b's mechanism is not exercised.
    verdict5 F-5b unreachable "the kernel answered 400 at the shape check (HttpSession.cpp:913-957) so nothing was queued and the southbound write path was never entered. Find a shape-valid rule the switch still refuses, or record F-5b as not exercised this run. Body: $BAD_RESP"
else
    # Poll: the error is logged asynchronously by the dispatcher thread (Controller.cpp:55).
    WAITED="$(wait_for_line "$KLOG" kernel_dispatch_failed 30)"
    DISPATCH_N="$(count_matches kernel_dispatch_failed "$KLOG")"
    info "'dispatched <op> failed' lines in kernel.log: $DISPATCH_N (first seen after ${WAITED}s)"
    if [[ "$DISPATCH_N" != "0" && "$DISPATCH_N" != "-1" ]]; then
        verdict5 F-5b present "the P4 half still behaves as 08-18 recorded: the kernel logs the rejection ($DISPATCH_N line(s)). F-5b is a DIFFERENTIAL and is only settled once 50_r5_ovs.sh shows the OVS half staying silent -- one arm is half a finding."
        ok "P4 arm of the differential recorded"
    else
        verdict5 F-5b fixed "no 'dispatched ... failed' line appeared within 30 s of a rejected rule. Before accepting this, check that the rule was actually rejected: a rule that succeeded produces no error line either, and that is the failure mode this check is most likely to have."
        bad "no dispatch-failure line -- verify the rule was really refused by the switch before treating silence as a fix"
    fi
fi

# -------------------------------------------------------------------------------------------------
say "F-5 -- the phantom rule (an OVS finding; the P4 arm is the negative control)"
# 08-18 measured, on P4: "kernel=4 proxy=4 at t=2,4,8,16,30s -- no phantom, ever."  Re-run the
# same sampling here so the OVS result in 50_... has a same-round comparator rather than a
# twelve-day-old one.
: > "$OUT/f5_p4_samples.tsv"
printf 'elapsed_s\tkernel_entries_matching_901\n' >> "$OUT/f5_p4_samples.tsv"
for t in 0 2 4 7 9 12 16 20 30 45 60 84; do
    read -r RCX CODEX <<<"$(http_probe "f5_p4_t$t" GET "$NDT_URL/ndt/get_switch_openflow_table_entries")"
    K="$(grep -c '901' "$OUT/http/f5_p4_t$t.body" 2>/dev/null || true)"
    printf '%s\t%s\n' "$t" "${K:-0}" >> "$OUT/f5_p4_samples.tsv"
    sleep 2
done
sed 's/^/      /' "$OUT/f5_p4_samples.tsv"
PHANTOM="$(awk -F'\t' 'NR>1 && $2>0 {c++} END{print c+0}' "$OUT/f5_p4_samples.tsv")"
if [[ "$PHANTOM" == "0" ]]; then
    verdict5 F-5 unreachable "no phantom on P4, matching 08-18's 'no phantom, ever'. F-5 is an OVS finding about what happens when the SWITCH refuses a rule the kernel accepted; the P4 proxy writes synchronously and reports inside its 200, so the window F-5 describes does not exist here. This is the negative control for 50_r5_ovs.sh, not a verdict on F-5 itself."
else
    verdict5 F-5 present "a phantom appeared on P4 in $PHANTOM sample(s) -- this would be NEW, since 08-18 recorded none. Check the fingerprint: if the actions field is an OBJECT among strings and byte-identical to the POST body, the kernel is echoing the request rather than reporting the table."
fi

fi   # end of full-mode block

# -------------------------------------------------------------------------------------------------
# F-2 and F-3 need a DEGRADED fabric.  They are here rather than in 25_apps_energy.sh so that the
# R-5 verdicts all land in one file, but they cannot run until the Energy-App has acted.
# -------------------------------------------------------------------------------------------------
say "F-2 / F-3 -- the contract suite against a network that is correctly degraded"

DOWN_N=0
if [[ -n "$(port_holder 8000)" ]]; then
    read -r RC_G CODE_G <<<"$(http_probe f2_graph GET "$NDT_URL/ndt/get_graph_data")"
    DOWN_N="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for n in d.get("nodes",[]) if n.get("vertex_type")==0 and not n.get("is_up")))' "$OUT/http/f2_graph.body" 2>/dev/null || echo 0)"
fi
info "switches currently down: $DOWN_N"

# Source half -- true regardless of fabric state.
F2_ADMIN="$(grep -c 'admin_disabled' "$SPEC" 2>/dev/null || true)"
info "inv_all_switches_up / inv_edges_enabled reference admin_disabled at ${F2_ADMIN:-0} site(s) in spec.py"
if [[ "${F2_ADMIN:-0}" == "0" ]]; then
    info "  -> the invariants still assert unconditionally that every switch and every edge is up"
    info "     (spec.py:161 inv_all_switches_up, spec.py:186 inv_edges_enabled). A deliberately"
    info "     powered-down switch is still indistinguishable from one that never connected."
fi

if (( DOWN_N == 0 )); then
    verdict5 F-2 unreachable "no switch is down, so the contract suite cannot be shown failing on a correctly degraded network. Run 25_apps_energy.sh first, then re-run this script as: ./40_r5_p4.sh --f2f3-only  BEFORE 90_restore.sh. A suite that passes on a healthy network says nothing about F-2."
    verdict5 F-3 unreachable "no switch is down, so no endpoint returns the -1 sentinel and the schema is never asked the question F-3 is about. Same instruction as F-2."
    summary
    exit 0
fi

ok "the fabric is degraded ($DOWN_N switch(es) down) -- F-2 and F-3 are reachable"

# F-3 first: does any endpoint actually emit -1?  If not, the schema check below is vacuous.
SENT=0
for ep in get_cpu_utilization get_memory_utilization get_temperature; do
    read -r RCU CODEU <<<"$(http_probe "f3_$ep" GET "$NDT_URL/ndt/$ep")"
    N1="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for v in (d.values() if isinstance(d,dict) else []) if v == -1))' "$OUT/http/f3_$ep.body" 2>/dev/null || echo 0)"
    info "$ep -> http=$CODEU, keys with -1: $N1"
    SENT=$(( SENT + N1 ))
done
if (( SENT == 0 )); then
    verdict5 F-3 unreachable "$DOWN_N switch(es) are down but no endpoint returned -1. The sentinel F-3 is about was not produced, so the schema was not asked the question. Read one of the bodies in $OUT/http/f3_*.body before concluding anything."
else
    F3_MIN="$(grep -c 'Num(min=-1, max=100)' "$SPEC" 2>/dev/null || true)"
    F3_OLD="$(grep -c 'Num(min=0, max=100)' "$SPEC" 2>/dev/null || true)"
    info "spec.py: Num(min=-1,...) at ${F3_MIN:-0} site(s); Num(min=0,...) at ${F3_OLD:-0} site(s)"
    if [[ "${F3_OLD:-0}" != "0" ]]; then
        verdict5 F-3 present "the schema still rejects the documented -1 sentinel at ${F3_OLD} site(s), and $SENT key(s) carry -1 right now"
    else
        verdict5 F-3 fixed "spec.py:502/507 now read Num(min=-1, max=100) and $SENT key(s) carry -1 on a live degraded fabric, so the sentinel is both emitted and accepted. Note get_temperature's schema is a different shape (OneOf(Num(), Str())) and was never the F-3 site."
    fi
fi

# F-2: run the suite and see whether a correctly degraded network turns it red.
say "  running the contract suite against the degraded fabric"
RL="$REPO/tools/test_workflow/run_layers.sh"
if [[ ! -x "$RL" && ! -f "$RL" ]]; then
    verdict5 F-2 unreachable "run_layers.sh not found at $RL"
else
    set +e
    bash "$RL" api p4 > "$OUT/f2_run_layers.txt" 2>&1
    RL_RC=$?
    set -e
    info "run_layers.sh exited rc=$RL_RC ; output at $OUT/f2_run_layers.txt"
    tail -40 "$OUT/f2_run_layers.txt" | sed 's/^/      /' || true
    # H-21: compute the count into a variable, then test it.  `grep BROKEN | tail -1 || bad`
    # would report success no matter what, because the pipeline's status is tail's.
    BROKEN_N="$(grep -c 'BROKEN' "$OUT/f2_run_layers.txt" 2>/dev/null || true)"
    SWUP_N="$(grep -c 'switch(es) not up' "$OUT/f2_run_layers.txt" 2>/dev/null || true)"
    info "BROKEN lines: ${BROKEN_N:-0}; 'switch(es) not up' lines: ${SWUP_N:-0}"
    if [[ "${SWUP_N:-0}" != "0" ]]; then
        verdict5 F-2 present "the suite reports the deliberately powered-down switches as BROKEN (${SWUP_N} 'switch(es) not up' line(s), ${BROKEN_N} BROKEN line(s)) on a network the Energy-App degraded correctly. Unchanged from 08-18."
    elif [[ "$RL_RC" == "0" ]]; then
        verdict5 F-2 fixed "the suite passed with $DOWN_N switch(es) deliberately down. Before accepting: confirm the suite actually evaluated the switch invariants this run rather than skipping them -- a suite that did not look also does not complain."
    else
        verdict5 F-2 present "the suite failed (rc=$RL_RC) though not with the 08-18 wording. Read $OUT/f2_run_layers.txt and say which invariant fired; do not assume it is the same one."
    fi
fi

summary
info "F-5b is a DIFFERENTIAL: it is not settled until 50_r5_ovs.sh has run the OVS half."
exit 0
