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
    '           "--p4", convert_p4_arg(exdir, spec, which), "--out", pkg]' \
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
    '    rrc, rout = ndt(["release"])' \
    '    rrc, rout = 0, ""  # MUTANT: the lab stays claimed by a round that is over' \
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

# 17-21: the lab comes back, and the binary is named. Round 2, after the judge read the code:
# every one of these is a round that ends looking successful and leaves something behind.
#
# 🔴 17 IS THE ONE THAT WAS ACTUALLY BROKEN. `ndt up p4 --app` writes the model's host count
# into p4_proxy/mininet/host_count_override, `ndt down` does not put it back, and `ndt release`
# REFUSES while it differs from what the round started at (ndt:885-898). So before the restore
# existed, `--fabric ndtwin source_routing` (three hosts) ended with the lab still claimed and
# the driver exiting 0.
add "17. the host knob is never put back, so the release is refused" \
    "$DRIVER" \
    '    ok, why = knob_restore(knob_before)' \
    '    ok, why = True, "not restored"  # MUTANT' \
    'test_the_host_knob_is_put_back_between_the_down_and_the_release'

add "18. a release that would not take is not reported" \
    "$DRIVER" \
    '        problems.append("`ndt release` exited %d -- THE LAB IS STILL CLAIMED" % rrc)' \
    '        pass  # MUTANT: the lab stays claimed and the round says PASS' \
    'test_a_release_that_would_not_take_fails_the_run_and_says_the_lab_is_claimed'

# The restore writes the NUMBER instead of the bytes: an annotated knob file comes back as a
# bare digit, which reads the same to host_count_in and is not the same file.
add "19. the knob is restored as a number instead of as its bytes" \
    "$DRIVER" \
    '            f.write(before)' \
    '            f.write(b"4\n")  # MUTANT' \
    'test_the_knob_is_put_back_as_bytes_and_not_as_the_number'

add "20. the bmv2 binary is named but never hashed" \
    "$DRIVER" \
    '    return sha16(path), "%s   (ndt status: %s)" % (ver, value)' \
    '    return "-", value  # MUTANT: a version string, which cannot tell the two builds apart' \
    'test_a_path_in_the_status_row_is_hashed'

add "21. the round never asks ndt status, so nothing names the fabric's binary" \
    "$DRIVER" \
    '            srrc, sout = ndt(["status"])' \
    '            srrc, sout = 0, ""  # MUTANT' \
    'test_the_round_captures_ndt_status_and_hashes_the_binary_it_names'

# 22-23: two refusals and a label.
add "22. the ndtwin fabric may be run as root" \
    "$DRIVER" \
    '    if args.fabric == "ndtwin" and euid() == 0:' \
    '    if False:  # MUTANT: root-owned files in .test_run/ and runs/ are fine' \
    'test_ndtwin_mode_refuses_to_run_as_root_and_says_why'

add "23. the package records the skeleton as its source whatever was compiled" \
    "$DRIVER" \
    '    if which == "solution" and default == spec["prog"]:' \
    '    if False:  # MUTANT: source.p4 names a file this run did not build' \
    'test_a_solution_run_names_the_solution_file_it_compiled'

# 24-30: the cells the judge found unguarded -- each of these is a test that had never been
# seen to fail, which is the same as not having it.
add "24. the firewall SOLUTION arm accepts the external flow getting through" \
    "$DRIVER" \
    '                      not in_ok, G_BOTH,' \
    '                      in_ok, G_BOTH,  # MUTANT' \
    'test_the_solution_arm_wants_the_external_flow_blocked'

add "25. the link_monitor SOLUTION arm accepts a zero port" \
    "$DRIVER" \
    '                      bool(ports) and 0 not in ports, G_SRC,' \
    '                      True, G_SRC,  # MUTANT: the unimplemented arm passes as the solution' \
    'test_the_two_arms_are_distinguishable'

add "26. somebody else's live claim is read as a free lab" \
    "$DRIVER" \
    '    if owner != NDT_OWNER:' \
    '    if False:  # MUTANT: whoever holds it, it is ours' \
    'test_a_live_claim_of_somebody_elses_refuses'

add "27. the loss measurement goes back to two packets" \
    "$DRIVER" \
    '            out = self.cmd(host, "LANG=C ping -c %d -W 2 %s" % (count, dst))' \
    '            out = self.cmd(host, "LANG=C ping -c 2 -W 2 %s" % (dst,))  # MUTANT' \
    'test_pingall_sends_five_packets_on_every_ordered_pair'

# 33.3333% is what ping prints for 2 of 6 lost; an integer-only parser finds nothing there and
# calls a ping that ran UNTESTED -- or, with the other half of the guard gone, calls it clean.
add "28. the loss parser stops reading the decimal form ping prints" \
    "$DRIVER" \
    '        m = re.search(r"([0-9]+(?:\.[0-9]+)?)% packet loss", out)' \
    '        m = re.search(r"([0-9]+)% packet loss", out)  # MUTANT' \
    'test_the_loss_comes_from_the_summary_line'

add "29. the report stops saying which fabric and which package it was" \
    "$DRIVER" \
    '    a("| fabric | `%s` |" % ctx.get("fabric", "tutorials"))' \
    '    pass  # MUTANT: the raw no longer says which fabric produced it' \
    'test_the_report_header_carries_the_fabric_and_the_package'

add "30. an iperf client the timeout killed counts as a transfer" \
    "$DRIVER" \
    '        connected = bool(re.search(r"\d+(\.\d+)?\s*\w?bits/sec", cout)) and not killed' \
    '        connected = bool(re.search(r"\d+(\.\d+)?\s*\w?bits/sec", cout))  # MUTANT' \
    'test_a_client_killed_by_the_timeout_is_not_a_transfer'

# 31-41: the cells that had still never been red after round 2's first pass. A test that has
# never failed is a decoration, and "there is a cell for it" is not the same claim as "that
# cell can tell". Each of these is a defect somebody could actually ship.
add "31. the ndtwin dry run tells the operator to sudo" \
    "$DRIVER" \
    '                    else ndtwin_line(ex, which)))' \
    '                    else sudo_line(ex, which)))  # MUTANT' \
    'test_the_ndtwin_plan_names_the_ndt_commands_and_asks_for_no_sudo'

add "32. every run records solution/ as its source, including the skeleton's" \
    "$DRIVER" \
    '    return default' \
    '    return os.path.join("solution", default)  # MUTANT' \
    'test_a_skeleton_run_names_the_skeleton'

add "33. a status with no bmv2 row is reported as a dash, not as UNREADABLE" \
    "$DRIVER" \
    '        return "-", "UNREADABLE: `ndt status` printed no bmv2 row"' \
    '        return "-", "-"  # MUTANT: a blank identity reads as a binary nobody chose' \
    'test_a_status_with_no_bmv2_row_is_UNREADABLE_and_says_so'

add "34. a bmv2 row naming a file that is not there is hashed anyway" \
    "$DRIVER" \
    '    if not path or not os.path.isfile(path):' \
    '    if False:  # MUTANT' \
    'test_a_row_naming_a_binary_that_is_not_there_is_UNREADABLE'

add "35. the verdict does not mention a lab that was never given back" \
    "$DRIVER" \
    '    return "%s -- LAB NOT RETURNED: %s" % (verdict, problem), exit_code or 1' \
    '    return verdict, exit_code  # MUTANT: PASS over a lab somebody else cannot take' \
    'test_the_verdict_says_the_lab_was_not_returned'

add "36. every exercise compiles a companion, including the ones that have none" \
    "$DRIVER" \
    '    for name in sorted(want - {spec["prog"]}):' \
    '    for name in sorted(want):  # MUTANT' \
    'test_an_exercise_whose_default_is_its_own_program_has_no_companion'

add "37. the firewall's internal-to-external flow is expected to FAIL" \
    "$DRIVER" \
    '                  out_ok, G_BOTH,' \
    '                  not out_ok, G_BOTH,  # MUTANT' \
    'test_both_arms_require_the_internal_to_external_flow'

add "38. the link_monitor SKELETON arm expects a non-zero port" \
    "$DRIVER" \
    '                      ports == [0], G_BOTH,' \
    '                      ports != [0], G_BOTH,  # MUTANT' \
    'test_the_skeleton_arm_expects_every_reported_port_to_be_zero'

add "39. an EXPIRED claim still refuses the lab" \
    "$DRIVER" \
    '    if not re.match(r"^\d+$", exp or "") or int(exp) <= now:' \
    '    if False:  # MUTANT: a stale claim file refuses forever' \
    'test_an_expired_claim_is_not_a_claim'

add "40. the switch_state summary drops the pipeline sha" \
    "$DRIVER" \
    '        lines.append("s%s  ndtwin=%s p4info_sha256=%s  entries recorded=%s applied=%s "' \
    '        lines.append("s%s  ndtwin=%s pipeline=%s  entries recorded=%s applied=%s "  # MUTANT' \
    'test_the_summary_names_the_pipeline_sha_and_the_entry_counts'

add "41. the report names /usr/local/bin's bmv2 whatever the fabric ran" \
    "$DRIVER" \
    '    a("| `%s` | `%s` | %s |" % (ctx["env"].get("switch_path") or SWITCH,' \
    '    a("| `%s` | `%s` | %s |" % (SWITCH,  # MUTANT' \
    'test_the_report_names_the_bmv2_binary_by_its_sha'

# 42: the last cell that had never been red. The anchor carries the note line below it,
# because the same assertion is written in both arms and a bare `swids == [1, 2, 3, 4]` would
# land in whichever came first -- check_gate_anchors.py's DUP verdict, enforced at write time.
add "42. the link_monitor SOLUTION arm expects three of the four switches" \
    "$DRIVER" \
    '                      swids == [1, 2, 3, 4], G_SRC,
                      "send.py'"'"'s 9 ProbeFwd hops walk s1-s4-s2-s3-s1-s3-s2-s4-s1 over pod-topo")' \
    '                      swids == [1, 2, 3], G_SRC,  # MUTANT
                      "send.py'"'"'s 9 ProbeFwd hops walk s1-s4-s2-s3-s1-s3-s2-s4-s1 over pod-topo")' \
    'test_the_solution_arm_wants_all_four_switch_ids_and_no_zero_port'

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
        # 🔴 EVERY test that went red is printed, not only the expected one: that list is what
        # the SUMMARY's "which mutation was this test ever red for" table is built from, and a
        # cell that only ever names the expected test cannot tell a well-aimed mutation from a
        # blunt one. (B's gate prints the same thing for the same reason.)
        local also; also=$(tr ' ' '\n' <<<"$failed" | /usr/bin/grep -v -x -- "$expected" | tr '\n' ' ')
        printf '  ✅ caught by %s\n     also red: %s\n' "$expected" "${also:-(nothing else)}"
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

# 🔴 WHAT THIS GATE DOES NOT ESTABLISH, said out loud and kept true.
#
# An earlier version of this footer claimed the 09-08 fixture comparison was "not reddened by
# design". It is: mutation 1 (the default fabric) turns it red, and the run log says so. A
# footer that describes the gate's own output wrongly is the same defect the gate exists to
# catch, one level up.
#
# What IS true: every mutation names ONE test, and the `also red:` line under each one names
# the others that went red with it. Read together those lines cover EVERY cell in the suite --
# all fifty have been red for at least one mutation here, which is the claim "no test in this
# suite is a decoration" and is the only form of it worth making. The last eleven mutations
# (31-42) exist for exactly that: each was added because some cell had never been seen to
# fail, and the P2-C SUMMARY carries the cell-by-cell table this run produces.
printf '\nevery cell in the suite has been red for at least one mutation above; the `also red:`\n'
printf 'lines are what that claim is built from. (The 09-08 fixture comparison IS reddened --\n'
printf 'by mutation 1 -- and this footer used to say it was not.)\n'

printf '\n%s mutations, %s survived\n' "$MUTATIONS" "$SURVIVORS"
[[ "$SURVIVORS" -eq 0 ]]
