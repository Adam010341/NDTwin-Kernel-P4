#!/usr/bin/env bash
#
# Mutation gate for FINDINGS #63 -- `--logfile` must consume the path it is given, and a request
# the parser cannot honour must be REFUSED rather than accepted and dropped.
#
# [Co-developed with claude code -- Adam]
#
# Covers tests/test_LoggerCliArgs.cpp and the reachable `ndtwin_kernel --help` text.
#
# WHAT THE DEFECT WAS
#   if (arg == "--logfile" || arg == "-f") { cfg.enableFile = true; }
# The next argv was never consumed, so `--logfile /where/i/want.log` turned file logging on,
# discarded the path, and wrote to a hard-coded netdt.log in the process's cwd. Measured live on
# 2026-09-03: build/netdt.log = 74 942 bytes, the named file = 0, stderr silent.
#
# THREE THINGS THIS GATE IS BUILT TO CATCH, NOT ONE
#   1. the path is not consumed, or not carried to the sink       (M1, M2, M3)
#   2. a request that cannot be honoured is accepted anyway       (M4, M5, M8)
#   3. the help text and the behaviour disagree                   (M6, M9)
# A gate that only checked (1) would go green on a "fix" that quietly opened a default file.
#
# 🔴 THREE MUTATIONS MUST **NOT** BE CAUGHT (W1, W2, W3). A suite that reddens on them is pinning
# the source text rather than the behaviour, and every catch above would be worth nothing:
#   W1  a comment                       -- the classic control
#   W2  a THIRD accepted spelling of the same flag (--log-file) -- a widening: every command line
#       the tests use behaves identically, so a red here means the tests pin the flag's spelling
#   W3  reworded text in an UNRELATED part of main.cpp's usage -- proves the --help phase is
#       reading the logging block and not merely noticing that main.cpp changed
#
# 🔴 A MUTANT THAT DOES NOT COMPILE IS A SURVIVOR, not a skip: the suite never ran, so it proves
# nothing. Same for an anchor that has moved, and for a run that hangs.
#
# 🔴 GUARDS ITS OWN BASELINE. Three files are snapshotted with `cp -p` before anything is touched,
# an EXIT trap restores them however this exits including Ctrl-C, and the run ends by asserting
# byte-identity against the snapshot. `cp -p` restores the ORIGINAL mtime -- which is older than
# the object built from the mutant -- so ninja would see nothing to do and the NEXT mutation would
# be measured against a binary still containing the previous one, while the source on disk looked
# pristine. A restored file is therefore also `touch`ed -- but ONLY a file that actually changed,
# because touching the header on every iteration makes ninja rebuild all 83 TUs that include it.
# This trap has bitten this repo before; see tests/shell/mutate_rate_denominator.sh.
#
# 🔴 NEVER KILLS ANYTHING BY NAME. No pkill, no pgrep: `timeout` owns the only child. Nothing here
# starts Mininet, bmv2, OVS or a listening socket -- `ndtwin_kernel --help` prints and returns 0
# before any subsystem is constructed.
#
# 🔴 BUILD UNDER THE GUARD. This laptop's oomd took the user's own application down on 2026-09-02.
#   tools/build_guard/guarded_build.sh ./tests/shell/mutate_logfile_takes_a_path.sh
# JOBS defaults to 2 here as well, so an unguarded run is capped too, but only the guard's cgroup
# protects anything other than this build.
#
# Usage:  tools/build_guard/guarded_build.sh ./tests/shell/mutate_logfile_takes_a_path.sh
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
KERNEL=ndtwin_kernel
BIN="$BUILD_DIR/bin/$TARGET"
KBIN="$BUILD_DIR/bin/$KERNEL"
FILTER='LoggerCliArgs*:LoggerFileSink*:LoggerUsageText*'

LOGCPP=src/utils/Logger.cpp
LOGHPP=include/utils/Logger.hpp
MAIN=src/main.cpp
FILES=("$LOGCPP" "$LOGHPP" "$MAIN")

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
        # 🔴 ONLY the file a mutation actually changed is put back, and only that file is touched.
        # Touching all three every time made ninja recompile every TU that includes Logger.hpp --
        # 83 of them -- after each mutation, which turned a ~40-second iteration into a six-minute
        # one and would have made this gate too slow to run. `cmp` first, act second.
        cmp -s "${SNAP[$f]}" "$f" && continue
        cp -p "${SNAP[$f]}" "$f"
        touch "$f"          # see the header: cp -p brings the old mtime back and ninja believes it
    done
}
trap 'restore; rm -rf "$BK"' EXIT

# --- 2. anchors ---------------------------------------------------------------------------------
# Declared before anything is touched, every one exactly once. An anchor that matched twice would
# mutate a site the mutation is not named for; one that matches zero times means the source moved
# under the gate, and "could not be applied" must never be reported as "was caught".
count_exact() {
    python3 - "$1" "$2" <<'PYCOUNT'
import sys, pathlib
sys.stdout.write(str(pathlib.Path(sys.argv[1]).read_text().count(sys.argv[2])))
PYCOUNT
}

declare -a ANCHOR_FILE ANCHOR_TEXT ANCHOR_NAME
add_anchor() { ANCHOR_NAME+=("$1"); ANCHOR_FILE+=("$2"); ANCHOR_TEXT+=("$3"); }

add_anchor "logfile-consumes"   "$LOGCPP" '            cfg.filePath = require_value(arg, i, argc, argv);'
add_anchor "sink-uses-path"     "$LOGCPP" '                cfg.filePath, /*truncate=*/false);'
add_anchor "index-advance"      "$LOGCPP" '    ++i;
    return value;'
add_anchor "missing-refused"    "$LOGCPP" '        std::cerr << flag << " requires a value, and none was given.\n\n"
                  << Logger::cli_usage();
        std::exit(2);'
add_anchor "flag-shaped-guard"  "$LOGCPP" "    if (value.size() > 1 && value[0] == '-')"
add_anchor "sink-guard"         "$LOGCPP" '    if (!cfg.filePath.empty())
    {
        try
        {
            auto file_sink = std::make_shared<spdlog::sinks::basic_file_sink_mt>(
                cfg.filePath, /*truncate=*/false);'
add_anchor "usage-first-line"   "$LOGCPP" '    return "  --logfile, -f <path>       also write every log line to <path>. The path is\n"'
add_anchor "level-typo-guard"   "$LOGCPP" '    if (level == spdlog::level::off && name != "off")'
add_anchor "flag-spelling"      "$LOGCPP" '        if (arg == "--logfile" || arg == "-f")'
add_anchor "usage-comment"      "$LOGCPP" "    // Column 30, to line up with the deployment options in src/main.cpp's usage block."
add_anchor "main-prints-usage"  "$MAIN"   '        << Logger::cli_usage()'
add_anchor "main-unrelated"     "$MAIN"   '           "  --ai / --no-ai             enable or disable the Intent Translator\n"'
add_anchor "config-field"       "$LOGHPP" '    std::string filePath;'

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
# Both targets: the test binary owns the parser and the sink, the kernel owns the only --help a
# user can actually reach.
build() {
    cmake --build "$BUILD_DIR" --target "$TARGET" -j"$JOBS" >/dev/null 2>&1 &&
        cmake --build "$BUILD_DIR" --target "$KERNEL" -j"$JOBS" >/dev/null 2>&1
}

# run_tests <gtest_filter> -> sets STATUS RC OUT FAILED DIED_IN. rc comes from the binary itself
# and is never taken through a pipe, because a pipeline's status belongs to its last stage.
#
# 🔴 THREE WAYS A TEST GOES RED, AND ONLY ONE OF THEM PRINTS A `[  FAILED  ]` LINE. The code under
# test here calls std::exit on a refused request, so a mutation can make it exit from inside a
# case -- or from inside the GLOBAL TEST ENVIRONMENT, before any case starts. gtest never gets to
# report either one. Reading "no FAILED line" as "nothing went red" turns a mutation that was
# applied and did enormous damage into a survivor, and reading it as a catch when the process died
# before the first [ RUN ] would credit a test that never executed. DIED_IN is the last case gtest
# announced, and is empty when it announced none -- which stays a survivor, loudly.
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

# help_problem -- echoes the reason the reachable --help is wrong, or nothing when it is right.
# This is the half of the defect that is not code: `main.cpp` used to say "Logging options are
# also accepted; see --logfile / --loglevel" and there was nowhere to see them, because Logger's
# own --help branch is unreachable from this binary.
help_problem() {
    local out
    out=$(timeout 30 "$KBIN" --help 2>&1)
    if [[ -z "$out" ]]; then echo "the kernel printed no usage at all"; return; fi
    grep -qF -- '--logfile, -f <path>' <<<"$out" ||
        { echo "--help does not show --logfile taking a path"; return; }
    grep -qF -- '--loglevel, -l <level>' <<<"$out" ||
        { echo "--help does not show --loglevel taking a value"; return; }
    grep -qF -- 'see --logfile / --loglevel' <<<"$out" &&
        { echo "--help still points at a help text this binary can never print"; return; }
    grep -qF -- 'netdt.log' <<<"$out" &&
        { echo "--help still names the old hard-coded file"; return; }
    echo ""
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

# mutate <label> <file> <anchor> <new> <expect-red...>
# Every named test must be red. "Something went red" is not the check -- WHICH light went red is;
# two tests in this repository have previously reddened on a mutation aimed at other behaviour.
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

    local missed=() got=() t
    if [[ "${expected[0]}" == "HELP" ]]; then
        local why; why=$(help_problem)
        if [[ -n "$why" ]]; then
            printf '  ✅ caught  the reachable --help is wrong: %s\n' "$why"
        else
            echo "  🔴 SURVIVED -- ndtwin_kernel --help still reads correctly"
            SURVIVORS=$((SURVIVORS + 1))
        fi
        restore; return
    fi

    local filter=""
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
            printf '  ✅ caught  reason=the process exited %d inside %s (no FAILED line: gtest\n            never got to report)\n' "$RC" "$DIED_IN"
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

# widen <label> <file> <anchor> <new> -- a change that must leave EVERY test green and the
# reachable --help correct. These are what give the catches above their meaning.
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
    local why; why=$(help_problem)
    if [[ "$STATUS" == pass && -z "$why" ]]; then
        echo "  ✅ survived -- behaviour unchanged, so the catches above are about behaviour"
    else
        [[ "$STATUS" != pass ]] && echo "  🔴 CAUGHT: tests went red on a behaviour-preserving change: $FAILED"
        [[ -n "$why" ]] && echo "  🔴 CAUGHT: the --help check fired on an unrelated edit: $why"
        echo "     This gate cannot tell an edit from a behaviour change."
        WIDENINGS_CAUGHT=$((WIDENINGS_CAUGHT + 1))
    fi
    restore
}

# --- 4. baseline --------------------------------------------------------------------------------
echo
echo "=== baseline (unmutated working tree) must build, be green, and print a correct --help ==="
if ! build; then
    echo "🔴 THE BASELINE DOES NOT COMPILE. Nothing below would mean anything." >&2
    cmake --build "$BUILD_DIR" --target "$TARGET" -j"$JOBS" 2>&1 | tail -40 >&2
    exit 2
fi
[[ -x "$BIN" ]]  || { echo "🔴 $BIN is missing after a successful build" >&2; exit 2; }
[[ -x "$KBIN" ]] || { echo "🔴 $KBIN is missing after a successful build" >&2; exit 2; }
BIN_SHA_BEFORE=$(sha256sum "$BIN" | cut -c1-16)

run_tests "$FILTER"
case "$STATUS" in
  pass) echo "  ok       baseline green ($(grep -c '^\[       OK \]' <<<"$OUT") cases in $FILTER)" ;;
  hang) echo "🔴 BASELINE HUNG (>${TEST_TIMEOUT}s). Not a red; the gate cannot proceed." >&2; exit 2 ;;
  *)    echo "🔴 THE BASELINE IS ALREADY RED: $FAILED" >&2
        echo "   Every 'expect red' below would be meaningless. Stopping." >&2; exit 2 ;;
esac
baseline_help=$(help_problem)
if [[ -n "$baseline_help" ]]; then
    echo "🔴 THE BASELINE'S OWN --help IS WRONG: $baseline_help" >&2; exit 2
fi
echo "  ok       ndtwin_kernel --help names --logfile <path> and --loglevel <level>"
echo "  ok       $TARGET sha256 $BIN_SHA_BEFORE"

# ================================================================================================
# 5. the mutations
# ================================================================================================

# M1. THE DEFECT EXACTLY AS IT SHIPPED: the flag is a boolean again and the name is hard-coded.
#     require_value stays reachable through --loglevel, so this compiles -- a mutant that failed
#     to compile would be a survivor and would have told us nothing.
mutate "the flag is a boolean again: the path is not consumed, netdt.log is hard-coded" \
    "$LOGCPP" \
    '            cfg.filePath = require_value(arg, i, argc, argv);' \
    '            cfg.filePath = "netdt.log";' \
    LoggerCliArgsTest.LogfileConsumesThePathThatFollowsIt \
    LoggerCliArgsTest.TheShortFormConsumesAPathToo

# M2. The path is parsed correctly and then thrown away one layer down. This is the half a
#     parser-only test cannot see, and it is why the sink test reads the bytes back out.
mutate "the sink ignores the config and reopens the hard-coded netdt.log" \
    "$LOGCPP" \
    '                cfg.filePath, /*truncate=*/false);' \
    '                "netdt.log", /*truncate=*/false);' \
    LoggerFileSinkTest.InitWritesToThePathTheConfigNamesAndToNoOther

# M3. The index advances twice, so the option AFTER the path is eaten. The run then comes back at
#     the default level having been asked for another -- accepted, no effect, no message: the
#     same shape as the defect, moved one argument to the right.
mutate "consuming the path eats the next option too" \
    "$LOGCPP" \
    '    ++i;
    return value;' \
    '    i += 2;
    return value;' \
    LoggerCliArgsTest.TheOptionAfterTheLogfilePathIsStillParsed

# M4. A missing value goes back to being silently tolerated -- exactly what `--loglevel` used to
#     do with its `&& i + 1 < argc` guard: no match, no branch, no message, default kept.
mutate "a missing value is silently accepted instead of refused" \
    "$LOGCPP" \
    '        std::cerr << flag << " requires a value, and none was given.\n\n"
                  << Logger::cli_usage();
        std::exit(2);' \
    '        return std::string();' \
    LoggerCliArgsDeathTest.LogfileWithNoPathIsRefusedRatherThanDefaulted \
    LoggerCliArgsDeathTest.LoglevelWithNoValueIsRefusedRatherThanIgnored

# M5. "The user mistyped" collapses back into "the user did not type": `--logfile --no-ai` becomes
#     a log file named --no-ai, and main.cpp's parser -- walking the same argv -- claims the same
#     token for itself. Two parsers disagreeing about what the command line said.
mutate "a following option is taken as the value" \
    "$LOGCPP" \
    "    if (value.size() > 1 && value[0] == '-')" \
    "    if (false && value.size() > 1 && value[0] == '-')" \
    LoggerCliArgsDeathTest.LogfileFollowedByAnotherOptionIsRefused \
    LoggerCliArgsDeathTest.LoglevelFollowedByAnotherOptionIsRefused

# M6. The help text drifts back to describing a behaviour the program no longer has. A wrong
#     usage string is a defect in the same way a wrong return value is -- it is what the operator
#     acts on -- and this is the mutation that proves the text is pinned rather than decorative.
mutate "the usage text goes back to promising a hard-coded netdt.log" \
    "$LOGCPP" \
    '    return "  --logfile, -f <path>       also write every log line to <path>. The path is\n"' \
    '    return "  --logfile, -f       also write logs to netdt.log\n"' \
    LoggerUsageTextTest.TheUsageShowsLogfileTakingAPath \
    LoggerUsageTextTest.TheUsageNoLongerPromisesAHardCodedFilename

# M7. The sink opens a file nobody asked for. A "fix" shaped like this passes every positive case
#     -- the named path still works -- while quietly restoring the default file the finding is
#     about. Only the negative case can see it.
#
#     🔴 THE FIRST VERSION OF THIS MUTATION WAS UNUSABLE AND THE GATE SAID SO. Dropping the guard
#     alone (`if (true)`) makes init open "" -- which throws, which the catch turns into
#     std::exit(2), and that happens in the GLOBAL TEST ENVIRONMENT before a single case starts.
#     The binary died with no [ RUN ] line, so no test could be named red and a mutation that had
#     been applied was reported as a survivor. Supplying a default name is both the realistic
#     wrong fix and the version that leaves the harness able to answer.
#
#     The default is deliberately NOT "netdt.log": a name that cannot already exist means the gate
#     can delete it unconditionally afterwards, instead of having to reason about whose file it
#     found in the working tree.
mutate "a default log file is opened when none was requested" \
    "$LOGCPP" \
    '    if (!cfg.filePath.empty())
    {
        try
        {
            auto file_sink = std::make_shared<spdlog::sinks::basic_file_sink_mt>(
                cfg.filePath, /*truncate=*/false);' \
    '    if (true)
    {
        try
        {
            auto file_sink = std::make_shared<spdlog::sinks::basic_file_sink_mt>(
                cfg.filePath.empty() ? std::string("netdt-mutant-default.log") : cfg.filePath,
                /*truncate=*/false);' \
    LoggerFileSinkTest.AnEmptyPathOpensNoFile
rm -f netdt-mutant-default.log

# M8. Same family, one flag over: spdlog::level::from_str is NOEXCEPT and answers `off` for every
#     name it does not know, so removing this check does not restore an error -- it makes a
#     mistyped level turn logging OFF, silently, with status 0.
mutate "a mistyped log level silently disables logging instead of being refused" \
    "$LOGCPP" \
    '    if (level == spdlog::level::off && name != "off")' \
    '    if (false)' \
    LoggerCliArgsDeathTest.AMistypedLevelIsRefusedRatherThanSilentlyDisablingLogging

# M9. The reachable --help stops carrying the logging options and goes back to pointing at a help
#     text this binary can never print. No gtest case can see this: main.cpp is not linked into
#     the test binary. The check is the kernel's own --help output.
mutate "the kernel's --help stops printing the logging options" \
    "$MAIN" \
    '        << Logger::cli_usage()' \
    '        << "Logging options are also accepted; see --logfile / --loglevel.\n"' \
    HELP

# ================================================================================================
# 6. the widenings -- these MUST survive
# ================================================================================================

# W1. A comment. If anything reddens here, every catch above is measuring "a file was edited and
#     rebuilt" rather than "the behaviour changed".
widen "a comment, nothing else" \
    "$LOGCPP" \
    "    // Column 30, to line up with the deployment options in src/main.cpp's usage block." \
    "    // Column 30, so this lines up with the deployment options in src/main.cpp."

# W2. A third accepted spelling of the same flag. Every command line these tests use behaves
#     exactly as before; only a suite that pins the flag's SPELLING rather than its behaviour
#     would notice. This is the control for over-fitting.
widen "--log-file accepted as a third spelling" \
    "$LOGCPP" \
    '        if (arg == "--logfile" || arg == "-f")' \
    '        if (arg == "--logfile" || arg == "--log-file" || arg == "-f")'

# W3. Reworded text in an unrelated part of main.cpp's usage. The --help phase must be reading the
#     logging block, not noticing that main.cpp changed.
widen "an unrelated line of main.cpp's usage is reworded" \
    "$MAIN" \
    '           "  --ai / --no-ai             enable or disable the Intent Translator\n"' \
    '           "  --ai / --no-ai             turn the Intent Translator on or off\n"'

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
# M7's mutant writes a log file into the working tree. It is removed beside the mutation; this is
# the check that says so, because a gate that leaves litter is a gate whose next run starts dirty.
if [[ -e netdt-mutant-default.log ]]; then
    echo "  🔴 M7's mutant left netdt-mutant-default.log in the working tree"; ok=0
else
    echo "  no mutant log file left in the working tree"
fi
echo "  test binary: $(sha256sum "$BIN" 2>/dev/null | cut -c1-16) (was $BIN_SHA_BEFORE)"

printf '\n=== verdict ===\n'
printf '  %d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"
printf '  %d widenings, %d wrongly caught\n' "$WIDENINGS" "$WIDENINGS_CAUGHT"

if [[ "$ok" != 1 ]]; then exit 2; fi
if (( SURVIVORS > 0 || WIDENINGS_CAUGHT > 0 )); then exit 1; fi
echo "  FINDINGS #63 gate: every mutation was caught by the test it names, and every"
echo "  behaviour-preserving change was left alone."
exit 0
