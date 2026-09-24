#!/usr/bin/env bash
#
# Mutation gate for doc/audit/2026-09-04_p4-tutorial-exercise-prep/drive_exercise.py
# and its offline suite (TICKET-P2 section 5, worker C).
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration, and this driver's suite is the
# shape most at risk of being one: every fabric in it is a stub, so a cell can be green
# because the driver is right or because the stub answered the question for it. Every
# mutation below is aimed at a decision the driver makes on its own, and each names the ONE
# test that must go red for it.  (No count is written here on purpose: this header said
# "Sixteen" while the table had grown to 42, and a gate that misdescribes its own size is
# the defect it exists to catch, one level up. The run prints the number it actually ran.)
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
# print "N caught" above while catching nothing at all. A comment-only edit must stay green.
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

# [Co-developed with claude code -- Adam]
# 🔴 ABSOLUTE, DERIVED FROM THIS SCRIPT'S OWN LOCATION (TICKET-P3 §9 ruling 14d) -- the way
# every other gate in this directory already does it.
#
# These four were RELATIVE, so "which files this gate measured" depended on the caller's cwd.
# Run from another checkout, `$DRIVER` resolved to THAT checkout's drive_exercise.py: the
# anchors genuinely were not in the file the gate read, and it reported
# `ANCHOR IS NOT UNIQUE (0 matches) -- Fix the anchor.` -- a true statement about the wrong
# file, and indistinguishable from an anchor that had really gone stale. That is exactly the
# failure §9 ruling 12a named for `bash -n`, in a second place: A TOOL THAT MEASURED THE WRONG
# THING, OR COULD NOT MEASURE AT ALL, MUST SAY SO ABOUT ITSELF -- never about its subject.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && cd .. && pwd)"
PYTHON="${PYTHON:-$REPO/p4_proxy/venv/bin/python}"
PREP="$REPO/doc/audit/2026-09-04_p4-tutorial-exercise-prep"
DRIVER="$PREP/drive_exercise.py"
TESTS="$PREP/tests"

# 🔴 THE LOG SAYS WHAT THIS RUN READ (§9 ruling 14d). Round 4's bad run was only diagnosable
# by re-deriving it afterwards; a log that names the cwd, the resolved interpreter, the resolved
# subject and its sha cannot be mistaken for a run against a different checkout.
printf 'gate       : %s\n' "${BASH_SOURCE[0]}"
printf 'cwd        : %s\n' "$PWD"
printf 'interpreter: %s\n' "$(realpath "$PYTHON" 2>/dev/null || echo "MISSING: $PYTHON")"
printf 'subject    : %s\n' "$(realpath "$DRIVER" 2>/dev/null || echo "MISSING: $DRIVER")"
printf 'subject sha: %s\n' "$(sha256sum "$DRIVER" 2>/dev/null | cut -d' ' -f1)"
echo

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
# 🔴 IT REFUSES INSTEAD OF ANSWERING A NUMBER IT DOES NOT HAVE (§9 ruling 14d). When the
# interpreter could not run, this printed nothing, `n` became the empty string, and the caller's
# arithmetic turned that into 0 -- reported as `ANCHOR IS NOT UNIQUE (0 matches)`, i.e. a claim
# about the anchor. There is no number to report: the gate stops, rc 2, no verdict line, the
# same refusal a dead mutant gets in mutate_ndt_up_down_robust.sh.
# 🔴 THE REFUSAL, REACHED FROM THE PARENT SHELL (§9 ruling 15①). `anchor_count` cannot end the
# gate from inside `$(...)`, so it returns 2 and every call site funnels here. This is the only
# place that ends the process, and it ends it the way a refusal must: rc 2, no verdict line.
#: How many times the suite failed to RUN (no `Ran N tests` line). 🔴 SEPARATE FROM SURVIVORS
#: AND IT REFUSES EVERYWHERE (TICKET-P3 §9 ruling 16②). Round 6 made NO-SUITE a refusal at the
#: baseline only: inside `mutate` it was SURVIVORS++ and the gate carried on to print
#: `N mutations, M survived` -- a verdict about a comparison that never happened, the exact
#: shape ruling 12a forbids; at the negative control it printed "A COMMENT TURNED THE SUITE
#: RED: NO-SUITE" (it did not -- the suite never ran); and the closing check called it
#: "THE SUITE IS RED". A suite that did not execute is not red, not green and not a survivor.
NOSUITE=0

refuse_no_suite() {   # refuse_no_suite <where>
    NOSUITE=$((NOSUITE+1))
    echo
    echo "🔴 REFUSED: the test suite did not run at all (no 'Ran N tests' line) -- $1."
    echo "   interpreter: $PYTHON"
    echo "   That is neither red nor green nor a survivor: nothing was measured. No verdict"
    echo "   line is printed, because a count of survivors would describe a comparison that"
    echo "   never happened."
    exit 2
}

refuse_anchor_count() {
    echo
    echo "🔴 REFUSED: the gate could not count anchors, so it measured nothing."
    echo "   No verdict line is printed at all: a count of survivors would be a claim about a"
    echo "   comparison that never happened. See the REFUSED lines above for what failed."
    exit 2
}

anchor_count() {
    local out rc
    out="$(ANCHOR="$2" "$PYTHON" - "$1" 2>&1 <<'PY'
import os, pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text().count(os.environ["ANCHOR"]))
PY
)"; rc=$?
    if [[ "$rc" -ne 0 || ! "$out" =~ ^[0-9]+$ ]]; then
        echo "🔴 REFUSED: anchor_count could not run (rc=$rc)" >&2
        echo "   interpreter : $PYTHON" >&2
        echo "   subject     : $1" >&2
        echo "   it printed  : ${out:-<nothing>}" >&2
        echo "   This is NOT 'the anchor is stale' -- the gate could not look. No verdict." >&2
        # 🔴 `return 2`, NOT `exit 2` (TICKET-P3 §9 ruling 15①). Every call site is
        # `n=$(anchor_count ...)`, and `exit` inside a command substitution ends only THAT
        # subshell: the parent read `n=""`, `[[ "" -ne 1 ]]` was true, and the gate printed
        # `ANCHOR IS NOT UNIQUE ( matches)`, counted a survivor, and still printed
        # `86 mutations, 87 survived` / rc 1. In gate mode round 5's "refusal" changed nothing
        # but a line on stderr. A refusal has to travel as an EXIT STATUS the caller checks.
        return 2
    fi
    printf '%s\n' "$out"
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
    '        say("!! pre-flight FAILED (rc %d). '"'"'ndt up p4 --app'"'"' would refuse this too;"
            " nothing was started." % rc)
        return 2, pkg, state' \
    '        pass  # MUTANT: the lab is held while the package is being rejected' \
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

# 43 (P2-E): the defect the 2026-09-18 19:11 live round actually hit. Without `-u` the
# receiver's stdout is a file the interpreter block-buffers, and _stop_receiver's SIGTERM
# runs no atexit handler -- so link_monitor's driver-h1-receive.log came back 0 B and every
# assertion about the probes failed while the switch log held all 8 of them. This is a
# mutation whose survival would be invisible in the suite and loud in the lab: the arms that
# pass (basic, source_routing) pass only because THEIR receive.py flushes itself.
add "43. the receiver is started buffered, so its output dies with the SIGTERM" \
    "$DRIVER" \
    '        cmd = [VENV_PY, "-u", self._script(script)]' \
    '        cmd = [VENV_PY, self._script(script)]  # MUTANT: a file is block-buffered' \
    'test_every_receive_py_is_started_unbuffered_with_u_before_the_script'

# ---------------------------------------------------------------------------------------------
# TICKET-P3 §6.2: the other nine exercises, the `--telemetry` flag and the generic cell.
#
# 🔴 EVERY ONE OF THESE AIMS AT A DECISION THE DRIVER MAKES, not at a reading the stub could
# have answered for it. The nine new arms are the shape most at risk of being decoration: none
# of them has ever been run, so a cell can be green because the expectation is right or because
# nothing ever produced a value for it.

# 44-45: exercises/basic_tunnel is the one exercise whose claim is that the TUNNEL routed the
# packet. Both of these turn it back into a claim about IP routing.
add "44. the two tunnel rounds change the destination IP, not just dst_id" \
    "$DRIVER" \
    '        scmd = [VENV_PY, self._script("send.py"), self.ips["h2"], "P4 driver probe",
                "--dst_id", str(dst_id)]' \
    '        scmd = [VENV_PY, self._script("send.py"), self.ips["h%d" % dst_id],
                "P4 driver probe", "--dst_id", str(dst_id)]  # MUTANT' \
    'test_both_rounds_send_to_the_same_ip_and_only_dst_id_moves'

add "45. a tunnel packet arriving at BOTH hosts is accepted" \
    "$DRIVER" \
    '                      n3_b >= 1 and n2_b == 0, G_BOTH,' \
    '                      n3_b >= 1, G_BOTH,  # MUTANT: h2 may have it too' \
    'test_a_tunnel_that_delivered_to_the_wrong_host_is_red'

# 46: exercises/calc's answer is a LINE. As a substring, `2` is in half the error messages that
# file can print -- including "cannot find P4calc header in the packet" the moment a count
# appears in it -- so the failure would be read as the answer.
add "46. the calc answer is matched as a substring instead of a line" \
    "$DRIVER" \
    '        answered = bool(re.search(r"^2$", out, re.M))' \
    '        answered = "2" in out  # MUTANT' \
    'test_the_answer_is_a_line_and_not_a_substring'

# 47: the REPL is never told to quit, so every calc round ends on SEND_TIMEOUT and a driver
# timeout is reported as the switch not answering.
add "47. calc.py is never told to quit" \
    "$DRIVER" \
    '        out = self._send_once("h1", scmd, feed=b"1+1\nquit\n", label="K1  h1 calc.py <<< 1+1")' \
    '        out = self._send_once("h1", scmd, feed=b"1+1\n", label="K1  h1 calc.py <<< 1+1")' \
    'test_the_repl_is_fed_the_expression_and_the_quit'

# 48: 🔴 ecn WITHOUT THE QUEUE. ecn.p4:9's ECN_THRESHOLD is 10 enqueued packets; nothing else in
# the exercise builds a queue, so the solution arm would be red for a reason that is not ecn.p4
# and the report would say "no congestion mark" about a fabric that was never congested.
# (P4-D'', TICKET-P4-roles §7 ruling 7: the anchor now carries the ecn background's own -t.)
add "48. ecn stops running the background flow that builds the queue" \
    "$DRIVER" \
    '        srv, cli, fh = self._background_udp(
            "h11", "h22", self.ips["h22"], rate="1M",
            seconds=ecn_background_seconds(self.args.recv_warmup, self.args.drain_wait))
        try:
            recv, rfh, rpath, rcmd = self._start_receiver("h2", "h2")
            self.steps.append(("E1  h2 starts the sniffer", rcmd, "(background; output below)"))' \
    '        srv = cli = fh = None  # MUTANT: no queue, no congestion, no mark
        try:
            recv, rfh, rpath, rcmd = self._start_receiver("h2", "h2")
            self.steps.append(("E1  h2 starts the sniffer", rcmd, "(background; output below)"))' \
    'test_ecn_runs_a_background_flow_between_h11_and_h22'

# 49: the ecn skeleton arm tolerates a marked packet, so the two arms stop being two arms.
add "49. the ecn skeleton arm accepts a congestion mark" \
    "$DRIVER" \
    '                      bool(tos) and set(tos) == {"0x1"}, G_BOTH,
                      "README step 1.8: '"'"'the ipv4.tos field is always 1'"'"'; ecn.p4:132-138 "' \
    '                      bool(tos), G_BOTH,  # MUTANT
                      "README step 1.8: '"'"'the ipv4.tos field is always 1'"'"'; ecn.p4:132-138 "' \
    'test_the_ecn_arms_are_distinguishable'

# 50: only one protocol is sent. A switch that stamped 0xb9 on everything would then pass, and
# the classification IS exercises/qos.
add "50. qos sends only UDP" \
    "$DRIVER" \
    '        udp_tos, udp_out, udp_n = self._qos_round("UDP", "1")
        tcp_tos, tcp_out, tcp_n = self._qos_round("TCP", "2")' \
    '        udp_tos, udp_out, udp_n = self._qos_round("UDP", "1")
        tcp_tos, tcp_out, tcp_n = udp_tos, udp_out, udp_n  # MUTANT' \
    'test_qos_sends_both_protocols_with_the_flags_its_send_py_parses'

# 51: the qos TCP class is asserted against UDP's value, which is the same mistake one layer in.
add "51. qos expects the UDP class on TCP as well" \
    "$DRIVER" \
    '                      str(sorted(set(tcp_tos))), "0xb1" in tcp_tos, G_BOTH,' \
    '                      str(sorted(set(tcp_tos))), "0xb9" in tcp_tos, G_BOTH,  # MUTANT' \
    'test_a_fabric_that_stamped_one_class_on_both_protocols_is_red'

# 52: mri stops asserting that the option arrived at all, so "count = 0" becomes true of a
# packet whose MRI option was never there -- which is a different exercise failing.
add "52. mri no longer checks that the MRI option reached h2" \
    "$DRIVER" \
    '        self._add("injection: the MRI option survived to h2", ">=1 count field",
                  "%d" % len(counts), bool(counts), G_SRC,' \
    '        self._add("injection: the MRI option survived to h2", ">=1 count field",
                  "%d" % len(counts), True, G_SRC,  # MUTANT' \
    'test_a_packet_with_no_mri_option_fails_its_own_check'

# 53: the mri skeleton arm accepts any count, so a solution-shaped trace passes it.
add "53. the mri skeleton arm accepts any hop count" \
    "$DRIVER" \
    '                      bool(counts) and set(counts) == {0}, G_BOTH,' \
    '                      bool(counts), G_BOTH,  # MUTANT' \
    'test_the_mri_arms_are_distinguishable'

# 54: one send instead of ten. A single packet is consistent with BOTH load_balance arms --
# the skeleton always picks h2 and the solution picks one of the two -- so the exercise's whole
# claim disappears while every cell stays green-looking.
add "54. load_balance sends one packet instead of ten" \
    "$DRIVER" \
    '        for i in range(10):' \
    '        for i in range(1):  # MUTANT' \
    'test_ten_packets_are_sent_to_the_load_balanced_address'

# 55: the load_balance solution arm accepts a fabric that only ever used h2 -- the skeleton's
# own result.
add "55. the load_balance solution arm accepts only h2 being used" \
    "$DRIVER" \
    '                      n2 >= 1 and n3 >= 1, G_BOTH,' \
    '                      n2 >= 1, G_BOTH,  # MUTANT' \
    'test_the_load_balance_arms_are_distinguishable'

# 56: 🔴 THE HALF OF multicast THAT IS NOT REACHABILITY. sig-topo/s1-runtime.json:47-65
# replicates ports 1,2,3 and the fourth is the student's own TODO, so a fabric that reached h4
# is running something the package does not carry -- and without this the solution arm is
# "everything pings", which is the answer for a completely different runtime json.
add "56. multicast stops requiring h4 to be unreachable" \
    "$DRIVER" \
    '        h4_blocked = bool(to_h4) and all(r.tested and r.loss == 100 for r in to_h4)' \
    '        h4_blocked = True  # MUTANT' \
    'test_a_solution_that_also_reached_h4_is_red'

# 57: an untested pair counts as a blocked one. A host whose namespace could not be entered
# then reads exactly like a host the multicast group does not replicate to.
add "57. an untested pair passes multicast's injection check" \
    "$DRIVER" \
    '                  pa.untested == 0, G_SRC,' \
    '                  True, G_SRC,  # MUTANT' \
    'test_an_untested_pair_is_not_a_blocked_one'

# 58: multicast runs the exercise'\''s disable_ipv6.sh as shipped -- `sudo sysctl` on the BOX.
# It would turn IPv6 off for everything on this laptop, which is not this driver'\''s to do.
add "58. multicast disables IPv6 on the machine instead of in the namespaces" \
    "$DRIVER" \
    '            out = self.h.cmd(name, "sysctl -w net.ipv6.conf.all.disable_ipv6=1 "
                                   "&& sysctl -w net.ipv6.conf.default.disable_ipv6=1")' \
    '            out = self.h.cmd(name, "sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1")  # MUTANT' \
    'test_ipv6_is_disabled_inside_every_host_and_not_on_the_box'

# 59: 🔴 THE CONTROLLER'\''S HARD-CODED PORTS ON THE WRONG FABRIC. exercises/p4runtime'\''s
# mycontroller.py dials 127.0.0.1:5005N and device_id N-1; on NDTwin those are not the truth and
# tools/p4_exercise/run_external_controller.py is what rewrites them (TICKET-P1D). Without the
# adapter the controller connects to nothing and every arm reads as "the exercise does not work
# on NDTwin".
add "59. the ndtwin arm runs the exercise controller without the adapter" \
    "$DRIVER" \
    '            argv = [CTRL_PY, os.path.join(REPO, "tools", "p4_exercise",
                                          "run_external_controller.py"), self.package, ctrl]' \
    '            argv = [CTRL_PY, os.path.join(self.exdir, ctrl)]  # MUTANT' \
    'test_the_ndtwin_arm_goes_through_the_adapter_live_p1_03_uses'

# 60: the controller'\''s liveness is not checked. "h1 cannot ping h2" is then true of the
# skeleton, of a controller that died at import and of a fabric that never came up alike.
add "60. a controller that exited is reported as having stayed up" \
    "$DRIVER" \
    '        alive = proc.poll() is None' \
    '        alive = True  # MUTANT' \
    'test_a_controller_that_died_fails_the_injection_check'

# 61: the set of switches the controller programmed stops being asserted, which is the same
# property live-p1/_common.sh'\''s controller_program_set carries on the twin'\''s side.
add "61. the p4runtime arm accepts any set of programmed switches" \
    "$DRIVER" \
    '            self._add("switches the controller programmed", "[1, 2]", str(loaded),
                      loaded == [1, 2], G_SRC,' \
    '            self._add("switches the controller programmed", "[1, 2]", str(loaded),
                      bool(loaded), G_SRC,  # MUTANT' \
    'test_a_controller_that_programmed_the_wrong_switches_is_red'

# 62: the flowcache arm stops noticing that it should never have got there. The skeleton is
# supposed to stop at p4c; reaching the data plane with it means the red arm is not red.
add "62. reaching flowcache's steps with the skeleton is no longer a finding" \
    "$DRIVER" \
    '        if self.which == "skeleton":
            self._add("RED ARM: the skeleton must not compile", "p4c refuses it",
                      "it compiled and the steps ran", False, G_BOTH,' \
    '        if False:  # MUTANT
            self._add("RED ARM: the skeleton must not compile", "p4c refuses it",
                      "it compiled and the steps ran", False, G_BOTH,' \
    'test_reaching_the_flowcache_steps_with_the_skeleton_is_itself_the_finding'

# 63: flowcache stops checking that a flow was ever cached, so the ping becomes evidence about
# whatever else happens to forward.
add "63. flowcache accepts a ping with no cached flow behind it" \
    "$DRIVER" \
    '                      "cached" if cached else "no '"'"'added table entry'"'"' line", cached, G_SRC,' \
    '                      "cached" if cached else "no '"'"'added table entry'"'"' line", True, G_SRC,  # MUTANT' \
    'test_a_flowcache_round_with_no_cached_flow_is_red'

# 64: 🔴 --telemetry IS SPELLED OUT WHEN IT WAS NOT ASKED FOR. `auto` looks harmless and is not:
# it overrules every package that declared telemetry.source and the round then reports the
# result as that package's.
add "64. the driver always passes --telemetry, overruling the package" \
    "$DRIVER" \
    '        if getattr(args, "telemetry", None):
            up_argv += ["--telemetry", args.telemetry]' \
    '        up_argv += ["--telemetry", getattr(args, "telemetry", None) or "auto"]  # MUTANT' \
    'test_no_flag_means_the_package_decides'

# 65: the telemetry knob is not put back. Nothing refuses over it -- `ndt down` leaves it and
# `ndt release` does not read it -- so the next bring-up silently inherits this round's source.
add "65. the telemetry knob is left where this round moved it" \
    "$DRIVER" \
    '    tok, twhy = knob_restore(telemetry_before, TELEMETRY_KNOB)' \
    '    tok, twhy = (True, "left alone")  # MUTANT' \
    'test_the_telemetry_knob_is_put_back_by_the_teardown'

# 66: the generic cell gets its own copy of the rule instead of live-p1/_common.sh's. Two
# instruments, and "the same cell over thirteen exercises" becomes a comparison between them.
add "66. the generic link-usage cell stops going through live-p1/_common.sh" \
    "$DRIVER" \
    '              "link_usage_round %s %s %s %s %s\n" % (_sh(str(ctrl_pid or "")),
                                                     _sh(LIVE_COMMON), _sh(package),' \
    '              "true %s %s %s %s %s\n" % (_sh(LIVE_COMMON), _sh(package),  # MUTANT' \
    'test_the_cell_is_live_p1_commons_own_function_and_not_a_second_copy'

# 67: a cell that could not run is reported as a cell that passed. rc 2 from link_usage_round
# is "no namespace / no sudo" -- a permission answer, and the greenest possible way to publish
# one.
# 🔴 THE ANCHOR MOVED WITH RULING 33, AND THE ANCHOR CHECK IS WHAT SAID SO. 67 and 93 shared
# the one-line `return ("not-run" if ...)`, which the four-answer map replaced; 93 was
# repointed with the ruling and this one was not, so `ANCHOR_CHECK=1` reported `0 matches`
# before any verdict was produced. It now names the last line of that map -- the one that
# still decides true/false -- which is the same mutation it always was.
add "67. any rc from the generic cell counts as a pass" \
    "$DRIVER" \
    '    return bool(rc == 0), out' \
    '    return True, out  # MUTANT' \
    'test_a_non_zero_rc_is_a_failed_cell_and_not_a_skip'

# 68: the generic cell is never run at all. Every exercise's own arms stay exactly as green as
# before, which is the point: this is the cell that is about NDTwin.
add "68. the round never runs the generic link-usage cell" \
    "$DRIVER" \
    '                ok, usage_out = link_usage_cell(pkg, "%s/%s" % (ex, which), usage_dir,
                                                dst=usage_dst, ctrl_pid=ctrl)' \
    '                ok, usage_out = True, "(MUTANT: not run)"' \
    'test_the_round_runs_it_after_the_steps_and_records_the_expectation'

# 69: a skeleton that COMPILED when it was supposed not to is reported as the designed refusal.
add "69. flowcache's compile arm is green whichever way the compile went" \
    "$DRIVER" \
    '            "p4c rc=%d" % rc, rc != 0, G_BOTH,' \
    '            "p4c rc=%d" % rc, True, G_BOTH,  # MUTANT' \
    'test_a_flowcache_skeleton_that_DOES_compile_is_the_finding'

# 70: every exercise's compile failure becomes "by design", so a broken tool chain is filed as
# a red arm on twelve exercises that have none.
add "70. any compile failure is treated as a designed red arm" \
    "$DRIVER" \
    '    red_stage = spec.get("red_arm") if which == "skeleton" else None' \
    '    red_stage = "compile"  # MUTANT' \
    'test_a_compile_failure_anywhere_else_is_still_exit_2'

# 71: --telemetry is accepted on the tutorials fabric, where nothing reads it.
add "71. --telemetry is accepted on the tutorials fabric" \
    "$DRIVER" \
    '    if args.telemetry and args.fabric != "ndtwin":' \
    '    if False:  # MUTANT' \
    'test_the_flag_is_refused_on_the_tutorials_fabric'

# 72: the table itself. An exercise in EXERCISES with no steps_ method compiles, brings a
# fabric up and then raises inside Steps.run -- exit 2, after the lab was claimed.
add "72. an exercise can sit in the table with no scripted steps" \
    "$DRIVER" \
    '    "load_balance": {
        "topo": "topology.json",' \
    '    "load_balance_typo": {
        "topo": "topology.json",' \
    'test_all_thirteen_exercises_are_in_the_table'

# 73-74: 🔴 exercises/p4runtime has NO solution/*.p4. Measured by reading the real tree on
# 2026-09-19 -- advanced_tunnel.p4 has no TODO in it, the exercise IS the controller, and both
# arms run the same pipeline. Either half of the flag that says so is a round that never starts,
# or a round that silently compiles the skeleton and calls it the solution.
add "73. the controller-variant exercises look for a solution/*.p4 that is not there" \
    "$DRIVER" \
    '    if which == "skeleton" or spec.get("variant") == "controller":' \
    '    if which == "skeleton":  # MUTANT' \
    'test_p4runtime_compiles_the_same_program_on_both_arms'

add "74. a missing solution/*.p4 silently falls back to the skeleton everywhere" \
    "$DRIVER" \
    '    if cands:
        return cands[0], base
    return None, base' \
    '    if cands:
        return cands[0], base
    return os.path.join(exdir, spec["prog"]), base  # MUTANT' \
    'test_an_exercise_with_no_solution_program_is_still_an_error_everywhere_else'

# 75-78: the generic cell needs a FLOW, and four ways to lose that.
add "75. the generic cell runs on the skeleton arm too" \
    "$DRIVER" \
    '    if which != "solution":
        return False, None, ("the skeleton arm is a fabric the exercise says should not "
                             "forward; there is no path for a program-independent cell to follow")' \
    '    if False:  # MUTANT
        return False, None, ""' \
    'test_the_cell_does_not_run_on_a_skeleton_arm'

# 🔴 THE REPLACEMENT KEEPS A BODY. `if False:` alone leaves the `if` with no suite, the mutant
# does not PARSE, and this gate scores that as a SURVIVOR -- correctly: a mutation that never
# reached the interpreter established nothing about the behaviour it was aimed at.
add "76. an exercise that forwards nothing is measured anyway" \
    "$DRIVER" \
    '    if want is False:
        return False, None, spec.get("link_usage_why") or "this exercise declares no path"' \
    '    if False:  # MUTANT
        pass' \
    'test_three_solutions_forward_nothing_and_are_named'

add "77. the destination override is ignored, so two exercises measure to a host they cannot reach" \
    "$DRIVER" \
    '    return True, (want if isinstance(want, str) else None), ""' \
    '    return True, None, ""  # MUTANT' \
    'test_the_two_unreachable_last_hosts_are_overridden'

add "78. the destination never reaches the shell helper" \
    "$DRIVER" \
    '                                                     _sh(dst or "")))' \
    '                                                     _sh("")))  # MUTANT' \
    'test_the_destination_reaches_the_shell_helper'

# 79: A6 half-done again -- the verdict asks which fabric it was, so `basic_tunnel`'s skeleton
# goes back to reading `PASS (1/1)` / exit 0 on tutorials and `RED ARM (1/1)` / exit 1 on NDTwin.
# ONE EXERCISE MUST NOT READ TWO WAYS ON TWO FABRICS (round-3 ruling 1).
add "79. the designed-refusal verdict is restricted to one fabric again" \
    "$DRIVER" \
    '    designed = DESIGNED_REFUSAL["hit"]' \
    '    designed = (args.fabric == "ndtwin" and DESIGNED_REFUSAL["hit"])  # MUTANT' \
    'test_the_tutorials_arm_reads_the_same_as_the_ndtwin_one'

# 80: the tutorials harness refusal stops setting the flag at all -- the same arm, reported as
# an ordinary pass because `program_switches` raising is what it is SUPPOSED to do here.
add "80. the tutorials harness refusal is not recorded as a designed one" \
    "$DRIVER" \
    '                designed_refusal_seen()
                return False' \
    '                return False  # MUTANT' \
    'test_the_tutorials_arm_reads_the_same_as_the_ndtwin_one'

# 81: the flag is module state and is never cleared, so round N reports round N-1's refusal --
# and `06_thirteen.sh` runs twenty-six rounds in one loop.
add "81. the designed-refusal flag leaks from one round into the next" \
    "$DRIVER" \
    '    DESIGNED_REFUSAL["hit"] = False

    if args.fabric == "ndtwin":' \
    '    if args.fabric == "ndtwin":  # MUTANT' \
    'test_the_flag_does_not_leak_from_one_round_into_the_next'

# 82: multicast measures from whatever ARP state the fabric happens to be in. h4's own ARP IS
# answered, so once it has run every other host holds h4's MAC and hX -> h4 becomes a plain
# unicast that h4's mac_forward entry delivers -- 0% on a fabric that has not changed.
add "82. multicast no longer empties the ARP caches before measuring" \
    "$DRIVER" \
    '        flushed = self.h.flush_arp()' \
    '        flushed = []  # MUTANT' \
    'test_the_arp_caches_are_emptied_before_and_between_the_passes'

# 83: the re-measure from cold caches goes away, so "h4 is unreachable" is once again only as
# true as the order the pairs happened to be walked in.
add "83. the cold-cache re-measure of hX -> h4 is dropped" \
    "$DRIVER" \
    '            reflushed = self.h.flush_arp()' \
    '            reflushed = []  # MUTANT' \
    'test_the_arp_caches_are_emptied_before_and_between_the_passes'

# 84: pingall walks dst-major, so h1 -> h4 is measured AFTER h4 -> h1 has taught h1 h4's MAC and
# the expectation inverts on a fabric that is behaving exactly as the exercise describes.
add "84. pingall walks dst-major, poisoning the h4 expectation" \
    "$DRIVER" \
    '        for src in self.names():
            for dst in self.names():' \
    '        for dst in self.names():          # MUTANT
            for src in self.names():' \
    'test_the_pingall_order_is_src_major'

# 85: the generic cell's expectation string goes back to naming a bound nobody applies. R4
# replaced "exactly 0 off the path" with a floor; a reader reconciling a green cell against
# `off-path == 0` concludes the off-path edges integrated to zero, which they did not.
add "85. the generic cell claims an off-path bound that is not the one applied" \
    "$DRIVER" \
    '                        "primary on-path > 0; minor rows printed, not asserted; "
                        "off-path under one sample'"'"'s worth (256 x MTU x 8 bit) or 2% of the "
                        "smallest PRIMARY on-path, whichever is larger",' \
    '                    "on-path > 0, off-path == 0",  # MUTANT' \
    'test_the_generic_cell_states_the_bound_it_actually_applies'

# 86: THE FLUSH MOVES TO AFTER THE WALK (TICKET-P3 §9 ruling 12c). Two flushes still happen, so
# a cell that COUNTS them is satisfied -- and the measurement is taken from whatever ARP state
# the fabric was already in, which is the state the expectation is not true in. This is the
# mutation round 3's cell could not see.
add "86. multicast flushes the ARP caches AFTER the pingall instead of before" \
    "$DRIVER" \
    '        flushed = self.h.flush_arp()
        say("$ ip neigh flush all, in each host namespace -> %s" % (", ".join(flushed) or "none"))
        self.steps.append(("ARP caches emptied before the measurement",
                           "ip neigh flush all (each host)", ", ".join(flushed) or "none"))
        pa = self._pingall()' \
    '        pa = self._pingall()  # MUTANT: the walk first
        flushed = self.h.flush_arp()
        say("$ ip neigh flush all, in each host namespace -> %s" % (", ".join(flushed) or "none"))
        self.steps.append(("ARP caches emptied before the measurement",
                           "ip neigh flush all (each host)", ", ".join(flushed) or "none"))' \
    'test_the_first_flush_happens_BEFORE_the_pingall'

# 87: THE SECOND FLUSH MOVES TO AFTER THE RE-MEASURE (TICKET-P3 §9 ruling 15⑤). Two flushes
# still happen and both still sit after the walk, so the arithmetic round 5 asserted is
# satisfied -- while the three hX -> h4 pairs are re-measured with h4's MAC still cached from
# the pairs above them, which is the one state in which their expectation is not true.
add "87. the cold-cache re-measure runs BEFORE its own flush" \
    "$DRIVER" \
    '            reflushed = self.h.flush_arp()
            say("$ ip neigh flush all again -> %s; re-measuring the three hX -> h4 pairs"
                % (", ".join(reflushed) or "none"))
            again = [(src, self.h.ping(src, self.h.ips["h4"], 5)) for src in group]' \
    '            again = [(src, self.h.ping(src, self.h.ips["h4"], 5)) for src in group]  # MUTANT
            reflushed = self.h.flush_arp()
            say("$ ip neigh flush all again -> %s; re-measuring the three hX -> h4 pairs"
                % (", ".join(reflushed) or "none"))' \
    'test_the_second_flush_happens_after_the_pingall'

# 88: THE FLUSH LANDS IN THE MIDDLE OF THE RE-MEASURE (TICKET-P3 §9 ruling 16①). One ping on
# warm caches, then the flush, then the other two -- so two flushes still happen, both still
# follow the walk, and the LAST ping still follows the LAST flush. Round 6's cell passed this
# exactly as written; it is the arm that cell's own comment claimed to block.
add "88. the second flush lands between the first and second re-measure ping" \
    "$DRIVER" \
    '            reflushed = self.h.flush_arp()
            say("$ ip neigh flush all again -> %s; re-measuring the three hX -> h4 pairs"
                % (", ".join(reflushed) or "none"))
            again = [(src, self.h.ping(src, self.h.ips["h4"], 5)) for src in group]' \
    '            again = [(group[0], self.h.ping(group[0], self.h.ips["h4"], 5))]  # MUTANT
            reflushed = self.h.flush_arp()
            say("$ ip neigh flush all again -> %s; re-measuring the three hX -> h4 pairs"
                % (", ".join(reflushed) or "none"))
            again += [(src, self.h.ping(src, self.h.ips["h4"], 5)) for src in group[1:]]' \
    'test_the_second_flush_happens_after_the_pingall'

# 89: THE LAST IP HEADER INSTEAD OF THE FIRST (§9 ruling 20②). h2's ICMP port-unreachable
# embeds the original datagram, so the block has an outer header (h2 -> h1, tos 0xc0) and an
# inner one (h1 -> h2, tos 0x1). Reading the last one makes the filter and the value disagree
# again -- which is how `UDP tos stays 0x1` came back `got ['0x1', '0xc0']` on the live run.
add "89. _tos_from reads the LAST IP header of a block, not the first" \
    "$DRIVER" \
    '        start = re.search(r"^[|\s]*###\[ IP \]###", block, re.M)
        if start is None:
            return None' \
    '        start = list(re.finditer(r"^[|\s]*###\[ IP", block, re.M))[-1:]  # MUTANT
        start = start[0] if start else None
        if start is None:
            return None' \
    'test_h2s_icmp_error_is_not_read_as_one_of_h1s_frames'

# 90: THE NESTING PREFIX IS NOT STRIPPED (§9 ruling 23①). scapy prints an IP option as a nested
# layer with `|` on every line; anchoring on `^\s*` reads the MRI count as 0 and the swids as
# [], which is what both mri arms reported while the transcript showed the option in full.
add "90. _field_values goes back to anchoring at line start" \
    "$DRIVER" \
    '        return re.findall(r"^[|\s]*%s\s*=\s*(\S+)\s*$" % re.escape(field), text, re.M)' \
    '        return re.findall(r"^\s*%s\s*=\s*(\S+)\s*$" % re.escape(field), text, re.M)  # MUTANT' \
    'test_the_mri_count_is_read_through_the_nesting_prefix'

# 91: flowcache measures loss without warming the cache (§9 ruling 28②). Its FIRST packet is
# punted to the controller, so a single ping measures the install latency as loss.
add "91. flowcache stops warming the cache before it measures loss" \
    "$DRIVER" \
    '            probe = self.h.ping("h1", self.ips["h2"], count=3)' \
    '            probe = None  # MUTANT' \
    'test_flowcache_warms_the_cache_before_it_measures_loss'

# 92: the cell no longer carries the controller pid, so the NOT RUN branch is unreachable from
# the driver again (§9 ruling 28①). 🔴 REPOINTED (§9 ruling 31①): the cell that used to catch
# this was `assertIn("ctrl_pid=ctrl", open(DRIVER_PATH).read())` -- a grep for this very line,
# which was green while `run_on_ndtwin.ctrl_pid` was an attribute nothing ever assigned. The
# cell that catches it now starts a real process and reads the pid the cell was handed.
add "92. the generic cell is called without the arm's controller pid" \
    "$DRIVER" \
    '                                                dst=usage_dst, ctrl_pid=ctrl)' \
    '                                                dst=usage_dst)  # MUTANT' \
    'test_the_cell_is_handed_the_pid_of_the_process_the_round_started'

# 93: NOT RUN stops being an answer of its own and folds back into true/false (§9 ruling 28①).
# The anchor moved with ruling 33, which turned the one-line return into the four-answer map;
# the mutation is the same one -- rc 3 falls through to `bool(rc == 0)`.
add "93. a NOT RUN generic cell is folded back into true/false" \
    "$DRIVER" \
    '    if rc == LINK_USAGE_NOT_RUN_RC:' \
    '    if False:  # MUTANT' \
    'test_a_not_run_generic_cell_is_never_a_pass'

# 96 (§9 ruling 33): the window refusal falls through to `bool(rc == 0)` again, so an NDTwin
# arm records "the caller would have had to wait 308 s" under the twin's own sentence -- the
# misattribution ruling 31③ removed from live-p1/05 and this file did not follow.
add "96. the over-long-window refusal is reported as a reading about the twin" \
    "$DRIVER" \
    '    if rc == LINK_USAGE_WINDOW_RC:' \
    '    if False:  # MUTANT' \
    'test_the_round_names_the_window_and_never_the_twin_sentence'

# 97 (§9 ruling 33): the two files stop agreeing on the protocol. rc 4 is _common.sh's, and a
# driver that spells it 5 maps nothing -- which is precisely the state ruling 33 found, one
# round after the shell side gained the code.
add "97. the driver's window rc drifts from the shell file's" \
    "$DRIVER" \
    'LINK_USAGE_WINDOW_RC = 4' \
    'LINK_USAGE_WINDOW_RC = 5  # MUTANT' \
    'test_the_two_refusal_codes_are_the_shell_files_own'

# 94: the arm's controller is stopped BEFORE the generic cell again -- the order the driver had
# until §9 ruling 31①, in which every G1 on p4runtime and flowcache measured a fabric whose
# controller had already exited. The mutation restores it in one line, at the top of the branch
# that runs the cell.
add "94. the controller is stopped before the generic cell measures" \
    "$DRIVER" \
    '                usage_dir = os.path.join(log_dir, "link_usage")' \
    '                usage_dir = os.path.join(log_dir, "link_usage"); steps_out.extend(session.stop_controller())  # MUTANT' \
    'test_the_controller_is_alive_while_the_cell_measures_and_stopped_after'

# 95: the channel loses its source -- Steps publishes no pid, so the cell is handed None and the
# liveness check has nothing to check again (§9 ruling 31①). 92 kills the sink; this kills the
# spring, which is the half that was missing at f87580cb.
add "95. _start_controller publishes no pid for the process it started" \
    "$DRIVER" \
    '        self.ctrl_pid = proc.pid' \
    '        self.ctrl_pid = None  # MUTANT' \
    'test_start_controller_publishes_the_pid_of_the_process_it_started'

# 98-104 (P4-D', 2026-09-24): the tutorials SOLUTION arms of flowcache and p4runtime ran
# <exdir>/solution/mycontroller.py in place, whose own '../../utils/' is relative to __file__
# and so names <tutorials>/exercises/utils -- and both died at `import p4runtime_lib.bmv2`
# (logs/orchestrator-0924/tutorials-18/{flowcache,p4runtime}_solution.log). The fix hands that
# arm, and only that arm, the exercise's own utils/ on PYTHONPATH.
# [Co-developed with claude code -- Adam]
#
# 98 IS THE FIX REVERTED: the arm goes back to running the controller with nothing on its path,
# which is the exact state the orchestrator's round measured. The killer RUNS the command the
# driver would have run, against a tree whose controller opens with the tutorials' own lines.
add "98. the tutorials solution arm runs its controller in place with no utils/ (the 09-24 fix reverted)" \
    "$DRIVER" \
    '        if self.fabric != "ndtwin" and os.path.dirname(ctrl):' \
    '        if False:  # MUTANT: the 2026-09-24 fix reverted' \
    'test_the_tutorials_solution_controller_imports_the_exercises_p4runtime_lib'

# 99-100: the fix leaks into the two arms the ticket says it must not change.
add "99. the skeleton arm is handed utils/ on PYTHONPATH too" \
    "$DRIVER" \
    '        if self.fabric != "ndtwin" and os.path.dirname(ctrl):' \
    '        if self.fabric != "ndtwin":  # MUTANT: every tutorials arm, skeleton included' \
    'test_the_skeleton_arm_is_handed_the_environment_it_always_had'

add "100. the ndtwin arm is handed utils/ on PYTHONPATH too" \
    "$DRIVER" \
    '        if self.fabric != "ndtwin" and os.path.dirname(ctrl):' \
    '        if os.path.dirname(ctrl):  # MUTANT: the adapter'"'"'s arm as well' \
    'test_the_ndtwin_arm_is_handed_the_environment_it_always_had'

# 101-102: the directory is the wrong one. 101 is off by one level -- <tutorials>/exercises/utils,
# the very path the solution's own line already fails on. 102 is the hard-coded tree instead of
# the exercise's: right on this laptop by coincidence, wrong for any tree that is not ~/tutorials.
add "101. the exercise's utils/ is derived one level short" \
    "$DRIVER" \
    '    return os.path.normpath(os.path.join(os.path.abspath(exdir), os.pardir, os.pardir, "utils"))' \
    '    return os.path.normpath(os.path.join(os.path.abspath(exdir), os.pardir, "utils"))  # MUTANT' \
    'test_the_tutorials_solution_controller_imports_the_exercises_p4runtime_lib'

add "102. the utils/ handed over is the hard-coded ~/tutorials one, not the exercise's" \
    "$DRIVER" \
    '    return os.path.normpath(os.path.join(os.path.abspath(exdir), os.pardir, os.pardir, "utils"))' \
    '    return UTILS  # MUTANT' \
    'test_the_tutorials_solution_controller_imports_the_exercises_p4runtime_lib'

add "103. a PYTHONPATH the driver inherited is discarded instead of kept behind utils/" \
    "$DRIVER" \
    '            inherited = [p for p in [env.get("PYTHONPATH")] if p]' \
    '            inherited = []  # MUTANT' \
    'test_a_pythonpath_the_driver_inherited_is_kept_behind_the_exercises_utils'

# 104: the round works and the report lies about how: C1 records a command that, pasted, dies of
# the import the round itself no longer does.
add "104. the report records the controller command without the PYTHONPATH it ran with" \
    "$DRIVER" \
    '            shown = "PYTHONPATH=%s %s" % (env["PYTHONPATH"], shown)' \
    '            pass  # MUTANT' \
    'test_the_command_the_report_records_reproduces_the_run'

# 105-106 (P4-D' round 2, judge's items 1-2). Both SURVIVED the round-1 suite (da0fa021's test
# file): its guards ran with no PYTHONPATH in the process at all, so an arm that LOST an
# inherited value had nothing to lose; and nothing read the printed `$ ...` start line.
# 105 takes the caller's PYTHONPATH out for EVERY arm before the solution-only branch -- the
# solution arm still gets utils/ + inherited, so only the two guarded arms change.
add "105. the caller's PYTHONPATH is taken away from the skeleton and ndtwin arms" \
    "$DRIVER" \
    '        if self.fabric != "ndtwin" and os.path.dirname(ctrl):
            inherited = [p for p in [env.get("PYTHONPATH")] if p]' \
    '        inherited = [p for p in [env.pop("PYTHONPATH", None)] if p]  # MUTANT: for every arm
        if self.fabric != "ndtwin" and os.path.dirname(ctrl):' \
    'test_the_skeleton_arm_is_handed_the_environment_it_always_had'

add "106. the printed start line drops the PYTHONPATH the controller runs with" \
    "$DRIVER" \
    '        say("$ %s   (> %s)" % (shown, path))' \
    '        say("$ %s   (> %s)" % (" ".join(argv), path))  # MUTANT' \
    'test_the_printed_start_line_carries_the_prefix_on_the_solution_arm_only'

# 107-125 (P4-D'', TICKET-P4-roles §7 ruling 7): the ecn solution arm's mark check had 2-4
# probes to look at. [Co-developed with claude code -- Adam]
# Every one of these is a way back to an instrument that cannot tell a marking data plane from
# a silent one -- or to one that cannot fail at all. 107-111 are the train (its count, and a
# sender that is killed before its tail); 112-115 the background that has to outlast it;
# 116-118 the two arms' claims, exactly as strict as before with ten times the probes; 119 the
# injection row the ruling keeps; 120-121 mri/qos's shared constants; 122-125 the delivered
# count, which is disclosed as a step and must stay out of the verdict table.
add "107. ecn goes back to the shared six-probe train" \
    "$DRIVER" \
    '                    str(ECN_PROBES)]' \
    '                    str(SEND_SECONDS)]  # MUTANT: the shared six' \
    'test_the_ecn_sender_is_asked_for_enough_probes'

add "108. the ecn train is cut under the 1% floor the 09-24 rate sets" \
    "$DRIVER" \
    'ECN_PROBES = 60' \
    'ECN_PROBES = 30  # MUTANT: half the README'"'"'s 60 -- 0.9^30 = 4% false fails' \
    'test_the_ecn_sender_is_asked_for_enough_probes'

add "109. the ecn sender is handed the shared SEND_TIMEOUT, which kills the train's tail" \
    "$DRIVER" \
    '            sout = self._send_once("h1", scmd, label="E2  h1 send.py (one packet per second)",
                                   timeout=ECN_SEND_TIMEOUT)' \
    '            sout = self._send_once("h1", scmd, label="E2  h1 send.py (one packet per second)")  # MUTANT' \
    'test_the_ecn_sender_is_not_killed_before_its_last_probe'

add "110. _send_once ignores the timeout it is handed" \
    "$DRIVER" \
    '                                      timeout=SEND_TIMEOUT if timeout is None else timeout)' \
    '                                      timeout=SEND_TIMEOUT)  # MUTANT: the parameter is decoration' \
    'test_the_ecn_sender_is_not_killed_before_its_last_probe'

add "111. the ecn sender's timeout leaves no room for start-up or sendp()" \
    "$DRIVER" \
    'ECN_SEND_TIMEOUT = ECN_PROBES + 20' \
    'ECN_SEND_TIMEOUT = ECN_PROBES  # MUTANT: 60 probes are ~62 s at the 09-24 spacing' \
    'test_the_ecn_sender_is_not_killed_before_its_last_probe'

add "112. the ecn background falls back to the shared 20 s" \
    "$DRIVER" \
    '            "h11", "h22", self.ips["h22"], rate="1M",
            seconds=ecn_background_seconds(self.args.recv_warmup, self.args.drain_wait))' \
    '            "h11", "h22", self.ips["h22"], rate="1M")  # MUTANT: BG_SECONDS' \
    'test_the_background_outlasts_the_whole_probe_train'

# 113 and 115 are green at the shipped 3 s / 3 s waits (the 5 s margin absorbs either one) and
# red only at the inflated --recv-warmup 12 / --drain-wait 9 subtest -- which is why it exists.
add "113. the background covers the sender but not the sniffer's drain" \
    "$DRIVER" \
    '    return int(math.ceil(recv_warmup + ECN_SEND_TIMEOUT + drain_wait)) + ECN_BG_MARGIN' \
    '    return int(math.ceil(recv_warmup + ECN_SEND_TIMEOUT)) + ECN_BG_MARGIN  # MUTANT: no drain' \
    'test_the_background_outlasts_the_whole_probe_train'

add "114. the background ends exactly when the sniffer can, with no margin" \
    "$DRIVER" \
    'ECN_BG_MARGIN = 5' \
    'ECN_BG_MARGIN = 0  # MUTANT' \
    'test_the_background_outlasts_the_whole_probe_train'

add "115. the background forgets the receiver warm-up it starts before" \
    "$DRIVER" \
    '    return int(math.ceil(recv_warmup + ECN_SEND_TIMEOUT + drain_wait)) + ECN_BG_MARGIN' \
    '    return int(math.ceil(ECN_SEND_TIMEOUT + drain_wait)) + ECN_BG_MARGIN  # MUTANT: no warm-up' \
    'test_the_background_outlasts_the_whole_probe_train'

add "116. the ecn RED ARM reads only the old six-probe prefix of the train" \
    "$DRIVER" \
    '                      bool(tos) and set(tos) == {"0x1"}, G_BOTH,
                      "README step 1.8: '"'"'the ipv4.tos field is always 1'"'"'; ecn.p4:132-138 "' \
    '                      bool(tos) and set(tos[:6]) == {"0x1"}, G_BOTH,  # MUTANT
                      "README step 1.8: '"'"'the ipv4.tos field is always 1'"'"'; ecn.p4:132-138 "' \
    'test_one_mark_anywhere_in_the_long_train_reddens_the_skeleton'

add "117. the ecn RED ARM passes a run in which nothing reached h2" \
    "$DRIVER" \
    '                      bool(tos) and set(tos) == {"0x1"}, G_BOTH,
                      "README step 1.8: '"'"'the ipv4.tos field is always 1'"'"'; ecn.p4:132-138 "' \
    '                      set(tos) <= {"0x1"}, G_BOTH,  # MUTANT: an empty set is all-0x1 too
                      "README step 1.8: '"'"'the ipv4.tos field is always 1'"'"'; ecn.p4:132-138 "' \
    'test_no_packet_at_all_fails_the_injection_check_rather_than_passing_vacuously'

add "118. the ecn solution takes any tos that is not 0x1 as the congestion mark" \
    "$DRIVER" \
    '                      str(sorted(set(tos))), "0x3" in tos, G_BOTH,' \
    '                      str(sorted(set(tos))), bool(set(tos) - {"0x1"}), G_BOTH,  # MUTANT' \
    'test_only_0x3_counts_as_the_congestion_mark'

add "119. the ecn injection row is dropped" \
    "$DRIVER" \
    '        self._add("injection: packets reached h2", ">=1", "%d" % len(pkts),
                  len(pkts) >= 1, G_SRC,
                  "send.py:35-41 sends one UDP/4321 datagram per second; receive.py:34 filters "' \
    '        if False: self._add("injection: packets reached h2", ">=1", "%d" % len(pkts),  # MUTANT
                  len(pkts) >= 1, G_SRC,
                  "send.py:35-41 sends one UDP/4321 datagram per second; receive.py:34 filters "' \
    'test_the_verdict_rows_are_the_ones_the_ruling_keeps'

add "120. the shared SEND_SECONDS is raised instead of ecn getting its own" \
    "$DRIVER" \
    'SEND_SECONDS = 6      # s of the mri/qos senders' \
    'SEND_SECONDS = 60      # MUTANT: every sender gets the ecn train; s of the mri/qos senders' \
    'test_mri_and_qos_keep_the_shared_sender_and_background'

add "121. mri borrows the ecn probe train" \
    "$DRIVER" \
    '                    str(SEND_SECONDS)]' \
    '                    str(ECN_PROBES)]  # MUTANT' \
    'test_mri_and_qos_keep_the_shared_sender_and_background'

add "122. the delivered-count disclosure is never filed" \
    "$DRIVER" \
    '        self.steps.append(("E4  probes that reached h2 (disclosure, not a verdict)",' \
    '        if False: self.steps.append(("E4  probes that reached h2 (disclosure, not a verdict)",  # MUTANT' \
    'test_the_arm_discloses_how_many_probes_reached_h2_and_in_what_order'

add "123. the disclosure counts against the shared six, not what the sender was asked for" \
    "$DRIVER" \
    '                % (len(pkts), ECN_PROBES, self.args.drain_wait, " ".join(tos) or "(none)"))' \
    '                % (len(pkts), SEND_SECONDS, self.args.drain_wait, " ".join(tos) or "(none)"))  # MUTANT' \
    'test_the_arm_discloses_how_many_probes_reached_h2_and_in_what_order'

add "124. the disclosure prints the tos SET, so the arrival order (the 1 -> 3) is lost" \
    "$DRIVER" \
    '                % (len(pkts), ECN_PROBES, self.args.drain_wait, " ".join(tos) or "(none)"))' \
    '                % (len(pkts), ECN_PROBES, self.args.drain_wait, " ".join(sorted(set(tos))) or "(none)"))  # MUTANT' \
    'test_the_arm_discloses_how_many_probes_reached_h2_and_in_what_order'

add "125. the disclosure is also filed as a verdict row that cannot fail" \
    "$DRIVER" \
    '        say("   " + seen.replace("\n", "\n   "))' \
    '        say("   " + seen.replace("\n", "\n   "))
        self._add("probes that reached h2 (disclosure)", "-", "%d" % len(pkts), True, G_SRC)  # MUTANT' \
    'test_the_verdict_rows_are_the_ones_the_ruling_keeps'

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
        n=$(anchor_count "${MUT_SRC[$i]}" "${MUT_ANCHOR[$i]}") || refuse_anchor_count
        if [[ "$n" -eq 1 ]]; then
            printf '  ok    %s  (%s)\n' "$n" "${MUT_LABEL[$i]}"
        else
            printf '  🔴 %s matches  (%s)\n' "$n" "${MUT_LABEL[$i]}"; broken=$((broken + 1))
        fi
    done
    n=$(anchor_count "$CTRL_SRC" "$CTRL_ANCHOR") || refuse_anchor_count
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
    # 🔴 A SUITE THAT NEVER RAN IS NOT A SUITE WITH NO RED CELLS (§9 ruling 15①). unittest
    # always prints `Ran N tests`; an interpreter that died prints no such line, and rc != 0
    # with nothing parsable came back as the empty string -- which the caller reads as "nothing
    # went red". At the baseline that printed `ok baseline green` over a suite that never
    # executed; for a mutation it would have reported a survivor.
    if ! /usr/bin/grep -qE '^Ran [0-9]+ tests?' <<<"$out"; then
        echo "NO-SUITE"; return
    fi
    if [[ $rc -eq 0 ]]; then echo ""; return; fi
    sed -n 's/^\(FAIL\|ERROR\): \([A-Za-z_][A-Za-z0-9_]*\) .*/\2/p' <<<"$out" | sort -u | tr '\n' ' '
}

# mutate <label> <src> <anchor> <replacement> <expected-test>
#
# `src` is the repo file the anchor is counted in -- which is what
# tests/shell/check_gate_anchors.py reads -- and the file that is WRITTEN is the copy.
mutate() {
    local label="$1" src="$2" anchor="$3" repl="$4" expected="$5"
    local n; n=$(anchor_count "$src" "$anchor") || refuse_anchor_count
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
    if [[ "$failed" == "NO-SUITE" ]]; then
        refuse_no_suite "while measuring mutation: $label"
    fi
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
if [[ "$BASE_RED" == "NO-SUITE" ]]; then
    DRIVE_EXERCISE_UNDER_TEST="$DRIVER" "$PYTHON" -m unittest discover -s "$TESTS" -t "$TESTS" 2>&1 \
        | tail -10 | sed 's/^/     /'
    refuse_no_suite "at the baseline, before any mutation"
fi
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
n=$(anchor_count "$CTRL_SRC" "$CTRL_ANCHOR") || refuse_anchor_count
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
        [[ "$ctrl_red" == "NO-SUITE" ]] && refuse_no_suite "at the negative control"
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
[[ "$after_red" == "NO-SUITE" ]] && refuse_no_suite "on the closing re-check against the real file"
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
# all fifty-one have been red for at least one mutation here, which is the claim "no test in
# this suite is a decoration" and is the only form of it worth making. Mutations 31-42 exist
# for exactly that: each was added because some cell had never been seen to fail, and the
# P2-C SUMMARY carries the cell-by-cell table this run produces. Mutation 43 is the fifty-
# first cell, added with it by P2-E.
printf '\nevery cell in the suite has been red for at least one mutation above; the `also red:`\n'
printf 'lines are what that claim is built from. (The 09-08 fixture comparison IS reddened --\n'
printf 'by mutation 1 -- and this footer used to say it was not.)\n'

printf '\n%s mutations, %s survived\n' "$MUTATIONS" "$SURVIVORS"
[[ "$SURVIVORS" -eq 0 ]]
