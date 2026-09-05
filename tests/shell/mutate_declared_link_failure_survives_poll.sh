#!/usr/bin/env bash
#
# Mutation gate for doc/KNOWN-ISSUES.md B-6 -- a DECLARED link failure must survive the topology
# poll, and the poll must go on raising every link nobody declared down.
#
# [Co-developed with claude code -- Adam]
#
# Covers tests/test_PollDoesNotResurrect.cpp (DeclaredLinkFailureTest) and
# tests/test_HttpSessionRouting.cpp (DeclaredLinkFailureWireTest).
#
# WHAT THE DEFECT WAS
#   TopologyAndFlowMonitor::updateLinks applied Ryu's link list with
#       (*m_graph)[edgeOpt.value()].isUp = true;
#   and no else branch anywhere in the function -- the same one-way ratchet updateSwitches was
#   before FINDINGS #46, and believed harmless for the same-sounding reason: Ryu DROPS a failed
#   link from /v1.0/topology/links, so "a poll can fill in what was missed but cannot resurrect an
#   edge the push path correctly took down". That premise holds for a link that really broke and
#   NOT for one that was only declared broken through POST /ndt/link_failure_detected: nothing
#   about the fabric changed, so Ryu keeps listing it. Nothing in the code checked the premise.
#   Measured 2026-09-04 (R2-B): 5 declarations, 5 resurrections, 0-30 s later, each ~0.6 s after a
#   poll, /ndt/link_recovery_detected never called and no line in kernel.log. The netem control
#   arm -- a real cut -- came back 0 of 1.
#
# 🔴 TWO DIRECTIONS, AND THE SECOND ONE IS WHY THIS GATE EXISTS AT ALL
#   1. RESTORING the defect must be caught          (M1, M2, M4, M5)
#      -- discovery lifts isUp over a standing declaration, by any of the routes it could take:
#         the veto removed, the veto inverted, the withdrawal that never happens, and the push
#         path going back to the observation writer (which is the trunk shape of this bug).
#   2. RELAXING past the fix must ALSO be caught    (M3, M6, M7, M8)
#      -- a poll that NEVER raises a link satisfies every assertion in direction 1 and is a worse
#         outage than the defect: updateLinks is the ONLY writer that brings an inter-switch link
#         back, so `// isUp = true;` would leave the graph dark for every link that was ever down.
#         M7 is the subtler version -- the derived-liveness pass marking its own edges as declared,
#         so a switch outage becomes permanent -- and M8 is the one a reader of the fix's summary
#         sentence reaches for first: "do not lift anything that is down".
#
# 🔴 THREE MUTATIONS MUST **NOT** BE CAUGHT (W1, W2, W3). A suite that reddens on these is pinning
# source text rather than behaviour, and every catch above would be worth nothing:
#   W1  a comment                        -- the classic control
#   W2  the WARN's wording               -- the log line is not the behaviour
#   W3  the veto written as an equivalent expression -- proves the tests assert what the graph
#       ends up holding, not the shape of the branch that put it there
#
# 🔴 A MUTANT THAT DOES NOT COMPILE IS A SURVIVOR, not a skip: the suite never ran, so it proves
# nothing. Same for an anchor that has moved, and for a run that hangs.
#
# 🔴 GUARDS ITS OWN BASELINE. The file it can touch is snapshotted with `cp -p` first, an EXIT trap
# restores it however this exits including Ctrl-C, and the run ends by asserting byte identity
# against the snapshot AND that the test binary's sha is the one the baseline built.
#
# 🔴 NEVER KILLS ANYTHING BY NAME. No pkill, no pgrep: `timeout` owns the only child. Nothing here
# starts Mininet, bmv2, OVS or a listening socket, and NOTHING HERE RUNS tc -- the netem half of
# B-6 is covered by tests/test_NetemLinkFault.cpp against a fake runner, deliberately, because a
# gate that touched the machine's qdisc tree would be the injection tool corrupting the experiment
# this repository exists to protect.
#
# 🔴 BUILD UNDER THE GUARD. This laptop's oomd took the user's own application down on 2026-09-02.
#   JOBS=2 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh \
#       ./tests/shell/mutate_declared_link_failure_survives_poll.sh
#
# Usage:  tools/build_guard/guarded_build.sh ./tests/shell/mutate_declared_link_failure_survives_poll.sh
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
FILTER='DeclaredLinkFailureTest.*:DeclaredLinkFailureWireTest.*'

TFM=src/ndt_core/collection/TopologyAndFlowMonitor.cpp
FILES=("$TFM")

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

add_anchor "link-veto"      "$TFM" '                    if (eprop.declaredDown)'
add_anchor "link-lifts"     "$TFM" '                    else
                    {
                        eprop.isUp = true;
                    }'
add_anchor "link-enables"   "$TFM" '                    eprop.isEnabled = true;'
add_anchor "declared-down"  "$TFM" '    eprop.isUp = false;
    eprop.declaredDown = true;'
add_anchor "declared-clear" "$TFM" '    eprop.declaredDown = false;'
add_anchor "derived-down"   "$TFM" '            ep.isUp = false;
            ep.downReason = DownReason::SwitchUnreachable;'
add_anchor "link-warn-text" "$TFM" '                                "the control plane still lists link (dpid {} port {}), but a link "'
add_anchor "link-comment"   "$TFM" '                    // Being listed by Ryu is not evidence that a link is carrying traffic. The'

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
# 5. the mutations -- direction 1: putting the defect back
# ================================================================================================

# M1. 🔴 THE DEFECT EXACTLY AS IT SHIPPED. The veto is gone and the write is unconditional again.
mutate "the defect verbatim: the poll lifts every link it is told about" \
    "$TFM" \
    '                    if (eprop.declaredDown)' \
    '                    if (false)' \
    DeclaredLinkFailureTest.ADeclaredLinkFailureSurvivesATopologyPoll \
    DeclaredLinkFailureTest.EveryLaterPollDeclinesTheDeclaredLinkToo \
    DeclaredLinkFailureWireTest.ADeclaredLinkFailureIsStillDownAfterAPollAndSaysWhy

# M2. The veto inverted: only DECLARED links are lifted. Catches a test suite that checks "the
#     branch is consulted" rather than which way round it goes.
mutate "the veto is inverted: only a declared link is raised" \
    "$TFM" \
    '                    if (eprop.declaredDown)' \
    '                    if (!eprop.declaredDown)' \
    DeclaredLinkFailureTest.ADeclaredLinkFailureSurvivesATopologyPoll \
    DeclaredLinkFailureTest.APollStillRaisesALinkNobodyDeclaredDown

# M4 in the ticket's numbering: recovery never withdraws the declaration, so an injection is
#     permanent and unrecoverable -- the mirror image of the defect, and the failure mode this fix
#     introduces if the withdrawal is ever lost.
mutate "recovery does not withdraw the declaration" \
    "$TFM" \
    '    eprop.declaredDown = false;' \
    '    // [mutant] the declaration is never withdrawn' \
    DeclaredLinkFailureTest.ADeclaredRecoveryLetsThePollRaiseTheEdgeAgain \
    DeclaredLinkFailureTest.ALinkThatCameBackInRyuIsRaisedAgainAfterRecovery \
    DeclaredLinkFailureWireTest.ARecoveryWithdrawsTheDeclarationAndTheNextPollRaisesTheLink

# 🔴 THE TRUNK SHAPE OF THIS BUG. The push path records an OBSERVATION instead of a declaration,
#     which is byte-for-byte what setEdgeDown does and is exactly what HttpSession called before
#     this fix. FINDINGS #46's sentence with "vertex" replaced by "edge": calling the observation
#     writer from a push path is the defect, because the graph can no longer tell the twin's own
#     opinion from what it was told.
mutate "the push path records an observation instead of a declaration (= trunk)" \
    "$TFM" \
    '    eprop.isUp = false;
    eprop.declaredDown = true;' \
    '    eprop.isUp = false;' \
    DeclaredLinkFailureTest.ADeclaredLinkFailureSurvivesATopologyPoll \
    DeclaredLinkFailureTest.EveryLaterPollDeclinesTheDeclaredLinkToo \
    DeclaredLinkFailureTest.ObservationWritersNeitherSetNorClearTheDeclaration \
    DeclaredLinkFailureWireTest.ADeclaredLinkFailureIsStillDownAfterAPollAndSaysWhy

# ================================================================================================
#    direction 2: relaxing past the fix. 🔴 These are the reason this gate is not just B-6's.
# ================================================================================================

# THE OVER-CORRECTION. The poll stops writing isUp at all -- the shape someone reaches for on
#     reading "the poll must not mark links up". Every assertion in direction 1 stays green, and
#     the fabric never comes back: updateLinks is the only writer that raises an inter-switch link.
mutate "the poll never raises any link" \
    "$TFM" \
    '                    else
                    {
                        eprop.isUp = true;
                    }' \
    '                    else
                    {
                        // nothing
                    }' \
    DeclaredLinkFailureTest.APollStillRaisesALinkNobodyDeclaredDown \
    DeclaredLinkFailureTest.ALinkThatCameBackInRyuIsRaisedAgainAfterRecovery \
    DeclaredLinkFailureTest.ADerivedDownEdgeIsStillRaisedWhenTheSwitchComesBack

# The veto swallows the ADMINISTRATIVE axis too, which would make /ndt/link_failure_detected a
#     covert DisableSwitch: the link stops being routable rather than stops being up.
mutate "the veto blocks isEnabled as well as isUp" \
    "$TFM" \
    '                    eprop.isEnabled = true;' \
    '                    if (!eprop.declaredDown) eprop.isEnabled = true;' \
    DeclaredLinkFailureTest.ADeclaredDownEdgeIsStillAdministrativelyEnabled

# 🔴 The subtle over-correction: the DERIVED liveness pass marks its own edges as declared, so an
#     edge taken down because a switch went away is never raised again -- every switch outage
#     becomes permanent and the twin never reports a recovered fabric. Direction 1 cannot see this
#     at all: a stickier declaration makes every one of those cases greener.
mutate "the derived liveness pass marks its edges as declared" \
    "$TFM" \
    '            ep.isUp = false;
            ep.downReason = DownReason::SwitchUnreachable;' \
    '            ep.isUp = false;
            ep.declaredDown = true;
            ep.downReason = DownReason::SwitchUnreachable;' \
    DeclaredLinkFailureTest.ADerivedDownEdgeIsStillRaisedWhenTheSwitchComesBack

# The first thing a reader of "a poll must not resurrect a link that is down" writes: veto on the
#     liveness bit rather than on the declaration. Same permanence as the mutation above, reached
#     from the other side, and it looks more defensible in review than it is.
mutate "the veto reads isUp instead of the declaration" \
    "$TFM" \
    '                    if (eprop.declaredDown)' \
    '                    if (!eprop.isUp)' \
    DeclaredLinkFailureTest.APollStillRaisesALinkNobodyDeclaredDown \
    DeclaredLinkFailureTest.ALinkThatCameBackInRyuIsRaisedAgainAfterRecovery \
    DeclaredLinkFailureTest.ADerivedDownEdgeIsStillRaisedWhenTheSwitchComesBack

# ================================================================================================
# 6. the widenings -- these MUST survive
# ================================================================================================

# W1. A comment. If anything reddens here, every catch above is measuring "a file was edited and
#     rebuilt" rather than "the behaviour changed".
widen "a comment, nothing else" \
    "$TFM" \
    '                    // Being listed by Ryu is not evidence that a link is carrying traffic. The' \
    '                    // Ryu listing a link is not evidence that it carries traffic. The'

# W2. The WARN's wording. A suite that reddens here is pinning a string, and the next person to
#     improve the message would have to change a test to do it.
widen "the declined-resurrection warning is reworded" \
    "$TFM" \
    '                                "the control plane still lists link (dpid {} port {}), but a link "' \
    '                                "link (dpid {} port {}) is still listed by the control plane, but a link "'

# W3. The veto written as an equivalent expression. The control for tests that pin the structure of
#     the fix rather than what the graph ends up holding.
widen "the veto is written as an equivalent expression" \
    "$TFM" \
    '                    if (eprop.declaredDown)' \
    '                    if (bool(eprop.declaredDown) == true)'

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
echo "  B-6 gate: the defect cannot be put back by any of four routes, a poll that stops raising"
echo "  links is caught by four more, and three behaviour-preserving edits were left alone."
exit 0
