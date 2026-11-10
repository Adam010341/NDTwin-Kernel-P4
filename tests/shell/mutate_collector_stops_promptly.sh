#!/usr/bin/env bash
#
# Mutation gate: the sFlow collector's stop() is prompt, and its queue, sleeps, fetch and drain
# cannot hang or abort a shutdown (the first OVS port lookup's `sudo ovs-vsctl`, which waits for
# ovsdb, is outside this; see the test file's header).
#
# [Co-developed with claude code -- Adam]
#
# Covers tests/test_CollectorStopsPromptly.cpp.
#
# WHAT THE DEFECTS WERE
#   (1) A lost wakeup: the worker queues were notified without their mutex after the stop flag was
#       stored, so a worker between its check of the flag and its wait could sleep for good, and
#       run()'s join of the pool -- then stop(), then the kernel -- with it.
#   (2) Waits nothing could end: the destination-path fetch (`curl --max-time 10`) ran on the plain
#       executor, and the periodic threads slept in 1 s slices or for a random 0.5-2 s.
#   (3) The shutdown drain called the packet handler outside the worker loop's try/catch.
#
# 🔴 TWO DIRECTIONS
#   1. PUTTING A DEFECT BACK must be caught (M1-M8): the notify without the lock, the fetch on the
#      uncancellable executor, the drain without its catch, and each of the five sleeps made
#      uninterruptible again.
#   2. BUYING THE BOUND BY DROPPING A JOIN must also be caught (M9): a stop() that skips the refresh
#      thread's join returns fast and then destroys a joinable std::thread, which is std::terminate.
#   3. Two that only a second start() or a receive loop failing on its own can show (M10, M11):
#      start() not re-arming the stop signal, and that loop's exit not requesting it.
#
# 🔴 FOUR CHANGES MUST **NOT** BE CAUGHT (W1-W4): a comment, the cancel log line's wording, the
# notify moved inside the lock -- a different correct fix -- and W4, stop() not requesting the stop
# itself. W4 is redundant today, not harmless by luck: run() requests it on its way out, which it
# reaches within one 100 ms poll of stop() clearing m_running, so the bound still holds. stop()'s own
# request saves up to that 100 ms and does not depend on run() being alive; this suite does not
# defend that, and listing it here says so. A suite that reddens on W1-W3 is pinning source text.
#
# 🔴 A MUTANT THAT DOES NOT COMPILE IS A SURVIVOR, and so is an anchor that has moved and a run that
# hangs. The tests use ephemeral ports only and start the collector's threads in-process; nothing
# here starts Mininet, bmv2 or OVS, and nothing is killed by name -- `timeout` owns the only child.
#
# 🔴 GUARDS ITS OWN BASELINE: every file it can touch is snapshotted first, an EXIT trap restores
# them, and the run ends by asserting byte identity and that the test binary's sha is the one the
# baseline built. A restored file is `touch`ed only if it actually changed.
#
# 🔴 BUILD UNDER THE GUARD on a machine whose memory is shared with other work:
#   tools/build_guard/guarded_build.sh ./tests/shell/mutate_collector_stops_promptly.sh
#
# Usage:  BUILD_DIR=build JOBS=2 TEST_TIMEOUT=300 bash tests/shell/mutate_collector_stops_promptly.sh
#
# Exit: 0 every mutation caught by the test it names, every widening survived, tree restored
#       1 at least one mutation survived, or a widening was caught
#       2 no verdict is possible: baseline red or not building, anchor drift, hang, failed restore
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

BUILD_DIR="${BUILD_DIR:-build}"
JOBS="${JOBS:-2}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
FILTER_ALL='CollectorStopsPromptlyTest.*'
T=CollectorStopsPromptlyTest

QUEUE=include/ndt_core/collection/SPSCQueue.hpp
COLL=src/ndt_core/collection/FlowLinkUsageCollector.cpp
FILES=("$QUEUE" "$COLL")

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

add_anchor "notify-lock"    "$QUEUE" '        {
            std::lock_guard<std::mutex> lk(m_mu);
        }
        m_cv_not_empty.notify_all();'
add_anchor "drain-catch"    "$QUEUE" '    while (queue.pop(item, running))
    {
        handleReporting(item, handle, report);
    }'
add_anchor "notify-comment" "$QUEUE" '    /// Wakes every waiter so it re-reads the stop flag. Call it after storing that flag.'
add_anchor "fetch"          "$COLL"  '        const std::string output = utils::execCommandCancellable(cmd, m_stopSignal).output;'
add_anchor "request"        "$COLL"  '    const std::size_t killed = m_stopSignal.request();'
add_anchor "cancel-log"     "$COLL"  '                           "Collector: stop cancelled {} in-flight destination-path request(s)",'
add_anchor "refresh-sleep"  "$COLL"  '        if (m_stopSignal.waitFor(interval) || !m_running.load())'
add_anchor "rates-sleep"    "$COLL"  '        if (m_stopSignal.waitFor(chrono::seconds(1)))'
add_anchor "random-sleep"   "$COLL"  '        if (m_stopSignal.waitFor(chrono::milliseconds(waitTime)))'
add_anchor "purge-sleep"    "$COLL"  '        if (m_stopSignal.waitFor(chrono::milliseconds(1000)))'
add_anchor "path-sleep"     "$COLL"  '        if (m_stopSignal.waitFor(kFlowPathRecomputeInterval))'
add_anchor "restart-reset"  "$COLL"  '    m_stopSignal.reset();'
add_anchor "run-request"    "$COLL"  '    m_stopSignal.request();
    stopAndJoinWorkers();'
add_anchor "refresh-join"   "$COLL"  '    if (m_destinationPathRefreshThread.joinable())
    {
        m_destinationPathRefreshThread.join();
    }'

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

# run_tests <gtest_filter> -> sets STATUS RC OUT FAILED DIED_IN. A mutant that aborts the process
# prints no `[  FAILED  ]` line; DIED_IN is then the last case gtest announced.
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

# mutate <label> <file> <anchor> <new> <expect-red...> -- every named test must be red.
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
        [[ -n "$FAILED" ]] && printf '     (something else went red: %s)\n' "$FAILED"
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
    run_tests "$FILTER_ALL"
    if [[ "$STATUS" == pass ]]; then
        echo "  ✅ survived -- behaviour unchanged, so the catches above are about behaviour"
    else
        echo "  🔴 CAUGHT: tests went red on a behaviour-preserving change: $FAILED $DIED_IN"
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
  *)    echo "🔴 THE BASELINE IS ALREADY RED: $FAILED $DIED_IN" >&2; exit 2 ;;
esac
SKIPPED=$(skipped_cases)
if [[ -n "$SKIPPED" ]]; then
    echo "🔴 CASES WERE SKIPPED, NOT RUN: $SKIPPED" >&2; exit 2
fi
echo "  ok       nothing skipped"
echo "  ok       $TARGET sha256 $BIN_SHA_BEFORE"

# ================================================================================================
# 5. direction 1: putting a defect back
# ================================================================================================
mutate "the queue is notified without its mutex (the lost wakeup)" \
    "$QUEUE" \
    '        {
            std::lock_guard<std::mutex> lk(m_mu);
        }
        m_cv_not_empty.notify_all();' \
    '        m_cv_not_empty.notify_all();' \
    "$T.AWorkerBetweenItsCheckAndItsWaitIsStillWokenByTheStop"

mutate "the destination-path fetch goes back to the uncancellable executor" \
    "$COLL" \
    '        const std::string output = utils::execCommandCancellable(cmd, m_stopSignal).output;' \
    '        const std::string output = utils::execCommand(cmd);' \
    "$T.ADestinationPathFetchInFlightIsCancelledByStop"

mutate "the drain calls the handler outside the catch again" \
    "$QUEUE" \
    '    while (queue.pop(item, running))
    {
        handleReporting(item, handle, report);
    }' \
    '    while (queue.pop(item, running))
    {
        handle(item);
    }' \
    "$T.AnItemThatThrowsDuringTheDrainIsReportedAndTheRestAreHandled"

# The five sleeps, each put back on a plain sleep_for. The comma expression keeps the `if`, so the
# only change is that the wait cannot be ended early.
mutate "the destination-path refresh sleeps out its interval" \
    "$COLL" \
    '        if (m_stopSignal.waitFor(interval) || !m_running.load())' \
    '        if ((std::this_thread::sleep_for(interval), false) || !m_running.load())' \
    "$T.AnIdleCollectorStopsWithinTheBound"

mutate "the rate loop sleeps out its second" \
    "$COLL" \
    '        if (m_stopSignal.waitFor(chrono::seconds(1)))' \
    '        if ((this_thread::sleep_for(chrono::seconds(1)), false))' \
    "$T.AnIdleCollectorStopsWithinTheBound"

# 0.5-2 s, drawn at random: one idle stop can land in its last 0.5 s and pass, twenty in a row
# cannot, so the repeated case is the one named.
mutate "the random-rate loop sleeps out its 0.5-2 s" \
    "$COLL" \
    '        if (m_stopSignal.waitFor(chrono::milliseconds(waitTime)))' \
    '        if ((this_thread::sleep_for(chrono::milliseconds(waitTime)), false))' \
    "$T.RepeatedStartAndStopNeverHangsAndStaysWithinTheBound"

mutate "the idle-flow purge sleeps out its second" \
    "$COLL" \
    '        if (m_stopSignal.waitFor(chrono::milliseconds(1000)))' \
    '        if ((this_thread::sleep_for(chrono::milliseconds(1000)), false))' \
    "$T.AnIdleCollectorStopsWithinTheBound"

mutate "the flow-path loop sleeps out its interval" \
    "$COLL" \
    '        if (m_stopSignal.waitFor(kFlowPathRecomputeInterval))' \
    '        if ((std::this_thread::sleep_for(kFlowPathRecomputeInterval), false))' \
    "$T.AnIdleCollectorStopsWithinTheBound"

# ================================================================================================
# 6. direction 2: a fast stop bought by dropping a join -- std::terminate when the thread dies
# ================================================================================================
mutate "the refresh thread's join is deleted -- a 'fast' stop that aborts the process" \
    "$COLL" \
    '    if (m_destinationPathRefreshThread.joinable())
    {
        m_destinationPathRefreshThread.join();
    }' \
    '    // join removed' \
    "$T.AnIdleCollectorStopsWithinTheBound"

# ================================================================================================
# 6b. two more that only a restart or a receive loop failing on its own can show (M10, M11)
# [Co-developed with claude code -- Adam]
# ================================================================================================
mutate "start() no longer re-arms the stop signal (a restarted collector quits at once)" \
    "$COLL" \
    '    m_stopSignal.reset();' \
    '    // reset removed' \
    "$T.AStoppedCollectorStartedAgainWorksAndStopsWithinTheBound"

mutate "a receive loop that fails on its own no longer requests the stop" \
    "$COLL" \
    '    m_stopSignal.request();
    stopAndJoinWorkers();' \
    '    stopAndJoinWorkers();' \
    "$T.AReceiveLoopThatFailsOnItsOwnTakesThePeriodicThreadsWithIt"

# ================================================================================================
# 7. widenings -- these MUST stay green
# ================================================================================================
widen "a comment is reworded" \
    "$QUEUE" \
    '    /// Wakes every waiter so it re-reads the stop flag. Call it after storing that flag.' \
    '    /// Wakes all waiters; they re-read the stop flag. Store the flag first.'

widen "the cancel log line is reworded" \
    "$COLL" \
    '                           "Collector: stop cancelled {} in-flight destination-path request(s)",' \
    '                           "Collector: killed {} destination-path fetch(es) at stop",'

widen "the notify moves inside the lock (another correct fix)" \
    "$QUEUE" \
    '        {
            std::lock_guard<std::mutex> lk(m_mu);
        }
        m_cv_not_empty.notify_all();' \
    '        std::lock_guard<std::mutex> lk(m_mu);
        m_cv_not_empty.notify_all();'

# W4. Redundant today -- see the header: run() requests the stop within one poll of stop().
widen "stop() itself no longer requests the stop (run()'s exit still does)" \
    "$COLL" \
    '    const std::size_t killed = m_stopSignal.request();' \
    '    const std::size_t killed = 0;'

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
    echo "  🔴 THE RESTORED TREE DOES NOT BUILD"; ok=0
fi
run_tests "$FILTER_ALL"
if [[ "$STATUS" != pass ]]; then
    echo "  🔴 the suite is red after restore -- a mutant object is still linked in: $FAILED"; ok=0
else
    echo "  suite green again after restore"
fi
BIN_SHA_AFTER=$(sha256sum "$BIN" 2>/dev/null | cut -c1-16)
if [[ "$BIN_SHA_AFTER" != "$BIN_SHA_BEFORE" ]]; then
    echo "  🔴 test binary sha changed: $BIN_SHA_AFTER (was $BIN_SHA_BEFORE)"; ok=0
else
    echo "  test binary sha unchanged: $BIN_SHA_AFTER"
fi

printf '\n=== verdict ===\n'
printf '  %d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"
printf '  %d widenings, %d wrongly caught\n' "$WIDENINGS" "$WIDENINGS_CAUGHT"

if [[ "$ok" != 1 ]]; then exit 2; fi
if (( SURVIVORS > 0 || WIDENINGS_CAUGHT > 0 )); then exit 1; fi
echo "  Collector stop gate: none of the defects can be put back by any of ten routes,"
echo "  a stop made fast by deleting a join is caught, and four behaviour-preserving edits were left alone."
exit 0
