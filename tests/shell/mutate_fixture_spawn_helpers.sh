#!/usr/bin/env bash
#
# Mutation gate for the fixture-spawn helpers of seven suites: every call of a helper runs in the
# suite's own shell -- each helper refuses any other and ends the run (its `[[ $BASHPID == "$$" ]]`
# guard), and the SUBSHELL mutants below hold it to that -- and a fixture that never takes its
# argv0 must be a FAILED check the suite COUNTS, followed by a summary line and a non-zero exit.
#
# [Co-developed with claude code -- Adam]
#
# WHAT WENT WRONG (measured 2026-09-28). Each helper polled /proc for 1-2 s and then ran `exit 1`,
# but every caller wrote X="$(spawn_fixture ...)" -- X="$(spawn ...)" in test_faults_topo_pid.sh
# and test_ndt_ovs_claim.sh, whose helper has that name -- so that exit left only the command
# substitution. The suite ran on with X holding whatever the helper had printed to stdout (its
# own "Ran N checks" line in four suites; nothing at all in test_ndt_helper_apps_window.sh and
# test_faults_topo_pid.sh, whose helpers printed only their FAILED line, to stderr), the
# FAILED line was never counted (test_ndt_apps_liveness.sh printed 23 FAILED lines under "Ran 51
# checks, 17 failed"), and test_ndtwin_lab_sweep.sh -- errexit is on there, left behind by the
# ndtwin-lab it sources -- stopped at the assignment without printing any summary.
# test_ndt_down_stops_only_ours.sh had the same call form with `|| { ...; exit 1; }` after it: the
# failure was counted, but the fixture it gave up on was never reaped.
#
# FOUR PARTS. The first two are there because a mutant of a helper only ever reaches that helper's
# FIRST call site: the helper ends the run there. A later site written back as X="$(helper ...)" is never reached by
# any mutant, and at some sites (a decoy whose pid nothing reads again) the suite stays green too.
#   1. STATIC, every call site. Each non-comment line that mentions the suite's helper is either
#      its one definition or `helper ARGS; VAR="$FIXTURE_PID"` -- arguments double-quoted with
#      plain $VAR expansions, or bare words. A `$(`, a backtick, a `<(`, a `|` or anything else
#      around a call is refused, and so is an indented call outside the one conditional block
#      this gate knows (window's 12C).
#   2. THE CONTROL COUNTS THEM. Each suite's unmutated copy must be green AND print one
#      `ok       fixture took argv0=` line per call site found in part 1: a call that ran anywhere
#      but this shell (a function called from a substitution, say) prints its line into a
#      variable instead. window's call inside 12C is expected only when 12C ran -- the suite says
#      "12C did NOT run" when it did not, and then that site is not expected, by name.
#   3. MUTANTS, each a helper that cannot recognise its fixture, two ways: NEVER -- the argv0
#      comparison gets a suffix no fixture wears, so the poll runs to its bound, the way it would
#      for a fixture too slow to exec -- and GONE -- the fixture exits at once, so the poll reads a
#      /proc entry that is not there (the `|| true` after that read is what keeps errexit from
#      ending test_ndtwin_lab_sweep.sh at it). Each mutant must then
#        1. exit non-zero,
#        2. print a "Ran N checks, M failed" summary,
#        3. print a FAILED line for the fixture itself,
#        4. COUNT it -- M equals the number of FAILED lines it printed --
#        5. and not leave the fixture it gave up on running (every pid named after that FAILED line);
#      a GONE mutant's FAILED block must also say "nothing readable", the read GONE is there for.
#      And one mutant must SURVIVE: sweep's GONE with that `|| true` removed has to end with rc 1
#      and no summary at all -- errexit ending it at that read, not a timeout (124) or anything
#      else. If it did not, GONE would not be reaching the read it is meant to reach.
#   4. SUBSHELL: one call per suite wrapped in ( ... ). Part 1 passes that line and part 2 still
#      counts its premise (the subshell's stdout is the suite's), so only the helper's own guard
#      can catch it: the run must end with that guard's FAILED line, exactly once, and the rc 143
#      of the TERM it sends -- and no green summary.
#
# A copy is written BESIDE its suite (tests/shell/.spawn-gate-<pid>-<kind>-<label>-<suite>), so
# every path the suite derives from its own location -- lib_probe_stub.sh,
# check_process_by_name.py, ../../tools, ../../doc -- is the real one. A copy anywhere else cannot
# find them, which is why two of these suites went unmeasured the first time. A mirror tree of
# symlinks would not do either: `ndt` finds its REPO through `readlink -f` of its own path, so it
# would be in the real tree while the suite's paths are in the mirror. So each copy is removed
# after its run, and on EXIT, INT and TERM; a SIGKILL can still leave one, and .gitignore keeps
# that out of a commit. The judge itself is held first to synthetic runs, each built to come out
# one way (J1-J14: the verdict, the gone-without-true acceptance, GONE's block, SUBSHELL's verdict).
#
# Usage: bash tests/shell/mutate_fixture_spawn_helpers.sh [label...]
#   labels: orphans liveness sweep window topo_pid ovs_claim down (default: all seven)
#   TEST_TIMEOUT=600   seconds allowed per suite run
# Exit: 0 every call site plain and counted, every mutation caught; 1 a call site that is not
#       plain or not counted, or a mutation that survived; 2 refused (a control that did not come
#       out as it must, an anchor not exactly once, harness)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORPHANS="$HERE/test_ndt_app_orphans.sh"
LIVENESS="$HERE/test_ndt_apps_liveness.sh"
SWEEP="$HERE/test_ndtwin_lab_sweep.sh"
WINDOW="$HERE/test_ndt_helper_apps_window.sh"
TOPO_PID="$HERE/test_faults_topo_pid.sh"
OVS_CLAIM="$HERE/test_ndt_ovs_claim.sh"
DOWN="$HERE/test_ndt_down_stops_only_ours.sh"
ALL_LABELS=(orphans liveness sweep window topo_pid ovs_claim down)
TEST_TIMEOUT="${TEST_TIMEOUT:-600}"
command -v timeout >/dev/null 2>&1 || { echo "refused: GNU timeout is required"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "refused: python3 is required"; exit 2; }
cd "$HERE/../.." || { echo "refused: cannot cd to the repo root"; exit 2; }
J6PID=""
trap 'rm -f "$HERE"/.spawn-gate-$$-*; [[ -n "$J6PID" ]] && kill "$J6PID" 2>/dev/null' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
SURVIVORS=0; MUTATIONS=0

LABELS=("$@")
(( ${#LABELS[@]} )) || LABELS=("${ALL_LABELS[@]}")
for l in "${LABELS[@]}"; do
    [[ " ${ALL_LABELS[*]} " == *" $l "* ]] || { echo "refused: no suite labelled '$l' (${ALL_LABELS[*]})"; exit 2; }
done
selected() { [[ " ${LABELS[*]} " == *" $1 "* ]]; }

# suite_info <label> -> SFILE (the suite), SHELPER (its helper's name), and for a suite with a call
# site inside a conditional block: SCOND_OPEN (that block's `if` line, exactly once at column 0)
# and SCOND_SKIP (what the suite prints when the block did not run, exactly once in the file).
suite_info() {
    SCOND_OPEN=""; SCOND_SKIP=""
    case "$1" in
        orphans)   SFILE="$ORPHANS";   SHELPER=spawn_fixture ;;
        liveness)  SFILE="$LIVENESS";  SHELPER=spawn_fixture ;;
        sweep)     SFILE="$SWEEP";     SHELPER=spawn_fixture ;;
        window)    SFILE="$WINDOW";    SHELPER=spawn_fixture
                   SCOND_OPEN='if [[ "$DEAD_TE" =~ ^[0-9]+$ ]] && [[ ! -d "/proc/$DEAD_TE" ]]; then'
                   SCOND_SKIP='12C did NOT run' ;;
        topo_pid)  SFILE="$TOPO_PID";  SHELPER=spawn ;;
        ovs_claim) SFILE="$OVS_CLAIM"; SHELPER=spawn ;;
        down)      SFILE="$DOWN";      SHELPER=spawn ;;
        *)         echo "refused: suite_info has no '$1'"; exit 2 ;;
    esac
}

# --- the two python programs, read here at the top level ----------------------------------------
# Kept out of the functions' command substitutions: tests/shell/check_gate_anchors.py reads a heredoc
# as one only at the top level of a command, and inside $( ) it would read this python as shell.
# STATIC_PY <suite> <helper> <cond-open> <cond-skip> <name>: part 1's reader. Prints one FAILED
# line per finding, then "COUNT <sites> <in-block> <site lines>|<in-block lines>"; rc 0 clean, 1 not.
IFS= read -r -d '' STATIC_PY <<'PY'
import re, sys
path, helper, cond_open, cond_skip, rel = sys.argv[1:6]
text = open(path).read()
lines = text.split("\n")
h = re.escape(helper)
mention = re.compile(r"(?<![\w./-])" + h + r"(?![\w-])")
definition = re.compile(r"^" + h + r"\(\)\s*\{\s*$")
arg = r'(?:"(?:[^"`$\\]|\$[A-Za-z_]\w*|\$\{[A-Za-z_]\w*\})*"|[A-Za-z0-9_./-]+)'
call = re.compile(r"^(\s*)" + h + r"((?:[ \t]+" + arg + r")+)[ \t]*;[ \t]*[A-Za-z_]\w*=\"\$FIXTURE_PID\"[ \t]*$")
bad = []
# The one conditional block, if this suite has one: from its `if` line to the next column-0
# else/fi. Both texts must be there exactly once, or the count below would be a guess.
region = None
if cond_open:
    opens = [i for i, l in enumerate(lines) if l == cond_open]
    if len(opens) != 1:
        bad.append((0, "the conditional block's opening line occurs %d time(s), not once" % len(opens), cond_open))
    else:
        end = next((j for j in range(opens[0] + 1, len(lines)) if re.match(r"^(else|fi)\b", lines[j])), None)
        if end is None:
            bad.append((opens[0] + 1, "the conditional block never reaches a column-0 else/fi", cond_open))
        else:
            region = (opens[0], end)
    if text.count(cond_skip) != 1:
        bad.append((0, "the block's did-not-run text occurs %d time(s), not once" % text.count(cond_skip), cond_skip))
defs, sites, cond = 0, [], []
for i, l in enumerate(lines):
    if l.lstrip().startswith("#") or not mention.search(l):
        continue
    if definition.match(l):
        defs += 1
        continue
    # Every other mention is a call site, plain or not: part 2 expects one counted premise per
    # site, so a site written back as X="$(helper ...)" is still expected there -- and its premise,
    # printed into X, is missing. That is what lets part 2 catch a revert without part 1.
    sites.append(i + 1)
    inside = region is not None and region[0] < i < region[1]
    if inside:
        cond.append(i + 1)
    m = call.match(l)
    if m:
        if m.group(1) and not inside:
            bad.append((i + 1, "an indented call outside the one conditional block this gate knows", l))
        continue
    if "$(" in l or "`" in l:
        why = "the helper inside a command substitution"
    elif "<(" in l or ">(" in l:
        why = "the helper inside a process substitution"
    elif "|" in l:
        why = "the helper next to a | or ||"
    else:
        why = 'not of the form %s ARGS; VAR="$FIXTURE_PID"' % helper
    bad.append((i + 1, why, l))
if defs != 1:
    bad.append((0, "%d definition(s) of %s(), not one" % (defs, helper), ""))
if not sites:
    bad.append((0, "no call site of %s at all" % helper, ""))
for n, why, l in bad:
    print("  FAILED   static %s:%s: %s: %s" % (rel, n, why, l.strip()[:100]))
print("COUNT %d %d %s|%s" % (len(sites), len(cond), " ".join(map(str, sites)), " ".join(map(str, cond))))
sys.exit(1 if bad else 0)
PY
# COPY_PY <src> <dst> [<old> <new>]...: writes <dst> with each anchor replaced once, only if every
# anchor occurs exactly once; prints each anchor's count (or 1 with no anchors).
IFS= read -r -d '' COPY_PY <<'PY'
import sys
src, dst, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
s = open(src).read()
counts = []
for k in range(0, len(pairs), 2):
    a, b = pairs[k], pairs[k + 1]
    counts.append(str(s.count(a)))
    if s.count(a) == 1:
        s = s.replace(a, b, 1)
if all(c == "1" for c in counts):
    open(dst, "w").write(s)
print(" ".join(counts) if counts else "1")
PY

# --- one run, and the rule that reads it -------------------------------------------------------
run_one() {   # run_one <file> -> RUN_OUT, RUN_RC, RUN_S
    local t0=$SECONDS
    RUN_OUT="$(timeout "$TEST_TIMEOUT" bash "$1" </dev/null 2>&1)"; RUN_RC=$?
    RUN_S=$(( SECONDS - t0 ))
}
# A fixture is still there if /proc has it, it is not a zombie, and it is still a `sleep`.
fixture_alive() { [[ "$(cat "/proc/$1/comm" 2>/dev/null)" == sleep ]] \
                  && [[ "$(sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)" != Z ]]; }
judge() {   # judge -> "caught (...)" or "SURVIVED (...)", read from RUN_OUT and RUN_RC
    local ran m printed fixline pid i left=""
    ran="$(grep -E '^Ran [0-9]+ checks' <<<"$RUN_OUT" | tail -1)"
    printed="$(grep -cE '^ *FAILED ' <<<"$RUN_OUT")"
    fixline="$(grep -m1 -E '^ *FAILED +fixture .*argv0' <<<"$RUN_OUT" | sed 's/^ *//')"
    m=""
    [[ "$ran" =~ ^Ran\ [0-9]+\ checks,\ ([0-9]+)\ failed ]] && m="${BASH_REMATCH[1]}"
    [[ "$ran" =~ ^Ran\ [0-9]+\ checks,\ all\ passed ]] && m=0
    (( RUN_RC != 0 )) || { echo "SURVIVED (rc 0)"; return; }
    [[ -n "$ran" ]] || { echo "SURVIVED (rc $RUN_RC, and no \"Ran N checks\" line at all)"; return; }
    [[ -n "$m" ]] || { echo "SURVIVED (a summary this gate cannot read: $ran)"; return; }
    [[ -n "$fixline" ]] || { echo "SURVIVED (no FAILED line names the fixture; $ran)"; return; }
    (( m == printed )) || { echo "SURVIVED ($printed FAILED line(s) printed, the summary counts $m: $ran)"; return; }
    for pid in $(sed -n '/^ *FAILED  *fixture .*argv0/,$p' <<<"$RUN_OUT" | grep -oE 'pid [0-9]+' | cut -d' ' -f2); do
        for i in 1 2 3 4 5 6 7 8 9 10; do fixture_alive "$pid" || break; sleep 0.3; done
        fixture_alive "$pid" && left="$left $pid"
    done
    [[ -z "$left" ]] || { echo "SURVIVED (the fixture it gave up on is still running: pid$left)"; return; }
    echo "caught (rc $RUN_RC; $ran; ${fixline:0:80})"
}
# [Co-developed with claude code -- Adam] The three rules below were added 2026-10-01.
# The one verdict gone-without-true may have: errexit ended the run at the read (rc 1), with no
# summary. A timeout (124) or any other rc with no summary is some other way of ending.
MUST_SURVIVE='SURVIVED (rc 1, and no "Ran N checks" line at all)'
# gone_block_says_unreadable: RUN_OUT's FAILED fixture block -- that line and the indented lines
# under it -- says "nothing readable", so the read of /proc/<pid>/cmdline is what came up empty.
# (Into a variable first: `awk | grep -q` under pipefail can read as a failure when grep quits early.)
gone_block_says_unreadable() {
    local block
    block="$(awk '!b && /^ *FAILED +fixture .*argv0/ { b = 1; print; next }
                  b && /^      / { print; next }
                  b { exit }' <<<"$RUN_OUT")"
    [[ "$block" == *"nothing readable"* ]]
}
# judge_subshell -> "caught (...)" or "SURVIVED (...)" for a SUBSHELL mutant: the helper's guard
# printed its FAILED line exactly once, the run ended with the 143 of the TERM the guard sends,
# and no green summary came after it.
GUARD_TEXT="called outside this suite's own shell"
judge_subshell() {
    local n
    n="$(grep -cF -- "$GUARD_TEXT" <<<"$RUN_OUT")"
    (( RUN_RC != 0 )) || { echo "SURVIVED (rc 0)"; return; }
    (( n == 1 )) || { echo "SURVIVED ($n line(s) say the helper was $GUARD_TEXT, not 1; rc $RUN_RC)"; return; }
    (( RUN_RC == 143 )) || { echo "SURVIVED (rc $RUN_RC, not the 143 of the TERM the guard sends)"; return; }
    if grep -qE '^Ran [0-9]+ checks, (0 failed|all passed)' <<<"$RUN_OUT"; then
        echo "SURVIVED (a green summary after the guard fired)"; return
    fi
    echo "caught (rc $RUN_RC; $(grep -m1 -F -- "$GUARD_TEXT" <<<"$RUN_OUT" | sed 's/^ *//' | cut -c1-80))"
}

# --- the judge's own controls: each must come out as stated, or nothing below means anything ----
echo "the judge, on synthetic runs:"
jcontrol() {   # jcontrol <name> <rc> <output> <the glob the verdict must match> [<verdict fn>, judge]
    local v
    RUN_RC="$2"; RUN_OUT="$3"; v="$("${5:-judge}")"
    # shellcheck disable=SC2053  # $4 IS a glob
    if [[ "$v" == $4 ]]; then printf '  ok       %s -> %s\n' "$1" "${v:0:100}"
    else printf '  refused: control "%s" answered "%s", not "%s"\n' "$1" "${v:0:100}" "$4"; exit 2; fi
}
jcontrol "J1: a FAILED fixture line the summary does not count" 1 \
    $'  FAILED   fixture never took argv0=x\nRan 3 checks, 0 failed' 'SURVIVED (1 FAILED line(s) printed, the summary counts 0*'
jcontrol "J2: no summary line at all" 1 \
    $'  FAILED   fixture never took argv0=x' 'SURVIVED (rc 1, and no "Ran N checks" line at all)'
jcontrol "J3: rc 0" 0 \
    $'  FAILED   fixture took argv0=x\nRan 2 checks, 1 failed' 'SURVIVED (rc 0)'
jcontrol "J4: a counted failure that is not the fixture's" 1 \
    $'  FAILED   something else\nRan 2 checks, 1 failed' 'SURVIVED (no FAILED line names the fixture*'
jcontrol "J5: the fixture's failure, counted" 1 \
    $'  ok       before\n  FAILED   fixture took argv0=x\n             expected: x\nRan 2 checks, 1 failed' 'caught (rc 1; Ran 2 checks, 1 failed;*'
# J6 is the only one with a real process in it: a live `sleep`, named after the FAILED line the way
# a helper names the fixture it gave up on. Without it nothing shows condition 5 can ever fail.
sleep 120 >/dev/null 2>&1 </dev/null & J6PID=$!
jcontrol "J6: the fixture's failure, counted, but the fixture is still running" 1 \
    "  FAILED   fixture took argv0=x
             expected: [x]
             actual:   [nothing readable (pid $J6PID, after 30s)]
Ran 2 checks, 1 failed" "SURVIVED (the fixture it gave up on is still running: pid $J6PID)"
kill "$J6PID" 2>/dev/null; wait "$J6PID" 2>/dev/null; J6PID=""
# J7-J8: what gone-without-true accepts. A timeout with no summary is not errexit ending the run.
jsurvive() {   # jsurvive <name> <rc> <output> <accepted|rejected>
    local v got=rejected
    RUN_RC="$2"; RUN_OUT="$3"; v="$(judge)"
    [[ "$v" == "$MUST_SURVIVE" ]] && got=accepted
    if [[ "$got" == "$4" ]]; then printf '  ok       %s -> %s: %s\n' "$1" "$got" "${v:0:90}"
    else printf '  refused: control "%s" was %s (%s), not %s\n' "$1" "$got" "${v:0:90}" "$4"; exit 2; fi
}
jsurvive "J7: gone-without-true timed out (rc 124), no summary" 124 \
    'machine-wide scan (real ps, read-only)' rejected
jsurvive "J8: gone-without-true ended by errexit (rc 1), no summary" 1 \
    'machine-wide scan (real ps, read-only)' accepted
# J9-J10: GONE's FAILED block, in the two layouts the suites print.
jgone() {   # jgone <name> <output> <yes|no: the block says "nothing readable">
    local got=no
    RUN_OUT="$2"; gone_block_says_unreadable && got=yes
    if [[ "$got" == "$3" ]]; then printf '  ok       %s -> %s\n' "$1" "$got"
    else printf '  refused: control "%s" answered %s, not %s\n' "$1" "$got" "$3"; exit 2; fi
}
jgone "J9: a fixture block whose read came up empty" \
    $'  FAILED   fixture took argv0=x\n             expected: [x]  actual: [nothing readable (pid 7, after 30s)]\nRan 2 checks, 1 failed' yes
jgone "J10: a fixture block that read an argv0, \"nothing readable\" only in a later block" \
    $'  FAILED   fixture took argv0=x\n             expected: x\n             actual:   x/y (pid 7, after 30s)\n  FAILED   other: nothing readable\nRan 3 checks, 2 failed' no
# J11-J12: SUBSHELL's verdict -- the guard's line and its TERM, against a suite that just went red.
jcontrol "J11: the guard's FAILED line once, then rc 143" 143 "  ok       fixture took argv0=x
  FAILED   spawn $GUARD_TEXT (BASHPID 9, suite 8): ending the run" 'caught (rc 143;*' judge_subshell
jcontrol "J12: red with a summary, but no guard line" 1 \
    $'  ok       fixture took argv0=x\n  FAILED   the decoy is not te\nRan 5 checks, 1 failed' 'SURVIVED (0 line(s) say*' judge_subshell
# J13-J14: the guard fired, but the run did not end the way its TERM ends it -- a TERM trap that
# cleans up and returns, or a suite that ran on to a green summary.
jcontrol "J13: the guard's FAILED line once, but rc 1" 1 "  ok       fixture took argv0=x
  FAILED   spawn $GUARD_TEXT (BASHPID 9, suite 8): ending the run
Ran 2 checks, 1 failed" 'SURVIVED (rc 1, not the 143*' judge_subshell
jcontrol "J14: the guard's FAILED line once, rc 143, then a green summary" 143 "  ok       fixture took argv0=x
  FAILED   spawn $GUARD_TEXT (BASHPID 9, suite 8): ending the run
Ran 5 checks, all passed" 'SURVIVED (a green summary after the guard fired)' judge_subshell

# --- 1. static: every call site of every selected suite -----------------------------------------
declare -A STATIC_TOTAL=() STATIC_COND=()
STATIC_BAD=0
static_suite() {   # static_suite <label> -> prints its findings; STATIC_TOTAL/STATIC_COND[label]
    local label="$1" out rc
    suite_info "$label"
    out="$(python3 -c "$STATIC_PY" "$SFILE" "$SHELPER" "$SCOND_OPEN" "$SCOND_SKIP" "${SFILE#"$HERE/"}")"; rc=$?
    local count; count="$(grep '^COUNT ' <<<"$out" | tail -1)"
    if [[ ! "$count" =~ ^COUNT\ ([0-9]+)\ ([0-9]+)\ ([0-9\ ]*)\|([0-9\ ]*)$ ]] || (( rc > 1 )); then
        printf '  refused: the static reader failed on %s (rc %s): %s\n' "${SFILE#"$HERE/"}" "$rc" "$(head -3 <<<"$out" | paste -sd'|' -)"
        exit 2
    fi
    STATIC_TOTAL[$label]="${BASH_REMATCH[1]}"; STATIC_COND[$label]="${BASH_REMATCH[2]}"
    local lines="${BASH_REMATCH[3]}" clines="${BASH_REMATCH[4]}"
    grep -v '^COUNT ' <<<"$out"
    if (( rc == 0 )); then
        printf '  ok       %-10s %s() called at %s line(s), every one a plain call: %s%s\n' "$label" "$SHELPER" \
               "${STATIC_TOTAL[$label]}" "$lines" "${clines:+ (inside the conditional block: $clines)}"
    else
        STATIC_BAD=$((STATIC_BAD + 1))
        printf '  FAILED   %-10s not every call of %s() is a plain call in this shell (call sites: %s)\n' \
               "$label" "$SHELPER" "$lines"
    fi
}
echo
echo "1. every call site, read from the source"
for l in "${LABELS[@]}"; do static_suite "$l"; done
# Part 2 is measured on its own by taking out exactly this one line.
if (( STATIC_BAD )); then echo; echo "static check: $STATIC_BAD suite(s) with a call site that is not plain -- the suites were not run"; exit 1; fi

# --- 2 and 3: per suite, the control and its count, then the mutants ---------------------------
# make_copy <kind> <label> <file> [<old> <new>]... -> COPY, a copy beside the suite with each
# anchor replaced; refused unless every anchor occurs exactly once.
make_copy() {
    local kind="$1" label="$2" file="$3" n
    shift 3
    COPY="$HERE/.spawn-gate-$$-$kind-$label-$(basename "$file")"
    n="$(python3 -c "$COPY_PY" "$file" "$COPY" "$@")"
    if [[ ! "$n" =~ ^1(\ 1)*$ ]]; then
        printf '  refused: %s %s -- an anchor occurs %s time(s) in %s, not once\n' "$kind" "$label" "${n:-?}" "${file#"$HERE/"}"
        exit 2
    fi
}

COUNT_BAD=0
gate_control() {   # gate_control <label>: green, and one ok line per call site
    local label="$1" expected got note=""
    suite_info "$label"
    make_copy control "$label" "$SFILE"
    run_one "$COPY"; rm -f "$COPY"
    if (( RUN_RC != 0 )) || ! grep -qE '^Ran [0-9]+ checks, (0 failed|all passed)' <<<"$(grep -E '^Ran ' <<<"$RUN_OUT" | tail -1)" \
            || grep -qE '^ *FAILED ' <<<"$RUN_OUT"; then
        printf '  refused: %s -- the unmutated copy is not green (rc %s): %s\n' "$label" "$RUN_RC" \
               "$(grep -E '^ *FAILED |^Ran ' <<<"$RUN_OUT" | head -3 | paste -sd'|' -)"
        exit 2
    fi
    expected="${STATIC_TOTAL[$label]}"
    if [[ -n "$SCOND_SKIP" ]] && grep -qF -- "$SCOND_SKIP" <<<"$RUN_OUT"; then
        expected=$(( expected - STATIC_COND[$label] ))
        note=" -- the suite says \"$SCOND_SKIP\", so its ${STATIC_COND[$label]} call(s) in that block are not expected"
    fi
    got="$(grep -cE '^ *ok +fixture took argv0=' <<<"$RUN_OUT")"
    printf '  control  %-10s %s  (%ss)\n' "$label" "$(grep -E '^Ran ' <<<"$RUN_OUT" | tail -1)" "$RUN_S"
    if [[ "$got" == "$expected" ]]; then
        printf '  ok       %-10s %s fixture premise(s) counted in this shell, one per call site%s\n' "$label" "$got" "$note"
    else
        COUNT_BAD=$((COUNT_BAD + 1))
        printf '  FAILED   %-10s %s "ok fixture took argv0=" line(s), but %s call site(s) should have run%s\n' \
               "$label" "$got" "$expected" "$note"
    fi
}

# The parameters are NAMED so tests/shell/check_gate_anchors.py can read this gate.
gate_mutant() {   # gate_mutant <kind> <label> <file> <old> <new>: must be caught
    local kind="$1" label="$2" file="$3" old="$4" new="$5" r line what
    MUTATIONS=$((MUTATIONS+1))
    make_copy "$kind" "$label" "$file" "$old" "$new"
    run_one "$COPY"; rm -f "$COPY"
    if [[ "$kind" == subshell ]]; then
        r="$(judge_subshell)"; what="guard FAILED"
        line="$(grep -m1 -F -- "$GUARD_TEXT" <<<"$RUN_OUT" | sed 's/^ *//' | cut -c1-110)"
    else
        r="$(judge)"; what="fixture FAILED"
        line="$(grep -m1 -E '^ *FAILED +fixture .*argv0' <<<"$RUN_OUT" | sed 's/^ *//' | cut -c1-110)"
    fi
    if [[ "$kind" == gone && "$r" == caught* ]] && ! gone_block_says_unreadable; then
        r="SURVIVED (caught, but its FAILED block does not say \"nothing readable\": not the read GONE is for)"
    fi
    [[ "$r" == SURVIVED* ]] && SURVIVORS=$((SURVIVORS+1))
    printf '  %-8s %-10s %-8s %s  (%ss)\n' "${r%% (*}" "$label" "$kind" "(${r#* (}" "$RUN_S"
    printf '             its %s line: %s\n' "$what" "$line"
    printf '             its last line:           %s\n' "$(tail -1 <<<"$RUN_OUT" | cut -c1-110)"
}
# gate_must_survive <kind> <label> <file> <old> <new> <file2> <old2> <new2>: the positive control --
# a mutant this gate MUST call a survivor, for the reason given, or the mutant it shadows is not
# measuring what it claims to.
gate_must_survive() {
    local kind="$1" label="$2" file="$3" old="$4" new="$5" file2="$6" old2="$7" new2="$8" r
    [[ "$file2" == "$file" ]] || { echo "  refused: $kind -- both anchors must be in one file"; exit 2; }
    make_copy "$kind" "$label" "$file" "$old" "$new" "$old2" "$new2"
    run_one "$COPY"; rm -f "$COPY"
    r="$(judge)"
    if [[ "$r" == "$MUST_SURVIVE" ]]; then
        printf '  ok       %-10s %-6s survives as it must: %s  (%ss)\n' "$label" "$kind" "$r" "$RUN_S"
        printf '             its last line:           %s\n' "$(tail -1 <<<"$RUN_OUT" | cut -c1-110)"
    else
        printf '  refused: %s %s -- this mutant must end with rc 1 and no summary, and the judge said: %s\n' "$label" "$kind" "$r"
        printf '             its last line: %s\n' "$(tail -1 <<<"$RUN_OUT" | cut -c1-110)"
        exit 2
    fi
}

echo
echo "2. each suite's unmutated copy: green, and one counted premise per call site"
echo "3. then its helper made unable to recognise its fixture: NEVER (the poll's bound), GONE (/proc empty)"
echo "4. and one call wrapped in ( ... ): SUBSHELL, which only the helper's own guard can catch"
if selected orphans; then
    gate_control orphans
    gate_mutant never orphans "$ORPHANS" '[[ "${argv[0]:-}" == "$want" ]]' '[[ "${argv[0]:-}" == "$want/NDT-GATE-NEVER" ]]'
    gate_mutant gone  orphans "$ORPHANS" '( cd "$dir" && exec -a "$want" sleep "$FIXTURE_TTL" )' '( cd "$dir" && exit 0 )'
    gate_mutant subshell orphans "$ORPHANS" 'spawn_fixture "$FIX_ARGV"; FIX="$FIXTURE_PID"' '( spawn_fixture "$FIX_ARGV"; FIX="$FIXTURE_PID" )'
fi
if selected liveness; then
    gate_control liveness
    gate_mutant never liveness "$LIVENESS" '[[ "${argv[0]:-}" == "$want" ]]' '[[ "${argv[0]:-}" == "$want/NDT-GATE-NEVER" ]]'
    gate_mutant gone  liveness "$LIVENESS" '( cd "$dir" && exec -a "$want" sleep "$FIXTURE_TTL" )' '( cd "$dir" && exit 0 )'
    gate_mutant subshell liveness "$LIVENESS" 'spawn_fixture "$SIM_ARGV"; SIMFIX="$FIXTURE_PID"' '( spawn_fixture "$SIM_ARGV"; SIMFIX="$FIXTURE_PID" )'
fi
if selected sweep; then
    gate_control sweep
    gate_mutant never sweep "$SWEEP" '[[ "${argv[0]:-}" == "$want" ]]' '[[ "${argv[0]:-}" == "$want/NDT-GATE-NEVER" ]]'
    gate_mutant gone  sweep "$SWEEP" '( exec -a "$want" sleep "$FIXTURE_TTL" )' '( exit 0 )'
    gate_mutant subshell sweep "$SWEEP" 'spawn_fixture "$FIX_SW"; SWFIX="$FIXTURE_PID"' '( spawn_fixture "$FIX_SW"; SWFIX="$FIXTURE_PID" )'
    gate_must_survive gone-without-true sweep \
        "$SWEEP" '( exec -a "$want" sleep "$FIXTURE_TTL" )' '( exit 0 )' \
        "$SWEEP" "mapfile -d '' -t argv 2>/dev/null < \"/proc/\$pid/cmdline\" || true" "mapfile -d '' -t argv 2>/dev/null < \"/proc/\$pid/cmdline\""
fi
if selected window; then
    gate_control window
    gate_mutant never window "$WINDOW" '[[ "${argv[0]:-}" == "$want" ]]' '[[ "${argv[0]:-}" == "$want/NDT-GATE-NEVER" ]]'
    gate_mutant gone  window "$WINDOW" '( cd "$dir" && exec -a "$want" sleep "$FIXTURE_TTL" )' '( cd "$dir" && exit 0 )'
    gate_mutant subshell window "$WINDOW" 'spawn_fixture "$SIM_ARGV"; SIMFIX="$FIXTURE_PID"' '( spawn_fixture "$SIM_ARGV"; SIMFIX="$FIXTURE_PID" )'
fi
if selected topo_pid; then
    gate_control topo_pid
    gate_mutant never topo_pid "$TOPO_PID" '[[ "${argv[0]:-}" == "$want" ]]' '[[ "${argv[0]:-}" == "$want/NDT-GATE-NEVER" ]]'
    gate_mutant gone  topo_pid "$TOPO_PID" '( exec -a "$want" sleep "$FIXTURE_TTL" )' '( exit 0 )'
    gate_mutant subshell topo_pid "$TOPO_PID" 'spawn "$DECOYP"; DECOY="$FIXTURE_PID"' '( spawn "$DECOYP"; DECOY="$FIXTURE_PID" )'
fi
if selected ovs_claim; then
    gate_control ovs_claim
    gate_mutant never ovs_claim "$OVS_CLAIM" '[[ "${argv[0]:-}" == "$want" ]]' '[[ "${argv[0]:-}" == "$want/NDT-GATE-NEVER" ]]'
    gate_mutant gone  ovs_claim "$OVS_CLAIM" '( cd "$FIX" && exec -a "$want" sleep 120 )' '( cd "$FIX" && exit 0 )'
    gate_mutant subshell ovs_claim "$OVS_CLAIM" 'spawn "some-unrelated-program"; STRANGER="$FIXTURE_PID"' '( spawn "some-unrelated-program"; STRANGER="$FIXTURE_PID" )'
fi
if selected down; then
    gate_control down
    gate_mutant never down "$DOWN" '[[ "${argv[0]:-}" == "$want" ]]' '[[ "${argv[0]:-}" == "$want/NDT-GATE-NEVER" ]]'
    gate_mutant gone  down "$DOWN" "exec -a '\$want' sleep \$FIXTURE_TTL" 'exit 0'
    gate_mutant subshell down "$DOWN" 'spawn "$OURS_ARGV" "$FIX"; OURS="$FIXTURE_PID"' '( spawn "$OURS_ARGV" "$FIX"; OURS="$FIXTURE_PID" )'
fi

echo
echo "$MUTATIONS mutation(s), $SURVIVORS survivor(s); $COUNT_BAD control(s) whose premise count is not its call-site count"
(( SURVIVORS == 0 && COUNT_BAD == 0 ))
