#!/usr/bin/env bash
#
# Mutation gate for tools/p4_exercise (TICKET-P1 §3).
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration. This applies five mutations to the
# three tools, re-runs the whole suite after each, and records WHICH test went red -- not merely
# that something did. Same shape as tests/shell/mutate_ryu_rest_topology_bounded.sh, with one
# difference: the subject is a different file per mutation, because the work item is three tools
# and a gate that only ever mutated one of them would be evidence about one of them.
#
# The five, and why each is worth a line:
#
#   1. convert.py stops writing the reverse direction of an access link. Nothing raises: the
#      model still loads and `host_links()` still finds every host, because it reads whichever
#      direction it can. The half that is gone is the half the OTHER readers use.
#   2. convert.py puts a real dpid on the host side of an access edge. `host_links()` identifies
#      an access link by a FALSY dpid on one side (topo_from_json.py:127-133), so the link stops
#      being a host attachment and becomes an inter-switch cable that does not exist.
#   3. preflight.py accepts an entry naming a table the p4info does not have. This is the
#      mutation that matters most: a typo'd table name is valid JSON, installs nothing, and
#      leaves a switch forwarding nothing while the twin reports it healthy. If nothing goes red
#      here, pre-flight is a progress bar.
#   4. run_external_controller.py moves the address and leaves the device id. The connection
#      then succeeds and every request on it returns NOT_FOUND -- "the switch is up but the
#      rules did not take", which is a whole afternoon.
#   5. preflight.py stops checking an lpm prefix length against the field's width. bmv2 takes
#      the mask from that number; out of range it is either refused at install time or silently
#      truncated into a route that matches the wrong traffic.
#
# 🔴 Guards its own baseline: snapshot before the first mutation, EXIT trap restores on any
# exit, and the run asserts byte-identity at the end. The baseline is the WORKING TREE, not
# HEAD, so this runs against an uncommitted edit.
#
# One deliberate rule, the same as the gate this is modelled on: a mutant that does not parse,
# an anchor that has moved, or the wrong test going red all count as SURVIVORS -- never a
# warning, never a discount. A mutation that never reached the interpreter established nothing.
# None of the three aborts the remaining mutations.
#
# Usage:  tests/shell/mutate_p4_exercise_tools.sh
#         PYTHON=... tests/shell/mutate_p4_exercise_tools.sh
#         ANCHOR_CHECK=1 tests/shell/mutate_p4_exercise_tools.sh   # NOT a gate result
# Assumes: cwd is the repo root (or this worktree's root).
# Exit:    0 all mutations caught, 1 a mutation survived, 2 refused (baseline red / not restored /
#          anchor-check mode, which never produces a verdict).
set -uo pipefail

# 🔴 NO BYTECODE CACHE. A .pyc is revalidated against the source's (mtime-in-SECONDS, size), and
# a mutation that keeps the file the same length -- #4 and #5 both nearly do -- applied within
# the same wall-clock second can be shadowed by the previous mutant's cache. The verdict would
# then describe a file that was never on disk. Both halves are needed: this stops new caches
# being written, and red_tests() removes any that already existed.
export PYTHONDONTWRITEBYTECODE=1

PYTHON="${PYTHON:-p4_proxy/venv/bin/python}"
PKG=tools/p4_exercise
TESTS="$PKG/tests"
CONVERT="$PKG/convert.py"
PREFLIGHT="$PKG/preflight.py"
ADAPTER="$PKG/run_external_controller.py"

ANCHOR_CHECK="${ANCHOR_CHECK:-0}"
if [[ "${1:-}" == "--dry-run" ]]; then
    ANCHOR_CHECK=1
fi

[[ -f "$CONVERT" ]]   || { echo "REFUSE: $CONVERT not found -- run from the repo root." >&2; exit 2; }
[[ -f "$PREFLIGHT" ]] || { echo "REFUSE: $PREFLIGHT not found -- run from the repo root." >&2; exit 2; }
[[ -f "$ADAPTER" ]]   || { echo "REFUSE: $ADAPTER not found -- run from the repo root." >&2; exit 2; }
[[ -d "$TESTS" ]]     || { echo "REFUSE: $TESTS not found -- run from the repo root." >&2; exit 2; }
[[ -x "$PYTHON" ]]    || { echo "REFUSE: no interpreter at $PYTHON (override with PYTHON=)." >&2; exit 2; }

# The venv interpreter is not optional: preflight.py parses p4info through the `p4` protobuf
# package, which only that environment has. Checked here rather than discovered as an ERROR in
# every test, which would look like a mutation being caught.
if ! "$PYTHON" -c 'from p4.config.v1 import p4info_pb2' >/dev/null 2>&1; then
    echo "REFUSE: $PYTHON cannot import p4.config.v1.p4info_pb2 -- use p4_proxy/venv/bin/python." >&2
    exit 2
fi

# --- helpers ---------------------------------------------------------------------------------

# anchor_count <file> <literal> -- how many times the literal occurs. Shown for every mutation:
# an anchor matching twice silently mutates the wrong site, and one matching zero times makes
# the mutation a no-op that then "passes".
#
# python, not `grep -c -F`: grep splits a multi-line -F pattern into several patterns and counts
# matching LINES, so a multi-line anchor would report the wrong number.
anchor_count() {
    ANCHOR="$2" "$PYTHON" - "$1" <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
}

# --- the mutation table -------------------------------------------------------------------------
# Declared once so the anchor check and the gate cannot disagree about what is being tested.

MUT_LABEL=(); MUT_SRC=(); MUT_ANCHOR=(); MUT_REPL=(); MUT_EXPECT=()
add() { MUT_LABEL+=("$1"); MUT_SRC+=("$2"); MUT_ANCHOR+=("$3"); MUT_REPL+=("$4"); MUT_EXPECT+=("$5"); }

add "1. convert drops the reverse direction of every access link" \
    "$CONVERT" \
    '            edges.append(_edge(b_dpid, b_port, b_ip, 0, a[2], host["ip"], bps))' \
    '            pass  # MUTANT: the reverse direction is never written' \
    'test_every_link_is_stored_in_both_directions'

add "2. the host side of an access edge carries a real dpid instead of 0" \
    "$CONVERT" \
    '            edges.append(_edge(0, a[2], host["ip"], b_dpid, b_port, b_ip, bps))' \
    '            edges.append(_edge(b_dpid, a[2], host["ip"], b_dpid, b_port, b_ip, bps))' \
    'test_host_edges_carry_dpid_zero_on_the_host_side'

add "3. pre-flight accepts an entry naming a table the p4info does not have" \
    "$PREFLIGHT" \
    '    if table is None:
        known = ", ".join(index.table_names()[:6]) or "(none)"
        return [f"{where}: table {table_name!r} is not in the p4info (it has: {known})"]' \
    '    if table is None:
        return []  # MUTANT: an unknown table name is not a problem' \
    'test_a_bad_table_name_fails'

add "4. the adapter moves the address and leaves the device id behind" \
    "$ADAPTER" \
    '    return (f"localhost:{grpc_base + index}", index, index)' \
    '    return (f"localhost:{grpc_base + index}", device_id, index)  # MUTANT' \
    'test_device_id_moves_with_the_address'

add "5. pre-flight stops checking an lpm prefix length against the field width" \
    "$PREFLIGHT" \
    '            elif not 0 <= prefix <= field.bitwidth:' \
    '            elif False:  # MUTANT: the prefix length is never out of range' \
    'test_an_lpm_prefix_longer_than_the_field_fails'

CTRL_SRC="$CONVERT"
CTRL_ANCHOR='def build_model(hosts, switches, links):'
CTRL_REPL='# MUTANT: a comment, and nothing else.
def build_model(hosts, switches, links):'

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
        n=$(anchor_count "${MUT_SRC[$i]}" "${MUT_ANCHOR[$i]}")
        if [[ "$n" -eq 1 ]]; then
            printf '  ok    %s  (%s)\n' "$n" "${MUT_LABEL[$i]}"
        else
            printf '  🔴 %s matches  (%s)\n' "$n" "${MUT_LABEL[$i]}"; broken=$((broken + 1))
        fi
    done
    n=$(anchor_count "$CTRL_SRC" "$CTRL_ANCHOR")
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
for f in "$CONVERT" "$PREFLIGHT" "$ADAPTER"; do
    cp -p "$f" "$BK/$(basename "$f")"
done
restore() {
    for f in "$CONVERT" "$PREFLIGHT" "$ADAPTER"; do
        cp -p "$BK/$(basename "$f")" "$f"
        # cp -p puts the ORIGINAL mtime back. Nothing here is compiled, so no build system can
        # be fooled -- but __pycache__ is keyed on mtime and size, and an unlucky pair would let
        # a stale .pyc be imported. touch removes that possibility for the cost of a syscall.
        touch "$f"
    done
}
trap 'restore; rm -rf "$BK" "$PKG/__pycache__" "$TESTS/__pycache__"' EXIT

MUTATIONS=0
SURVIVORS=0

# red_tests -- the space-separated names of the test methods that failed or errored.
red_tests() {
    local out rc
    rm -rf "$PKG/__pycache__" "$TESTS/__pycache__"
    out=$("$PYTHON" -m unittest discover -s "$TESTS" -t "$TESTS" 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^\(FAIL\|ERROR\): \([A-Za-z_][A-Za-z0-9_]*\) .*/\2/p' <<<"$out" | sort -u | tr '\n' ' '
}

# mutate <label> <src> <anchor> <replacement> <expected-test>
mutate() {
    local label="$1" src="$2" anchor="$3" repl="$4" expected="$5"
    local n; n=$(anchor_count "$src" "$anchor")
    printf '\n=== %s ===\n' "$label"
    printf '  subject           : %s\n' "$src"
    printf '  anchor occurrences: %s\n' "$n"
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- this mutation proves nothing. Fix the anchor."
        SURVIVORS=$((SURVIVORS + 1)); MUTATIONS=$((MUTATIONS + 1)); restore; return
    fi
    MUTATIONS=$((MUTATIONS + 1))

    if ! ANCHOR="$anchor" REPL="$repl" "$PYTHON" - "$src" <<'PY'
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
    if ! "$PYTHON" -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$src" >/dev/null 2>&1; then
        echo "  🔴 MUTANT DOES NOT PARSE -- the behaviour it was aimed at is still untested."
        SURVIVORS=$((SURVIVORS + 1)); restore; return
    fi

    local failed; failed=$(red_tests)
    if [[ -z "$failed" ]]; then
        echo "  🔴 NOTHING WENT RED -- the mutation survived. That behaviour is untested."
        SURVIVORS=$((SURVIVORS + 1))
    elif /usr/bin/grep -q -- "$expected" <<<"$failed"; then
        printf '  ✅ caught by %s\n     all red: %s\n' "$expected" "$failed"
    else
        printf '  🔴 WRONG TEST WENT RED: got [%s], expected [%s]\n' "$failed" "$expected"
        echo "     The gate fires, but not for the reason this mutation claims."
        SURVIVORS=$((SURVIVORS + 1))
    fi
    restore
}

# --- baseline -----------------------------------------------------------------------------------

echo "TICKET-P1 §3 p4_exercise tools mutation gate"
echo "  interpreter : $PYTHON"
echo "  subjects    : $CONVERT"
echo "                $PREFLIGHT"
echo "                $ADAPTER"
echo "  suite       : $TESTS"
for f in "$CONVERT" "$PREFLIGHT" "$ADAPTER"; do
    printf '  baseline    : %s %s\n' "$(sha256sum "$f" | cut -c1-16)" "$f"
done
echo
echo "baseline (unmutated) must be green:"
BASE_RED=$(red_tests)
if [[ -n "$BASE_RED" ]]; then
    echo "  REFUSE: baseline is RED before any mutation."
    printf '    red: %s\n' "$BASE_RED"
    "$PYTHON" -m unittest discover -s "$TESTS" -t "$TESTS" 2>&1 | tail -20 | sed 's/^/    /'
    exit 2
fi
"$PYTHON" -m unittest discover -s "$TESTS" -t "$TESTS" 2>&1 | tail -3 | sed 's/^/    /'
echo "  ok       baseline green"

# --- mutations ----------------------------------------------------------------------------------

for i in "${!MUT_LABEL[@]}"; do
    mutate "${MUT_LABEL[$i]}" "${MUT_SRC[$i]}" "${MUT_ANCHOR[$i]}" "${MUT_REPL[$i]}" "${MUT_EXPECT[$i]}"
done

# --- negative control ---------------------------------------------------------------------------
# A gate that reddens on anything is not a gate. A comment-only edit must leave the suite green;
# if this goes red the suite is a change detector, not a specification.

printf '\n=== NEGATIVE CONTROL: comment-only edit must stay GREEN ===\n'
n=$(anchor_count "$CTRL_SRC" "$CTRL_ANCHOR")
printf '  subject           : %s\n' "$CTRL_SRC"
printf '  anchor occurrences: %s\n' "$n"
if [[ "$n" -ne 1 ]]; then
    echo "  🔴 control anchor is not unique ($n matches) -- the control proves nothing."
    SURVIVORS=$((SURVIVORS + 1))
else
    ANCHOR="$CTRL_ANCHOR" REPL="$CTRL_REPL" "$PYTHON" - "$CTRL_SRC" <<'PY'
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
bad_restore=0
for f in "$CONVERT" "$PREFLIGHT" "$ADAPTER"; do
    if cmp -s "$BK/$(basename "$f")" "$f"; then
        printf '  byte-identical  %s\n' "$f"
    else
        printf '  🔴 NOT RESTORED: %s -- do NOT commit\n' "$f"; bad_restore=1
    fi
done
[[ "$bad_restore" -eq 0 ]] || exit 2

after_red=$(red_tests)
if [[ -n "$after_red" ]]; then
    printf '🔴 THE SUITE IS RED AFTER RESTORE: %s\n' "$after_red"
    echo "   A mutant is still on disk. Do NOT commit."; exit 2
fi
echo "  suite green again after restore"

# Said out loud rather than left to be noticed: the tests no mutation above is expected to
# redden are not evidence about these five behaviours. The reproducibility test
# (test_two_conversions_are_byte_identical) and the p4c rows are regression guards -- green
# against a tool that does the wrong thing consistently -- and the read-back tests would also
# go red under #2, which is why #2 names the dpid test and not one of them.
printf '\nnot reddened by design: test_two_conversions_are_byte_identical and the p4c rows\n'
printf '(regression guards; they discriminate nothing about the five behaviours above)\n'

printf '\n%s mutations, %s survived\n' "$MUTATIONS" "$SURVIVORS"
[[ "$SURVIVORS" -eq 0 ]]
