#!/usr/bin/env bash
#
# Tests for G-6: `ndt apps` liveness -- start must prove the app is there, stop must not claim
# to have stopped something that was never running.
#
# [Co-developed with claude code -- Adam]
#
# What went wrong, measured live 2026-09-02 (doc/audit/2026-09-02_live-round/raw/):
#
#   * C26_apps_stop_falseok.log -- `ndt apps stop` on apps that were NOT running answered rc 0.
#     For nsr/viz/te the words were honest ("te not running") and only the exit code lied; for
#     energy/sim both lied ("ok sim stopped").
#   * the same file, on the start side -- `ok sim started (tmux: sim)` was printed by a check
#     that "cannot tell": `<name>-start` is `tmux new-session -d ...; echo`, so its rc says a
#     session was created, not that the program in it survived the second after.
#   * D1_teardown.log -- APPS_STOP_ALL_RC=0 for a teardown in which two of five apps had never
#     been started. A driver script reading that code cannot tell it from five-of-five.
#
# So the properties under test are:
#     1. a lab session is not a running program, and a running program is not a lab session --
#        each is checked against the other before a state is named;
#     2. `start` returns non-zero when the app is not there afterwards, whatever the lab said;
#     3. `stop` distinguishes "was running, now stopped" (0) from "there was nothing" (2) from
#        "could not stop it" (1), in the exit code and not only in the prose.
#
# Every check below that asserts NOTHING is running is paired with one that puts a real process
# on the machine and demands it be found, so a suite that silently stopped exercising the scan
# could not stay green.
#
# How the fixtures are safe on a shared machine (same construction as
# tests/shell/test_ndt_app_orphans.sh, which this suite deliberately mirrors):
#
#   * a fixture is `( exec -a "<fake argv0>" sleep N )&` -- the pid really is the process wearing
#     that command line, so /proc is a real witness and nothing about identity is stubbed;
#   * the argv0 is an unmistakable /nonexistent/NDT-TEST-FIXTURE/... path, so a leaked fixture
#     cannot be mistaken for a real app by a human or by `ndt status`;
#   * app_ps_snapshot is replaced everywhere a check could SIGNAL something, so the candidate
#     list is bounded to this test's own fixtures; the verdict on each candidate is still /proc;
#   * `sudo` and `lab_session` are replaced by shell functions, so this suite never reaches the
#     real ndtwin-lab, never asks for root, and cannot disturb a running lab. The auditor's
#     claim window (lab held by another session) is the reason that is not negotiable here.
#
# Run:  bash tests/shell/test_ndt_apps_liveness.sh
set -uo pipefail

export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT="$HERE/../../tools/test_workflow/ndt"

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

# shellcheck source=/dev/null
source "$NDT" || { echo "  FAILED   could not source $NDT"; echo "Ran 1 checks, 1 failed"; exit 1; }

TMPROOT="$(mktemp -d /tmp/ndt-apps-liveness-XXXXXX)"
REPO="$TMPROOT"
PIDDIR="$TMPROOT/.test_run/pids"
mkdir -p "$PIDDIR" "$TMPROOT/.test_run/logs"

FIXTURE_TTL=120
FIXTURE_REG="$TMPROOT/fixtures"
: > "$FIXTURE_REG"

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
    [[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/ndt-apps-liveness-* ]] && rm -rf "$TMPROOT"
    return 0
}
trap cleanup_fixtures EXIT INT TERM

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

# kill_fixture <pid> -- stop one fixture and wait for /proc to agree it is gone.
kill_fixture() {
    local pid="$1" i
    [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == sleep ]] || return 0
    kill -KILL "$pid" 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [[ -e "/proc/$pid" ]] || return 0
        sleep 0.1
    done
    return 0
}

# --- the lab, replaced ---------------------------------------------------------------
#
# LAB_SESSIONS is the set of tmux sessions the fake lab believes it has. LAB_PANE_PID maps a
# session to the fixture that is "running in its pane", so that `<name>-stop` can behave the way
# tmux does -- killing the session takes the pane's process with it -- while a fixture that the
# lab does not own survives, which is the case the code has to notice.
LAB_SESSIONS=""
LAB_START_RC=0
declare -A LAB_PANE_PID=()
declare -A LAB_START_SPAWNS=()

# The call log is a FILE, not a variable, for the same reason the fixture register is: every
# check below runs app_start/app_stop inside `$( )`, so an assignment made by the stub happens
# in a subshell and the parent sees nothing. An earlier draft asserted on a variable here and
# the assertion was vacuously false -- it would have stayed false however the code behaved.
SUDO_LOG="$TMPROOT/sudo_calls"
: > "$SUDO_LOG"
sudo_calls() { tr '\n' ' ' < "$SUDO_LOG"; }

lab_session() { [[ " $LAB_SESSIONS " == *" $1 "* ]]; }

sudo() {
    local a sub="" seen_lab=0
    for a in "$@"; do
        [[ "$a" == -* ]] && continue
        if (( seen_lab == 0 )); then seen_lab=1; continue; fi   # the $LAB path
        sub="$a"; break
    done
    echo "$sub" >> "$SUDO_LOG"
    case "$sub" in
        *-start)
            (( LAB_START_RC != 0 )) && return "$LAB_START_RC"
            LAB_SESSIONS+=" ${sub%-start}"
            # A start that actually works puts a process on the machine. Modelled explicitly so
            # that "the app came up" and "the lab said ok" are separately controllable -- which
            # is the entire distinction under test.
            local n="${sub%-start}"
            [[ -n "${LAB_START_SPAWNS[$n]:-}" ]] && SNAPSHOT_LINES="${LAB_START_SPAWNS[$n]}" ;;
        *-stop)
            local n="${sub%-stop}"
            LAB_SESSIONS="${LAB_SESSIONS/ $n/}"
            if [[ -n "${LAB_PANE_PID[$n]:-}" ]]; then
                kill_fixture "${LAB_PANE_PID[$n]}"
                unset 'LAB_PANE_PID[$n]'
            fi ;;
    esac
    return 0
}

# --- the machine ---------------------------------------------------------------------
# app_ps_snapshot is left ALONE until group 1 has used the real one: a scan that is stubbed from
# the first line can only ever prove that the stub works.
SNAPSHOT_LINES=""
fix_line() { printf '%s %s' "$1" "$2"; }

SIM_ARGV="/nonexistent/NDT-TEST-FIXTURE/simulation_platform_manager"
ENERGY_ARGV="/nonexistent/NDT-TEST-FIXTURE/energy_saving_app"
TE_ARGV="python3 /nonexistent/NDT-TEST-FIXTURE/Traffic-engineering-App.py"

# --- 1. identity: the two lab apps now have one --------------------------------------
#
# Paired with a real-ps read so that "the scan found nothing" can never pass by accident.
echo "identity (energy and sim are recognisable at all)"

SIMFIX="$(spawn_fixture "$SIM_ARGV")"
ENFIX="$(spawn_fixture "$ENERGY_ARGV")"

check "sim has a signature"                       yes "$(yn pid_is_app "$SIMFIX" sim)"
check "energy has a signature"                    yes "$(yn pid_is_app "$ENFIX" energy)"
check "sim is not energy"                         no  "$(yn pid_is_app "$SIMFIX" energy)"
check "real ps finds the live sim fixture"        yes "$(has "$SIMFIX" $'\n'"$(app_scan_pids sim)"$'\n')"
check "real ps does not report this shell"        no  "$(has "$$" $'\n'"$(app_scan_pids sim)"$'\n')"

# From here on the candidate list is bounded to this suite's own fixtures. The verdict on each
# candidate is still the real /proc.
app_ps_snapshot() { printf '%s\n' "$SNAPSHOT_LINES"; }

# --- 2. two witnesses, and each catches what the other misses -------------------------
echo "state (a session is not a program; a program is not a session)"

SNAPSHOT_LINES="$(fix_line "$SIMFIX" "$SIM_ARGV")"
LAB_SESSIONS="sim"
app_probe sim
check "session up + process alive  -> running"    running "$APP_STATE"
check "  and it names the pid"                    yes "$(has "$SIMFIX" " ${APP_LIVE_PIDS[*]} ")"

# The C26 shape: tmux made a session, the program died inside it.
SNAPSHOT_LINES=""
LAB_SESSIONS="sim"
app_probe sim
check "session up + NO process     -> not-running" not-running "$APP_STATE"
check "  and the reason is recorded"              1 "$APP_SESSION_WITHOUT_PROCESS"

# Started by hand, outside the lab socket: the hazard is that energy powers switches down.
SNAPSHOT_LINES="$(fix_line "$ENFIX" "$ENERGY_ARGV")"
LAB_SESSIONS=""
app_probe energy
check "no session + process alive  -> orphan"     pidfile-lost-but-alive "$APP_STATE"

SNAPSHOT_LINES=""
LAB_SESSIONS=""
app_probe energy
check "no session + no process     -> not-running" not-running "$APP_STATE"
check "  with no false reason attached"           0 "$APP_SESSION_WITHOUT_PROCESS"

# --- 3. start must prove it, not report the request ----------------------------------
echo "start (the rc of 'tmux new-session; echo' is not evidence)"

# The lab accepts the request and creates a session; nothing ever appears in it. This is exactly
# what C26 recorded as 'ok sim started'.
SNAPSHOT_LINES=""
LAB_SESSIONS=""
LAB_START_RC=0
out="$(app_start sim 2>&1)"; rc=$?
check "start of an app that never came up -> rc 1" 1 "$rc"
check "  does NOT say ok ... started"             no  "$(has "sim started" "$out")"
check "  says it did not start"                   yes "$(has "sim did not start" "$out")"
check "  names the empty session as the reason"   yes "$(has "nothing running in it" "$out")"
check "  and points at the app's own output"      yes "$(has "sim-out" "$out")"

# The happy path still has to work: the lab starts it AND a process appears.
SNAPSHOT_LINES=""
LAB_SESSIONS=""
LAB_START_SPAWNS[sim]="$(fix_line "$SIMFIX" "$SIM_ARGV")"
: > "$SUDO_LOG"
out="$(app_start sim 2>&1)"; rc=$?
check "start of an app that does come up -> rc 0" 0 "$rc"
check "  says it started"                         yes "$(has "sim started" "$out")"
check "  names the pid it verified"               yes "$(has "$SIMFIX" "$out")"
check "  and it asked the lab to start it"        yes "$(has "sim-start" " $(sudo_calls) ")"
unset 'LAB_START_SPAWNS[sim]'
SNAPSHOT_LINES=""

# A refusal from the lab is still a refusal.
SNAPSHOT_LINES=""
LAB_SESSIONS=""
LAB_START_RC=3
out="$(app_start energy 2>&1)"; rc=$?
check "lab refuses the request -> rc 1"           1 "$rc"
check "  and the rc is reported"                  yes "$(has "rc 3" "$out")"
LAB_START_RC=0

# --- 4. stop must not claim to have stopped nothing ----------------------------------
echo "stop (the D1 shape: rc 0 for apps that were never started)"

SNAPSHOT_LINES=""
LAB_SESSIONS=""
out="$(app_stop sim 2>&1)"; rc=$?
check "stop of a never-started lab app -> rc 2"   2 "$rc"
check "  does NOT say ok sim stopped"             no  "$(has "sim stopped" "$out")"
check "  says it is not running"                  yes "$(has "sim not running" "$out")"

# nsr/viz/te: the words were already honest here, the exit code was not.
rm -f "$PIDDIR"/app_*.pid
SNAPSHOT_LINES=""
out="$(app_stop te 2>&1)"; rc=$?
check "stop of a never-started pidfile app -> rc 2" 2 "$rc"
check "  still says not running"                  yes "$(has "te not running" "$out")"

# Really running, really stopped: rc 0 is reserved for this.
TEFIX="$(spawn_fixture "$TE_ARGV")"
SNAPSHOT_LINES="$(fix_line "$TEFIX" "$TE_ARGV")"
echo "$TEFIX" > "$PIDDIR/app_te.pid"
out="$(app_stop te 2>&1)"; rc=$?
check "stop of a running app -> rc 0"             0 "$rc"
check "  says it stopped it"                      yes "$(has "te stopped" "$out")"

# An empty session left behind is cleared, and saying so is the point: the next start would
# otherwise be refused by ndtwin-lab with "session already running".
SNAPSHOT_LINES=""
LAB_SESSIONS="energy"
: > "$SUDO_LOG"
out="$(app_stop energy 2>&1)"; rc=$?
check "stop with an empty session -> rc 2"        2 "$rc"
check "  says the session was still there"        yes "$(has "still there with nothing in it" "$out")"
check "  and clears it"                           yes "$(has "energy-stop" " $(sudo_calls) ")"

# A lab app the lab cannot reach: `energy-stop` kills a SESSION, and this one is not in a
# session. Reporting success here is the failure this whole area exists to stop.
ENFIX2="$(spawn_fixture "$ENERGY_ARGV")"
SNAPSHOT_LINES="$(fix_line "$ENFIX2" "$ENERGY_ARGV")"
LAB_SESSIONS=""
out="$(app_stop energy 2>&1)"; rc=$?
check "stop that did not stop it -> rc 1"         1 "$rc"
check "  does NOT claim success"                  no  "$(has "energy stopped (was" "$out")"
check "  says it is still running"                yes "$(has "STILL RUNNING" "$out")"
check "  names the pid to kill"                   yes "$(has "$ENFIX2" "$out")"
kill_fixture "$ENFIX2"

# The lab's own stop does work when the lab owns the pane.
SIMFIX2="$(spawn_fixture "$SIM_ARGV")"
SNAPSHOT_LINES="$(fix_line "$SIMFIX2" "$SIM_ARGV")"
LAB_SESSIONS="sim"
LAB_PANE_PID[sim]="$SIMFIX2"
out="$(app_stop sim 2>&1)"; rc=$?
SNAPSHOT_LINES=""
check "lab stop of a lab-owned app -> rc 0"       0 "$rc"
check "  says it stopped it"                      yes "$(has "sim stopped (was" "$out")"

# --- 5. the aggregate a teardown script reads ----------------------------------------
echo "apps stop all (what D1 recorded as APPS_STOP_ALL_RC=0)"

rm -f "$PIDDIR"/app_*.pid
SNAPSHOT_LINES=""
LAB_SESSIONS=""
out="$(cmd_apps stop all 2>&1)"; rc=$?
check "nothing was running -> rc 2"               2 "$rc"
check "  and it says nothing was stopped"         yes "$(has "nothing to stop" "$out")"

TEFIX2="$(spawn_fixture "$TE_ARGV")"
SNAPSHOT_LINES="$(fix_line "$TEFIX2" "$TE_ARGV")"
echo "$TEFIX2" > "$PIDDIR/app_te.pid"
out="$(cmd_apps stop all 2>&1)"; rc=$?
SNAPSHOT_LINES=""
check "one of five was running -> rc 0"           0 "$rc"
check "  and the mix is stated"                   yes "$(has "were already not running" "$out")"

# --- 6. this suite does not become the thing it tests --------------------------------
echo "the suite reaps its own fixtures"
check "no fixture survives this run"              0 "$(reap_fixtures)"

echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
