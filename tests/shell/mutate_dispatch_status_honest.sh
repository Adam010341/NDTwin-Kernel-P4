#!/usr/bin/env bash
#
# Mutation gate for W11 (#54 / R6 K-4): the dispatch-status endpoint's honest counters.
#
# [Co-developed with claude code -- Adam]
#
# Three claims are under test and they fail in different places, so the gate spans three suites
# and two lanes:
#
#   A  the counters are named for what they count      `dispatched_ok`, not `succeeded`
#   B  a second group answers about the SWITCH         accepted/rejected/unknown, unknown on OVS
#   C  a caller can ask about its own POST             ?request_id=<id>
#
#   cpp       tests/test_DispatchOutcomeLog.cpp     the classification and the per-request tallies
#             tests/test_RoutingStrategies.cpp      the carrier: does a plane's refusal arrive as one
#             tests/test_HttpSessionRouting.cpp     the response body and the route
#   contract  tools/contract_test --self-test       the schema and the two closure invariants
#
# 🔴 The mutation this gate exists for is number 2: `accepted_by_switch` derived from
# `dispatched_ok`. That is not a hypothetical slip -- it is the shortest way to make the new
# counter "work" on the OVS plane, where it is otherwise permanently `unknown`, and it converts an
# honest "I do not know" into a confident wrong answer for every rule in the fabric. Everything
# else here is scaffolding around that one line.
#
# 🔴 Same divergence from mutate_f6_stale_table_carry_forward.sh as the A-7 gate: a mutant that
# does not compile is a SURVIVOR, not a skip. A mutation that cannot be built has not been shown
# to be caught, and on a shared tree "it did not compile" reads as "it passed".
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# byte-identity asserted at the end. The baseline is the WORKING TREE, not HEAD.
#
# Usage:
#   tests/shell/mutate_dispatch_status_honest.sh               full gate (needs a configured BUILD_DIR)
#   tests/shell/mutate_dispatch_status_honest.sh --dry-run     anchors only, NOT a gate result
#   tests/shell/mutate_dispatch_status_honest.sh --python-only the contract lane, PARTIAL result
#   BUILD_DIR=build-asan tests/shell/mutate_dispatch_status_honest.sh
#
# Assumes: cwd is the repo root, and ${BUILD_DIR:-build} is already configured (ninja) for the
# full run. Run it THROUGH tools/build_guard/guarded_build.sh -- the plain `cmake --build` below
# is deliberate (nesting guards is refused), and the guard's PATH shim is what bounds the jobs.
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (harness fault only:
#       missing file, unconfigured build, red baseline, or a tree left unrestored).
set -uo pipefail

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
FILTER='DispatchOutcomeLogTest.*:DispatchStatusEndpointTest.*:RoutingStrategyFixture.*'

OUT=include/ndt_core/routing_management/DispatchOutcomeLog.hpp
SES=src/ndt_core/http/HttpSession.cpp
BASE=src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp
SPC=tools/contract_test/spec.py
FILES=("$OUT" "$SES" "$BASE" "$SPC")

CONTRACT_PY="${CONTRACT_PY:-/home/adam/miniconda3/bin/python3}"

MODE=full
case "${1:-}" in
    --dry-run)     MODE=dryrun ;;
    --python-only) MODE=python ;;
    "")            ;;
    *) echo "REFUSE: unknown argument '$1'. Use --dry-run or --python-only." >&2; exit 2 ;;
esac

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "REFUSE: $f not found -- run from the repo root." >&2; exit 2; }
done
[[ -x "$CONTRACT_PY" ]] || {
    echo "REFUSE: contract interpreter $CONTRACT_PY not found. Set CONTRACT_PY." >&2; exit 2; }
if [[ "$MODE" == full ]]; then
    [[ -d "$BUILD_DIR" ]] || {
        echo "REFUSE: $BUILD_DIR is not configured. cmake -B $BUILD_DIR -G Ninja" >&2
        echo "        (or run --python-only for the lane that needs no build)" >&2
        exit 2; }
fi

BK=$(mktemp -d)
snap() { echo "$BK/$(basename "$1")"; }
for f in "${FILES[@]}"; do cp -p "$f" "$(snap "$f")"; done

# A .pyc whose source is edited back to the same length within the same second keeps its
# mtime+size validation stamp, so the interpreter would serve the MUTANT's bytecode from a
# pristine-looking file. Both this and PYTHONDONTWRITEBYTECODE=1, because either alone has a hole.
clear_pyc() {
    find tools/contract_test -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
    return 0
}

restore() {
    local f
    for f in "${FILES[@]}"; do
        cp -p "$(snap "$f")" "$f"
        # cp -p restores the ORIGINAL mtime, which is older than the object built from the mutant,
        # so ninja would see nothing to do and the next lane would test the mutant against a
        # pristine source. touch is what actually restores the build.
        touch "$f"
    done
    clear_pyc
}
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
DECLARED=0

# --- helpers ---------------------------------------------------------------------------------

# anchor_count <file> <literal>. python, not `grep -c -F`: grep splits a multi-line pattern into
# several patterns and counts matching LINES, so a multi-line anchor would report its line count
# and be rejected as "not unique". Most anchors below span lines.
anchor_count() {
    ANCHOR="$2" "$CONTRACT_PY" - "$1" <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
}

build() { cmake --build "$BUILD_DIR" --target "$TARGET" >/dev/null 2>&1; }

# Each red_<lane> prints the space-separated identities of the tests that failed, empty if green.
# rc comes from the process directly, never through a pipe, so a crash cannot be read as a pass.

red_cpp() {
    local out rc
    out=$("$BIN" --gtest_filter="$FILTER" 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^\[  FAILED  \] \([A-Za-z0-9_]*\.[A-Za-z0-9_]*\).*/\1/p' <<<"$out" | sort -u | tr '\n' ' '
}

red_contract() {
    local out rc
    clear_pyc
    out=$(cd tools/contract_test && PYTHONDONTWRITEBYTECODE=1 \
              "$CONTRACT_PY" ./run_contract_test.py --self-test 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^  FAIL  \(.*\)$/\1/p' <<<"$out" | sed 's/:.*//' | sort -u | tr '\n' ' '
}

red_for() {
    case "$1" in
        cpp)      red_cpp ;;
        contract) red_contract ;;
        *) echo "HARNESS-FAULT-unknown-lane-$1" ;;
    esac
}

# mutate <label> <lane> <file> <anchor> <replacement> <expected-test> [declared-uncovered-reason]
mutate() {
    local label="$1" lane="$2" file="$3" anchor="$4" repl="$5" expected="$6" declared="${7:-}"

    if [[ "$MODE" == python && "$lane" == cpp ]]; then return; fi

    local n; n=$(anchor_count "$file" "$anchor")
    printf '\n=== %s  [%s] ===\n' "$label" "$lane"
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    MUTATIONS=$((MUTATIONS + 1))
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- this mutation proves nothing, so it is"
        echo "     counted as a survivor rather than skipped. Fix the anchor."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    ANCHOR="$anchor" REPL="$repl" "$CONTRACT_PY" - "$file" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a, r = os.environ["ANCHOR"], os.environ["REPL"]
assert s.count(a) == 1, "anchor is not unique at write time"
p.write_text(s.replace(a, r, 1))
PY
    if [[ $? -ne 0 ]]; then
        echo "  🔴 mutation could not be applied. NOT a pass."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    clear_pyc

    if [[ "$lane" == cpp ]] && ! build; then
        echo "  🔴 MUTANT DOES NOT COMPILE -- it has not been shown to be caught, which is what"
        echo "     this gate measures. Counted as a survivor (see the divergence note above)."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    local failed; failed=$(red_for "$lane")
    if [[ -z "$failed" ]]; then
        if [[ -n "$declared" ]]; then
            printf '  ⚪ SURVIVED AS DECLARED -- %s\n' "$declared"
            DECLARED=$((DECLARED + 1)); MUTATIONS=$((MUTATIONS - 1))
        else
            echo "  🔴 NOTHING WENT RED -- the mutation survived. That behaviour is untested."
            SURVIVORS=$((SURVIVORS + 1))
        fi
    elif grep -q -- "$expected" <<<"$failed"; then
        printf '  ✅ caught by %s\n     all red: %s\n' "$expected" "$failed"
    else
        printf '  🔴 WRONG TEST WENT RED: got [%s], expected [%s]\n' "$failed" "$expected"
        echo "     The gate fires, but not for the reason this mutation claims."
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# dry_one -- the --dry-run callback. Same signature as mutate(), touches nothing.
DRY_BAD=0
dry_one() {
    local label="$1" lane="$2" file="$3" anchor="$4"
    local n; n=$(anchor_count "$file" "$anchor")
    if [[ "$n" -eq 1 ]]; then
        printf '  ✅ 1x  [%-8s] %s\n            %s\n' "$lane" "$label" "$file"
    else
        printf '  🔴 %sx  [%-8s] %s\n            %s\n' "$n" "$lane" "$label" "$file"
        DRY_BAD=$((DRY_BAD + 1))
    fi
}

# --- the mutation table ------------------------------------------------------------------------
# One list, walked twice: `each_mutation mutate` runs the gate, `each_mutation dry_one` checks the
# anchors without touching anything. A callback rather than an array of packed strings because
# most anchors span lines and `read` stops at the first newline.
each_mutation() {
    local m="$1"

    # --- B: what the second group means ---------------------------------------------------

    # 🔴 THE ONE THIS GATE EXISTS FOR. The cheapest way to make accepted_by_switch non-zero on a
    # plane that adjudicates nothing, and the exact claim #54 is about: dispatch read as
    # programming. Every OVS rule would be reported as confirmed by a switch that never answered.
    "$m" "1. an acceptance by the far end is read as an acceptance by the switch" cpp "$OUT" \
        '        if (result.confirmsProgramming)
        {
            return SwitchOutcome::AcceptedBySwitch;
        }' \
        '        if (result.ok)
        {
            return SwitchOutcome::AcceptedBySwitch;
        }' \
        'DispatchOutcomeLogTest.AnOvsDispatchIsUnknownAtTheSwitchAndNotAnAcceptance' ''

    # The other direction: the group collapses to "unknown" for everything, so a plane that CAN
    # answer stops being asked. A field pinned at unknown reads as "checked, nothing wrong".
    "$m" "2. the classification is pinned at unknown, so no plane can ever answer" cpp "$OUT" \
        '        if (result.confirmsProgramming)
        {
            return SwitchOutcome::AcceptedBySwitch;
        }' \
        '        if (false)
        {
            return SwitchOutcome::AcceptedBySwitch;
        }' \
        'DispatchOutcomeLogTest.AConfirmedP4DispatchIsAnAcceptanceBySwitch' ''

    # R6 K-4's half: the proxy looked and said the entry is not there, and the bucket for that
    # disappears. The delete that removed nothing goes back to being indistinguishable.
    "$m" "3. a switch-side refusal is downgraded to 'unknown'" cpp "$OUT" \
        '            return SwitchOutcome::RejectedBySwitch;' \
        '            return SwitchOutcome::Unknown;' \
        'DispatchOutcomeLogTest.ANoOpDeleteIsNotAnAcceptanceBySwitch' ''

    # --- the carrier: does a plane's refusal arrive as one --------------------------------

    # The proxy's per-entry refusal stops being marked as a verdict, so P4 loses the only
    # switch-side "no" this kernel ever receives and everything reads `unknown` there too.
    "$m" "4. post() drops the plane's refusal claim on the error-body path" cpp "$BASE" \
        '                                      briefly(responseBody))
                                  .withProgrammingRefused(successConfirmsProgramming());' \
        '                                      briefly(responseBody));' \
        'RoutingStrategyFixture.AProxyRefusalIsAVerdictAboutTheSwitch' ''

    # The opposite and worse error: every refusal is a switch's refusal, so a Ryu 400 -- which the
    # switch never saw -- is reported as the switch rejecting the rule. B-2b in a new field.
    "$m" "5. every refusal is attributed to a switch, whatever plane answered" cpp "$BASE" \
        '                          .withProgrammingRefused(successConfirmsProgramming());
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "{} failed: {}",
                           operation,
                           result.message);
        return result;
    }

    // Some proxies answer 200' \
        '                          .withProgrammingRefused(true);
        SPDLOG_LOGGER_WARN(Logger::instance(),
                           "{} failed: {}",
                           operation,
                           result.message);
        return result;
    }

    // Some proxies answer 200' \
        'RoutingStrategyFixture.ARyuRejectionIsNotAVerdictAboutTheSwitch' ''

    # --- C: per-request attribution -------------------------------------------------------

    # The attribution is dropped, so every id answers zero and a caller concludes its own batch
    # was never dispatched -- the failure mode is silent and points the caller at a retry.
    "$m" "6. outcomes stop being attributed to their request" cpp "$OUT" \
        '        noteRequestOutcome_(job.requestId, result.ok, switchOutcome);' \
        '        (void)switchOutcome; // MUTANT' \
        'DispatchOutcomeLogTest.TwoRequestsDoNotPolluteEachOther' ''

    # A tally is invented for an id nobody registered, which collapses "unknown request" into
    # "known but not yet drained". Those two lead to opposite actions: fix your id, or wait.
    "$m" "7. an unregistered request id is invented on first outcome" cpp "$OUT" \
        '        const auto it = requests_.find(requestId);
        if (it == requests_.end())
        {
            return;
        }
        RequestTally& tally = it->second;' \
        '        const auto it = requests_.try_emplace(requestId).first;
        RequestTally& tally = it->second;' \
        'DispatchOutcomeLogTest.AnUnregisteredRequestIsNotInvented' ''

    # Re-registering an id wipes what is known about it. A reset tally reads exactly like a batch
    # that has not been dispatched yet, so the caller waits for something that already happened.
    "$m" "8. re-registering an id resets its counts" cpp "$OUT" \
        '        if (!inserted)
        {
            return;
        }' \
        '        if (false)
        {
            return;
        }' \
        'DispatchOutcomeLogTest.ReRegisteringAnIdDoesNotResetItsCounts' ''

    # The 2026-09-05 ruling undone: back to a ring a single burst can overflow, so the evidence of
    # a bad burst's first three quarters is replaced by an eviction count.
    "$m" "9. the failure ring shrinks below a dispatcher burst" cpp "$OUT" \
        '    static constexpr std::size_t kDefaultCapacity = 2000;' \
        '    static constexpr std::size_t kDefaultCapacity = 256;' \
        'DispatchOutcomeLogTest.TheFailureRingIsAsLargeAsADispatcherBurst' ''

    # --- A: the names, and the route ------------------------------------------------------

    # The rename reverted. The value is identical and the claim is not: "succeeded" is read as
    # "the switch has the rule", which is what 20 installs of one match measured as +20.
    "$m" "10. the counter is called succeeded again" cpp "$SES" \
        '                {"dispatched_ok", dispatchedOk},' \
        '                {"succeeded", dispatchedOk},' \
        'DispatchStatusEndpointTest.TheCountersAreNamedForWhatTheyCount' ''

    # The number without its reason. On OVS `unknown` equals `dispatched` permanently, and a
    # permanently-uninformative field with nothing beside it is read as "checked, nothing wrong".
    "$m" "11. the unknown count ships without its explanation" cpp "$SES" \
        '                {"why_unknown", kWhySwitchOutcomeUnknown}};' \
        '                {"why_unknown", ""}};' \
        'DispatchStatusEndpointTest.AnOvsFabricReportsUnknownAtTheSwitchAndSaysWhy' ''

    # The route back to an exact compare: ?request_id= falls through every branch to the
    # not-found tail, so the whole of C is unreachable while every unit test of it stays green.
    "$m" "12. the route stops accepting a query string" cpp "$SES" \
        '        else if (method == http::verb::get &&
                 utils::pathIs(target, "/ndt/get_flow_dispatch_status"))' \
        '        else if (method == http::verb::get && target == "/ndt/get_flow_dispatch_status")' \
        'DispatchStatusEndpointTest.TheRouteAcceptsAQueryStringAtAll' ''

    # An id this kernel has never heard of answers 200. A caller that reads only the status code
    # is told its request is fine -- the over-claim processFlowBatch answers 404 for.
    "$m" "13. an unknown request id is answered 200" cpp "$SES" \
        '        res.result(http::status::not_found);
        res.body() =
            json{{"status", "error"},
                 {"error", "unknown request_id"},' \
        '        res.result(http::status::ok);
        res.body() =
            json{{"status", "error"},
                 {"error", "unknown request_id"},' \
        'DispatchStatusEndpointTest.AnUnknownRequestIdIsNotAnswered200' ''

    # The defect test_HttpSessionRouting.cpp was written for, on the new parameter: std::stoull
    # throws into buildResponse's std::exception clause, so a typo answers 500 "I am broken".
    "$m" "14. request_id is parsed with std::stoull again" cpp "$SES" \
        '    const auto requestId = utils::tryParseUint64(raw);' \
        '    const auto requestId = std::optional<uint64_t>(std::stoull(raw));' \
        'DispatchStatusEndpointTest.ANonNumericRequestIdIsAClientErrorNotAServerError' ''

    # --- contract -------------------------------------------------------------------------

    "$m" "15. the switch-side closure invariant answers nothing" contract "$SPC" \
        '    sw = data.get("switch_outcome")
    if sw is None:
        return []' \
        '    return []  # MUTANT
    sw = data.get("switch_outcome")
    if sw is None:
        return []' \
        'switch_outcome_closes' ''

    # The specific check that catches an acceptance count borrowed from the dispatch counters --
    # the wire-level form of mutation 1, and the one a live run would have to catch.
    "$m" "16. the contract stops checking acceptance against dispatched_ok" contract "$SPC" \
        '    if dispatched_ok is not None and accepted > dispatched_ok:' \
        '    if False and dispatched_ok is not None and accepted > dispatched_ok:' \
        'switch_outcome_closes' ''

    # --- declared-uncovered -------------------------------------------------------------------
    # Run, reported, and NOT counted as a survivor -- with the reason stated, because an exemption
    # nobody wrote down is indistinguishable from a gap nobody noticed.

    "$m" "17. the HTTP layer stops stamping the request id onto its jobs" cpp "$SES" \
        '        job.requestId = requestId;' \
        '        (void)job; // MUTANT' \
        'DispatchStatusEndpointTest.ARequestIdAnswersForThatBatchAlone' \
        "processFlowBatch is not reachable from this suite: it dereferences both TopologyAndFlowMonitor (getSwitchKind) and DeviceConfigurationAndPowerManager (updateOpenFlowTables), and no peer in tests/ builds the second. The stamping is covered live -- POST a flow batch, read request_id out of the 200 body, GET ...?request_id=<id> and check dispatched is the batch size -- see doc/audit/2026-09-06_fix-dispatch-status-honest/FIX-DISPATCH-STATUS-HONEST.md"

    "$m" "18. the HTTP layer stops registering the request before enqueueing" cpp "$SES" \
        '    m_controller->noteRequestEnqueued(requestId, acceptedJobs.size());' \
        '    // MUTANT: not registered' \
        'DispatchStatusEndpointTest.ARequestIdAnswersForThatBatchAlone' \
        "same reason as 17. Note the direction of this one: without registration every id answers 404, so a live check that only asserts 'the id is known' would catch it -- it is the recipe named above, not a test in this tree, that closes it"
}

# --- dry run -----------------------------------------------------------------------------------

if [[ "$MODE" == dryrun ]]; then
    echo "W11 dispatch-status honesty gate -- ANCHOR DRY RUN"
    echo
    echo "  🔴 THIS IS NOT A GATE RESULT. Nothing is built, nothing is mutated and no test is"
    echo "     run. It checks only that every anchor still matches its file exactly once, which"
    echo "     is the failure this harness cannot otherwise detect: an anchor that has drifted"
    echo "     makes its mutation a silent no-op that then reports as caught."
    echo
    DRY_BAD=0
    each_mutation dry_one
    echo
    if [[ "$DRY_BAD" -ne 0 ]]; then
        echo "  $DRY_BAD anchor(s) do not match exactly once. The gate would refuse; fix them first."
        exit 2
    fi
    echo "  all anchors match exactly once -- the gate is runnable. STILL NOT A GATE RESULT:"
    echo "  run without --dry-run (or with --python-only) to find out what is actually caught."
    exit 0
fi

# --- baseline ----------------------------------------------------------------------------------

echo "W11 dispatch-status honesty gate (#54 / R6 K-4)"
[[ "$MODE" == python ]] && echo "  🔴 --python-only: PARTIAL RESULT, the cpp lane is skipped entirely"
echo "  mode      : $MODE"
echo "  build dir : $BUILD_DIR"
echo "  target    : $TARGET"
echo "  filter    : $FILTER"
for f in "${FILES[@]}"; do printf '  baseline  : %s %s\n' "$(sha256sum "$f" | cut -c1-16)" "$f"; done
echo
echo "baseline (unmutated) must build and be green:"

LANES=(contract)
[[ "$MODE" == full ]] && LANES=(cpp contract)

if [[ "$MODE" == full ]]; then
    if ! build; then
        echo "  REFUSE: the unmutated tree does not build. Nothing below would mean anything."
        cmake --build "$BUILD_DIR" --target "$TARGET" 2>&1 | tail -20 | sed 's/^/    /'
        exit 2
    fi
    # A filter that matches nothing runs zero tests and exits 0, which this gate would read as a
    # green baseline and then as "caught" for every mutation that reddens nothing. Assert that
    # the filter actually selects tests before believing any of it.
    if ! "$BIN" --gtest_filter="$FILTER" --gtest_list_tests 2>/dev/null | grep -q .; then
        echo "  REFUSE: the filter '$FILTER' selects no tests. A gate over an empty set is green"
        echo "          for every mutation and proves nothing."
        exit 2
    fi
fi
clear_pyc
for lane in "${LANES[@]}"; do
    base_red=$(red_for "$lane")
    if [[ -n "$base_red" ]]; then
        echo "  REFUSE: the $lane baseline is RED before any mutation."
        printf '    red: %s\n' "$base_red"
        exit 2
    fi
    printf '  ok       %s baseline green\n' "$lane"
done

# --- mutations ---------------------------------------------------------------------------------

each_mutation mutate

# --- negative control --------------------------------------------------------------------------
# A gate that reddens on anything is not a gate. A comment-only edit must leave every lane green;
# if one goes red those tests are change detectors, not a specification.

control() {
    local lane="$1" file="$2" anchor="$3" repl="$4"
    printf '\n=== NEGATIVE CONTROL [%s]: comment-only edit must stay GREEN ===\n' "$lane"
    local n; n=$(anchor_count "$file" "$anchor")
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 control anchor is not unique ($n matches) -- the control proves nothing."
        SURVIVORS=$((SURVIVORS + 1)); return
    fi
    ANCHOR="$anchor" REPL="$repl" "$CONTRACT_PY" - "$file" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace(os.environ["ANCHOR"], os.environ["REPL"], 1))
PY
    clear_pyc
    if [[ "$lane" == cpp ]] && ! build; then
        echo "  🔴 a comment broke the build -- the anchor landed somewhere it should not have."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    local ctrl_red; ctrl_red=$(red_for "$lane")
    if [[ -z "$ctrl_red" ]]; then
        echo "  ✅ green: the suite does not react to a comment"
    else
        printf '  🔴 A COMMENT TURNED THE SUITE RED: %s\n' "$ctrl_red"
        echo "     These tests are change detectors, not a specification."
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

if [[ "$MODE" == full ]]; then
    control cpp "$OUT" \
        '    std::atomic<uint64_t> acceptedBySwitch_{0};' \
        '    // MUTANT: a comment, and nothing else.
    std::atomic<uint64_t> acceptedBySwitch_{0};'

    # A second control on the response body, because the assertions there read JSON keys and a
    # test that reads a body by position rather than by key would react to any edit near it.
    control cpp "$SES" \
        '    json failures = json::array();' \
        '    // MUTANT: a comment, and nothing else.
    json failures = json::array();'
fi

control contract "$SPC" \
    '    sw = data.get("switch_outcome")' \
    '    # MUTANT: a comment, and nothing else.
    sw = data.get("switch_outcome")'

# --- byte-identity and verdict -----------------------------------------------------------------

restore
printf '\n--- baseline restored? ---\n'
ok=1
for f in "${FILES[@]}"; do
    if cmp -s "$(snap "$f")" "$f"; then
        printf '  byte-identical  %s\n' "$f"
    else
        printf '  🔴 NOT RESTORED: %s -- do NOT commit\n' "$f"; ok=0
    fi
done
[[ "$ok" == 1 ]] || exit 2

if [[ "$MODE" == full ]] && ! build; then
    echo "🔴 THE TREE DOES NOT BUILD AFTER RESTORE -- do NOT commit."; exit 2
fi
for lane in "${LANES[@]}"; do
    after_red=$(red_for "$lane")
    if [[ -n "$after_red" ]]; then
        printf '🔴 THE %s SUITE IS RED AFTER RESTORE: %s\n' "$lane" "$after_red"
        echo "   A mutant is still built in. Do NOT commit."; exit 2
    fi
done
echo "  every lane green again after restore"

printf '\n%s mutations, %s survived' "$MUTATIONS" "$SURVIVORS"
[[ "$DECLARED" -gt 0 ]] && printf ' (+%s declared-uncovered, listed above)' "$DECLARED"
printf '\n'
[[ "$MODE" == python ]] && echo "🔴 PARTIAL: the cpp lane did not run. This is not a full gate result."
[[ "$SURVIVORS" -eq 0 ]]
