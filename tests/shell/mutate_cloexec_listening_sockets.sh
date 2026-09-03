#!/usr/bin/env bash
#
# Mutation gate for FINDINGS #47 -- the kernel's listening sockets must not survive an exec, and
# the message it prints when a port is taken must be about what it found rather than what it
# assumed.
#
# [Co-developed with claude code -- Adam]
#
# Covers tests/test_CloseOnExecSockets.cpp.
#
# WHAT THE DEFECT WAS
#   m_sockfd = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);       // no SOCK_CLOEXEC
#   m_serverAcceptor = make_unique<tcp::acceptor>(...);          // Boost.Asio: also no CLOEXEC
# popen() is fork()+exec("/bin/sh"), so every `sh` and every `curl` this kernel ran inherited both
# listening sockets. Measured 2026-09-03 (round3 step 03): with the kernel's pid gone, :8000 and
# :6343 stayed bound for 2.01-2.22 s in 48/48 trials, restart-inside-the-window failed 6/6, and
# the failure said "Another NDTwin kernel is almost certainly still running" when the holder was
# the dead kernel's own orphaned curl.
#
# THREE FAMILIES THIS GATE IS BUILT TO CATCH, NOT ONE
#   1. the descriptor is inheritable again                      (M1, M2, M3, M4, M6, M7, M10)
#   2. the message asserts more than the evidence supports      (M5, M8, M9)
#   3. an OVER-BROAD "fix" -- close everything, including the   (M11)
#      descriptors the child needs
# (3) is the one a gate written only against (1) would wave through: closing every descriptor in
# the child makes the first family's tests greener than ever and breaks every caller of execArgv,
# which reads the child's stdout for its answer.
#
# 🔴 WIRING IS TESTED SEPARATELY FROM BEHAVIOUR. M6, M7 and M10 leave the socket-opening helpers
# perfectly correct and stop the production path from using them -- this repository's most-repeated
# defect. A gate whose only mutations were inside the helpers would call that a fix.
#
# 🔴 THREE MUTATIONS MUST **NOT** BE CAUGHT (W1, W2, W3). A suite that reddens on them is pinning
# source text rather than behaviour, and every catch above would be worth nothing.
#
# 🔴 A MUTANT THAT DOES NOT COMPILE IS A SURVIVOR, not a skip: the suite never ran. Same for an
# anchor that has moved, and for a run that hangs.
#
# 🔴 GUARDS ITS OWN BASELINE. Four files are snapshotted with `cp -p`, an EXIT trap restores them
# however this exits including Ctrl-C, and the run ends by asserting byte-identity. `cp -p` puts
# the ORIGINAL mtime back -- older than the object built from the mutant -- so ninja would see
# nothing to do and the next mutation would be measured against a binary still containing the
# previous one. A restored file is therefore also `touch`ed, but ONLY if it actually changed:
# include/utils/Utils.hpp is included by most of the tree, and touching it every iteration would
# make this gate unusably slow.
#
# 🔴 NEVER KILLS ANYTHING BY NAME. No pkill, no pgrep: `timeout` owns the only child.
#
# 🔴 BINDS NO FIXED PORT. Every socket the suite opens is bound to port 0, so this gate is safe to
# run while a kernel is up on :8000/:6343 -- and it does not disturb one.
#
# 🔴 BUILD UNDER THE GUARD. This laptop's oomd took the user's own application down on 2026-09-02.
#   tools/build_guard/guarded_build.sh ./tests/shell/mutate_cloexec_listening_sockets.sh
#
# Usage:  tools/build_guard/guarded_build.sh ./tests/shell/mutate_cloexec_listening_sockets.sh
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
FILTER='CloseOnExecSocketsTest*:PortOwnershipMessageTest*'

FDCPP=src/utils/FdHygiene.cpp
COLL=src/ndt_core/collection/FlowLinkUsageCollector.cpp
HAND=src/ndt_core/event_handling/ControllerAndOtherEventHandler.cpp
UTILS=include/utils/Utils.hpp
FILES=("$FDCPP" "$COLL" "$HAND" "$UTILS")

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
        touch "$f"          # cp -p brings the old mtime back and ninja would believe it
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

add_anchor "cloexec-socket"    "$FDCPP" '    return ::socket(domain, type | SOCK_CLOEXEC, protocol);'
add_anchor "set-cloexec"       "$FDCPP" '    return ::fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0;'
add_anchor "is-cloexec"        "$FDCPP" '    return flags >= 0 && (flags & FD_CLOEXEC) != 0;'
add_anchor "render-entry"      "$FDCPP" '    std::ostringstream out;
    const std::string proto_name = protocolName(proto);'
add_anchor "self-among-them"   "$FDCPP" '    const bool selfAmongThem =
        std::any_of(ownership.holders.begin(),
                    ownership.holders.end(),
                    [&](const PortHolder& h) { return h.comm == selfProgramName; });'
add_anchor "attribute-holder"  "$FDCPP" '            found = true;'
add_anchor "kernel-sentence"   "$FDCPP" '        out << "One of them is another " << selfProgramName
            << ": stop it before starting this one.";'
add_anchor "fd-comment"        "$FDCPP" '/// Splits on runs of spaces. /proc/net/* is column-aligned, so empty fields never occur.'
add_anchor "collector-socket"  "$COLL"  '    int sockfd = utils::cloexecSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);'
add_anchor "collector-message" "$COLL"  '        const std::string who =
            utils::diagnosePortInUse(port, utils::PortProtocol::Udp, "ndtwin_kernel");'
add_anchor "acceptor-marked"   "$HAND"  '    if (!utils::setCloseOnExec(acceptor->native_handle()))'
add_anchor "start-uses-factory" "$HAND" '    m_serverAcceptor = openApiAcceptor(m_ioContext, port);'
add_anchor "accept-adopts"     "$HAND"  '            adoptAcceptedSocket(*sock);'
add_anchor "execargv-closerange" "$UTILS" '        (void)::close_range(3, ~0U, 0);'

echo "=== anchor uniqueness (exact substring count must be 1) ==="
anchor_ok=1
for i in "${!ANCHOR_NAME[@]}"; do
    n=$(count_exact "${ANCHOR_FILE[$i]}" "${ANCHOR_TEXT[$i]}")
    printf '  %-6s %-22s %-52s x%s\n' \
        "$([[ "$n" == 1 ]] && echo ok || echo REFUSE)" "${ANCHOR_NAME[$i]}" "${ANCHOR_FILE[$i]}" "$n"
    [[ "$n" == 1 ]] || anchor_ok=0
done
[[ "$anchor_ok" == 1 ]] || { echo "🔴 anchors have drifted; this gate cannot render a verdict" >&2; exit 2; }

# --- 3. build + run helpers ---------------------------------------------------------------------
build() { cmake --build "$BUILD_DIR" --target "$TARGET" -j"$JOBS" >/dev/null 2>&1; }

# run_tests <gtest_filter> -> sets STATUS RC OUT FAILED DIED_IN. rc comes from the binary itself
# and is never taken through a pipe: a pipeline's status belongs to its last stage.
#
# 🔴 A CASE CAN GO RED WITHOUT A `[  FAILED  ]` LINE. A mutation here can make the process die --
# an unhandled boost exception out of an acceptor, a hang in the accept path -- and gtest never
# gets to report it. Reading "no FAILED line" as "nothing went red" would turn a mutation that did
# enormous damage into a survivor. DIED_IN is the last case gtest announced, empty when it
# announced none, which stays a survivor.
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
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# widen <label> <file> <anchor> <new> -- a change that must leave EVERY test green. These are what
# give the catches above their meaning.
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
# 5. the mutations
# ================================================================================================

# --- family 1: the descriptor becomes inheritable again -----------------------------------------

# M1. THE DEFECT EXACTLY AS IT SHIPPED, at the one place every socket this process creates goes
#     through. Everything downstream still calls cloexecSocket(); it just stops doing anything.
mutate "cloexecSocket stops asking for SOCK_CLOEXEC" \
    "$FDCPP" \
    '    return ::socket(domain, type | SOCK_CLOEXEC, protocol);' \
    '    return ::socket(domain, type, protocol);' \
    CloseOnExecSocketsTest.TheSflowReceiveSocketIsCloseOnExec \
    CloseOnExecSocketsTest.AChildCannotSeeTheSflowReceiveSocket

# M2. The marker for descriptors a library handed us reports success without doing anything -- the
#     shape a "fix" takes when someone silences a warning instead of removing its cause.
mutate "setCloseOnExec reports success without setting the flag" \
    "$FDCPP" \
    '    return ::fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0;' \
    '    return true;' \
    CloseOnExecSocketsTest.TheApiAcceptorIsCloseOnExec \
    CloseOnExecSocketsTest.AChildCannotSeeTheApiAcceptor \
    CloseOnExecSocketsTest.AnAcceptedConnectionIsMarkedCloseOnExec \
    CloseOnExecSocketsTest.AStartedServerHasACloseOnExecAcceptor \
    CloseOnExecSocketsTest.AConnectionAcceptedByTheRunningServerIsCloseOnExec

# M3. The sFlow socket goes back to a bare ::socket() while the shared helper stays correct. This
#     is the site the finding was measured on, and no helper-level test can see it.
mutate "the sFlow socket is created with a bare ::socket() again" \
    "$COLL" \
    '    int sockfd = utils::cloexecSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);' \
    '    int sockfd = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);' \
    CloseOnExecSocketsTest.TheSflowReceiveSocketIsCloseOnExec \
    CloseOnExecSocketsTest.AChildCannotSeeTheSflowReceiveSocket

# M4. The acceptor is created and never marked -- Boost.Asio's own behaviour, restored.
mutate "the API acceptor is left as Boost.Asio made it" \
    "$HAND" \
    '    if (!utils::setCloseOnExec(acceptor->native_handle()))' \
    '    if (false)' \
    CloseOnExecSocketsTest.TheApiAcceptorIsCloseOnExec \
    CloseOnExecSocketsTest.AChildCannotSeeTheApiAcceptor \
    CloseOnExecSocketsTest.AStartedServerHasACloseOnExecAcceptor

# --- family 1b: the WIRING. The helpers stay correct; nothing calls them. ------------------------

# M5. start() builds its own acceptor instead of using the factory. openApiAcceptor() is still
#     there, still correct, still tested -- and the running kernel does not use it. This is the
#     defect shape this repository has hit most often, and it is invisible to any test that
#     exercises the helper directly.
mutate "start() bypasses openApiAcceptor and constructs the acceptor itself" \
    "$HAND" \
    '    m_serverAcceptor = openApiAcceptor(m_ioContext, port);' \
    '    m_serverAcceptor = make_unique<tcp::acceptor>(m_ioContext, tcp::endpoint{tcp::v4(), port});' \
    CloseOnExecSocketsTest.AStartedServerHasACloseOnExecAcceptor

# M6. Same shape, one layer down: the accept path stops adopting what it accepted.
mutate "doAccept() stops marking the connection it accepted" \
    "$HAND" \
    '            adoptAcceptedSocket(*sock);' \
    '            ;' \
    CloseOnExecSocketsTest.AConnectionAcceptedByTheRunningServerIsCloseOnExec

# --- family 2: the message claims more than it found --------------------------------------------

# M7. THE MESSAGE EXACTLY AS IT SHIPPED. Printed without looking at anything, and false in the one
#     situation it was actually printed in.
mutate "the diagnosis goes back to asserting another kernel is running" \
    "$FDCPP" \
    '    std::ostringstream out;
    const std::string proto_name = protocolName(proto);' \
    '    return "Another NDTwin kernel is almost certainly still running and holding it.";
    std::ostringstream out;
    const std::string proto_name = protocolName(proto);' \
    PortOwnershipMessageTest.OrphanedChildrenAreNotReportedAsAnotherKernel \
    PortOwnershipMessageTest.AnUnattributableHolderIsNotCalledAKernel \
    PortOwnershipMessageTest.NoSocketFoundSaysSoInsteadOfInventingAHolder \
    PortOwnershipMessageTest.TheSflowBindFailureNamesTheRealHolderRatherThanBlamingAKernel

# M8. The opposite error, and it is an error: a message that can never name a second kernel is
#     useless in the case the original sentence was written for.
mutate "the diagnosis can no longer recognise a real second kernel" \
    "$FDCPP" \
    '    const bool selfAmongThem =
        std::any_of(ownership.holders.begin(),
                    ownership.holders.end(),
                    [&](const PortHolder& h) { return h.comm == selfProgramName; });' \
    '    const bool selfAmongThem = false;' \
    PortOwnershipMessageTest.AnotherKernelIsNamedWhenOneIsActuallyHoldingThePort

# M9. The renderer is honest and the scan finds nobody, so every real diagnosis collapses to "no
#     attributable holder". The pure message cases cannot see this; only a scan run against a
#     socket the test itself is holding can.
mutate "the /proc walk never attributes the port to any process" \
    "$FDCPP" \
    '            found = true;' \
    '            found = false;' \
    PortOwnershipMessageTest.TheProcScanFindsThisProcessHoldingItsOwnPort \
    PortOwnershipMessageTest.TheSflowBindFailureNamesTheRealHolderRatherThanBlamingAKernel

# M10. The collector keeps its close-on-exec socket and goes back to the hard-coded sentence. The
#     wiring mutation for the message: describePortOwnership() stays perfect and unused.
mutate "the bind failure stops consulting /proc and hard-codes the old sentence" \
    "$COLL" \
    '        const std::string who =
            utils::diagnosePortInUse(port, utils::PortProtocol::Udp, "ndtwin_kernel");' \
    '        const std::string who =
            "Another NDTwin kernel is almost certainly still running and holding it.";' \
    PortOwnershipMessageTest.TheSflowBindFailureNamesTheRealHolderRatherThanBlamingAKernel

# --- family 3: the over-broad "fix" -------------------------------------------------------------

# M11. Dropping the belt-and-braces close in execArgv's child. CLOEXEC alone still covers the
#     sockets this fix marks, so nothing in family 1 notices; only a descriptor deliberately left
#     unmarked can see it.
mutate "execArgv's child stops closing the descriptors nobody marked" \
    "$UTILS" \
    '        (void)::close_range(3, ~0U, 0);' \
    '        ;' \
    CloseOnExecSocketsTest.ExecArgvChildDoesNotInheritAnUnmarkedDescriptor

# M12. 🔴 THE OVER-BROAD FIX. "Close everything" passes every descriptor-leak test in this file and
#     breaks the program: the child's stdout is the pipe every execArgv caller reads its answer
#     from -- curl's HTTP status, snmpget's value, ovs-vsctl's port list. A gate that did not carry
#     this mutation would call a total loss of output a hardening.
mutate "execArgv's child closes stdin/stdout/stderr as well" \
    "$UTILS" \
    '        (void)::close_range(3, ~0U, 0);' \
    '        (void)::close_range(0, ~0U, 0);' \
    CloseOnExecSocketsTest.ExecArgvChildKeepsTheDescriptorsItNeeds

# ================================================================================================
# 6. the widenings -- these MUST survive
# ================================================================================================

# W1. A comment. If anything reddens here, every catch above is measuring "a file was edited and
#     rebuilt" rather than "the behaviour changed".
widen "a comment, nothing else" \
    "$FDCPP" \
    '/// Splits on runs of spaces. /proc/net/* is column-aligned, so empty fields never occur.' \
    '/// Splits on runs of spaces; /proc/net/* is column-aligned so an empty field cannot occur.'

# W2. The same predicate, written differently. `(flags & FD_CLOEXEC) != 0` and
#     `== FD_CLOEXEC` agree for every value of flags; only a test pinning the source would notice.
widen "isCloseOnExec tests the same bit a different way" \
    "$FDCPP" \
    '    return flags >= 0 && (flags & FD_CLOEXEC) != 0;' \
    '    return flags >= 0 && (flags & FD_CLOEXEC) == FD_CLOEXEC;'

# W3. The prose around the discriminating phrase is reworded. The message cases must be pinned to
#     "is this another kernel or not", not to the sentence that carries the answer.
widen "the second-kernel sentence is reworded around the phrase that matters" \
    "$FDCPP" \
    '        out << "One of them is another " << selfProgramName
            << ": stop it before starting this one.";' \
    '        out << "One of them is another " << selfProgramName
            << ", which must be stopped before this one starts.";'

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
echo "  test binary: $(sha256sum "$BIN" 2>/dev/null | cut -c1-16) (was $BIN_SHA_BEFORE)"

printf '\n=== verdict ===\n'
printf '  %d mutations, %d survived\n' "$MUTATIONS" "$SURVIVORS"
printf '  %d widenings, %d wrongly caught\n' "$WIDENINGS" "$WIDENINGS_CAUGHT"

if [[ "$ok" != 1 ]]; then exit 2; fi
if (( SURVIVORS > 0 || WIDENINGS_CAUGHT > 0 )); then exit 1; fi
echo "  FINDINGS #47 gate: every mutation was caught by the test it names, and every"
echo "  behaviour-preserving change was left alone."
exit 0
