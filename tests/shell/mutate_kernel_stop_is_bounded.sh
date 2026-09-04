#!/usr/bin/env bash
#
# Mutation gate for FINDINGS #27 and #76 -- stop() must be bounded, whatever the control plane does.
#
# [Co-developed with claude code -- Adam]
#
# Covers tests/test_KernelStopIsBounded.cpp, and re-runs tests/test_PowerManagerShutdown.cpp's
# death tests, because one of the two directions below can only be caught by them.
#
# WHAT THE DEFECTS WERE
#   #27 DeviceConfigurationAndPowerManager::fetchOpenFlowTablesInternal walks every up switch and
#       runs `curl -s --max-time 8` per switch, reading its stop flag only between rounds. Measured
#       on the 10-switch bmv2 fabric with the proxy not answering: SIGINT took 81.09 s, ~72 s of it
#       inside the join -- 9 remaining switches x 8 s, to the second.
#   #76 TopologyAndFlowMonitor's poll does the same three times a round at --max-time 5, and
#       main.cpp prints `Exiting` *before* calling the stop that blocks in it.
#
# 🔴 TWO DIRECTIONS, AND THE SECOND ONE IS WHY THIS GATE EXISTS AT ALL
#   1. RESTORING the defect must be caught             (M1-M7)
#      -- by every route it could come back: the in-round check deleted, either curl put back on
#         the uncancellable executor, request() no longer killing, the interruptible sleep made
#         uninterruptible, stop() no longer requesting, and the report silenced.
#   2. BUYING THE BOUND BY DROPPING THE JOIN must ALSO be caught   (M8)
#      -- this is the tempting wrong fix and it is *worse than the defect*. A stop() that does not
#         join returns in microseconds and makes every timing assertion in direction 1 go green,
#         while destroying a joinable std::thread -- which is std::terminate, i.e. KNOWN-ISSUES B-5
#         all over again. A gate without M8 would give a green light to deleting the join.
#
# 🔴 FIVE MUTATIONS MUST **NOT** BE CAUGHT (W1-W5). A suite that reddens on these is pinning source
# text rather than behaviour, and every catch above would be worth nothing:
#   W1  a comment                     -- the classic control
#   W2  the report's wording          -- the sentence is a diagnostic, not the behaviour. The tests
#                                        assert the worker and subsystem NAMES the report carries,
#                                        never the prose around them, and this proves it.
#   W3  a stop check written as an equivalent expression -- proves the tests assert elapsed time,
#                                        not the shape of the branch that produced it
#   W4  the walk's top-of-loop stop check REMOVED
#   W5  the three between-endpoint checks in pollControlPlaneTopology REMOVED
#       🔴 Read these two before trusting the tally. They are genuinely redundant *today*:
#       execCommandCancellable asks stopRequested() before it forks, so after a stop the remaining
#       switches and endpoints cost a syscall each and the round ends inside the bound anyway. This
#       gate therefore CANNOT catch their removal, and listing them as widenings is the honest way
#       to say so -- they are defence in depth against a future edit to the executor, not behaviour
#       this suite defends. FIX-KERNEL-STOP-BOUNDED.md §8.3 repeats it.
#
#       🔴 THE 2026-09-04 RUN CAUGHT BOTH OF THEM, AND THE FAULT WAS IN THIS SUITE, NOT IN THEM.
#       Both reddened AStopThatExceedsItsBoundSaysWhatItIsWaitingOn, which was then an integration
#       test: it started a real manager, set the report bound to 0, called stop() and demanded the
#       report appear. stop() runs request() -- which kills the in-flight curl AND notify_all()s
#       every sleeper -- and only then samples the worker set once. Whether any worker is still
#       registered at that instant is a race between the main thread and three workers, and the
#       widenings move a few instructions on the workers' exit path.
#       MEASURED, same binary, same source, only CPU affinity changed:
#           all 14 cores  15/15 pass
#           taskset -c 3   0/15 pass
#       In the failing runs stop() had behaved correctly -- the captured log carries
#       "cancelled 1 in-flight control-plane request(s)" and no report, which is right, because
#       every worker had already finished and there was nothing to wait on. The case was replaced
#       with three cases that own their own StopSignal and hold a WorkerScope alive, so the
#       straggler is a fact of the fixture instead of an outcome of the scheduler.
#
# 🔴 A MUTANT THAT DOES NOT COMPILE IS A SURVIVOR, not a skip: the suite never ran, so it proves
# nothing. Same for an anchor that has moved, and for a run that hangs.
#
# 🔴 GUARDS ITS OWN BASELINE. Every file it can touch is snapshotted with `cp -p` first, an EXIT
# trap restores them however this exits including Ctrl-C, and the run ends by asserting byte
# identity against the snapshot AND that the test binary's sha is the one the baseline built.
# `cp -p` restores the ORIGINAL mtime -- older than the object built from the mutant -- so ninja
# would see nothing to do and the next mutation would be measured against a stale binary. A
# restored file is therefore also `touch`ed, but ONLY if it actually changed.
#
# 🔴 NEVER KILLS ANYTHING BY NAME. No pkill, no pgrep: `timeout` owns the only child. The tests
# bind a loopback listener (an ephemeral port, and :8081 -- which they SKIP on if it is taken) and
# start the kernel's own worker threads in-process. Nothing here starts Mininet, bmv2 or OVS.
#
# 🔴 THIS SUITE IS SLOW ON PURPOSE. A caught mutation is one that makes a stop take 8-32 s, so a
# red case costs that much wall time. TEST_TIMEOUT is sized for it; do not lower it to "speed the
# gate up" -- a hang and a catch would stop being distinguishable.
#
# 🔴 BUILD UNDER THE GUARD. This laptop's oomd took the user's own application down twice.
#   tools/build_guard/guarded_build.sh ./tests/shell/mutate_kernel_stop_is_bounded.sh
#
# Usage:  tools/build_guard/guarded_build.sh ./tests/shell/mutate_kernel_stop_is_bounded.sh
#   BUILD_DIR=build     configured build directory (ninja)
#   JOBS=2              build parallelism
#   TEST_TIMEOUT=300    seconds allowed per test-binary run
#
# Exit: 0 every mutation caught by the test it names, all five widenings survived, tree restored
#       1 at least one mutation survived, or a widening was caught
#       2 no verdict is possible: baseline red or not building, anchor drift, hang, failed restore
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

BUILD_DIR="${BUILD_DIR:-build}"
JOBS="${JOBS:-2}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
FILTER='KernelStopIsBoundedTest.*'
# M8 is caught by the B-5 death tests, not by the timing suite. The restore check at the end runs
# both, so a mutation that damaged one and not the other cannot be missed.
FILTER_ALL='KernelStopIsBoundedTest.*:PowerManagerShutdownDeathTest.*'

SS=include/utils/StopSignal.hpp
PM=src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp
TFM=src/ndt_core/collection/TopologyAndFlowMonitor.cpp
FILES=("$SS" "$PM" "$TFM")

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
# Declared before anything is touched, every one exactly once. An anchor matching twice would
# mutate a site the mutation is not named for; one matching zero times means the source moved under
# the gate, and "could not be applied" must never be reported as "was caught".
count_exact() {
    python3 - "$1" "$2" <<'PYCOUNT'
import sys, pathlib
sys.stdout.write(str(pathlib.Path(sys.argv[1]).read_text().count(sys.argv[2])))
PYCOUNT
}

declare -a ANCHOR_FILE ANCHOR_TEXT ANCHOR_NAME
add_anchor() { ANCHOR_NAME+=("$1"); ANCHOR_FILE+=("$2"); ANCHOR_TEXT+=("$3"); }

add_anchor "walk-check"     "$PM"  '        if (m_stopSignal.stopRequested())
        {
            fetched.abandoned = true;
            break;
        }

        uint64_t dpid = props.dpid;'
add_anchor "flow-curl"      "$PM"  '        std::string raw = utils::execCommandCancellable(cmd, m_stopSignal).output;'
add_anchor "pm-request"     "$PM"  '    const std::size_t killed = m_stopSignal.request();'
add_anchor "pm-report"      "$PM"  '    utils::reportIfWorkersOutlastTheBound(m_stopSignal, m_stopReportBound, "power manager");'
add_anchor "pm-join"        "$PM"  '    if (m_openflowTablesUpdateThread.joinable())
    {
        m_openflowTablesUpdateThread.join();
    }'
add_anchor "pm-sleep"       "$PM"  '        if (m_stopSignal.waitFor(std::chrono::seconds(10)))
        {
            break;
        }
    }
}

// [Co-developed with claude code -- Adam]
// KNOWN-ISSUES F-6. Split out of openflowTablesUpdateWorker'
add_anchor "of-scope"       "$PM"  '    utils::StopSignal::WorkerScope scope(m_stopSignal, "openflow-tables");'
add_anchor "topo-curl"      "$TFM" '        return classifyEndpointReply(
            utils::execCommandCancellable(buildTopologyFetchCommand(url), m_stopSignal)
                .output);'
add_anchor "topo-request"   "$TFM" '    const std::size_t killed = m_stopSignal.request();'
add_anchor "topo-endchecks" "$TFM" '    const EndpointReply switchesReply = fetchTopologyEndpoint(m_ryuUrl[0]);
    if (m_stopSignal.stopRequested())
    {
        return;
    }
    const EndpointReply hostsReply = fetchTopologyEndpoint(m_ryuUrl[1]);
    if (m_stopSignal.stopRequested())
    {
        return;
    }
    const EndpointReply linksReply = fetchTopologyEndpoint(m_ryuUrl[2]);
    if (m_stopSignal.stopRequested())
    {
        return;
    }'
add_anchor "ss-kill"        "$SS"  '                if (::kill(-pid, SIGKILL) == 0)
                {
                    ++signalled;
                }'
add_anchor "ss-waitfor"     "$SS"  '        m_wake.wait_for(lock, duration, [this] { return m_stopped.load(std::memory_order_acquire); });'
add_anchor "ss-report-log"  "$SS"  '                       "{}: still waiting on {} worker(s) [{}] {:.2f} s after the stop request; "'
add_anchor "ss-report-body" "$SS"  '    const std::vector<std::string> stragglers = signal.waitForWorkers(bound);
    if (stragglers.empty())
    {
        return false;
    }'
add_anchor "ss-comment"     "$SS"  '/// True once request() has run and until reset() does. Cheap: no lock.'

echo "=== anchor uniqueness (exact substring count must be 1) ==="
anchor_ok=1
for i in "${!ANCHOR_NAME[@]}"; do
    n=$(count_exact "${ANCHOR_FILE[$i]}" "${ANCHOR_TEXT[$i]}")
    printf '  %-6s %-16s %-52s x%s\n' \
        "$([[ "$n" == 1 ]] && echo ok || echo REFUSE)" "${ANCHOR_NAME[$i]}" "${ANCHOR_FILE[$i]}" "$n"
    [[ "$n" == 1 ]] || anchor_ok=0
done
[[ "$anchor_ok" == 1 ]] || { echo "🔴 anchors have drifted; this gate cannot render a verdict" >&2; exit 2; }

# --- 3. build + run helpers ---------------------------------------------------------------------
build() { cmake --build "$BUILD_DIR" --target "$TARGET" -j"$JOBS" >/dev/null 2>&1; }

# run_tests <gtest_filter> -> sets STATUS RC OUT FAILED DIED_IN. rc comes from the binary itself and
# is never taken through a pipe, because a pipeline's status belongs to its last stage.
#
# 🔴 A TEST CAN GO RED WITHOUT PRINTING `[  FAILED  ]`. These cases start real threads and the B-5
# cases are death tests; a mutation that aborts the process kills it with no FAILED line, and
# reading "no FAILED line" as "nothing went red" would score real damage as a survivor. DIED_IN is
# the last case gtest announced, empty when it announced none -- which stays a survivor, loudly.
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

# 🔴 A SKIPPED CASE IS NOT A PASSING CASE. Both flow-table cases GTEST_SKIP if :8081 is taken, and
# a skip prints no [  FAILED  ] line -- so a mutation they were meant to catch would be scored a
# survivor for a reason that has nothing to do with the code. Checked once, before the baseline.
skipped_cases() {
    sed -n 's/^\[  SKIPPED \] \([A-Za-z_][A-Za-z0-9_]*\.[A-Za-z0-9_]*\).*/\1/p' <<<"$OUT" \
        | sort -u | tr '\n' ' '
}

is_red() {
    [[ " $FAILED " == *" $1 "* ]] && return 0
    [[ -n "$DIED_IN" && "$DIED_IN" == "$1" ]] && return 0
    return 1
}

# apply <file> <anchor> <new> -- python does the replace, so the anchor matches LITERALLY, newlines
# and all, and the count is re-asserted at the moment of writing. `sed -i` would read the anchor as
# a regex and would not see a multi-line one at all.
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

# widen <label> <file> <anchor> <new> -- a change that must leave EVERY case green. These are what
# give the catches above their meaning.
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
    run_tests "$FILTER_ALL"
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

run_tests "$FILTER_ALL"
case "$STATUS" in
  pass) echo "  ok       baseline green ($(grep -c '^\[       OK \]' <<<"$OUT") cases in $FILTER_ALL)" ;;
  hang) echo "🔴 BASELINE HUNG (>${TEST_TIMEOUT}s). Not a red; the gate cannot proceed." >&2; exit 2 ;;
  *)    echo "🔴 THE BASELINE IS ALREADY RED: $FAILED $DIED_IN" >&2
        echo "   Every 'expect red' below would be meaningless. Stopping." >&2; exit 2 ;;
esac
SKIPPED=$(skipped_cases)
if [[ -n "$SKIPPED" ]]; then
    echo "🔴 CASES WERE SKIPPED, NOT RUN: $SKIPPED" >&2
    echo "   Both flow-table cases skip when :8081 is already bound, and a skipped case cannot" >&2
    echo "   catch anything -- every mutation naming one would be scored a survivor for a reason" >&2
    echo "   that has nothing to do with the code. Free the port and re-run." >&2
    exit 2
fi
echo "  ok       nothing skipped"
echo "  ok       $TARGET sha256 $BIN_SHA_BEFORE"

# ================================================================================================
# 5. the mutations -- direction 1: putting the defect back
# ================================================================================================

# 🔴 WHERE THE BOUND ACTUALLY LIVES, AND WHY THERE IS NO "the walk checks nothing" MUTATION HERE.
#
# The obvious first mutation -- delete the stop check at the top of the per-switch walk, i.e. the
# defect verbatim -- was written, traced, and REMOVED before this gate was ever run, because it
# would have survived and been scored a catch by a reader who did not trace it:
#
#   * the walk has a second check, immediately after the curl, which still ends the round; and
#   * even with BOTH deleted, execCommandCancellable asks stopRequested() before it forks, so every
#     remaining switch costs a syscall rather than 8 s and the round still ends inside the bound.
#
# So the flag checks inside the round are NOT what carries the bound. **The cancellation is.** The
# checks earn their place by setting FlowTableFetch::abandoned -- which is what stops an interrupted
# round from being applied over the cache and deleting every switch it had not reached -- and that
# is a correctness property this suite does not measure. It is W5 below, not a mutation, and
# FIX-KERNEL-STOP-BOUNDED.md §8.3 says so in the same words.
#
# M1. The half that does carry it, for #27: the request already in flight when the stop arrives,
#     back on the executor that cannot be cancelled.
mutate "the flow-table request goes back to the uncancellable executor" \
    "$PM" \
    '        std::string raw = utils::execCommandCancellable(cmd, m_stopSignal).output;' \
    '        std::string raw = utils::execCommand(cmd);' \
    KernelStopIsBoundedTest.AFlowTablePollCaughtMidRoundStopsWithinTheBound

# M3. #76's half of the same thing, in the other class.
mutate "the topology request goes back to the uncancellable executor" \
    "$TFM" \
    '        return classifyEndpointReply(
            utils::execCommandCancellable(buildTopologyFetchCommand(url), m_stopSignal)
                .output);' \
    '        return classifyEndpointReply(utils::execCommand(buildTopologyFetchCommand(url)));' \
    KernelStopIsBoundedTest.ATopologyPollBlockedInItsHttpCallReturnsWithinTheBound

# M4. The signal still exists, the workers still consult it, and nothing kills the child. This is
#     the mutation that proves the cancellation -- not the flag -- is what carries the bound.
mutate "request() no longer kills the in-flight child" \
    "$SS" \
    '                if (::kill(-pid, SIGKILL) == 0)
                {
                    ++signalled;
                }' \
    '                (void)pid;' \
    KernelStopIsBoundedTest.AFlowTablePollCaughtMidRoundStopsWithinTheBound \
    KernelStopIsBoundedTest.ATopologyPollBlockedInItsHttpCallReturnsWithinTheBound

# M5. The interruptible sleep made uninterruptible: waitFor sleeps out its whole duration. The
#     worker's 10 s nap then sets the shutdown latency, which is the pre-fix idiom's cost.
mutate "waitFor ignores the stop and sleeps out its full duration" \
    "$SS" \
    '        m_wake.wait_for(lock, duration, [this] { return m_stopped.load(std::memory_order_acquire); });' \
    '        m_wake.wait_for(lock, duration, [] { return false; });' \
    KernelStopIsBoundedTest.AFlowTablePollCaughtMidRoundStopsWithinTheBound

# M6. stop() sets m_running and joins, exactly as trunk did -- the request that reaches a worker
#     inside a round is gone. Both classes, one mutation each, because they are separate defects.
mutate "the power manager's stop() no longer requests the stop" \
    "$PM" \
    '    const std::size_t killed = m_stopSignal.request();' \
    '    const std::size_t killed = 0;' \
    KernelStopIsBoundedTest.AFlowTablePollCaughtMidRoundStopsWithinTheBound

mutate "the monitor's stop() no longer requests the stop" \
    "$TFM" \
    '    const std::size_t killed = m_stopSignal.request();' \
    '    const std::size_t killed = 0;' \
    KernelStopIsBoundedTest.ATopologyPollBlockedInItsHttpCallReturnsWithinTheBound

# M7. The report silenced. A stop that has gone wrong and says nothing is indistinguishable from a
#     hang, which is the whole reason the line exists.
mutate "the over-bound report returns without saying anything" \
    "$SS" \
    '    const std::vector<std::string> stragglers = signal.waitForWorkers(bound);
    if (stragglers.empty())
    {
        return false;
    }' \
    '    const std::vector<std::string> stragglers = signal.waitForWorkers(bound);
    if (true)
    {
        return false;
    }' \
    KernelStopIsBoundedTest.TheOverBoundReportNamesTheWorkerAndTheSubsystem \
    KernelStopIsBoundedTest.TheMonitorsOverBoundReportNamesItsOwnWorker

# ================================================================================================
# 6. direction 2: buying the bound by dropping the join
#
# 🔴 THE ONE THAT MATTERS. Deleting the join makes stop() return in microseconds and turns every
# timing assertion above green. It is also KNOWN-ISSUES B-5 restored: a joinable std::thread
# destroyed is std::terminate, SIGABRT, exit 134 -- reproduced 7/7 on the real kernel. Only
# test_PowerManagerShutdown.cpp's death tests can see it, which is why this gate runs them.
# ================================================================================================
mutate "the openflow join is deleted -- a 'fast' stop that aborts the process" \
    "$PM" \
    '    if (m_openflowTablesUpdateThread.joinable())
    {
        m_openflowTablesUpdateThread.join();
    }' \
    '    // join removed' \
    PowerManagerShutdownDeathTest.AStoppedManagerIsDestroyedWithoutAborting \
    PowerManagerShutdownDeathTest.AManagerNeverStoppedIsDestroyedWithoutAborting

# ================================================================================================
# 7. the widenings -- these MUST stay green
# ================================================================================================

# W1. A comment. The classic control.
widen "a comment is reworded" \
    "$SS" \
    '/// True once request() has run and until reset() does. Cheap: no lock.' \
    '/// True from request() until reset(). No lock taken.'

# W2. The report's wording. The tests assert the worker name and the subsystem name -- the two
#     identifiers an operator acts on -- and nothing about the sentence carrying them.
widen "the over-bound report is reworded" \
    "$SS" \
    '                       "{}: still waiting on {} worker(s) [{}] {:.2f} s after the stop request; "' \
    '                       "{}: {} worker(s) [{}] have not returned {:.2f} s after the stop; "'

# W3. A stop check written as an equivalent expression. Proves the timing assertions are about
#     elapsed time and not about the shape of the branch that produced it.
widen "the walk's stop check is written as an equivalent expression" \
    "$PM" \
    '        if (m_stopSignal.stopRequested())
        {
            fetched.abandoned = true;
            break;
        }

        uint64_t dpid = props.dpid;' \
    '        if (bool(m_stopSignal.stopRequested()) != false)
        {
            fetched.abandoned = true;
            break;
        }

        uint64_t dpid = props.dpid;'

# W5. 🔴 The walk's top-of-loop stop check REMOVED -- the mutation this gate deliberately does not
#     claim. See the long note above section 5: the second check still ends the round, and the
#     pre-fork check in execCommandCancellable would end it even without either. Its real job is
#     setting FlowTableFetch::abandoned so an interrupted round is not applied over the cache, and
#     THAT is not measured here. Listed as a control so the tally cannot be misread as covering it.
widen "the walk's top-of-loop stop check is removed (redundant for timing -- see the note above)" \
    "$PM" \
    '        if (m_stopSignal.stopRequested())
        {
            fetched.abandoned = true;
            break;
        }

        uint64_t dpid = props.dpid;' \
    '        uint64_t dpid = props.dpid;'

# W4. 🔴 The three between-endpoint checks REMOVED, and this is a widening rather than a mutation
#     on purpose -- see the header. execCommandCancellable asks stopRequested() before it forks, so
#     the two remaining endpoints cost a syscall each after a stop and the round still ends inside
#     the bound. The checks are defence in depth against a future edit to the executor; this suite
#     does not defend them, and saying so here is more useful than a catch that is not real.
widen "the between-endpoint stop checks are removed (redundant today -- see the header)" \
    "$TFM" \
    '    const EndpointReply switchesReply = fetchTopologyEndpoint(m_ryuUrl[0]);
    if (m_stopSignal.stopRequested())
    {
        return;
    }
    const EndpointReply hostsReply = fetchTopologyEndpoint(m_ryuUrl[1]);
    if (m_stopSignal.stopRequested())
    {
        return;
    }
    const EndpointReply linksReply = fetchTopologyEndpoint(m_ryuUrl[2]);
    if (m_stopSignal.stopRequested())
    {
        return;
    }' \
    '    const EndpointReply switchesReply = fetchTopologyEndpoint(m_ryuUrl[0]);
    const EndpointReply hostsReply = fetchTopologyEndpoint(m_ryuUrl[1]);
    const EndpointReply linksReply = fetchTopologyEndpoint(m_ryuUrl[2]);'

# ================================================================================================
# 8. restore and verdict
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
[[ "$ok" == 1 ]] && echo "  all ${#FILES[@]} files byte-identical to the pre-run snapshot"
if [[ "$REBUILD_OK" == 1 ]]; then
    echo "  rebuilt from the restored tree"
else
    echo "  🔴 THE RESTORED TREE DOES NOT BUILD -- the binary on disk is whatever the last"
    echo "     mutation left. Do not run another gate against it."
    ok=0
fi
run_tests "$FILTER_ALL"
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
echo "  FINDINGS #27/#76 gate: neither defect can be put back by any of seven routes, buying the"
echo "  bound by deleting the join is caught by B-5's death tests, and five behaviour-preserving"
echo "  edits -- two of which document redundancies this suite does NOT defend -- were left alone."
exit 0
