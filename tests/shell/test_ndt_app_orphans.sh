#!/usr/bin/env bash
#
# Tests for ndt's three-state app stop: running / not-running / pidfile-lost-but-alive.
#
# [Co-developed with claude code -- Adam]
#
# What went wrong, measured live 2026-08-31 (doc/KNOWN-ISSUES.md §G): the previous session's
# TE-App sat in a crash loop for 20h07m02s and every interface agreed it was not there --
# `ndt status` said "apps none running", `ndt apps` said "te -", and `ndt apps stop te` returned
# 0 with the message "te not running". All three read one predicate whose only witness was
# .test_run/pids/app_te.pid, and the crash had taken the pidfile with it. An app that is
# invisible is also unkillable.
#
# The duration is the crash loop's, measured from the log's own timestamps before the 100 MB
# file was deleted. That day's orphan installed no flow rules either -- every error in the file is
# ":8000 connection refused" -- so what makes it worth a test suite is that it was unstoppable,
# not what it did.
#
# So the property under test is not "does stop kill a pid" but "can stop tell a machine with no
# app on it from a machine whose app it has lost track of". A test that only ever runs against a
# clean machine cannot see the difference -- it passes either way -- which is why every check
# below that asserts NOTHING is there is paired with one that asserts the scan ran (group 3) and
# one that puts a real process there and demands it be found (group 2).
#
# How the fixtures work, and why they are safe on a shared machine:
#
#   * A fixture is `( exec -a "<fake argv0>" sleep N )&`. exec keeps the pid from subshell to
#     sleep, so the pid really is the process wearing the fake command line, and /proc/<pid>/
#     cmdline really does read like a TE-App. Nothing is stubbed on the identity side: every
#     check below goes through the real /proc.
#   * REPO is redirected to a temp dir before anything runs, so no real .test_run/pids/ file is
#     read, written or deleted. (There is a real stale one on this machine -- app_viz.pid has
#     named a dead pid since 08-30 -- and this suite must not touch it.)
#   * Every check that can SIGNAL something replaces app_ps_snapshot with a fixed list holding
#     only this test's own fixtures, so a unit test can never reach a real app on the machine it
#     is running on. The identity check still reads real /proc; only the candidate list is bounded.
#   * The checks that use the real machine-wide ps are read-only and one-directional: "the
#     fixture I just started is in the result" and "the decoy I just started is not". Both are
#     true whatever else is running, so a busy machine cannot turn this suite red.
#
# Run:  bash tests/shell/test_ndt_app_orphans.sh
set -uo pipefail

export NO_COLOR=1                     # deterministic output to match on
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Env:  NDT_UNDER_TEST=<path>   -- point it at a copy to watch this suite go red. Added
# 2026-09-12: section 10's red is a one-line edit to `ndt`'s fail-closed branch,
# and a red nobody can reproduce from the repo is a red that exists only in a log.
NDT="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"

PASS=0
FAIL=0
check() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ok       $what"
        PASS=$((PASS + 1))
    else
        echo "  FAILED   $what"
        echo "             expected: $expected"
        echo "             actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}
yn() { if "$@"; then echo yes; else echo no; fi; }
has() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }

# ndt returns early when sourced (same seam as stack.sh:925), so this defines its functions
# without dispatching on argv.
# shellcheck source=/dev/null
source "$NDT" || { echo "  FAILED   could not source $NDT"; echo "Ran 1 checks, 1 failed"; exit 1; }

TMPROOT="$(mktemp -d /tmp/ndt-app-orphans-XXXXXX)"
# [Co-developed with claude code -- Adam] 🔴 THIS SUITE'S OWN sudo (2026-09-27): every sudo it
# makes is recorded and REFUSED rc 1 in sudo's own words, whatever this machine's grants or lab --
# the ANSWERS are fixed, and nothing it runs reaches root. Its PATH through ndt is not: ps,
# command -v, the lab ports, curl :8000 and the p4 manifest still decide which probes it makes
# (tests/shell/lib_probe_stub.sh, "WHAT THE STUB FIXES"). The closing check fails on any call
# outside the allow-list, and on a sudo on PATH that is not this stub.
# (from this file's own directory: a suite that sources ndt first has had its HERE replaced by
# ndt's -- the first version of this line found no lib there and the stub never ran)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_probe_stub.sh" \
    || { echo "  FAILED   no tests/shell/lib_probe_stub.sh beside this suite"; echo "Ran 1 checks, 1 failed"; exit 1; }
probe_stub_install "$TMPROOT" -- 'sudo ndtwin-lab status'
REPO="$TMPROOT"                       # every app_pidfile call now lands here, not in the workspace
PIDDIR="$TMPROOT/.test_run/pids"
mkdir -p "$PIDDIR"

FIXTURE_TTL=90                        # self-reaps even if this script is SIGKILLed
# The fixture register is a FILE, not an array. spawn_fixture was called from inside a command
# substitution until 2026-09-28, so `FIXTURE_PIDS+=(...)` appended in a subshell and the parent's
# trap saw an empty list -- measured here: an earlier draft leaked every fixture it started, and
# `ndt apps orphans` found fourteen of them still running. A suite that tests orphan detection
# must not be a source of orphans.
FIXTURE_REG="$TMPROOT/fixtures"
: > "$FIXTURE_REG"

# reap_fixtures -- kill every fixture this run started; echo how many are still alive after.
reap_fixtures() {
    local pid left=0
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        # Identity before signal, the same rule the code under test follows: only ever kill
        # something that is still the `sleep` this script started.
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
    # [Co-developed with claude code -- Adam] First, so a second signal cannot cut the cleaning
    # short (2026-10-03): an INT or TERM arriving in here would run its trap, and the shell would
    # exit with the rest of this undone.
    # The price: a signal that lands while a run that was ending anyway cleans up is ignored,
    # and that run still ends 0 or 1, not 130 or 143.
    trap '' INT TERM
    [[ -f "$FIXTURE_REG" ]] && reap_fixtures >/dev/null
    declare -F reap_hr >/dev/null && reap_hr >/dev/null
    [[ -n "${HR_FIFODIR:-}" && "$HR_FIFODIR" == /tmp/ndt-hr-fifo-* ]] && rm -rf "$HR_FIFODIR"
    [[ -n "${HR_OTHER:-}" && "$HR_OTHER" == /tmp/ndt-hr-other-* ]] && rm -rf "$HR_OTHER"
    [[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/ndt-app-orphans-* ]] && rm -rf "$TMPROOT"
    return 0
}
# [Co-developed with claude code -- Adam] A signal ENDS the run (2026-09-28). The handler used to
# clean up and return, so on INT or TERM the suite went on running with its probe stubs (TMPROOT) deleted,
# and its next sudo went to whatever sudo came next on PATH -- on a machine with a NOPASSWD grant,
# to root. The EXIT trap does the cleaning on the way out; INT and TERM only end the
# run, with the shell's usual 128+signal status.
trap cleanup_fixtures EXIT
# [Co-developed with claude code -- Adam] INT kills the shell with INT again rather than exiting
# 130 (2026-10-03). A shell that EXITS 130 has, as far as a calling bash can tell, handled the
# Ctrl-C itself, so a script running suites one after another (tools/test_workflow/
# l1_unit_tests.sh) went on to the next one. Killed by the signal, this shell still ends with
# 130 and runs its EXIT trap, and the caller stops as well.
trap 'trap - INT; kill -INT $$' INT
trap 'exit 143' TERM

# spawn_fixture <argv0> [cwd] -- start a process wearing that command line; its pid is left in
# FIXTURE_PID.
#
# Asserts its own success before returning. A fixture that silently failed to take the fake argv
# would make every "not found" check below pass for the wrong reason, which is the one way this
# suite could go green while testing nothing.
#
# [Co-developed with claude code -- Adam]
# 🔴 C10-8 (2026-09-12): the working directory is now part of the fixture, because it is part of
# the ANSWER. `ndt` asks of every pid the machine-wide scan produces whether it belongs to this
# checkout (proc_checkout), and a fixture inherits the cwd of whoever started it -- which for
# this suite is whatever tree it was launched from. Defaulting to $TMPROOT, the REPO every check
# below runs against, is what makes these fixtures orphans OF THIS CHECKOUT; section 8 passes a
# directory outside it on purpose and is the control for the other side.
#
# [Co-developed with claude code -- Adam]
# 🔴 CALLED AS A PLAIN COMMAND, NEVER AS X="$(spawn_fixture ...)" (2026-09-28). Inside a command
# substitution the `exit 1` below left only that subshell: the suite ran on with the helper's own
# summary text where a pid should be, and the FAILED line was never counted -- measured on 3368412d
# by tests/shell/mutate_fixture_spawn_helpers.sh, 59 FAILED lines under "Ran 104 checks, 52 failed".
# The premise is now a check THIS shell counts, on success too, and a failure ends the run with its
# summary. The poll waits up to FIXTURE_ARGV_WAIT seconds rather than one: a slow exec on a loaded
# machine is not a defect in the code under test.
FIXTURE_ARGV_WAIT=30
FIXTURE_PID=""
spawn_fixture() {
    # [Co-developed with claude code -- Adam] In this shell or not at all (2026-10-01). FIXTURE_PID,
    # the premise check and the `exit 1` below mean something only in the suite's own shell; a call
    # from a ( ... ), a pipeline or a $( ) spread over several lines -- forms a read of the source
    # does not see -- would keep all three in a subshell. So such a call ends the run, loudly.
    [[ $BASHPID == "$$" ]] || { echo "  FAILED   ${FUNCNAME[0]} called outside this suite's own shell (BASHPID $BASHPID, suite $$): ending the run" >&2; kill -TERM "$$"; exit 1; }
    local want="$1" dir="${2:-$TMPROOT}" pid deadline
    local -a argv=()
    FIXTURE_PID=""
    # Started from a command substitution of its own, so the fixture is never a job of this shell.
    # The redirections are load-bearing, not tidiness: a background child that inherits that
    # substitution's pipe keeps it open, and the caller blocks for the fixture's whole lifetime
    # (measured here -- the first draft hung for FIXTURE_TTL seconds per fixture and had to be
    # killed). The pid is registered INSIDE the substitution (2026-10-01): a signal sent to THIS
    # shell while the substitution runs is handled after it returns, and by then the EXIT trap's
    # register already holds the pid; registered after the assignment, it could be lost. Not
    # closed: a signal sent to the whole process group (a Ctrl-C) also reaches the substitution's
    # own subshell, which can die between starting the fixture and writing its pid -- a window
    # under a millisecond. A fixture in this shell's group usually dies of that same Ctrl-C; one
    # in a session of its own (setsid) does not, and is then left to its TTL.
    pid="$( ( cd "$dir" && exec -a "$want" sleep "$FIXTURE_TTL" ) \
            >/dev/null 2>&1 </dev/null & echo "$!" >> "$FIXTURE_REG"; echo "$!" )"
    deadline=$(( SECONDS + FIXTURE_ARGV_WAIT ))
    while :; do
        argv=()
        mapfile -d '' -t argv 2>/dev/null < "/proc/$pid/cmdline" || true
        if [[ "${argv[0]:-}" == "$want" ]]; then
            check "fixture took argv0=$want" "$want" "${argv[0]}"
            FIXTURE_PID="$pid"
            return 0
        fi
        (( SECONDS < deadline )) || break
        sleep 0.1
    done
    check "fixture took argv0=$want" "$want" \
          "${argv[0]:-nothing readable} (pid $pid, after ${FIXTURE_ARGV_WAIT}s)"
    echo
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
}

TE_SIG=Traffic-engineering-App.py
# A plausible orphan: the shape app_spawn leaves behind, with an unmistakable path so that a
# leaked fixture cannot be mistaken for a real TE-App by a human or by `ndt status`.
FIX_ARGV="python3 /nonexistent/NDT-TEST-FIXTURE/$TE_SIG"
# A decoy that MENTIONS the signature without being it -- the shape that made the first draft of
# app_scan_pids match every fork of its own shell (2026-08-31, reproduced before it shipped).
DECOY_ARGV="bash -c echo restarting $TE_SIG now"

# --- 1. identity: /proc decides, and it decides argument-wise ----------------------
echo "identity (pid_is_app reads /proc; a mention is not a match)"

spawn_fixture "$FIX_ARGV"; FIX="$FIXTURE_PID"
spawn_fixture "$DECOY_ARGV"; DECOY="$FIXTURE_PID"
spawn_fixture "sleep-with-no-signature-at-all"; PLAIN="$FIXTURE_PID"

check "the fixture is te"                        yes "$(yn pid_is_app "$FIX" te)"
check "the fixture is NOT nsr"                   no  "$(yn pid_is_app "$FIX" nsr)"
check "a command line that only MENTIONS te is not te" no "$(yn pid_is_app "$DECOY" te)"
check "an unrelated process is not te"           no  "$(yn pid_is_app "$PLAIN" te)"
check "a pid that does not exist is not te"      no  "$(yn pid_is_app 999999 te)"
check "pid 1 is refused outright"                no  "$(yn pid_is_app 1 te)"
check "an empty pid is refused"                  no  "$(yn pid_is_app '' te)"

# --- 2. the scan finds a real process on the real machine -------------------------
#
# Real ps, no stub. One-directional so that whatever else is running cannot change the answer.
echo "machine-wide scan (real ps, read-only)"

scan="$(app_scan_pids te)"
check "real scan finds the live fixture"         yes "$(has "$FIX" $'\n'"$scan"$'\n')"
check "real scan does not report the decoy"      no  "$(has "$DECOY" $'\n'"$scan"$'\n')"
check "real scan does not report this shell"     no  "$(has "$$" $'\n'"$scan"$'\n')"

# --- 3. the three states ----------------------------------------------------------
#
# From here on app_ps_snapshot is replaced, so nothing outside this test's own fixtures can be
# reached. The verdict on each candidate is still the real /proc.
echo "three states"

SNAPSHOT_LINES=""
# The call counter goes to a FILE, not a variable. app_scan_pids reads the snapshot through
# `< <(app_ps_snapshot)`, and process substitution runs in a subshell, so a variable incremented
# inside it never reaches this shell -- the first draft of the group-4 control read 0 for every
# call and would have reported "the scan never ran" no matter what the code did.
SNAPSHOT_LOG="$TMPROOT/snapshot-calls"
: > "$SNAPSHOT_LOG"
app_ps_snapshot() {
    echo x >> "$SNAPSHOT_LOG"
    # printf with a trailing newline: `while read` never runs its body for an unterminated last
    # line, so a stub that omits it silently presents an EMPTY machine to the code under test.
    [[ -n "$SNAPSHOT_LINES" ]] && printf '%s\n' "$SNAPSHOT_LINES"
    return 0
}
snapshot_calls() { wc -l < "$SNAPSHOT_LOG" | tr -d ' '; }
fix_line() { printf '%s %s' "$1" "$2"; }

rm -f "$PIDDIR/app_te.pid"
SNAPSHOT_LINES=""
app_probe te
check "no pidfile, nothing alive -> not-running"  not-running "$APP_STATE"
check "  and it names no pids"                    0 "${#APP_LIVE_PIDS[@]}"

SNAPSHOT_LINES="$(fix_line "$FIX" "$FIX_ARGV")"
app_probe te
check "no pidfile, one alive -> pidfile-lost-but-alive" pidfile-lost-but-alive "$APP_STATE"
check "  and it names the live pid"               "$FIX" "${APP_LIVE_PIDS[*]}"

echo "$FIX" > "$PIDDIR/app_te.pid"
app_probe te
check "pidfile names the live one -> running"     running "$APP_STATE"
check "  and it names it once, not twice"         "$FIX" "${APP_LIVE_PIDS[*]}"

echo 999999 > "$PIDDIR/app_te.pid"
app_probe te
check "stale pidfile + live orphan -> pidfile-lost-but-alive" pidfile-lost-but-alive "$APP_STATE"
check "  and it names the orphan, not the stale pid" "$FIX" "${APP_LIVE_PIDS[*]}"

SNAPSHOT_LINES=""
app_probe te
check "stale pidfile, nothing alive -> not-running" not-running "$APP_STATE"

# A pid that exists but is somebody else -- the recycled-pid case. The old app_stop sent SIGTERM
# to whatever number the pidfile held, without ever asking what it was.
echo "$PLAIN" > "$PIDDIR/app_te.pid"
app_probe te
check "pidfile names a LIVE stranger -> not-running" not-running "$APP_STATE"
check "  and the stranger is not on the kill list" 0 "${#APP_LIVE_PIDS[@]}"

ln -sf /etc/hostname "$PIDDIR/app_te.pid"
SNAPSHOT_LINES="$(fix_line "$FIX" "$FIX_ARGV")"
app_probe te
check "symlinked pidfile + live app -> pidfile-lost-but-alive" pidfile-lost-but-alive "$APP_STATE"
check "  the link is not followed"                "$FIX" "${APP_LIVE_PIDS[*]}"
rm -f "$PIDDIR/app_te.pid"

# --- 4. the scan really runs (the force-green control) ----------------------------
#
# Every "not-running" check above would also pass if app_probe had quietly stopped scanning --
# which is the shape of half the failures in this repo's history. This is the check that tells
# "nothing found" from "nothing looked".
echo "the scan is actually executed on the negative path"

SNAPSHOT_LINES=""
: > "$SNAPSHOT_LOG"
app_probe te
check "not-running, and the scan ran anyway"      not-running "$APP_STATE"
check "  the process snapshot was taken"          yes "$( (( $(snapshot_calls) >= 1 )) && echo yes || echo no)"

: > "$SNAPSHOT_LOG"
app_stop te >/dev/null 2>&1
check "stop's not-running path also scans"        yes "$( (( $(snapshot_calls) >= 1 )) && echo yes || echo no)"

# --- 5. stop -- the state that used to report success while the app ran -----------
echo "stop"

# [Co-developed with claude code -- Adam]
# 2026-09-02, G-6: this check asserted rc 0 and now asserts rc 2. It is not a test being
# weakened -- it is the contract changing, and this line is where the old contract was written
# down. app_stop's "there was nothing to stop" used to be indistinguishable from "it was
# running and now is not", which is how a live teardown recorded APPS_STOP_ALL_RC=0 for a
# teardown that stopped three of five apps. The prose here was already honest; only the exit
# code was not, and a driver script reads the exit code.
SNAPSHOT_LINES=""
rm -f "$PIDDIR/app_te.pid"
out="$(app_stop te 2>&1)"; rc=$?
check "nothing running -> rc 2 (was 0 before G-6)" 2 "$rc"
check "  says not running"                        yes "$(has "not running" "$out")"
# [Co-developed with claude code -- Adam]
# 2026-09-03, with the apps-stop fix: this sentence grew from two witnesses to four, and
# it is pinned here because it IS the contract -- "not running" has to say what it looked at.
# The old wording was true by its own lights and still wrong: "no live instance found by pid or
# by scan" was printed on 09-02 while two JVMs ran for another 1h54m, because a pid and an argv
# are the two things a reparented child is invisible to. The process group and the log's writers
# are the two that would have seen them.
check "  and says how it knows"                   yes "$(has "nothing found by pid, by scan, by process group or by log" "$out")"

spawn_fixture "python3 /nonexistent/NDT-TEST-FIXTURE-VICTIM/$TE_SIG"; VICTIM="$FIXTURE_PID"
SNAPSHOT_LINES="$(fix_line "$VICTIM" "python3 /nonexistent/NDT-TEST-FIXTURE-VICTIM/$TE_SIG")"
rm -f "$PIDDIR/app_te.pid"
out="$(app_stop te 2>&1)"; rc=$?
check "pidfile lost, app alive -> rc 0"           0 "$rc"
check "  names the state"                         yes "$(has "pidfile-lost-but-alive" "$out")"
check "  does NOT claim it is not running"        no  "$(has "te not running" "$out")"
check "  names the pid it found"                  yes "$(has "$VICTIM" "$out")"
check "  the process is actually gone"            no  "$(yn pid_is_app "$VICTIM" te)"

# The recycled-pid case again, this time through the killing path: a stale pidfile pointing at a
# live stranger must not get that stranger signalled.
echo "$PLAIN" > "$PIDDIR/app_te.pid"
SNAPSHOT_LINES=""
out="$(app_stop te 2>&1)"; rc=$?
# rc 2 for the same reason as above: the stranger is not this app, so nothing was stopped.
check "stale pidfile naming a stranger -> rc 2"   2 "$rc"
check "  the stranger is still alive"             yes "$(yn test -d "/proc/$PLAIN")"
check "  and the bad pidfile was discarded"       no  "$(yn test -e "$PIDDIR/app_te.pid")"

# A poisoned pidfile must not be followed, must not be deleted -- and must no longer stop the
# app from being found. The old code returned 1 here before looking at anything, so the live app
# survived behind the bad link.
spawn_fixture "python3 /nonexistent/NDT-TEST-FIXTURE-LINKED/$TE_SIG"; VICTIM2="$FIXTURE_PID"
SNAPSHOT_LINES="$(fix_line "$VICTIM2" "python3 /nonexistent/NDT-TEST-FIXTURE-LINKED/$TE_SIG")"
ln -sf /etc/hostname "$PIDDIR/app_te.pid"
out="$(app_stop te 2>&1)"; rc=$?
check "symlinked pidfile -> rc 1 (still poisoned)" 1 "$rc"
check "  says it is a symlink"                    yes "$(has "is a symlink" "$out")"
check "  the link is left for the operator"       yes "$(yn test -L "$PIDDIR/app_te.pid")"
check "  and /etc/hostname was not read as a pid" no  "$(has "$(cat /etc/hostname)" "$out")"
check "  but the app was still stopped"           no  "$(yn pid_is_app "$VICTIM2" te)"
rm -f "$PIDDIR/app_te.pid"

# --- 6. the pre-run check ---------------------------------------------------------
echo "apps orphans (the gate a measurement runs before it starts)"

SNAPSHOT_LINES=""
rm -f "$PIDDIR"/app_*.pid
out="$(apps_orphans 2>&1)"; rc=$?
check "clean machine -> rc 0"                     0 "$rc"
check "  and it says so"                          yes "$(has "no untracked app processes" "$out")"

SNAPSHOT_LINES="$(fix_line "$FIX" "$FIX_ARGV")"
out="$(apps_orphans 2>&1)"; rc=$?
check "an untracked app -> rc 1"                  1 "$rc"
check "  names the app"                           yes "$(has "te: pidfile-lost-but-alive" "$out")"
check "  names the pid"                           yes "$(has "$FIX" "$out")"
check "  says how to stop it"                     yes "$(has "ndt apps stop te" "$out")"

# --- 7. the interfaces that were blind ---------------------------------------------
echo "the three interfaces that all said 'not there'"

out="$(apps_status 2>&1)"
check "apps_status shows ORPHAN, not '-'"         yes "$(has "ORPHAN" "$out")"
check "  and names the pid"                       yes "$(has "$FIX" "$out")"

SNAPSHOT_LINES=""
out="$(apps_status 2>&1)"
check "apps_status is quiet when there is none"   no  "$(has "ORPHAN" "$out")"

# --- 8. the scan is machine-wide, the verdict is this checkout's ------------
#
# [Co-developed with claude code -- Adam]
# Measured 2026-09-12 15:05:14 (the same shape was seen earlier that day, at 05:50).
# Another worktree of this repo was running tests/shell/test_ndt_helper_apps_window.sh, whose
# fixtures wear an app's argv on purpose. `ndt apps orphans` in the MAIN checkout counted them
# as its own -- `VERDICT: NOT CLEAN`, over a lab that was down, clean and bridge-free -- and the
# night's regression grid stopped on it; the same round's `ndt down` printed `!! sim is running
# untracked (pid 1166836) -- stopping it by pid` and tried to kill another tree's test.
#
# So this section has two halves and needs both: a process from another checkout is NOT this
# one's orphan (and is not signalled), AND a genuine orphan of this checkout still is. A
# confinement that swallowed the second would be a worse defect than the one it fixes, which is
# why the discriminating check below puts one of each in the same report.
echo "confinement (another checkout's process is not this checkout's orphan)"

# The rule everything here rests on. The nested case is the one a prefix test gets wrong: every
# wt-* worktree on this machine lives UNDER the main checkout, so "starts with $REPO" says
# "mine" about every other tree.
mkdir -p "$TMPROOT/scratch/wt-other/tests/shell"
printf 'gitdir: /nowhere\n' > "$TMPROOT/scratch/wt-other/.git"
check "a path inside \$REPO is this checkout's"   yes "$(yn path_under_this_checkout "$TMPROOT/tools")"
check "  \$REPO itself is"                        yes "$(yn path_under_this_checkout "$TMPROOT")"
check "a path outside it is not"                  no  "$(yn path_under_this_checkout "/etc/hostname")"
check "a relative path is not a path here"        no  "$(yn path_under_this_checkout "tools/x")"
check "🔴 a path inside a NESTED checkout is not" no  "$(yn path_under_this_checkout "$TMPROOT/scratch/wt-other/tests/shell/t.sh")"
check "  nor the nested checkout's own directory" no  "$(yn path_under_this_checkout "$TMPROOT/scratch/wt-other")"
check "  while the directory above it still is"   yes "$(yn path_under_this_checkout "$TMPROOT/scratch")"

# A fixture that belongs to that other tree: same argv shape as ours, running in ITS directory.
OTHER_ARGV="python3 /nonexistent/NDT-TEST-FIXTURE-OTHERTREE/$TE_SIG"
spawn_fixture "$OTHER_ARGV" "$TMPROOT/scratch/wt-other"; OTHERFIX="$FIXTURE_PID"
check "the other tree's fixture is still te by argv" yes "$(yn pid_is_app "$OTHERFIX" te)"
check "  but proc_checkout says it is not ours"   1   "$(proc_checkout "$OTHERFIX"; echo $?)"
check "  and our own fixture is ours"             0   "$(proc_checkout "$FIX"; echo $?)"

rm -f "$PIDDIR"/app_*.pid
SNAPSHOT_LINES="$(fix_line "$OTHERFIX" "$OTHER_ARGV")"
app_probe te
check "🔴 app_probe does not adopt it"            not-running "$APP_STATE"
check "  and it names no pids"                    0 "${#APP_LIVE_PIDS[@]}"

out="$(apps_orphans 2>&1)"; rc=$?
check "🔴 another checkout's process -> rc 0"     0   "$rc"
check "  the process half is clean"               yes "$(has "no untracked app processes" "$out")"
check "  it is NOT called pidfile-lost-but-alive" no  "$(has "pidfile-lost-but-alive" "$out")"
check "  nor counted as running with nothing tracking it" no "$(has "app(s) are running with nothing tracking them" "$out")"
check "🔴 it is named in a column of its own"     yes "$(has "seen elsewhere (not this checkout)" "$out")"
check "  with its pid"                            yes "$(has "$OTHERFIX" "$out")"
check "  and why it was not counted"              yes "$(has "nothing ties it to" "$out")"
check "  and that this teardown will not stop it" yes "$(has "does not stop them" "$out")"

# The killing half, which is the branch `ndt down` takes for an app it finds untracked
# (cmd_down's [0/3] gate is app_probe, G-6). Nothing may be signalled here.
out="$(app_stop te 2>&1)"; rc=$?
check "🔴 stop has nothing of ours to stop -> rc 2" 2 "$rc"
check "  and the other tree's process is ALIVE"   yes "$(yn test -d "/proc/$OTHERFIX")"
check "  and it is still wearing its own argv"    yes "$(yn pid_is_app "$OTHERFIX" te)"

# 🔴 The discriminator. One report, two processes, two columns: the confinement must not be a
# way of never finding anything.
SNAPSHOT_LINES="$(fix_line "$FIX" "$FIX_ARGV")
$(fix_line "$OTHERFIX" "$OTHER_ARGV")"
out="$(apps_orphans 2>&1)"; rc=$?
check "🔴 ours and theirs together -> rc 1"       1   "$rc"
check "  OURS is the orphan"                      yes "$(has "te: pidfile-lost-but-alive" "$out")"
check "  and the report names our pid"            yes "$(has "$FIX" "$out")"
check "  theirs is in the elsewhere column"       yes "$(has "seen elsewhere (not this checkout): 1 process(es)" "$out")"
check "  and the elsewhere column names theirs"   yes "$(has "$OTHERFIX" "$out")"

# apps_status: the other interface that used to print the same adopted pid.
out="$(apps_status 2>&1)"
check "apps_status reports ours as ORPHAN"        yes "$(has "$FIX" "$out")"

SNAPSHOT_LINES="$(fix_line "$OTHERFIX" "$OTHER_ARGV")"
out="$(apps_status 2>&1)"
check "  and says nothing of theirs"              no  "$(has "ORPHAN" "$out")"

SNAPSHOT_LINES=""
rm -f "$PIDDIR"/app_*.pid

# --- 10. the process nobody could attribute is counted as OURS --------
#
# [Co-developed with claude code -- Adam]
# `proc_checkout` answers 2 -- "could not tell" -- when BOTH
# /proc/<pid>/cwd and /proc/<pid>/fd are unreadable, every caller treats a 2 as ours, and the
# report says so instead of claiming to know. That is the whole of the attribution check's safety side: the apps
# `sudo ndtwin-lab` starts run as root, where both readings are refused, and treating "cannot
# tell" as foreign would hand this checkout a clean verdict over exactly the orphan class it most
# needs to find. Until now it had a red and a green only in tests/shell/test_orphans_verdict.sh
# -- on a SYNTHETIC report, i.e. on the reader's handling of a sentence somebody typed. `ndt`'s
# own branch had never been driven: it needs a candidate process this user may not look inside.
#
# 🔴 NO ROOT, NO NAMESPACE, NO SECOND UID. The two readings are a seam (proc_cwd_link /
# proc_fd_links) and this section replaces them, so the process below is a real live fixture with
# a real /proc entry and only the two channels are blinded. What that costs is stated rather than
# hidden: this section proves what proc_checkout DOES with a blind pair, not that root processes
# produce one -- the second half is an OS fact (measured live on 2026-09-12: `/proc/<pid>/fd of a
# root process could not be read`) and is out of an offline suite's reach.
#
# 🔴 AND IT NEEDS THE DISCRIMINATING CONTROL. "Cannot tell -> ours" and "another tree's -> not
# ours" are two answers to two inputs, and a proc_checkout that answered 2 to everything would
# pass every check in the first group. The control is the same fixture with the seam intact.
echo "fail-closed (a pid nobody could attribute is counted as this checkout's)"

# The fixture's cwd is $TMPROOT -- this checkout -- so with the seam intact it is OURS by cwd.
# Blinding both channels is what makes it the unattributable case rather than a foreign one.
blind_both='proc_cwd_link() { return 1; }; proc_fd_links() { return 2; }'
blind_cwd_only='proc_cwd_link() { return 1; }'
# The whole thing runs in a child shell so the seam never leaks into the sections above or below.
in_ndt() {   # in_ndt <extra shell> <code>  -> its output
    bash -c "source '$NDT' >/dev/null 2>&1
REPO='$TMPROOT'
APP_NAMES='te'
$1
$2" 2>&1
}

check "🔴 both channels blind -> could not tell (rc 2)" 2 \
      "$(in_ndt "$blind_both" "proc_checkout $FIX >/dev/null; echo \$?")"
check "  and it says who owns it was not established" yes \
      "$(has "who owns it was NOT established" "$(in_ndt "$blind_both" "proc_checkout $FIX >/dev/null; printf '%s' \"\$PROC_CHECKOUT_WHY\"")")"
check "  naming the two channels it could not read"   yes \
      "$(has "cannot read /proc/$FIX/cwd or /proc/$FIX/fd" "$(in_ndt "$blind_both" "proc_checkout $FIX >/dev/null; printf '%s' \"\$PROC_CHECKOUT_WHY\"")")"

# 🔴 The half this is FOR: it is counted, not merely described. app_claims_pid answers 0 for a 2,
# and carries the reason so the report can print it.
check "🔴 app_claims_pid COUNTS it as ours"            0 \
      "$(in_ndt "$blind_both" "app_claims_pid te $FIX; echo \$?")"
check "  and records why it could not be established"  yes \
      "$(has "who owns it was NOT established" "$(in_ndt "$blind_both" "app_claims_pid te $FIX; printf '%s' \"\$APP_ATTRIB_BLIND\"")")"
check "  and it is NOT filed under elsewhere"          0 \
      "$(in_ndt "$blind_both" "app_claims_pid te $FIX; echo \${#APP_ELSEWHERE[@]}")"

# 🔴 It reaches the verdict. A fail-closed that stopped at the sentence would be a report that
# says "I could not tell" over a rc 0 -- the could-not-check-looks-clean shape with the sign flipped.
OUT10="$(in_ndt "$blind_both" "app_ps_snapshot() { printf '%s %s\n' $FIX '$FIX_ARGV'; }
rm -f '$PIDDIR'/app_*.pid
apps_orphans; echo \"ORPHANS_RC=\$?\"")"
check "🔴 apps orphans is rc 1 over it"               ORPHANS_RC=1 "$(grep -o 'ORPHANS_RC=[0-9]*' <<<"$OUT10")"
check "  it is the orphan, by name"                   yes "$(has "te: pidfile-lost-but-alive" "$OUT10")"
check "  and the report prints the fail-closed line"  yes "$(has "who owns these could NOT be established, so they are counted as this checkout's" "$OUT10")"
check "  it is not in the elsewhere column"           no  "$(has "seen elsewhere (not this checkout)" "$OUT10")"

# --- the controls. Each one is an input that must NOT produce "could not tell".
spawn_fixture "python3 /nonexistent/NDT-TEST-FIXTURE-BLIND-CONTROL/$TE_SIG" "$TMPROOT/scratch/wt-other"; OTHER10="$FIXTURE_PID"
check "🔴 CONTROL: the same code, seam intact, other tree -> 1" 1 \
      "$(in_ndt "" "proc_checkout $OTHER10 >/dev/null; echo \$?")"
check "  and that one IS filed under elsewhere"        1 \
      "$(in_ndt "" "app_claims_pid te $OTHER10; echo \${#APP_ELSEWHERE[@]}")"
check "  while our own fixture, seam intact, is 0"     0 \
      "$(in_ndt "" "proc_checkout $FIX >/dev/null; echo \$?")"
# 🔴 ONE channel blind is not "could not tell". The fd channel is what attributes our own apps
# (they run from a sibling repo, so cwd is another checkout by design), so a cwd that cannot be
# read must still let the fd answer -- and must still be able to say "not ours" when it does not.
check "🔴 cwd blind, fd readable, other tree -> 1"     1 \
      "$(in_ndt "$blind_cwd_only" "proc_checkout $OTHER10 >/dev/null; echo \$?")"
check "  cwd blind, fd readable, nothing of ours -> 1" 1 \
      "$(in_ndt "$blind_cwd_only" "proc_checkout $FIX >/dev/null; echo \$?")"
check "🔴 cwd blind, but an fd under \$REPO -> ours"   0 \
      "$(in_ndt "$blind_cwd_only
proc_fd_links() { printf '%s\n' /dev/null '$TMPROOT/.test_run/logs/app_te.log'; return 0; }" \
        "proc_checkout $FIX >/dev/null; echo \$?")"
check "  and it says which fd said so"                 yes \
      "$(has "it holds $TMPROOT/.test_run/logs/app_te.log open" "$(in_ndt "$blind_cwd_only
proc_fd_links() { printf '%s\n' /dev/null '$TMPROOT/.test_run/logs/app_te.log'; return 0; }" \
        "proc_checkout $FIX >/dev/null; printf '%s' \"\$PROC_CHECKOUT_WHY\"")")"
# And an fd inside a NESTED checkout is still not ours -- the path rule applies to this channel
# too, which is the one place a `-lname "$REPO/*"` prefilter could quietly get it wrong.
check "🔴 an fd inside a nested checkout is not ours"  1 \
      "$(in_ndt "$blind_cwd_only
proc_fd_links() { printf '%s\n' '$TMPROOT/scratch/wt-other/x.log'; return 0; }" \
        "proc_checkout $FIX >/dev/null; echo \$?")"

# The seam itself, against the real /proc, so that a test which mocks it is still anchored to
# something real: the fixture's own fds and cwd are readable and are what they should be.
check "proc_cwd_link reads the fixture's real cwd"     "$TMPROOT" \
      "$(in_ndt "" "proc_cwd_link $FIX")"
check "proc_fd_links reads its real fds"              0 \
      "$(in_ndt "" "proc_fd_links $FIX >/dev/null; echo \$?")"
check "  and a pid that is gone is 'could not read'"  2 \
      "$(in_ndt "" "proc_fd_links 999999 >/dev/null; echo \$?")"

SNAPSHOT_LINES=""
rm -f "$PIDDIR"/app_*.pid

# --- 11. a program run by hand from examples/ is counted, and `ndt down` names it ------
#
# [Co-developed with claude code -- Adam]
# Measured live on a P4 fabric (the energy-saving example, started by hand per its README, kept
# alive across `ndt down` / `ndt clean` / `ndt up`): `ndt apps orphans` answered CLEAN three
# times over it, and the next fabric was changed by it. `energy_saving_sdk.py` carries none of
# the five app signatures, so no channel above could have seen it. The cells below are HR1-HR6.
#
# 🔴 REAL PROCESSES WITH REAL ARGV. The fixtures above are `exec -a "<one fake argv0>" sleep`:
# a single argv element with spaces in it, which is not the shape of a hand-run program. These
# are python3 itself, started as `python3 -c <sleeper> <fifo> <ttl> <script.py>`, so /proc really
# shows argv[0]=python3 and a later element ending in .py. Each one is in a session of its own,
# says "up" through a FIFO when it is running (the suite waits with `read -t`, never a sleep), is
# killed by its exact pid, and has a TTL so that a SIGKILLed suite cannot leave it behind.
#
# 🔴 THE CONTROLS ARE INPUTS THAT MUST NOT BE COUNTED, each one the opposite of one condition the
# scan tests: argv[0] not python (HR2), a script that is not under examples/ (HR2b) or not a file
# there (HR2c), another checkout's copy (HR3), a pid the stack's own *.pid names (HR4).
echo "a program run by hand from examples/ (HR1-HR6)"

command -v python3 >/dev/null 2>&1 || { check "this section needs python3 on PATH" yes no; echo; echo "Ran $((PASS + FAIL)) checks, $FAIL failed"; exit 1; }
command -v setsid  >/dev/null 2>&1 || { check "this section needs setsid on PATH" yes no; echo; echo "Ran $((PASS + FAIL)) checks, $FAIL failed"; exit 1; }
HR_TTL=90
HR_FIFODIR="$(mktemp -d /tmp/ndt-hr-fifo-XXXXXX)"      # outside $REPO: a fifo fd must not attribute a fixture to it
HR_OTHER="$(mktemp -d /tmp/ndt-hr-other-XXXXXX)"       # another tree with its own examples/, outside $REPO
HR_REG="$HR_FIFODIR/pids"; : > "$HR_REG"
HR_REL=examples/p4_energy_saving/energy_saving_sdk.py
mkdir -p "$TMPROOT/examples/p4_energy_saving" "$HR_OTHER/examples/p4_energy_saving" "$TMPROOT/tools"
: > "$TMPROOT/$HR_REL"; : > "$HR_OTHER/$HR_REL"; : > "$TMPROOT/tools/helper.py"
: > "$TMPROOT/examples/p4_energy_saving/data.txt"
HR_CODE='import sys, time
open(sys.argv[1], "w").write("up\n")
time.sleep(float(sys.argv[2]))'
HR_PID=""; HR_N=0

# hr_alive <pid> -- is that pid still the fixture THIS run started (its argv carries this run's fifo directory)?
hr_alive() {
    local cl
    cl="$(tr '\0' ' ' 2>/dev/null < "/proc/$1/cmdline")"
    [[ "$cl" == *"$HR_FIFODIR"* ]] && echo yes || echo no
}
# reap_hr -- kill every fixture of this section by exact pid; echo how many are still alive.
reap_hr() {
    local pid left=0
    [[ -f "$HR_REG" ]] || { echo 0; return 0; }
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$(hr_alive "$pid")" == yes ]] && kill -KILL "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    done < "$HR_REG"
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$(hr_alive "$pid")" == yes ]] && left=$((left + 1))
    done < "$HR_REG"
    echo "$left"
}
# spawn_hr <cwd> <argv0> <script-arg>... -- python3 wearing that argv[0], in <cwd>, in a session of
# its own; its pid is left in HR_PID. Called as a plain command, never from a substitution.
spawn_hr() {
    [[ $BASHPID == "$$" ]] || { echo "  FAILED   ${FUNCNAME[0]} called outside this suite's own shell (BASHPID $BASHPID, suite $$): ending the run" >&2; kill -TERM "$$"; exit 1; }
    local dir="$1" a0="$2" fifo fd line="" pid argv0 sid
    shift 2
    HR_N=$((HR_N + 1)); fifo="$HR_FIFODIR/f$HR_N"; HR_PID=""
    mkfifo "$fifo" || { check "mkfifo $fifo" yes no; exit 1; }
    exec {fd}<>"$fifo"
    HR_CODE="$HR_CODE" setsid bash -c 'cd "$1" || exit 1; a0="$2"; shift 2; exec -a "$a0" python3 -c "$HR_CODE" "$@"' \
        _ "$dir" "$a0" "$fifo" "$HR_TTL" "$@" >/dev/null 2>&1 </dev/null {fd}>&- &
    pid=$!
    echo "$pid" >> "$HR_REG"
    read -t 30 -r -u "$fd" line
    exec {fd}>&-
    argv0="$(tr '\0' '\n' 2>/dev/null < "/proc/$pid/cmdline" | head -1)"
    sid="$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ')"
    check "fixture $HR_N is running ($line), argv0=$a0, in a session of its own" "up $a0 $pid" "$line $argv0 $sid"
    HR_PID="$pid"
    [[ "$line" == up ]] || { echo; echo "Ran $((PASS + FAIL)) checks, $FAIL failed"; exit 1; }
}
orph_rc() { local o; o="$(apps_orphans 2>&1)"; ORPH_RC=$?; ORPH_OUT="$o"; }

rm -f "${PIDDIR:?}"/*.pid "${PIDDIR:?}"/*.pgid
spawn_hr "$TMPROOT" python3 "$HR_REL";               HR1="$HR_PID"
spawn_hr "$TMPROOT" tail "$HR_REL";                  HR2="$HR_PID"
spawn_hr "$TMPROOT" python3 tools/helper.py;         HR2B="$HR_PID"
spawn_hr "$TMPROOT" python3 examples/nonesuch.py;    HR2C="$HR_PID"
spawn_hr "$HR_OTHER" python3 "$HR_REL";              HR3="$HR_PID"
spawn_hr "$TMPROOT/examples/p4_energy_saving" python3 energy_saving_sdk.py; HR1B="$HR_PID"
spawn_hr "$TMPROOT" python3 tools/helper.py examples/p4_energy_saving/data.txt; HR2D="$HR_PID"
# HR1c: this checkout's own example, started from the checkout's PARENT directory by a relative path.
spawn_hr "${TMPROOT%/*}" python3 "${TMPROOT##*/}/$HR_REL"; HR1C="$HR_PID"
HR1_LINE="$(fix_line "$HR1" "python3 -c x $HR_REL")"
HR2_LINE="$(fix_line "$HR2" "tail -f $HR_REL")"
HR2B_LINE="$(fix_line "$HR2B" "python3 -c x tools/helper.py")"
HR2C_LINE="$(fix_line "$HR2C" "python3 -c x examples/nonesuch.py")"
HR3_LINE="$(fix_line "$HR3" "python3 -c x $HR_REL")"
HR1B_LINE="$(fix_line "$HR1B" "python3 -c x energy_saving_sdk.py")"
HR2D_LINE="$(fix_line "$HR2D" "python3 -c x tools/helper.py examples/p4_energy_saving/data.txt")"
HR1C_LINE="$(fix_line "$HR1C" "python3 -c x ${TMPROOT##*/}/$HR_REL")"
check "premise: the first fixture is this checkout's by cwd"      0 "$(proc_checkout "$HR1" >/dev/null; echo $?)"
check "premise: the other tree's fixture is not"                  1 "$(proc_checkout "$HR3" >/dev/null; echo $?)"

# HR1: the process nothing tracks.
SNAPSHOT_LINES="$HR1_LINE"
orph_rc
check "HR1 a hand-run example -> rc 1"                            1 "$ORPH_RC"
check "  it is named, with its pid"                               yes "$(has "hand-run: pid $HR1" "$ORPH_OUT")"
check "  and it is in the tally line orphans_verdict.sh reads"    yes "$(has "1 app(s) are running with nothing tracking them" "$ORPH_OUT")"
check "  the remedy is the pid"                                   yes "$(has "kill $HR1" "$ORPH_OUT")"
check "  it does not say the machine is clean"                    no  "$(has "ok  no untracked app processes" "$ORPH_OUT")"
check "  and it is still alive (nothing here signals)"            yes "$(hr_alive "$HR1")"

# HR1b: run from inside examples/, by bare filename: only the process's cwd says where the script is.
SNAPSHOT_LINES="$HR1B_LINE"; orph_rc
check "HR1b run from inside examples/ by bare filename -> rc 1"   1 "$ORPH_RC"
check "  and it is named"                                         yes "$(has "hand-run: pid $HR1B" "$ORPH_OUT")"

# HR1c: the same example, started from OUTSIDE the checkout by a relative path (cwd is the parent
# directory): its script still resolves into this checkout, so it is ours, not "elsewhere".
check "premise: its cwd is not inside this checkout"              no  "$(path_under_this_checkout "$(readlink "/proc/$HR1C/cwd")" && echo yes || echo no)"
SNAPSHOT_LINES="$HR1C_LINE"; orph_rc
check "HR1c relative path from outside the checkout -> rc 1"      1 "$ORPH_RC"
check "  it is named, with its pid"                               yes "$(has "hand-run: pid $HR1C" "$ORPH_OUT")"
check "  and it is not filed under seen elsewhere"                no  "$(has "seen elsewhere" "$ORPH_OUT")"

# HR2: the controls. Each is rc 0 and says nothing about hand-run.
SNAPSHOT_LINES="$HR2_LINE"; orph_rc
check "HR2 argv[0] is not python (tail -f the same file) -> rc 0" 0 "$ORPH_RC"
check "  and no hand-run line"                                    no  "$(has "hand-run:" "$ORPH_OUT")"
SNAPSHOT_LINES="$HR2B_LINE"; orph_rc
check "HR2b a script outside examples/ -> rc 0"                   0 "$ORPH_RC"
SNAPSHOT_LINES="$HR2C_LINE"; orph_rc
check "HR2c examples/nonesuch.py, not a file there -> rc 0"       0 "$ORPH_RC"
check "  and no hand-run line"                                    no  "$(has "hand-run:" "$ORPH_OUT")"
SNAPSHOT_LINES="$HR2D_LINE"; orph_rc
check "HR2d a data file under examples/ beside a script outside it -> rc 0" 0 "$ORPH_RC"

# HR3: another checkout's copy of the same example.
SNAPSHOT_LINES="$HR3_LINE"; orph_rc
check "HR3 another checkout's copy -> rc 0"                       0 "$ORPH_RC"
check "  listed under seen elsewhere"                             yes "$(has "seen elsewhere (not this checkout): 1 process(es)" "$ORPH_OUT")"
check "  by pid, as a hand-run"                                   yes "$(has "hand-run  pid $HR3" "$ORPH_OUT")"
check "  and not as an orphan"                                    no  "$(has "hand-run: pid" "$ORPH_OUT")"
check "  nor in the tally"                                        no  "$(has "app(s) are running with nothing tracking them" "$ORPH_OUT")"
SNAPSHOT_LINES="$HR1_LINE
$HR3_LINE"; orph_rc
check "HR3 ours and theirs together -> rc 1"                      1 "$ORPH_RC"
check "  ours is the orphan"                                      yes "$(has "hand-run: pid $HR1" "$ORPH_OUT")"
check "  theirs is not"                                           no  "$(has "hand-run: pid $HR3" "$ORPH_OUT")"
check "  one counted, one elsewhere"                              yes "$(has "1 app(s) are running with nothing tracking them" "$ORPH_OUT")"
check "  elsewhere names theirs"                                  yes "$(has "hand-run  pid $HR3" "$ORPH_OUT")"

# HR4: a pid the stack's own *.pid names is the stack's.
SNAPSHOT_LINES="$HR1_LINE"
echo "$HR1" > "$PIDDIR/hr_stack_member.pid"
orph_rc
check "HR4 a pid named in .test_run/pids/*.pid -> rc 0"           0 "$ORPH_RC"
check "  and no hand-run line"                                    no  "$(has "hand-run:" "$ORPH_OUT")"
rm -f "${PIDDIR:?}/hr_stack_member.pid"
orph_rc
check "HR4 control: the same process without the file -> rc 1"    1 "$ORPH_RC"

# HR7: a process this user cannot look inside (cwd and fds unreadable) is counted, and says so --
# the same fail-closed reading section 10 pins for the five apps.
SNAPSHOT_LINES="$HR1_LINE"
HR7_OUT="$(in_ndt "$blind_both" "app_ps_snapshot() { printf '%s %s\n' $HR1 'python3 -c x $HR_REL'; }
rm -f '$PIDDIR'/app_*.pid
apps_orphans; echo \"ORPHANS_RC=\$?\"")"
check "HR7 cwd and fds unreadable -> rc 1"                        ORPHANS_RC=1 "$(grep -o 'ORPHANS_RC=[0-9]*' <<<"$HR7_OUT")"
check "  it is named"                                             yes "$(has "hand-run: pid $HR1" "$HR7_OUT")"
check "  and the report says who owns it was not established"     yes "$(has "who owns these could NOT be established" "$HR7_OUT")"

# HR6: `ndt down` and `ndt up` say so, and do not stop it. The teardown is the real cmd_down over a
# stubbed stack (the shape of tests/shell/test_ndt_down_stops_only_ours.sh): no lab, no root.
mkdir -p "$TMPROOT/tools/test_workflow" "$TMPROOT/etc" "$TMPROOT/.test_run/logs"
printf 'helper\n' > "$TMPROOT/installed-ndtwin-lab"
printf '#!/usr/bin/env bash\necho "stopped kernel"\nexit 0\n' > "$TMPROOT/stack.sh"; chmod +x "$TMPROOT/stack.sh"
HR_STUBS='
REPO="'"$TMPROOT"'"
HERE="'"$TMPROOT"'/tools/test_workflow"
LAB="'"$TMPROOT"'/installed-ndtwin-lab"
STACK="'"$TMPROOT"'/stack.sh"
MANIFEST="'"$TMPROOT"'/manifest.json"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
LAB_CONF="'"$TMPROOT"'/etc/ndtwin-lab.conf"
LAB_DEFAULT_KERNEL_DIR="'"$TMPROOT"'"
APP_NAMES="te"
sudo() { return 0; }
bmv2_count() { echo 0; }
mn_count() { echo 0; }
fabric_host_count() { echo 0; }
topo_session() { return 1; }
in_flight() { :; }
foreign_claim() { :; }
measuring_declared() { :; }
guard_no_live_ovs() { return 0; }
check_up_target() { UP_TARGET_PROBLEMS=(); return 0; }
ndt_sudo_report() { return 0; }
ndt_sudo_rows() { echo one-row; }
git_lines() { :; }
ovs_bridge_count() { echo 0; }
ovs_daemon_running() { return 1; }
netem_count() { echo 0; }
port_open() { return 1; }
ndt_port_open() { return 1; }
ndt_port_listener_pids() { return 0; }
http_get_graph() { :; }
curl() { return 1; }
wait_reaped() { return 0; }
app_ps_snapshot() { cat "'"$TMPROOT"'/hr_snapshot" 2>/dev/null; return 0; }
'
hr_drive() {   # hr_drive <shell-code> -> its output plus a trailing RC=<n>
    bash -c "source '$NDT' >/dev/null 2>&1
$HR_STUBS
$1
echo \"RC=\$?\"" 2>&1
}
hr_rc() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }

printf '%s\n' "$HR1_LINE" > "$TMPROOT/hr_snapshot"
HR_DOWN="$(NDT_OWNER=hr-test hr_drive cmd_down)"
check "HR6 down: the apps step is shown"                          yes "$(has "[0/3] apps" "$HR_DOWN")"
check "  it names the hand-run program, not stopped"              yes "$(has "hand-run: still running, not started by ndt, NOT stopped: pid $HR1" "$HR_DOWN")"
check "  with the remedy"                                         yes "$(has "stop it yourself:  kill $HR1" "$HR_DOWN")"
check "  🔴 the program is still running after the teardown"      yes "$(hr_alive "$HR1")"
check "  and the teardown went on to [1/3]"                       yes "$(has "[1/3] kernel + proxy/Ryu" "$HR_DOWN")"
: > "$TMPROOT/hr_snapshot"
HR_DOWN0="$(NDT_OWNER=hr-test hr_drive cmd_down)"
check "  control: nothing on the field -> no hand-run line"       no  "$(has "hand-run:" "$HR_DOWN0")"
check "  premise: that teardown ends 3 (nothing was up), so a changed rc shows" 3 "$(hr_rc "$HR_DOWN0")"
check "  🔴 and the exit status is the same with and without it"  "$(hr_rc "$HR_DOWN0")" "$(hr_rc "$HR_DOWN")"
printf '%s\n' "$HR3_LINE" > "$TMPROOT/hr_snapshot"
HR_DOWN3="$(NDT_OWNER=hr-test hr_drive cmd_down)"
check "  control: another checkout's copy is not warned about as ours" no "$(has "hand-run: still running" "$HR_DOWN3")"
check "  it is in the elsewhere column"                           yes "$(has "seen elsewhere (not this checkout): 1 process(es)" "$HR_DOWN3")"
# up: the warning is its own function, and the `up)` arm must call it before the plan runs.
printf '%s\n' "$HR1_LINE" > "$TMPROOT/hr_snapshot"
HR_UP="$(hr_drive 'hand_run_scan; hand_run_warn up')"
check "HR6 up: the same program is named"                         yes "$(has "hand-run: pid $HR1" "$HR_UP")"
check "  and it says it will act on the fabric being built"       yes "$(has "it will act on" "$HR_UP")"
check "  🔴 the up) arm of ndt calls it before the plan runs"     yes \
      "$(awk '/^    up\)$/ {f=1} f && /hand_run_scan/ {h=NR} f && /^        \$plan$/ {p=NR; exit} END {print (h && p && h < p) ? "yes" : "no"}' "$NDT")"
: > "$TMPROOT/hr_snapshot"
check "  control: nothing on the field -> up says nothing"        "RC=0" "$(hr_drive 'hand_run_scan; hand_run_warn up')"

# --- 12. `ndt status` names a hand-run program, and `--check` does not count it (C1-C5) -----
#
# [Co-developed with claude code -- Adam]
# Measured live (2026-11-22): `energy_saving_sdk.py --every 120` started by hand on a `basic` fabric.
# `ndt apps orphans` said NOT CLEAN over it while `ndt status` printed `apps  none running`. Decided
# 2026-11-23: status NAMES it and nothing else -- `--check` keeps its exit status and its problem
# lines, because `ndt apps orphans` is the verdict on this class. The same real python3 fixtures as
# above (HR1: this checkout's, HR3: another tree's) under the real cmd_status; only what describes
# THIS machine is stubbed (the shape of tests/shell/test_ndt_status_residue_row.sh).
echo "ndt status names a hand-run program, report-only (C1-C5)"
cat > "$TMPROOT/status_stubs.sh" <<'STUBEOF'
REPO="$ST_REPO"
HERE="$ST_REPO/tools/test_workflow"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
MANIFEST="$REPO/manifest.json"
LAB_CONF="$ST_REPO/etc/ndtwin-lab.conf"
APP_NAMES="te"
sudo() { return 0; }
claim_line() { echo none; }
git_lines() { :; }
in_flight() { :; }
foreign_claim() { :; }
sample_rate() { echo 256; }
rate_source() { echo fixture; }
bmv2_binary() { echo fixture-bmv2; }
stale_pipeline() { return 1; }
source_ahead_of_build() { return 1; }
bmv2_count() { echo 0; }
mn_count() { echo 0; }
fabric_host_count() { echo 0; }
ovs_bridge_count() { echo 0; }
ovs_daemon_running() { return 1; }
topo_session() { return 1; }
live_dataplane_kind() { echo ovs; }
lab_kernel_dir() { echo "$REPO"; }
port_open() { return 1; }
ndt_port_open() { return 1; }
ndt_port_listener_pids() { return 0; }
http_get_graph() { :; }
curl() { return 1; }
netem_count() { echo 0; }
ndt_sudo_report() { return 0; }
ndt_sudo_rows() { echo one-row; }
check_up_target() { UP_TARGET_PROBLEMS=(); return 0; }
lab_version_verdict() { echo "same fixture-sha fixture-sha"; }
measuring_declared() { :; }
app_ps_snapshot() { cat "$ST_REPO/st_snapshot" 2>/dev/null; return 0; }
app_probe() { APP_STATE=not-running; APP_LIVE_PIDS=(); [[ -n "${ST_APP_RUNNING:-}" && "$1" == "$ST_APP_RUNNING" ]] && APP_STATE=running
              [[ -n "${ST_APP_ORPHAN:-}" && "$1" == "$ST_APP_ORPHAN" ]] && { APP_STATE=pidfile-lost-but-alive; APP_LIVE_PIDS=(4242); }; return 0; }
STUBEOF
# st_page <args> -> the page (STDOUT only: a row printed to stderr is not on the page a pipe reads), then a
# trailing RC=<n>. ST_PRE is shell code run after the stubs.
st_page() {
    ST_REPO="$TMPROOT" ST_APP_RUNNING="${ST_APP_RUNNING:-}" ST_APP_ORPHAN="${ST_APP_ORPHAN:-}" bash -c "source '$NDT' >/dev/null 2>&1
source '$TMPROOT/status_stubs.sh'
${ST_PRE:-}
cmd_status ${1:-}
echo \"RC=\$?\"" 2>/dev/null
}
st_rc() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }
st_problems() { sed -n '/^check: /,$p;/^  - /p' <<<"$1" | grep -v '^RC=' ; }
# st_row <label> <page> -- the page's row with that label, and its continuation lines (those with an empty label)
st_row() { awk -v l="$1" '$0 ~ "^  " l "( |$)" {p=1; print; next} p && /^                 [^ ]/ {print; next} {p=0}' <<<"$2"; }

printf '%s\n' "$HR1_LINE" > "$TMPROOT/st_snapshot"
ST1="$(st_page)"
ST1_APPS="$(st_row apps "$ST1")"
ST1_HR="$(st_row hand-run "$ST1")"
check "C1 a live hand-run program -> a hand-run row names its pid"  yes "$(has "pid $HR1  " "$ST1_HR")"
check "  the row names its argv (the script)"                     yes "$(has "$HR_REL" "$ST1_HR")"
check "  and says it is tracked by nothing and not stopped by ndt" yes "$(has "tracked by nothing; ndt does not stop it (kill $HR1)" "$ST1_HR")"
check "  and that it was started by hand from this checkout's examples/" yes "$(has "started by hand from this checkout's examples/" "$ST1_HR")"
check "  the apps row is not a bare 'none running'"              no  "$(has "none running" "$ST1_APPS")"
check "  it says none was started by ndt and points at the row"   yes "$(has "none started by ndt -- see the hand-run row(s) below" "$ST1_APPS")"
check "  one pid, exactly two lines"                              2 "$(wc -l <<<"$ST1_HR" | tr -d ' ')"
ST1B="$(ST_APP_RUNNING=te st_page)"
check "C1b an app ndt started AND a hand-run one: the apps row is exactly the app" "  apps           te" "$(sed -n '/^  apps /p' <<<"$ST1B")"
check "  and the hand-run row is still there"                    yes "$(has "pid $HR1  " "$(st_row hand-run "$ST1B")")"
# C1c: an app ndt started whose pidfile is gone (running, untracked) AND a hand-run one. The page must not
# say none was started by ndt: one was, and its untracked row names it.
ST1C="$(ST_APP_ORPHAN=te st_page)"
check "C1c an app ndt started with no pidfile AND a hand-run one: the apps row does not say none was started by ndt" no "$(has "none started by ndt" "$(st_row apps "$ST1C")")"
check "  the apps row is the base's own text"                    "  apps           none running" "$(sed -n '/^  apps /p' <<<"$ST1C")"
check "  the untracked row names the app"                         yes "$(has "te(4242)" "$(st_row untracked "$ST1C")")"
check "  and the hand-run row is still there"                    yes "$(has "pid $HR1  " "$(st_row hand-run "$ST1C")")"

# C2: --check -- the exit status and the problem lines are the same with and without the program.
ST2="$(st_page --check)"
: > "$TMPROOT/st_snapshot"
ST2_0="$(st_page --check)"
check "C2 --check names the hand-run row too"                     yes "$(has "pid $HR1  " "$(st_row hand-run "$ST2")")"
check "  premise: the same fixture state without the program has no hand-run row" no "$(has "hand-run" "$ST2_0")"
check "  🔴 --check ends with the same rc with and without it"     "$(st_rc "$ST2_0")" "$(st_rc "$ST2")"
check "  🔴 and with the same problem lines"                       "$(st_problems "$ST2_0")" "$(st_problems "$ST2")"
check "  nothing in the problem lines mentions it"                no  "$(has "$HR1" "$(st_problems "$ST2")")"

# C3: no hand-run program -> the scan ran, and it added no byte to the page.
: > "$TMPROOT/st_snapshot"
ST3="$(st_page)"
ST3_OFF="$(ST_PRE='hand_run_scan() { HAND_RUN=(); }' st_page)"
rm -f "$TMPROOT/st_scan_ran"
ST_PRE='eval "$(declare -f hand_run_scan | sed "1s/.*/hand_run_scan_real ()/")"; hand_run_scan() { : > "$ST_REPO/st_scan_ran"; hand_run_scan_real; }' st_page >/dev/null
check "C3 plain status runs the hand-run scan"                    yes "$([[ -e "$TMPROOT/st_scan_ran" ]] && echo yes || echo no)"
check "  with no hand-run program the apps row reads none running" yes "$(has "none running" "$(st_row apps "$ST3")")"
check "  and the page has no hand-run row"                        no  "$(has "hand-run" "$ST3")"
check "  the apps row is exactly that, with no byte after it"      "  apps           none running" "$(sed -n '/^  apps /p' <<<"$ST3")"
check "  and the next line is the blank that ends the block"      "" "$(awk '/^  apps /{getline; print; exit}' <<<"$ST3")"
check "  🔴 and it is byte-identical to the page with the scan switched off" "$ST3_OFF" "$ST3"
ST3C="$(printf '%s\n%s\n' "$HR2_LINE" "$HR2C_LINE" > "$TMPROOT/st_snapshot"; st_page)"
check "  nor do processes that are not candidates change a byte"   "$ST3_OFF" "$ST3C"

# C4: another checkout's copy goes to the elsewhere row and gets no hand-run row.
printf '%s\n' "$HR3_LINE" > "$TMPROOT/st_snapshot"
ST4="$(st_page)"
check "C4 another checkout's copy -> an elsewhere row naming it"  yes "$(has "hand-run($HR3) -- another checkout's; not counted, not stopped" "$(st_row elsewhere "$ST4")")"
check "  no hand-run row"                                         no  "$(has "pid $HR3" "$(st_row hand-run "$ST4")")"
check "  and the apps row still reads none running"               yes "$(has "none running" "$(st_row apps "$ST4")")"
printf '%s\n%s\n' "$HR1_LINE" "$HR3_LINE" > "$TMPROOT/st_snapshot"
ST4B="$(st_page)"
check "  ours and theirs together: ours has the row"              yes "$(has "pid $HR1  " "$(st_row hand-run "$ST4B")")"
check "  theirs is only in elsewhere"                             yes "$(has "($HR3)" "$(st_row elsewhere "$ST4B")")"
check "  and not in a hand-run row"                               no  "$(has "pid $HR3" "$(st_row hand-run "$ST4B")")"

# C5: a pid whose owner could not be established is named, says so, and is still no problem.
printf '%s\n' "$HR1_LINE" > "$TMPROOT/st_snapshot"
ST5="$(ST_PRE="$blind_both" st_page --check)"
: > "$TMPROOT/st_snapshot"
check "C5 owner not established -> the row says so"               yes "$(has "who owns it could not be established" "$(st_row hand-run "$ST5")")"
check "  and --check still has the same rc and problem lines"     "$(st_rc "$ST2_0")|$(st_problems "$ST2_0")" "$(st_rc "$ST5")|$(st_problems "$ST5")"
: > "$TMPROOT/st_snapshot"

check "no hand-run fixture survives this section"                  0 "$(reap_hr)"
SNAPSHOT_LINES=""
rm -f "${PIDDIR:?}"/*.pid

# --- 9. this suite does not become the thing it tests ------------------------------
#
# Asserted rather than left to the EXIT trap, because the trap's own failure is silent: the
# first version of it tracked pids in an array assigned inside a command substitution, so it
# reaped nothing and every run leaked three TE-shaped processes onto the machine.
echo "the suite reaps its own fixtures"
check "no fixture survives this run"              0 "$(reap_fixtures)"

# [Co-developed with claude code -- Adam] the stub's closing check (lib_probe_stub.sh)
check "🔴 every sudo went to this suite's stub and was an allow-listed read-only probe" "" "$(probe_stub_outside 2>&1 | sort | uniq -c | sed 's/^ *//' | paste -sd';' -)"
echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
