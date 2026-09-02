#!/usr/bin/env bash
#
# Mutation gate for tests/test_FlowLiveness.cpp and the four liveness cases appended to
# tests/test_HttpSessionRouting.cpp.  KNOWN-ISSUES B-x.
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration.  This applies each mutation the design
# is supposed to be protected against, rebuilds, and records WHICH named test went red -- never
# merely that something did.  Two of this project's tests have previously turned red on a mutation
# aimed at a different behaviour, so "the gate works" is established only by the identity of the
# failure.
#
# 🔴 ONE MUTATION IS EXPECTED TO KILL THE TEST BINARY BY SIGNAL, NOT BY ASSERTION.
# `pathIs -> starts_with` restores the pre-patch top-k route, so /ndt/get_detected_top_k_flow_dataZZZ
# reaches its handler and dereferences the null collector that HttpSessionTestPeer supplies.  A
# segfault is a legitimate red here -- the request was served when it should have been refused --
# but it looks nothing like a failed EXPECT: gtest prints no FAILED line, because the process is
# gone.  Every run therefore goes through `timeout`, and the exit status is classified three ways:
#
#     rc == 124            the binary HUNG.  Never a pass, never a catch.  Something is wrong with
#                          the gate itself and the run stops.
#     rc  > 128            the binary died of signal rc-128.  RED, reason=crash, and the test that
#                          was red is the last one gtest printed `[ RUN      ]` for.
#     rc != 0 otherwise    ordinary assertion failures; the names come from the FAILED lines.
#
# Conflating those three is the whole reason this is written out: a crash reported as a hang would
# be retried forever, and a crash reported as "nothing went red" would mark a real catch as a
# survivor.
#
# 🔴 Guards its own baseline.  Every file it touches is snapshotted with `cp -p` before the first
# mutation, an EXIT trap restores on any exit including Ctrl-C, and the run ends by asserting
# byte-identity against the snapshot.  Baseline is the WORKING TREE, not HEAD, so this runs against
# an uncommitted fix.
#
# 🔴 Never kills anything by name.  No pkill, no pgrep: `timeout` owns the only child.
#
# Usage:  tests/shell/mutate_bx_flow_liveness.sh
#   BUILD_DIR=build     configured build directory (ninja)
#   JOBS=4              build parallelism
#   TEST_TIMEOUT=300    seconds allowed per test-binary run
#
# Exit: 0 all mutations caught and the control survived
#       1 at least one mutation survived
#       2 the gate cannot render a verdict (baseline red, anchor drift, hang, failed restore,
#         or the comment-only control going red -- which would mean this gate measures "the file
#         changed" rather than "the behaviour changed")
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

BUILD_DIR="${BUILD_DIR:-build}"
JOBS="${JOBS:-4}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"

SFLOW=include/common_types/SFlowType.hpp
FLUCH=include/ndt_core/collection/FlowLinkUsageCollector.hpp
HTTPH=include/ndt_core/http/HttpSession.hpp
UTILS=include/utils/Utils.hpp
FILES=("$SFLOW" "$FLUCH" "$HTTPH" "$UTILS")

# --- 0. self-check ------------------------------------------------------------------------------
# Syntax-checking the script from inside the script is circular, and it is here anyway: the gate is
# run in a batch with other branches' gates, and a gate that dies of a typo halfway through a
# mutation leaves a mutant on disk.  The EXIT trap covers that, but only if the script parsed.
if ! bash -n "${BASH_SOURCE[0]}"; then
    echo "🔴 this script does not parse" >&2; exit 2
fi
command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
[[ -d "$BUILD_DIR" ]] || { echo "🔴 no configured build dir at '$BUILD_DIR'" >&2; exit 2; }

# --- 1. anchors ---------------------------------------------------------------------------------
# Declared before anything is touched, and every one must appear EXACTLY once.  An anchor that
# matches twice would mutate a site the mutation was not named for and the verdict would be about
# the wrong code; an anchor that matches zero times means the source moved under the gate, and
# "the mutation could not be applied" must never be reported as "the mutation was caught".
declare -a ANCHOR_FILE ANCHOR_TEXT ANCHOR_NAME

add_anchor() { ANCHOR_NAME+=("$1"); ANCHOR_FILE+=("$2"); ANCHOR_TEXT+=("$3"); }

add_anchor "classify-window-test" "$SFLOW" \
'    if (ageMs < activeWindowMs)'
add_anchor "filter-active-case" "$SFLOW" \
'            return liveness == FlowLiveness::Active;'
add_anchor "active-window-const" "$FLUCH" \
'constexpr int64_t kFlowActiveWindowMs = 3000;'
add_anchor "api-default" "$HTTPH" \
'        sflow::FlowLivenessFilter::ActiveOnly;'
add_anchor "pathis-body" "$UTILS" \
'    if (!target.starts_with(path))
    {
        return false;
    }
    return target.size() == path.size() || target[path.size()] == '"'"'?'"'"';'

# 🔴 `grep -cF` is the WRONG TOOL for a multi-line anchor, and it fails in the direction that
# hides the problem: grep splits an -F pattern on newlines and treats the pieces as alternatives,
# then counts LINES matching any of them.  The five-line pathIs anchor counted 121 that way --
# every line in Utils.hpp holding a `{`, a `}` or a `return false;`.  A "must be 1" threshold would
# have rejected a perfectly good anchor; a "must be >= 1" threshold would have accepted an anchor
# that no longer exists.  The exact substring count comes from python.  The grep number is printed
# beside it as a cross-check on the anchor's FIRST LINE only, which is the question grep can
# actually answer.
count_exact() {
    python3 - "$1" "$2" <<'PYCOUNT'
import sys, pathlib
sys.stdout.write(str(pathlib.Path(sys.argv[1]).read_text().count(sys.argv[2])))
PYCOUNT
}

echo "=== anchor uniqueness (exact substring count must be 1) ==="
anchor_ok=1
for i in "${!ANCHOR_NAME[@]}"; do
    n=$(count_exact "${ANCHOR_FILE[$i]}" "${ANCHOR_TEXT[$i]}")
    first=${ANCHOR_TEXT[$i]%%$'\n'*}
    g=$(grep -cF -- "$first" "${ANCHOR_FILE[$i]}")
    printf '  %-24s %-54s exact=%s  grep(first line)=%s\n' \
        "${ANCHOR_NAME[$i]}" "${ANCHOR_FILE[$i]}" "$n" "$g"
    [[ "$n" == 1 ]] || { echo "     🔴 exact count must be 1"; anchor_ok=0; }
done
[[ "$anchor_ok" == 1 ]] || { echo "🔴 anchors have drifted; this gate cannot render a verdict" >&2; exit 2; }

# --- 2. snapshot --------------------------------------------------------------------------------
BK=$(mktemp -d)
declare -A SNAP SHA
for f in "${FILES[@]}"; do
    s="$BK/$(echo "$f" | md5sum | cut -c1-12).snap"
    cp -p "$f" "$s"; SNAP["$f"]="$s"; SHA["$f"]=$(sha256sum "$f" | cut -d' ' -f1)
done

restore() {
    local f
    for f in "${FILES[@]}"; do
        cp -p "${SNAP[$f]}" "$f"
        # `cp -p` puts the ORIGINAL mtime back, which is older than the object built from the
        # mutant -- so ninja sees nothing to do and the NEXT mutation is measured against a binary
        # that still contains the previous one, while the source on disk looks pristine.  The
        # sha256 check below passes either way, because it checks the file and not the artifact.
        # `touch` is what actually restores the build.  This exact trap has bitten this repo before
        # (see tests/shell/mutate_rate_denominator.sh).
        touch "$f"
    done
}
trap 'restore; rm -rf "$BK"' EXIT

BIN_SHA_BEFORE="(absent)"
[[ -f "$BIN" ]] && BIN_SHA_BEFORE=$(sha256sum "$BIN" | cut -c1-16)

# --- 3. build + run helpers ---------------------------------------------------------------------
build() { cmake --build "$BUILD_DIR" --target "$TARGET" -j"$JOBS" >/dev/null 2>&1; }

# run_tests <gtest_filter>  ->  sets STATUS RC OUT FAILED CRASHED_IN
# rc is captured from the command substitution directly; nothing is piped, because a pipe would
# hand back the status of the last stage instead of the binary's.
run_tests() {
    OUT=$(timeout "$TEST_TIMEOUT" "$BIN" --gtest_filter="$1" 2>&1); RC=$?
    FAILED=$(sed -n 's/^\[  FAILED  \] \([A-Za-z_][A-Za-z0-9_]*\.[A-Za-z0-9_]*\).*/\1/p' <<<"$OUT" \
             | sort -u | tr '\n' ' ')
    CRASHED_IN=""
    if (( RC == 124 )); then
        STATUS=hang
    elif (( RC > 128 )); then
        STATUS=crash
        CRASHED_IN=$(sed -n 's/^\[ RUN      \] \(.*\)$/\1/p' <<<"$OUT" | tail -1)
    elif (( RC != 0 )); then
        STATUS=fail
    else
        STATUS=pass
    fi
}

# is_red <test name>  -- true if that named test failed an assertion or was the one running when
# the process died of a signal.
is_red() {
    [[ " $FAILED " == *" $1 "* ]] && return 0
    [[ "$STATUS" == crash && "$CRASHED_IN" == "$1" ]] && return 0
    return 1
}

# --- 4. baseline --------------------------------------------------------------------------------
echo
echo "=== baseline (unmutated working tree) must build and be green ==="
if ! build; then
    echo "🔴 THE BASELINE DOES NOT COMPILE.  Nothing below means anything." >&2
    cmake --build "$BUILD_DIR" --target "$TARGET" -j"$JOBS" 2>&1 | tail -40 >&2
    exit 2
fi
# The suites this gate reasons about.  Everything in section 5 expects a red inside this scope, so
# a pre-existing failure somewhere else in test_routing_strategy cannot change any verdict below.
# It is still printed, loudly: a batch run that silently steps over an unrelated red is how a
# broken tree gets a row of green ticks.  A red INSIDE the scope is different -- it means the
# expected-red names cannot be trusted -- and it stops the run.
BX_SCOPE='FlowLivenessTest.*:FlowLivenessTableTest.*:HttpSessionRoutingTest.*'
in_bx_scope() {
    case "$1" in
        FlowLivenessTest.*|FlowLivenessTableTest.*|HttpSessionRoutingTest.*) return 0 ;;
        *) return 1 ;;
    esac
}

run_tests '*'
case "$STATUS" in
  pass)  echo "  ok       baseline green ($(grep -c '^\[       OK \]' <<<"$OUT") cases)" ;;
  crash) echo "🔴 BASELINE DIED OF SIGNAL $((RC-128)) while running: ${CRASHED_IN:-<unknown>}" >&2
         [[ -n "$FAILED" ]] && echo "   assertions already failed: $FAILED" >&2
         echo "   A crash on the UNMUTATED tree is never acceptable; the gate cannot proceed." >&2
         exit 2 ;;
  hang)  echo "🔴 BASELINE HUNG (>${TEST_TIMEOUT}s).  Not a red; the gate cannot proceed." >&2
         exit 2 ;;
  *)     bx_red=0
         echo "  baseline is NOT fully green.  Failing tests:"
         for t in $FAILED; do
             if in_bx_scope "$t"; then
                 echo "     🔴 IN SCOPE      $t"; bx_red=1
             else
                 echo "     ⚠️  out of scope  $t"
             fi
         done
         if [[ "$bx_red" == 1 ]]; then
             echo "🔴 A test this gate depends on is already red before any mutation." >&2
             echo "   Every 'expect red' below would be meaningless.  Stopping." >&2
             exit 2
         fi
         echo "  ⚠️  proceeding: every red is outside $BX_SCOPE, so it cannot affect the"
         echo "     verdicts below -- but SOMEONE MUST FIX THE ABOVE.  This gate is not a"
         echo "     statement about them."
         ;;
esac

# --- 5. mutations -------------------------------------------------------------------------------
MUTATIONS=0
SURVIVORS=0

# apply <file> <old> <new>   -- python does the replace so the anchor is matched LITERALLY,
# newlines and all, and re-asserts its own count at the moment of writing.  A shell `sed -i` would
# treat the anchor as a regex and a multi-line anchor not at all.
apply() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys, pathlib
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path); s = p.read_text()
if s.count(old) != 1:
    sys.stderr.write("anchor count %d, expected 1\n" % s.count(old)); sys.exit(1)
p.write_text(s.replace(old, new, 1))
PY
}

# mutate <label> <file> <old> <new> <expect-test...>
mutate() {
    local label="$1" file="$2" old="$3" new="$4"; shift 4
    local expected=("$@")
    MUTATIONS=$((MUTATIONS + 1))
    printf '\n=== %d. %s ===\n' "$MUTATIONS" "$label"
    printf '  expect red: %s\n' "${expected[*]}"

    if ! apply "$file" "$old" "$new"; then
        echo "  🔴 SURVIVED (anchor could not be applied) -- this proves nothing about the tests"
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    if ! build; then
        echo "  🔴 SURVIVED (mutant does not compile) -- this proves nothing about the tests"
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    local filter="" t
    for t in "${expected[@]}"; do filter+="$t:"; done
    run_tests "${filter%:}"

    local missed=() got=()
    for t in "${expected[@]}"; do
        if is_red "$t"; then got+=("$t"); else missed+=("$t"); fi
    done

    if [[ "$STATUS" == hang ]]; then
        echo "  🔴 HUNG (>${TEST_TIMEOUT}s) -- not a red, and not a catch"
        SURVIVORS=$((SURVIVORS + 1))
    elif [[ ${#missed[@]} -eq 0 ]]; then
        if [[ "$STATUS" == crash ]]; then
            printf '  ✅ caught  reason=crash (signal %d, died in %s)\n' "$((RC-128))" "$CRASHED_IN"
        else
            printf '  ✅ caught  reason=assert  red: %s\n' "${got[*]}"
        fi
    else
        printf '  🔴 SURVIVED -- these stayed green: %s\n' "${missed[*]}"
        [[ -n "$FAILED" ]] && printf '     (something else went red: %s -- the gate fires, but not\n     for the reason the design claims)\n' "$FAILED"
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# 1. The classifier stops classifying: everything is active, forever.  The most direct denial of
#    the whole ticket.  `true ||` rather than deleting the body, because -Werror is on and an
#    unreachable-code or unused-variable warning would fail the build and be reported as
#    "does not compile", which proves nothing.
mutate "classifyFlowLiveness always answers active" "$SFLOW" \
'    if (ageMs < activeWindowMs)' \
'    if (true || ageMs < activeWindowMs)' \
    FlowLivenessTest.TheActiveWindowIsHalfOpenSoItsUpperBoundIsAlreadyIdle \
    FlowLivenessTest.TheWholeRetentionTailIsIdleRatherThanActiveOrEnded \
    FlowLivenessTest.EndedBeginsExactlyWherePurgeIdleFlowsWouldRemoveTheRow \
    FlowLivenessTableTest.AStoppedFlowIsGoneFromTheDefaultViewAndStillThereUnderAll

# 2. 🔑 THE ONE THAT MATTERS MOST.  Three states collapse into the boolean "exclude ended", which
#    is the fix that passes review and removes almost nothing: `Ended` rows barely exist, because
#    purgeIdleFlows sweeps them within a second, so the ~92% -- all of them Idle -- keep sailing
#    through.  The fixture case is the one that must catch it, because the pure-function case
#    alone would let someone argue the collapse is harmless in practice.
mutate "three states collapse into boolean exclude-ended" "$SFLOW" \
'            return liveness == FlowLiveness::Active;' \
'            return liveness != FlowLiveness::Ended;' \
    FlowLivenessTest.ActiveOnlyAdmitsNothingButActive \
    FlowLivenessTableTest.AStoppedFlowIsGoneFromTheDefaultViewAndStillThereUnderAll \
    FlowLivenessTableTest.TopKFiltersBeforeItTruncatesRatherThanAfter

# 3. The window collapses to zero: nothing is ever active, and the endpoint answers [] under load.
#    The pessimistic failure direction -- traffic that is really there, reported as gone.
mutate "kFlowActiveWindowMs = 0" "$FLUCH" \
'constexpr int64_t kFlowActiveWindowMs = 3000;' \
'constexpr int64_t kFlowActiveWindowMs = 0;' \
    FlowLivenessTest.TheActiveWindowSitsBetweenARateLoopPeriodAndTheIdleTimeout \
    FlowLivenessTableTest.RowsJustReplayedAreActiveAndSurviveTheDefaultFilter \
    FlowLivenessTableTest.TheCountsAddUpToTheWholeTableAndMoveTogether

# 4. The window swallows the idle timeout: `Idle` becomes unreachable and the lifecycle silently
#    returns to two states.  Only the constant-relationship case can see this -- every
#    collector-level case drives the window through the test seam and so never reads the constant.
#    That gap is why FlowLivenessTest.TheActiveWindowSitsBetween... exists; this gate found it.
mutate "kFlowActiveWindowMs = 1000000000 (idle unreachable)" "$FLUCH" \
'constexpr int64_t kFlowActiveWindowMs = 3000;' \
'constexpr int64_t kFlowActiveWindowMs = 1000000000;' \
    FlowLivenessTest.TheActiveWindowSitsBetweenARateLoopPeriodAndTheIdleTimeout

# 5. The endpoint default is flipped back to the pre-patch population.  The single line that
#    decides whether /ndt/get_detected_flow_data keeps contradicting doc/2026-01-02_ndt_api.md:358.
#    ⚠️ Caught by a constant pin, NOT by a served request: no test in this repository builds an
#    HttpSessionTestPeer with a real collector, so nothing observes the handler honouring the
#    default.  Adding that peer is the highest-value follow-up to this gate.
mutate "API default flipped back to All" "$HTTPH" \
'        sflow::FlowLivenessFilter::ActiveOnly;' \
'        sflow::FlowLivenessFilter::All;' \
    FlowLivenessTest.TheEndpointDefaultIsActiveOnlyRatherThanTheWholeTable

# 6. utils::pathIs reverted to the exact compare it replaced.  This is what the flow-data route
#    was before the patch, and it is why the endpoint could not carry a query string at all: the
#    target no longer matched any branch and fell through to the 404 tail.
mutate "utils::pathIs reverted to exact ==" "$UTILS" \
'    if (!target.starts_with(path))
    {
        return false;
    }
    return target.size() == path.size() || target[path.size()] == '"'"'?'"'"';' \
'    return target == path;' \
    HttpSessionRoutingTest.AQueryStringOnGetDetectedFlowDataStillReachesItsRoute \
    HttpSessionRoutingTest.AnUnrecognisedLivenessValueIsRefusedRatherThanQuietlyDefaulted \
    HttpSessionRoutingTest.TopKRefusesAnUnrecognisedLivenessValueBeforeTouchingTheCollector

# 7. 🔴 THE CRASHING ONE.  pathIs reverted to the loose prefix compare the top-k route used before
#    the patch, so /ndt/get_detected_top_k_flow_dataZZZ is served instead of refused, reaches its
#    handler, and dereferences HttpSessionTestPeer's null collector.  Red by SIGSEGV, with no
#    FAILED line anywhere in the output.  Run alone, because a crash takes the rest of the binary's
#    reporting with it.
mutate "utils::pathIs reverted to loose starts_with (expect signal death)" "$UTILS" \
'    if (!target.starts_with(path))
    {
        return false;
    }
    return target.size() == path.size() || target[path.size()] == '"'"'?'"'"';' \
'    return target.starts_with(path);' \
    HttpSessionRoutingTest.AMistypedFlowDataEndpointIsNotFoundRatherThanServed

# --- 6. negative control ------------------------------------------------------------------------
# A comment.  It must SURVIVE.  If the suite goes red on this, the gate above is measuring "a file
# was edited and rebuilt" rather than "the behaviour changed", and every ✅ printed above is
# worthless.  This is the case that gives the other seven their meaning.
printf '\n=== CONTROL (comment only -- MUST survive) ===\n'
CONTROL_BAD=0
if apply "$SFLOW" \
    'enum class FlowLiveness
{' \
    '// mutation-gate negative control: text with no behaviour
enum class FlowLiveness
{'; then
    if build; then
        run_tests 'FlowLivenessTest.*:FlowLivenessTableTest.*:HttpSessionRoutingTest.*'
        case "$STATUS" in
          pass)  echo "  ✅ survived -- a comment changes nothing, so the catches above are about behaviour" ;;
          crash) echo "  🔴 CONTROL DIED OF SIGNAL $((RC-128)) in ${CRASHED_IN:-<unknown>}"; CONTROL_BAD=1 ;;
          hang)  echo "  🔴 CONTROL HUNG"; CONTROL_BAD=1 ;;
          *)     echo "  🔴 CONTROL WENT RED: $FAILED"
                 echo "     This gate cannot tell an edit from a behaviour change.  Every catch above is void."
                 CONTROL_BAD=1 ;;
        esac
    else
        echo "  🔴 CONTROL DOES NOT COMPILE -- a comment broke the build; the anchor is wrong"; CONTROL_BAD=1
    fi
else
    echo "  🔴 CONTROL anchor could not be applied"; CONTROL_BAD=1
fi
restore

# --- 7. verdict ---------------------------------------------------------------------------------
# One rebuild after the final restore, and its result is CHECKED.  `build || true` would leave the
# batch's next gate running against a binary built from the last mutant while every file on disk
# looked pristine -- the same failure `touch` exists to prevent, one level up.
restore
REBUILD_OK=1
if ! build; then
    REBUILD_OK=0
fi

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
    echo "     mutation left.  Do not run another gate against it."
    ok=0
fi
echo "  test binary: $(sha256sum "$BIN" 2>/dev/null | cut -c1-16) (was $BIN_SHA_BEFORE)"

printf '\n=== verdict ===\n'
printf '  %d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"
[[ "$CONTROL_BAD" == 1 ]] && echo "  control FAILED -- the gate has no discriminating power"

if [[ "$ok" != 1 || "$CONTROL_BAD" == 1 ]]; then exit 2; fi
if (( SURVIVORS > 0 )); then exit 1; fi
exit 0
