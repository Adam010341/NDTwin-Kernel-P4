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
# file was deleted (doc/audit/2026-08-31_live-recipes/app_te_log_evidence.txt). The figure this
# comment first carried, 20h32m, came from neither the log nor anything else in the repo and has
# been withdrawn. That day's orphan installed no flow rules either -- every error in the file is
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
# 2026-09-12 (FIX-NDT-11 ②): section 10's red is a one-line edit to `ndt`'s fail-closed branch,
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

# ndt returns early when sourced (same seam as stack.sh:877), so this defines its functions
# without dispatching on argv.
# shellcheck source=/dev/null
source "$NDT" || { echo "  FAILED   could not source $NDT"; echo "Ran 1 checks, 1 failed"; exit 1; }

TMPROOT="$(mktemp -d /tmp/ndt-app-orphans-XXXXXX)"
REPO="$TMPROOT"                       # every app_pidfile call now lands here, not in the workspace
PIDDIR="$TMPROOT/.test_run/pids"
mkdir -p "$PIDDIR"

FIXTURE_TTL=90                        # self-reaps even if this script is SIGKILLed
# The fixture register is a FILE, not an array. spawn_fixture is called from inside a command
# substitution, so `FIXTURE_PIDS+=(...)` appends in a subshell and the parent's trap sees an
# empty list -- measured here: an earlier draft leaked every fixture it started, and `ndt apps
# orphans` found fourteen of them still running. A suite that tests orphan detection must not be
# a source of orphans.
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
    [[ -f "$FIXTURE_REG" ]] && reap_fixtures >/dev/null
    [[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/ndt-app-orphans-* ]] && rm -rf "$TMPROOT"
    return 0
}
trap cleanup_fixtures EXIT INT TERM

# spawn_fixture <argv0> [cwd] -- start a process wearing that command line; echo its pid.
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
spawn_fixture() {
    local want="$1" dir="${2:-$TMPROOT}" pid i
    local -a argv=()
    # The redirections are load-bearing, not tidiness. spawn_fixture is called inside a command
    # substitution, and a background child that inherits that substitution's pipe keeps it open:
    # without these the caller blocks for the fixture's whole lifetime (measured here -- the
    # first draft hung for FIXTURE_TTL seconds per fixture and had to be killed).
    ( cd "$dir" && exec -a "$want" sleep "$FIXTURE_TTL" ) >/dev/null 2>&1 </dev/null &
    pid=$!
    echo "$pid" >> "$FIXTURE_REG"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        argv=()
        mapfile -d '' -t argv 2>/dev/null < "/proc/$pid/cmdline"
        [[ "${argv[0]:-}" == "$want" ]] && { echo "$pid"; return 0; }
        sleep 0.1
    done
    echo "  FAILED   fixture never took argv0=$want (pid $pid)" >&2
    echo "Ran $((PASS + FAIL + 1)) checks, $((FAIL + 1)) failed"
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

FIX="$(spawn_fixture "$FIX_ARGV")"
DECOY="$(spawn_fixture "$DECOY_ARGV")"
PLAIN="$(spawn_fixture "sleep-with-no-signature-at-all")"

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
# running and now is not", which is how D1_teardown.log recorded APPS_STOP_ALL_RC=0 for a
# teardown that stopped three of five apps. The prose here was already honest; only the exit
# code was not, and a driver script reads the exit code.
SNAPSHOT_LINES=""
rm -f "$PIDDIR/app_te.pid"
out="$(app_stop te 2>&1)"; rc=$?
check "nothing running -> rc 2 (was 0 before G-6)" 2 "$rc"
check "  says not running"                        yes "$(has "not running" "$out")"
# [Co-developed with claude code -- Adam]
# 2026-09-03, fix/apps-stop-kills-the-group: this sentence grew from two witnesses to four, and
# it is pinned here because it IS the contract -- "not running" has to say what it looked at.
# The old wording was true by its own lights and still wrong: "no live instance found by pid or
# by scan" was printed on 09-02 while two JVMs ran for another 1h54m, because a pid and an argv
# are the two things a reparented child is invisible to. The process group and the log's writers
# are the two that would have seen them.
check "  and says how it knows"                   yes "$(has "nothing found by pid, by scan, by process group or by log" "$out")"

VICTIM="$(spawn_fixture "python3 /nonexistent/NDT-TEST-FIXTURE-VICTIM/$TE_SIG")"
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
VICTIM2="$(spawn_fixture "python3 /nonexistent/NDT-TEST-FIXTURE-LINKED/$TE_SIG")"
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

# --- 8. C10-8: the scan is machine-wide, the verdict is this checkout's ------------
#
# [Co-developed with claude code -- Adam]
# Measured 2026-09-12 15:05:14 (CELLS-2 window 1; the shape was ROLE-10 section 9 at 05:50).
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
OTHERFIX="$(spawn_fixture "$OTHER_ARGV" "$TMPROOT/scratch/wt-other")"
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

# --- 10. E-7 / C10-8: the process nobody could attribute is counted as OURS --------
#
# [Co-developed with claude code -- Adam]
# FIX-NDT-10 SUMMARY §7-9. `proc_checkout` answers 2 -- "could not tell" -- when BOTH
# /proc/<pid>/cwd and /proc/<pid>/fd are unreadable, every caller treats a 2 as ours, and the
# report says so instead of claiming to know. That is the whole of C10-8's safety side: the apps
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
# produce one -- the second half is an OS fact (FIX-NDT-10's live evidence: `/proc/<pid>/fd of a
# root process could not be read`, R4-LIVE §4-A9) and is out of an offline suite's reach.
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
# says "I could not tell" over a rc 0 -- the E-7 shape with the sign flipped.
OUT10="$(in_ndt "$blind_both" "app_ps_snapshot() { printf '%s %s\n' $FIX '$FIX_ARGV'; }
rm -f '$PIDDIR'/app_*.pid
apps_orphans; echo \"ORPHANS_RC=\$?\"")"
check "🔴 apps orphans is rc 1 over it"               ORPHANS_RC=1 "$(grep -o 'ORPHANS_RC=[0-9]*' <<<"$OUT10")"
check "  it is the orphan, by name"                   yes "$(has "te: pidfile-lost-but-alive" "$OUT10")"
check "  and the report prints the fail-closed line"  yes "$(has "who owns these could NOT be established, so they are counted as this checkout's" "$OUT10")"
check "  it is not in the elsewhere column"           no  "$(has "seen elsewhere (not this checkout)" "$OUT10")"

# --- the controls. Each one is an input that must NOT produce "could not tell".
OTHER10="$(spawn_fixture "python3 /nonexistent/NDT-TEST-FIXTURE-BLIND-CONTROL/$TE_SIG" "$TMPROOT/scratch/wt-other")"
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

# --- 9. this suite does not become the thing it tests ------------------------------
#
# Asserted rather than left to the EXIT trap, because the trap's own failure is silent: the
# first version of it tracked pids in an array assigned inside a command substitution, so it
# reaped nothing and every run leaked three TE-shaped processes onto the machine.
echo "the suite reaps its own fixtures"
check "no fixture survives this run"              0 "$(reap_fixtures)"

echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
