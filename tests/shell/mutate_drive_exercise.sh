#!/usr/bin/env bash
#
# Mutation gate for doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py
# and its offline suite (TICKET-P2 section 5, worker C).
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration, and this driver's suite is the
# shape most at risk of being one: every fabric in it is a stub, so a cell can be green
# because the driver is right or because the stub answered the question for it. Sixteen
# mutations, each aimed at a decision the driver makes on its own, and each naming the ONE
# test that must go red for it.
#
# 🔴 THE MUTANT IS A COPY, AND THE ORIGINAL IS NEVER WRITTEN. `mutate_p4_exercise_tools.sh`
# edits its subjects in place and restores them, which is safe there and is not safe here:
# this worktree's drive_exercise.py is also the file the orchestrator's LIVE round runs, and
# a gate interrupted mid-mutation would leave a mutant on disk for it. So the copy goes to a
# temp directory and the suite is pointed at it through DRIVE_EXERCISE_UNDER_TEST; the sha256
# of the real file is taken before the first mutation and again at the end, and the run says
# so out loud rather than leaving it to be assumed.
#
# One deliberate rule, the same as the gates this is modelled on: a mutant that does not
# parse, an anchor that has moved or matches twice, a run that HUNG, or the wrong test going
# red all count as SURVIVORS -- never a warning, never a discount. A mutation that never
# reached the interpreter established nothing. None of them aborts the remaining mutations.
#
# 🔴 THE NEGATIVE CONTROL is not optional either: a suite that reddens for any edit would
# print "16 caught" above while catching nothing at all. A comment-only edit must stay green.
#
# Usage:  tests/shell/mutate_drive_exercise.sh
#         PYTHON=... tests/shell/mutate_drive_exercise.sh
#         ANCHOR_CHECK=1 tests/shell/mutate_drive_exercise.sh   # NOT a gate result
# Assumes: cwd is the repo root (or this worktree's root).
# Exit:    0 all mutations caught and the control stayed green; 1 a mutation survived or the
#          control went red; 2 refused (baseline red, the original was written, or
#          anchor-check mode, which never produces a verdict).
set -uo pipefail

# 🔴 NO BYTECODE CACHE. A .pyc is revalidated against the source's (mtime-in-SECONDS, size),
# and several of these mutations keep the file the same length; two applied inside one
# wall-clock second could then be shadowed by the previous mutant's cache and the verdict
# would describe a file that was never on disk.
export PYTHONDONTWRITEBYTECODE=1

PYTHON="${PYTHON:-p4_proxy/venv/bin/python}"
PREP=doc/audit/2026-09-04_p4-tutorial-exercise-prep
DRIVER="$PREP/drive_exercise.py"
TESTS="$PREP/tests"

ANCHOR_CHECK="${ANCHOR_CHECK:-0}"
if [[ "${1:-}" == "--dry-run" ]]; then
    ANCHOR_CHECK=1
fi

[[ -f "$DRIVER" ]] || { echo "REFUSE: $DRIVER not found -- run from the repo root." >&2; exit 2; }
[[ -d "$TESTS" ]]  || { echo "REFUSE: $TESTS not found -- run from the repo root." >&2; exit 2; }
[[ -x "$PYTHON" ]] || { echo "REFUSE: no interpreter at $PYTHON (override with PYTHON=)." >&2; exit 2; }

# --- helpers ---------------------------------------------------------------------------------

# anchor_count <file> <literal> -- how many times the literal occurs. Shown for every mutation:
# an anchor matching twice silently mutates the wrong site, and one matching zero times makes
# the mutation a no-op that then "passes".
#
# python, not `grep -c -F`: grep splits a multi-line -F pattern into several patterns and
# counts matching LINES, so a multi-line anchor would report the wrong number.
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

# 1-2 are the 09-08 control: the tutorials arm is the baseline every NDTwin number is read
# against, so a driver that quietly changed which fabric it builds, or which json the harness
# is handed, would make "the same command, again" a sentence nobody could check.
add "1. --fabric defaults to ndtwin, so the 09-08 command builds another fabric" \
    "$DRIVER" \
    '    ap.add_argument("--fabric", choices=["tutorials", "ndtwin"], default="tutorials",' \
    '    ap.add_argument("--fabric", choices=["tutorials", "ndtwin"], default="ndtwin",' \
    'test_the_default_fabric_is_tutorials'

add "2. the harness is handed the VARIANT's json instead of DEFAULT_PROG's" \
    "$DRIVER" \
    '            % (VENV_PY, TUT, spec["topo"], default_base, SWITCH))' \
    '            % (VENV_PY, TUT, spec["topo"], base, SWITCH))  # MUTANT' \
    'test_the_tutorials_harness_is_handed_the_default_programs_json'

# 3-4: exercises/firewall is the one shipped exercise whose switches do NOT all run the same
# program (pod-topo/topology.json gives s1 build/firewall.json, the Makefile gives s2-s4
# basic.p4). Both halves of that are a silent wrong-program bring-up: nothing crashes, every
# switch forwards, and the twin reports health throughout.
add "3. the companion program is never compiled, so s2-s4 have no json" \
    "$DRIVER" \
    '    want = {spec["prog"], spec["default_prog"]}' \
    '    want = {spec["prog"]}  # MUTANT: only the variant is built' \
    'test_firewall_builds_its_own_program_and_the_default_one'

add "4. convert.py is given the variant stem, so every switch gets the wrong default" \
    "$DRIVER" \
    '           "--p4", spec["default_prog"], "--out", pkg]' \
    '           "--p4", spec["prog"], "--out", pkg]  # MUTANT' \
    'test_convert_is_given_the_default_prog_and_not_the_variant'

# 5-6: the loss number. Both acceptance conditions this driver reports are RATES, and both of
# these turn a reading that did not happen into the best possible one.
add "5. a ping with no summary line reads as 0% loss" \
    "$DRIVER" \
    '            return PingResult(None, 0, 0,
                              why="ping printed no '"'"'%% packet loss'"'"' summary for %s -> %s"
                                  % (host, dst),
                              raw=out)' \
    '            return PingResult(0.0, count, count, raw=out)  # MUTANT: silence is success' \
    'test_a_ping_with_no_summary_line_is_untested_and_not_zero_loss'

add "6. an untested pair is left out of the total instead of voiding it" \
    "$DRIVER" \
    '        if self.untested or not self.sent:' \
    '        if not self.sent:  # MUTANT: untested pairs do not count against the rate' \
    'test_one_untested_pair_voids_the_number_even_when_the_others_were_clean'

# 7-8: the namespace. `ndt`'s host_pid rule is the TAIL field because `mn -c` kills by that
# exact string; a substring match finds this driver's own `sh -c` line as often as the host.
add "7. the namespace pid is matched anywhere in the argv, not at its tail" \
    "$DRIVER" \
    '            if len(parts) >= 2 and parts[-1] == tag and parts[0].isdigit():' \
    '            if tag in line and parts and parts[0].isdigit():  # MUTANT' \
    'test_the_pid_is_the_tail_field_of_the_process_table'

add "8. a host with no namespace comes back as pid 0 instead of a named failure" \
    "$DRIVER" \
    '        raise HostNotFound(
            "no namespace for %s: no process in `ps -eo pid=,args=` ends in %r" % (host, tag))' \
    '        return "0"  # MUTANT: no namespace is rendered as a pid, and then as packet loss' \
    'test_a_host_with_no_namespace_is_a_named_failure_and_not_zero_loss'

# 9-11: the lab. A package that will not pre-flight must not have held the lab while it was
# being rejected, a claim must come back however the round ended, and `ndt` must know who is
# asking (CLAUDE.md: ndt 指令都帶 NDT_OWNER).
add "9. a FAILED pre-flight goes on to claim the lab and bring the fabric up" \
    "$DRIVER" \
    '    if rc != 0:
        say("!! pre-flight FAILED (rc %d). '"'"'ndt up p4 --app'"'"' would refuse this too;"
            " nothing was started." % rc)
        return 2, pkg, state' \
    '    if False:  # MUTANT: the lab is held while the package is being rejected
        pass' \
    'test_a_refused_preflight_never_takes_the_claim'

add "10. the claim is not given back when a step raised" \
    "$DRIVER" \
    '        rrc, _ = ndt(["release"])' \
    '        rrc = 0  # MUTANT: the lab stays claimed by a round that is over' \
    'test_the_teardown_runs_both_halves_even_when_the_steps_raise'

add "11. the ndt calls go out with whatever owner the environment had" \
    "$DRIVER" \
    '    env["NDT_OWNER"] = NDT_OWNER' \
    '    env.pop("NDT_OWNER", None)  # MUTANT' \
    'test_every_ndt_call_carries_the_owner'

# 12-14: the two new exercises' arms. A red arm that is not red makes the green arm evidence of
# nothing -- live-p1/03's whole argument, and the reason each of these is a cell of its own.
add "12. the firewall skeleton arm asserts the flow is BLOCKED (the red arm cannot be red)" \
    "$DRIVER" \
    '                      in_ok, G_BOTH,' \
    '                      not in_ok, G_BOTH,  # MUTANT' \
    'test_the_skeleton_arm_is_red_when_the_external_flow_is_blocked'

add "13. link_monitor stops checking the port field, the only thing that tells the arms apart" \
    "$DRIVER" \
    '                      ports == [0], G_BOTH,' \
    '                      True, G_BOTH,  # MUTANT: any port is the skeleton port' \
    'test_the_two_arms_are_distinguishable'

add "14. a run in which NO probe arrived passes every check about the probes" \
    "$DRIVER" \
    '                  len(rows) >= 1, G_README,' \
    '                  True, G_README,  # MUTANT: no rows is not a problem' \
    'test_no_probe_rows_fails_the_injection_check_rather_than_passing_vacuously'

# 15: `measuring=` is the only channel a session has for "you cannot see what I am running
# from the process table" (ROLE-4 T2d). Ignoring it loses somebody else's measurement.
add "15. a claim that DECLARES a measurement is treated as a free lab" \
    "$DRIVER" \
    '    if fields.get("measuring"):' \
    '    if False:  # MUTANT: a declared measurement does not stop a bring-up' \
    'test_our_own_claim_that_declares_a_measurement_refuses_too'

# 16: the raw. An unreadable switch_state rendered as a row of Nones is a reading nobody took,
# printed where the reader expects one that was.
add "16. an unreadable switch_state is rendered as an ordinary (empty) report" \
    "$DRIVER" \
    '    if not isinstance(state, dict) or "error" in state:' \
    '    if False:  # MUTANT: whatever came back is a report' \
    'test_an_unreadable_switch_state_says_so_instead_of_printing_zeros'

CTRL_SRC="$DRIVER"
CTRL_ANCHOR='def host_key(name):'
CTRL_REPL='# MUTANT: a comment, and nothing else.
def host_key(name):'

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

# --- the work directory, and the original's sha -------------------------------------------------

WORK="$(mktemp -d "${TMPDIR:-/tmp}/drive-exercise-mutate-XXXXXX")"
trap 'rm -rf "$WORK" "$TESTS/__pycache__"' EXIT
MUTANT="$WORK/drive_exercise.py"
BASE_SUM="$(sha256sum "$DRIVER" | cut -d' ' -f1)"

MUTATIONS=0
SURVIVORS=0

# red_tests [driver] -- the space-separated names of the test methods that failed or errored,
# or the single token HUNG when the suite did not finish.
#
# 🔴 A TIMEOUT IS A SURVIVOR. A mutation that made the suite hang produces no red test, and
# "nothing went red" and "nothing finished" would otherwise be scored the same way.
red_tests() {
    local out rc drv="${1:-$DRIVER}"
    rm -rf "$TESTS/__pycache__"
    out=$(DRIVE_EXERCISE_UNDER_TEST="$drv" timeout 600 \
          "$PYTHON" -m unittest discover -s "$TESTS" -t "$TESTS" 2>&1); rc=$?
    if [[ $rc -eq 124 ]]; then echo "HUNG"; return; fi
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^\(FAIL\|ERROR\): \([A-Za-z_][A-Za-z0-9_]*\) .*/\2/p' <<<"$out" | sort -u | tr '\n' ' '
}

# mutate <label> <src> <anchor> <replacement> <expected-test>
#
# `src` is the repo file the anchor is counted in -- which is what
# tests/shell/check_gate_anchors.py reads -- and the file that is WRITTEN is the copy.
mutate() {
    local label="$1" src="$2" anchor="$3" repl="$4" expected="$5"
    local n; n=$(anchor_count "$src" "$anchor")
    printf '\n=== %s ===\n' "$label"
    printf '  subject           : %s  (mutated as a copy in %s)\n' "$src" "$WORK"
    printf '  anchor occurrences: %s\n' "$n"
    if [[ "$n" -ne 1 ]]; then
        echo "  🔴 ANCHOR IS NOT UNIQUE ($n matches) -- this mutation proves nothing. Fix the anchor."
        SURVIVORS=$((SURVIVORS + 1)); MUTATIONS=$((MUTATIONS + 1)); return
    fi
    MUTATIONS=$((MUTATIONS + 1))

    cp "$src" "$MUTANT"
    if ! ANCHOR="$anchor" REPL="$repl" "$PYTHON" - "$MUTANT" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
a, r = os.environ["ANCHOR"], os.environ["REPL"]
assert s.count(a) == 1, "anchor is not unique at write time"
p.write_text(s.replace(a, r, 1))
PY
    then
        echo "  🔴 mutation could not be applied. NOT a pass."
        SURVIVORS=$((SURVIVORS + 1)); return
    fi

    # A mutant that does not parse never reached the tests, so it establishes nothing.
    if ! "$PYTHON" -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$MUTANT" >/dev/null 2>&1; then
        echo "  🔴 MUTANT DOES NOT PARSE -- the behaviour it was aimed at is still untested."
        SURVIVORS=$((SURVIVORS + 1)); return
    fi

    local failed; failed=$(red_tests "$MUTANT")
    if [[ "$failed" == "HUNG" ]]; then
        echo "  🔴 THE SUITE DID NOT FINISH (timeout) -- a run that hung caught nothing."
        SURVIVORS=$((SURVIVORS + 1))
    elif [[ -z "$failed" ]]; then
        echo "  🔴 NOTHING WENT RED -- the mutation survived. That behaviour is untested."
        SURVIVORS=$((SURVIVORS + 1))
    elif /usr/bin/grep -q -- "$expected" <<<"$failed"; then
        printf '  ✅ caught by %s\n     all red: %s\n' "$expected" "$failed"
    else
        printf '  🔴 WRONG TEST WENT RED: got [%s], expected [%s]\n' "$failed" "$expected"
        echo "     The gate fires, but not for the reason this mutation claims."
        SURVIVORS=$((SURVIVORS + 1))
    fi
}

# --- baseline -----------------------------------------------------------------------------------

echo "TICKET-P2 §5 drive_exercise.py mutation gate"
echo "  interpreter : $PYTHON"
echo "  subject     : $DRIVER"
echo "  suite       : $TESTS"
printf '  baseline    : %s %s\n' "${BASE_SUM:0:16}" "$DRIVER"
echo
echo "baseline (unmutated) must be green:"
BASE_RED=$(red_tests)
if [[ -n "$BASE_RED" ]]; then
    echo "  REFUSE: baseline is RED before any mutation."
    printf '    red: %s\n' "$BASE_RED"
    DRIVE_EXERCISE_UNDER_TEST="$DRIVER" "$PYTHON" -m unittest discover -s "$TESTS" -t "$TESTS" 2>&1 \
        | tail -20 | sed 's/^/    /'
    exit 2
fi
DRIVE_EXERCISE_UNDER_TEST="$DRIVER" "$PYTHON" -m unittest discover -s "$TESTS" -t "$TESTS" 2>&1 \
    | tail -3 | sed 's/^/    /'
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
    cp "$CTRL_SRC" "$MUTANT"
    ANCHOR="$CTRL_ANCHOR" REPL="$CTRL_REPL" "$PYTHON" - "$MUTANT" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
p.write_text(s.replace(os.environ["ANCHOR"], os.environ["REPL"], 1))
PY
    ctrl_red=$(red_tests "$MUTANT")
    if [[ -z "$ctrl_red" ]]; then
        echo "  ✅ green: the suite does not react to a comment"
    else
        printf '  🔴 A COMMENT TURNED THE SUITE RED: %s\n' "$ctrl_red"
        echo "     These tests are change detectors, not a specification."
        SURVIVORS=$((SURVIVORS + 1))
    fi
fi

# --- the original, and the verdict ---------------------------------------------------------------
#
# Nothing above writes $DRIVER, and this is where that stops being a claim: the sha is taken
# again and compared, and the suite is run once more against the real file.

printf '\n--- was the original written? ---\n'
NOW_SUM="$(sha256sum "$DRIVER" | cut -d' ' -f1)"
if [[ "$NOW_SUM" != "$BASE_SUM" ]]; then
    printf '  🔴 %s CHANGED DURING THE GATE -- do NOT commit\n' "$DRIVER"
    printf '     before: %s\n     after:  %s\n' "$BASE_SUM" "$NOW_SUM"
    exit 2
fi
printf '  byte-identical  %s  sha256 %s\n' "$DRIVER" "$BASE_SUM"

after_red=$(red_tests)
if [[ -n "$after_red" ]]; then
    printf '🔴 THE SUITE IS RED AGAINST THE REAL FILE: %s\n' "$after_red"
    exit 2
fi
echo "  suite green against the real file"

# Said out loud rather than left to be noticed: the cells no mutation above is expected to
# redden are not evidence about these sixteen behaviours. The fixture comparison
# (test_the_tutorials_plan_and_sudo_line_are_what_they_printed_on_09_08) is a regression guard
# -- it is green against a driver that is consistently wrong about the ndtwin half -- which is
# why mutation 2 names the firewall cell and not it.
printf '\nnot reddened by design: the report-shape cells and the 09-08 fixture comparison\n'
printf '(regression guards; they discriminate nothing about the sixteen behaviours above)\n'

printf '\n%s mutations, %s survived\n' "$MUTATIONS" "$SURVIVORS"
[[ "$SURVIVORS" -eq 0 ]]
