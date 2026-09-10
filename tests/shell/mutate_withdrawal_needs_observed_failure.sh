#!/usr/bin/env bash
#
# Mutation gate for doc/KNOWN-ISSUES.md B-6, SECOND ROUND (W8b) -- three rulings, one gate:
#
#   W8-2 (b)  a withdrawal has to PAIR with a reported break. /ndt/link_recovery_detected may
#             withdraw a declaration only when /ndt/link_failure_detected reported this link
#             broken; a bare rediscovery (Ryu restarting) may not.
#   W8-7      the four link endpoints refuse `src_dpid == 0 || dst_dpid == 0`. dpid 0 is the host
#             end of a host edge, which these endpoints do not address.
#   W8-4      the kernel sweeps the qdisc tree at startup on MININET and WARNs about netem it
#             finds. It does not clear it and does not turn it into a declaration.
#   E-22      (added 2026-09-07, WAKEUP.md 3-52) /ndt/link_recovery_detected logs its OUTCOME,
#             after the outcome is known, and the three outcomes are three different sentences.
#
# [Co-developed with claude code -- Adam]
#
# Covers tests/test_PollDoesNotResurrect.cpp (DeclaredLinkFailureTest, the W8b cases),
# tests/test_HttpSessionRouting.cpp (DeclaredLinkFailureWireTest, the W8b and W8-7 cases) and
# tests/test_NetemLinkFault.cpp (ResidualNetemSweepTest).
#
# WHAT THE DEFECT WAS -- and this one was MEASURED ON A LIVE FABRIC, not reasoned about
#   Branch fix/w8-declared-link-failure-sticky made a declared link failure survive a topology
#   poll. It did not make one survive the CONTROL PLANE RESTARTING. Arm lw8b, 2026-09-07 00:08,
#   OVS 4 hosts, kernel 37d641fa9fd6fc14 built from 017c060f
#   (scratch/overnight-2026-09-05/logs/live-round2-console.log):
#
#     00:08:44  declare s1:1 -> s5:1                 is_up=False down_reason=declared
#     00:08:47  Ryu killed by pid, :8080 closed      still is_up=False down_reason=declared
#     00:08:54  Ryu restarted with the SAME argv     ryu2.log "Link added: ..." per link
#     00:08:53+ kernel.log                           one POST /ndt/link_recovery_detected per link
#     00:09:04  t+10 s through t+90 s                is_up=True down_reason=none, 9 of 9 samples
#
#   Ryu's topology module raises EventLinkAdd when LLDP FIRST discovers a link, so a controller
#   restart is indistinguishable from a fabric-wide recovery; intelligent_router.py's on_link_add
#   notifies the twin from there, and handleLinkRecovery withdrew unconditionally. For an injection
#   made through /ndt/inject_link_failure that is the worse half: the declaration is withdrawn and
#   the `tc netem loss 100%` stays attached, so the graph reports a link that is up and does not
#   carry packets.
#
# 🔴 TWO DIRECTIONS, AND THE SECOND ONE IS WHY THIS GATE EXISTS AT ALL
#   1. RESTORING any of the four defects must be caught      (M1 .. M10, M19, M20)
#      -- the unconditional withdrawal, the report that is never recorded or never spent, the
#         notification path calling the injection writer, dpid 0 let through at the helper or at
#         one call site, the startup sweep that finds nothing or says nothing, and the recovery
#         log written before the outcome is known or written the same way for all three outcomes.
#   2. RELAXING PAST the fix must ALSO be caught             (M11 .. M18)
#      -- and every one of these is a bigger outage than the defect:
#         * a recovery report that NEVER withdraws makes every real link outage permanent;
#         * a pairing rule that also refuses edges nobody declared down stops the endpoint
#           raising links at all -- it is one of only two writers that ever does;
#         * an /ndt/inject_link_recovery that needs the control plane's agreement leaves an
#           injection unwithdrawable, which is the state this whole fix creates on purpose;
#         * an observation writer that manufactures a failure report hands every twin-derived
#           outage a licence to withdraw a declaration;
#         * a dpid guard that refuses everything passes every W8-7 case above;
#         * a startup sweep that CLEARS what it finds destroys the fault campaign it started
#           underneath, which is the exact thing Adam ruled against.
#
# 🔴 A MUTANT THAT DOES NOT COMPILE IS A SURVIVOR, not a skip: the suite never ran, so it proves
# nothing. Same for an anchor that has moved, and for a run that hangs.
#
# 🔴 GUARDS ITS OWN BASELINE. Both files it can touch are snapshotted with `cp -p` first, an EXIT
# trap restores them however this exits including Ctrl-C, and the run ends by asserting byte
# identity against the snapshots AND that the test binary's sha is the one the baseline built.
#
# 🔴 NEVER KILLS ANYTHING BY NAME. No pkill, no pgrep: `timeout` owns the only child. Nothing here
# starts Mininet, bmv2, OVS or a listening socket, and NOTHING HERE RUNS tc -- the startup sweep is
# driven through a fake TcRunner, deliberately, because a gate that touched the machine's qdisc
# tree would be the injection tool corrupting the experiment this repository exists to protect.
#
# 🔴 BUILD UNDER THE GUARD. This laptop's oomd took the user's own application down on 2026-09-02.
#   JOBS=2 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh \
#       ./tests/shell/mutate_withdrawal_needs_observed_failure.sh
#
# Usage:  tools/build_guard/guarded_build.sh ./tests/shell/mutate_withdrawal_needs_observed_failure.sh
#   BUILD_DIR=build     configured build directory (ninja)
#   JOBS=2              build parallelism
#   TEST_TIMEOUT=300    seconds allowed per test-binary run
#
# Exit: 0 every mutation caught by the test it names, all three widenings survived, tree restored
#       1 at least one mutation survived, or a widening was caught
#       2 no verdict is possible: baseline red or not building, anchor drift, hang, failed restore
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

BUILD_DIR="${BUILD_DIR:-build}"
JOBS="${JOBS:-2}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
FILTER='DeclaredLinkFailureTest.*:DeclaredLinkFailureWireTest.*:ResidualNetemSweepTest.*'

TFM=src/ndt_core/collection/TopologyAndFlowMonitor.cpp
HS=src/ndt_core/http/HttpSession.cpp
FILES=("$TFM" "$HS")

MUTATIONS=0
SURVIVORS=0
WIDENINGS=0
WIDENINGS_CAUGHT=0

# --- 0. self-check ------------------------------------------------------------------------------
if ! bash -n "${BASH_SOURCE[0]}"; then
    echo "🔴 this script does not parse" >&2; exit 2
fi
command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
command -v python3 >/dev/null || { echo "🔴 python3 is required" >&2; exit 2; }
[[ -f "$BUILD_DIR/CMakeCache.txt" ]] || {
    echo "🔴 '$BUILD_DIR' is not a configured build dir. Configure it first, or pass BUILD_DIR=." >&2
    exit 2
}

# --- 1. snapshot --------------------------------------------------------------------------------
BK=$(mktemp -d)
declare -A SNAP SHA
for f in "${FILES[@]}"; do
    s="$BK/$(echo "$f" | md5sum | cut -c1-12).snap"
    cp -p "$f" "$s"; SNAP["$f"]="$s"; SHA["$f"]=$(sha256sum "$f" | cut -d' ' -f1)
done

restore() {
    local f
    for f in "${FILES[@]}"; do
        cmp -s "${SNAP[$f]}" "$f" && continue
        cp -p "${SNAP[$f]}" "$f"
        touch "$f"          # cp -p brings the old mtime back and ninja believes it
    done
}
trap 'restore; rm -rf "$BK"' EXIT

# --- 2. anchors ---------------------------------------------------------------------------------
count_exact() {
    python3 - "$1" "$2" <<'PYCOUNT'
import sys, pathlib
sys.stdout.write(str(pathlib.Path(sys.argv[1]).read_text().count(sys.argv[2])))
PYCOUNT
}

declare -a ANCHOR_FILE ANCHOR_TEXT ANCHOR_NAME
add_anchor() { ANCHOR_NAME+=("$1"); ANCHOR_FILE+=("$2"); ANCHOR_TEXT+=("$3"); }

add_anchor "pair-rule"     "$TFM" '    if (!eprop.failureReported && eprop.declaredDown)'
add_anchor "report-write"  "$TFM" '        (*m_graph)[e].failureReported = true;'
add_anchor "report-spend"  "$TFM" '    eprop.failureReported = false;
    eprop.declaredDown = false;'
add_anchor "inject-spend"  "$TFM" '    eprop.declaredDown = false;
    // Spent as well: an operator taking an injection back ends the episode, so a recovery report'
add_anchor "inject-report" "$TFM" '    eprop.declaredDown = false;
    // Spent as well: an operator taking an injection back ends the episode, so a recovery report
    // arriving afterwards must not find a report left over to pair with. W8b.
    eprop.failureReported = false;'
add_anchor "obs-down"      "$TFM" '    (*m_graph)[e].isUp = false;
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "setEdgeDown {}", (*m_graph)[e].isUp);'
add_anchor "sweep-mode"    "$TFM" '    std::vector<std::string> found;
    if (m_mode != utils::MININET)'
add_anchor "sweep-detect"  "$TFM" '        if (utils::netem::findExistingNetem(tree.output).safe)'
add_anchor "sweep-warn"    "$TFM" '    if (!found.empty())'
# The anchor takes the `dst` binding with it: dropping only the condition would leave `dst`
# unused, and this build is -Werror, so that mutant would not compile -- and a mutant that does not
# compile is scored a SURVIVOR here, not a skip. (It was, on the first run of this gate.)
add_anchor "sweep-scope"   "$TFM" '        const auto dst = boost::target(ed, *m_graph);
        const auto& sp = (*m_graph)[src];
        // Both ends must be switches: a host edge has no Mininet switch interface at its far end,
        // and since W8-7 no link endpoint can address one anyway.
        if (sp.vertexType != VertexType::SWITCH ||
            (*m_graph)[dst].vertexType != VertexType::SWITCH || sp.bridgeNameForMininet.empty())'
add_anchor "sweep-comment" "$TFM" '    // Read once. The graph is under a shared lock inside that call and the sweep below runs a'
add_anchor "sweep-found"   "$TFM" '        if (utils::netem::findExistingNetem(tree.output).safe)
        {
            found.push_back(iface);
        }'
add_anchor "unread-warn"   "$TFM" '            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "could not read the qdisc tree for {} (tc qdisc show returned {}), "
                               "so this startup sweep cannot say whether it carries netem",
                               iface,
                               tree.status);
            continue;'
add_anchor "dpid-guard"    "$HS"  '    return srcDpid != 0 && dstDpid != 0;'
add_anchor "notify-writer" "$HS"  '    m_topologyAndFlowMonitor->setEdgeDownByReportedFailure(fwdOpt.value());'
add_anchor "inject-door"   "$HS"  'HttpSession::handleInjectLinkFailure(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Inject Link Failure");
    auto data = parseLinkFailedEventPayload(m_req.body());
    if (!data)
    {
        res.result(http::status::bad_request);
        res.body() = R"({"error":"Invalid link-failure payload"})";
        return;
    }
    // W8-7. Refused here for the reason the notification endpoint refuses it, and one more: this
    // endpoint runs tc, so a dpid-0 payload would attach netem to whichever host-facing interface
    // the arbitrarily-chosen edge named. [Co-developed with claude code -- Adam]
    if (!namesTwoSwitches(data->srcDpid, data->dstDpid))
    {
        res.result(http::status::bad_request);
        res.body() = kHostEdgeRefusal;
        return;
    }'
add_anchor "refusal-text"  "$HS"  '    R"({"error":"src_dpid and dst_dpid must both name a switch: dpid 0 is the host end of a host )"'
# E-22 / 3-52. Two anchors: WHERE the recovery outcome is logged, and WHETHER the three outcomes
# get three sentences. They are separate defects -- moving the line without changing the words
# still leaves a declined report reading as a success -- so they are separate mutations.
add_anchor "log-placement" "$HS"  '    auto fwdOpt = m_topologyAndFlowMonitor->findEdgeBySrcAndDstDpid({srcDpid, dstDpid});
    if (!fwdOpt.has_value())
    {
        logLinkRecoveryOutcome(RecoveryLogOutcome::NoSuchEdge,
                               srcDpid,
                               srcInterface,
                               dstDpid,
                               dstInterface);
        res.result(http::status::not_found);
        res.body() = R"({"error":"edge not found in topology"})";
        return;
    }'
add_anchor "log-sentences" "$HS"  '    switch (outcome)
    {
        case RecoveryLogOutcome::Withdrawn:
            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "link recovered on {}:{} -> {}:{}: any declaration standing on this "
                               "link was withdrawn and both directions are up",
                               srcDpid,
                               srcInterface,
                               dstDpid,
                               dstInterface);
            return;
        case RecoveryLogOutcome::Retained:
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "link recovery declined on {}:{} -> {}:{}: a link failure is "
                               "declared here and nothing ever reported this link broken, so the "
                               "declaration was retained and the link is still down. POST "
                               "/ndt/inject_link_recovery to withdraw it",
                               srcDpid,
                               srcInterface,
                               dstDpid,
                               dstInterface);
            return;
        case RecoveryLogOutcome::NoSuchEdge:
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "link recovery ignored on {}:{} -> {}:{}: the topology holds no "
                               "such edge, so nothing was withdrawn and nothing was marked up",
                               srcDpid,
                               srcInterface,
                               dstDpid,
                               dstInterface);
            return;
    }'
add_anchor "log-decline-text" "$HS" '                               "declaration was retained and the link is still down. POST "
                               "/ndt/inject_link_recovery to withdraw it",'

echo "=== anchor uniqueness (exact substring count must be 1) ==="
anchor_ok=1
for i in "${!ANCHOR_NAME[@]}"; do
    n=$(count_exact "${ANCHOR_FILE[$i]}" "${ANCHOR_TEXT[$i]}")
    printf '  %-6s %-14s %-52s x%s\n' \
        "$([[ "$n" == 1 ]] && echo ok || echo REFUSE)" "${ANCHOR_NAME[$i]}" "${ANCHOR_FILE[$i]}" "$n"
    [[ "$n" == 1 ]] || anchor_ok=0
done
[[ "$anchor_ok" == 1 ]] || { echo "🔴 anchors have drifted; this gate cannot render a verdict" >&2; exit 2; }

# --- 3. build + run helpers ---------------------------------------------------------------------
build() { cmake --build "$BUILD_DIR" --target "$TARGET" -j"$JOBS" >/dev/null 2>&1; }

# run_tests <gtest_filter> -> sets STATUS RC OUT FAILED DIED_IN. rc comes from the binary itself and
# is never taken through a pipe, because a pipeline's status belongs to its last stage.
#
# 🔴 A TEST CAN GO RED WITHOUT PRINTING `[  FAILED  ]`: a mutation that deadlocks or segfaults kills
# the process with no FAILED line, and reading that as "nothing went red" would score real damage
# as a survivor. DIED_IN is the last case gtest announced, empty when it announced none.
run_tests() {
    OUT=$(timeout "$TEST_TIMEOUT" "$BIN" --gtest_filter="$1" 2>&1); RC=$?
    FAILED=$(sed -n 's/^\[  FAILED  \] \([A-Za-z_][A-Za-z0-9_]*\.[A-Za-z0-9_]*\).*/\1/p' <<<"$OUT" \
             | sort -u | tr '\n' ' ')
    DIED_IN=""
    if   (( RC == 124 )); then STATUS=hang
    elif (( RC > 128 ));  then STATUS=crash
    elif (( RC != 0 ));   then STATUS=fail
    else                       STATUS=pass
    fi
    if [[ "$STATUS" != pass && "$STATUS" != hang && -z "$FAILED" ]]; then
        DIED_IN=$(sed -n 's/^\[ RUN      \] \(.*\)$/\1/p' <<<"$OUT" | tail -1)
    fi
}

is_red() {
    [[ " $FAILED " == *" $1 "* ]] && return 0
    [[ -n "$DIED_IN" && "$DIED_IN" == "$1" ]] && return 0
    return 1
}

# apply <file> <anchor> <new> -- python does the replace, so the anchor matches LITERALLY, newlines
# and all, and the count is re-asserted at the moment of writing.
apply() {
    local file="$1" anchor="$2" new="$3"
    python3 - "$file" "$anchor" "$new" <<'PY'
import sys, pathlib
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path); s = p.read_text()
if s.count(old) != 1:
    sys.stderr.write("anchor count %d, expected 1\n" % s.count(old)); sys.exit(1)
p.write_text(s.replace(old, new, 1))
PY
}

# mutate <label> <file> <anchor> <new> <expect-red...>
# Every named test must be red. "Something went red" is not the check -- WHICH light went red is.
mutate() {
    local label="$1" file="$2" anchor="$3" new="$4"; shift 4
    local expected=("$@")
    MUTATIONS=$((MUTATIONS + 1))
    printf '\n=== M%d. %s ===\n' "$MUTATIONS" "$label"
    printf '  expect red: %s\n' "${expected[*]}"

    if ! apply "$file" "$anchor" "$new"; then
        echo "  🔴 SURVIVED (anchor could not be applied) -- this proves nothing about the tests"
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    if ! build; then
        echo "  🔴 SURVIVED (mutant does not compile) -- the suite never ran"
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    local missed=() got=() t filter=""
    for t in "${expected[@]}"; do filter+="$t:"; done
    run_tests "${filter%:}"
    for t in "${expected[@]}"; do
        if is_red "$t"; then got+=("$t"); else missed+=("$t"); fi
    done

    if [[ "$STATUS" == hang ]]; then
        echo "  🔴 HUNG (>${TEST_TIMEOUT}s) -- not a red, and not a catch"
        SURVIVORS=$((SURVIVORS + 1))
    elif [[ ${#missed[@]} -eq 0 ]]; then
        if [[ "$STATUS" == crash ]]; then
            printf '  ✅ caught  reason=signal %d, died in %s\n' "$((RC-128))" "$DIED_IN"
        elif [[ -n "$DIED_IN" ]]; then
            printf '  ✅ caught  reason=the process exited %d inside %s\n' "$RC" "$DIED_IN"
        else
            printf '  ✅ caught  red: %s\n' "${got[*]}"
        fi
    else
        printf '  🔴 SURVIVED -- these stayed green: %s\n' "${missed[*]}"
        [[ -n "$FAILED" ]] && printf '     (something else went red: %s -- the gate fires, but not\n     for the reason this mutation claims)\n' "$FAILED"
        [[ "$STATUS" != pass && -z "$FAILED" && -z "$DIED_IN" ]] && printf '     (the binary exited %d before announcing a single case -- the mutation broke the\n     test process itself, which is damage, not evidence)\n' "$RC"
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# widen <label> <file> <anchor> <new> -- a change that must leave EVERY case green.
widen() {
    local label="$1" file="$2" anchor="$3" new="$4"
    WIDENINGS=$((WIDENINGS + 1))
    printf '\n=== W%d. %s (MUST stay green) ===\n' "$WIDENINGS" "$label"

    if ! apply "$file" "$anchor" "$new"; then
        echo "  🔴 the widening's anchor could not be applied -- this control checked nothing"
        WIDENINGS_CAUGHT=$((WIDENINGS_CAUGHT + 1)); restore; return
    fi
    if ! build; then
        echo "  🔴 CAUGHT: the widening does not compile"
        WIDENINGS_CAUGHT=$((WIDENINGS_CAUGHT + 1)); restore; return
    fi
    run_tests "$FILTER"
    if [[ "$STATUS" == pass ]]; then
        echo "  ✅ survived -- behaviour unchanged, so the catches above are about behaviour"
    else
        echo "  🔴 CAUGHT: tests went red on a behaviour-preserving change: $FAILED $DIED_IN"
        echo "     This gate cannot tell an edit from a behaviour change."
        WIDENINGS_CAUGHT=$((WIDENINGS_CAUGHT + 1))
    fi
    restore
}

# --- 4. baseline --------------------------------------------------------------------------------
echo
echo "=== baseline (unmutated working tree) must build and be green ==="
if ! build; then
    echo "🔴 THE BASELINE DOES NOT COMPILE. Nothing below would mean anything." >&2
    cmake --build "$BUILD_DIR" --target "$TARGET" -j"$JOBS" 2>&1 | tail -40 >&2
    exit 2
fi
[[ -x "$BIN" ]] || { echo "🔴 $BIN is missing after a successful build" >&2; exit 2; }
BIN_SHA_BEFORE=$(sha256sum "$BIN" | cut -c1-16)

run_tests "$FILTER"
case "$STATUS" in
  pass) echo "  ok       baseline green ($(grep -c '^\[       OK \]' <<<"$OUT") cases in $FILTER)" ;;
  hang) echo "🔴 BASELINE HUNG (>${TEST_TIMEOUT}s). Not a red; the gate cannot proceed." >&2; exit 2 ;;
  *)    echo "🔴 THE BASELINE IS ALREADY RED: $FAILED $DIED_IN" >&2
        echo "   Every 'expect red' below would be meaningless. Stopping." >&2; exit 2 ;;
esac
echo "  ok       $TARGET sha256 $BIN_SHA_BEFORE"

# ================================================================================================
# 5. direction 1 -- putting each of the three defects back
# ================================================================================================

# M1. 🔴 W8-2, THE DEFECT EXACTLY AS THE lw8b ARM MEASURED IT. The pairing rule is gone and every
#     recovery report withdraws whatever it lands on -- which is what branch
#     fix/w8-declared-link-failure-sticky does, so this mutant is that branch's behaviour.
mutate "the defect verbatim: any recovery report withdraws any declaration (= w8 branch)" \
    "$TFM" \
    '    if (!eprop.failureReported && eprop.declaredDown)' \
    '    if (false)' \
    DeclaredLinkFailureTest.ARediscoveryDoesNotWithdrawADeclarationNothingReportedBroken \
    DeclaredLinkFailureTest.ARecoveryReportIsSpentAndDoesNotWithdrawTheNextDeclaration \
    DeclaredLinkFailureTest.TheInjectionWithdrawalAlsoSpendsAStandingReport \
    DeclaredLinkFailureWireTest.ARyuRestartDoesNotWithdrawAnInjectedLinkFailure

# M2. The report is never recorded, so nothing can ever pair with it: the notification endpoint's
#     own recovery stops working and every real link outage becomes permanent.
mutate "the notification path never records that the break was reported" \
    "$TFM" \
    '        (*m_graph)[e].failureReported = true;' \
    '        // [mutant] the report is never recorded' \
    DeclaredLinkFailureTest.AReportedFailureIsWithdrawnByItsMatchingRecovery \
    DeclaredLinkFailureTest.ObservationWritersNeitherSetNorClearTheFailureReport \
    DeclaredLinkFailureWireTest.AReportedFailureIsStillWithdrawnByItsOwnRecovery

# M3. 🔴 The wire half of the same thing: /ndt/link_failure_detected calls the INJECTION writer, so
#     a break Ryu reported is indistinguishable from an operator's injection and its own recovery
#     can no longer withdraw it. This is the call HttpSession made before W8b.
mutate "the notification endpoint records an injection instead of a reported failure" \
    "$HS" \
    '    m_topologyAndFlowMonitor->setEdgeDownByReportedFailure(fwdOpt.value());' \
    '    m_topologyAndFlowMonitor->setEdgeDownByDeclaration(fwdOpt.value());' \
    DeclaredLinkFailureWireTest.AReportedFailureIsStillWithdrawnByItsOwnRecovery

# M4. The report is not spent by the recovery that pairs with it, so ONE real outage licenses every
#     later rediscovery to end an injection -- the defect, delayed by one episode.
mutate "a failure report is never spent, so one report buys every later withdrawal" \
    "$TFM" \
    '    eprop.failureReported = false;
    eprop.declaredDown = false;' \
    '    eprop.declaredDown = false;' \
    DeclaredLinkFailureTest.ARecoveryReportIsSpentAndDoesNotWithdrawTheNextDeclaration

# M5. The operator's own withdrawal leaves the report behind, so the NEXT injection on that edge is
#     withdrawable by the next rediscovery.
mutate "the injection withdrawal leaves a report behind for the next episode" \
    "$TFM" \
    '    eprop.declaredDown = false;
    // Spent as well: an operator taking an injection back ends the episode, so a recovery report
    // arriving afterwards must not find a report left over to pair with. W8b.
    eprop.failureReported = false;' \
    '    eprop.declaredDown = false;
    // [mutant] the report outlives the episode it belonged to' \
    DeclaredLinkFailureTest.TheInjectionWithdrawalAlsoSpendsAStandingReport

# M6. 🔴 W8-7, THE DEFECT VERBATIM. dpid 0 is accepted, so `{"src_dpid":1,"dst_dpid":0}` resolves to
#     whichever host edge of s1 the graph iterates first and the endpoint acts on a link the caller
#     never named.
mutate "dpid 0 is let through, so a host edge is addressable after all" \
    "$HS" \
    '    return srcDpid != 0 && dstDpid != 0;' \
    '    return true;' \
    DeclaredLinkFailureWireTest.EveryLinkEndpointRefusesAHostEdgeAddressedByDpidZero \
    DeclaredLinkFailureWireTest.ARefusedHostEdgeRequestLeavesTheHostEdgeAlone

# M7. One door left open. The helper is intact and a single call site does not use it -- which is
#     what a fix applied by search-and-replace across four handlers actually fails at.
mutate "the guard is missing from /ndt/inject_link_failure alone" \
    "$HS" \
    'HttpSession::handleInjectLinkFailure(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Inject Link Failure");
    auto data = parseLinkFailedEventPayload(m_req.body());
    if (!data)
    {
        res.result(http::status::bad_request);
        res.body() = R"({"error":"Invalid link-failure payload"})";
        return;
    }
    // W8-7. Refused here for the reason the notification endpoint refuses it, and one more: this
    // endpoint runs tc, so a dpid-0 payload would attach netem to whichever host-facing interface
    // the arbitrarily-chosen edge named. [Co-developed with claude code -- Adam]
    if (!namesTwoSwitches(data->srcDpid, data->dstDpid))
    {
        res.result(http::status::bad_request);
        res.body() = kHostEdgeRefusal;
        return;
    }' \
    'HttpSession::handleInjectLinkFailure(http::response<http::string_body>& res)
{
    SPDLOG_LOGGER_INFO(Logger::instance(), "Handle Inject Link Failure");
    auto data = parseLinkFailedEventPayload(m_req.body());
    if (!data)
    {
        res.result(http::status::bad_request);
        res.body() = R"({"error":"Invalid link-failure payload"})";
        return;
    }' \
    DeclaredLinkFailureWireTest.EveryLinkEndpointRefusesAHostEdgeAddressedByDpidZero

# M8. 🔴 W8-4, THE RULING'S OWN MUTATION: the WARN is removed. The sweep still runs and still
#     returns what it found, so nothing but the log line changes -- which is the whole deliverable.
mutate "the startup sweep finds the netem and says nothing" \
    "$TFM" \
    '    if (!found.empty())' \
    '    if (false)' \
    ResidualNetemSweepTest.ResidualNetemIsNamedInOneWarningAtStartup

# M9. The sweep never detects anything, so it reports a clean fabric over a cut one -- the same
#     silence as M8 reached from the other end.
mutate "the startup sweep never recognises netem in the tree" \
    "$TFM" \
    '        if (utils::netem::findExistingNetem(tree.output).safe)' \
    '        if (false)' \
    ResidualNetemSweepTest.ResidualNetemIsNamedInOneWarningAtStartup

# M10. "Could not read" reported as nothing at all, so silence means two different things and a
#      sweep that never ran is indistinguishable from a clean one.
mutate "an unreadable qdisc tree is passed over in silence" \
    "$TFM" \
    '            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "could not read the qdisc tree for {} (tc qdisc show returned {}), "
                               "so this startup sweep cannot say whether it carries netem",
                               iface,
                               tree.status);
            continue;' \
    '            continue;' \
    ResidualNetemSweepTest.AnUnreadableInterfaceIsReportedAsUnreadNotAsClean

# ================================================================================================
#    direction 2: relaxing past the fix. 🔴 These are the reason this gate is not just W8b's.
# ================================================================================================

# M11. THE BLUNT OVER-CORRECTION. Every recovery report is declined, so /ndt/link_recovery_detected
#      never withdraws anything and never raises anything: a real link outage becomes permanent and
#      the only writer left that raises a link is the 30 s poll.
mutate "no recovery report ever withdraws anything" \
    "$TFM" \
    '    if (!eprop.failureReported && eprop.declaredDown)' \
    '    if (true)' \
    DeclaredLinkFailureTest.AReportedFailureIsWithdrawnByItsMatchingRecovery \
    DeclaredLinkFailureTest.ARecoveryStillRaisesAnEdgeNobodyDeclaredDown \
    DeclaredLinkFailureWireTest.AReportedFailureIsStillWithdrawnByItsOwnRecovery

# M12. The subtle half of the same thing: the rule drops its `declaredDown` clause, so a recovery
#      report for an edge carrying NO declaration is refused too and stops marking it up. Every
#      case in direction 1 stays green.
mutate "the pairing rule also refuses edges nobody declared down" \
    "$TFM" \
    '    if (!eprop.failureReported && eprop.declaredDown)' \
    '    if (!eprop.failureReported)' \
    DeclaredLinkFailureTest.ARecoveryStillRaisesAnEdgeNobodyDeclaredDown

# M13. The operator's own withdrawal becomes conditional as well, so an injection nothing reported
#      broken is unwithdrawable -- and that is precisely the state this fix creates on purpose.
mutate "the injection withdrawal needs the control plane's agreement too" \
    "$TFM" \
    '    eprop.declaredDown = false;
    // Spent as well: an operator taking an injection back ends the episode, so a recovery report' \
    '    if (eprop.failureReported) eprop.declaredDown = false;
    // Spent as well: an operator taking an injection back ends the episode, so a recovery report' \
    DeclaredLinkFailureTest.TheInjectionWithdrawalNeedsNoReportToPairWith \
    DeclaredLinkFailureWireTest.InjectRecoveryStillWithdrawsAfterARefusedRediscovery

# M14. The seam pointed the other way: an OBSERVATION manufactures a failure report, so every
#      outage the twin derived for itself hands the next rediscovery a licence to withdraw.
mutate "the observation writer manufactures a control-plane failure report" \
    "$TFM" \
    '    (*m_graph)[e].isUp = false;
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "setEdgeDown {}", (*m_graph)[e].isUp);' \
    '    (*m_graph)[e].isUp = false;
    (*m_graph)[e].failureReported = true;
    SPDLOG_LOGGER_DEBUG(Logger::instance(), "setEdgeDown {}", (*m_graph)[e].isUp);' \
    DeclaredLinkFailureTest.ObservationWritersNeitherSetNorClearTheFailureReport

# M15. The dpid guard refuses EVERYTHING. Every W8-7 case in direction 1 goes green and all four
#      endpoints stop working -- the failure mode of an input check written from its error message
#      outwards.
mutate "the dpid guard refuses every link, not just dpid 0" \
    "$HS" \
    '    return srcDpid != 0 && dstDpid != 0;' \
    '    return false;' \
    DeclaredLinkFailureWireTest.TheDpidZeroRefusalDoesNotTouchOrdinarySwitchToSwitchLinks

# M16. The startup sweep widens to host-facing interfaces, so it reports residue this kernel could
#      not have made and names no owner for it.
mutate "the startup sweep reads host-facing interfaces too" \
    "$TFM" \
    '        const auto dst = boost::target(ed, *m_graph);
        const auto& sp = (*m_graph)[src];
        // Both ends must be switches: a host edge has no Mininet switch interface at its far end,
        // and since W8-7 no link endpoint can address one anyway.
        if (sp.vertexType != VertexType::SWITCH ||
            (*m_graph)[dst].vertexType != VertexType::SWITCH || sp.bridgeNameForMininet.empty())' \
    '        const auto& sp = (*m_graph)[src];
        if (sp.vertexType != VertexType::SWITCH || sp.bridgeNameForMininet.empty())' \
    ResidualNetemSweepTest.TheSweepCoversBothEndsOfEverySwitchToSwitchLinkAndNothingElse

# M17. 🔴 THE OVER-CORRECTION ADAM RULED AGAINST BY NAME: the sweep cleans up what it finds. A
#      kernel that removed netem at startup silently destroys the fault campaign it started
#      underneath, and tools/test_workflow/faults.sh is entitled to have netem on an interface.
mutate "the startup sweep clears the netem it finds" \
    "$TFM" \
    '        if (utils::netem::findExistingNetem(tree.output).safe)
        {
            found.push_back(iface);
        }' \
    '        if (utils::netem::findExistingNetem(tree.output).safe)
        {
            utils::netem::restoreInterface(iface, run);
            found.push_back(iface);
        }' \
    ResidualNetemSweepTest.TheSweepNeverRunsACommandThatChangesTheTree

# M18. The sweep runs on a testbed deployment, where the names this graph produces belong to
#      whatever else on the machine happens to answer to them.
mutate "the startup sweep runs tc on a non-MININET deployment" \
    "$TFM" \
    '    std::vector<std::string> found;
    if (m_mode != utils::MININET)' \
    '    std::vector<std::string> found;
    if (false)' \
    ResidualNetemSweepTest.ATestbedDeploymentRunsNoTcAtAll

# ================================================================================================
#   E-22 / WAKEUP.md 3-52: the recovery log has to carry the outcome. Direction 1, added
#   2026-09-07 and numbered AFTER M18 on purpose, so M1..M18 keep meaning what RED-GREEN.md and
#   the R2 summary already say they mean.
# ================================================================================================

# M19. 🔴 3-52 VERBATIM. The line goes back in front of findEdgeBySrcAndDstDpid and in front of the
#      pairing rule, which is where it sat until this ticket: a declined report, an applied one and
#      one naming an edge the graph does not hold all log `link recovered on 1:1 -> 5:1` again.
#      Measured on arm lw8b2 (2026-09-07): 04:33:37.198 DECLINED and 04:33:38.131 APPLIED are
#      byte-identical lines. The outcome-carrying line at the bottom is left in place, because that
#      is the honest version of this defect -- an operator grepping kernel.log for a recovery still
#      gets a hit for a report the kernel refused.
mutate "the recovery log moves back in front of the outcome (3-52 verbatim)" \
    "$HS" \
    '    auto fwdOpt = m_topologyAndFlowMonitor->findEdgeBySrcAndDstDpid({srcDpid, dstDpid});
    if (!fwdOpt.has_value())
    {
        logLinkRecoveryOutcome(RecoveryLogOutcome::NoSuchEdge,
                               srcDpid,
                               srcInterface,
                               dstDpid,
                               dstInterface);
        res.result(http::status::not_found);
        res.body() = R"({"error":"edge not found in topology"})";
        return;
    }' \
    '    SPDLOG_LOGGER_INFO(Logger::instance(),
                       "link recovered on {}:{} -> {}:{}",
                       srcDpid,
                       srcInterface,
                       dstDpid,
                       dstInterface);

    auto fwdOpt = m_topologyAndFlowMonitor->findEdgeBySrcAndDstDpid({srcDpid, dstDpid});
    if (!fwdOpt.has_value())
    {
        res.result(http::status::not_found);
        res.body() = R"({"error":"edge not found in topology"})";
        return;
    }' \
    DeclaredLinkFailureWireTest.ADeclinedRecoveryIsNotLoggedAsARecovery \
    DeclaredLinkFailureWireTest.ARecoveryForAnEdgeTheGraphDoesNotHoldSaysThatInstead

# M20. 🔴 The half a fix like this stops at: the call is in the right PLACE and still says the same
#      thing whatever happened. Moving a line is not the deliverable -- the sentence is. Every
#      structural property survives here (one call site per outcome, logged after the decision),
#      so only a case that reads the WORDS can tell this apart from the fix.
mutate "the three outcomes are one sentence again, just logged later" \
    "$HS" \
    '    switch (outcome)
    {
        case RecoveryLogOutcome::Withdrawn:
            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "link recovered on {}:{} -> {}:{}: any declaration standing on this "
                               "link was withdrawn and both directions are up",
                               srcDpid,
                               srcInterface,
                               dstDpid,
                               dstInterface);
            return;
        case RecoveryLogOutcome::Retained:
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "link recovery declined on {}:{} -> {}:{}: a link failure is "
                               "declared here and nothing ever reported this link broken, so the "
                               "declaration was retained and the link is still down. POST "
                               "/ndt/inject_link_recovery to withdraw it",
                               srcDpid,
                               srcInterface,
                               dstDpid,
                               dstInterface);
            return;
        case RecoveryLogOutcome::NoSuchEdge:
            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "link recovery ignored on {}:{} -> {}:{}: the topology holds no "
                               "such edge, so nothing was withdrawn and nothing was marked up",
                               srcDpid,
                               srcInterface,
                               dstDpid,
                               dstInterface);
            return;
    }' \
    '    switch (outcome)
    {
        case RecoveryLogOutcome::Withdrawn:
        case RecoveryLogOutcome::Retained:
        case RecoveryLogOutcome::NoSuchEdge:
            SPDLOG_LOGGER_INFO(Logger::instance(),
                               "link recovered on {}:{} -> {}:{}",
                               srcDpid,
                               srcInterface,
                               dstDpid,
                               dstInterface);
            return;
    }' \
    DeclaredLinkFailureWireTest.ADeclinedRecoveryIsNotLoggedAsARecovery \
    DeclaredLinkFailureWireTest.AnAppliedRecoveryLogsThatTheDeclarationWentAway \
    DeclaredLinkFailureWireTest.ARecoveryForAnEdgeTheGraphDoesNotHoldSaysThatInstead

# ================================================================================================
# 6. the widenings -- these MUST survive
# ================================================================================================

# W1. A comment. If anything reddens here, every catch above is measuring "a file was edited and
#     rebuilt" rather than "the behaviour changed".
widen "a comment, nothing else" \
    "$TFM" \
    '    // Read once. The graph is under a shared lock inside that call and the sweep below runs a' \
    '    // Read once. The graph is held under a shared lock in that call and the sweep below runs a'

# W2. The refusal's PROSE. The cases assert 400 and that the message names `dpid`; a suite that
#     reddens on a rewording would make the next person change a test to improve a sentence.
widen "the dpid-0 refusal is reworded (it still names the field)" \
    "$HS" \
    '    R"({"error":"src_dpid and dst_dpid must both name a switch: dpid 0 is the host end of a host )"' \
    '    R"({"error":"both src_dpid and dst_dpid have to name a switch: a dpid of 0 is the host end of a host )"'

# W3. The pairing rule written as an equivalent expression. The control for tests that pin the
#     structure of the fix rather than what the graph ends up holding.
widen "the pairing rule is written as an equivalent expression" \
    "$TFM" \
    '    if (!eprop.failureReported && eprop.declaredDown)' \
    '    if (eprop.declaredDown && eprop.failureReported == false)'

# W4. E-22's control. The declined sentence is REWORDED while still saying the outcome. The three
#     new cases key on the word that carries the outcome; if one of them reddens here it is pinning
#     a sentence instead, and the next person to improve the wording would have to edit a test.
widen "the declined recovery sentence is reworded (it still says the declaration was retained)" \
    "$HS" \
    '                               "declaration was retained and the link is still down. POST "
                               "/ndt/inject_link_recovery to withdraw it",' \
    '                               "declaration was retained and the link stays down. Use POST "
                               "/ndt/inject_link_recovery to take the injection back",'

# ================================================================================================
# 7. restore and verdict
# ================================================================================================
restore
REBUILD_OK=1
build || REBUILD_OK=0

printf '\n=== restore ===\n'
ok=1
for f in "${FILES[@]}"; do
    now=$(sha256sum "$f" | cut -d' ' -f1)
    if [[ "$now" != "${SHA[$f]}" ]]; then
        echo "  🔴 NOT RESTORED: $f  (${now:0:16} != ${SHA[$f]:0:16})  DO NOT COMMIT"; ok=0
    elif ! cmp -s "${SNAP[$f]}" "$f"; then
        echo "  🔴 NOT BYTE-IDENTICAL: $f  DO NOT COMMIT"; ok=0
    fi
done
[[ "$ok" == 1 ]] && echo "  all ${#FILES[@]} file(s) byte-identical to the pre-run snapshot"
if [[ "$REBUILD_OK" == 1 ]]; then
    echo "  rebuilt from the restored tree"
else
    echo "  🔴 THE RESTORED TREE DOES NOT BUILD -- the binary on disk is whatever the last"
    echo "     mutation left. Do not run another gate against it."
    ok=0
fi
run_tests "$FILTER"
if [[ "$STATUS" != pass ]]; then
    echo "  🔴 the suite is red after restore -- a mutant object is still linked in: $FAILED"; ok=0
else
    echo "  suite green again after restore"
fi
BIN_SHA_AFTER=$(sha256sum "$BIN" 2>/dev/null | cut -c1-16)
if [[ "$BIN_SHA_AFTER" != "$BIN_SHA_BEFORE" ]]; then
    echo "  🔴 test binary sha changed: $BIN_SHA_AFTER (was $BIN_SHA_BEFORE). The tree restored"
    echo "     byte-identically, so a binary that did not is a build that is not reproducible"
    echo "     from it -- and every 'caught' above was measured against binaries built the same way."
    ok=0
else
    echo "  test binary sha unchanged: $BIN_SHA_AFTER"
fi

printf '\n=== verdict ===\n'
printf '  %d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"
printf '  %d widenings, %d wrongly caught\n' "$WIDENINGS" "$WIDENINGS_CAUGHT"

if [[ "$ok" != 1 ]]; then exit 2; fi
if (( SURVIVORS > 0 || WIDENINGS_CAUGHT > 0 )); then exit 1; fi
echo "  W8b gate: a withdrawal cannot be unpaired from a reported break by any of five routes,"
echo "  dpid 0 cannot be let back in at the helper or at one door, the startup sweep cannot go"
echo "  silent or blind, the recovery log cannot go back in front of its outcome or collapse its"
echo "  three outcomes into one sentence, and eight ways of over-correcting are caught too."
exit 0
