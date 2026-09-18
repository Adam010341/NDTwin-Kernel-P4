#!/usr/bin/env bash
#
# Mutation gate for TICKET-P3 section 3.4: the FlowKey families, the ihl-derived L4 offset, and
# which of the two byte banks a sample lands in.
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration. This applies each mutation the design
# is supposed to be protected against, rebuilds, and records WHICH named test went red -- never
# merely that something did. The framework is tests/shell/mutate_bx_flow_liveness.sh's, with one
# difference that is not optional here:
#
# 🔴 EVERY BUILD GOES THROUGH tools/build_guard/guarded_build.sh WITH JOBS=1.
# A bare `cmake --build` on this laptop is what systemd-oomd killed on 2026-09-02, taking the
# user's own application with it (README and doc/audit/2026-09-02*). The guard is re-entrant, so
# running this script under an outer guard is safe and does not deadlock.
#
# ⏱  Four of the eight mutations are in include/common_types/SFlowType.hpp, which ~46 translation
# units include, and at JOBS=1 each of those is a multi-minute rebuild. Budget most of an hour.
# The two .cpp-only mutations rebuild one file. That asymmetry is why section 3.4 caps this at
# six mutations.
#
# Usage:  tests/shell/mutate_flowkey_families.sh
#   BUILD_DIR=build       configured build directory (ninja), relative to the worktree root
#   TEST_TIMEOUT=600      seconds allowed per test-binary run
#
# Exit: 0 all mutations caught and both controls survived
#       1 at least one mutation survived
#       2 the gate cannot render a verdict (baseline red, anchor drift, hang, failed restore, or
#         a control going red -- which would mean this gate measures "the file changed" rather
#         than "the behaviour changed")
set -uo pipefail

# 🔴 The worktree this script lives in, and no other. `git rev-parse --show-toplevel` answers
# about the CALLER's directory, so launching this from the main checkout -- which is trivially
# easy with a `setsid nohup bash <abs path>` and is how it was first run -- makes it snapshot and
# mutate a shared checkout that several sessions have uncommitted work in. The anchor check
# happens to refuse there (a tree without these changes has none of the anchors), but "it would
# have failed anyway" is not a protection, and the next anchor to become common to both trees
# removes it. CLAUDE.md's shared-worktree rule is the reason this is an abort and not a warning.
OWN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" # tests/shell/ -> the worktree root
cd "$(git rev-parse --show-toplevel)" || exit 2
if [[ "$PWD" != "$OWN_ROOT" ]]; then
    echo "🔴 refusing to run: git says the top level here is" >&2
    echo "     $PWD" >&2
    echo "   but this script belongs to" >&2
    echo "     $OWN_ROOT" >&2
    echo "   Run it from inside its own worktree. A mutation gate must never edit another" >&2
    echo "   checkout's files." >&2
    exit 2
fi

BUILD_DIR="${BUILD_DIR:-build}"
TEST_TIMEOUT="${TEST_TIMEOUT:-600}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
GUARD=tools/build_guard/guarded_build.sh

SFLOW=include/common_types/SFlowType.hpp
COLL=src/ndt_core/collection/FlowLinkUsageCollector.cpp
FILES=("$SFLOW" "$COLL")

# --- 0. self-check ------------------------------------------------------------------------------
if ! bash -n "${BASH_SOURCE[0]}"; then
    echo "🔴 this script does not parse" >&2; exit 2
fi
command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
[[ -d "$BUILD_DIR" ]] || { echo "🔴 no configured build dir at '$BUILD_DIR'" >&2; exit 2; }
[[ -x "$GUARD" ]] || { echo "🔴 $GUARD is missing: this gate must not build bare" >&2; exit 2; }

# --- 1. anchors ---------------------------------------------------------------------------------
# Declared before anything is touched, and every one must appear EXACTLY once. An anchor matching
# twice would mutate a site the mutation was not named for; an anchor matching zero times means
# the source moved under the gate, and "the mutation could not be applied" must never be reported
# as "the mutation was caught".
declare -a ANCHOR_FILE ANCHOR_TEXT ANCHOR_NAME
add_anchor() { ANCHOR_NAME+=("$1"); ANCHOR_FILE+=("$2"); ANCHOR_TEXT+=("$3"); }

BANK_GUARD='            if (m_mode == utils::MININET)
            {
                std::unique_lock<std::shared_mutex> lk(m_counterReportsMutex);'
EGRESS_ONLY='                else if (outputPort != 0)'
IPV6_BRANCH='    if (ethType == kEtherTypeIpv6)'
IHL_OFFSET='        const size_t ipHeaderBytes = static_cast<size_t>(out.ipv4Ihl) * 4;'
L2_COUNTER='    case FlowKeyFamily::L2:
        m_samplesL2.fetch_add(1, std::memory_order_relaxed);
        break;'
MAC_HASH='        hashCombine(seed, key.srcMac);
        hashCombine(seed, key.dstMac);'
IPV4_CLEARS_L2='        out.key = FlowKey{};
        out.key.family = FlowKeyFamily::IPv4;'
CONTROL_CPP='// [Co-developed with claude code -- Adam] TICKET-P3 §2.3.
void
FlowLinkUsageCollector::noteFrameIdentity'
CONTROL_HDR='inline FrameIdentity
identifyFrame(const uint8_t* frame, size_t length)'

add_anchor "bank-guard"    "$COLL"  "$BANK_GUARD"
add_anchor "egress-only"   "$COLL"  "$EGRESS_ONLY"
add_anchor "l2-counter"    "$COLL"  "$L2_COUNTER"
add_anchor "control-cpp"   "$COLL"  "$CONTROL_CPP"
add_anchor "ipv6-branch"   "$SFLOW" "$IPV6_BRANCH"
add_anchor "ihl-offset"    "$SFLOW" "$IHL_OFFSET"
add_anchor "mac-hash"      "$SFLOW" "$MAC_HASH"
add_anchor "ipv4-clears-l2" "$SFLOW" "$IPV4_CLEARS_L2"
add_anchor "control-hdr"   "$SFLOW" "$CONTROL_HDR"

# 🔴 `grep -cF` is the WRONG TOOL for a multi-line anchor and it fails in the direction that hides
# the problem: grep splits an -F pattern on newlines and counts LINES matching any piece. The
# exact substring count comes from python; the grep number is printed beside it as a cross-check
# on the anchor's FIRST LINE only, which is the question grep can answer.
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
    g=$(/usr/bin/grep -cF -- "$first" "${ANCHOR_FILE[$i]}")
    printf '  %-14s %-52s exact=%s  grep(first line)=%s\n' \
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

# Which files this run has written since the last restore. Maintained at the three `apply`
# call sites -- see the note above apply() for why it cannot live inside it.
DIRTY=()

restore() {
    local f
    for f in "${FILES[@]}"; do
        cp -p "${SNAP[$f]}" "$f"
        # `cp -p` puts the ORIGINAL mtime back, which is older than the object built from the
        # mutant -- so ninja sees nothing to do and the NEXT mutation is measured against a binary
        # that still contains the previous one, while the source on disk looks pristine. The
        # sha256 check below passes either way, because it checks the file and not the artifact.
        #
        # Only the file this run actually wrote needs it, and that distinction is worth making
        # here: SFlowType.hpp is included by ~46 translation units, so touching it for a mutation
        # that lives in the .cpp doubled the wall clock of every single step -- the first full run
        # took 1h45m, and a run that long is how the 05:34 disk-full incident got to interrupt one
        # halfway through. A file nobody wrote still has a correct object.
        # [Co-developed with claude code -- Adam] Round 2.
        if [[ " ${DIRTY[*]-} " == *" $f "* ]]; then
            touch "$f"
        fi
    done
    DIRTY=()
}
trap 'restore; rm -rf "$BK"' EXIT

BIN_SHA_BEFORE="(absent)"
[[ -f "$BIN" ]] && BIN_SHA_BEFORE=$(sha256sum "$BIN" | cut -c1-16)

# --- 3. build + run helpers ---------------------------------------------------------------------
build() {
    JOBS=1 LOCK_WAIT=10800 "$GUARD" cmake --build "$BUILD_DIR" --target "$TARGET" >/dev/null 2>&1
}

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

is_red() {
    [[ " $FAILED " == *" $1 "* ]] && return 0
    [[ "$STATUS" == crash && "$CRASHED_IN" == "$1" ]] && return 0
    return 1
}

# The suites this gate reasons about. A pre-existing red anywhere else cannot change a verdict
# below, but a red INSIDE this scope means the expected-red names cannot be trusted.
SCOPE='FlowKeyFamiliesTest.*:SFlowParsingFixture.*:LastHopAttributionTest.*:GoldenFixtureTest.*:EmitterRoundtripTest.*'
in_scope() {
    case "$1" in
        FlowKeyFamiliesTest.*|SFlowParsingFixture.*|LastHopAttributionTest.*|GoldenFixtureTest.*|EmitterRoundtripTest.*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- 4. baseline --------------------------------------------------------------------------------
echo
echo "=== baseline (unmutated working tree) must build and be green ==="
if ! build; then
    echo "🔴 THE BASELINE DOES NOT COMPILE. Nothing below means anything." >&2
    JOBS=1 LOCK_WAIT=10800 "$GUARD" cmake --build "$BUILD_DIR" --target "$TARGET" 2>&1 | tail -40 >&2
    exit 2
fi
run_tests '*'
case "$STATUS" in
  pass)  echo "  ok       baseline green ($(/usr/bin/grep -c '^\[       OK \]' <<<"$OUT") cases)" ;;
  crash) echo "🔴 BASELINE DIED OF SIGNAL $((RC-128)) while running: ${CRASHED_IN:-<unknown>}" >&2
         exit 2 ;;
  hang)  echo "🔴 BASELINE HUNG (>${TEST_TIMEOUT}s). Not a red; the gate cannot proceed." >&2
         exit 2 ;;
  *)     scope_red=0
         echo "  baseline is NOT fully green. Failing tests:"
         for t in $FAILED; do
             if in_scope "$t"; then echo "     🔴 IN SCOPE      $t"; scope_red=1
             else echo "     ⚠️  out of scope  $t"; fi
         done
         if [[ "$scope_red" == 1 ]]; then
             echo "🔴 A test this gate depends on is already red before any mutation." >&2
             exit 2
         fi
         echo "  ⚠️  proceeding: every red is outside $SCOPE, so it cannot affect the verdicts"
         echo "     below -- but SOMEONE MUST FIX THE ABOVE."
         ;;
esac

# --- 5. mutations -------------------------------------------------------------------------------
MUTATIONS=0
SURVIVORS=0

# apply <file> <old> <new> -- python does the replace so the anchor is matched LITERALLY,
# newlines and all, and re-asserts its own count at the moment of writing.
#
# 🔴 apply()'s BODY IS THE PYTHON HEREDOC AND NOTHING ELSE. check_gate_anchors.py recognises a
# `NAME+=("$1")` statement inside a function as a mutation-table BUILDER, so recording the dirty
# file in here -- the obvious place -- made the tool classify apply() as a table it could not find
# call sites for, and it reported this whole gate as UNPARSED (which is exit 2, "not checked",
# not a caveat on a pass). The bookkeeping lives at the three call sites instead.
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
    # See apply(): the dirty-file bookkeeping lives at the call sites, so restore() knows which
    # file to touch without apply() looking like a table builder to check_gate_anchors.py.
    DIRTY+=("$file")
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

# M-A1. 🔑 THE ONE THE TICKET IS ABOUT. The byte counter goes back under the frame's identity, so
# a link carrying ARP, LLDP, IPv6 or an exercise's own ethertype publishes 0 bps again -- which is
# bit-identical, to every consumer, to an idle link. This is the pre-P3 behaviour: the counter sat
# below an ethertype test that `continue`d the sample.
mutate "M-A1 link bytes are banked only for IPv4 frames (identity before bytes)" "$COLL" \
"$BANK_GUARD" \
'            if (m_mode == utils::MININET && identity.key.family == FlowKeyFamily::IPv4)
            {
                std::unique_lock<std::shared_mutex> lk(m_counterReportsMutex);' \
    FlowKeyFamiliesTest.AnArpSampleBanksItsLinkBytesAndIsObservedAsL2 \
    FlowKeyFamiliesTest.ACustomEtherTypeSampleBanksItsLinkBytesAndIsObservedAsL2 \
    FlowKeyFamiliesTest.AnIpv6UdpSampleIsObservedWithItsAddressesAndPorts

# M-A2. The egress-only branch is skipped, so the sample falls through to the both-ports-zero
# arm and is banked in m_counterReports keyed by its OUTPUT port -- exactly the dead branch
# section 2.2 replaces. The drain then credits the edge pointing the other way.
mutate "M-A2 an egress-only sample goes back into the ingress bank" "$COLL" \
"$EGRESS_ONLY" \
'                else if (false && outputPort != 0)' \
    FlowKeyFamiliesTest.AnEgressOnlySampleCreditsTheEgressBankAndOnlyThat \
    FlowKeyFamiliesTest.TheTwoHalvesOfADualPortSampleAreTheTwoOneSidedSamples \
    LastHopAttributionTest.AnIngressLessSampleIsBankedOnceAndOnTheEgressSide

# M-A5 (out of numeric order: it is the second .cpp-only mutation, and .cpp mutations rebuild one
# file instead of forty-six). The L2 family stops being counted, so samples_by_family under-reports
# exactly the traffic the counters were added for.
mutate "M-A5 samples_by_family does not count the L2 family" "$COLL" \
"$L2_COUNTER" \
'    case FlowKeyFamily::L2:
        break;' \
    FlowKeyFamiliesTest.AnArpSampleBanksItsLinkBytesAndIsObservedAsL2 \
    FlowKeyFamiliesTest.TheStatsObjectCarriesEveryFamilyAndTheNonIpv4Identities \
    FlowKeyFamiliesTest.RepeatedFramesOfOneIdentityAccumulateOnOneRow

# M-A3. IPv6 degrades to the L2 family: the addresses and the upper-layer ports are dropped and
# every IPv6 flow collapses onto one key per MAC pair.
mutate "M-A3 the IPv6 family falls back to L2" "$SFLOW" \
"$IPV6_BRANCH" \
'    if (false && ethType == kEtherTypeIpv6)' \
    FlowKeyFamiliesTest.AnIpv6UdpSampleIsObservedWithItsAddressesAndPorts \
    SFlowParsingFixture.AFullIpv6ExtensionChainResolvesToTheUpperLayerPorts

# M-A4. The header length is ignored and the L4 offset goes back to the constant 20 bytes, which
# is what read mri's IPv4 option bytes as ports.
mutate "M-A4 the IPv4 L4 offset ignores ihl" "$SFLOW" \
"$IHL_OFFSET" \
'        const size_t ipHeaderBytes = 20;' \
    FlowKeyFamiliesTest.Ipv4OptionsMoveThePortsAndTheParserFollowsThem

# M-A6. The L2 family's hash stops looking at the MACs. Nothing fails at runtime -- operator==
# still separates the keys -- so only a direct assertion on the hash can see this.
mutate "M-A6 the L2 hash ignores the MAC addresses" "$SFLOW" \
"$MAC_HASH" \
'        (void)key.srcMac;
        (void)key.dstMac;' \
    FlowKeyFamiliesTest.TwoL2KeysDifferingOnlyInTheirMacsHashDifferently

# M-A7. 🔑 ROUND 2, THE ONE THE JUDGE FOUND. The IPv4 branch stops clearing the L2 fields, so an
# IPv4 key carries the frame's MAC addresses again -- and this fabric rewrites both at every hop,
# so one flow becomes one flow-table row per hop. Added rather than swapped in: the seventh
# mutation costs one more rebuild of SFlowType.hpp, which the round-2 `restore` change (touch only
# what was written) more than pays for.
mutate "M-A7 the IPv4 branch keeps the MAC addresses of the frame" "$SFLOW" \
"$IPV4_CLEARS_L2" \
'        out.key.family = FlowKeyFamily::IPv4;' \
    FlowKeyFamiliesTest.OneIpv4FlowStaysOneRowWhenTheMacsChangeAtEveryHop \
    FlowKeyFamiliesTest.TheParsersOwnIpv4KeyCarriesNoL2Fields

# --- 6. negative controls -----------------------------------------------------------------------
# One per file. They must SURVIVE. If the suite goes red on a comment, the gate above is measuring
# "a file was edited and rebuilt" rather than "the behaviour changed", and every ✅ is worthless.
# Two of them rather than one because the two files rebuild through completely different amounts
# of the project -- one translation unit against forty-six -- and a rebuild that large is its own
# opportunity for something stale to be picked up.
#
# 🔴 THE CONTROLS CALL `apply` DIRECTLY, AT THE CALL SITE, and that shape is load-bearing.
# tests/shell/check_gate_anchors.py reads gate scripts statically to answer "can this gate still
# find the text it mutates"; it understands `apply <file> <old> <new>` and the `mutate` table, and
# it read the first draft's `run_control <label> <file> <old> <new>` wrapper positionally --
# taking the label's successor as the file and the replacement as the anchor, reporting MISSING:1
# for an anchor that is present. A gate whose anchors that tool cannot count is a gate nobody is
# watching for drift, which is the entire failure mode it exists to catch, so the wrapper is gone
# and only the verdict-classifying half of it remains.
CONTROL_BAD=0

# classify_control -- everything a control does EXCEPT naming a file or an anchor.
classify_control() {
    if ! build; then
        echo "  🔴 CONTROL DOES NOT COMPILE -- a comment broke the build; the anchor is wrong"
        CONTROL_BAD=1; restore; return
    fi
    run_tests "$SCOPE"
    case "$STATUS" in
      pass)  echo "  ✅ survived -- a comment changes nothing, so the catches above are about behaviour" ;;
      crash) echo "  🔴 CONTROL DIED OF SIGNAL $((RC-128)) in ${CRASHED_IN:-<unknown>}"; CONTROL_BAD=1 ;;
      hang)  echo "  🔴 CONTROL HUNG"; CONTROL_BAD=1 ;;
      *)     echo "  🔴 CONTROL WENT RED: $FAILED"
             echo "     This gate cannot tell an edit from a behaviour change. Every catch above is void."
             CONTROL_BAD=1 ;;
    esac
    restore
}

printf '\n=== CONTROL (comment in the collector -- MUST survive) ===\n'
DIRTY+=("$COLL")
if apply "$COLL" \
"$CONTROL_CPP" \
'// mutation-gate negative control: text with no behaviour
// [Co-developed with claude code -- Adam] TICKET-P3 §2.3.
void
FlowLinkUsageCollector::noteFrameIdentity'; then
    classify_control
else
    echo "  🔴 CONTROL anchor could not be applied"; CONTROL_BAD=1; restore
fi

printf '\n=== CONTROL (comment in SFlowType.hpp -- MUST survive) ===\n'
DIRTY+=("$SFLOW")
if apply "$SFLOW" \
"$CONTROL_HDR" \
'// mutation-gate negative control: text with no behaviour
inline FrameIdentity
identifyFrame(const uint8_t* frame, size_t length)'; then
    classify_control
else
    echo "  🔴 CONTROL anchor could not be applied"; CONTROL_BAD=1; restore
fi

# --- 7. verdict ---------------------------------------------------------------------------------
# One rebuild after the final restore, and its result is CHECKED. `build || true` would leave the
# next gate running against a binary built from the last mutant while every file on disk looked
# pristine -- the same failure `touch` exists to prevent, one level up.
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
[[ "$ok" == 1 ]] && echo "  both files byte-identical to the pre-run snapshot"
if [[ "$REBUILD_OK" == 1 ]]; then
    echo "  rebuilt from the restored tree"
else
    echo "  🔴 THE RESTORED TREE DOES NOT BUILD -- the binary on disk is whatever the last"
    echo "     mutation left. Do not run another gate against it."
    ok=0
fi
echo "  test binary: $(sha256sum "$BIN" 2>/dev/null | cut -c1-16) (was $BIN_SHA_BEFORE)"

printf '\n=== verdict ===\n'
printf '  %d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"
[[ "$CONTROL_BAD" == 1 ]] && echo "  a control FAILED -- the gate has no discriminating power"

if [[ "$ok" != 1 || "$CONTROL_BAD" == 1 ]]; then exit 2; fi
if (( SURVIVORS > 0 )); then exit 1; fi
exit 0
