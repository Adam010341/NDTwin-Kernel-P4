#!/usr/bin/env bash
#
# Mutation gate for the A-4f tests: the sFlow record an OVS power cycle deletes, and the
# telemetry-silence status that makes the loss visible.
#
# [Co-developed with claude code -- Adam]
#
# Covers the C++ half of KNOWN-ISSUES A-4f. `ovs-vsctl del-br` destroys the Bridge row and the
# sFlow record hanging off it, powerOn rebuilt everything except that record, and the links
# arriving at the switch then read exactly 0 bps for ever -- bit-identical to an idle link.
# The tests under gate are in tests/test_OvsPowerStrategy.cpp (config half) and
# tests/test_SFlowParsing.cpp, suite TelemetrySilenceTest (visibility half).
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# byte-identity asserted at the end. Baseline is the WORKING TREE, not HEAD, so this runs against
# an uncommitted fix. These files live in a worktree other sessions write to.
#
# 🔴 THREE THINGS THIS HARNESS HAS TO GET RIGHT, EACH LEARNED THE EXPENSIVE WAY
#
#   1. A mutant that never reached the tests is a SURVIVOR, not a footnote. Two ways to get one:
#      it did not compile -- the project builds with -Werror -Wall -Wextra -Wpedantic -Wunused
#      (CMakeLists.txt:51-53), so an unused variable or an unreachable return is enough -- or its
#      anchor no longer matches the source. Either way the suite was never given anything to
#      catch, which is exactly as much evidence of a good test as a mutation it shrugged at. Both
#      are counted in the SURVIVORS column, with the reason printed, because a separate "3
#      skipped" bucket sitting next to "0 survived" gets read as a pass. Every mutation below is
#      written to compile cleanly on purpose; if one stops doing so, that is a finding about this
#      file. (mutation-gate-for-tests, step 3: an earlier check aborting first.)
#
#   2. Anchors are LITERAL and must occur EXACTLY ONCE. No perl, no sed, no regex: perl -0pi -e
#      once interpolated `$PROCFS` and `$pid` out of seven replacement strings, injected `"//stat"`
#      into all seven, and the accompanying "the file changed" hash check reported every injection
#      as successful. A hash proves something changed, not that the right thing changed. Here the
#      replacer counts the anchor first and refuses if the count is not 1 -- 0 means the code moved
#      under us, 2 means the mutation would land somewhere it was not aimed. The run continues so
#      the remaining mutations still get exercised (this script is one of a batch), but that
#      mutation is scored as a survivor.
#
#   3. The comment-only control at the end. If a mutation that cannot change behaviour turns the
#      suite red, this harness is not measuring what it claims to -- a stale build directory, a
#      flaky test, a rebuild that did not actually rebuild -- and every CAUGHT above it is
#      unearned. A gate with no negative control cannot tell "the tests are good" from "everything
#      is red today".
#
# Runs no ovs-vsctl and touches no fabric: every test under gate drives OVSPowerStrategy through
# its two shell seams, both replaced by fakes, and TelemetrySilenceTest calls a pure static.
#
# Usage:   bash tests/shell/mutate_a4f_sflow_power_cycle.sh
#          BUILD_DIR=build-asan bash tests/shell/mutate_a4f_sflow_power_cycle.sh
# Exit:    0 = every mutant killed and the control stayed green
#          1 = at least one mutant survived -- including one that never reached the tests
#              because it would not build or because its anchor no longer matches
#          2 = the baseline is unusable (not configured, does not build, or already red),
#              or the comment-only control failed, which invalidates the whole run

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

BUILD_DIR="${BUILD_DIR:-build}"

# The gtest binary is `test_routing_strategy`: tests/CMakeLists.txt:2-56 compiles every
# tests/test_*.cpp into that single executable, and there is no per-file target. Named here
# rather than assumed, because `ninja test_OvsPowerStrategy` does not exist and would fail with
# a message about an unknown target rather than about anything to do with these tests.
TARGET=test_routing_strategy
BIN="$BUILD_DIR/tests/$TARGET"
FILTER='OvsPowerStrategyTest.*:OvsPowerStrategyConcurrencyTest.*:TelemetrySilenceTest.*'

POWER=src/ndt_core/power_management/OVSPowerStrategy.cpp
COLLECTOR=src/ndt_core/collection/FlowLinkUsageCollector.cpp
FILES=("$POWER" "$COLLECTOR")

BK=$(mktemp -d)
snap() { echo "$BK/$(basename "$1")"; }
for f in "${FILES[@]}"; do cp "$f" "$(snap "$f")"; done

# 🔴 Plain `cp`, then `touch`. NEVER `cp -p` or `cp -a` here.
#
# ninja decides what to rebuild by comparing mtimes. `cp -p` restores the ORIGINAL mtime, which is
# older than the object file just compiled from the mutant -- so ninja concludes there is nothing
# to do, the next mutation is measured against the PREVIOUS mutant's binary, and the results are
# attributed to the wrong mutation. Every line of the report would still look plausible.
#
# Plain `cp` already sets mtime to now; the `touch` is belt and braces, and it is here mostly so
# that anyone tidying this into `cp -p` has to delete an explicit line and read why it existed.
restore() {
    local f
    for f in "${FILES[@]}"; do cp "$(snap "$f")" "$f"; touch "$f"; done
}
trap 'restore; rm -rf "$BK"' EXIT

SURVIVORS=0
MUTATIONS=0
MUT_APPLIED=1
# How many of the survivors survived because the suite never got to run against them (stale
# anchor, or a mutant that did not compile). Informational only -- they are already in SURVIVORS.
NOT_RUN=0

# --- the replacer -------------------------------------------------------------------------------
# Literal, exactly-once, and the strings arrive through the environment so no shell, sed or perl
# metacharacter is ever interpreted. See note 2 in the header for what this replaces.
apply() {   # $1 = file, $2 = literal old text, $3 = literal new text
    MUT_OLD="$2" MUT_NEW="$3" python3 - "$1" <<'PY'
import os
import sys

path = sys.argv[1]
old = os.environ["MUT_OLD"]
new = os.environ["MUT_NEW"]
text = open(path).read()
n = text.count(old)
if n != 1:
    sys.stderr.write(
        "anchor occurs %d times in %s, need exactly 1.\n"
        "0 means the source moved; 2+ means the mutation would land somewhere it was not "
        "aimed. Either way this gate is not measuring what it says it is.\n" % (n, path))
    sys.exit(3)
open(path, "w").write(text.replace(old, new))
PY
    local rc=$?
    # 🔴 The status MUST be consumed here. The first version of this file did not: `apply` is
    # called at top level, nothing read its status, and set -e is off (deliberately -- the whole
    # harness runs on captured exit codes). So a python3 exiting 3 scrolled past and `report` then
    # built, ran and scored the UNMUTATED binary, which of course passed. The header already
    # claimed "Both abort the run rather than being skipped" while that was untrue.
    #
    # Found by a negative control that duplicated a real anchor and required a non-zero run; the
    # run answered 0. An assertion nobody has watched fail is not known to work.
    #
    # A stale anchor does not abort the run: it is recorded as a SURVIVOR and the remaining
    # mutations still execute. The reasoning is that "the test never ran" and "the test ran and
    # did not notice" are the same fact from the report's point of view -- neither is evidence
    # that the suite catches anything -- and aborting would additionally throw away the results
    # of every mutation after it, which matters when this is one script in a batch.
    if [[ "$rc" -ne 0 ]]; then
        MUT_APPLIED=0
    fi
}

build() {   # rc 0 = built. Output is captured, not piped, so the rc is the compiler's.
    local out rc
    if [[ "${ANCHOR_CHECK:-0}" == 1 ]]; then BUILD_OUT="(skipped: ANCHOR_CHECK)"; return 0; fi
    out=$(ninja -C "$BUILD_DIR" "$TARGET" 2>&1); rc=$?
    BUILD_OUT="$out"
    return $rc
}

run_tests() {   # rc 0 = all green. timeout so a hanging mutant becomes an rc, not a hung harness.
    local out rc
    if [[ "${ANCHOR_CHECK:-0}" == 1 ]]; then TEST_OUT="(skipped: ANCHOR_CHECK)"; return 0; fi
    out=$(timeout 600 "$BIN" --gtest_filter="$FILTER" --gtest_color=no 2>&1); rc=$?
    TEST_OUT="$out"
    return $rc
}

failed_names() { grep -E '^\[  FAILED  \] [A-Za-z]' <<<"$TEST_OUT" | sort -u | sed 's/^/             /'; }

# $1 = mutation name, then one or more gtest names that MUST go red.
report() {
    local name="$1"; shift
    local rc missing=()
    MUTATIONS=$((MUTATIONS + 1))

    # A mutation that was never applied is a SURVIVOR, not a warning. The suite did not kill it;
    # the suite never saw it. Reported with its reason so nobody mistakes it for a test that ran
    # and shrugged, but counted in the same column, because a separate "3 skipped" bucket next to
    # "0 survived" is read as a pass by everyone in a hurry.
    if [[ "${MUT_APPLIED:-1}" -eq 0 ]]; then
        printf '  SURVIVED %-58s (anchor did not resolve -- the mutation never happened,\n' "$name"
        printf '             so the tests were never given anything to catch. Re-read the anchor\n'
        printf '             against the current source and fix this file.)\n'
        SURVIVORS=$((SURVIVORS + 1))
        NOT_RUN=$((NOT_RUN + 1))
        MUT_APPLIED=1
        restore
        return
    fi

    # ANCHOR_CHECK=1 walks the whole sequence without ninja: every mutation is really applied to
    # the real files through the real `apply`, so every anchor's exactly-once assertion really
    # fires, and the restore and byte-identity checks really run. It proves the literals still
    # match the source and nothing more -- it cannot tell you a mutant compiles or that a test
    # goes red. It exists so this file can be checked in from a session that is not allowed to
    # build, without anyone mistaking that check for the gate.
    if [[ "${ANCHOR_CHECK:-0}" == 1 ]]; then
        printf '  anchor   %-58s (resolved, exactly once)\n' "$name"
        restore
        return
    fi

    # Same rule as a stale anchor, same column: if the mutant does not compile, the test binary
    # was never rebuilt from it and the suite was never given a chance to fail. -Werror -Wall
    # -Wextra -Wpedantic -Wunused (CMakeLists.txt:51-53) makes this easy to hit by accident -- an
    # unused variable is enough -- so it needs to be loud rather than tucked into a footnote.
    if ! build; then
        printf '  SURVIVED %-58s (did not compile -- the test never ran)\n' "$name"
        sed 's/^/             /' <<<"$BUILD_OUT" | tail -12
        SURVIVORS=$((SURVIVORS + 1))
        NOT_RUN=$((NOT_RUN + 1))
        restore
        return
    fi

    run_tests; rc=$?
    local t
    for t in "$@"; do
        grep -q "\[  FAILED  \] $t" <<<"$TEST_OUT" || missing+=("$t")
    done

    if [[ "$rc" -ne 0 && ${#missing[@]} -eq 0 ]]; then
        printf '  caught   %-58s (%s went red)\n' "$name" "$*"
    else
        printf '  SURVIVED %-58s (rc=%d)\n' "$name" "$rc"
        if [[ ${#missing[@]} -gt 0 ]]; then
            printf '             these stayed green, so they prove nothing: %s\n' "${missing[*]}"
        fi
        failed_names
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# --- baseline -----------------------------------------------------------------------------------
echo "baseline:"
if [[ "${ANCHOR_CHECK:-0}" == 1 ]]; then
    echo "  ANCHOR_CHECK=1 -- resolving every anchor against the working tree, no build, no tests."
    echo "  🔴 This is NOT the gate. It cannot tell you a mutant compiles or that a test went red."
elif [[ ! -f "$BUILD_DIR/build.ninja" ]]; then
    echo "  REFUSE: $BUILD_DIR is not a configured ninja build directory."
    echo "          Configure it first (this script will not choose your build type for you):"
    echo "            cmake -G Ninja -S . -B $BUILD_DIR -DCMAKE_BUILD_TYPE=Debug"
    exit 2
fi
if ! build; then
    echo "  REFUSE: the unmutated tree does not build, so nothing below would mean anything."
    sed 's/^/    /' <<<"$BUILD_OUT" | tail -25
    exit 2
fi
[[ "${ANCHOR_CHECK:-0}" == 1 ]] || echo "  ok       $TARGET built from the unmutated tree"

if run_tests; then
    [[ "${ANCHOR_CHECK:-0}" == 1 ]] ||
        printf '  ok       baseline green (%s)\n' "$(grep -cE '^\[       OK \]' <<<"$TEST_OUT") tests"
else
    echo "  REFUSE: the baseline is already red. A gate cannot distinguish a mutant it killed"
    echo "          from a suite that was failing before it started."
    failed_names
    exit 2
fi
echo
echo "mutations:"

# 1. powerOff stops saving the record before del-br destroys it.
#    The read still happens, so this is precisely "we looked and then threw the answer away" --
#    the shape the port list had before executeListPorts learned to report a failed query.
apply "$POWER" \
  '    topoMonitor->setBridgeSflowState(node, sflow);' \
  '    topoMonitor->setBridgeSflowState(node, SflowBridgeState{});'
report "powerOff does not save the sFlow record" \
    OvsPowerStrategyTest.PowerOffReadsTheSflowRecordBeforeItDeletesTheBridge \
    OvsPowerStrategyTest.PowerOffRecordsAnUnreadableSflowAsUnknownRatherThanAsAbsent

# 2. powerOn replays the configuration and then believes itself.
#    Every ovs-vsctl still runs and every one of them still exits 0; the only thing removed is the
#    read-back. This is the mutant the whole "an exit status is not evidence of an effect" claim
#    stands on, so if it survives, that claim is decoration.
apply "$POWER" \
  '    const auto after = executeReadSflowState(swName);' \
  '    const auto after = std::make_optional(saved);'
report "powerOn replays the record but never reads it back" \
    OvsPowerStrategyTest.PowerOnReportsFailureWhenTheSflowRecordDoesNotComeBack

# 3. The read-back accepts a record attached to an interface with no IPv4 address.
#    Structurally present, functionally useless: the datagrams carry no agent address the
#    collector can key an edge from, so the restore ran, succeeded, and landed somewhere nothing
#    can see it. That is the ninth form in injections-must-assert-their-own-success, and it is the
#    one a reviewer is most likely to call over-engineering.
apply "$POWER" \
'    if (after->agentIpCidr.empty())
    {
        // Structurally attached, but to an interface with no address. The datagrams would go out
        // (or not) with no usable agent IP and the collector could not key them to an edge, so
        // this is a restore that ran, succeeded, and landed where it cannot be seen.
        SPDLOG_LOGGER_ERROR(Logger::instance(),
                            "sFlow record for {} is attached, but its agent interface {} has no "
                            "IPv4 address, so samples cannot be attributed to any link",
                            swName,
                            after->agentIface);
        return false;
    }
' \
''
report "the read-back accepts an address-less agent interface" \
    OvsPowerStrategyTest.PowerOnReportsFailureWhenTheAgentInterfaceHasNoAddress

# 4. The retry falls back into the full bring-up.
#    This one is a regression I introduced and then caught by writing the retry test: widening the
#    early-return guard is only half the fix, because the widened guard led straight into an
#    `add-br` that exits 1 on a bridge that already exists. Both halves fail the same way from
#    outside -- the retry repairs nothing -- so it is kept as a mutant rather than as a comment.
apply "$POWER" \
'    if (alreadyUp)
    {
        return finishTelemetryRestore(node, swName, saved, topoMonitor);
    }
' \
''
report "a retried power-on falls into add-br again instead of restoring" \
    OvsPowerStrategyTest.ARetriedPowerOnReAttemptsTheSflowRestore

# 5. Every link reports healthy telemetry.
#    The failure mode this whole feature exists to prevent, in its purest form: a status field
#    that always says the reading can be trusted is worse than no status field, because it
#    answers the question wrongly instead of leaving it open.
apply "$COLLECTOR" \
'    LinkTelemetryStatus out;
    const int64_t portAt = portLastSampleMillis;' \
'    LinkTelemetryStatus out;
    out.status = "live";
    if (windowSeconds >= 0.0)
    {
        return out;
    }
    const int64_t portAt = portLastSampleMillis;'
report "telemetry_status is always live" \
    TelemetrySilenceTest.AnAgentReportingNowhereMakesThisLinksZeroAnAbsence \
    TelemetrySilenceTest.AnAgentThatHasNeverReportedIsUnknownRatherThanSilent

# --- the control ---------------------------------------------------------------------------------
# A change that cannot alter behaviour. If the suite goes red here, nothing above is trustworthy:
# it would mean the binary under test is not the tree that was mutated, or a test is flaky, and
# either way every "caught" line above could have been produced by the same accident.
echo
echo "control (must stay GREEN -- a comment cannot change behaviour):"
apply "$POWER" \
  '// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.' \
  '// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro. (control mutation)'
CONTROL_OK=1
if ! build; then
    echo "  🔴 CONTROL BROKEN: a comment-only edit failed to build. This harness is not sane."
    sed 's/^/    /' <<<"$BUILD_OUT" | tail -12
    CONTROL_OK=0
elif run_tests; then
    if [[ "${ANCHOR_CHECK:-0}" == 1 ]]; then
        echo "  anchor   comment-only control anchor resolved (no suite was run)"
    else
        echo "  ok       comment-only mutation left the suite green"
    fi
else
    echo "  🔴 CONTROL FAILED: a comment-only edit turned the suite red, so the CAUGHT results"
    echo "     above are unearned -- suspect a stale build dir, a flaky test, or a rebuild that"
    echo "     did not rebuild. Do not report this run as a passing gate."
    failed_names
    CONTROL_OK=0
fi
restore

# --- restore, and prove it ------------------------------------------------------------------------
echo
ok=1
for f in "${FILES[@]}"; do
    cmp -s "$(snap "$f")" "$f" || { echo "🔴 NOT RESTORED: $f"; ok=0; }
done
if [[ "$ok" == 1 ]]; then
    echo "baseline restored: both sources byte-identical to the pre-run snapshot"
fi

# Leave the build directory matching the restored tree. Without this the next person's `ninja`
# would be a no-op over objects compiled from the last mutant, and a build directory that
# disagrees with the source is the quietest way to measure the wrong thing.
build || echo "⚠️  final rebuild of the restored tree failed -- your build dir is now stale"

echo
if [[ "${ANCHOR_CHECK:-0}" == 1 ]]; then
    printf '%d of %d anchors resolved exactly once; sources restored byte-identical.\n' \
        "$((MUTATIONS - NOT_RUN))" "$MUTATIONS"
    if [[ "$NOT_RUN" -gt 0 ]]; then
        printf '🔴 %d did not resolve -- see the SURVIVED lines above.\n' "$NOT_RUN"
    fi
    echo 'NOT A GATE RESULT -- no build, no tests. Run without ANCHOR_CHECK for the real thing.'
    [[ "$ok" == 1 && "$NOT_RUN" -eq 0 ]]
    exit $?
fi
printf '%d mutations, %d survived' "$MUTATIONS" "$SURVIVORS"
if [[ "$NOT_RUN" -gt 0 ]]; then
    printf ' (%d of them never reached the tests: stale anchor or a mutant that would not build)' \
        "$NOT_RUN"
fi
printf '\n'
[[ "$ok" == 1 && "$CONTROL_OK" == 1 && "$SURVIVORS" -eq 0 ]]
