#!/usr/bin/env bash
#
# Mutation gate for FINDINGS #38 -- a connection that was refused must not be reported as a wait
# that ran out, and a wait that really did run out must go on saying so.
#
# [Co-developed with claude code -- Adam]
#
# Covers tests/test_RefusedIsNotTimeout.cpp.
#
# WHAT THE DEFECT WAS
#   SimulationRequestManager::requestSimulation branched on `curl.httpStatus == 0` -- which is
#   what curl's %{http_code} reports ("000") for EVERY failure that produced no HTTP response --
#   and then hard-coded one cause:
#       "no response from the simulator server at <url> within 30s"
#   Round 2 measured that sentence coming back in 6.0-9.0 ms, 5 times out of 5, with nothing
#   listening on the port; the kernel's own log timed the same 502 at 9.9 ms. curl's exit code
#   (7 could-not-connect vs 28 timed-out) was already in CommandOutcome::status and was discarded.
#
# 🔴 TWO DIRECTIONS, AND THE SECOND ONE IS WHY THIS GATE EXISTS AT ALL
#   1. PUTTING THE DEFECT BACK must be caught             (M1, M2, M3, M6, M7)
#      -- by the original string, by discarding curl's exit code again, by routing the refusal
#         back into the timeout branch, by collapsing a third cause into "refused", and by
#         quoting the deadline instead of the measurement.
#   2. RELAXING PAST THE FIX must ALSO be caught          (M4, M5)
#      -- deleting the timeout wording everywhere satisfies "a refusal must not say timeout" and
#         is a worse message than the defect: the one request that really does wait out the
#         deadline stops saying so. M5 is the mirror: everything becomes "refused".
#
# 🔴 THREE MUTATIONS MUST **NOT** BE CAUGHT (W1, W2, W3). A suite that reddens on these is pinning
# source text rather than the classification, and every catch above would be worth nothing:
#   W1  a comment                     -- the classic control
#   W2  the REFUSAL reworded, same classification -- the deliverable this gate was asked for: the
#                                        next person must be able to improve the sentence without
#                                        editing a test
#   W3  the TIMEOUT reworded, same classification -- the other half, so the pinning is symmetric
#
# 🔴 A MUTANT THAT DOES NOT COMPILE IS A SURVIVOR, not a skip: the suite never ran, so it proves
# nothing. Same for an anchor that has moved, and for a run that hangs.
#
# 🔴 GUARDS ITS OWN BASELINE. The one file it can touch is snapshotted with `cp -p`, an EXIT trap
# restores it however this exits including Ctrl-C, and the run ends by asserting byte identity
# against the snapshot AND that the test binary's sha is the one the baseline built. `cp -p`
# restores the ORIGINAL mtime -- older than the object built from the mutant -- so a restored file
# is also `touch`ed, but only when it actually changed.
#
# 🔴 NEVER KILLS ANYTHING BY NAME. No pkill, no pgrep: `timeout` owns the only child. The tests
# bind loopback sockets on kernel-chosen ports and close them; nothing here starts Mininet, bmv2,
# OVS, or a server on a fixed port. Each hang case costs the 2 s deadline the tests construct.
#
# 🔴 BUILD UNDER THE GUARD. This laptop's oomd took the user's own application down on 2026-09-02.
#   tools/build_guard/guarded_build.sh ./tests/shell/mutate_refused_is_not_timeout.sh
#
# Usage:  tools/build_guard/guarded_build.sh ./tests/shell/mutate_refused_is_not_timeout.sh
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
FILTER='RefusedIsNotTimeoutTest.*'

SRM=src/ndt_core/application_management/SimulationRequestManager.cpp
FILES=("$SRM")

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
command -v curl    >/dev/null || { echo "🔴 curl is required -- it is the subject" >&2; exit 2; }
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
#
# Note on the two measurement anchors: this file runs curl TWICE, and the second call site is the
# same four lines at a deeper indent. The anchors therefore carry the execArgv line above them,
# which makes the leading indentation load-bearing and each of them unique.
count_exact() {
    python3 - "$1" "$2" <<'PYCOUNT'
import sys, pathlib
sys.stdout.write(str(pathlib.Path(sys.argv[1]).read_text().count(sys.argv[2])))
PYCOUNT
}

declare -a ANCHOR_FILE ANCHOR_TEXT ANCHOR_NAME
add_anchor() { ANCHOR_NAME+=("$1"); ANCHOR_FILE+=("$2"); ANCHOR_TEXT+=("$3"); }

add_anchor "classify-call"  "$SRM" '        dispatch.failureReason = describeCurlNoReply(outcome.status,
                                                     elapsedSeconds,
                                                     m_requestTimeoutSeconds,
                                                     SIM_SERVER_URL);'
add_anchor "measurement"    "$SRM" '    const auto startedAt = std::chrono::steady_clock::now();
    const utils::CommandOutcome outcome = utils::execArgv(argv);
    const double elapsedSeconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - startedAt).count();'
add_anchor "curl-exit-7"    "$SRM" '    case 7:
        return "connection refused after " + took + ": nothing accepted a connection at " + url +
               " (curl exit 7)";'
add_anchor "curl-exit-28"   "$SRM" '    case 28:
        return "timed out after " + took + ": no reply from " + url + " within the " +
               std::to_string(deadlineSeconds) + "s deadline (curl exit 28)";'
add_anchor "curl-exit-56"   "$SRM" '    case 56:
        return "connection reset after " + took + " by " + url + " (curl exit 56)";'
add_anchor "finding-comment" "$SRM" '        // FINDINGS #38. This read, for every cause alike:'

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
# 🔴 A TEST CAN GO RED WITHOUT PRINTING `[  FAILED  ]`. These cases open sockets and start a
# thread; a mutation that made one of them abort would kill the process with no FAILED line, and
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
    run_tests "$FILTER"
    if [[ "$STATUS" == pass ]]; then
        echo "  ✅ survived -- behaviour unchanged, so the catches above are about behaviour"
    else
        echo "  🔴 CAUGHT: tests went red on a behaviour-preserving change: $FAILED $DIED_IN"
        echo "     This gate cannot tell a rewording from a reclassification."
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
# 5. the mutations -- direction 1: putting the defect back
# ================================================================================================

# M1. THE DEFECT VERBATIM. The sentence Round 2 measured coming back in 6 ms, restored exactly:
#     one hard-coded cause for the union of every cause, and the deadline where a measurement
#     should be. Note that AHangIsStillDescribedAsATimeout goes red on this too -- the old string
#     never said "timed out" either; it said "within Ns", which reads as a claim about the wait
#     and is not one.
#
#     The `(void)elapsedSeconds;` is not decoration. This tree builds with -Wall -Wextra -Werror,
#     and the shipped message uses no measurement, so without that line the mutant fails to compile
#     -- and a mutant that does not compile is scored a SURVIVOR here, because the suite never ran.
#     The cast keeps the mutation about the MESSAGE, which is what the finding is about; the
#     measurement having become dead code is an artefact of mutating one site out of two.
mutate "the shipped message: 'no response ... within Ns' for every cause" \
    "$SRM" \
    '        dispatch.failureReason = describeCurlNoReply(outcome.status,
                                                     elapsedSeconds,
                                                     m_requestTimeoutSeconds,
                                                     SIM_SERVER_URL);' \
    '        (void)elapsedSeconds;
        dispatch.failureReason = "no response from the simulator server at " + SIM_SERVER_URL +
                                 " within " + std::to_string(m_requestTimeoutSeconds) + "s";' \
    RefusedIsNotTimeoutTest.ARefusalIsNotDescribedAsATimeout \
    RefusedIsNotTimeoutTest.AHangIsStillDescribedAsATimeout \
    RefusedIsNotTimeoutTest.TheTwoFailuresDoNotProduceTheSameSentence \
    RefusedIsNotTimeoutTest.TheRefusalCarriesTheDurationThatWasActuallyMeasured

# M2. THE MECHANISM, not the wording: curl's exit status is discarded again. Passing a constant
#     leaves the classifier in place and every branch of it reachable in principle, and still
#     renders one diagnosis for all causes -- which is what "the exit code sat unread" means.
#
#     Note which test is NOT named here. TheTwoFailuresDoNotProduceTheSameSentence stays green
#     under this mutation, because the measured duration is still in the sentence and the two
#     durations differ. That is worth stating rather than hiding: that case pins "the two do not
#     collapse into one string", and once a real measurement is in the string they cannot, whatever
#     the diagnosis says. The case that notices a lost diagnosis is the one that asks for the word.
mutate "curl's exit status is discarded again (a constant is classified instead)" \
    "$SRM" \
    '        dispatch.failureReason = describeCurlNoReply(outcome.status,' \
    '        dispatch.failureReason = describeCurlNoReply(0,' \
    RefusedIsNotTimeoutTest.ARefusalIsNotDescribedAsATimeout \
    RefusedIsNotTimeoutTest.AHangIsStillDescribedAsATimeout

# M3. The refusal is routed back into the timeout branch -- the same collapse, one case label
#     later. This is the shape a careless merge produces, and it still looks like a classifier.
mutate "curl exit 7 renders the timeout sentence" \
    "$SRM" \
    '    case 7:
        return "connection refused after " + took + ": nothing accepted a connection at " + url +
               " (curl exit 7)";' \
    '    case 7:
        return "timed out after " + took + ": no reply from " + url + " within the " +
               std::to_string(deadlineSeconds) + "s deadline (curl exit 28)";' \
    RefusedIsNotTimeoutTest.ARefusalIsNotDescribedAsATimeout

# ================================================================================================
#    direction 2: relaxing past the fix. 🔴 These are the reason this gate is not just #38's.
# ================================================================================================

# M4. THE OVER-CORRECTION. Reading "a refusal must not be called a timeout" as "stop saying
#     timeout" satisfies every assertion in direction 1 and is worse than the defect: the one
#     request that really did sit for the whole deadline stops saying so, and an operator loses
#     the only message that would have sent them to look at a slow simulator.
mutate "the timeout wording is removed everywhere" \
    "$SRM" \
    '    case 28:
        return "timed out after " + took + ": no reply from " + url + " within the " +
               std::to_string(deadlineSeconds) + "s deadline (curl exit 28)";' \
    '    case 28:
        return "no reply from " + url + " after " + took + " (curl exit 28)";' \
    RefusedIsNotTimeoutTest.AHangIsStillDescribedAsATimeout

# M5. The mirror over-correction: everything becomes a refusal. Direction 1 cannot see this --
#     "the refusal does not say timeout" is greener than ever -- and it is the same collapse the
#     finding is about, pointing the other way.
mutate "a genuine timeout is reported as a refusal" \
    "$SRM" \
    '    case 28:
        return "timed out after " + took + ": no reply from " + url + " within the " +
               std::to_string(deadlineSeconds) + "s deadline (curl exit 28)";' \
    '    case 28:
        return "connection refused after " + took + ": nothing accepted a connection at " + url +
               " (curl exit 28)";' \
    RefusedIsNotTimeoutTest.AHangIsStillDescribedAsATimeout

# M6. A THIRD CAUSE folded into "refused". A peer that accepted the connection and then reset it
#     is not a peer that refused one, and the operator action differs again (the simulator is up
#     and dying, versus not running). Deterministic here: tearing down a listening socket with a
#     connection still in its accept queue gives curl exit 56, five runs out of five.
mutate "a reset connection is reported as a refusal" \
    "$SRM" \
    '    case 56:
        return "connection reset after " + took + " by " + url + " (curl exit 56)";' \
    '    case 56:
        return "connection refused after " + took + ": nothing accepted a connection at " + url +
               " (curl exit 56)";' \
    RefusedIsNotTimeoutTest.ADroppedConnectionIsNeitherOfTheTwo

# M7. The number goes back to being the deadline rather than the measurement. The classification
#     is untouched and correct -- the message says "connection refused" -- and it still quotes a
#     duration nobody observed, which is the half of the finding that is about the number.
mutate "the message quotes the deadline instead of the measured duration" \
    "$SRM" \
    '    const auto startedAt = std::chrono::steady_clock::now();
    const utils::CommandOutcome outcome = utils::execArgv(argv);
    const double elapsedSeconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - startedAt).count();' \
    '    const utils::CommandOutcome outcome = utils::execArgv(argv);
    const double elapsedSeconds = static_cast<double>(m_requestTimeoutSeconds);' \
    RefusedIsNotTimeoutTest.TheRefusalCarriesTheDurationThatWasActuallyMeasured

# ================================================================================================
# 6. the widenings -- these MUST survive
# ================================================================================================

# W1. A comment. If anything reddens here, every catch above is measuring "a file was edited and
#     rebuilt" rather than "the classification changed".
widen "a comment, nothing else" \
    "$SRM" \
    '        // FINDINGS #38. This read, for every cause alike:' \
    '        // FINDINGS #38. Before this, for every cause alike, it read:'

# W2. THE REFUSAL REWORDED, classification intact. This is the control the whole gate is for: the
#     tests must be pinning which of refused/reset/timed-out the message commits to, not the
#     sentence it commits to it in. A red here means the next person to improve the wording has to
#     edit a test to do it, and message tests that behave like that stop being maintained.
widen "the refusal is reworded, same classification" \
    "$SRM" \
    '    case 7:
        return "connection refused after " + took + ": nothing accepted a connection at " + url +
               " (curl exit 7)";' \
    '    case 7:
        return "connection refused after " + took + " -- nothing is listening at " + url +
               " (curl exit 7)";'

# W3. The timeout reworded, classification intact. The other half, so the pinning is symmetric:
#     a suite that allows the refusal to be reworded but not the timeout is still pinning text,
#     just on one side.
widen "the timeout is reworded, same classification" \
    "$SRM" \
    '    case 28:
        return "timed out after " + took + ": no reply from " + url + " within the " +
               std::to_string(deadlineSeconds) + "s deadline (curl exit 28)";' \
    '    case 28:
        return "timed out after " + took + " -- " + url +
               " accepted the connection but sent nothing back before the " +
               std::to_string(deadlineSeconds) + "s deadline (curl exit 28)";'

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
echo "  FINDINGS #38 gate: the refusal cannot be called a timeout again by any of five routes,"
echo "  dropping the timeout wording or calling everything a refusal is caught too, the quoted"
echo "  duration must be one this process measured, and three behaviour-preserving edits --"
echo "  including a rewording of each message -- were left alone."
exit 0
