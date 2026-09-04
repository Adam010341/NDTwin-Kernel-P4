#!/usr/bin/env bash
#
# Mutation gate for the KNOWN-ISSUES A-7 follow-up: the dispatch-status endpoint's
# running/scope disclosure, its contract, and FINDING-07's table disclosure in the P4 proxy.
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration. This applies each mutation, rebuilds
# or re-runs as the lane requires, and records WHICH test went red -- not merely that something
# did. The identity matters here more than usual, because the change spans three suites that can
# be green for unrelated reasons:
#
#   cpp       tests/test_FlowDispatcher.cpp        does running() track start/stop
#   proxy     p4_proxy/tests/test_flowentry_*.py   does the add response name the table it hit
#   contract  tools/contract_test --self-test      does the endpoint's schema/invariants bite
#
# 🔴 DELIBERATE DIVERGENCE FROM tests/shell/mutate_f6_stale_table_carry_forward.sh, which this
# is otherwise written to match: f6 treats a mutant that does not compile as "proves nothing"
# and decrements the count. Here a compile failure is a SURVIVOR. The reason is that a mutation
# which cannot be built has not been shown to be caught, and on a shared tree the tempting
# reading of "it did not compile" is "it passed". Same for an anchor that has moved and for the
# wrong test going red. Every way of not-proving-it is counted the same way: survived.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# and the run asserts byte-identity at the end. The baseline is the WORKING TREE, not HEAD, so
# this runs against an uncommitted fix.
#
# Usage:
#   tests/shell/mutate_a7_dispatch_status.sh              full gate (needs a configured BUILD_DIR)
#   tests/shell/mutate_a7_dispatch_status.sh --dry-run    anchors only, NOT a gate result
#   tests/shell/mutate_a7_dispatch_status.sh --python-only the two Python lanes, PARTIAL result
#   BUILD_DIR=build-asan tests/shell/mutate_a7_dispatch_status.sh
#
# Assumes: cwd is the repo root. The full run needs ${BUILD_DIR:-build} already configured
# (ninja); --dry-run and --python-only need no build at all, which is why they exist -- this
# machine runs CPU-sensitive measurements and a build is not always affordable.
#
# Exit: 0 every mutation caught, 1 a mutation survived, 2 refused (harness fault only:
#       missing file, unconfigured build, red baseline, or a tree left unrestored).
set -uo pipefail

BUILD_DIR="${BUILD_DIR:-build}"
TARGET=test_routing_strategy
BIN="$BUILD_DIR/bin/$TARGET"
FILTER='FlowDispatcherTest.*'

DSP=include/ndt_core/routing_management/FlowDispatcher.hpp
DSC=src/ndt_core/routing_management/FlowDispatcher.cpp
SES=src/ndt_core/http/HttpSession.cpp
API=p4_proxy/proxy_agent/api_routes.py
SPC=tools/contract_test/spec.py
FILES=("$DSP" "$DSC" "$SES" "$API" "$SPC")

# The proxy's own venv, not miniconda: the handlers import fastapi, which miniconda's python3
# does not have. A missing interpreter is a harness fault, not a survivor -- it proves nothing.
PROXY_PY="${PROXY_PY:-/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python3}"
CONTRACT_PY="${CONTRACT_PY:-/home/adam/miniconda3/bin/python3}"

MODE=full
case "${1:-}" in
    --dry-run)     MODE=dryrun ;;
    --python-only) MODE=python ;;
    "")            ;;
    *) echo "REFUSE: unknown argument '$1'. Use --dry-run or --python-only." >&2; exit 2 ;;
esac

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "REFUSE: $f not found -- run from the repo root." >&2; exit 2; }
done

if [[ "$MODE" != dryrun ]]; then
    [[ -x "$PROXY_PY" ]] || {
        echo "REFUSE: proxy interpreter $PROXY_PY not found. Set PROXY_PY." >&2; exit 2; }
    [[ -x "$CONTRACT_PY" ]] || {
        echo "REFUSE: contract interpreter $CONTRACT_PY not found. Set CONTRACT_PY." >&2; exit 2; }
fi
if [[ "$MODE" == full ]]; then
    [[ -d "$BUILD_DIR" ]] || {
        echo "REFUSE: $BUILD_DIR is not configured. cmake -B $BUILD_DIR -G Ninja" >&2
        echo "        (or run --python-only for the two lanes that need no build)" >&2
        exit 2; }
fi

BK=$(mktemp -d)
snap() { echo "$BK/$(basename "$1")"; }
for f in "${FILES[@]}"; do cp -p "$f" "$(snap "$f")"; done

# Clears every __pycache__ under the two Python trees. A .pyc whose source is edited back to the
# same length within the same second keeps its mtime+size validation stamp, so the interpreter
# serves the MUTANT's bytecode from a pristine-looking source file. PYTHONDONTWRITEBYTECODE=1 is
# set on every run below as well; both, because either alone has a hole.
clear_pyc() {
    find p4_proxy tools/contract_test -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
    return 0
}

restore() {
    local f
    for f in "${FILES[@]}"; do
        cp -p "$(snap "$f")" "$f"
        # cp -p puts the ORIGINAL mtime back, which is older than the object built from the
        # mutant -- ninja would then see nothing to do and the next run would test the mutant
        # while the source on disk is pristine. touch is what actually restores the build, and
        # it does the same job for CPython's mtime-keyed bytecode cache.
        touch "$f"
    done
    clear_pyc
}
trap 'restore; rm -rf "$BK"' EXIT

MUTATIONS=0
SURVIVORS=0
DECLARED=0

# --- helpers ---------------------------------------------------------------------------------

# anchor_count <file> <literal> -- prints how many times the literal occurs. Shown for every
# mutation: an anchor that matches twice silently mutates the wrong site, and one that matches
# zero times makes the mutation a no-op that then "passes".
#
# python, not `grep -c -F`: grep splits a multi-line -F pattern into several patterns and counts
# matching LINES, so a two-line anchor would report 2 and be rejected as "not unique". Two of the
# anchors below span lines.
anchor_count() {
    ANCHOR="$2" "$CONTRACT_PY" - "$1" <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
}

build() { cmake --build "$BUILD_DIR" --target "$TARGET" >/dev/null 2>&1; }

# Each red_<lane> prints the space-separated identities of the tests that failed, empty if green.
# rc is captured from the process directly, never through a pipe, so a crash cannot be read as a
# pass by a summary line that was never printed.

red_cpp() {
    local out rc
    out=$("$BIN" --gtest_filter="$FILTER" 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^\[  FAILED  \] \([A-Za-z]*\.[A-Za-z]*\).*/\1/p' <<<"$out" | sort -u | tr '\n' ' '
}

red_proxy() {
    local out rc
    clear_pyc
    out=$(cd p4_proxy/tests && PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=.. \
              "$PROXY_PY" test_flowentry_endpoints.py 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^\(FAIL\|ERROR\): \([A-Za-z_0-9]*\) .*/\2/p' <<<"$out" | sort -u | tr '\n' ' '
}

red_contract() {
    local out rc
    clear_pyc
    out=$(cd tools/contract_test && PYTHONDONTWRITEBYTECODE=1 \
              "$CONTRACT_PY" ./run_contract_test.py --self-test 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^  FAIL  \(.*\)$/\1/p' <<<"$out" | sed 's/:.*//' | sort -u | tr '\n' ' '
}

# red_for <lane>. A lane whose prerequisites are absent must not answer "green".
red_for() {
    case "$1" in
        cpp)      red_cpp ;;
        proxy)    red_proxy ;;
        contract) red_contract ;;
        *) echo "HARNESS-FAULT-unknown-lane-$1" ;;
    esac
}

# mutate <label> <lane> <file> <anchor> <replacement> <expected-test> [declared-uncovered-reason]
mutate() {
    local label="$1" lane="$2" file="$3" anchor="$4" repl="$5" expected="$6" declared="${7:-}"

    if [[ "$MODE" == python && "$lane" == cpp ]]; then return; fi

    local n; n=$(anchor_count "$file" "$anchor")
    printf '\n=== %s  [%s] ===\n' "$label" "$lane"
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    MUTATIONS=$((MUTATIONS + 1))
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- this mutation proves nothing, so it is"
        echo "     counted as a survivor rather than skipped. Fix the anchor."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    ANCHOR="$anchor" REPL="$repl" "$CONTRACT_PY" - "$file" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a, r = os.environ["ANCHOR"], os.environ["REPL"]
assert s.count(a) == 1, "anchor is not unique at write time"
p.write_text(s.replace(a, r, 1))
PY
    if [[ $? -ne 0 ]]; then
        echo "  🔴 mutation could not be applied. NOT a pass."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    clear_pyc

    if [[ "$lane" == cpp ]] && ! build; then
        echo "  🔴 MUTANT DOES NOT COMPILE -- it has not been shown to be caught, which is what"
        echo "     this gate measures. Counted as a survivor (see the divergence note above)."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    local failed; failed=$(red_for "$lane")
    if [[ -z "$failed" ]]; then
        if [[ -n "$declared" ]]; then
            printf '  ⚪ SURVIVED AS DECLARED -- %s\n' "$declared"
            DECLARED=$((DECLARED + 1)); MUTATIONS=$((MUTATIONS - 1))
        else
            echo "  🔴 NOTHING WENT RED -- the mutation survived. That behaviour is untested."
            SURVIVORS=$((SURVIVORS + 1))
        fi
    elif grep -q -- "$expected" <<<"$failed"; then
        printf '  ✅ caught by %s\n     all red: %s\n' "$expected" "$failed"
    else
        printf '  🔴 WRONG TEST WENT RED: got [%s], expected [%s]\n' "$failed" "$expected"
        echo "     The gate fires, but not for the reason this mutation claims."
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# dry_one -- the --dry-run callback. Same signature as mutate(), touches nothing.
DRY_BAD=0
dry_one() {
    local label="$1" lane="$2" file="$3" anchor="$4"
    local n; n=$(anchor_count "$file" "$anchor")
    if [[ "$n" -eq 1 ]]; then
        printf '  ✅ 1x  [%-8s] %s\n            %s\n' "$lane" "$label" "$file"
    else
        printf '  🔴 %sx  [%-8s] %s\n            %s\n' "$n" "$lane" "$label" "$file"
        DRY_BAD=$((DRY_BAD + 1))
    fi
}

# --- the mutation table ------------------------------------------------------------------------
# One list, walked twice: `each_mutation mutate` runs the gate, `each_mutation dry_one` checks the
# anchors without touching anything. Held as a callback rather than an array of packed strings
# because two anchors and one replacement span lines, and `read` stops at the first newline --
# the first draft of this file packed them and the dry run reported an anchor matching 14 times,
# because what it actually searched for was the last line of a truncated anchor.
#
# Callback signature: <label> <lane> <file> <anchor> <replacement> <expected-test> <declared>
each_mutation() {
    local m="$1"

    "$m" "1. running() is pinned true, so a stopped queue reads as live" cpp "$DSP" \
        '    bool running() const { return running_.load(std::memory_order_relaxed); }' \
        '    bool running() const { return true; }' \
        'FlowDispatcherTest.RunningTellsAZeroDropCountApartFromAStoppedQueue' ''

    "$m" "2. running() is pinned false, so a healthy queue reads as dead" cpp "$DSP" \
        '    bool running() const { return running_.load(std::memory_order_relaxed); }' \
        '    bool running() const { return false; }' \
        'FlowDispatcherTest.RunningTellsAZeroDropCountApartFromAStoppedQueue' ''

    # THE ORIGINAL A-7 DEFECT at this layer: the shutdown-window drop stops being counted, so the
    # endpoint publishes a zero that means nothing at all. The pre-existing test is named because
    # it is the stronger claim; the new one should redden too, and the run prints both.
    "$m" "3. a shutdown-window drop stops being counted" cpp "$DSC" \
        '    const uint64_t before = droppedAfterStop_.fetch_add(n, std::memory_order_relaxed);' \
        '    const uint64_t before = droppedAfterStop_.fetch_add(0, std::memory_order_relaxed);' \
        'FlowDispatcherTest.JobsDroppedAfterStopAreCountedAndNotSilent' ''

    # FINDING-07: every rule is reported as reaching the ternary table, so a caller is told its
    # priority was honoured when the rule went to ipv4_lpm. The exact lie the disclosure exists
    # to stop, reintroduced one level up from where it used to live.
    #
    # 2026-09-04: re-anchored. This exact line is now written twice -- once in the standalone
    # helper _priority_disclosure() (api_routes.py:306, used elsewhere) and once inlined in
    # add_flow_entry() (api_routes.py:367, the site this mutation and its expected test are
    # about). A one-line anchor now matches both, and mutate()'s `s.replace(a, r, 1)` would have
    # silently mutated the FIRST one in file order -- _priority_disclosure, the wrong site -- so
    # the anchor is widened to the next line (body = ..., untouched, unique to add_flow_entry) to
    # pin it to the right one.
    "$m" "4. every rule claims it reached the priority-bearing table" proxy "$API" \
        '    table = "flow_5tuple" if needs_five_tuple(match) else "ipv4_lpm"
    body = {"status": "success", "table": table, "priority_honoured": table == "flow_5tuple"}' \
        '    table = "flow_5tuple"
    body = {"status": "success", "table": table, "priority_honoured": table == "flow_5tuple"}' \
        'test_a_destination_only_rule_says_its_priority_was_not_honoured' ''

    "$m" "5. priority_honoured is pinned true whatever the table" proxy "$API" \
        '    body = {"status": "success", "table": table, "priority_honoured": table == "flow_5tuple"}' \
        '    body = {"status": "success", "table": table, "priority_honoured": True}' \
        'test_a_destination_only_rule_says_its_priority_was_not_honoured' ''

    # The caveat fires on every destination-only write, including the kernel's own priority-less
    # ones. Not a wrong answer, a useless one: a warning on every call is one nobody still reads
    # by the time a real one arrives. Caught only by the test written for that, which is why it
    # is a separate test rather than an extra assertion on the one above.
    "$m" "6. the note is emitted even when no priority was asked for" proxy "$API" \
        '    if data.get("priority") is not None and table == "ipv4_lpm":' \
        '    if table == "ipv4_lpm":' \
        'test_the_note_is_only_for_a_caller_that_actually_asked_for_a_priority' ''

    "$m" "7. the counters invariant answers nothing" contract "$SPC" \
        '    c = data.get("counters") or {}
    dispatched, succeeded, failed = c.get("dispatched"), c.get("succeeded"), c.get("failed")' \
        '    return []  # MUTANT
    c = data.get("counters") or {}
    dispatched, succeeded, failed = c.get("dispatched"), c.get("succeeded"), c.get("failed")' \
        'dispatch_counters_close' ''

    # The optionality is load-bearing, not politeness: a required field reports a false
    # regression against every kernel built before that field existed.
    "$m" "8. dispatcher_running becomes a required field" contract "$SPC" \
        '}, optional={
    # Both added by the A-7 follow-up; optional for the same reason as dropped_after_stop.
    "dispatcher_running": Bool(),' \
        '    "dispatcher_running": Bool(),
}, optional={' \
        'get_flow_dispatch_status' ''

    # --- declared-uncovered -------------------------------------------------------------------
    # Run, reported, and NOT counted as a survivor -- with the reason stated, because an
    # exemption that is not written down is indistinguishable from a gap nobody noticed.
    "$m" "9. the endpoint stops publishing dispatcher_running" cpp "$SES" \
        '        {"dispatcher_running", m_controller->dispatcher().running()},
' \
        '' \
        'FlowDispatcherTest.RunningTellsAZeroDropCountApartFromAStoppedQueue' \
        "no suite here exercises HttpSession's handlers in-process -- the response body is only reachable from a running kernel, so this is covered by the live recipe in the A-7 findings, not by any test this gate can run"
}

# --- dry run -----------------------------------------------------------------------------------

if [[ "$MODE" == dryrun ]]; then
    echo "A-7 dispatch-status mutation gate -- ANCHOR DRY RUN"
    echo
    echo "  🔴 THIS IS NOT A GATE RESULT. Nothing is built, nothing is mutated and no test is"
    echo "     run. It checks only that every anchor still matches its file exactly once, which"
    echo "     is the failure this harness cannot otherwise detect: an anchor that has drifted"
    echo "     makes its mutation a silent no-op that then reports as caught."
    echo
    DRY_BAD=0
    each_mutation dry_one
    echo
    if [[ "$DRY_BAD" -ne 0 ]]; then
        echo "  $DRY_BAD anchor(s) do not match exactly once. The gate would refuse; fix them first."
        exit 2
    fi
    echo "  all anchors match exactly once -- the gate is runnable. STILL NOT A GATE RESULT:"
    echo "  run without --dry-run (or with --python-only) to find out what is actually caught."
    exit 0
fi

# --- baseline ----------------------------------------------------------------------------------

echo "A-7 dispatch-status mutation gate"
[[ "$MODE" == python ]] && echo "  🔴 --python-only: PARTIAL RESULT, the cpp lane is skipped entirely"
echo "  mode      : $MODE"
echo "  build dir : $BUILD_DIR"
echo "  target    : $TARGET"
echo "  filter    : $FILTER"
for f in "${FILES[@]}"; do printf '  baseline  : %s %s\n' "$(sha256sum "$f" | cut -c1-16)" "$f"; done
echo
echo "baseline (unmutated) must build and be green:"

LANES=(proxy contract)
[[ "$MODE" == full ]] && LANES=(cpp proxy contract)

if [[ "$MODE" == full ]]; then
    if ! build; then
        echo "  REFUSE: the unmutated tree does not build. Nothing below would mean anything."
        cmake --build "$BUILD_DIR" --target "$TARGET" 2>&1 | tail -20 | sed 's/^/    /'
        exit 2
    fi
fi
clear_pyc
for lane in "${LANES[@]}"; do
    base_red=$(red_for "$lane")
    if [[ -n "$base_red" ]]; then
        echo "  REFUSE: the $lane baseline is RED before any mutation."
        printf '    red: %s\n' "$base_red"
        exit 2
    fi
    printf '  ok       %s baseline green\n' "$lane"
done

# --- mutations ---------------------------------------------------------------------------------

each_mutation mutate

# --- negative control --------------------------------------------------------------------------
# A gate that reddens on anything is not a gate. A comment-only edit must leave every lane green;
# if one goes red those tests are change detectors, not a specification. One control per Python
# lane, and one for cpp only when that lane ran -- a control that is not executed proves nothing.

control() {
    local lane="$1" file="$2" anchor="$3" repl="$4"
    printf '\n=== NEGATIVE CONTROL [%s]: comment-only edit must stay GREEN ===\n' "$lane"
    local n; n=$(anchor_count "$file" "$anchor")
    printf '  anchor occurrences: %s in %s\n' "$n" "$file"
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 control anchor is not unique ($n matches) -- the control proves nothing."
        SURVIVORS=$((SURVIVORS + 1)); return
    fi
    ANCHOR="$anchor" REPL="$repl" "$CONTRACT_PY" - "$file" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace(os.environ["ANCHOR"], os.environ["REPL"], 1))
PY
    clear_pyc
    if [[ "$lane" == cpp ]] && ! build; then
        echo "  🔴 a comment broke the build -- the anchor landed somewhere it should not have."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi
    local ctrl_red; ctrl_red=$(red_for "$lane")
    if [[ -z "$ctrl_red" ]]; then
        echo "  ✅ green: the suite does not react to a comment"
    else
        printf '  🔴 A COMMENT TURNED THE SUITE RED: %s\n' "$ctrl_red"
        echo "     These tests are change detectors, not a specification."
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

if [[ "$MODE" == full ]]; then
    control cpp "$DSP" \
        '    std::atomic<bool> running_{false};' \
        '    // MUTANT: a comment, and nothing else.
    std::atomic<bool> running_{false};'
fi

# 2026-09-04: re-anchored (same reason as mutation #4 above -- this line now exists twice, and
# the control has to land on the same add_flow_entry site the mutation does).
control proxy "$API" \
    '    table = "flow_5tuple" if needs_five_tuple(match) else "ipv4_lpm"
    body = {"status": "success", "table": table, "priority_honoured": table == "flow_5tuple"}' \
    '    # MUTANT: a comment, and nothing else.
    table = "flow_5tuple" if needs_five_tuple(match) else "ipv4_lpm"
    body = {"status": "success", "table": table, "priority_honoured": table == "flow_5tuple"}'

control contract "$SPC" \
    '    c = data.get("counters") or {}' \
    '    # MUTANT: a comment, and nothing else.
    c = data.get("counters") or {}'

# --- byte-identity and verdict -----------------------------------------------------------------

restore
printf '\n--- baseline restored? ---\n'
ok=1
for f in "${FILES[@]}"; do
    if cmp -s "$(snap "$f")" "$f"; then
        printf '  byte-identical  %s\n' "$f"
    else
        printf '  🔴 NOT RESTORED: %s -- do NOT commit\n' "$f"; ok=0
    fi
done
[[ "$ok" == 1 ]] || exit 2

if [[ "$MODE" == full ]] && ! build; then
    echo "🔴 THE TREE DOES NOT BUILD AFTER RESTORE -- do NOT commit."; exit 2
fi
for lane in "${LANES[@]}"; do
    after_red=$(red_for "$lane")
    if [[ -n "$after_red" ]]; then
        printf '🔴 THE %s SUITE IS RED AFTER RESTORE: %s\n' "$lane" "$after_red"
        echo "   A mutant is still built in. Do NOT commit."; exit 2
    fi
done
echo "  every lane green again after restore"

printf '\n%s mutations, %s survived' "$MUTATIONS" "$SURVIVORS"
[[ "$DECLARED" -gt 0 ]] && printf ' (+%s declared-uncovered, listed above)' "$DECLARED"
printf '\n'
[[ "$MODE" == python ]] && echo "🔴 PARTIAL: the cpp lane did not run. This is not a full gate result."
[[ "$SURVIVORS" -eq 0 ]]
