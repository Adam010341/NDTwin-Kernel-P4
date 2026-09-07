#!/usr/bin/env bash
#
# Mutation gate for FINDINGS #69 and #70 -- an option no parser in this program owns must be an
# ERROR, and an option some parser DOES own must not become one.
#
# [Co-developed with claude code -- Adam]
#
# Covers the FINDINGS #70 cases in tests/test_LoggerCliArgs.cpp and the parts of the defect that
# live in src/main.cpp, which no gtest case can reach: main.cpp has a main() of its own and is not
# linked into the test binary, so main's half of the union is checked here on the REAL
# ndtwin_kernel binary or it is not checked anywhere.
#
# WHAT THE DEFECT WAS
#   $ ndtwin_kernel --logfle /tmp/x.log ; echo $?
#   0                       <- accepted, no log file, no message, nothing to notice
# Both parsers ignored what they did not recognise, and NEITHER WAS WRONG TO: `cli::parse` walks
# the whole argv and must tolerate `--logfile`, `Logger::parse_cli_args` walks the same argv and
# must tolerate `--mode`. "I do not recognise this" is only true of the UNION, so the fix is one
# pass over both tables (Logger::reject_unknown_flags) and the gate has to attack that shape:
# the union, the wiring, and both tables that feed it.
#
# FIVE THINGS THIS GATE IS BUILT TO CATCH, NOT ONE
#   1. the check decides nothing, or decides and then carries on          (M1, M7)
#   2. the check exists but main never calls it -- existence is not wiring (M2)
#   3. a table drifts from the parser it describes, in either binary      (M3, M4)
#   4. the check reads a flag's VALUE as a flag                           (M5)
#   5. the refusal, or the help, stops telling the operator anything      (M6, M8, M9)
#
# 🔴 THREE MUTATIONS MUST **NOT** BE CAUGHT (W1, W2, W3). A refusal is trivial to get right by
# refusing everything, and every catch above would be satisfied by exactly that:
#   W1  a comment                          -- the classic control
#   W2  a THIRD accepted spelling (--log-file), added to BOTH the table and the parser -- a
#       widening: every command line the tests use behaves identically, so a red here means the
#       suite pins the table's CONTENTS rather than the behaviour the table produces. Adding it to
#       the table alone would NOT be a widening; it would be a flag the check accepts and the
#       parser ignores, which is the defect itself.
#   W3  the end-of-options marker "--" also accepted -- a second widening, in the check itself
#       rather than in a table, because W2 cannot tell a hard-coded token list from a real lookup
#
# 🔴 A MUTANT THAT DOES NOT COMPILE IS A SURVIVOR, not a skip: the suite never ran, so it proves
# nothing. Same for an anchor that has moved, and for a run that hangs.
#
# 🔴 NOTHING HERE STARTS THE KERNEL. Every ndtwin_kernel invocation below either is refused during
# argument parsing or carries --help, and main.cpp answers --help and returns 0 before a single
# subsystem is constructed or a socket is bound. No Mininet, no bmv2, no OVS, no lab.
#
# 🔴 NEVER KILLS ANYTHING BY NAME. No pkill, no pgrep: `timeout` owns the only child.
#
# 🔴 GUARDS ITS OWN BASELINE, in the shape tests/shell/mutate_logfile_takes_a_path.sh established:
# the two mutated files are snapshotted with `cp -p`, an EXIT trap restores them however this exits
# including Ctrl-C, and the run ends by asserting byte-identity against the snapshot. `cp -p`
# restores the ORIGINAL mtime -- older than the object built from the mutant -- so ninja would see
# nothing to do and the NEXT mutation would be measured against a binary still holding the previous
# one, while the source on disk looked pristine. A restored file is therefore also `touch`ed, and
# only the file that actually changed, because include/utils/Logger.hpp is included by 83 TUs and
# is deliberately NOT mutated here for that reason.
#
# 🔴 BUILD UNDER THE GUARD. This laptop's oomd took the user's own application down on 2026-09-02.
#   tools/build_guard/guarded_build.sh ./tests/shell/mutate_logger_cli.sh
#
# Usage:  tools/build_guard/guarded_build.sh ./tests/shell/mutate_logger_cli.sh
#   BUILD_DIR=build     configured build directory (ninja)
#   JOBS=2              build parallelism
#   TEST_TIMEOUT=300    seconds allowed per test-binary run
#
# Exit: 0 every mutation caught by the check it names, all three widenings survived, tree restored
#       1 at least one mutation survived, or a widening was caught
#       2 no verdict is possible: baseline red or not building, anchor drift, hang, failed restore
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

BUILD_DIR="${BUILD_DIR:-build}"
JOBS="${JOBS:-2}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
TARGET=test_routing_strategy
KERNEL=ndtwin_kernel
BIN="$BUILD_DIR/bin/$TARGET"
KBIN="$BUILD_DIR/bin/$KERNEL"
FILTER='LoggerCliArgs*:LoggerFileSink*:LoggerUsageText*'

LOGCPP=src/utils/Logger.cpp
MAIN=src/main.cpp
FILES=("$LOGCPP" "$MAIN")

# A path the --help positive control must NOT create. Its absence is what proves the kernel exited
# in its parser rather than reaching Logger::init with a file to open.
# [Co-developed with claude code -- Adam] $$: the name was a constant in a world-writable
# directory, and this gate both `rm -f`s it and reads its absence as the verdict. Two runs on one
# machine could each delete the other's evidence -- one reading a file it did not create as a
# failure, the other reading its own deleted file as a pass. Found by tests/shell/check_test_tmpdirs.py
# (E-17), which is the only reason anyone was looking.
NOFILE=/tmp/ndtwin-logger-cli-gate-should-not-exist.$$.log

MUTATIONS=0
SURVIVORS=0
WIDENINGS=0
WIDENINGS_CAUGHT=0

# --- 0. self-check ------------------------------------------------------------------------------
if ! bash -n "${BASH_SOURCE[0]}"; then
    echo "🔴 this script does not parse" >&2; exit 2
fi
command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
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
trap 'restore; rm -f "$NOFILE"; rm -rf "$BK"' EXIT

# --- 2. anchors ---------------------------------------------------------------------------------
count_exact() {
    python3 - "$1" "$2" <<'PYCOUNT'
import sys, pathlib
sys.stdout.write(str(pathlib.Path(sys.argv[1]).read_text().count(sys.argv[2])))
PYCOUNT
}

declare -a ANCHOR_FILE ANCHOR_TEXT ANCHOR_NAME
add_anchor() { ANCHOR_NAME+=("$1"); ANCHOR_FILE+=("$2"); ANCHOR_TEXT+=("$3"); }

add_anchor "check-body"        "$LOGCPP" '        const int arity = arity_of(token);
        if (arity < 0)'
add_anchor "check-exits"       "$LOGCPP" '                      << "Run with --help for the full usage.\n";
            std::exit(2);'
add_anchor "accepted-list"     "$LOGCPP" '                      << "Accepted options: " << known_option_names(also_known) << "\n"'
add_anchor "value-skip"        "$LOGCPP" '        i += std::max(arity, 0);'
add_anchor "flag-spelling"     "$LOGCPP" '        if (arg == "--logfile" || arg == "-f")'
add_anchor "logging-table"     "$LOGCPP" '        {"--logfile", 1},
        {"-f", 1},'
add_anchor "help-branch-exit"  "$LOGCPP" '            std::exit(0);'
add_anchor "usage-level-line"  "$LOGCPP" '           "  --loglevel, -l <level>     trace, debug, info, warn, err, critical, off\n";'
add_anchor "my-comment"        "$LOGCPP" '        // Not option-shaped, so not this function'"'"'s business: a positional belongs to whoever'
add_anchor "main-calls-check"  "$MAIN"   '    Logger::reject_unknown_flags(argc, argv, deploymentFlags());'
add_anchor "deployment-table"  "$MAIN"   '        {"--mode", 1}, {"--topology", 1}, {"--ai", 0}, {"--no-ai", 0}, {"--help", 0}, {"-h", 0},'

echo "=== anchor uniqueness (exact substring count must be 1) ==="
anchor_ok=1
for i in "${!ANCHOR_NAME[@]}"; do
    n=$(count_exact "${ANCHOR_FILE[$i]}" "${ANCHOR_TEXT[$i]}")
    printf '  %-6s %-20s %-28s x%s\n' \
        "$([[ "$n" == 1 ]] && echo ok || echo REFUSE)" "${ANCHOR_NAME[$i]}" "${ANCHOR_FILE[$i]}" "$n"
    [[ "$n" == 1 ]] || anchor_ok=0
done
[[ "$anchor_ok" == 1 ]] || { echo "🔴 anchors have drifted; this gate cannot render a verdict" >&2; exit 2; }

# --- 3. build + run helpers ---------------------------------------------------------------------
build() {
    cmake --build "$BUILD_DIR" --target "$TARGET" -j"$JOBS" >/dev/null 2>&1 &&
        cmake --build "$BUILD_DIR" --target "$KERNEL" -j"$JOBS" >/dev/null 2>&1
}

# run_tests <gtest_filter> -> sets STATUS RC OUT FAILED DIED_IN.
#
# 🔴 THE CODE UNDER TEST CALLS std::exit ON A REFUSED REQUEST, so a mutation can end the process
# from inside a case -- or from inside the global test environment, before any case starts -- and
# gtest never gets to print a `[  FAILED  ]` line for either. Reading "no FAILED line" as "nothing
# went red" would turn a mutation that did enormous damage into a survivor. DIED_IN is the last
# case gtest announced, and is empty when it announced none, which stays a survivor, loudly.
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

# ------------------------------------------------------------------------------------------------
# The kernel binary's own behaviour. src/main.cpp is not linked into the test binary, so the
# deployment table, the call site, and the end-to-end refusal exist for this program only here.
#
# kernel_problem <check> -- echoes the reason the check FAILED, or nothing when it passed.
# ------------------------------------------------------------------------------------------------
kernel_problem() {
    local check="$1" out rc
    case "$check" in

    # The half of FINDINGS #70 that is about the help text: the block must be printed by the one
    # parser that can be reached, not pointed at.
    help-prints-logging-options)
        out=$(timeout 30 "$KBIN" --help 2>&1); rc=$?
        (( rc == 0 )) || { echo "ndtwin_kernel --help exited $rc"; return; }
        grep -qF -- '--logfile, -f <path>' <<<"$out" ||
            { echo "--help does not show --logfile taking a path"; return; }
        grep -qF -- '--loglevel, -l <level>' <<<"$out" ||
            { echo "--help does not show --loglevel taking a value"; return; }
        ;;

    # RELAXING-DIRECTION CONTROL, on the real binary. Every flag in BOTH tables on one command
    # line, which must be accepted. A check that refused everything, or a table that lost an
    # entry, fails here and nowhere else. --help keeps it inside main's parser: the kernel prints
    # its usage and returns 0 without constructing anything.
    all-known-flags-accepted)
        rm -f "$NOFILE"
        out=$(timeout 30 "$KBIN" --help --mode mininet --topology /tmp/ndtwin-gate-topo.json \
                  --no-ai --logfile "$NOFILE" --loglevel debug 2>&1); rc=$?
        (( rc == 0 )) || { echo "a command line of nothing but known flags was refused (exit $rc): ${out##*$'\n'}"; return; }
        [[ -e "$NOFILE" ]] && { echo "the --help path reached Logger::init and opened $NOFILE"; return; }
        ;;

    # THE FINDING ITSELF, end to end, on the shipping binary.
    #
    # 🔴 EVERY REFUSAL CHECK CARRIES --help, AND EVERY ONE READS THE MESSAGE RATHER THAN JUST rc.
    # Measured on the pristine tree at 431d98a5, before any of this was written:
    #     $ ndtwin_kernel --logfle /tmp/x.log ; echo $?
    #     stdin is not a TTY, so --mode must be given explicitly.
    #     2
    # The typo was ignored exactly as the finding says, and the process still exited NON-ZERO --
    # because --mode was missing and stdin was a pipe. A check written as `rc != 0` would have
    # passed on the defective tree and every catch below would have been worth nothing. --help
    # removes that confound (main answers it and returns 0 before anything is constructed), and
    # the grep is what actually distinguishes "refused for this reason" from "refused".
    unknown-long-flag-refused)
        out=$(timeout 30 "$KBIN" --help --logfle /tmp/x.log 2>&1); rc=$?
        grep -qF -- "unknown option '--logfle'" <<<"$out" ||
            { echo "'--logfle' was not refused by name (exit $rc)"; return; }
        (( rc != 0 )) || { echo "the message named --logfle and the run still exited 0"; return; }
        ;;

    unknown-short-flag-refused)
        out=$(timeout 30 "$KBIN" --help -x 2>&1); rc=$?
        grep -qF -- "unknown option '-x'" <<<"$out" ||
            { echo "'-x' was not refused by name (exit $rc)"; return; }
        (( rc != 0 )) || { echo "the message named -x and the run still exited 0"; return; }
        ;;

    # Neither parser honours the equals form, so accepting it silently is the same lie in a
    # different spelling.
    equals-form-refused)
        out=$(timeout 30 "$KBIN" --help --loglevel=debug 2>&1); rc=$?
        grep -qF -- "unknown option '--loglevel=debug'" <<<"$out" ||
            { echo "'--loglevel=debug' was not refused by name (exit $rc)"; return; }
        (( rc != 0 )) || { echo "the message named it and the run still exited 0"; return; }
        ;;

    # The refusal has to name what WOULD have worked, and --mode is in main's table only, so this
    # also proves the caller's half reached the message.
    refusal-names-both-tables)
        out=$(timeout 30 "$KBIN" --help --logfle /tmp/x.log 2>&1)
        grep -qF -- 'Accepted options:' <<<"$out" ||
            { echo "the refusal does not list the accepted options"; return; }
        grep -qF -- '--mode' <<<"$out" ||
            { echo "the accepted list omits main's own flags"; return; }
        grep -qF -- '--loglevel' <<<"$out" ||
            { echo "the accepted list omits the logging flags"; return; }
        ;;

    *) echo "unknown kernel check '$check' -- the gate is broken, not the code"; return ;;
    esac
    echo ""
}

# every kernel check, used for the baseline and for the widenings
all_kernel_problems() {
    local c why
    for c in help-prints-logging-options all-known-flags-accepted unknown-long-flag-refused \
             unknown-short-flag-refused equals-form-refused refusal-names-both-tables; do
        why=$(kernel_problem "$c")
        [[ -n "$why" ]] && { echo "$c: $why"; return; }
    done
    echo ""
}

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

# mutate <label> <file> <anchor> <new> <expect...>
#   expect entries are either gtest FQNs, or KERNEL:<check>. Every named one must fire. "Something
#   went red" is not the check -- WHICH light went red is.
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

    local missed=() got=() t gtests=() filter=""
    for t in "${expected[@]}"; do
        [[ "$t" == KERNEL:* ]] || { gtests+=("$t"); filter+="$t:"; }
    done
    if [[ ${#gtests[@]} -gt 0 ]]; then
        run_tests "${filter%:}"
        if [[ "$STATUS" == hang ]]; then
            echo "  🔴 HUNG (>${TEST_TIMEOUT}s) -- not a red, and not a catch"
            SURVIVORS=$((SURVIVORS + 1)); restore; return
        fi
    fi
    for t in "${expected[@]}"; do
        if [[ "$t" == KERNEL:* ]]; then
            local why; why=$(kernel_problem "${t#KERNEL:}")
            if [[ -n "$why" ]]; then got+=("$t ($why)"); else missed+=("$t"); fi
        else
            if is_red "$t"; then got+=("$t"); else missed+=("$t"); fi
        fi
    done

    if [[ ${#missed[@]} -eq 0 ]]; then
        if [[ -n "${DIED_IN:-}" ]]; then
            printf '  ✅ caught  %s\n            (the process exited %d inside %s: gtest never got to report)\n' \
                "${got[*]}" "$RC" "$DIED_IN"
        else
            printf '  ✅ caught  %s\n' "${got[*]}"
        fi
    else
        printf '  🔴 SURVIVED -- these stayed green: %s\n' "${missed[*]}"
        [[ -n "${FAILED:-}" ]] && printf '     (something else went red: %s -- the gate fires, but not\n     for the reason this mutation claims)\n' "$FAILED"
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# widen <label> <file> <anchor> <new> [<file> <anchor> <new> ...]
#   Must leave EVERY test green and EVERY kernel check happy.
#
#   🔴 TAKES MORE THAN ONE EDIT ON PURPOSE. A widening has to be a change a person would actually
#   make, and the first version of W2 was not: it added a spelling to Logger's TABLE and not to
#   the parser's branch chain, which is not "the same behaviour by another name" -- it is a flag
#   the union check accepts and the parser then ignores, the exact defect this gate exists for.
#   The drift-guard case caught it and was right to. A real widening touches both.
widen() {
    local label="$1"; shift
    WIDENINGS=$((WIDENINGS + 1))
    printf '\n=== W%d. %s (MUST stay green) ===\n' "$WIDENINGS" "$label"

    local applied_ok=1
    while [[ $# -ge 3 ]]; do
        apply "$1" "$2" "$3" || applied_ok=0
        shift 3
    done
    if [[ "$applied_ok" != 1 ]]; then
        echo "  🔴 the widening's anchor could not be applied -- this control checked nothing"
        WIDENINGS_CAUGHT=$((WIDENINGS_CAUGHT + 1)); restore; return
    fi
    if ! build; then
        echo "  🔴 CAUGHT: the widening does not compile"
        WIDENINGS_CAUGHT=$((WIDENINGS_CAUGHT + 1)); restore; return
    fi
    run_tests "$FILTER"
    local why; why=$(all_kernel_problems)
    if [[ "$STATUS" == pass && -z "$why" ]]; then
        echo "  ✅ survived -- behaviour unchanged, so the catches above are about behaviour"
    else
        [[ "$STATUS" != pass ]] && echo "  🔴 CAUGHT: tests went red on a behaviour-preserving change: $FAILED $DIED_IN"
        [[ -n "$why" ]] && echo "  🔴 CAUGHT: a kernel check fired on a behaviour-preserving change: $why"
        echo "     This gate cannot tell an edit from a behaviour change."
        WIDENINGS_CAUGHT=$((WIDENINGS_CAUGHT + 1))
    fi
    restore
}

# --- 4. baseline --------------------------------------------------------------------------------
echo
echo "=== baseline (unmutated working tree) must build, be green, and refuse an unknown flag ==="
if ! build; then
    echo "🔴 THE BASELINE DOES NOT COMPILE. Nothing below would mean anything." >&2
    cmake --build "$BUILD_DIR" --target "$TARGET" -j"$JOBS" 2>&1 | tail -40 >&2
    exit 2
fi
[[ -x "$BIN" ]]  || { echo "🔴 $BIN is missing after a successful build" >&2; exit 2; }
[[ -x "$KBIN" ]] || { echo "🔴 $KBIN is missing after a successful build" >&2; exit 2; }
BIN_SHA_BEFORE=$(sha256sum "$BIN" | cut -c1-16)
KBIN_SHA_BEFORE=$(sha256sum "$KBIN" | cut -c1-16)

run_tests "$FILTER"
case "$STATUS" in
  pass) echo "  ok       baseline green ($(grep -c '^\[       OK \]' <<<"$OUT") cases in $FILTER)" ;;
  hang) echo "🔴 BASELINE HUNG (>${TEST_TIMEOUT}s). Not a red; the gate cannot proceed." >&2; exit 2 ;;
  *)    echo "🔴 THE BASELINE IS ALREADY RED: $FAILED $DIED_IN" >&2
        echo "   Every 'expect red' below would be meaningless. Stopping." >&2; exit 2 ;;
esac
baseline_kernel=$(all_kernel_problems)
if [[ -n "$baseline_kernel" ]]; then
    echo "🔴 THE BASELINE'S OWN KERNEL BEHAVIOUR IS WRONG: $baseline_kernel" >&2; exit 2
fi
echo "  ok       ndtwin_kernel refuses --logfle, accepts every known flag, and prints its options"
echo "  ok       $TARGET sha256 $BIN_SHA_BEFORE"
echo "  ok       $KERNEL sha256 $KBIN_SHA_BEFORE"

# ================================================================================================
# 5. the mutations
# ================================================================================================

# M1. THE DEFECT EXACTLY AS IT SHIPPED: the check decides nothing. Everything still compiles and
#     every other case still passes -- which is precisely why it went unnoticed for as long as it
#     did.
#
#     🔴 THIS MUTATION HUNG THE FIRST TIME IT RAN, AND THE CODE WAS WRONG, NOT THE MUTATION. With
#     the branch disabled, `arity` is -1 for an unknown flag and the advance was a bare
#     `i += arity`, which cancels the ++i and spins forever. The fix was in src/utils/Logger.cpp
#     (`i += std::max(arity, 0)`), not here: a loop index that is only non-negative because of a
#     branch three lines above it is a hang waiting for the next edit, and a hang is scored as
#     neither a catch nor a usable survivor.
mutate "the union check decides nothing again (the defect as it shipped)" \
    "$LOGCPP" \
    '        const int arity = arity_of(token);
        if (arity < 0)' \
    '        const int arity = arity_of(token);
        if (false)' \
    LoggerCliArgsDeathTest.AnUnknownOptionIsRefusedRatherThanSilentlyIgnored \
    LoggerCliArgsDeathTest.AMistypedShortOptionIsRefusedToo \
    KERNEL:unknown-long-flag-refused

# M2. EXISTENCE IS NOT WIRING. The check is written, tested and correct -- and main never calls
#     it. No gtest case in this repository can see this: src/main.cpp is not linked into the test
#     binary. This mutation is the whole reason the gate drives the real ndtwin_kernel.
mutate "the check is never called from main (written, tested, and not wired)" \
    "$MAIN" \
    '    Logger::reject_unknown_flags(argc, argv, deploymentFlags());' \
    '    (void)deploymentFlags();' \
    KERNEL:unknown-long-flag-refused \
    KERNEL:unknown-short-flag-refused

# M3. main's table drifts from main's parser: --topology is still honoured by parse(), and now
#     refused before parse() ever sees it. A refusal is only an improvement while it is accurate,
#     and this is the direction that makes a working command line stop working.
mutate "main's table forgets --topology, so a flag the kernel honours is refused" \
    "$MAIN" \
    '        {"--mode", 1}, {"--topology", 1}, {"--ai", 0}, {"--no-ai", 0}, {"--help", 0}, {"-h", 0},' \
    '        {"--mode", 1}, {"--ai", 0}, {"--no-ai", 0}, {"--help", 0}, {"-h", 0},' \
    KERNEL:all-known-flags-accepted

# M4. Logger's table drifts the same way. Note WHICH case catches it: the loop over
#     logging_flags() cannot -- a flag removed from the table is a flag the loop stops trying --
#     so the catch is the hand-written command line that names --logfile itself. A suite made only
#     of table-driven loops would be blind to exactly this.
mutate "Logger's table forgets --logfile, so the logging flag itself is refused" \
    "$LOGCPP" \
    '        {"--logfile", 1},
        {"-f", 1},' \
    '        {"-f", 1},' \
    LoggerCliArgsTest.ACommandLineUsingBothParsersFlagsIsAccepted

# M5. The value of a value-taking flag is scanned as if it were a flag. `--topology -weird.json`
#     becomes "unknown option '-weird.json'" -- the check refusing a command line on the strength
#     of a filename, which is a new defect wearing the fix's clothes.
mutate "a flag's value is scanned as an option instead of stepped over" \
    "$LOGCPP" \
    '        i += std::max(arity, 0);' \
    '        i += 0;' \
    LoggerCliArgsTest.TheValueOfAValueTakingFlagIsNotScannedAsAnOption

# M6. The refusal stops saying what would have worked. Still non-zero, still names the flag --
#     and the operator is back to guessing, which is most of what the message is for.
#
#     The replacement still CALLS known_option_names and throws the answer away. This build is
#     -Werror with -Wunused-function, so a mutant that simply deleted the call would not compile,
#     and a mutant that does not compile is a survivor: the suite never ran.
mutate "the refusal stops naming the accepted options" \
    "$LOGCPP" \
    '                      << "Accepted options: " << known_option_names(also_known) << "\n"' \
    '                      << known_option_names(also_known).substr(0, 0)' \
    LoggerCliArgsDeathTest.TheRefusalNamesTheOptionsThatWouldHaveBeenAccepted \
    KERNEL:refusal-names-both-tables

# M7. THE PLAUSIBLE WRONG FIX: the message is printed and the run carries on. This is the version
#     a hurried reviewer accepts -- something IS printed now -- and it leaves the run doing exactly
#     what the finding describes, with a warning nobody reads scrolling past.
mutate "the unknown flag is reported and then tolerated (warn, do not refuse)" \
    "$LOGCPP" \
    '                      << "Run with --help for the full usage.\n";
            std::exit(2);' \
    '                      << "Run with --help for the full usage.\n";
            continue;' \
    LoggerCliArgsDeathTest.AnUnknownOptionIsRefusedRatherThanSilentlyIgnored \
    KERNEL:unknown-long-flag-refused

# M8. FINDINGS #70's first half: the --help branch of the logging parser stops answering. It is
#     unreachable in the kernel and reachable in a logging-only binary, and "unreachable here" is
#     not "may quietly stop working".
mutate "the logging parser's --help prints and then falls through instead of exiting" \
    "$LOGCPP" \
    '            std::exit(0);' \
    '            (void)0;' \
    LoggerCliArgsDeathTest.TheHelpBranchOfTheLoggingParserRunsAndPrintsTheOptionBlock \
    LoggerCliArgsDeathTest.TheShortHelpBranchRunsToo

# M9. FINDINGS #69 from the direction the hard-coded list cannot see: the usage advertises a level
#     name the parser does not accept. `verbose` is the one an operator would try, and
#     spdlog::level::from_str answers `off` for it -- so a help text nobody checked against the
#     parser is a help text that recommends turning logging off.
mutate "the usage advertises a level name the parser refuses" \
    "$LOGCPP" \
    '           "  --loglevel, -l <level>     trace, debug, info, warn, err, critical, off\n";' \
    '           "  --loglevel, -l <level>     trace, debug, info, verbose, warn, err, critical, off\n";' \
    LoggerUsageTextTest.EveryLevelNameTheUsageActuallyPrintsIsAcceptedByTheParser

# ================================================================================================
# 6. the widenings -- these MUST survive
# ================================================================================================

# W1. A comment. If anything reddens here, every catch above is measuring "a file was edited and
#     rebuilt" rather than "the behaviour changed".
widen "a comment, nothing else" \
    "$LOGCPP" \
    '        // Not option-shaped, so not this function'"'"'s business: a positional belongs to whoever' \
    '        // Not option-shaped, so none of this function'"'"'s business: a positional is for whoever'

# W2. A third accepted spelling of an existing flag, added in BOTH places a spelling lives: the
#     table the union check reads, and the branch chain the parser reads. Every command line these
#     tests and checks use behaves exactly as before; only a suite that pins the TABLE rather than
#     the behaviour the table produces would notice.
widen "--log-file accepted as a third spelling (table AND parser)" \
    "$LOGCPP" \
    '        {"--logfile", 1},
        {"-f", 1},' \
    '        {"--logfile", 1},
        {"--log-file", 1},
        {"-f", 1},' \
    "$LOGCPP" \
    '        if (arg == "--logfile" || arg == "-f")' \
    '        if (arg == "--logfile" || arg == "--log-file" || arg == "-f")'

# W3. A widening in the CHECK rather than in a table: the end-of-options marker "--" stops being
#     an unknown option. No command line anywhere in this gate contains it, so behaviour is
#     unchanged -- and W2 could not have told a real table lookup from a hard-coded token list,
#     which is why there are two of these.
widen "a bare -- is no longer an unknown option" \
    "$LOGCPP" \
    '        if (token.size() < 2 || token[0] != '"'"'-'"'"')' \
    '        if (token.size() < 2 || token[0] != '"'"'-'"'"' || token == "--")'

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
    echo "  🔴 the suite is red after restore -- a mutant object is still linked in: $FAILED $DIED_IN"; ok=0
else
    echo "  suite green again after restore"
fi
why=$(all_kernel_problems)
if [[ -n "$why" ]]; then
    echo "  🔴 the kernel misbehaves after restore: $why"; ok=0
else
    echo "  ndtwin_kernel behaves again after restore"
fi
if [[ -e "$NOFILE" ]]; then
    echo "  🔴 the --help positive control left $NOFILE behind"; ok=0
else
    echo "  no log file left behind by the --help positive control"
fi

printf '\n=== verdict ===\n'
printf '  %d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"
printf '  %d widenings,  %d wrongly caught\n' "$WIDENINGS" "$WIDENINGS_CAUGHT"
if [[ "$ok" != 1 ]]; then
    echo "  🔴 the tree or the binaries are not in a state that permits a verdict"; exit 2
fi
if (( SURVIVORS == 0 && WIDENINGS_CAUGHT == 0 )); then
    echo "  ✅ every mutation was caught by the check it names, and every widening survived"
    exit 0
fi
exit 1
