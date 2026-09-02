#!/usr/bin/env bash
#
# Mutation gate for F-8 -- `left_link_bandwidth_bps` must carry the topology's declared capacity,
# and "never sampled" must not be able to pass itself off as "sampled and idle".
#
# [Co-developed with claude code -- Adam]
#
# Covers tests/test_LeftBandwidthCapacity.cpp and the two GraphDataHeadroomTest cases in
# tests/test_HttpSessionRouting.cpp. Every test in those files was written in a worktree
# forbidden from building, so NONE of them had been seen red or green when they were committed.
# This script is what converts that table of claims into evidence: each mutation names the single
# line it reverts AND the test that must be the one to go red. "The gate turned red" is not the
# check; WHICH light turned red is -- two tests in this project have previously gone red on a
# mutation aimed at a different behaviour.
#
# A mutant that does not compile is counted as a SURVIVOR, not waved through: the suite never
# ran, so it proves nothing about the tests. Same for an anchor that has moved.
#
# 🔴 Guards its own baseline: five files are snapshotted before anything is touched, an EXIT trap
# restores them however the script leaves, and the run ends by asserting byte-identity against
# the snapshot. cp -p restores the ORIGINAL mtime, which is older than the object built from the
# mutant -- ninja would then see nothing to do and the next run would test a mutant while the
# source on disk looked pristine -- so every restore also touches the file.
#
# Usage:  tests/shell/mutate_f8_declared_link_capacity.sh
#         BUILD_DIR=out tests/shell/mutate_f8_declared_link_capacity.sh
#
# Exit:   0  every mutation caught by its named test, control clean, baseline restored
#         1  at least one mutation survived, or the comment-only control went red
#         2  refused: baseline red, build dir not configured, anchor moved, or restore failed
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
FILTER='LeftBandwidthCapacityTest.*:LeftBandwidthDefaultTest.*:GraphDataHeadroomTest.*'

GT=include/common_types/GraphTypes.hpp
TAFM=src/ndt_core/collection/TopologyAndFlowMonitor.cpp
HS=src/ndt_core/http/HttpSession.cpp
SPEC=tools/contract_test/spec.py
FIXTURE=tools/contract_test/selftest_fixtures.py
FILES=("$GT" "$TAFM" "$HS" "$SPEC" "$FIXTURE")

MUTATIONS=0
SURVIVORS=0
CONTROL_FAILED=0
PY_FAILED=0

# --- snapshot + restore ------------------------------------------------------------------------

BK=$(mktemp -d)
snap() { echo "$BK/$(basename "$1").$(echo "$1" | md5sum | cut -c1-6)"; }
for f in "${FILES[@]}"; do cp -p "$f" "$(snap "$f")"; done

restore() {
    local f bad=0
    for f in "${FILES[@]}"; do
        cp -p "$(snap "$f")" "$f"
        # The mtime came back with the content; ninja compares mtimes, so say the file is new.
        touch "$f"
        cmp -s "$(snap "$f")" "$f" || { echo "🔴 RESTORE FAILED: $f. Do NOT commit." >&2; bad=1; }
    done
    return "$bad"
}
trap 'restore || true; rm -rf "$BK"' EXIT

# --- helpers ------------------------------------------------------------------------------------

build() { cmake --build "$BUILD_DIR" --target "$TARGET" -j4 >/dev/null 2>&1; }

# Names of the tests that failed, deduplicated. rc is captured from the binary itself, never
# through a pipe -- a pipeline's rc belongs to the last stage, and every filter here exits 0.
reds() {
    local out
    out=$("$BIN" --gtest_filter="$FILTER" 2>&1)
    printf '%s' "$out" |
        sed -n 's/^\[  FAILED  \] \([A-Za-z0-9_]*\.[A-Za-z0-9_]*\).*/\1/p' | sort -u | tr '\n' ' '
}

# $1 = label, $2 = the test that must go red, $3 = python mutation program (on stdin)
mutate() {
    local label="$1" expect="$2" prog="$3" failed
    MUTATIONS=$((MUTATIONS + 1))
    printf '\n  --- %s\n      expect red: %s\n' "$label" "$expect"

    if ! python3 - "$GT" "$TAFM" "$HS" <<<"$prog"; then
        printf '      SURVIVED  the anchor has moved -- mutation never applied, so it proves nothing\n'
        SURVIVORS=$((SURVIVORS + 1)); restore || exit 2; return
    fi
    if ! build; then
        printf '      SURVIVED  the mutant does not compile -- the suite never ran\n'
        SURVIVORS=$((SURVIVORS + 1)); restore || exit 2; return
    fi

    failed=$(reds)
    if [[ -z "$failed" ]]; then
        printf '      SURVIVED  nothing went red -- that behaviour is untested\n'
        SURVIVORS=$((SURVIVORS + 1))
    elif grep -qF "$expect" <<<"$failed"; then
        printf '      caught    red: %s\n' "$failed"
    else
        printf '      SURVIVED  WRONG TEST WENT RED: got [%s], expected [%s]\n' "${failed% }" "$expect"
        printf '                the gate fires, but not for the reason the header claims\n'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore || exit 2
}

# =================================================================================================
# Phase 0 -- preflight: this script parses, and every anchor it edits occurs exactly once
# =================================================================================================
echo "=== phase 0: preflight ==="
if bash -n "${BASH_SOURCE[0]}"; then echo "  ok       bash -n: this script parses"
else echo "  REFUSE: this script does not parse"; exit 2; fi

anchor_ok=1
check_anchor() {   # $1 = file, $2 = literal anchor
    local n; n=$(grep -cF -- "$2" "$1")
    printf '  %-6s %-56s x%s  in %s\n' \
        "$([[ "$n" == 1 ]] && echo ok || echo REFUSE)" "$(cut -c1-56 <<<"$2")" "$n" "$1"
    [[ "$n" == 1 ]] || anchor_ok=0
}
check_anchor "$GT"      'uint64_t leftBandwidthFromFlowSample = 0;'
check_anchor "$TAFM"    '        ep.leftBandwidthFromFlowSample = ep.linkBandwidth;'
check_anchor "$TAFM"    '        ep.leftBandwidthSource = BandwidthSource::Declared;'
check_anchor "$TAFM"    '        edgeProps.leftBandwidthSource = BandwidthSource::Measured;'
check_anchor "$HS"      '             {"left_link_bandwidth_source", toString(e.leftBandwidthSource)},'
check_anchor "$TAFM"    '        // F-8. The declared capacity was already being read on the line above and handed to'
check_anchor "$SPEC"    '             "left_link_bandwidth_source": Str(allowed=("declared", "measured", "unknown"))})'
check_anchor "$FIXTURE" '"left_link_bandwidth_source": "measured"'
if [[ "$anchor_ok" != 1 ]]; then
    echo "  REFUSE: an anchor is missing or ambiguous. A mutation that cannot be applied is not a pass." >&2
    exit 2
fi

# =================================================================================================
# Phase 1 -- the /ndt/ contract half. Pure Python: NO BUILD, so it runs even if the compiler
# window is shut. Proves the new key's vocabulary guard is load-bearing rather than decorative.
# =================================================================================================
echo
echo "=== phase 1: contract schema (no build required) ==="
CT=(python3 tools/contract_test/run_contract_test.py --self-test)

"${CT[@]}" >/dev/null 2>&1; rc=$?
if [[ "$rc" == 0 ]]; then echo "  ok       baseline self-test green (rc=0)"
else echo "  🔴 FAIL   baseline self-test is not green (rc=$rc)"; PY_FAILED=1; fi

# force-red: a value outside the three-word vocabulary must be rejected, and named.
sed -i 's/"left_link_bandwidth_source": "measured"/"left_link_bandwidth_source": "definitely"/' "$FIXTURE"
out=$("${CT[@]}" 2>&1); rc=$?
if [[ "$rc" != 0 ]] && grep -qF "left_link_bandwidth_source: expected one of" <<<"$out"; then
    echo "  ok       force-red: an illegal provenance value is rejected (rc=$rc), and named"
else
    echo "  🔴 FAIL   an illegal provenance value was NOT rejected (rc=$rc)"; PY_FAILED=1
fi

# The half that matters: with the SAME illegal value in place, remove the guard. If the run still
# passes, the guard is what was doing the work. If it fails anyway, something else is catching it
# and this check has been measuring the wrong thing all along.
python3 - "$SPEC" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = ('}, optional={"left_link_bandwidth_bps": Num(),\n'
       '             "left_link_bandwidth_source": Str(allowed=("declared", "measured", "unknown"))})')
new = '}, optional={"left_link_bandwidth_bps": Num()})'
assert s.count(old) == 1, "spec.py anchor missing or ambiguous"
p.write_text(s.replace(old, new, 1))
PYEOF
"${CT[@]}" >/dev/null 2>&1; rc=$?
if [[ "$rc" == 0 ]]; then
    echo "  ok       guard removed: the illegal value passes silently (rc=0) -- the guard is load-bearing"
else
    echo "  🔴 FAIL   the illegal value is caught even without the guard (rc=$rc) -- this check"
    echo "            has not been proving what it claims"; PY_FAILED=1
fi

restore || exit 2
"${CT[@]}" >/dev/null 2>&1; rc=$?
if [[ "$rc" == 0 ]]; then echo "  ok       restored: self-test green again (rc=0)"
else echo "  🔴 FAIL   self-test not green after restore (rc=$rc)"; PY_FAILED=1; fi

# =================================================================================================
# Phase 2 -- baseline. A gate run against a red baseline reports nothing at all.
# =================================================================================================
echo
echo "=== phase 2: baseline ==="
if [[ ! -f "$BUILD_DIR/CMakeCache.txt" ]]; then
    echo "  REFUSE: $BUILD_DIR is not a configured build dir. Configure it first, or pass BUILD_DIR=." >&2
    exit 2
fi
if ! build; then
    echo "  REFUSE: the unmutated tree does not build. Nothing below would mean anything." >&2
    cmake --build "$BUILD_DIR" --target "$TARGET" -j4 2>&1 | tail -30 >&2
    exit 2
fi
[[ -x "$BIN" ]] || { echo "  REFUSE: $BIN is missing after a successful build." >&2; exit 2; }

BIN_SHA_BEFORE=$(sha256sum "$BIN" | cut -c1-16)
baseline_red=$(reds)
if [[ -n "$baseline_red" ]]; then
    echo "  REFUSE: the baseline is already red. These tests failed before any mutation:" >&2
    for t in $baseline_red; do echo "            $t" >&2; done
    exit 2
fi
echo "  ok       baseline green (filter: $FILTER)"
echo "  ok       $TARGET sha256 $BIN_SHA_BEFORE"

# =================================================================================================
# Phase 3 -- the mutations. One per row of the table in test_LeftBandwidthCapacity.cpp's header.
# =================================================================================================
echo
echo "=== phase 3: mutations ==="

# 1. F-8 EXACTLY AS IT SHIPPED. The loader reads link_bandwidth_bps and hands it to leftBandwidth
#    -- the field TESTBED mode reports -- while leftBandwidthFromFlowSample, the field MININET
#    mode reports, keeps its 1 Gbit/s in-class initialiser. Both halves are reverted, because
#    dropping the loader line alone would leave the field at 0 rather than at the sentinel, and
#    the defect being reproduced is specifically "a plausible number nobody measured".
mutate "declared capacity reaches leftBandwidth only; MININET field left at the sentinel" \
       "LeftBandwidthCapacityTest.ADeclaredTenGigabitLinkAdvertisesTenGigabitsBeforeAnySample" '
import sys, pathlib
gt, tafm = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
s = gt.read_text()
old = "uint64_t leftBandwidthFromFlowSample = 0;"
new = "uint64_t leftBandwidthFromFlowSample = MININET_INTERFACE_SPEED;"
assert s.count(old) == 1, "GraphTypes anchor missing"
gt.write_text(s.replace(old, new, 1))
t = tafm.read_text()
drop = "        ep.leftBandwidthFromFlowSample = ep.linkBandwidth;\n"
assert t.count(drop) == 1, "loader anchor missing"
tafm.write_text(t.replace(drop, "", 1))
'

# 2. The provenance never advances: a figure derived from sampled bytes is still labelled
#    Declared. A measured edge has to be caught calling itself unmeasured.
mutate "BandwidthSource is always Declared, even after a flow sample" \
       "LeftBandwidthCapacityTest.TheFirstFlowSampleTurnsDeclaredIntoMeasured" '
import sys, pathlib
tafm = pathlib.Path(sys.argv[2]); t = tafm.read_text()
old = "        edgeProps.leftBandwidthSource = BandwidthSource::Measured;"
new = "        edgeProps.leftBandwidthSource = BandwidthSource::Declared;"
assert t.count(old) == 1, "rate-path anchor missing or ambiguous"
tafm.write_text(t.replace(old, new, 1))
'

# 3. The number goes out with no provenance beside it -- which is the state every consumer was
#    in before this fix, and which no amount of correct arithmetic makes readable.
mutate "get_graph_data omits the left_link_bandwidth_source key" \
       "GraphDataHeadroomTest.TheHeadroomFigureCarriesItsProvenance" '
import sys, pathlib
hs = pathlib.Path(sys.argv[3]); s = hs.read_text()
old = "             {\"left_link_bandwidth_source\", toString(e.leftBandwidthSource)},\n"
assert s.count(old) == 1, "HttpSession anchor missing"
hs.write_text(s.replace(old, "", 1))
'

# 4. THE WORST SHAPE THIS DEFECT CAN TAKE: the hardcoded 1 Gbit/s is still what an unsampled edge
#    publishes, and it is now stamped Measured. A fabricated figure wearing a measurement badge is
#    strictly worse than the original bug, because the field added to expose it now vouches for it.
mutate "the 1 Gbit/s sentinel is published stamped Measured" \
       "LeftBandwidthCapacityTest.AnUnsampledEdgeIsNotReportedAsMeasured" '
import sys, pathlib
gt, tafm = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
s = gt.read_text()
old = "uint64_t leftBandwidthFromFlowSample = 0;"
new = "uint64_t leftBandwidthFromFlowSample = MININET_INTERFACE_SPEED;"
assert s.count(old) == 1, "GraphTypes anchor missing"
gt.write_text(s.replace(old, new, 1))
t = tafm.read_text()
drop = "        ep.leftBandwidthFromFlowSample = ep.linkBandwidth;\n"
stamp = "        ep.leftBandwidthSource = BandwidthSource::Declared;"
assert t.count(drop) == 1 and t.count(stamp) == 1, "loader anchors missing"
t = t.replace(drop, "", 1)
tafm.write_text(t.replace(stamp, "        ep.leftBandwidthSource = BandwidthSource::Measured;", 1))
'

# =================================================================================================
# Phase 4 -- negative control. Changing only a comment must change nothing. Without this, a suite
# that fails for an unrelated reason (a flaky fixture, a stale object) would read as four caught
# mutations, and every line above would be a false positive.
# =================================================================================================
echo
echo "=== phase 4: comment-only control (must stay GREEN) ==="
python3 - "$TAFM" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = "        // F-8. The declared capacity was already being read on the line above and handed to"
new = "        // F-8. The declared capacity was already read on the line above and handed to"
assert s.count(old) == 1, "comment anchor missing"
p.write_text(s.replace(old, new, 1))
PYEOF
if ! build; then
    echo "  🔴 FAIL   a comment-only edit broke the build"; CONTROL_FAILED=1
else
    ctl=$(reds)
    if [[ -z "$ctl" ]]; then
        echo "  ok       nothing went red -- the reds above are attributable to the code, not to noise"
    else
        echo "  🔴 FAIL   a comment-only edit turned tests red: $ctl"
        echo "            every 'caught' above is suspect until this is explained"
        CONTROL_FAILED=1
    fi
fi
restore || exit 2

# =================================================================================================
# Phase 5 -- put the tree back, prove it, and say what the run established
# =================================================================================================
echo
echo "=== phase 5: restore and verdict ==="
identical=1
for f in "${FILES[@]}"; do
    cmp -s "$(snap "$f")" "$f" || { echo "  🔴 NOT RESTORED: $f"; identical=0; }
done
if [[ "$identical" == 1 ]]; then
    echo "  ok       all ${#FILES[@]} files byte-identical to the pre-run snapshot"
else
    echo "  REFUSE: the working tree still holds a mutant. Do NOT commit." >&2
    exit 2
fi

if ! build; then
    echo "  REFUSE: the restored tree does not build." >&2; exit 2
fi
after=$(reds)
if [[ -n "$after" ]]; then
    echo "  REFUSE: the suite is red after restore -- a mutant object is still linked in:" >&2
    for t in $after; do echo "            $t" >&2; done
    exit 2
fi
echo "  ok       suite green again after restore"
echo "  ok       $TARGET sha256 $(sha256sum "$BIN" | cut -c1-16) (was $BIN_SHA_BEFORE)"

echo
echo "$MUTATIONS mutations, $SURVIVORS survived"
[[ "$CONTROL_FAILED" == 1 ]] && echo "comment-only control: FAILED"
[[ "$PY_FAILED" == 1 ]] && echo "contract schema gate: FAILED"
if [[ "$SURVIVORS" == 0 && "$CONTROL_FAILED" == 0 && "$PY_FAILED" == 0 ]]; then
    echo "F-8 gate: every mutation was caught by the test the header names."
    exit 0
fi
exit 1
