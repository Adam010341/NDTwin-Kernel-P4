#!/usr/bin/env bash
#
# Tests for G-9: ndtwin-lab's orphan sweep, after `pkill -f` was taken out of it.
#
# [Co-developed with claude code -- Adam]
#
# `pkill -f <pattern>` signals every process whose WHOLE COMMAND LINE contains the pattern. The
# project's rule against it (CLAUDE.md) is not stylistic -- it has three distinct failure modes
# and this repo has been bitten by each:
#
#   1. it matches the searcher, and its shell, and that shell's parent. A guard that finds itself
#      cannot tell "X is running" from "I am looking for X". lib_e.sh's iperf3 guard, ndt's
#      header trap notes 1-2, and tools/p4_power_helper.py all carry the same lesson.
#   2. it matches mentions: an echo, a log filename, an editor with the file open.
#   3. it signals without verifying -- that the thing that matched was meant, that it died, or
#      that the pid was not recycled into a stranger in between.
#
# So the properties under test are the three things a REPLACEMENT has to do that `pkill -f`
# cannot, and each check below is written so that the old behaviour fails it:
#
#     a. a process is identified by an argv ELEMENT being the program, not by the pattern
#        occurring somewhere in the line;
#     b. the sweeper, its shell and its ancestors are never candidates -- while a process that
#        merely shares their process group still is, because that one is a real target;
#     c. what was signalled is re-read from /proc afterwards, and a survivor is reported as a
#        survivor rather than as "cleanup done".
#
# Safety on a shared machine -- this suite is run while another session holds the lab claim:
#
#   * it NEVER calls the `cleanup` verb, never runs mn -c, and never touches tmux. Only the
#     sweep functions are exercised, sourced out of the script;
#   * sweep_ps_snapshot is replaced everywhere a check could signal, so the candidate list is
#     bounded to this suite's own fixtures; the verdict on each candidate is still the real /proc;
#   * fixtures wear /nonexistent/NDT-TEST-FIXTURE/... argv0s, so a leaked one cannot be mistaken
#     for a real switch or topology by a human, by `ndt status`, or by a later sweep;
#   * the suite reaps its own fixtures and asserts that it did.
#
# Run:  bash tests/shell/test_ndtwin_lab_sweep.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$HERE/../../tools/test_workflow/ndtwin-lab"

PASS=0
FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ok       $what"; PASS=$((PASS + 1))
    else
        echo "  FAILED   $what"
        echo "             expected: $expected"
        echo "             actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}
yn()  { if "$@"; then echo yes; else echo no; fi; }
has() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }

# Sourced, not run: the script returns before its root guard and before its dispatch, so this
# defines the sweep functions as an ordinary user and no verb can fire.
# shellcheck source=/dev/null
source "$LAB" || { echo "  FAILED   could not source $LAB"; echo "Ran 1 checks, 1 failed"; exit 1; }

check "sourcing it as a non-root user is allowed"  1 "$NDTWIN_LAB_SOURCED"

TMPROOT="$(mktemp -d /tmp/ndtwin-lab-sweep-XXXXXX)"
FIXTURE_REG="$TMPROOT/fixtures"
: > "$FIXTURE_REG"
FIXTURE_TTL=120

reap_fixtures() {
    local pid left=0
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == sleep ]] || continue
        kill -KILL "$pid" 2>/dev/null
    done < "$FIXTURE_REG"
    sleep 0.3
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == sleep ]] && left=$((left + 1))
    done < "$FIXTURE_REG"
    echo "$left"
}
cleanup_fixtures() {
    [[ -f "$FIXTURE_REG" ]] && reap_fixtures >/dev/null
    [[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/ndtwin-lab-sweep-* ]] && rm -rf "$TMPROOT"
    return 0
}
trap cleanup_fixtures EXIT INT TERM

# spawn_fixture <argv0> -- a real process wearing that command line; echoes its pid.
#
# argv0 only: the fixture is a `sleep`, and every extra argument would have to be a duration for
# it to survive. That is not a limitation here -- argv0 is exactly where the identity question
# lives, and a decoy carries its mention in argv0 too.
spawn_fixture() {
    local want="$1" pid i
    local -a argv=()
    ( exec -a "$want" sleep "$FIXTURE_TTL" ) >/dev/null 2>&1 </dev/null &
    pid=$!
    echo "$pid" >> "$FIXTURE_REG"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        argv=()
        mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null
        [[ "${argv[0]:-}" == "$want" ]] && { echo "$pid"; return 0; }
        sleep 0.1
    done
    echo "  FAILED   fixture never took argv0=$want (pid $pid)" >&2
    echo "Ran $((PASS + FAIL + 1)) checks, $((FAIL + 1)) failed"
    exit 1
}

SW=simple_switch_grpc
TOPO=ntg_bmv2_topo.py
NTG="Network-Traffic-Generator/testbed_topo.py"

FIX_SW="/nonexistent/NDT-TEST-FIXTURE/bin/$SW"
FIX_TOPO="/nonexistent/NDT-TEST-FIXTURE/$TOPO"
FIX_NTG="/nonexistent/NDT-TEST-FIXTURE/$NTG"
FIX_OTHER_TESTBED="/nonexistent/NDT-TEST-FIXTURE/p4_proxy/mininet/testbed_topo.py"

# --- 1. identity, decided argument-wise -----------------------------------------------
#
# sweep_matches is the whole difference from `pkill -f`, so it is tested directly and on the
# exact command lines that made `pkill -f` wrong.
echo "identity (an argv element IS the program; a mention is not)"

check "a compiled switch by absolute path"   yes "$(yn sweep_matches "$SW" "/usr/local/bin/$SW" --name s1)"
check "an interpreted topo as argv[1]"       yes "$(yn sweep_matches "$TOPO" /usr/bin/python3 "/home/adam/x/$TOPO")"
check "the path-suffix form"                 yes "$(yn sweep_matches "$NTG" python "/home/adam/$NTG")"

check "an echo that MENTIONS a switch"       no  "$(yn sweep_matches "$SW" bash -c "echo restarting $SW now")"
check "a log file named after the topo"      no  "$(yn sweep_matches "$TOPO" tail -f "/var/log/$TOPO.log")"
check "an editor holding the file open"      no  "$(yn sweep_matches p4_testbed_topo.py vim notes-p4_testbed_topo.py.bak)"
check "the operator's own cleanup command"   no  "$(yn sweep_matches "$SW" sudo ndtwin-lab cleanup)"
check "a different testbed_topo.py"          no  "$(yn sweep_matches "$NTG" python "$FIX_OTHER_TESTBED")"
check "no argv at all"                       no  "$(yn sweep_matches "$SW")"

# --- 2. the real machine, read-only ----------------------------------------------------
#
# Real ps, no stub, one-directional: "the fixture I started is found" and "the decoy I started
# is not". Both stay true however busy the machine is, so a live round cannot turn this red.
echo "machine-wide scan (real ps, read-only)"

SWFIX="$(spawn_fixture "$FIX_SW")"
# The decoy's command line CONTAINS both patterns -- `pkill -f simple_switch_grpc` and
# `pkill -f ntg_bmv2_topo.py` would each signal it -- while no argv element IS either program.
DECOY_ARGV0="/nonexistent/NDT-TEST-FIXTURE/bin/reporter-restarting-$SW-and-$TOPO"
DECOY="$(spawn_fixture "$DECOY_ARGV0")"

check "the real scan finds the switch fixture"  yes "$(has "$SWFIX" $'\n'"$(sweep_find "$SW")"$'\n')"
check "the real scan does not find the decoy"   no  "$(has "$DECOY" $'\n'"$(sweep_find "$SW")"$'\n')"
check "the real scan does not find this shell"  no  "$(has "$$" $'\n'"$(sweep_find "$SW")"$'\n')"

# --- 3. the sweeper cannot sweep itself ------------------------------------------------
#
# The candidate list is bounded from here on. This shell is INJECTED into it wearing the
# pattern, which is precisely what happens to an operator who typed the pattern: `pkill -f`
# signals them. The ancestor chain must drop it -- and must NOT drop the fixture, which is a
# child of this shell and a legitimate target.
echo "self-match (the failure that makes a guard report a clean machine)"

SNAP_LINES=""
sweep_ps_snapshot() { printf '%s\n' "$SNAP_LINES"; }

# A sweeper whose OWN command line is the thing it is looking for. This is not contrived: it is
# `sudo ndtwin-lab cleanup` typed into a shell that has the pattern in its argv, and it is the
# case `pkill -f` gets wrong every time -- it signals that shell. Injecting a fake ps line is not
# enough to test it, because /proc is the authority and /proc would disagree; the scanner here
# therefore really wears the switch's argv0, so /proc really does say it is a switch. Only the
# self/ancestor exclusion can save it.
cat > "$TMPROOT/scan.sh" <<'SCANEOF'
source "$1" || exit 9
# Bound to exactly two candidates: this process and its parent. Both are real pids whose real
# /proc will be read; nothing else on the machine is reachable from here.
#
# The args column must CARRY the pattern. ps is the prefilter, so a candidate whose args do not
# mention it is dropped before the self-exclusion is ever consulted -- and then deleting the
# exclusion would not change the answer, which is a check that cannot fail. Measured: it could
# not, until this line was fixed, and the mutation gate is what said so.
PAT="$2"
sweep_ps_snapshot() {
    printf '%s %s\n%s %s\n' \
        "$$"    "/nonexistent/NDT-TEST-FIXTURE/bin/$PAT --name self" \
        "$PPID" "/nonexistent/NDT-TEST-FIXTURE/bin/$PAT --name parent"
}
echo "SELF=$$"
echo "PARENT=$PPID"
echo "FOUND=$(sweep_find "$2" | tr '
' ',')"
SCANEOF

# Case A: the scanner itself wears the pattern.
selfout="$( exec -a "$FIX_SW" bash "$TMPROOT/scan.sh" "$LAB" "$SW" 2>&1 )"
self_pid="$(sed -n 's/^SELF=//p' <<<"$selfout")"
self_found="$(sed -n 's/^FOUND=//p' <<<"$selfout")"
check "the scanner really looks like a switch" yes "$(yn test -n "$self_pid")"
check "and it does not find ITSELF"            no  "$(has "$self_pid," ",$self_found")"

# Case B: the pattern is on an ANCESTOR, not on the scanner -- the operator's shell, one level
# up. $$ and $PPID alone would still catch this one; two levels up is what needs the walk, and
# the walk is what is being exercised.
cat > "$TMPROOT/parent.sh" <<'PARENTEOF'
exec bash "$1" "$2" "$3"
PARENTEOF
# `; exit $?` is load-bearing. bash -c with a single simple command EXECS it instead of forking,
# so `bash -c 'bash ...'` replaces the argv0-wearing shell with the scanner and there is no
# matching ancestor left to exclude -- the check would pass for the wrong reason, and it did
# until the mutation gate reported the mutation as surviving.
ancout="$( exec -a "$FIX_SW" bash -c 'bash "$0" "$1" "$2"; exit $?' "$TMPROOT/scan.sh" "$LAB" "$SW" 2>&1 )"
anc_parent="$(sed -n 's/^PARENT=//p' <<<"$ancout")"
anc_found="$(sed -n 's/^FOUND=//p' <<<"$ancout")"
check "a matching ANCESTOR is not a candidate" no  "$(has "$anc_parent," ",$anc_found")"

# ...while a process that merely shares the group IS one: excluding the process group instead of
# the ancestor chain would make cleanup silently skip a switch started from the same terminal.
SNAP_LINES="$(printf '%s %s' "$SWFIX" "$FIX_SW --name s1")"
found="$(sweep_find "$SW")"
check "the real switch fixture still is found"  yes "$(has "$SWFIX" $'\n'"$found"$'\n')"
check "  even though it shares our group"       yes "$(yn test "$(ps -o pgid= -p $$ | tr -d ' ')" = "$(ps -o pgid= -p "$SWFIX" | tr -d ' ')")"

# --- 4. counting -----------------------------------------------------------------------
#
# `pgrep -c -f X` counts the pgrep itself, so an empty machine reports 1. The status line read
# that number out loud.
echo "counting (what 'ndtwin-lab status' prints)"

SNAP_LINES="$(printf '%s %s' "$$" "bash tests/shell/test_ndtwin_lab_sweep.sh $SW")"
check "no switches, and we are looking -> 0"   0 "$(sweep_count "$SW")"

SWFIX2="$(spawn_fixture "/nonexistent/NDT-TEST-FIXTURE/bin2/$SW")"
SNAP_LINES="$(printf '%s %s\n%s %s\n%s %s' \
    "$$"      "bash tests/shell/test_ndtwin_lab_sweep.sh $SW" \
    "$SWFIX"  "$FIX_SW --name s1" \
    "$SWFIX2" "/nonexistent/NDT-TEST-FIXTURE/bin2/$SW --name s2")"
check "two switches, and we are looking -> 2"  2 "$(sweep_count "$SW")"

# --- 5. signalling, and reading /proc afterwards ---------------------------------------
echo "kill (what actually happened, not what was requested)"

TOPOFIX="$(spawn_fixture "$FIX_TOPO")"
SNAP_LINES="$(printf '%s %s\n%s %s' \
    "$TOPOFIX" "$FIX_TOPO" \
    "$DECOY"   "$DECOY_ARGV0")"

out="$(sweep_kill topo "$TOPO" 2>&1)"; rc=$?
check "killing a real topo -> rc 0"            0 "$rc"
check "  it names the pid it stopped"          yes "$(has "stopped        topo pid $TOPOFIX" "$out")"
check "  and /proc agrees it is gone"          no  "$(yn sweep_alive "$TOPOFIX" "$TOPO")"
check "  the decoy was left alone"             yes "$(yn sweep_alive "$DECOY" "${DECOY_ARGV0##*/}")"

SNAP_LINES=""
out="$(sweep_kill topo "$TOPO" 2>&1)"; rc=$?
check "nothing to kill -> rc 0"                0 "$rc"
check "  and it says 'none', not 'done'"       yes "$(has "none           topo" "$out")"

# A survivor must be reported as a survivor. pid 1 can never be signalled by this suite and is
# never a candidate, so the unkillable case is exercised through sweep_alive's own contract
# instead of by trying to make a real process ignore SIGKILL.
check "a pid that does not exist is not alive" no  "$(yn sweep_alive 999999 "$TOPO")"
check "a live pid that is not the program"     no  "$(yn sweep_alive "$DECOY" "$TOPO")"

# --- 6. this suite does not become the thing it tests ----------------------------------
echo "the suite reaps its own fixtures"
check "no fixture survives this run"           0 "$(reap_fixtures)"

echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
