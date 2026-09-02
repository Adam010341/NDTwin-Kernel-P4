#!/usr/bin/env bash
#
# Mutation gate for tests/python/test_ryu_rest_topology_bounded.py (KNOWN-ISSUES A-2, item 2).
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration. This applies each mutation to the
# vendored app, re-runs the suite, and records WHICH test went red -- not merely that something
# did. No build step: the subject is Python, so a mutation costs one interpreter start rather than
# a link of test_routing_strategy, which is why this gate can afford to be run on every edit.
#
# The subject is tools/ryu_apps/rest_topology_bounded.py, the copy stack.sh loads. Mutating the
# stock file in site-packages is deliberately NOT done: it is outside the repo, shared with every
# other conda user of that env, and a crash mid-run would leave someone else's Ryu patched.
#
# 🔴 The mutation that matters most is #6. The 3 s ceiling is not a taste: it must stay under the
# kernel's --max-time 5 (TopologyAndFlowMonitor.hpp kTopologyRequestTimeoutSeconds). Raise it to
# 10 and the client always aborts first -- the warning is never written, the parked greenlet is
# never released, and the fix looks present while doing nothing. If nothing goes red for #6, the
# cross-component constraint is untested and the number is folklore.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any exit,
# and the run asserts byte-identity at the end. The baseline is the WORKING TREE, not HEAD, so
# this runs against an uncommitted edit.
#
# One deliberate rule, the same as tests/shell/mutate_a2_poll_round.sh: a mutant that does not
# parse, an anchor that has moved, or the wrong test going red all count as SURVIVORS -- never a
# warning, never a discount. A mutation that never reached the interpreter established nothing.
# None of the three aborts the remaining mutations.
#
# Usage:  tests/shell/mutate_ryu_rest_topology_bounded.sh
#         PYTHON=/usr/bin/python3 tests/shell/mutate_ryu_rest_topology_bounded.sh
#         ANCHOR_CHECK=1 tests/shell/mutate_ryu_rest_topology_bounded.sh   # NOT a gate result
# Assumes: cwd is the repo root.
# Exit:    0 all mutations caught, 1 a mutation survived, 2 refused (baseline red / not restored /
#          anchor-check mode, which never produces a verdict).
set -uo pipefail

# 🔴 NO BYTECODE CACHE. This is not hygiene, it is correctness, and it was found by this gate
# reporting a survivor on its own first run.
#
# A .pyc is revalidated against the source's (mtime-in-SECONDS, size). Mutation 2 and mutation 3
# replace `self._bounded('hosts', lambda: get_host(...))` and `self._bounded('links', lambda:
# get_link(...))` respectively -- 'hosts'/'links' and get_host/get_link are the same length, so
# the two mutants are byte-identical in SIZE (11531). Applied in the same wall-clock second, the
# second one reuses the first one's cached bytecode: the gate applies mutation 3, the interpreter
# runs mutation 2, and the verdict describes a file that was never on disk.
#
# That is the ninja/`cp -p` trap from mutate_f6_stale_table_carry_forward.sh in a different build
# system, and it is why "which test went red" is checked rather than "something went red" -- the
# identity check is what turned a silently wrong PASS into a visible survivor.
export PYTHONDONTWRITEBYTECODE=1

PYTHON="${PYTHON:-/home/adam/miniconda3/bin/python3}"
SRC=tools/ryu_apps/rest_topology_bounded.py
TEST=tests/python/test_ryu_rest_topology_bounded.py
PYCACHE=tools/ryu_apps/__pycache__

ANCHOR_CHECK="${ANCHOR_CHECK:-0}"
if [[ "${1:-}" == "--dry-run" ]]; then
    ANCHOR_CHECK=1
fi

[[ -f "$SRC" ]]  || { echo "REFUSE: $SRC not found -- run from the repo root." >&2; exit 2; }
[[ -f "$TEST" ]] || { echo "REFUSE: $TEST not found -- run from the repo root." >&2; exit 2; }
[[ -x "$PYTHON" ]] || { echo "REFUSE: no interpreter at $PYTHON (override with PYTHON=)." >&2; exit 2; }

# --- helpers ---------------------------------------------------------------------------------

# anchor_count <file> <literal> -- prints how many times the literal occurs. Shown for every
# mutation: an anchor that matches twice silently mutates the wrong site, and one that matches
# zero times makes the mutation a no-op that then "passes".
#
# python, not `grep -c -F`: grep splits a multi-line -F pattern into several patterns and counts
# matching LINES, so a multi-line anchor would report the wrong number and be rejected.
anchor_count() {
    ANCHOR="$2" "$PYTHON" - "$1" <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
}

# --- the mutation table -------------------------------------------------------------------------
# Declared once so the anchor check and the gate cannot disagree about what is being tested.

MUT_LABEL=(); MUT_ANCHOR=(); MUT_REPL=(); MUT_EXPECT=()
add() { MUT_LABEL+=("$1"); MUT_ANCHOR+=("$2"); MUT_REPL+=("$3"); MUT_EXPECT+=("$4"); }

# 1-3. The ceiling is removed from one handler at a time. This is the tree as it was before the
#      fix, one endpoint at a time -- the read goes straight through to send_request and the
#      greenlet parks. Done three times rather than once because the observed wedge took out all
#      three at the same moment, and a fix that bounded only the endpoint the ticket happened to
#      name would leave two thirds of the same outage in place.
add "1. the switches handler is unbounded again" \
    "        switches = self._bounded('switches', lambda: get_switch(self.topology_api_app, dpid))" \
    "        switches = get_switch(self.topology_api_app, dpid)" \
    'test_all_three_endpoints_are_bounded'

add "2. the hosts handler is unbounded again" \
    "        hosts = self._bounded('hosts', lambda: get_host(self.topology_api_app, dpid))" \
    "        hosts = get_host(self.topology_api_app, dpid)" \
    'test_all_three_endpoints_are_bounded'

add "3. the links handler is unbounded again" \
    "        links = self._bounded('links', lambda: get_link(self.topology_api_app, dpid))" \
    "        links = get_link(self.topology_api_app, dpid)" \
    'test_a_blocked_link_read_answers_instead_of_propagating'

# 4. The failure is dressed as success. 200 on a read that never happened is the one answer a
#    monitoring system, a proxy and a human reading `curl -i` all mis-handle in the same
#    direction. The kernel cannot see the status code at all, so this costs the kernel nothing
#    directly -- which is exactly why only a test can catch it.
add "4. a failed read answers 200 instead of 503" \
    "        return Response(status=503, body=b'')" \
    "        return Response(status=200, body=b'')" \
    'test_the_answer_to_a_blocked_read_is_503'

# 5. 🔴 THE ONE THE KERNEL ACTUALLY FEELS. utils::execCommand is a bare popen() that captures
#    stdout and discards the exit status, so the HTTP status never reaches the kernel and the body
#    is the entire channel. A non-empty body means the kernel classifies the round as ANSWERED and
#    hands this string to json::parse -- strictly worse than the wedge it replaced, because the
#    wedge was at least detectable.
add "5. the failure carries a body, so the kernel reads it as an answer" \
    "        return Response(status=503, body=b'')" \
    "        return Response(status=503, body=b'{\"error\": \"topology read timed out\"}')" \
    'test_the_answer_to_a_blocked_read_has_an_empty_body'

# 6. 🔴 THE CROSS-COMPONENT CONSTRAINT. 10 s is above the kernel's --max-time 5, so the client
#    always aborts first: this app's warning is never written, and the greenlet stays parked
#    because it is blocked before it ever writes and never learns the client left. The fix would
#    be present in the file and absent in effect -- and every other test here would still pass,
#    which is what makes this mutation worth its own line.
add "6. the ceiling rises above the kernel's --max-time 5" \
    'TOPO_REST_TIMEOUT_S = float(os.environ.get("NDTWIN_RYU_REST_TOPO_TIMEOUT_S", "3"))' \
    'TOPO_REST_TIMEOUT_S = float(os.environ.get("NDTWIN_RYU_REST_TOPO_TIMEOUT_S", "10"))' \
    'test_the_server_gives_up_before_the_kernel_does'

CTRL_ANCHOR='    def _unavailable():'
CTRL_REPL='    # MUTANT: a comment, and nothing else.
    def _unavailable():'

# --- anchor check (never a verdict) -------------------------------------------------------------

if [[ "$ANCHOR_CHECK" != "0" ]]; then
    echo "================================================================"
    echo " ANCHOR CHECK ONLY -- THIS IS NOT A GATE RESULT."
    echo " No mutation was applied and no test was run. The exit code is 2"
    echo " on purpose so this can never be mistaken for a passing gate."
    echo " Run without ANCHOR_CHECK/--dry-run for a verdict."
    echo "================================================================"
    broken=0
    for i in "${!MUT_LABEL[@]}"; do
        n=$(anchor_count "$SRC" "${MUT_ANCHOR[$i]}")
        if [[ "$n" -eq 1 ]]; then
            printf '  ok    %s  (%s)\n' "$n" "${MUT_LABEL[$i]}"
        else
            printf '  🔴 %s matches  (%s)\n' "$n" "${MUT_LABEL[$i]}"; broken=$((broken + 1))
        fi
    done
    n=$(anchor_count "$SRC" "$CTRL_ANCHOR")
    if [[ "$n" -eq 1 ]]; then
        printf '  ok    %s  (negative control)\n' "$n"
    else
        printf '  🔴 %s matches  (negative control)\n' "$n"; broken=$((broken + 1))
    fi
    if [[ "$broken" -eq 0 ]]; then
        echo "ANCHORS: ok -- all ${#MUT_LABEL[@]} mutations plus the control resolve to one site each."
    else
        echo "ANCHORS: BROKEN -- $broken anchor(s) have moved. Fix them before running the gate."
    fi
    echo "(still exiting 2: an anchor check is not a gate result)"
    exit 2
fi

# --- baseline snapshot --------------------------------------------------------------------------

BK=$(mktemp -d)
SNAP="$BK/$(basename "$SRC")"
cp -p "$SRC" "$SNAP"
restore() {
    cp -p "$SNAP" "$SRC"
    # cp -p puts the ORIGINAL mtime back. Nothing here is compiled, so no build system can be
    # fooled by it -- but __pycache__ is keyed on mtime and size, and an unlucky pair would let a
    # stale .pyc be imported. touch removes that possibility for the same cost as the comment.
    touch "$SRC"
}
trap 'restore; rm -rf "$BK" "$PYCACHE"' EXIT

MUTATIONS=0
SURVIVORS=0

# red_tests -- prints the space-separated names of the test methods that failed or errored. The
# subTest suffix "(endpoint='get_switch')" is stripped so a subTest failure reports under its
# method name. rc is taken from the interpreter directly, never through a pipe.
red_tests() {
    local out rc
    # PYTHONDONTWRITEBYTECODE stops new caches being written; this removes any that already
    # existed before the gate started. Both are needed -- the interpreter still READS a stale
    # .pyc it did not write. See the banner at the top for what that cost on the first run.
    rm -rf "$PYCACHE"
    out=$("$PYTHON" "$TEST" 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^\(FAIL\|ERROR\): \([A-Za-z_][A-Za-z0-9_]*\) .*/\2/p' <<<"$out" | sort -u | tr '\n' ' '
}

# mutate <label> <anchor> <replacement> <expected-test>
mutate() {
    local label="$1" anchor="$2" repl="$3" expected="$4"
    local n; n=$(anchor_count "$SRC" "$anchor")
    printf '\n=== %s ===\n' "$label"
    printf '  anchor occurrences: %s in %s\n' "$n" "$SRC"
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- this mutation proves nothing. Fix the anchor."
        SURVIVORS=$((SURVIVORS + 1)); MUTATIONS=$((MUTATIONS + 1)); restore; return
    fi
    MUTATIONS=$((MUTATIONS + 1))

    if ! ANCHOR="$anchor" REPL="$repl" "$PYTHON" - "$SRC" <<'PY'
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

    # A mutant that does not parse never reached the tests, so it establishes nothing about them.
    if ! "$PYTHON" -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$SRC" >/dev/null 2>&1; then
        echo "  🔴 MUTANT DOES NOT PARSE -- the behaviour it was aimed at is still untested."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    local failed; failed=$(red_tests)
    if [[ -z "$failed" ]]; then
        echo "  🔴 NOTHING WENT RED -- the mutation survived. That behaviour is untested."
        SURVIVORS=$((SURVIVORS + 1))
    elif grep -q -- "$expected" <<<"$failed"; then
        printf '  ✅ caught by %s\n     all red: %s\n' "$expected" "$failed"
    else
        printf '  🔴 WRONG TEST WENT RED: got [%s], expected [%s]\n' "$failed" "$expected"
        echo "     The gate fires, but not for the reason this mutation claims."
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# --- baseline -----------------------------------------------------------------------------------

echo "A-2 Ryu bounded-topology mutation gate"
echo "  interpreter : $PYTHON"
echo "  subject     : $SRC"
echo "  suite       : $TEST"
printf '  baseline    : %s %s\n' "$(sha256sum "$SRC" | cut -c1-16)" "$SRC"
echo
echo "baseline (unmutated) must be green:"
BASE_RED=$(red_tests)
if [[ -n "$BASE_RED" ]]; then
    echo "  REFUSE: baseline is RED before any mutation."
    printf '    red: %s\n' "$BASE_RED"
    "$PYTHON" "$TEST" 2>&1 | tail -20 | sed 's/^/    /'
    exit 2
fi
"$PYTHON" "$TEST" 2>&1 | tail -3 | sed 's/^/    /'
echo "  ok       baseline green"

# --- mutations ----------------------------------------------------------------------------------

for i in "${!MUT_LABEL[@]}"; do
    mutate "${MUT_LABEL[$i]}" "${MUT_ANCHOR[$i]}" "${MUT_REPL[$i]}" "${MUT_EXPECT[$i]}"
done

# --- negative control ---------------------------------------------------------------------------
# A gate that reddens on anything is not a gate. A comment-only edit must leave the suite green;
# if this goes red the suite is a change detector, not a specification.

printf '\n=== NEGATIVE CONTROL: comment-only edit must stay GREEN ===\n'
n=$(anchor_count "$SRC" "$CTRL_ANCHOR")
printf '  anchor occurrences: %s in %s\n' "$n" "$SRC"
if [[ "$n" -ne 1 ]]; then
    echo "  🔴 control anchor is not unique ($n matches) -- the control proves nothing."
    SURVIVORS=$((SURVIVORS + 1))
else
    ANCHOR="$CTRL_ANCHOR" REPL="$CTRL_REPL" "$PYTHON" - "$SRC" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace(os.environ["ANCHOR"], os.environ["REPL"], 1))
PY
    ctrl_red=$(red_tests)
    if [[ -z "$ctrl_red" ]]; then
        echo "  ✅ green: the suite does not react to a comment"
    else
        printf '  🔴 A COMMENT TURNED THE SUITE RED: %s\n' "$ctrl_red"
        echo "     These tests are change detectors, not a specification."
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
fi

# --- byte-identity and verdict ------------------------------------------------------------------

restore
printf '\n--- baseline restored? ---\n'
if cmp -s "$SNAP" "$SRC"; then
    printf '  byte-identical  %s\n' "$SRC"
else
    printf '  🔴 NOT RESTORED: %s -- do NOT commit\n' "$SRC"; exit 2
fi

after_red=$(red_tests)
if [[ -n "$after_red" ]]; then
    printf '🔴 THE SUITE IS RED AFTER RESTORE: %s\n' "$after_red"
    echo "   A mutant is still on disk. Do NOT commit."; exit 2
fi
echo "  suite green again after restore"

# The one test no mutation above is expected to redden, said out loud rather than left to be
# noticed: test_a_healthy_read_still_returns_the_same_json is a regression guard against the fix
# being "achieved" by breaking the healthy answer. It is green against the stock file too, so it
# discriminates nothing about this fix -- it is not decoration, but it is not evidence either.
printf '\nnot reddened by design: test_a_healthy_read_still_returns_the_same_json (regression guard,\n'
printf 'green against the stock file too, so it discriminates nothing about this fix)\n'

printf '\n%s mutations, %s survived\n' "$MUTATIONS" "$SURVIVORS"
[[ "$SURVIVORS" -eq 0 ]]
