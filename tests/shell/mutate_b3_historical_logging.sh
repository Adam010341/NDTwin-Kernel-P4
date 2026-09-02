#!/usr/bin/env bash
#
# Mutation gate for the KNOWN-ISSUES B-3 fix: /ndt/historical_logging must answer with the reason
# a row will not appear, instead of "success" on both branches.
#
# [Co-developed with claude code -- Adam]
#
# Each mutation reintroduces one part of the defect, or breaks one half of the property the fix
# rests on, and names the gtest case that must go red. A mutation that SURVIVES means that case is
# decorative.
#
# 🔴 WHY THIS GATE IS NOT OPTIONAL HERE. B-3 was "fixed" once already, in aabe605, and the fix was
# real -- the message stopped lying. What it left was a reply whose `status` field was a constant,
# so every caller-visible signal except one bool still said the same thing on both branches. The
# suite was green before this change and is green after it. Only a mutation run can say which of
# the two shapes it is actually pinning.
#
# 🔴 The harness guards its own baseline. Originals are snapshotted before the first mutation, an
# EXIT trap restores them on any exit including interrupt, and the run ends by asserting the files
# are byte-identical to the snapshot. These files live in a worktree other sessions write to.
#
# The baseline is the WORKING TREE, not HEAD: this is meant to be runnable against an uncommitted
# fix, and "restore to HEAD" would silently discard it.
#
# Usage:  bash tests/shell/mutate_b3_historical_logging.sh
#         BUILD_DIR=build-asan bash tests/shell/mutate_b3_historical_logging.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"

HDM=src/ndt_core/data_management/HistoricalDataManager.cpp
HDH=include/ndt_core/data_management/HistoricalDataManager.hpp
HTTP=src/ndt_core/http/HttpSession.cpp
ALLOW=tools/contract_test/warning_allowlist.txt
CHECK=tools/contract_test/check_logs.py

FILTER='HistoricalLogging*'
FILES=("$HDM" "$HDH" "$HTTP" "$ALLOW")
BK=$(mktemp -d)

snap() { echo "$BK/$(basename "$1")"; }
for f in "${FILES[@]}"; do cp "$f" "$(snap "$f")"; done
restore() { local f; for f in "${FILES[@]}"; do cp "$(snap "$f")" "$f"; done; }
trap 'restore; rm -rf "$BK"' EXIT

build() { cmake --build "$BUILD_DIR" --target "$TARGET" -j"$(nproc)" 2>&1; }
run() { "$BIN" --gtest_filter="$FILTER" 2>&1; }

MUTATIONS=0
SURVIVORS=0
BROKEN=0

# Every mutation is a literal string replacement asserted to have fired exactly once. A perl
# substitution that matches nothing edits nothing, and the run then reports the UNMUTATED tree as
# "caught" -- a green tick that means nothing.
# memory/injections-must-assert-their-own-success.
mutate() {   # $1 = file, $2 = literal to find, $3 = literal replacement
    local file="$1" from="$2" to="$3" n
    n=$(FROM="$from" perl -0777 -ne 'my $f = quotemeta $ENV{FROM}; my $c = () = /$f/g; print $c' "$file")
    if [[ "$n" != "1" ]]; then
        echo "  🔴 REFUSE: the mutation target appears $n times in $file, expected exactly 1"
        echo "     target: $from"
        exit 2
    fi
    FROM="$from" TO="$to" perl -0777 -pi -e 'my $f = quotemeta $ENV{FROM}; s/$f/$ENV{TO}/' "$file"
}

# $1 = mutation name, $2 = gtest case that must fail
report() {
    local name="$1" want="$2" out rc
    MUTATIONS=$((MUTATIONS + 1))
    if ! build > "$BK/build.log" 2>&1; then
        # A mutation that does not compile proves nothing about the tests: it never reached them.
        printf '  BUILD-FAIL %-52s (the mutation did not compile -- it tested nothing)\n' "$name"
        tail -5 "$BK/build.log" | sed 's/^/               /'
        BROKEN=$((BROKEN + 1))
        restore
        return
    fi
    out=$(run); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "[  FAILED  ] $want" <<<"$out"; then
        printf '  caught     %-52s (%s went red)\n' "$name" "$want"
    else
        printf '  SURVIVED   %-52s (%s stayed green -- that case proves nothing)\n' "$name" "$want"
        grep -E '^\[  FAILED  \]' <<<"$out" | sed 's/^/               /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# A mutation that must NOT be caught. Without it, a suite that fails on absolutely any edit --
# a stale build, a dirty tree, a broken runner -- would score a perfect run and look rigorous.
# memory/a-control-that-cannot-fail-measures-nothing.
control() {   # $1 = name
    local name="$1" out rc
    MUTATIONS=$((MUTATIONS + 1))
    if ! build > "$BK/build.log" 2>&1; then
        printf '  BUILD-FAIL %-52s (the CONTROL did not compile)\n' "$name"
        tail -5 "$BK/build.log" | sed 's/^/               /'
        BROKEN=$((BROKEN + 1))
        restore
        return
    fi
    out=$(run); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  ok         %-52s (stayed green, as it must)\n' "$name"
    else
        printf '  🔴 CONTROL WENT RED %-44s\n' "$name"
        grep -E '^\[  FAILED  \]' <<<"$out" | sed 's/^/               /'
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# ---------------------------------------------------------------------------------------------
echo "build dir: $BUILD_DIR   target: $TARGET   filter: $FILTER"
echo
echo "baseline (unmutated) must be green:"
if ! build > "$BK/build.log" 2>&1; then
    echo "  REFUSE: the baseline does not build"
    tail -20 "$BK/build.log" | sed 's/^/    /'
    exit 2
fi
baseline_out=$(run); baseline_rc=$?
if [[ "$baseline_rc" -ne 0 ]] || grep -q '^\[  FAILED  \]' <<<"$baseline_out"; then
    echo "  REFUSE: baseline is not green; mutation results would be meaningless (rc=$baseline_rc)"
    grep -E '^\[  FAILED  \]' <<<"$baseline_out" | sed 's/^/    /'
    grep -E '^\[==========\]|^\[  PASSED  \]' <<<"$baseline_out" | sed 's/^/    /'
    exit 2
fi
grep -E '^\[==========\]|^\[  PASSED  \]' <<<"$baseline_out" | sed 's/^/  /'
echo
echo "mutations:"

# 1. THE DEFECT B-3 NAMES, verbatim: the non-recording branch goes back to "success", so `status`
#    is a constant and only `recording` differs. This is the shape at 1208d22.
mutate "$HTTP" \
    'res.body() = json{{"status", "not_applicable"},' \
    'res.body() = json{{"status", "success"},'
report "MININET enable says \"success\" again (the defect)" \
       "HistoricalLoggingReplyTest.MininetEnableIsNotAnsweredWithTheSameStatusFieldAsARealEnable"

# 2. The same field drifts to some OTHER string. Caught only by the exact-token assertion: an
#    inequality against "success" alone would let this through, and a caller cannot branch on a
#    token nobody wrote down. This is why that test asserts the value and not just the difference.
mutate "$HTTP" \
    'res.body() = json{{"status", "not_applicable"},' \
    'res.body() = json{{"status", "enabled"},'
report "MININET enable's status drifts to \"enabled\"" \
       "HistoricalLoggingReplyTest.MininetEnableIsNotAnsweredWithTheSameStatusFieldAsARealEnable"

# 3. The machine-readable token goes, leaving only the English sentence -- which is what callers
#    had to regex before. The anchor is the whole non-recording body because the `reason` line
#    itself appears in both branches.
mutate "$HTTP" \
    '        res.body() = json{{"status", "not_applicable"},
                          {"recording", false},
                          {"reason", HistoricalDataManager::reasonCode(recState)},
                          {"message", why}}
                         .dump();' \
    '        res.body() = json{{"status", "not_applicable"},
                          {"recording", false},
                          {"message", why}}
                         .dump();'
report "the reason token is dropped from the reply" \
       "HistoricalLoggingReplyTest.TheEnableReplyNamesTheReasonInAMachineReadableField"

# 4. The gate reverts to canRecord(): a mode question standing in for a liveness question. MININET
#    still answers correctly, so every MININET test stays green -- this is exactly why the file
#    carries a TESTBED case as its positive control.
mutate "$HTTP" \
    'const bool recording = (recState == RecordingState::RECORDING);' \
    'const bool recording = m_historicalDataManager->canRecord();'
report "the gate reverts to canRecord() (mode, not liveness)" \
       "HistoricalLoggingReplyTest.AnUnstartedRecorderIsNotReportedAsRecordingEither"

# 5. One sentence for every non-recording cause, so a TESTBED reply blames MININET. The reason
#    token stays correct, which is the point: the two halves of the answer can drift apart, and
#    the operator reads the sentence.
mutate "$HTTP" \
    'why = "Historical data logging is enabled, but the recorder thread is not running, "
                  "so no rows will be written until the kernel starts it.";' \
    'why = "Historical data logging is enabled, but this deployment does not record: the "
                  "recorder is only started outside MININET mode, so no rows will be written.";'
report "the message stops following the reason" \
       "HistoricalLoggingReplyTest.AnUnstartedRecorderIsNotReportedAsRecordingEither"

# 6. start() goes back to evaluating the exchange first. `or` is left-to-right, so MININET leaves
#    the object marked running with no thread behind it -- the same lie the endpoint was telling,
#    one layer down. No thread is spawned either way, so only the flag can see this.
mutate "$HDM" \
    '    if (m_mode == utils::DeploymentMode::MININET)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),' \
    '    if (m_running.exchange(true) or m_mode == utils::DeploymentMode::MININET)
    {
        SPDLOG_LOGGER_WARN(Logger::instance(),'
report "start() marks MININET as running (the latent half)" \
       "HistoricalLoggingStateTest.StartInMininetLeavesTheObjectNotClaimingToBeRunning"

# 7. The mode check and the flag check swap places in recordingState(). Both orderings "work";
#    only one of them points a MININET operator at the lever that would actually help, which is
#    none. Pins the precedence as a decision rather than an accident.
mutate "$HDH" \
    '        if (!canRecord())
        {
            return RecordingState::NOT_AVAILABLE_IN_MININET;
        }
        if (!m_loggingEnabled.load())
        {
            return RecordingState::DISABLED_BY_REQUEST;
        }' \
    '        if (!m_loggingEnabled.load())
        {
            return RecordingState::DISABLED_BY_REQUEST;
        }
        if (!canRecord())
        {
            return RecordingState::NOT_AVAILABLE_IN_MININET;
        }'
report "recordingState() lets the flag outrank the mode" \
       "HistoricalLoggingStateTest.TheReportedStateDistinguishesTheFourReachableCauses"

# 8. The disable path is turned into a refusal. A "fix" that answers not_applicable to everything
#    would pass mutations 1-7; this is the assertion that stops the honest reply from becoming a
#    blanket one.
mutate "$HTTP" \
    '    if (is_enabled && !recording)' \
    '    if (!recording)'
report "every reply becomes not_applicable, disable included" \
       "HistoricalLoggingReplyTest.DisablingIsStillAPlainSuccess"

# 9. THE CONTROL. A comment-only edit changes no behaviour, so the suite must stay green. If this
#    goes red the run above is measuring something other than the code -- a stale object file, a
#    dirty tree, a flaky runner -- and every "caught" line before it is suspect.
mutate "$HTTP" \
    '    // KNOWN-ISSUES B-3, second pass.' \
    '    // KNOWN-ISSUES B-3, second pass (control edit -- text only, no behaviour).'
control "comment-only edit (control)"

restore
build > /dev/null 2>&1
echo

# ---------------------------------------------------------------------------------------------
# The log-check half, kept deliberately separate.
#
# 🔴 WHAT THIS DOES AND DOES NOT SHOW. check_logs.py fails any warning that is not allowlisted, and
# the fix adds a startup warning that fires on every MININET kernel. This section proves the
# ALLOWLIST RULE behaves -- present: accepted; removed: red -- by feeding check_logs.py a
# SYNTHETIC line in the spdlog format it parses.
#
# It does NOT show that the kernel emits that line, and it is not evidence that it does. Nothing
# here starts a kernel, a fabric, or Mininet. The claim "the running kernel prints this at
# startup" needs a live MININET run and is recorded as unverified until someone does one.
echo "log check (synthetic fixture -- proves the allowlist rule, NOT that the kernel logs it):"
FIXTURE="$BK/synthetic.log"
cat > "$FIXTURE" <<'EOF'
[2026-09-02 12:00:00.000] [info] [main.cpp:430 main] NDTwin kernel starting
[2026-09-02 12:00:00.001] [warning] [HistoricalDataManager.cpp:64 start] HistoricalDataManager not started: MININET deployments do not run the recorder, so no historical link row will ever be written. /ndt/historical_logging reports this as reason=not-available-in-mininet-mode.
EOF

if [[ ! -f "$CHECK" ]] || ! command -v python3 >/dev/null 2>&1; then
    # Skipped, not passed. A missing checker must not be able to score a clean run.
    echo "  SKIPPED: need python3 and $CHECK"
    SURVIVORS=$((SURVIVORS + 1))
else
    LOGMUT=0
    python3 "$CHECK" "$FIXTURE" --allowlist "$ALLOW" >"$BK/logcheck.out" 2>&1; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        echo "  ok         allowlisted warning is accepted"
    else
        echo "  🔴 the allowlist entry does not match its own message (rc=$rc)"
        sed 's/^/               /' "$BK/logcheck.out"
        LOGMUT=1
    fi

    # Remove the allowlist line: the same fixture must now be refused.
    MUTATIONS=$((MUTATIONS + 1))
    mutate "$ALLOW" \
        'WARNING | ^HistoricalDataManager not started: MININET | MININET does not run the recorder; stated once at startup so the absence of historical rows is visible without reading the source
' \
        ''
    python3 "$CHECK" "$FIXTURE" --allowlist "$ALLOW" >"$BK/logcheck.mut" 2>&1; rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "  caught     allowlist entry removed -> check_logs.py goes red (rc=$rc)"
    else
        echo "  SURVIVED   allowlist entry removed and check_logs.py stayed green"
        sed 's/^/               /' "$BK/logcheck.mut"
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
    [[ "$LOGMUT" -eq 1 ]] && SURVIVORS=$((SURVIVORS + 1))
fi

# ---------------------------------------------------------------------------------------------
restore
echo
ok=1
for f in "${FILES[@]}"; do
    if ! cmp -s "$(snap "$f")" "$f"; then
        echo "🔴 BASELINE NOT RESTORED -- a mutant is still on disk: $f"
        diff -u "$(snap "$f")" "$f" | head -20
        ok=0
    fi
done
[[ "$ok" == 1 ]] && echo "baseline restored: all ${#FILES[@]} files byte-identical to the pre-run snapshot"
echo
echo "$MUTATIONS mutations, $SURVIVORS survived, $BROKEN did not compile"
[[ "$ok" == 1 && "$SURVIVORS" -eq 0 && "$BROKEN" -eq 0 ]]
