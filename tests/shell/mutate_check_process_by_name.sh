#!/usr/bin/env bash
#
# Mutation gate for the PYTHON half of tests/shell/check_process_by_name.py.
#
# [Co-developed with claude code -- Adam]
#
# The shell half already has one: tests/shell/mutate_g9_faults_topo_pid.sh, which puts the G-9
# defect back into faults.sh. That gate mutates faults.sh and nothing else, and it cannot be
# taught a second target -- check_gate_anchors.py resolves a write_case heredoc's file from the
# ONE path its applier bakes in, so a two-target gate would report every case against the wrong
# file. Hence a second gate, in the shape mutate_check_test_tmpdirs.sh established for mutating a
# checker rather than a subject.
#
# Why this half needs its own gate at all: the python surface was added on 2026-09-11 because
# "shell only" had stopped being a limit and become a hole. Both mininet topologies ran
# `os.system('sudo pkill -f simple_switch_grpc')` as root on every bring-up, for as long as this
# checker has existed, while it reported a clean tree every night. A checker that reports by
# SAYING NOTHING has to be shown red before its silence means anything, and the specific failure
# to pin is not "it crashed" -- it is that a shell parser pointed at python parses fine and
# reports nothing.
#
# Eleven mutations, in four families:
#   M1        the SURFACE goes back to shell-only -- the exact state that hid the two live sites.
#   M2, M5,   the spawner set forgets a way to start a process: os.system, Mininet's Node.cmd,
#   M6        subprocess.check_output. Each is one line of one file in this tree.
#   M3, M4,   the argument walk stops looking: a list literal (`subprocess.run(["pkill", ...])`,
#   M7, M11   which contains no shell and no space before -f), an f-string, `ps | grep` in
#             python, and the extension dispatch that decides which grammar to use.
#   M8-M10    the DATA rule breaks in both directions: an unreadable file reported as a clean
#             one (L-3), and prose read as code -- which is the way a lint gets switched off.
#
# A mutation that makes the WRONG check go red is a SURVIVOR, not a kill: the case it targets was
# never put to the test. Every check name in the suite is unique for exactly this reason.
#
# 🔴 Never writes the checker. Each mutation goes to a COPY in a temp dir and the suite is
# pointed at it with CHECK_PROCESS_BY_NAME_UNDER_TEST -- this worktree is shared and another
# session may be running the real file right now. Byte identity is asserted at the end anyway.
#
# 🔴 Never kills anything by name -- the rule under test. `timeout` owns the only child, and the
# suite reaps its own `sleep` fixtures by pid and asserts that it did.
#
# 🔴 Touches no lab, builds nothing: the checker is read-only, every tree it reads is either this
# repo or a synthetic file in a temp directory.
#
# Usage:  tests/shell/mutate_check_process_by_name.sh
#   TEST_TIMEOUT=300   seconds allowed per suite run
#
# Exit: 0 every mutation was caught by the check named for it, and the control survived
#       1 at least one mutation survived, or was caught by the wrong check
#       2 the gate cannot render a verdict (baseline red, anchor drift, hang, or the control
#         going red -- which would mean this gate measures "the file changed")
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CHECKER="$HERE/check_process_by_name.py"
SUITE="$REPO/tests/shell/test_faults_topo_pid.sh"
PY="${PY:-/usr/bin/python3}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"

if ! bash -n "${BASH_SOURCE[0]}"; then echo "🔴 this script does not parse" >&2; exit 2; fi
command -v timeout >/dev/null || { echo "🔴 GNU timeout is required" >&2; exit 2; }
[[ -f "$CHECKER" && -f "$SUITE" ]] || { echo "🔴 missing $CHECKER or $SUITE" >&2; exit 2; }

BK=$(mktemp -d "${TMPDIR:-/tmp}/check-by-name-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT INT TERM
BASE_SHA=$(sha256sum "$CHECKER" | cut -d' ' -f1)

MUTATIONS=0
SURVIVORS=0
VERDICT=0

# The suite, driven against whichever copy of the checker it is handed.
run_against() { CHECK_PROCESS_BY_NAME_UNDER_TEST="$1" timeout "$TEST_TIMEOUT" bash "$SUITE" 2>&1; }

report() {   # $1 = mutation name, $2 = mutated copy, $3 = the check that must go red
    local out rc
    MUTATIONS=$((MUTATIONS + 1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" == 124 ]]; then
        printf '  🔴 %-58s suite HUNG -- never a catch\n' "$1" >&2
        VERDICT=2; return
    fi
    if (( rc > 128 )); then
        printf '  🔴 %-58s suite died of signal %s -- not an assertion\n' "$1" "$((rc-128))" >&2
        VERDICT=2; return
    fi
    if [[ "$rc" -ne 0 ]] && grep -qF "  FAILED   $3" <<<"$out"; then
        printf '  caught   %-58s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS + 1))
        VERDICT=1
        printf '  SURVIVED %-58s (%s stayed green -- that case proves nothing)\n' "$1" "$3" >&2
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /' >&2
    fi
}

control() {  # $1 = name, $2 = mutated copy -- must NOT go red
    local out rc
    MUTATIONS=$((MUTATIONS + 1))
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  SURVIVED %-58s (control, as required)\n' "$1"
    else
        printf '  🔴 %-58s CONTROL WENT RED -- this gate measures "the file changed"\n' "$1" >&2
        grep -E '^  FAILED|^Ran ' <<<"$out" | sed 's/^/             /' >&2
        VERDICT=2
    fi
}

mutant() {   # $1 = name, $2 = anchor \x1f replacement; prints the path to the mutated copy
    local out="$BK/check.$1.py"; cp "$CHECKER" "$out"
    "$PY" - "$out" "$2" <<'PY'
import sys
p, spec = sys.argv[1], sys.argv[2]
old, new = spec.split("\x1f")
s = open(p).read()
assert s.count(old) == 1, "anchor is not unique (%d matches): %r" % (s.count(old), old[:70])
open(p, "w").write(s.replace(old, new))
PY
    echo "$out"
}

echo "baseline (must be green before any mutation):"
run_against "$CHECKER" | tail -1
if ! run_against "$CHECKER" >/dev/null 2>&1; then
    echo "  🔴 baseline is RED -- nothing below is interpretable" >&2
    run_against "$CHECKER" | grep -E '^  FAILED' | sed 's/^/    /' >&2
    exit 2
fi
echo

# --- family 1: the surface goes back to shell-only -----------------------------------------------
# This is not an invented mutation. It is the state this file was in until 2026-09-11, and the
# state in which it reported "0 new, 0 stale" while two files ran pkill -f as root.

m1=$(mutant m1 '    for pattern in SUITE_GLOBS + PY_GLOBS:'$'\x1f''    for pattern in SUITE_GLOBS:')
report "M1: the derived surface is shell-only again" "$m1" \
       "  and python is in the surface"

# --- family 2: the spawner set forgets a way to start a process ----------------------------------

m2=$(mutant m2 '    "system", "popen", "Popen", "run", "call", "check_call", "check_output",'$'\x1f''    "popen", "Popen", "run", "call", "check_call", "check_output",')
report "M2: os.system is no longer a way to run something" "$m2" \
       "os.system with the shell one-liner"

m5=$(mutant m5 '    "getoutput", "getstatusoutput", "cmd", "sendCmd", "cmdPrint", "pexec",'$'\x1f''    "getoutput", "getstatusoutput", "pexec",')
report "M5: Mininet Node.cmd is not a way to run something" "$m5" \
       "an f-string through a Mininet node"

m6=$(mutant m6 '    "system", "popen", "Popen", "run", "call", "check_call", "check_output",
    "getoutput", "getstatusoutput", "cmd", "sendCmd", "cmdPrint", "pexec",'$'\x1f''    "system", "popen", "Popen", "run", "call", "check_call",
    "getoutput", "getstatusoutput", "cmd", "sendCmd", "cmdPrint", "pexec",')
report "M6: subprocess.check_output is not a spawner" "$m6" \
       "check_output, shell=True"

# --- family 3: the argument walk stops looking ---------------------------------------------------

m3=$(mutant m3 '    elif isinstance(node, (ast.List, ast.Tuple, ast.Set)):'$'\x1f''    elif False:')
report "M3: an argv LIST is not followed into its elements" "$m3" \
       "an argv list, with no shell at all"

m4=$(mutant m4 '    elif isinstance(node, ast.JoinedStr):'$'\x1f''    elif False:')
report "M4: an f-string is not followed into its literal parts" "$m4" \
       "an f-string handed to os.system"

m7=$(mutant m7 '            hit = PS_BY_NAME.search(node.value)'$'\x1f''            hit = None')
report "M7: ps-read-for-a-name is not checked in python" "$m7" \
       "python: ps read for a name"

m11=$(mutant m11 '_ANALYSER_BY_EXTENSION = {".py": python_sites}'$'\x1f''_ANALYSER_BY_EXTENSION = {}')
report "M11: .py is read with the shell parser" "$m11" \
       "a docstring is prose"

# --- family 4: the data rule breaks, in both directions ------------------------------------------
# A false alarm costs the same as a miss: the first person who has to explain why a docstring that
# TEACHES the rule is a violation of it turns the checker off, and the real site goes with it.

m8=$(mutant m8 '        return [(path, 1, NOT_CHECKED, "-", "this file is not parseable python: %s" % err)]'$'\x1f''        return []')
report "M8: unparseable python is reported as a clean file" "$m8" \
       "unparseable python is NOT CHECKED"

m9=$(mutant m9 '    prose = {id(node.value) for node in ast.walk(tree)'$'\x1f''    prose = {id(node.value) for node in tree.body[:1]')
report "M9 (widening): only the module docstring is prose" "$m9" \
       "a string used as a block comment"

m10=$(mutant m10 '        if id(node) in prose:'$'\x1f''        if False:')
report "M10 (widening): prose is read as code" "$m10" \
       "a docstring is prose"

# --- the control ---------------------------------------------------------------------------------
# Rewording a comment must change nothing. Without this, every line above could be measuring
# "the file is not byte-identical" instead of "the behaviour is different".

c1=$(mutant c1 '# python
# ================================================================================================='$'\x1f''# python (the half added 2026-09-11)
# =================================================================================================')
control "C1 (control): a comment is reworded" "$c1"

# --- the checker itself must be untouched --------------------------------------------------------
echo
NOW_SHA=$(sha256sum "$CHECKER" | cut -d' ' -f1)
if [[ "$NOW_SHA" == "$BASE_SHA" ]]; then
    echo "baseline byte-identical: yes  $CHECKER (never written; every mutation went to a copy)"
else
    echo "🔴 $CHECKER WAS WRITTEN -- $BASE_SHA -> $NOW_SHA" >&2
    VERDICT=2
fi

echo
echo "GATE-SUMMARY mutations=$MUTATIONS survived=$SURVIVORS"
echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"
case "$VERDICT" in
    0) echo "VERDICT: every mutation was caught by the check named for it; the control survived" ;;
    1) echo "VERDICT: at least one mutation survived or was caught by the wrong check" >&2 ;;
    *) echo "VERDICT: no verdict -- the gate could not run cleanly" >&2 ;;
esac
exit "$VERDICT"
