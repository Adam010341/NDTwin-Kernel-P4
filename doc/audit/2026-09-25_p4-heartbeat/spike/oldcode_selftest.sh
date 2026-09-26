#!/usr/bin/env bash
#
# oldcode_selftest.sh -- can the spike's --self-test tell each fix from the code it replaced?
#
# [Co-developed with claude code -- Adam]
#
# Judge R4-4 (round-4 verdict): the round-4 evidence of discrimination came from a tool that lived
# only in a session scratchpad; the logs kept its effect, not its method. This is that tool, in the
# repo, extended to the round-5 fixes and to the round-6 checks (findings 1, 2 and 5 of the round-5
# verdict; R5-2 is a MUTANT, not a past form -- the code it guards never had an older shape).
# Round 7 adds R6-1 / R6-2 (the round-6 verdict's two fidelity notes: the self-test's own fakes put
# back to their round-6 form) and L1 / L2 -- the teardown of the FIRST LIVE RUN (09-26 10:30): no
# re-claim without measuring= before `ndt down`, and a release whatever `ndt down` answered -- with
# rows that put back one piece of the round-7 fix each (the ones marked MUTANT guard new code).
# Round 7b adds R7-1 / R7-2 (the round-7 verdict's findings: the CLAIM_MINUTES default below the
# sources, and the census building an arm after a refused down) and mutants for notes 3 and 4.
#
# For each REVERT below: a copy of S_heartbeat_spike.sh and a copy of hb_watch.py are written
# BESIDE the real ones (same directory, so SPIKE_DIR / LIVE_P1 / REPO resolve exactly as for the
# real script; the spike copy's WATCH points at the hb_watch copy), with that one fix put back to
# its old form -- every edit of every requested revert is asserted to apply exactly as many times
# as it is written for BEFORE anything runs, and the diff is printed. Then the COPY's own
# --self-test runs: its `declare -f` drivers carry the copy's functions, so the new checks run
# against the old code. A revert passes only if
#   * the self-test exits non-zero, and
#   * its red lines are exactly the ones written for that fix: every expected line red exactly
#     once, no other line red, and each expected line carries the reason given for it.
# The CONTROL (the same copying, no revert) must exit 0 with no red line: the copying itself
# changes nothing a check can see.
#
#   bash doc/audit/2026-09-25_p4-heartbeat/spike/oldcode_selftest.sh           # every revert
#   bash doc/audit/2026-09-25_p4-heartbeat/spike/oldcode_selftest.sh R4-2 r3   # just these
#   bash doc/audit/2026-09-25_p4-heartbeat/spike/oldcode_selftest.sh --list
#   bash doc/audit/2026-09-25_p4-heartbeat/spike/oldcode_selftest.sh --self-check [case...]
#
# --self-check -- THE TOOL'S OWN RED (finding 3, round-5 verdict: its verdict code had never been
# seen to fire). It hands the same verdict code deliberately wrong expectations, each against a real
# copy and a real self-test run, and demands the answer each must give:
#   wrong-reason     a red line expected with a reason it does not carry     UNEXPECTED, rc 1
#   extra-line       an expected red line the self-test does not have        UNEXPECTED, rc 1
#   unnamed-red      a red line no expectation names                         UNEXPECTED, rc 1
#   reddens-nothing  an edit no check can see (the self-test exits 0)        UNEXPECTED, rc 1
#   dirty-control    a control that is not clean                             UNEXPECTED, rc 1
#   anchor-absent    an edit whose text the spike does not have              rc 2, nothing run
#   anchor-count     an edit that applies a different number of times        rc 2, nothing run
#   watch-line       a spike whose WATCH line cannot be repointed            rc 2, nothing run
#   real-row         its own control: the real R4-3 row as the table has it  DISCRIMINATES, rc 0
#   copies-ignored   git ignores the copies' names (finding 4: a SIGKILLed run leaves them in this
#                    tracked directory; spike/.gitignore keeps them out of a commit)
# Each case must answer with its rc AND its own PROBLEM line -- UNEXPECTED for some other reason
# is not the path under test. Exit 0: every case answered as it must; 1 otherwise; 2 usage.
#
# Touches no lab: what runs is the spike's --self-test, with SELFTEST_PROBE_SUDO and FAULTS_TC
# removed from its environment (the opt-in sudo probe stays off). The copies are removed on exit.
# Exit 0: every requested revert discriminates (and the control is clean); 1 otherwise; 2 usage,
# or an edit that does not apply (the tool no longer matches the spike -- not a pass; nothing runs).
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="oldcode-$$"
trap 'rm -f "$D"/."$TAG"-*' EXIT INT TERM
/usr/bin/python3 -I - "$D" "$TAG" "$@" <<'PY'
import contextlib
import difflib
import io
import os
import re
import subprocess
import sys

D, TAG, ARGS = sys.argv[1], sys.argv[2], sys.argv[3:]
SPIKE, WATCH = os.path.join(D, "S_heartbeat_spike.sh"), os.path.join(D, "hb_watch.py")

# name -> (what it puts back, [(file, new text, old text, count)], [(red-line text, reason text)])
# The red-line text is matched inside a line that carries the red mark; the reason must be in
# that same line. An empty reason asks for nothing beyond the line itself.
REVERTS = {
    "control": ("nothing -- the copying alone", [], []),
    "r3": ("round 4's two set -e fixes (judge R3-1: bare watch_hit; the round-4 audit: bare return)", [
        ("spike", '    [[ "$v" == OK* ]] || return 0\n', '    [[ "$v" == OK* ]] || return\n', 1),
        ("spike", 'watch_hit "$dir" "$stopf" || true; return 0; fi', 'watch_hit "$dir" "$stopf"; return 0; fi', 2),
    ], [
        ("a clean window under set -e: rc 1", ""),
        ("a detection part that fails its first check ended the run under set -e: rc 1", ""),
        # added in round 5: the census arm's clean window is the same bare watch_hit, at its call site
        ("a census arm with the new daemon's report: died", ""),
        # added in round 7: a `loss 100%` residue (firstlossy) ends detect at that same first check
        ("a residue shaped loss 100%: rc 1", "6/8 directions heard"),
        # added in round 7b: the round-7 verdict's scenarios go red under this old form too
        ("a census of two arms whose downs go through: rc 1", "the census died"),
        ("census, an arm's 'ndt down' refused (measured arm): rc 1", "the census died"),
    ]),
    "R4-1": ("the whole R4-1 fix: census's old session block, wait_session's old call, hb_watch's old `session`", [
        ("watch", '        print(session_of(load(argv[2]), int(argv[3])))\n',
                  '        print(load(argv[2]).get("session") or "")\n', 1),
        ("spike", 's="$(/usr/bin/python3 -I "$WATCH" session "$1" "$3" 2>/dev/null)" || s=""',
                  's="$(/usr/bin/python3 -I "$WATCH" session "$1" 2>/dev/null)" || s=""', 1),
        ("spike", '''        # The daemon THIS start started (judge R4-1): its pid from start's own answer, and the
        # session only from a running report of that pid. "already running" names no pid here.
        hb_pid="$(/usr/bin/python3 -I "$WATCH" started-pid "$dir/11_hb_start.txt" 2>/dev/null)" || hb_pid=""
        session=""
        if [[ -n "$hb_pid" ]]; then
            session="$(wait_session "$HB_REPORT" 20 "$hb_pid")" || session=""
        fi
        if [[ -z "$session" ]]; then
            if [[ -n "$hb_pid" ]]; then
                printf '%s\\t%s\\tyes\\tno session in 5 s\\t-\\n' "$ex" "$which" >> "$RUN/40_census.tsv"
                fail "census $ex/$which: the heartbeat started (pid $hb_pid) but no running report of that pid carries a session after 5 s"
            else
                # Nothing was waited for on this path (finding 5, round-5 verdict): the row says what happened.
                printf '%s\\t%s\\tyes\\tstart named no pid\\t-\\n' "$ex" "$which" >> "$RUN/40_census.tsv"
                fail "census $ex/$which: 'heartbeat start' answered 0 without saying it started a daemon -- see 11_hb_start.txt"
            fi
''', '''        if ! session="$(wait_session "$HB_REPORT" 20)"; then
            printf '%s\\t%s\\tyes\\tno session in 5 s\\t-\\n' "$ex" "$which" >> "$RUN/40_census.tsv"
            fail "census $ex/$which: the heartbeat started but its report carries no session after 5 s"
''', 1),
    ], [
        ("the previous arm's final 'stopped' report was taken for the new session", "a1a1a1a1a1a1a1a1"),
        ("a 'stopped' report of the pid start named was taken for a session", "b2b2b2b2b2b2b2b2"),
        ("a 'running' report of another pid was taken for the new session", "c3c3c3c3c3c3c3c3"),
        ("an arm whose report is still the previous arm's 'stopped' one", "sniff h1 a1a1a1a1a1a1a1a1"),
        ("an arm whose start answered 'already running'", "sniff h1 d4d4d4d4d4d4d4d4"),
    ]),
    "R4-1/status": ("half of R4-1: session_of without its `status == running` clause", [
        ("watch", '    if doc.get("status") != "running":\n        return ""\n', '', 1),
    ], [
        ("session: a stopped report is none, even of that pid", "False"),
        ("a 'stopped' report of the pid start named was taken for a session", "b2b2b2b2b2b2b2b2"),
    ]),
    "R4-1/pid": ("the other half of R4-1: session_of without its pid clause", [
        ("watch", '    if doc.get("pid") != pid:\n        return ""\n', '', 1),
    ], [
        ("session: a running report of another pid is none", "False"),
        ("a 'running' report of another pid was taken for the new session", "c3c3c3c3c3c3c3c3"),
    ]),
    "R4-2": ("R4-2: `cut_link || break` -- a half-done cut left to the EXIT trap", [
        ("spike", 'cut_link || { restore_link || fail "cycle $i: could not remove the netem a half-done cut left on $CUT_A"; break; }',
                  'cut_link || break', 1),
    ], [
        ("a half-done cut: rc 0", "teardown said: cannot locate the netem"),
        # added in round 6: the same cut with the first end's `del` refused too -- left to the EXIT
        # trap, the netem is tried again after `ndt down` removed its veth
        ("a half-done cut whose restore is refused too: rc 0", "spike_finish tried the revert again"),
    ]),
    "R4-3": ("R4-3: the census table through a bare `column | sed` under pipefail", [
        ("spike", '    show_census "$RUN/40_census.tsv"\n',
                  r'''    column -t -s $'\t' "$RUN/40_census.tsv" | sed 's/^/   /'
''', 1),
    ], [
        ("the census table without 'column' ended the run: rc 127", "column: command not found"),
    ]),
    "R4-3/d-i": ("judge (d)(i): hb_watch all-heard / others-up with a bare load()", [
        ("watch", '''        try:
            print(all_heard(load(argv[2]), float(argv[3])))
        except (OSError, ValueError, KeyError) as exc:
            print(f"BAD the report could not be read: {exc!r}")
''', '''        print(all_heard(load(argv[2]), float(argv[3])))
''', 1),
        ("watch", '''        try:
            print(others_up(load(argv[2]), parse_dirs(argv[3]), time.monotonic(), float(argv[4])))
        except (OSError, ValueError, KeyError) as exc:
            print(f"BAD the report could not be read: {exc!r}")
''', '''        print(others_up(load(argv[2]), parse_dirs(argv[3]), time.monotonic(), float(argv[4])))
''', 1),
    ], [
        ("all-heard on a report that cannot be read: BAD, rc 0", "raised FileNotFoundError"),
        ("others-up on a report that cannot be read: BAD, rc 0", "raised FileNotFoundError"),
    ]),
    # Every detect scenario that gets past the first check reads QDISC_TOOL, so all of them go red
    # when the driver lacks it -- by construction, and for that one reason.
    "R4-5": ("R4-5: the detect driver without QDISC_TOOL", [
        ("spike", '''        printf 'QDISC_TOOL=%q\\n' "$st_tmp/fake_qdisc_tool"\n''', '', 1),
    ], [
        ("a detection cycle that goes as designed: rc 1", "QDISC_TOOL: unbound variable"),
        ("a half-done cut: rc 1", "QDISC_TOOL: unbound variable"),
        # added in round 6
        ("a half-done cut whose restore is refused too: rc 1", "QDISC_TOOL: unbound variable"),
        ("a cut refused on its first end: rc 1", "QDISC_TOOL: unbound variable"),
        ("a first end that already carries a netem: rc 1", "QDISC_TOOL: unbound variable"),
    ]),
    "R5-1": ("round-5 finding 1: `restore_link || true` -- a half-done cut whose restore fails", [
        ("spike", 'restore_link || fail "cycle $i: could not remove the netem a half-done cut left on $CUT_A"',
                  'restore_link || true', 1),
    ], [
        # revert_link_loss has emptied INJECTED_IFACES: nothing else will ever name that end
        ("a half-done cut whose restore is refused too: rc 0",
         "failures recorded: [tc refused to add netem on s3-eth1 (root); detection (report level"),
    ]),
    # NOT a past form: the code this guards never had an older shape. The plausible wrong one --
    # book each end in INJECTED_IFACES before tc has accepted it -- makes every refused cut restore
    # an end it never touched: a misleading second failure, or a netem that is not this run's deleted.
    "R5-2": ("round-5 finding 2 (a MUTANT): cut_link books each end before tc has accepted it", [
        ("spike", '        INJECTED_IFACES+=("$dev")\n    done\n', '    done\n', 1),
        ("spike", '    for dev in "$CUT_A" "$CUT_B"; do\n        where="$(netem_attach_point "$dev")" || true\n',
                  '    for dev in "$CUT_A" "$CUT_B"; do\n        INJECTED_IFACES+=("$dev")\n'
                  '        where="$(netem_attach_point "$dev")" || true\n', 1),
    ], [
        ("a cut refused on its first end: rc 0", "could not remove the netem a half-done cut left on s1-eth3"),
        ("a first end that already carries a netem: rc 0", "tc qdisc del dev s1-eth3 root"),
        # by construction: in both half-done cuts the refused second end is "restored" as well
        ("a half-done cut: rc 0", "cannot locate the netem"),
        ("a half-done cut whose restore is refused too: rc 0", "faults.sh said: cannot locate the netem to remove"),
    ]),
    "R5-5": ("round-5 finding 5: the census row for a start that named no pid reads 'no session in 5 s'", [
        ("spike", r"printf '%s\t%s\tyes\tstart named no pid\t-\n'", r"printf '%s\t%s\tyes\tno session in 5 s\t-\n'", 1),
    ], [
        ("an arm whose start answered 'already running'", "row: basic|solution|yes|no session in 5 s|-"),
    ]),
    # Round 6's verdict, findings 1 and 2 (notes): the self-test's own fakes put back to their round-6
    # form -- rows about the TEST's fidelity, as R4-5 is.
    "R6-1": ("round-6 note 1: the fake qdisc_tool's `diff` answers 'identical' whatever the fake tc holds", [
        ("spike", '''    diff) if [[ "$(tree)" == "$(cat "$2")" ]]; then echo "qdisc state unchanged"
          else diff "$2" <(tree); echo "QDISC STATE CHANGED since the snapshot" >&2; exit 1; fi ;;
''', '''    diff) echo "qdisc state unchanged" ;;
''', 1),
    ], [
        # the fourth failure a live run lists (the netem left on s1-eth3 is in the qdisc diff) is missing
        ("a half-done cut whose restore is refused too: rc 0", "not every cycle was detected], calls"),
    ]),
    "R6-2": ("round-6 note 2: firstunsafe's residue back to `loss 100%`", [
        ("spike", '''    st_detect firstunsafe healthy "netem.$CUT_A=delay 1ms"''',
                  '''    st_detect firstunsafe healthy "netem.$CUT_A=loss 100%"''', 1),
    ], [
        # it never reaches cut_link: the heartbeat is not heard across it, so the first check ends detect
        ("a first end that already carries a netem: rc 0", "6/8 directions heard"),
    ]),
    "R6-2/watch": ("half of round-6 note 2: the fake hb_watch never reads the fake tc (a lossy netem is heard)", [
        ("spike", '''lossy = bool(state) and any("loss 100%" in open(p).read() for p in glob.glob(os.path.join(state, "netem.*")))''',
                  '''lossy = False''', 1),
    ], [
        ("a residue shaped loss 100%: rc 0", "no safe netem attach point on s1-eth3"),
    ]),
    # L = the first LIVE run of segment S (09-26 10:30, runs/2026-09-26T023021Z_S_heartbeat/): L1 its
    # claim kept declaring measuring=, so both `ndt down`s were refused rc 5; L2 finish() released
    # the lab anyway. L1 and L2 are that run's code (past forms); the rows with a `/` put back one
    # piece of the round-7 fix (L2/verdict, L2/hygiene, L2/knob and L2/return are MUTANTS: the code
    # they guard is new in round 7). The checks are scenarios (a)-(e) of the self-test's teardown block.
    "L1": ("the first live run's teardown: no re-claim without measuring= before either `ndt down`", [
        ("spike", '''    retract_measuring "$RUN/90_down.reclaim.txt"
''', '', 1),
        ("spike", '''    retract_measuring "${1%.txt}.reclaim.txt" || true
''', '', 1),
    ], [
        ("a run that declared measuring= (the 09-26 live run's shape)",
         "down [NDT_MEASURING in env];down [NDT_MEASURING in env];claim;status"),
        ("a declared run whose detection part stopped at its first check",
         "up [NDT_MEASURING in env];down [NDT_MEASURING in env];claim;status"),
        ("a knob found at 128 that 'ndt up' moved to 4", "NOT RELEASED -- THE LAB STAYS CLAIMED"),
        ("a knob that could not be put back after a re-claim", "NOT RELEASED -- THE LAB STAYS CLAIMED"),
        # added in round 7b: the round-7 verdict's scenarios go red under this old form too
        ("a teardown whose 'ndt down' did not verify clean (rc 1)", "the teardown's 'ndt down' exited 5"),
        ("a claim that lapsed mid-run", "up [NDT_MEASURING in env];down [NDT_MEASURING in env];down [NDT_MEASURING in env];release"),
    ]),
    "L1/detect": ("half of L1: no re-claim before nd_down (detect's and census's downs)", [
        ("spike", '''    retract_measuring "${1%.txt}.reclaim.txt" || true
''', '', 1),
    ], [
        ("a run that declared measuring= (the 09-26 live run's shape)", "'ndt down' after the detection part exited 5"),
        ("a knob found at 128 that 'ndt up' moved to 4", "'ndt down' after the detection part exited 5"),
        ("a knob that could not be put back after a re-claim", "'ndt down' after the detection part exited 5"),
        # added in round 7b: the round-7 verdict's scenarios go red under this old form too
        ("a claim that lapsed mid-run", "up [NDT_MEASURING in env];down [NDT_MEASURING in env];claim;down"),
    ]),
    "L1/teardown": ("the other half of L1: no re-claim in spike_finish, before finish's down", [
        ("spike", '''    retract_measuring "$RUN/90_down.reclaim.txt"
''', '', 1),
    ], [
        ("a declared run whose detection part stopped at its first check", "NOT RELEASED -- THE LAB STAYS CLAIMED"),
    ]),
    "L2": ("the first live run's spike_ndt: `release` is the real ndt's, whatever the down answered", [
        ("spike", '''spike_ndt() {
    local rc
    if [[ "${1:-}" == release ]]; then
        # `return $?`, NEVER a bare `return`: this runs inside the EXIT trap, and there a bare
        # `return` answers the status of the last command BEFORE the trap (bash's `return`
        # builtin) -- scenario (d) of the self-test caught a refused release answering 0 that way.
        spike_release
        return $?
    fi
    "$REAL_NDT" "$@" && rc=0 || rc=$?
    if [[ "${1:-}" == down ]]; then
        TEARDOWN_DOWN_RC="$rc"
        if (( rc != 0 && rc != 3 )); then
            # The last line is what gets read; a lab left claimed with a fabric maybe up is the one
            # thing on it somebody has to act on, so it goes first whatever failed before it.
            VERDICT_RC=1
            VERDICT_WHY="NOT RELEASED -- THE LAB STAYS CLAIMED: the teardown's 'ndt down' exited $rc, so a fabric may still be up; see $(basename "$RUN")/90_down.txt and finish by hand with the commands printed above${VERDICT_WHY:+ (first failure before it: $VERDICT_WHY)}"
        fi
        if (( rc == 3 && FABRIC_UP == 0 )); then
            echo "spike: 'ndt down' answered 3 (nothing was up) -- expected: this run had already taken its own fabric down"
            return 0
        fi
    fi
    return "$rc"
}
''', '''spike_ndt() {
    local rc
    "$REAL_NDT" "$@" && rc=0 || rc=$?
    if [[ "${1:-}" == down ]] && (( rc == 3 && FABRIC_UP == 0 )); then
        echo "spike: 'ndt down' answered 3 (nothing was up) -- expected: this run had already taken its own fabric down"
        return 0
    fi
    return "$rc"
}
''', 1),
    ], [
        # every scenario: none of them ends as designed without spike_release
        ("a run that declared measuring= (the 09-26 live run's shape)", "claim;down;down;release, lab.claim: none (released)"),
        ("a declared run whose detection part stopped at its first check", "claim;down;release, lab.claim: none (released)"),
        ("a teardown whose 'ndt down' is refused anyway", "lab.claim: none (released)"),
        ("a knob found at 128 that 'ndt up' moved to 4", "'ndt release' did not take"),
        ("a knob that could not be put back after a re-claim", "last line 'PASS S_heartbeat'"),
        # added in round 7b: the round-7 verdict's scenarios go red under this old form too
        ("a teardown whose 'ndt down' did not verify clean (rc 1)", "lab.claim: none (released)"),
        ("a lab another owner claimed mid-run", "it never said whose claim the fabric is under"),
        ("a claim that lapsed mid-run", "claim;down;down;release, lab.claim: none (released)"),
    ]),
    "L2/keep": ("the heart of L2 alone: spike_release releases whatever the teardown's down answered", [
        ("spike", '''    if [[ "$TEARDOWN_DOWN_RC" != 0 && "$TEARDOWN_DOWN_RC" != 3 ]]; then
        keep_claim
        # rc 0 when the verdict already leads with this (spike_ndt's down wrote it): finish's own
        # line for a failed release says "run it by hand", and `ndt release` is the one command that
        # must NOT be run first. With no down on record, 1 -- that line is then the only FAIL there is.
        [[ -n "$TEARDOWN_DOWN_RC" ]] && return 0 || return 1
    fi
''', '', 1),
    ], [
        ("a teardown whose 'ndt down' is refused anyway", "lab.claim: none (released)"),
        # added in round 7b: the round-7 verdict's scenarios go red under this old form too
        ("a teardown whose 'ndt down' did not verify clean (rc 1)", "lab.claim: none (released)"),
        ("a lab another owner claimed mid-run", "release [NDT_MEASURING in env]"),
    ]),
    "L2/verdict": ("a MUTANT: the verdict does not lead with the kept claim", [
        ("spike", '''        if (( rc != 0 && rc != 3 )); then
            # The last line is what gets read; a lab left claimed with a fabric maybe up is the one
            # thing on it somebody has to act on, so it goes first whatever failed before it.
            VERDICT_RC=1
            VERDICT_WHY="NOT RELEASED -- THE LAB STAYS CLAIMED: the teardown's 'ndt down' exited $rc, so a fabric may still be up; see $(basename "$RUN")/90_down.txt and finish by hand with the commands printed above${VERDICT_WHY:+ (first failure before it: $VERDICT_WHY)}"
        fi
''', '', 1),
    ], [
        ("a teardown whose 'ndt down' is refused anyway", "last line 'FAIL S_heartbeat -- 'ndt down' after the detection part exited 5'"),
        # added in round 7b: the round-7 verdict's scenarios go red under this old form too
        ("a teardown whose 'ndt down' did not verify clean (rc 1)", "last line 'FAIL S_heartbeat -- 'ndt down' after the detection part exited 1'"),
        ("a lab another owner claimed mid-run", "last line 'FAIL S_heartbeat -- could not take back"),
    ]),
    "L2/hygiene": ("a MUTANT: no re-claim on the restored knob before the release", [
        ("spike", '''        echo "re-claiming on the knob as it is now, so the round baseline 'ndt release' compares with is what is there"
        reclaim "$(claim_minutes 15)" "$(lab_claim_field note)" "$RUN/95_release.reclaim.txt" \\
            || echo "!! that re-claim did not take -- 'ndt release' may refuse; its answer is the verdict"
''', '', 1),
    ], [
        ("a run that declared measuring= (the 09-26 live run's shape)", "claim;down;down;release, lab.claim: none (released)"),
        ("a declared run whose detection part stopped at its first check", "claim;down;release, lab.claim: none (released)"),
        # the release the re-claim exists for: 128 put back, the baseline still 4
        ("a knob found at 128 that 'ndt up' moved to 4", "'ndt release' did not take"),
        # added in round 7b: the round-7 verdict's scenarios go red under this old form too
        ("a claim that lapsed mid-run", "claim;down;down;release, lab.claim: none (released)"),
    ]),
    "L2/knob": ("a MUTANT: a re-claim and a release over a knob that is not back", [
        ("spike", '''        if ! knob_back; then
            echo "!! NOT RELEASING: host_count_override is not back to the bytes this run found (said above)."
            echo "!!   this run re-claimed after 'ndt up' moved it, so the round's recorded start is the moved"
            echo "!!   value, and 'ndt release' would accept it. Put it back -- the bytes are in"
            echo "!!   $(basename "$RUN")/00_host_count_override.entry -- then, to record that and release:"
            printf '!!     NDT_OWNER=%q %q claim 15 && NDT_OWNER=%q %q release\\n' "$NDT_OWNER" "$REAL_NDT" "$NDT_OWNER" "$REAL_NDT"
            return 1
        fi
''', '', 1),
    ], [
        ("a knob that could not be put back after a re-claim", "last line 'PASS S_heartbeat'"),
    ]),
    "L2/return": ("a MUTANT, the one scenario (d) found: a bare `return` after spike_release, inside the EXIT trap", [
        ("spike", '''        spike_release
        return $?
''', '''        spike_release
        return
''', 1),
    ], [
        ("a knob that could not be put back after a re-claim", "last line 'PASS S_heartbeat'"),
    ]),
    # Round 7's verdict (fable, on a77b8fe2): R7-1 and R7-2 are past forms -- the a77b8fe2 code; the
    # rows with a `/` and R7-3 / R7-4/* are MUTANTS of code that had no older wrong shape (notes 3-4
    # added scenarios, not code).
    "R7-1": ("round-7 finding 1: the spike's CLAIM_MINUTES default below the sources, where _common.sh's 45 wins", [
        ("spike", '''# 🔴 AND THE CLAIM'S MINUTES, FOR THE SAME REASON (round-7 verdict, finding 1). _common.sh runs
# `: "${CLAIM_MINUTES:=45}"` when it is sourced; written below the `source`, this default never took
# effect -- the 09-26 live run claimed "for 45m", which PART=all (detection + 26 census arms, over
# an hour) outlives. A CLAIM_MINUTES from the caller still wins. The self-test runs everything above
# self_test() and reads back every such default.
: "${CLAIM_MINUTES:=180}"
''', '', 1),
        ("spike", '''EXERCISES="${ONLY:-$ALL_EXERCISES}"; EXERCISES="${EXERCISES//,/ }"
''', '''EXERCISES="${ONLY:-$ALL_EXERCISES}"; EXERCISES="${EXERCISES//,/ }"
: "${CLAIM_MINUTES:=180}"
''', 1),
    ], [
        ("a default the spike sets is NOT what its run gets (source order)",
         "CLAIM_MINUTES: the spike sets '180', a PART=all run gets '45'"),
    ]),
    "R7-2": ("round-7 finding 2: the a77b8fe2 census -- after a refused arm down, the next arm is built", [
        ("spike", '''            note "no switch-to-switch link: no heartbeat frame enters this fabric"
            census_down "$dir/90_down.txt" "$ex" "$which" || { census_skip_rest "$ex" "$which"; return 0; }
            (( ARM_DOWN_RC == 0 )) || fail "census $ex/$which: 'ndt down' exited $ARM_DOWN_RC"
''', '''            note "no switch-to-switch link: no heartbeat frame enters this fabric"
            nd_down "$dir/90_down.txt" || fail "census $ex/$which: 'ndt down' failed"
''', 1),
        ("spike", '''            census_down "$dir/90_down.txt" "$ex" "$which" || { census_skip_rest "$ex" "$which"; return 0; }
''', '''            nd_down "$dir/90_down.txt" || true
''', 3),
        ("spike", '''        census_down "$dir/90_down.txt" "$ex" "$which" && rc=0 || rc=1
''', '''        nd_down "$dir/90_down.txt" && rc=0 || rc=$?
        (( rc == 0 )) || fail "census $ex/$which: 'ndt down' exited $rc"
''', 1),
        ("spike", '''        # This arm's reading stands -- it was taken on its own fabric, and judged above -- and
        # nothing is built after a refused down.
        (( rc == 0 )) || { census_skip_rest "$ex" "$which"; return 0; }
        (( ARM_DOWN_RC == 0 )) || fail "census $ex/$which: 'ndt down' exited $ARM_DOWN_RC"
''', '', 1),
    ], [
        ("census, an arm's 'ndt down' refused (measured arm)", "ndt calls: up;down;up;down"),
        ("census, an arm's 'ndt down' refused (no link (rc 3))", "ndt calls: up;down;up;down"),
        ("census, an arm's 'ndt down' refused ('ndt up' failed)", "ndt calls: up;down;up;down"),
        ("census, an arm's 'ndt down' refused (heartbeat start failed)", "ndt calls: up;down;up;down"),
        ("census, an arm's 'ndt down' refused (start named no pid)", "ndt calls: up;down;up;down"),
    ]),
    "R7-2/stop": ("a MUTANT: census_down records a refused down and lets the census go on", [
        ("spike", '''    fail "census $2/$3: 'ndt down' exited $ARM_DOWN_RC -- the census STOPS here: that fabric may still be up, and the next arm's 'ndt up p4 --app' would reuse it ('already up ... reusing') and measure this arm's pipeline under its own name"
    return 1
''', '''    fail "census $2/$3: 'ndt down' exited $ARM_DOWN_RC -- the census STOPS here: that fabric may still be up, and the next arm's 'ndt up p4 --app' would reuse it ('already up ... reusing') and measure this arm's pipeline under its own name"
    return 0
''', 1),
    ], [
        ("census, an arm's 'ndt down' refused (measured arm)", "ndt calls: up;down;up;down"),
        ("census, an arm's 'ndt down' refused (no link (rc 3))", "ndt calls: up;down;up;down"),
        ("census, an arm's 'ndt down' refused ('ndt up' failed)", "ndt calls: up;down;up;down"),
        ("census, an arm's 'ndt down' refused (heartbeat start failed)", "ndt calls: up;down;up;down"),
        ("census, an arm's 'ndt down' refused (start named no pid)", "ndt calls: up;down;up;down"),
    ]),
    "R7-2/always": ("a MUTANT: census_down stops the census after every down, refused or not", [
        ("spike", '''    (( ARM_DOWN_RC == 0 || ARM_DOWN_RC == 3 )) && return 0
''', '', 1),
    ], [
        # the control: two arms whose downs go through must both be built
        ("a census of two arms whose downs go through", "ndt calls: up;down,"),
        # and the stubbed census arm, whose down answers 0
        ("a census arm with the new daemon's report", "the census STOPS here"),
    ]),
    "R7-3": ("a MUTANT (note 3): a teardown down that did not verify clean (rc 1) counts as down, and is released", [
        ("spike", '''    if [[ "$TEARDOWN_DOWN_RC" != 0 && "$TEARDOWN_DOWN_RC" != 3 ]]; then
        keep_claim
''', '''    if [[ "$TEARDOWN_DOWN_RC" != 0 && "$TEARDOWN_DOWN_RC" != 3 && "$TEARDOWN_DOWN_RC" != 1 ]]; then
        keep_claim
''', 1),
    ], [
        ("a teardown whose 'ndt down' did not verify clean (rc 1)", "lab.claim: none (released)"),
    ]),
    "R7-4/theirs": ("a MUTANT (note 4): keep_claim says nothing when the claim it cannot rewrite is another owner's", [
        ("spike", '''    else
        echo "!! -- and could NOT rewrite it ($(basename "$kept")). It reads owner=$(lab_claim_field owner): if that is not"
        echo "!!    $NDT_OWNER, the fabric is under THEIR claim now -- tell them, do not tear it down from here."
    fi
''', '''    fi
''', 1),
    ], [
        ("a lab another owner claimed mid-run", "it never said whose claim the fabric is under"),
    ]),
    "R7-4/floor": ("a MUTANT (note 4): a re-claim of a lapsed claim keeps 'what is left' -- nothing", [
        ("spike", '''    if (( left > $1 )); then echo "$left"; else echo "$1"; fi
''', '''    echo "$left"
''', 1),
    ], [
        ("a claim that lapsed mid-run", "lab claimed by hb-selftest for 0m"),
    ]),
}
RED = "\U0001f534"
REPOINT = 'WATCH="$SPIKE_DIR/hb_watch.py"\n'


def copy_stem(n):
    """Where revert number n's copies go: beside the real files, under this run's TAG."""
    return os.path.join(D, f".{TAG}-{n}")


def run(table, names):
    """Judge each revert in `names` of `table` -- a clean control, table["control"], first.

    Prints everything. 0: every revert discriminates and the control is clean; 1: anything else;
    2: an edit that does not apply, or a spike whose WATCH line cannot be repointed -- asked of
    EVERY requested revert before anything runs, so a 2 means that nothing ran.
    """
    if "control" not in names:
        names = ["control"] + names          # every answer is read against a clean control
    originals = {"spike": open(SPIKE).read(), "watch": open(WATCH).read()}
    prepared = []
    for n, name in enumerate(names):
        what, edits, want = table[name]
        text = dict(originals)
        for f, new, old, count in edits:
            found = text[f].count(new)
            if found != count:
                print(f"### {name}: the edit on {f} applies {found} time(s), written for {count} -- the tool "
                      f"no longer matches the spike; nothing was run\n    looked for: {new[:120]!r}")
                return 2
            text[f] = text[f].replace(new, old)
        if text["spike"].count(REPOINT) != 1:
            print(f"### {name}: the spike no longer sets WATCH as {REPOINT!r}; nothing was run")
            return 2
        prepared.append((n, name, what, want, text))
    env = {k: v for k, v in os.environ.items() if k not in ("SELFTEST_PROBE_SUDO", "FAULTS_TC")}
    rows, all_ok = [], True
    for n, name, what, want, text in prepared:
        watch_copy, spike_copy = copy_stem(n) + "-hb_watch.py", copy_stem(n) + "-spike.sh"
        text["spike"] = text["spike"].replace(REPOINT, f'WATCH="$SPIKE_DIR/{os.path.basename(watch_copy)}"\n')
        try:
            with open(watch_copy, "w") as fh:
                fh.write(text["watch"])
            with open(spike_copy, "w") as fh:
                fh.write(text["spike"])
            print(f"\n### {name}: {what}")
            print("### the copies differ from this checkout's files exactly by:")
            for f, path in (("watch", WATCH), ("spike", SPIKE)):
                sys.stdout.writelines(difflib.unified_diff(originals[f].splitlines(True), text[f].splitlines(True),
                                                           path, os.path.basename(spike_copy if f == "spike" else watch_copy), n=0))
            p = subprocess.run(["bash", spike_copy, "--self-test"], env=env, capture_output=True, text=True)
        finally:
            for path in (watch_copy, spike_copy):
                try:
                    os.remove(path)
                except OSError:
                    pass
        out = p.stdout + p.stderr
        reds = [l.rstrip() for l in out.splitlines() if RED in l]
        print("### its --self-test (SELFTEST_PROBE_SUDO and FAULTS_TC unset): rc", p.returncode)
        for l in reds:
            print(l)
        for l in out.splitlines():
            if re.search(r"SELF-TEST (PASS|FAIL)", l):
                print(l)
        problems = []
        matched = set()
        for text_, reason in want:
            hits = [i for i, l in enumerate(reds) if text_ in l]
            if len(hits) != 1:
                problems.append(f"expected red once, got {len(hits)}: {text_!r}")
                continue
            matched.add(hits[0])
            if reason and reason not in reds[hits[0]]:
                problems.append(f"red, but not for its reason ({reason!r} missing): {text_!r}")
        for i, l in enumerate(reds):
            if i not in matched:
                problems.append(f"red that no expectation names: {l.strip()[:160]!r}")
        if name == "control":
            if p.returncode != 0:
                problems.append(f"the control's self-test exited {p.returncode}")
        elif p.returncode == 0:
            problems.append("the self-test exited 0 with the old code in place")
        ok = not problems
        all_ok &= ok
        for pr in problems:
            print("### PROBLEM:", pr)
        print(f"### {name}: {'DISCRIMINATES' if name != 'control' and ok else 'CLEAN' if ok else 'UNEXPECTED'}")
        rows.append((name, p.returncode, len(reds), len(want), "ok" if ok else "UNEXPECTED"))

    print("\n### per revert: the copy's self-test rc, red lines, red lines written for it, verdict")
    print(f"    {'revert':12s} {'rc':>3s} {'red':>4s} {'want':>5s}  verdict")
    for name, rc, nred, nwant, v in rows:
        print(f"    {name:12s} {rc:3d} {nred:4d} {nwant:5d}  {v}")
    print("OLD CODE IS RED IN EXACTLY ITS OWN CHECKS, EVERY REVERT" if all_ok else "UNEXPECTED -- see PROBLEM lines")
    return 0 if all_ok else 1


def copies_ignored():
    """Whether git ignores the names this tool gives its copies (finding 4, round-5 verdict)."""
    names = [os.path.basename(copy_stem(n)) + s for n in (0, len(REVERTS) - 1) for s in ("-spike.sh", "-hb_watch.py")]
    print(f"### self-check copies-ignored: git check-ignore -v on {' '.join(names)} -- each must be ignored")
    p = subprocess.run(["git", "-C", D, "check-ignore", "-v", "--", *names], capture_output=True, text=True)
    for l in (p.stdout + p.stderr).splitlines():
        print("    | " + l)
    ignored = set()
    for l in p.stdout.splitlines():
        meta, _, path = l.partition("\t")
        if not meta.split(":", 2)[-1].startswith("!"):     # a `!` pattern matching means NOT ignored
            ignored.add(path)
    missing = [n for n in names if n not in ignored]
    ok = p.returncode == 0 and not missing
    print(f"### self-check copies-ignored: git rc {p.returncode}; "
          + ("every copy name is ignored" if ok else "NOT ignored: " + " ".join(missing)))
    return p.returncode, ok


def self_check(only):
    """--self-check: the verdict code of run(), handed wrong expectations on purpose (the header)."""
    ctl = REVERTS["control"]
    _, edits43, want43 = REVERTS["R4-3"]
    line43 = want43[0][0]
    wrong, extra = "a reason this red line does not carry", "a check this self-test does not have"

    def case(what, edits, want):
        return {"control": ctl, "case": (what, edits, want)}

    # name -> (table, the reverts run() is asked for, the rc it must answer,
    #          [(an output line that starts with this, and also contains this)])
    cases = {
        "wrong-reason": (case(f"R4-3's edit; its red line expected with {wrong!r}", edits43, [(line43, wrong)]),
                         ["case"], 1, [(f"### PROBLEM: red, but not for its reason ({wrong!r} missing)", line43),
                                       ("### case: UNEXPECTED", "")]),
        "extra-line": (case(f"R4-3's edit; its own red line, and {extra!r}", edits43, want43 + [(extra, "")]),
                       ["case"], 1, [(f"### PROBLEM: expected red once, got 0: {extra!r}", ""),
                                     ("### case: UNEXPECTED", "")]),
        # The PROBLEM line carries the red line's repr(), and that line holds both kinds of quote, so
        # its ' come out escaped: look for a part of R4-3's line with no quote in it.
        "unnamed-red": (case("R4-3's edit; no red line expected", edits43, []),
                        ["case"], 1, [("### PROBLEM: red that no expectation names:", line43.rsplit("' ", 1)[-1]),
                                      ("### case: UNEXPECTED", "")]),
        "reddens-nothing": (case("an edit to a comment line, which no check can see",
                                 [("spike", "# --- helpers -", "# --- helpers (a self-check edit) -", 1)], []),
                            ["case"], 1, [("### PROBLEM: the self-test exited 0 with the old code in place", ""),
                                          ("### case: UNEXPECTED", "")]),
        "dirty-control": ({"control": ("the copying plus R4-3's edit: a control that is not clean", edits43, [])},
                          ["control"], 1, [("### PROBLEM: the control's self-test exited 1", ""),
                                           ("### control: UNEXPECTED", "")]),
        "anchor-absent": (case("an edit whose text the spike does not have",
                               [("spike", "a line this spike does not have\n", "", 1)], []),
                          ["case"], 2, [("### case: the edit on spike applies 0 time(s), written for 1", "")]),
        "anchor-count": (case("R4-3's edit, written for two places", [(f, new, old, 2) for f, new, old, _ in edits43], []),
                         ["case"], 2, [("### case: the edit on spike applies 1 time(s), written for 2", "")]),
        "watch-line": (case("an edit that moves the spike's WATCH line",
                            [("spike", REPOINT, 'WATCH="$SPIKE_DIR/hb_watch_elsewhere.py"\n', 1)], []),
                       ["case"], 2, [("### case: the spike no longer sets WATCH as", "")]),
        "real-row": ({"control": ctl, "R4-3": REVERTS["R4-3"]}, ["R4-3"], 0, [("### R4-3: DISCRIMINATES", "")]),
    }
    order = list(cases) + ["copies-ignored"]
    names = only or order
    unknown = [n for n in names if n not in order]
    if unknown:
        print(f"unknown self-check case(s): {' '.join(unknown)} (the header lists them)", file=sys.stderr)
        return 2
    rows = []
    for name in names:
        print(f"\n### self-check {name}")
        if name == "copies-ignored":
            got, ok = copies_ignored()
            must = 0
        else:
            table, run_names, must, lines = cases[name]
            print(f"### self-check {name}: {table[run_names[-1]][0]} -- must answer rc {must}")
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                got = run(table, run_names)
            out = buf.getvalue().splitlines()
            for l in out:
                print("    | " + l)
            missing = [a + (f" ... {b}" if b else "") for a, b in lines
                       if not any(l.startswith(a) and b in l for l in out)]
            ok = got == must and not missing
            print(f"### self-check {name}: rc {got} (must be {must}); "
                  + ("its own line(s) are there" if not missing else "MISSING: " + " | ".join(missing)))
        print(f"### self-check {name}: {'AS IT MUST' if ok else 'NOT AS IT MUST'}")
        rows.append((name, must, got, ok))

    print("\n### per case: the rc it must answer, the rc it answered, verdict")
    print(f"    {'case':16s} {'must':>4s} {'got':>4s}  verdict")
    for name, must, got, ok in rows:
        print(f"    {name:16s} {must:4d} {got:4d}  {'ok' if ok else 'NOT AS IT MUST'}")
    all_ok = all(r[3] for r in rows)
    print("EVERY VERDICT PATH OF THE TOOL ANSWERS AS IT MUST" if all_ok else "SELF-CHECK FAIL -- see NOT AS IT MUST")
    return 0 if all_ok else 1


if ARGS[:1] == ["--self-check"]:
    sys.exit(self_check(ARGS[1:]))
if ARGS == ["--list"]:
    for name, (what, _, want) in REVERTS.items():
        print(f"{name:12s} {what}  -> {len(want)} red line(s)")
    sys.exit(0)
names = ARGS or list(REVERTS)
unknown = [n for n in names if n not in REVERTS]
if unknown:
    print(f"unknown revert(s): {' '.join(unknown)} (--list)", file=sys.stderr)
    sys.exit(2)
sys.exit(run(REVERTS, names))
PY
