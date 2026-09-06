#!/usr/bin/env bash
#
# Mutation gate for FINDINGS #61, #62, #89, #90 and #91 -- a topology file that names a switch it
# does not contain, a port a switch cannot have, a node nothing can address, or a data plane this
# build cannot drive, must be refused at load, and refused whole.
#
# [Co-developed with claude code -- Adam]
#
# Covers tests/test_TopologyInputValidation.cpp.
#
# 🔴 #89 IS A DIFFERENT CLAIM FROM #61/#62 AND IS MEASURED DIFFERENTLY (M10-M16, added
# 2026-09-05). #61/#62 were about whether the loader refuses at all. #89 is about WHERE it
# refuses: three node-side conditions were still throwing from inside the builder loop, on node N,
# with nodes 0..N-1 already added -- so every one of them was already "refused", and a mutation
# scored by `threw` would show nothing. M10-M13 are scored by `vertices == 0`. The fourth door,
# `ecmp_groups[].port_id`, had no check anywhere and is M14-M16.
#
# 🔴 #90 IS A THIRD CLAIM AGAIN (M17-M20, added 2026-09-06): door 3b's condition stopped at
# `vertexType == SWITCH`, so the same defect on a HOST was accepted. Half of it is scored like
# #61/#62 (`threw`, because an addressless host really did load) and half like nothing else in
# this file (the message, because a missing or non-array "ip" was ALREADY refused -- with a raw
# nlohmann exception where a sentence belongs). See section 5c.
#
# 🔴 #61/#62 WERE MEASURED ON :8000. #89's three doors WERE NOT -- they were read out of the
# source, and this gate plus test_TopologyInputValidation.cpp is their entire evidence. Anything
# quoting this file must not upgrade them to field observations. #90's empty-array half WAS
# measured on :8000 (R0b, 2026-09-05, kernel 862c4bf8, served as `('h9', [])`); its missing-key
# and non-array halves were not, and are message claims rather than acceptance claims.
#
# 🔴 W15-2 (M25-M27, added 2026-09-07) REVERSES HALF OF #91 BY RULING, so this gate now measures
# a door that is deliberately narrower than it was yesterday: an unrecognised brand is admitted
# when the node declares an explicit, legal `switch_kind`, and the switch is marked
# power_path/telemetry_path "none" in the graph. The mark is not a detail -- it is the condition
# the ruling came with, it is what M27 exists for, and a gate that only measured "the file loads"
# would pass a fix that had quietly restored #91's silent fallback. See section 5e.
#
# 🔴 #91 (M21-M24, added 2026-09-06) IS THE SAME ROUND'S bad file `c`, and it WAS measured:
# `brand_name = "NOT_A_REAL_KIND"` was accepted, mapped to HARDWARE, and reported only as a
# data-plane MIXTURE whose suggested remedy would have made the typo permanent. Half of this half
# is therefore about what the message SAYS, and M24 is the only thing that can redden it. See
# section 5d.
#
# WHAT THE DEFECTS WERE
#   #61  An edge whose dpid matched no switch node was dropped. One `[warning] Skipping edge:`
#        line, and the graph went on to be served: measured on :8000 against the shipped P4
#        4-host topology with one field changed, 40 edges in and **39** out, every endpoint 200
#        (round5-topology-repro/03_mutant_m1_host_edge_ghost_dpid.log).
#   #62  `src_interface` 0 and 999999 passed with no range check at all and were republished
#        verbatim by get_graph_data (06_/07_mutant logs).
#
# 🔴 TWO DIRECTIONS, AND THE SECOND ONE IS WHY THIS GATE IS NOT JUST #61's AND #62's.
#   1. RESTORING either defect must be caught             (M1-M7)
#      -- the validator not called, the endpoint check gone, the refusal turned back into a
#         WARN, the range check gone, and the range check off by one at either end.
#   2. OVER-CORRECTING must ALSO be caught                (M8, M9)
#      -- 🔴 M8 IS THE MOST IMPORTANT MUTATION IN THIS FILE. "A port index must be >= 1" is the
#         rule a reader reaches for, and it is wrong: the spec says the host side of a host edge
#         carries dpid 0 AND interface 0, and five shipped TESTBED files do exactly that on every
#         host edge. A gate without M8 would green-light a change that refuses five of the
#         thirteen files this repo ships -- a wider outage than #62 ever caused.
#         M9 is the same shape one step milder: the ceiling quietly narrowed to the fleet's
#         observed maximum, which passes every #62 case and breaks the next switch with more
#         ports than today's.
#
# 🔴 THE FIX HAS TWO LAYERS, SO ONE MUTATION HERE EDITS TWO SITES (M2). The validator refuses the
# file, and the edge builder still refuses to add half a graph if the two ever disagree. That is
# deliberate -- a silent drop is the failure being fixed, so "the validator and the builder
# disagree" must not be the one path that reintroduces it -- but it means no single-site edit can
# restore the measured 40->39 behaviour. Reporting that as "unrestorable" would be a gate
# flattering its own subject, so M2 applies both edits and is labelled as doing so.
#
# 🔴 THREE MUTATIONS MUST **NOT** BE CAUGHT (W1, W2, W3). A suite that reddens on these is
# pinning source text rather than behaviour:
#   W1  a comment                    -- the classic control
#   W2  the refusal's wording        -- the tests assert that the offending NUMBER reaches the
#                                       operator, never the prose around it. Rewording a
#                                       diagnostic must stay free.
#   W3  the dpid lookup written as the negated comparison -- identical semantics, different shape
#
# 🔴 A MUTANT THAT DOES NOT COMPILE IS A SURVIVOR, not a skip: the suite never ran, so it proves
# nothing. Same for an anchor that has moved, and for a run that hangs.
#
# 🔴 GUARDS ITS OWN BASELINE. Every file it can touch is snapshotted with `cp -p` first, an EXIT
# trap restores them however this exits including Ctrl-C, and the run ends by asserting byte
# identity against the snapshot AND that the test binary's sha is the one the baseline built.
# `cp -p` restores the ORIGINAL mtime -- older than the object built from the mutant -- so ninja
# would see nothing to do and the next mutation would be measured against a stale binary. A
# restored file is therefore also `touch`ed, but only if it actually changed.
#
# 🔴 NEVER KILLS ANYTHING BY NAME. No pkill, no pgrep: `timeout` owns the only child. Nothing
# here starts Mininet, bmv2, OVS, or a listening socket -- these cases load JSON off disk.
#
# 🔴 BUILD UNDER THE GUARD. This laptop's oomd took the user's own application down on 2026-09-02.
#   tools/build_guard/guarded_build.sh ./tests/shell/mutate_topology_input_is_validated.sh
#
# Usage:  tools/build_guard/guarded_build.sh ./tests/shell/mutate_topology_input_is_validated.sh
#   BUILD_DIR=build     configured build directory (ninja)
#   JOBS=2              build parallelism
#   TEST_TIMEOUT=300    seconds allowed per test-binary run
#
# Exit: 0 every mutation caught by the test it names, both widenings survived, tree restored
#       1 at least one mutation survived, or a widening was caught
#       2 no verdict is possible: baseline red or not building, anchor drift, hang, failed restore
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

BUILD_DIR="${BUILD_DIR:-build}"
JOBS="${JOBS:-2}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
FILTER='TopologyInputValidationTest.*'

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
# Declared before anything is touched, every one exactly once. An anchor matching twice would
# mutate a site the mutation is not named for; one matching zero times means the source moved
# under the gate, and "could not be applied" must never be reported as "was caught".
count_exact() {
    python3 - "$1" "$2" <<'PYCOUNT'
import sys, pathlib
sys.stdout.write(str(pathlib.Path(sys.argv[1]).read_text().count(sys.argv[2])))
PYCOUNT
}

declare -a ANCHOR_FILE ANCHOR_TEXT ANCHOR_NAME
add_anchor() { ANCHOR_NAME+=("$1"); ANCHOR_FILE+=("$2"); ANCHOR_TEXT+=("$3"); }

add_anchor "validate-call"  "$TFM" '    validateStaticTopologyJson(j, where, m_mode);'
add_anchor "dpid-known"     "$TFM" '            if (switchDpids.count(dpid) == 0)'
add_anchor "dpid-refusal"   "$TFM" '                    "\" is " + std::to_string(dpid) +'
add_anchor "host-addr"      "$TFM" '            if (nodeAddresses.count(addresses.front()) == 0)'
add_anchor "iface-ceiling"  "$TFM" '        if (ifIndex > kMaxTopologyInterface)'
add_anchor "iface-floor"    "$TFM" '        if (dpid != 0 && ifIndex == 0)'
add_anchor "max-constant"   "$TFM" 'constexpr std::uint32_t kMaxTopologyInterface = 65535;'
add_anchor "builder-refuse" "$TFM" '        if (!srcVertexOpt.has_value() || !dstVertexOpt.has_value())'
add_anchor "gate-comment"   "$TFM" '    // The endpoints, indexed exactly the way the edge loop below resolves them: switches by'
# FINDINGS #89 / W-TOPO-THREE-DOORS. All five are in validateStaticTopologyJson and none of them
# is in the builder loop, deliberately: the builder still carries its own copy of the three door-3
# refusals as a backstop, and a gate that mutated THAT copy would be measuring the backstop.
add_anchor "door3a-kind"    "$TFM" '            (void)switchKindFromString(nodeJson.at("switch_kind").get<std::string>());'
add_anchor "door3b-noip"    "$TFM" '        if (vertexType == VertexType::SWITCH && addresses.empty())'
add_anchor "door3c-mode"    "$TFM" '        if (mode == utils::DeploymentMode::MININET && vertexType == VertexType::SWITCH &&'
add_anchor "door3c-bridge"  "$TFM" '            !(nodeJson.contains("bridge_name") && nodeJson.at("bridge_name").is_string()))'
add_anchor "door2-range"    "$TFM" '                if (portId < 1 || portId > static_cast<std::int64_t>(kMaxTopologyInterface))'

# FINDINGS #90 door 3d -- the HOST half of door 3b. Four anchors: the door itself, and each of
# the three faults it names separately, because "refused" and "refused in a sentence" are two
# different claims and only the second one is red before this fix for two of the three.
add_anchor "door3d-host"    "$TFM" '        if (vertexType == VertexType::HOST)'
add_anchor "door3d-nokey"   "$TFM" '            if (!nodeJson.contains("ip"))'
add_anchor "door3d-notarr"  "$TFM" '            else if (!nodeJson.at("ip").is_array())'
add_anchor "door3d-empty"   "$TFM" '            else if (nodeJson.at("ip").empty())'

# FINDINGS #91 door 3e -- an unknown switch brand_name.
add_anchor "door3e-switch"  "$TFM" '        if (vertexType == VertexType::SWITCH)
        {
            if (!(nodeJson.contains("brand_name") && nodeJson.at("brand_name").is_string()))'
add_anchor "door3e-member"  "$TFM" '            if (std::find(kAcceptedSwitchBrands.begin(), kAcceptedSwitchBrands.end(), brandName) ==
                    kAcceptedSwitchBrands.end() &&
                !declaresLegalSwitchKind(nodeJson))'
add_anchor "door3e-list"    "$TFM" '    "HPE5520",        // testbed hardware, SNMP power + temperature'
add_anchor "door3e-message" "$TFM" '                    ". An unrecognised brand used to be mapped to \"hardware\" silently, which "'

# W15-2 -- the switch_kind exemption and the mark it costs. Three anchors: the exemption clause
# itself, the predicate that decides it, and the line that writes the mark onto the vertex. The
# mark has its own anchor because "the file loads" and "and the twin admits it cannot drive this
# switch" are two claims, and a fix that made only the first one true would be #91's silent
# fallback wearing a ruling.
add_anchor "w15b-exempt"    "$TFM" '                !declaresLegalSwitchKind(nodeJson))'
add_anchor "w15b-presence"  "$TFM" '            if (!(nodeJson.contains("brand_name") && nodeJson.at("brand_name").is_string()))'
add_anchor "w15b-predicate" "$TFM" '    if (!(nodeJson.contains("switch_kind") && nodeJson.at("switch_kind").is_string()))'
add_anchor "w15b-mark"      "$TFM" '        vp.powerPath = powerPathForBrandName(vp.brandName);'

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

# run_tests <gtest_filter> -> sets STATUS RC OUT FAILED DIED_IN. rc comes from the binary itself
# and is never taken through a pipe, because a pipeline's status belongs to its last stage.
#
# 🔴 A TEST CAN GO RED WITHOUT PRINTING `[  FAILED  ]`. A mutation that throws out of a place the
# fixture does not guard kills the process with no FAILED line, and reading "no FAILED line" as
# "nothing went red" would score real damage as a survivor. DIED_IN is the last case gtest
# announced, empty when it announced none -- which stays a survivor, loudly.
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

# apply <file> <anchor> <new> -- python does the replace, so the anchor matches LITERALLY,
# newlines and all, and the count is re-asserted at the moment of writing. `sed -i` would read
# the anchor as a regex and would not see a multi-line one at all.
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

# _score <label> <expect-red...> -- everything after the edits have been applied. Shared by
# mutate and mutate2 so a two-site mutation is scored by exactly the same rules as a one-site one.
_score() {
    local label="$1"; shift
    local expected=("$@")
    printf '  expect red: %s\n' "${expected[*]}"

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
        # [Co-developed with claude code -- Adam]
        # 🔴 PRINT THE RED, not just the name of the light. Added 2026-09-05 with #89's
        # mutations. "M11 caught AnAddresslessSwitchLeavesNoPartiallyLoadedGraph" does not say
        # WHICH assertion went red, and for door 3 that is the entire distinction being measured:
        # `threw` is true with and without the fix, and only the `vertices == 0` line separates
        # them. A gate whose log cannot show that cannot be quoted as evidence for it, and every
        # reader would have to rebuild the mutant to find out. Capped, because a mutation that
        # breaks the fixture can print thousands of lines.
        sed -n '/^\[ RUN      \]/,/^\[  FAILED  \]/p' <<<"$OUT" \
            | grep -vE '^\[       OK \]|^\[ RUN      \]$' | head -40 | sed 's/^/    | /'
    else
        printf '  🔴 SURVIVED -- these stayed green: %s\n' "${missed[*]}"
        [[ -n "$FAILED" ]] && printf '     (something else went red: %s -- the gate fires, but not\n     for the reason this mutation claims)\n' "$FAILED"
        [[ "$STATUS" != pass && -z "$FAILED" && -z "$DIED_IN" ]] && printf '     (the binary exited %d before announcing a single case -- the mutation broke the\n     test process itself, which is damage, not evidence)\n' "$RC"
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# mutate <label> <file> <anchor> <new> <expect-red...>
# Every named test must be red. "Something went red" is not the check -- WHICH light went red is.
mutate() {
    local label="$1" file="$2" anchor="$3" new="$4"; shift 4
    MUTATIONS=$((MUTATIONS + 1))
    printf '\n=== M%d. %s ===\n' "$MUTATIONS" "$label"

    if ! apply "$file" "$anchor" "$new"; then
        echo "  🔴 SURVIVED (anchor could not be applied) -- this proves nothing about the tests"
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    _score "$label" "$@"
}

# mutate2 <label> <file> <anchorA> <newA> <anchorB> <newB> <expect-red...>
# Two sites, one mutant. Only for a defect the fix defends in two places -- see the header.
mutate2() {
    local label="$1" file="$2" a1="$3" n1="$4" a2="$5" n2="$6"; shift 6
    MUTATIONS=$((MUTATIONS + 1))
    printf '\n=== M%d. %s ===\n' "$MUTATIONS" "$label"

    if ! apply "$file" "$a1" "$n1" || ! apply "$file" "$a2" "$n2"; then
        echo "  🔴 SURVIVED (an anchor could not be applied) -- this proves nothing"
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    _score "$label" "$@"
}

# widen <label> <file> <anchor> <new> -- a change that must leave EVERY case green. These are
# what give the catches above their meaning.
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
# 5. the mutations -- direction 1: putting either defect back
# ================================================================================================

# M1. VALIDATION REMOVED. The whole pass is never called. #62 is then unchecked end to end; #61
#     is still refused, by the builder's own guard -- but refused AFTER 14 vertices and 32 edges
#     have been added, which is the partial application the fix exists to stop. That split is
#     exactly what the two #61 tests are for, and only one of them may go red here.
#
#     🔴 ITS ANCHOR MOVED ONCE ALREADY, AND NOTHING BUT check_gate_anchors.py SAID SO. #89 gave
#     validateStaticTopologyJson a third parameter; this anchor still read `(j, where)`, so on
#     2026-09-05 M1 reported SURVIVED-anchor-not-applied while every test stayed green. That is
#     the exact failure mode that tool exists for (`mutate_lock_renew_expiry.sh` lost six anchors
#     the same way). Run it after touching this function's signature, not just this file.
#
#     🔴 `if (false)` rather than deleting the call, and the first draft of this gate got it
#     wrong. Replacing the call with `(void)j;` leaves validateStaticTopologyJson defined and
#     unreferenced in an anonymous namespace, which is -Wunused-function, which is -Werror here:
#     the mutant did not compile and this gate scored it a SURVIVOR -- correctly, because a suite
#     that never ran proves nothing. Keeping the call in dead code removes the validation while
#     leaving the function used, so what is measured is the missing check and not the warning.
mutate "validation removed: the whole pass is never called" \
    "$TFM" \
    '    validateStaticTopologyJson(j, where, m_mode);' \
    '    if (false)
    {
        validateStaticTopologyJson(j, where, m_mode);
    }' \
    TopologyInputValidationTest.AGhostDpidEdgeLeavesNoPartiallyLoadedGraph \
    TopologyInputValidationTest.ASixDigitInterfaceIsRefused \
    TopologyInputValidationTest.TheRefusalNamesTheInterfaceThatWasOutOfRange \
    TopologyInputValidationTest.ADestinationInterfaceIsCheckedToo \
    TopologyInputValidationTest.OneAboveTheLargestInRangeInterfaceIsRefused \
    TopologyInputValidationTest.AZeroInterfaceOnTheSwitchSideIsRefused \
    TopologyInputValidationTest.AMalformedSwitchKindLeavesNoPartiallyLoadedGraph \
    TopologyInputValidationTest.AnAddresslessSwitchLeavesNoPartiallyLoadedGraph \
    TopologyInputValidationTest.AMissingBridgeNameInMininetLeavesNoPartiallyLoadedGraph \
    TopologyInputValidationTest.AnOutOfRangeEcmpPortIdIsRefusedAtLoad \
    TopologyInputValidationTest.AZeroEcmpPortIdIsRefusedAtLoad \
    TopologyInputValidationTest.ANegativeEcmpPortIdIsRefusedAtLoad \
    TopologyInputValidationTest.AnAddresslessHostLeavesNoPartiallyLoadedGraph \
    TopologyInputValidationTest.TheAddresslessHostRefusalNamesTheHost \
    TopologyInputValidationTest.AHostWithNoIpKeyAtAllIsRefusedInPlainLanguage \
    TopologyInputValidationTest.AHostWhoseIpIsNotAnArrayIsRefusedInPlainLanguage \
    TopologyInputValidationTest.AnExistingHostLosingItsAddressNowNamesTheHostNotTheEdge \
    TopologyInputValidationTest.ASwitchWithASwitchKindStillNeedsABrandName

# M2. THE #61 DEFECT VERBATIM: THE ERROR SWALLOWED INTO A WARN AGAIN. Both layers, because the
#     fix has two -- see the header. The validator logs and moves on, and the builder goes back
#     to the `Skipping edge` line it shipped with. This is the measured 40 -> 39.
mutate2 "error swallowed into a WARN again (both layers): the 40 -> 39 defect verbatim" \
    "$TFM" \
    '                throw std::runtime_error(
                    "\"" + dpidKey +
                    "\" is " + std::to_string(dpid) +
                    " and no switch node in this file declares that dpid. Refusing the file: this "
                    "link used to be dropped with one warning and the rest of the topology served "
                    "as though it were complete");' \
    '                SPDLOG_LOGGER_WARN(Logger::instance(),
                                   "Skipping edge: dpid {} matches no switch node",
                                   dpid);
                return;' \
    '            throw std::runtime_error(
                "this edge resolved while the file was validated but not while the graph was "
                "built, which should be impossible. Refusing rather than dropping it: a graph "
                "quietly missing one link reports a healthy fabric with a cable unplugged");' \
    '            SPDLOG_LOGGER_WARN(Logger::instance(),
                               "Skipping edge: src_dpid={} dst_dpid={}",
                               ep.srcDpid,
                               ep.dstDpid);
            continue;' \
    TopologyInputValidationTest.AnEdgeNamingADpidNoSwitchHasIsRefused \
    TopologyInputValidationTest.TheRefusalNamesTheDpidThatMatchedNothing \
    TopologyInputValidationTest.AGhostDpidEdgeLeavesNoPartiallyLoadedGraph

# M3. The endpoint check answers "yes" for every dpid -- the lookup is still written, still
#     compiles, and can never fire. The shape a refactor produces when it "simplifies" a set
#     lookup it believes is redundant.
mutate "the unknown-dpid check can never fire" \
    "$TFM" \
    '            if (switchDpids.count(dpid) == 0)' \
    '            if (switchDpids.count(dpid) == 0 && false)' \
    TopologyInputValidationTest.AGhostDpidEdgeLeavesNoPartiallyLoadedGraph

# M4. The other half of #61's lookup: the host side, resolved by address rather than by dpid.
#     Nothing in the switch-side cases can see this.
mutate "a host edge's address is no longer checked against the file" \
    "$TFM" \
    '            if (nodeAddresses.count(addresses.front()) == 0)' \
    '            if (nodeAddresses.count(addresses.front()) == 0 && false)' \
    TopologyInputValidationTest.AHostEdgeWhoseAddressMatchesNoNodeIsRefused

# M5. #62's ceiling removed. 999999 passes again and reaches get_graph_data verbatim.
mutate "the interface range check is removed" \
    "$TFM" \
    '        if (ifIndex > kMaxTopologyInterface)' \
    '        if (false)' \
    TopologyInputValidationTest.ASixDigitInterfaceIsRefused \
    TopologyInputValidationTest.TheRefusalNamesTheInterfaceThatWasOutOfRange \
    TopologyInputValidationTest.ADestinationInterfaceIsCheckedToo \
    TopologyInputValidationTest.OneAboveTheLargestInRangeInterfaceIsRefused

# M6. RANGE CHECK OFF BY ONE, at the top. `>` becomes `>=` on the value one past the limit --
#     i.e. the ceiling silently gains a value. One character, and every #62 case above stays
#     green: only the boundary case can see it.
mutate "range check off by one: the ceiling admits one value too many" \
    "$TFM" \
    '        if (ifIndex > kMaxTopologyInterface)' \
    '        if (ifIndex > kMaxTopologyInterface + 1)' \
    TopologyInputValidationTest.OneAboveTheLargestInRangeInterfaceIsRefused

# M7. RANGE CHECK OFF BY ONE, at the bottom, and this is the dangerous direction: port 1 is the
#     lowest port every one of the thirteen shipped files uses, so `== 0` becoming `<= 1` refuses
#     all of them. Both the boundary case and the shipped-fleet case must see it.
mutate "range check off by one: the floor also refuses port 1" \
    "$TFM" \
    '        if (dpid != 0 && ifIndex == 0)' \
    '        if (dpid != 0 && ifIndex <= 1)' \
    TopologyInputValidationTest.TheSmallestInRangeSwitchInterfaceIsAccepted \
    TopologyInputValidationTest.EveryShippedTopologyStillLoadsWithNothingDropped \
    TopologyInputValidationTest.TheTwoMininetCapableTopologiesStillLoadInMininetMode

# ================================================================================================
#    direction 2: over-correcting. 🔴 These are the reason this gate is not just #61's and #62's.
# ================================================================================================

# M8. 🔴 THE FLEET-BREAKING MISTAKE. "A port index must be >= 1" -- the rule the finding's own
#     wording invites -- applied to both sides instead of only the switch side. Every #62 case
#     above stays green. Five shipped TESTBED files, which put the documented 0 on every host
#     edge, stop loading.
mutate "the floor is applied to the host side too (port 0 refused everywhere)" \
    "$TFM" \
    '        if (dpid != 0 && ifIndex == 0)' \
    '        if (ifIndex == 0)' \
    TopologyInputValidationTest.AZeroInterfaceOnTheHostSideIsStillAccepted \
    TopologyInputValidationTest.EveryShippedTopologyStillLoadsWithNothingDropped

# M9. The milder over-correction: the ceiling narrowed to the highest interface index the fleet
#     happens to use today (67). Every #62 case stays green -- 999999 is still refused -- and the
#     next switch with more ports than any current one is refused with it.
mutate "the ceiling is narrowed to the fleet's observed maximum" \
    "$TFM" \
    'constexpr std::uint32_t kMaxTopologyInterface = 65535;' \
    'constexpr std::uint32_t kMaxTopologyInterface = 67;' \
    TopologyInputValidationTest.TheLargestInRangeInterfaceIsAccepted

# ================================================================================================
#    FINDINGS #89 / W-TOPO-THREE-DOORS -- the other input paths, added 2026-09-05
#
# 🔴 EVERY ONE OF THESE MUTATES ONLY THE VALIDATOR'S COPY, NEVER THE BUILDER'S. The builder still
# throws on all three door-3 conditions and that is deliberate (two layers, same as M2's), so the
# mutant here restores "refused, after 0..N-1 nodes are already in the graph" rather than "not
# refused at all". That is the whole point: the three *LeavesNoPartiallyLoadedGraph cases go red
# on `vertices == 0` while `threw` stays true, which is what distinguishes this fix from a fix
# that only made the loader throw. A gate that mutated the builder's copy instead would be
# measuring the backstop and would report the validator as untested.
#
# 🔴 NONE OF THESE MAY DELETE THE `mode` PARAMETER'S ONLY USE. -Werror turns an unused parameter
# into a compile error, a mutant that does not compile is scored a SURVIVOR here (correctly -- the
# suite never ran), and the survivor would be an artefact of the gate rather than of the tests. So
# M12 keeps `mode` in the condition it disables, and M13 changes which mode rather than removing it.
# ================================================================================================

# M10. Door 3a: switch_kind is no longer validated up front. The builder still calls
#      switchKindFromString for the value it needs, so the file is still refused -- with every
#      earlier node already added.
mutate "door 3a: a malformed switch_kind is refused by the builder again, not by the validator" \
    "$TFM" \
    '            (void)switchKindFromString(nodeJson.at("switch_kind").get<std::string>());' \
    '            (void)0;' \
    TopologyInputValidationTest.AMalformedSwitchKindLeavesNoPartiallyLoadedGraph

# M11. Door 3b: FINDINGS #85's door back where it was. This is the sharpest case in the file --
#      the refusal still happens, from TopologyAndFlowMonitor.cpp's builder loop, so a suite
#      asserting only `threw` stays entirely green on it.
mutate "door 3b: an addressless switch is refused by the builder again, not by the validator" \
    "$TFM" \
    '        if (vertexType == VertexType::SWITCH && addresses.empty())' \
    '        if (vertexType == VertexType::SWITCH && addresses.empty() && false)' \
    TopologyInputValidationTest.AnAddresslessSwitchLeavesNoPartiallyLoadedGraph

# M12. Door 3c: the MININET bridge_name check never fires. `mode` stays in the condition so the
#      mutant still compiles -- see the section header.
mutate "door 3c: the MININET bridge_name check never fires" \
    "$TFM" \
    '            !(nodeJson.contains("bridge_name") && nodeJson.at("bridge_name").is_string()))' \
    '            false)' \
    TopologyInputValidationTest.AMissingBridgeNameInMininetLeavesNoPartiallyLoadedGraph

# M13. 🔴 DOOR 3c's FLEET-BREAKING DIRECTION, the M8 of this half of the gate. The check is put on
#      the wrong mode: TESTBED now demands a bridge_name and MININET no longer checks one. The
#      five _ipAlias4_ TESTBED files declare no bridge_name on any switch, so all five stop
#      loading -- a wider outage than the defect. Three cases must see it, and one of them is the
#      shipped-fleet case.
mutate "door 3c is applied to the wrong mode (TESTBED demands a bridge_name)" \
    "$TFM" \
    '        if (mode == utils::DeploymentMode::MININET && vertexType == VertexType::SWITCH &&' \
    '        if (mode == utils::DeploymentMode::TESTBED && vertexType == VertexType::SWITCH &&' \
    TopologyInputValidationTest.AMissingBridgeNameInMininetLeavesNoPartiallyLoadedGraph \
    TopologyInputValidationTest.AMissingBridgeNameIsNotCheckedInTestbedMode \
    TopologyInputValidationTest.EveryShippedTopologyStillLoadsWithNothingDropped

# M14. Door 2's ceiling removed. 999999 in an ecmp member is accepted again and reaches the flow
#      path -- #62's defect, on the field #62 did not cover.
mutate "door 2: the ecmp port_id ceiling is removed" \
    "$TFM" \
    '                if (portId < 1 || portId > static_cast<std::int64_t>(kMaxTopologyInterface))' \
    '                if (portId < 1)' \
    TopologyInputValidationTest.AnOutOfRangeEcmpPortIdIsRefusedAtLoad

# M15. Door 2's floor removed entirely. port_id is a signed int read straight out of the file, so
#      this admits 0 AND every negative. Both cases must see it, which is what separates it from
#      M16 below.
mutate "door 2: the ecmp port_id floor is removed (0 and negatives accepted)" \
    "$TFM" \
    '                if (portId < 1 || portId > static_cast<std::int64_t>(kMaxTopologyInterface))' \
    '                if (portId > static_cast<std::int64_t>(kMaxTopologyInterface))' \
    TopologyInputValidationTest.AZeroEcmpPortIdIsRefusedAtLoad \
    TopologyInputValidationTest.ANegativeEcmpPortIdIsRefusedAtLoad

# M16. 🔴 OVER-CORRECTION BY FALSE ANALOGY, and the reason M15 is not enough on its own. The
#      writer knows port 0 is legitimate on the host side of a host EDGE (M8 above is the whole
#      story) and transplants the exemption onto ecmp_groups, where it does not belong: ecmp
#      groups appear only on switch nodes and every member names a switch port. Zero is admitted,
#      negatives are still refused -- so ONLY the zero case can tell M16 from a correct bound.
mutate "door 2: the host side's port-0 exemption is transplanted onto ecmp members" \
    "$TFM" \
    '                if (portId < 1 || portId > static_cast<std::int64_t>(kMaxTopologyInterface))' \
    '                if ((portId != 0 && portId < 1) ||
                    portId > static_cast<std::int64_t>(kMaxTopologyInterface))' \
    TopologyInputValidationTest.AZeroEcmpPortIdIsRefusedAtLoad

# ================================================================================================
# 5c. FINDINGS #90 -- door 3d, the HOST half of door 3b (M17-M20, added 2026-09-06)
#
# 🔴 THIS DOOR IS MEASURED DIFFERENTLY AGAIN, AND IN TWO DIFFERENT WAYS AT ONCE.
#   - The EMPTY ARRAY was measured live: R0b (2026-09-05, kernel 862c4bf8) loaded a host with
#     `"ip": []` into the shipped OVS model, the kernel accepted it with zero diagnostic, opened
#     :8000, and served the node as `('h9', [])`. For that one, `threw` is a real red.
#   - The MISSING KEY and the NON-ARRAY were already refused before this fix, by the shared
#     `at("ip")` read a few lines below -- inside the validator, so `vertices == 0` too. NOTHING
#     about the refusal changed for them; what changed is that the operator gets a sentence
#     instead of `[json.exception.out_of_range.403] key 'ip' not found`. The only assertion that
#     can move is the one that says the message is not a raw nlohmann exception, and M18/M19 are
#     the mutations that prove that assertion is load-bearing rather than decorative.
#
# 🔴 UNLIKE M10-M12 THERE IS NO BUILDER COPY TO FALL BACK ON. Door 3b's builder twin is
# switch-only (`vp.vertexType == VertexType::SWITCH && vp.ip.empty()`), so a mutation that
# disables door 3d removes the refusal outright rather than pushing it into the builder loop.
# That is why M17 expects `threw` to go red as well, where M11 expects only `vertices`.
# ================================================================================================

# M17. The door never fires. The measured defect verbatim: an addressless host loads, and so does
#      a host whose "ip" is missing or a bare string -- those two by falling through to the shared
#      read, which is where their nlohmann exception comes back.
#
#      🔴 THIS MUTATION ALREADY CAUGHT A DEFECTIVE TEST ONCE, ON 2026-09-06, AND THAT IS WHY THE
#      FIXTURE LOOKS THE WAY IT DOES. The first draft of
#      AnAddresslessHostLeavesNoPartiallyLoadedGraph emptied an EXISTING host's "ip". That file is
#      refused with or without door 3d -- the two edges naming that host by address stop resolving
#      and #61's edge door refuses it -- so the case stayed green here and M17 reported SURVIVED
#      while the whole suite was green. Only an ADDED host, which no edge points at, reaches the
#      node side. Do not "simplify" the fixture back.
mutate "door 3d: the host address check never fires" \
    "$TFM" \
    '        if (vertexType == VertexType::HOST)' \
    '        if (vertexType == VertexType::HOST && false)' \
    TopologyInputValidationTest.AnAddresslessHostLeavesNoPartiallyLoadedGraph \
    TopologyInputValidationTest.TheAddresslessHostRefusalNamesTheHost \
    TopologyInputValidationTest.AHostWithNoIpKeyAtAllIsRefusedInPlainLanguage \
    TopologyInputValidationTest.AHostWhoseIpIsNotAnArrayIsRefusedInPlainLanguage \
    TopologyInputValidationTest.AnExistingHostLosingItsAddressNowNamesTheHostNotTheEdge

# M18. Only the missing-key arm is dropped. The very next line is `nodeJson.at("ip").is_array()`,
#      so the file is STILL refused -- by at() throwing out_of_range from inside the door. Exactly
#      one case may move, and it moves on the message and on nothing else.
mutate "door 3d: a missing \"ip\" key falls through to at() and its nlohmann exception" \
    "$TFM" \
    '            if (!nodeJson.contains("ip"))' \
    '            if (false)' \
    TopologyInputValidationTest.AHostWithNoIpKeyAtAllIsRefusedInPlainLanguage

# M19. Only the wrong-type arm is dropped. A JSON string is not empty, so the door says nothing
#      and the shared read below throws type_error.302. Same shape as M18, other fault.
mutate "door 3d: a non-array \"ip\" falls through to the shared read's type_error" \
    "$TFM" \
    '            else if (!nodeJson.at("ip").is_array())' \
    '            else if (false)' \
    TopologyInputValidationTest.AHostWhoseIpIsNotAnArrayIsRefusedInPlainLanguage

# M20. 🔴 DOOR 3d's FLEET-BREAKING DIRECTION -- the M8/M13 of this door, and the reason
#      AHostWithMoreThanOneAddressStillLoads exists. "A host needs an address" is read as "a host
#      has AN address", singular. The five _ipAlias4_ TESTBED files give every host FOUR (that is
#      what the name means: 160 hosts across five files), so all five stop loading -- a wider
#      outage than the defect. The addressless cases stay GREEN here, because 0 != 1 as well: only
#      the two controls can see it.
mutate "door 3d demands exactly one address (the five _ipAlias4_ files give four)" \
    "$TFM" \
    '            else if (nodeJson.at("ip").empty())' \
    '            else if (nodeJson.at("ip").size() != 1)' \
    TopologyInputValidationTest.EveryShippedTopologyStillLoadsWithNothingDropped \
    TopologyInputValidationTest.AHostWithMoreThanOneAddressStillLoads

# ================================================================================================
# 5d. FINDINGS #91 / W15 -- door 3e, a brand_name this build has no data plane for (M21-M24,
#     added 2026-09-06)
#
# 🔴 THE DEFECT WAS NOT SILENCE, IT WAS A REFUSAL THAT DID NOT REFUSE. R0b measured an unknown
# brand being accepted while the operator was shown an ERROR-level "Topology mixes data planes"
# line whose suggested remedy -- set AppConfig::ALLOW_MIXED_DATAPLANE -- would have made the typo
# permanent. So this half of the gate has two directions that are easy to confuse:
#   - the file must be refused                        (M21)
#   - and refused for the brand, not for the mixture  (M24 puts the advice back in the message)
# and one that is more dangerous than either, because it looks like tightening:
#   - the accepted list narrowed to the virtual kinds (M23) takes five shipped files down.
#
# 🔴 NONE OF THESE MAY LEAVE kAcceptedSwitchBrands OR acceptedSwitchBrandList() UNUSED: -Werror
# turns that into a compile error and a mutant that does not compile is scored a SURVIVOR here.
# M21 therefore adds `&& false` to the membership test rather than deleting it, and M23 changes an
# entry rather than removing one (the array's size is declared, so a removal would also leave a
# value-initialised empty brand behind and measure something else).
# ================================================================================================

# M21. The membership test can never fire. The measured defect verbatim: an unknown brand is
#      accepted, becomes HARDWARE, and the only diagnostic is about the mixture it caused.
mutate "door 3e: an unknown brand_name is accepted again" \
    "$TFM" \
    '            if (std::find(kAcceptedSwitchBrands.begin(), kAcceptedSwitchBrands.end(), brandName) ==
                    kAcceptedSwitchBrands.end() &&
                !declaresLegalSwitchKind(nodeJson))' \
    '            if (std::find(kAcceptedSwitchBrands.begin(), kAcceptedSwitchBrands.end(), brandName) ==
                    kAcceptedSwitchBrands.end() &&
                !declaresLegalSwitchKind(nodeJson) && false)' \
    TopologyInputValidationTest.AnUnknownBrandNameLeavesNoPartiallyLoadedGraph \
    TopologyInputValidationTest.TheUnknownBrandRefusalNamesTheBrandAndTheAcceptedOnes \
    TopologyInputValidationTest.TheUnknownBrandRefusalDoesNotSuggestAllowingMixedDataPlanes

# M22. 🔴 OVER-WIDE: the door is applied to every node type. Every host in every shipped file
#      carries `"brand_name": ""`, which is not a data plane and is not in the list, so this
#      refuses all thirteen files -- the M8/M13/M20 shape again, on the vertexType guard.
mutate "door 3e is applied to hosts as well as switches" \
    "$TFM" \
    '        if (vertexType == VertexType::SWITCH)
        {
            if (!(nodeJson.contains("brand_name") && nodeJson.at("brand_name").is_string()))' \
    '        if (true)
        {
            if (!(nodeJson.contains("brand_name") && nodeJson.at("brand_name").is_string()))' \
    TopologyInputValidationTest.AHostBrandNameIsNotChecked \
    TopologyInputValidationTest.EveryShippedTopologyStillLoadsWithNothingDropped

# M23. 🔴 THE FLEET-BREAKING DIRECTION, and the one that reads as a harmless typo fix. One
#      hardware model is misspelled in the accepted list. The two _ipAlias4_HPE_ files stop
#      loading, and -- because DeviceConfigurationAndPowerManager.cpp still branches on the real
#      spelling -- the tripwire that exists for exactly this drift must see it too.
mutate "door 3e: a hardware model is misspelled in the accepted list" \
    "$TFM" \
    '    "HPE5520",        // testbed hardware, SNMP power + temperature' \
    '    "HPE9999",        // testbed hardware, SNMP power + temperature' \
    TopologyInputValidationTest.EveryShippedTopologyStillLoadsWithNothingDropped \
    TopologyInputValidationTest.EveryBrandTheShippedFleetNamesIsAccepted \
    TopologyInputValidationTest.TheAcceptedBrandListCoversEveryBrandTheCodeBranchesOn

# M24. 🔴 THE ADVICE COMES BACK. The file is still refused, and the refusal still names the brand
#      -- but it tells the operator to set ALLOW_MIXED_DATAPLANE, which is what R0b caught the old
#      message doing and is the half of this fix that is about what the message SAYS. Only one
#      case can see it.
mutate "door 3e: the refusal suggests ALLOW_MIXED_DATAPLANE again" \
    "$TFM" \
    '                    ". An unrecognised brand used to be mapped to \"hardware\" silently, which "' \
    '                    ". Fix the topology file, or set AppConfig::ALLOW_MIXED_DATAPLANE to "
                    "override. An unrecognised brand used to be mapped to \"hardware\", which "' \
    TopologyInputValidationTest.TheUnknownBrandRefusalDoesNotSuggestAllowingMixedDataPlanes

# ================================================================================================
# 5e. W15-2 -- the switch_kind exemption, and the mark it costs (M25-M27, added 2026-09-07)
#
# 🔴 THIS HALF REVERSES #91, SO IT HAS TO BE MEASURED IN BOTH DIRECTIONS AT ONCE. Adam ruled on
# 2026-09-06 that a node declaring an explicit, legal `switch_kind` is admitted even when its
# `brand_name` is one this build cannot drive -- and that such a machine must be marked in the
# graph as one whose power and telemetry nobody manages. Two mutations for the two ways to get
# that wrong, and they are opposites:
#   - the exemption is gone      (M25) -- the ruling is not implemented, the Cisco operator is
#                                         still editing C++
#   - the exemption is unconditional (M26) -- #91 is undone: every unrecognised brand is admitted
#                                         again, which is the measured defect verbatim
# and one for the direction that looks like the fix while removing its condition:
#   - the switch is admitted but NOT marked (M27) -- the graph says a switch this build has no
#                                         OID, no login and no plug logic for has a power path.
#     🔴 M27 IS THE ONE THAT MATTERS. A reviewer reading "the file loads now" would call M25/M26
#     the subject of this ruling; the half that is easy to lose is the half nobody sees fail,
#     because a wrong mark on a switch that loads fine looks exactly like a right one.
#
# ⚠️ declaresLegalSwitchKind's OWN strictness (key present, a string, a value switchKindFromString
# accepts) has NO mutation here, and that is a limitation of this gate rather than of the code:
# door 3a runs twenty lines earlier and throws on every malformed switch_kind, so no input can
# reach the predicate with one. AnUnknownBrandWithAMalformedSwitchKindIsStillRefused says the same
# thing from the test side. Reporting a mutation there would be scoring an unreachable branch.
# ================================================================================================

# M25. The exemption is removed: an explicit switch_kind no longer admits an unrecognised brand.
#      The ruling undone, back to #91's cost.
mutate "W15-2: an explicit switch_kind no longer exempts an unrecognised brand" \
    "$TFM" \
    '                !declaresLegalSwitchKind(nodeJson))' \
    '                !(declaresLegalSwitchKind(nodeJson) && false))' \
    TopologyInputValidationTest.AnUnknownBrandWithAnExplicitSwitchKindIsAccepted \
    TopologyInputValidationTest.TheExemptedSwitchIsMarkedAsHavingNoPowerOrTelemetryPath \
    TopologyInputValidationTest.TheExemptionIsPerNodeAndDoesNotUnmarkItsNeighbours \
    TopologyInputValidationTest.TheStaticTopologyEndpointPublishesTheUnmanagedMark

# M26. 🔴 THE EXEMPTION SPREADS TO THE OTHER HALF OF DOOR 3E: a node that declares a switch_kind
#      is let past the `brand_name` PRESENCE check as well. It reads like the same ruling applied
#      consistently, and it is not: the builder reads brand_name with at(), so a node without one
#      throws a raw nlohmann exception from a line further down -- the "the message is an
#      exception class, not a sentence" defect doors 3c/3d/3e were each written to remove.
mutate "W15-2: the exemption also waives the brand_name presence check" \
    "$TFM" \
    '            if (!(nodeJson.contains("brand_name") && nodeJson.at("brand_name").is_string()))' \
    '            if (!(nodeJson.contains("brand_name") && nodeJson.at("brand_name").is_string()) &&
                !declaresLegalSwitchKind(nodeJson))' \
    TopologyInputValidationTest.ASwitchWithASwitchKindStillNeedsABrandName

# M27. 🔴 THE CONDITION, DROPPED. The file loads, the switch is served, and the graph reports the
#      brand's own default path for a brand that has none -- `powerPathForBrandName` replaced by
#      the value an accepted hardware switch would get. Nothing about loading changes, so only
#      the cases that ask what is ON the vertex can see it.
mutate "W15-2: an exempted switch is reported as having a power path" \
    "$TFM" \
    '        vp.powerPath = powerPathForBrandName(vp.brandName);' \
    '        vp.powerPath = "snmp";' \
    TopologyInputValidationTest.TheExemptedSwitchIsMarkedAsHavingNoPowerOrTelemetryPath \
    TopologyInputValidationTest.TheExemptionIsPerNodeAndDoesNotUnmarkItsNeighbours \
    TopologyInputValidationTest.TheStaticTopologyEndpointPublishesTheUnmanagedMark

# ================================================================================================
# 6. the widenings -- these MUST survive
# ================================================================================================

# W1. A comment. If anything reddens here, every catch above is measuring "a file was edited and
#     rebuilt" rather than "the behaviour changed".
widen "a comment, nothing else" \
    "$TFM" \
    '    // The endpoints, indexed exactly the way the edge loop below resolves them: switches by' \
    '    // The endpoints, indexed the way the edge loop below resolves them: switches by'

# W2. The refusal's wording. The tests assert that the offending NUMBER reaches the operator --
#     dpid 99, interface 999999 -- and never the prose. A suite that reddens here would make the
#     next person change a test to improve a message.
widen "the unknown-dpid refusal is reworded" \
    "$TFM" \
    '                    "\" is " + std::to_string(dpid) +
                    " and no switch node in this file declares that dpid. Refusing the file: this "
                    "link used to be dropped with one warning and the rest of the topology served "
                    "as though it were complete");' \
    '                    "\" names dpid " + std::to_string(dpid) +
                    ", which no switch node in this file declares. The file is refused rather "
                    "than loaded without this link.");'

# W3. The dpid lookup written as the negated comparison -- identical semantics, different shape.
#     The control for tests that pin the structure of the check rather than what it decides.
widen "the dpid lookup is written as the negated comparison" \
    "$TFM" \
    '            if (switchDpids.count(dpid) == 0)' \
    '            if (!(switchDpids.count(dpid) > 0))'

# W4. #89's control. The ecmp bound written with the literal instead of the named constant and
#     `< 1` written as `<= 0` -- identical semantics for a signed value, different text in both
#     halves of the condition. If this reddens, M14/M15/M16 are pinning how the bound is spelled
#     rather than where it sits, and "three doors closed" would be a claim about source text.
widen "the ecmp bound is written as the equivalent literal" \
    "$TFM" \
    '                if (portId < 1 || portId > static_cast<std::int64_t>(kMaxTopologyInterface))' \
    '                if (portId <= 0 || portId > 65535)'

# W5. #90's control. `empty()` written as `size() == 0` -- the same predicate, one character away
#     from M20's `size() != 1`. If this reddens, M20 is measuring the spelling of the emptiness
#     test rather than which host counts it refuses.
widen "the host emptiness test is written as size() == 0" \
    "$TFM" \
    '            else if (nodeJson.at("ip").empty())' \
    '            else if (nodeJson.at("ip").size() == 0)'

# W6. #91's control. The membership test written as none_of with an explicit comparison instead of
#     find-against-end: identical semantics, a completely different shape. If this reddens,
#     M21/M23 are pinning how the lookup is spelled rather than which brands it admits.
widen "the brand membership test is written as none_of" \
    "$TFM" \
    '            if (std::find(kAcceptedSwitchBrands.begin(), kAcceptedSwitchBrands.end(), brandName) ==
                    kAcceptedSwitchBrands.end() &&
                !declaresLegalSwitchKind(nodeJson))' \
    '            if (std::none_of(kAcceptedSwitchBrands.begin(),
                             kAcceptedSwitchBrands.end(),
                             [&brandName](std::string_view accepted) {
                                 return accepted == brandName;
                             }) &&
                !declaresLegalSwitchKind(nodeJson))'

# W7. The W15-2 control. The exemption written as two named booleans and a guard instead of one
#     conjunct: the same decision reached by a different route. If this reddens, M25-M27 are
#     pinning how the exemption is spelled rather than which files it admits.
widen "the exemption is written as a separate guard rather than a conjunct" \
    "$TFM" \
    '            if (std::find(kAcceptedSwitchBrands.begin(), kAcceptedSwitchBrands.end(), brandName) ==
                    kAcceptedSwitchBrands.end() &&
                !declaresLegalSwitchKind(nodeJson))' \
    '            const bool brandIsAccepted =
                std::find(kAcceptedSwitchBrands.begin(), kAcceptedSwitchBrands.end(), brandName) !=
                kAcceptedSwitchBrands.end();
            const bool toldExplicitly = declaresLegalSwitchKind(nodeJson);
            if (!brandIsAccepted && !toldExplicitly)'

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
[[ "$ok" == 1 ]] && echo "  all ${#FILES[@]} files byte-identical to the pre-run snapshot"
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
echo "  FINDINGS #61/#62 gate: neither defect can be put back by any of seven routes -- including"
echo "  the two-layer restoration of the measured 40 -> 39 -- a range check that refuses the host"
echo "  side's documented port 0 or the fleet's port 1 is caught, and three behaviour-preserving"
echo "  edits were left alone."
echo "  FINDINGS #89 gate: none of the three node-side refusals can be pushed back into the builder"
echo "  loop without a case going red on vertices == 0 while threw stays true, moving the"
echo "  bridge_name check to the wrong mode is caught by the shipped fleet, the ecmp port_id bound"
echo "  cannot lose either end, and the host side's port-0 exemption cannot be transplanted onto"
echo "  ecmp members -- while writing the same bound as a literal stays green."
echo "  FINDINGS #90 gate: door 3d cannot be switched off, neither of its two plain-language arms"
echo "  can quietly fall back to a raw nlohmann exception, and it cannot narrow to 'exactly one"
echo "  address' without the five _ipAlias4_ files saying so -- while spelling the emptiness test"
echo "  a different way stays green."
echo "  W15-2 gate: the switch_kind exemption cannot be removed, cannot spread to the brand_name"
echo "  presence check, and cannot admit a switch without marking it power_path/telemetry_path"
echo "  none -- while writing the exemption as two named booleans and a guard stays green."
echo "  FINDINGS #91 gate: an unknown brand_name cannot be admitted again, the refusal cannot"
echo "  start suggesting ALLOW_MIXED_DATAPLANE, the accepted list cannot be applied to hosts, and"
echo "  it cannot lose a hardware model without both the shipped fleet and the brand-drift"
echo "  tripwire saying so -- while writing the membership test as none_of stays green."
exit 0
