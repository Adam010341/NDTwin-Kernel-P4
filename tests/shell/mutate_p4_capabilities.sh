#!/usr/bin/env bash
#
# Mutation gate for the per-switch `capabilities` on /ndt/get_graph_data (third cut of the
# P4-driven API; the contract is TICKET-P4-roles.md Appendix A). Suite: tests/test_P4Capabilities.cpp.
#
# [Co-developed with claude code -- Adam]
#
#   M1   the proxy's answer is never recorded                                        (red)
#   M2   WIDENING: `capabilities: null` (or any non-object) becomes an entry          (red)
#   M3   the object is rebuilt from the five keys Appendix A names                   (red)
#   M4   null-valued keys are "tidied" away                                          (red)
#   M5   a dpid key is read leniently -- sign, junk, 0x prefix                       (red)
#   M6   a dpid key that overflows 64 bits wraps instead of being refused            (red)
#   M7   WIDENING: an unreadable answer manufactures an entry                        (red)
#   M8   hosts are not excluded when a node is written                               (red)
#   M9   WIDENING: an undescribed switch is given an empty object                    (red)
#   M10  an OVS fabric asks the proxy too                                            (red)
#   M11  the 1 Hz step never records what it read                                    (red)
#   M12  an unreadable proxy leaves the last answer standing                         (red)
#   M13  each answer is merged into the last instead of replacing it                 (red)
#   M14  the 1 Hz step no longer hands the answer on to the liveness verdicts        (red)
#   M15  get_graph_data never puts the object on the node                            (red)
#   C1   control: a comment added beside the write                                   (must stay green)
#
# 🔴 THE WIDENINGS (M2, M7, M9) ARE THE ONES THAT MATTER MOST. Absence is the contract's baseline:
# a node without `capabilities` tells the GUI "every operation is supported". Anything that makes
# the key appear where the proxy said nothing -- `null`, `{}`, a placeholder for an unreadable
# answer -- is the cheapest way to look more complete, and it turns "nobody said" into something
# a consumer may read as "supports nothing".
#
# M14 is not about capabilities at all: the change moved the bmv2 liveness fetch into the step
# this gate mutates, and M14 is the check that the move did not cost the liveness loop its input.
#
# Every cell -- one build followed by one run of the suite -- is ONE call to
# tools/build_guard/guarded_build.sh, so each takes the lock once and the gate never holds it
# between cells. To take the lock once for the whole run instead, wrap it in an outer guard and
# set NO_GUARD=1 (the guard is re-entrant):
#
#   JOBS=1 LOCK_WAIT=10800 tools/build_guard/guarded_build.sh \
#       env NO_GUARD=1 bash tests/shell/mutate_p4_capabilities.sh
#
# NO_GUARD=1 without an outer guard is an unguarded build on this laptop -- do not.
#
# Usage:  bash tests/shell/mutate_p4_capabilities.sh
#         BUILD_DIR=build-asan bash tests/shell/mutate_p4_capabilities.sh
#         ANCHOR_CHECK=1 bash tests/shell/mutate_p4_capabilities.sh   # NOT a gate result
# Assumes: ${BUILD_DIR:-build} is already configured (ninja). Runs from the repo root it lives in.
# Exit:    0 every mutation caught and the control green, 1 a mutation survived (or the control
#          went red), 2 refused (baseline red, anchor moved, baseline not restored, or anchor-check
#          mode -- which never produces a verdict).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
FILTER='P4Capabilities.*:P4CapabilitiesPoll.*:P4CapabilitiesWire.*'
GUARD="${GUARD:-$REPO/tools/build_guard/guarded_build.sh}"

CAPS=src/ndt_core/power_management/P4Capabilities.cpp
DCPM=src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp
HTTP=src/ndt_core/http/HttpSession.cpp
FILES=("$CAPS" "$DCPM" "$HTTP")

ANCHOR_CHECK="${ANCHOR_CHECK:-0}"
if [[ "${1:-}" == "--dry-run" ]]; then
    ANCHOR_CHECK=1
fi

for f in "${FILES[@]}" tests/test_P4Capabilities.cpp; do
    [[ -f "$f" ]] || { echo "REFUSE: $f not found." >&2; exit 2; }
done

MUTATIONS=0
SURVIVORS=0

# anchor_count <file> <literal> -- how many times the literal occurs. python rather than
# `grep -c -F`, which splits a multi-line pattern into several and counts matching LINES.
anchor_count() {
    ANCHOR="$2" python3 - "$1" <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
}

# --- the mutation table ------------------------------------------------------------------------
# Declared once so the anchor check and the gate cannot disagree about what is being tested.
# Fields: label, file, anchor, replacement, the test that must go red ("-" for a control).

MUT_LABEL=(); MUT_FILE=(); MUT_ANCHOR=(); MUT_REPL=(); MUT_EXPECT=()
add() {
    MUT_LABEL+=("$1"); MUT_FILE+=("$2"); MUT_ANCHOR+=("$3")
    MUT_REPL+=("$4");  MUT_EXPECT+=("$5")
}

add "M1: the proxy's answer is never recorded" \
    "$CAPS" \
    '        out.emplace(*dpid, *capsIt);' \
    '        // MUTANT: nothing is recorded' \
    'P4Capabilities.TheAppendixAFixturesAreCopiedVerbatim'

add "M2: WIDENING -- capabilities: null (or a non-object) becomes an entry" \
    "$CAPS" \
    '        if (capsIt == entry.end() || !capsIt->is_object())' \
    '        if (capsIt == entry.end())' \
    'P4Capabilities.ASwitchTheProxyDoesNotDescribeGetsNoEntry'

add "M3: the object is rebuilt from the five keys Appendix A names" \
    "$CAPS" \
    '        out.emplace(*dpid, *capsIt);' \
    '        nlohmann::json known = nlohmann::json::object();
        for (const char* k : {"ipv4_route", "five_tuple", "reroute", "link_discovery",
                              "binding_source"})
        {
            if (capsIt->contains(k))
            {
                known[k] = capsIt->at(k);
            }
        }
        out.emplace(*dpid, known);' \
    'P4Capabilities.KeysAndValuesTheKernelHasNeverHeardOfPassThrough'

add "M4: null-valued keys are tidied away" \
    "$CAPS" \
    '        out.emplace(*dpid, *capsIt);' \
    '        nlohmann::json tidy = *capsIt;
        for (auto it = tidy.begin(); it != tidy.end();)
        {
            if (it->is_null())
            {
                it = tidy.erase(it);
            }
            else
            {
                ++it;
            }
        }
        out.emplace(*dpid, tidy);' \
    'P4Capabilities.TheAppendixAFixturesAreCopiedVerbatim'

add "M5: a dpid key is read leniently (sign, junk, 0x prefix)" \
    "$CAPS" \
    "        if (c < '0' || c > '9')
        {
            return std::nullopt;
        }" \
    "        if (c < '0' || c > '9')
        {
            break;
        }" \
    'P4Capabilities.AKeyThatIsNotAPlainDecimalDpidIsSkipped'

add "M6: a dpid key that overflows 64 bits wraps instead of being refused" \
    "$CAPS" \
    '        if (value > (kMax - digit) / 10)' \
    '        if (value > (kMax - digit) / 10 && key.size() > 64)' \
    'P4Capabilities.AKeyThatIsNotAPlainDecimalDpidIsSkipped'

add "M7: WIDENING -- an unreadable answer manufactures an entry" \
    "$CAPS" \
    '    if (!payload.has_value() || !payload->is_object())
    {
        return out;
    }' \
    '    if (!payload.has_value() || !payload->is_object())
    {
        out.emplace(0, nlohmann::json::object());
        return out;
    }' \
    'P4Capabilities.NoAnswerMeansNoCapabilities'

add "M8: hosts are not excluded when a node is written" \
    "$CAPS" \
    '    if (vertex.vertexType != VertexType::SWITCH)
    {
        return;
    }' \
    '    // MUTANT: hosts are not excluded' \
    'P4Capabilities.AttachNeverTouchesAHost'

add "M9: WIDENING -- an undescribed switch is given an empty object" \
    "$CAPS" \
    '    if (it == caps.end())
    {
        return;
    }' \
    '    if (it == caps.end())
    {
        node["capabilities"] = nlohmann::json::object();
        return;
    }' \
    'P4Capabilities.AttachLeavesAnUndescribedSwitchExactlyAsItWas'

add "M10: an OVS fabric asks the proxy too" \
    "$DCPM" \
    '    if (m_mode == utils::DeploymentMode::MININET && dataPlaneIsBmv2())
    {
        payload = fetchP4SwitchState();
    }' \
    '    if (true)
    {
        payload = fetchP4SwitchState();
    }' \
    'P4CapabilitiesPoll.AnOvsFabricNeverAsksTheProxyAndCarriesNothing'

add "M11: the 1 Hz step never records what it read" \
    "$DCPM" \
    '        m_p4Capabilities = std::move(capabilities);' \
    '        (void)capabilities;' \
    'P4CapabilitiesPoll.AnAllBmv2FabricRecordsWhatTheProxySaid'

add "M12: an unreadable proxy leaves the last answer standing" \
    "$DCPM" \
    '    p4caps::CapabilitiesByDpid capabilities = p4caps::fromSwitchState(payload);
    {' \
    '    p4caps::CapabilitiesByDpid capabilities = p4caps::fromSwitchState(payload);
    if (payload.has_value())
    {' \
    'P4CapabilitiesPoll.AnUnreadableProxyWithdrawsTheLastAnswer'

add "M13: each answer is merged into the last instead of replacing it" \
    "$DCPM" \
    '        m_p4Capabilities = std::move(capabilities);' \
    '        for (auto& [dpid, one] : capabilities)
        {
            m_p4Capabilities[dpid] = std::move(one);
        }' \
    'P4CapabilitiesPoll.EachAnswerReplacesThePreviousOneWhole'

add "M14: the 1 Hz step no longer hands the answer on to the liveness verdicts" \
    "$DCPM" \
    '    return payload;
}

p4caps::CapabilitiesByDpid' \
    '    return std::nullopt;
}

p4caps::CapabilitiesByDpid' \
    'P4CapabilitiesPoll.AnAllBmv2FabricRecordsWhatTheProxySaid'

add "M15: get_graph_data never puts the object on the node" \
    "$HTTP" \
    '        p4caps::attachToNode(node, graph[vd], p4Capabilities);' \
    '        // MUTANT: capabilities never attached' \
    'P4CapabilitiesWire.EachSwitchNodeCarriesItsOwnCapabilitiesVerbatim'

add "C1: control -- a comment beside the write (must stay green)" \
    "$CAPS" \
    '    node["capabilities"] = it->second;' \
    '    // control cell: a comment changes nothing
    node["capabilities"] = it->second;' \
    '-'

# --- anchor check (never a verdict) -------------------------------------------------------------

if [[ "$ANCHOR_CHECK" != "0" ]]; then
    echo "================================================================"
    echo " ANCHOR CHECK ONLY -- THIS IS NOT A GATE RESULT."
    echo " Nothing was built, no mutation was applied, no test was run."
    echo " The exit code is 2 on purpose so this can never be mistaken for"
    echo " a passing gate."
    echo "================================================================"
    broken=0
    for i in "${!MUT_LABEL[@]}"; do
        n=$(anchor_count "${MUT_FILE[$i]}" "${MUT_ANCHOR[$i]}")
        if [[ "$n" -eq 1 ]]; then
            printf '  ok    %s  (%s)\n' "$n" "${MUT_LABEL[$i]}"
        else
            printf '  🔴 %s matches in %s  (%s)\n' "$n" "${MUT_FILE[$i]}" "${MUT_LABEL[$i]}"
            broken=$((broken + 1))
        fi
    done
    if [[ "$broken" -eq 0 ]]; then
        echo "ANCHORS: ok -- all ${#MUT_LABEL[@]} resolve to one site each."
    else
        echo "ANCHORS: BROKEN -- $broken anchor(s) have moved. Fix them before running the gate."
    fi
    echo "(still exiting 2: an anchor check is not a gate result)"
    exit 2
fi

# --- the gate: mutations in place, snapshot and restore ------------------------------------------

[[ -f "$BUILD_DIR/build.ninja" ]] || { echo "REFUSE: $BUILD_DIR is not configured (cmake -B $BUILD_DIR -G Ninja)." >&2; exit 2; }

SNAP=$(mktemp -d)
BK=$(mktemp -d)
snap() { echo "$SNAP/$(basename "$1")"; }
for f in "${FILES[@]}"; do cp -p "$f" "$(snap "$f")"; done
restore() {
    local f
    for f in "${FILES[@]}"; do
        # Only a file that differs is put back. Touching all three after every cell would make
        # every build recompile HttpSession.cpp (~1.6 GB, minutes at -j1) for mutants that never
        # went near it -- and each build waits on the shared lock.
        cmp -s "$(snap "$f")" "$f" && continue
        cp -p "$(snap "$f")" "$f"
        # cp -p restores the ORIGINAL mtime, which is older than the object built from the
        # mutant -- ninja would then see nothing to do and the next run would test the mutant
        # while the source on disk is pristine. touch is what actually restores the build.
        touch "$f"
    done
}
trap 'restore; rm -rf "$SNAP" "$BK"' EXIT

# cell -- ONE guard call that builds the target and, only if that succeeded, runs the suite:
# one cell, one lock acquisition, never a batch. Writes $BK/build.log and $BK/run.log and sets
# CELL_BUILT (0/1) and CELL_RC (the suite's exit status, taken from the binary directly, never
# through a pipe). See the header for NO_GUARD.
CELL_BUILT=0
CELL_RC=0
cell() {
    local runner=(bash -c '
        cmake --build "$1" --target "$2" -j1 >"$3" 2>&1 || exit 97
        "$4" --gtest_filter="$5" >"$6" 2>&1' _
        "$BUILD_DIR" "$TARGET" "$BK/build.log" "$BIN" "$FILTER" "$BK/run.log")
    : >"$BK/build.log"; : >"$BK/run.log"
    local rc
    if [[ "${NO_GUARD:-0}" == "1" ]]; then
        "${runner[@]}"; rc=$?
    else
        LOCK_WAIT="${LOCK_WAIT:-10800}" JOBS=1 "$GUARD" "${runner[@]}" >>"$BK/guard.log" 2>&1; rc=$?
    fi
    # 97 is the build failing. The guard's own refusals (lock timeout, bad env) come back as other
    # codes with an empty run log; they are reported as "did not build" too, never as a verdict.
    if [[ $rc -eq 97 || ! -s "$BK/run.log" ]]; then
        CELL_BUILT=0
    else
        CELL_BUILT=1
    fi
    CELL_RC=$rc
}

# red_tests -- the names of the tests the last cell saw fail, space-separated; empty when all
# passed. The name pattern admits digits: every suite here is spelled P4..., and a letters-only
# pattern would read each red as "none" and score every mutant a survivor.
red_tests() {
    if [[ $CELL_RC -eq 0 ]]; then echo ""; return; fi
    local names
    names=$(sed -n 's/^\[  FAILED  \] \([A-Za-z0-9_]*\.[A-Za-z0-9_]*\).*/\1/p' "$BK/run.log" | sort -u | tr '\n' ' ')
    # A non-zero exit with no FAILED line is a crash or an abort, which is red but names nothing.
    [[ -n "$names" ]] && echo "$names" || echo "UNNAMED(rc=$CELL_RC)"
}

echo "baseline (must be green before any mutation):"
cell
if [[ $CELL_BUILT -ne 1 ]]; then
    echo "  the tree does not build (cell rc $CELL_RC) -- nothing below would mean anything"
    tail -8 "$BK/build.log" "$BK/guard.log" 2>/dev/null | sed 's/^/    /'
    exit 2
fi
base_red=$(red_tests)
if [[ -n "$base_red" ]]; then
    echo "  baseline is RED: $base_red"
    exit 2
fi
echo "  green  ($(grep -c '^\[       OK \]' "$BK/run.log") cases passed in $FILTER)"

CONTROL_RED=0

# mutate <label> <file> <anchor> <replacement> <expected-test>
mutate() {
    local label="$1" file="$2" anchor="$3" repl="$4" expected="$5"
    local n; n=$(anchor_count "$file" "$anchor")
    printf '\n=== %s ===\n' "$label"
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- this mutation proves nothing. Fix the anchor."
        SURVIVORS=$((SURVIVORS + 1)); MUTATIONS=$((MUTATIONS + 1)); restore; return
    fi
    [[ "$expected" == "-" ]] || MUTATIONS=$((MUTATIONS + 1))

    if ! ANCHOR="$anchor" REPL="$repl" python3 - "$file" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a, r = os.environ["ANCHOR"], os.environ["REPL"]
assert s.count(a) == 1, "anchor is not unique at write time"
p.write_text(s.replace(a, r, 1))
PY
    then
        echo "  🔴 mutation could not be applied. NOT a pass."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    cell
    if [[ $CELL_BUILT -ne 1 ]]; then
        # A mutant that never reached the compiler established nothing about the tests.
        echo "  🔴 MUTANT DOES NOT COMPILE (cell rc $CELL_RC) -- the behaviour it was aimed at is still untested."
        tail -8 "$BK/build.log" | sed 's/^/    /'
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    local failed; failed=$(red_tests)
    restore

    if [[ "$expected" == "-" ]]; then
        if [[ -n "$failed" ]]; then
            echo "  🔴 CONTROL WENT RED: $failed -- the gate reports red for a change that changes nothing"
            CONTROL_RED=$((CONTROL_RED + 1))
        else
            echo "  control green, as it must be"
        fi
        return
    fi
    if [[ -z "$failed" ]]; then
        echo "  🔴 SURVIVED -- every test stayed green"
        SURVIVORS=$((SURVIVORS + 1))
        return
    fi
    if ! grep -qw -- "$expected" <<<"$failed"; then
        echo "  🔴 WRONG TEST WENT RED. expected $expected, got: $failed"
        echo "     A gate that fires without establishing what it claims is not a gate."
        SURVIVORS=$((SURVIVORS + 1))
        return
    fi
    echo "  caught by: $failed"
}

for i in "${!MUT_LABEL[@]}"; do
    mutate "${MUT_LABEL[$i]}" "${MUT_FILE[$i]}" "${MUT_ANCHOR[$i]}" \
           "${MUT_REPL[$i]}" "${MUT_EXPECT[$i]}"
done

echo
echo "restoring and rebuilding the baseline..."
restore
cell
if [[ $CELL_BUILT -ne 1 ]]; then
    echo "🔴 the tree does not build after restore -- the baseline was NOT restored"
    exit 2
fi
for f in "${FILES[@]}"; do
    if ! cmp -s "$f" "$(snap "$f")"; then
        echo "🔴 $f was NOT restored byte-for-byte"
        exit 2
    fi
done
after_red=$(red_tests)
if [[ -n "$after_red" ]]; then
    echo "🔴 the restored tree is RED: $after_red"
    exit 2
fi
echo "baseline restored, byte-identical, green."

echo
if [[ "$SURVIVORS" -eq 0 && "$CONTROL_RED" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived; control green"
    exit 0
fi
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived; $CONTROL_RED control(s) red"
exit 1
