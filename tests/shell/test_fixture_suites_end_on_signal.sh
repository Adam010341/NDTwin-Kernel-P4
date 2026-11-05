#!/usr/bin/env bash
#
# A signal ENDS each of the eight fixture-spawning suites: sent TERM (and INT) mid-run, a suite must
# stop at once with the shell's 128+signal status, its fixtures gone and its temp tree removed.
#
# [Co-developed with claude code -- Adam]
#
# WHAT WENT WRONG (2026-10-01). Six of these suites armed `trap <cleanup> EXIT INT TERM` with a
# cleanup that returns. On INT or TERM the handler reaped the fixtures, deleted the temp tree and
# RETURNED, and the suite went on running without them: test_ndt_down_stops_only_ours.sh spawned
# into the deleted directory and waited out its poll, the others ran their checks against a tree
# that was no longer there. test_ndt_app_orphans.sh was converted first (2026-09-28): EXIT does
# the cleaning, INT and TERM only end the run. This test holds all eight to that (the eighth,
# test_apps_stop_kills_the_group.sh, joined on 2026-10-03; test_live_p1_common.sh is not in it yet).
#
# AND THREE MORE WAYS (2026-10-03).
#   * A suite that EXITS 130 on INT has, to a calling bash, handled the Ctrl-C, and the caller
#     goes on (tools/test_workflow/l1_unit_tests.sh ran the next suite). So every INT run below
#     has a caller -- `bash -c 'bash <suite>; echo ...'` -- and must end with the caller's 130:
#     the suite killed by INT, and the caller with it.
#   * A second signal arriving while the cleanup runs cut it short. The `cleanup` runs send a
#     second signal while the cleanup's own `sleep 0.3` is running, three ways per suite: INT
#     then INT (Ctrl-C twice), TERM then TERM, INT then TERM. Six suites have that sleep between
#     reaping their fixtures and removing their tree; test_ndt_ovs_claim.sh and
#     test_apps_stop_kills_the_group.sh have none, and run as a copy with one inserted before
#     their `rm -rf` (a copy that changes when, not what).
#   * Two spawners had a window between starting a fixture and writing its pid down. `app`
#     signals test_ndt_apps_liveness.sh during app_spawn's `sleep 1`, which comes after the app
#     is started and before spawn_app_fixture records it -- a second, so it is hit as it is.
#     `two` signals test_ndt_helper_apps_window.sh between spawn_two_layer's `&` and its
#     TWO_PARENT=$!, which is far under a millisecond; it runs as a copy with a `sleep 1`
#     inserted there, so the signal can be put inside it.
#   * The cleanup of those two suites now kills every child of the suite's shell, by its group
#     only where the child leads one. `held` makes sure a child that does NOT lead one is there
#     when it runs -- the window suite's held parent, in the suite's own group -- through a copy
#     with a `sleep 1` after HELD=$!. A cleanup that killed that child's group would kill the
#     suite (and, under INT, its caller): 137, not 143 or 130. That is why every run is checked
#     to lead a session of its own, its session is printed beside this test's, and a run that does
#     not is NOT signalled: it is reaped by its token and the next run starts.
#
# HOW. Each suite is started in the background with a token in its environment that every
# process it starts inherits, so "a process of this run" is read from /proc/<pid>/environ, not
# from a name: a busy machine, or another checkout running the same suite, cannot be mistaken for
# it. The suite (or, for INT, its caller) leads a session of its own (setsid). The signal is sent
# at a moment chosen per run:
#   fixture  the suite has printed an `ok       fixture took argv0=` line AND a live process
#            carrying the token is listed in the suite's own fixture register -- a fixture, not
#            just any process of the run (a poll's sleep, a `bash -c`), so there is something its
#            cleanup must reap. That register also names the suite's temp tree: three suites
#            honour TMPDIR, which is pointed at a directory of this test's own; the other five
#            write under /tmp, and their tree is the new one whose register lists such a pid.
#   cleanup  the same, and then, once the cleanup the first signal started is in its `sleep 0.3`
#            (a child of the suite's shell that was not there before the signal), the second:
#            INT to the group, TERM to the suite's shell. Its premise is that sleep, seen alive
#            and stopped with the run held when the second signal goes (see HELD below); how
#            much of it was left then, from its start time, is printed beside it.
#   app      app_spawn's `sleep 1` is a child of the suite's shell AND the pidfile it has just
#            written names a live process of this run.
#   two      the inserted `sleep 1` is a child of the suite's shell AND the two-layer fixture's
#            child is alive (its pid is in the tree's twolayer_child).
#   held     the inserted `sleep 1` is a child of the suite's shell AND so is the held parent,
#            known by its stdin: the tree's `hold` fifo. Its premise is read too: the held parent's
#            process group is the suite's, and is not its own pid.
# apps_group has no check that announces a fixture: its moment is the suite's register of process
# GROUPS (`groups`) naming a live process of the run, the app it has just started.
# HELD (2026-11-05). A moment is only ever taken with the run HELD: its whole process group
# stopped (SIGSTOP; the group is the run's own, checked first), the suite's shell seen stopped,
# and then the moment read again. Every signal of a run is sent while it is held and before it is
# let go (SIGCONT), so the state the moment was read from is the state the signal lands in,
# however slowly this test is scheduled. A held moment also needs the suite NOT to be on its own
# way out -- no summary line printed yet, INT and TERM not ignored by its shell -- because every
# cleanup ignores both first thing (`trap '' INT TERM`), and a signal that lands in a run ending
# by itself is ignored by design: that run ends 0 or 1, which says nothing about the suite.
# [Co-developed with claude code -- Adam]
# LATE (2026-11-06). A run that came near its moment (its premise was seen) and then ended on its
# own, with no held look seeing the moment while the suite was still in its main flow -- held
# too late, held only once it was on its way out, or not held at all because this test was too
# slow -- is started again, up to SIGNAL_ATTEMPTS times in all within the one
# SIGNAL_FIRST_FIXTURE_WAIT, each restart printed as a note with the number of holds it made, its
# last line of output and how many of its processes were reaped. A late watcher is this test's
# problem, not the suite's. A run that never comes near its moment, or is still running when that
# wait is used up, is not restarted, and when every attempt is late the cell fails as a missed
# moment that names them.
# [Co-developed with claude code -- Adam]
# TERM goes to the suite's own pid, INT to its whole process group, the way a terminal's Ctrl-C
# arrives (bash runs an INT trap once the foreground child it is waiting for has died of INT too).
# Then:
#   * it ends within SIGNAL_END_WITHIN seconds (default 20), with 143 for TERM and 130 for INT;
#   * no process carrying the token is left once it has ended;
#   * its temp tree is gone.
# Under INT the "no process left" check can only fail for a fixture outside the suite's process
# group (a setsid one), or one that ignores INT: a fixture inside it that does not dies of the
# same INT, reaped or not.
# INT goes through `env --default-signal=INT`: a background job of a non-interactive shell starts
# with INT ignored, and bash cannot trap a signal that was ignored when it started.
#
# Run:  bash tests/shell/test_fixture_suites_end_on_signal.sh [label...]
#   labels: orphans liveness sweep window topo_pid ovs_claim down apps_group (default: all eight); a label
#   selects every run of that suite.
#   SIGNAL_END_WITHIN=20  SIGNAL_FIRST_FIXTURE_WAIT=30  SIGNAL_CLEANUP_WAIT=10  SIGNAL_HARD_LIMIT=30
#   SIGNAL_TOTAL_LIMIT=210 (seconds)  SIGNAL_ATTEMPTS=3. Green, the forty-three runs take 93-98 s in
#   all on the development machine (measured 2026-11-06, three runs with the holds: 93, 98 and 95 s;
#   103 s on the tree before them); about a third of that is the three `app`/`two`/`held` runs,
#   which wait for a point 11-13 s into their suite.
# THE BOUND. The limits keep a HUNG suite a red line rather than a killed CI job. ci.yml's
#   build-and-test has timeout-minutes 30, and on PR #22 that job took 22 min 11 s and 21 min 30 s
#   (GitHub Actions jobs 110274499246 and 110274514834: 07:56:17Z-08:18:28Z and
#   07:56:19Z-08:17:49Z), so about 7.8 min are left. One run is at most FIRST_WAIT (all its
#   attempts share it) + CLEANUP_WAIT + HARD_LIMIT, plus up to 2 s each for a hold that overruns
#   the first two, plus about 5 s of /proc scans = 79 s, and no run starts after TOTAL_LIMIT, so
#   this whole test ends within 210 + 79 = 289 s (4.8 min) -- 22 min 11 s + 4.8 min = 27.0 min,
#   inside the 30. Without the total limit it would be 43 x 79 = 3397 s. The limit is about twice
#   the green time, so a host half as fast still runs every run.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALL_LABELS=(orphans liveness sweep window topo_pid ovs_claim down apps_group)
END_WITHIN="${SIGNAL_END_WITHIN:-20}"
FIRST_WAIT="${SIGNAL_FIRST_FIXTURE_WAIT:-30}"
CLEANUP_WAIT="${SIGNAL_CLEANUP_WAIT:-10}"
HARD_LIMIT="${SIGNAL_HARD_LIMIT:-30}"
TOTAL_LIMIT="${SIGNAL_TOTAL_LIMIT:-210}"
ATTEMPTS="${SIGNAL_ATTEMPTS:-3}"

PASS=0; FAIL=0
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

LABELS=("$@")
(( ${#LABELS[@]} )) || LABELS=("${ALL_LABELS[@]}")
for l in "${LABELS[@]}"; do
    [[ " ${ALL_LABELS[*]} " == *" $l "* ]] || { echo "no suite labelled '$l' (${ALL_LABELS[*]})"; exit 2; }
done
selected() { [[ " ${LABELS[*]} " == *" $1 "* ]]; }

# suite_info <label> -> SFILE, SPREFIX (its temp tree's mktemp prefix), SPRIVATE (1: it honours
# TMPDIR), SREG (its fixture register, one pid per line, relative to that tree), SPREMISE (a line
# of its output that must be there before the signal: by default, a fixture that took its argv0)
suite_info() {
    SPREMISE='^ *ok +fixture took argv0='
    case "$1" in
        orphans)   SFILE="$HERE/test_ndt_app_orphans.sh";           SPREFIX=ndt-app-orphans-;     SPRIVATE=0; SREG=fixtures ;;
        liveness)  SFILE="$HERE/test_ndt_apps_liveness.sh";         SPREFIX=ndt-apps-liveness-;   SPRIVATE=0; SREG=fixtures ;;
        sweep)     SFILE="$HERE/test_ndtwin_lab_sweep.sh";          SPREFIX=ndtwin-lab-sweep-;    SPRIVATE=0; SREG=fixtures ;;
        topo_pid)  SFILE="$HERE/test_faults_topo_pid.sh";           SPREFIX=faults-topo-pid-;     SPRIVATE=0; SREG=fixtures ;;
        window)    SFILE="$HERE/test_ndt_helper_apps_window.sh";    SPREFIX=ndt-helper-window-;   SPRIVATE=1; SREG=fixtures ;;
        ovs_claim) SFILE="$HERE/test_ndt_ovs_claim.sh";             SPREFIX=ndt-ovs-claim-;       SPRIVATE=1; SREG=fixture.pids ;;
        down)      SFILE="$HERE/test_ndt_down_stops_only_ours.sh";  SPREFIX=ndt-down-ours-;       SPRIVATE=1; SREG=spawned.pids ;;
        # Its fixtures are not `sleep`s a check announces: the moment is the register of process
        # GROUPS, which the suite writes once the app it started is up -- any check printed before.
        apps_group) SFILE="$HERE/test_apps_stop_kills_the_group.sh"; SPREFIX=ndt-appsgroup-;       SPRIVATE=0; SREG=groups; SPREMISE='^ *ok ' ;;
    esac
}
# variant_of <label> <mode> -> VOLD, VNEW: the one edit a run's copy of the suite makes, or none.
variant_of() {
    VOLD=""; VNEW=""; VDESC=""
    case "$1 $2" in
        "ovs_claim cleanup")
            VOLD='[[ -n "${FIX:-}" && -d "$FIX" ]] && rm -rf "$FIX"'
            VNEW='sleep 0.3; [[ -n "${FIX:-}" && -d "$FIX" ]] && rm -rf "$FIX"'
            VDESC="a sleep 0.3 before the cleanup's rm -rf" ;;
        "apps_group cleanup")
            VOLD='[[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/ndt-appsgroup-* ]] && rm -rf "$TMPROOT"'
            VNEW='sleep 0.3; [[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/ndt-appsgroup-* ]] && rm -rf "$TMPROOT"'
            VDESC="a sleep 0.3 before the cleanup's rm -rf" ;;
        "window two")
            VOLD=$'    TWO_PARENT=$!\n'
            VNEW=$'    sleep 1\n    TWO_PARENT=$!\n'
            VDESC="a sleep 1 between spawn_two_layer's & and TWO_PARENT=\$!" ;;
        "window held")
            VOLD=$'HELD=$!\n'
            VNEW=$'HELD=$!\nsleep 1\n'
            VDESC="a sleep 1 after the held parent's HELD=\$!" ;;
    esac
}

env --default-signal=INT true 2>/dev/null \
    || { echo "  FAILED   env --default-signal is not available (GNU coreutils >= 8.31)"; echo "Ran 1 checks, 1 failed"; exit 1; }
command -v python3 >/dev/null 2>&1 \
    || { echo "  FAILED   python3 is required (to write the two copies)"; echo "Ran 1 checks, 1 failed"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ndt-signal-ends-run-XXXXXX")"
TOKENS=()
# [Co-developed with claude code -- Adam] nap <seconds> -- a wait with no fork: a read that times
# out on a fifo of this test's own, open at both ends so nothing ever arrives (2026-11-05). The
# polls between two holds of a run use it, so a run is let go for about that long and no longer,
# however slowly this test forks. Every run is started with that descriptor closed.
mkfifo "$WORK/nap" && exec {NAP_FD}<>"$WORK/nap" \
    || { echo "  FAILED   could not open a fifo in $WORK"; echo "Ran 1 checks, 1 failed"; rm -rf "$WORK"; exit 1; }
nap() { local nap_; read -r -t "$1" -u "$NAP_FD" nap_; return 0; }
HOLDING=0
# token_pids <token> -- every live process whose environment carries this run's token.
token_pids() {
    local f
    for f in $(grep -alsF -- "NDT_SIGNAL_TEST_TOKEN=$1" /proc/[0-9]*/environ 2>/dev/null); do
        f="${f#/proc/}"; echo "${f%/environ}"
    done
}
# reap_token <token> -- kill, by pid, whatever still carries it (each pid re-read first).
# REAPED: how many it killed ([Co-developed with claude code -- Adam], 2026-11-06).
reap_token() {
    local p
    REAPED=0
    for p in $(token_pids "$1"); do
        grep -qasF -- "NDT_SIGNAL_TEST_TOKEN=$1" "/proc/$p/environ" 2>/dev/null && kill -KILL "$p" 2>/dev/null \
            && REAPED=$((REAPED + 1))
    done
    return 0
}
cleanup() {
    # [Co-developed with claude code -- Adam] First, so a second signal cannot cut it short
    # (2026-10-03), as in the suites.
    trap '' INT TERM
    local t
    # [Co-developed with claude code -- Adam] A run this test is holding is reaped first, while it
    # is still stopped and cannot fork, then its group is let go (2026-11-06), so an INT or TERM of
    # this test mid-hold leaves no group stopped and no child of it unreaped. A SIGKILL of this
    # test cannot be handled at all: a run it was holding then stays stopped, in a session of its
    # own, until `kill -CONT -- -<that session's id>`.
    if (( ${HOLDING:-0} )) && [[ "${HELD_GROUP:-}" =~ ^[0-9]+$ ]]; then
        [[ -n "${HELD_TOKEN:-}" ]] && reap_token "$HELD_TOKEN"
        kill -s CONT -- "-$HELD_GROUP" 2>/dev/null
    fi
    for t in "${TOKENS[@]}"; do reap_token "$t"; done
    [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf "$WORK"
    rm -f "$HERE"/.spawn-gate-$$-signal-*
    return 0
}
trap cleanup EXIT
# [Co-developed with claude code -- Adam] Killed by INT, not exit 130 (2026-10-03): this file is
# itself run by l1_unit_tests.sh, which would otherwise go on after a Ctrl-C.
trap 'trap - INT; kill -INT $$' INT
trap 'exit 143' TERM

# state_of <pid> -- R/S/D/Z/... from /proc, or "gone".
state_of() { local s; s="$(cat "/proc/$1/stat" 2>/dev/null)" || { echo gone; return; }; s="${s##*) }"; echo "${s%% *}"; }
# [Co-developed with claude code -- Adam] proc_stat <pid> -> PSTAT, the fields of /proc/<pid>/stat
# from the state on (PSTAT[0] the state, [2] the process group, [3] the session, [19] the start
# time in clock ticks), read with no fork (2026-11-05); 1 when it is gone. ended: Z or gone.
proc_stat() { local s; PSTAT=(); { read -r s < "/proc/$1/stat"; } 2>/dev/null || return 1; read -r -a PSTAT <<<"${s##*) }"; }
ended() { proc_stat "$1" || return 0; [[ "${PSTAT[0]}" == Z ]]; }
leads_own_session() { proc_stat "$1" && [[ "${PSTAT[2]} ${PSTAT[3]}" == "$1 $1" ]]; }
# [Co-developed with claude code -- Adam] hold <group> <pid> -- stop the run's whole process group
# and wait, with no fork and for up to 2 s, until <pid> (the suite's shell) is seen stopped
# (2026-11-05). HELD_MS: the uptime, in ms, read just after the stop went. Called only for a
# group that leads its own session, which this test started. release <group> lets it go again.
hold() {
    local i u
    kill -s STOP -- "-$1" 2>/dev/null || return 1
    HOLDING=1; HELD_GROUP="$1"; HELD_TOKEN="${tok:-}"; HOLDS=$(( ${HOLDS:-0} + 1 ))
    read -r u _ < /proc/uptime; HELD_MS=$(( ${u%.*} * 1000 + 10#${u#*.} * 10 ))
    for (( i = 0; i < 400; i++ )); do
        proc_stat "$2" && [[ "${PSTAT[0]}" != Z ]] || break
        [[ "${PSTAT[0]}" == T ]] && return 0
        nap 0.005
    done
    release "$1"; return 1
}
release() { (( HOLDING )) && kill -s CONT -- "-$1" 2>/dev/null; HOLDING=0; return 0; }
# [Co-developed with claude code -- Adam] ending <suite pid> <its output> -- the suite is on its
# own way out (2026-11-05): its summary line is printed, or its shell ignores INT or TERM (bits 1
# and 14 of SigIgn), which each of the eight cleanups makes it do first thing. Gone counts too.
ending() {
    local k v
    grep -qE '^Ran [0-9]+ checks?' "$2" 2>/dev/null && return 0
    { while read -r k v; do [[ "$k" == SigIgn: ]] && break; done < "/proc/$1/status"; } 2>/dev/null
    [[ "$k" == SigIgn: && "$v" =~ ^[0-9a-fA-F]+$ ]] || return 0
    (( (16#$v >> 1) & 1 || (16#$v >> 14) & 1 ))
}
now_ms() { local t="${EPOCHREALTIME/,/.}"; echo $(( ${t%.*} * 1000 + 10#${t#*.} / 1000 )); }
# children_of <pid> -- its child pids, from /proc/<pid>/task/<pid>/children where there is one,
# else from every process's parent field.
children_of() {
    local f c s
    if [[ -r "/proc/$1/task/$1/children" ]]; then
        tr ' ' '\n' < "/proc/$1/task/$1/children" 2>/dev/null | grep -x '[0-9][0-9]*'
        return 0
    fi
    for f in /proc/[0-9]*/stat; do
        { read -r s < "$f"; } 2>/dev/null || continue
        s="${s##*) }"; s="${s#* }"
        [[ "${s%% *}" == "$1" ]] || continue
        c="${f#/proc/}"; echo "${c%/stat}"
    done
}
argv_of() { { tr '\0' ' ' < "/proc/$1/cmdline"; } 2>/dev/null; }
# child_running <pid> <argv, words joined by spaces> [<pids to ignore>] -> CHILD, the first child of
# <pid> with exactly that argv that is not in the list.
# [Co-developed with claude code -- Adam] With no fork (2026-11-05): the polls that look for a
# moment between two holds call it, and a fork there is time the run spends let go.
child_running() {
    local c f s
    local -a ck=() a=()
    CHILD=""
    if [[ -r "/proc/$1/task/$1/children" ]]; then
        { read -r -a ck < "/proc/$1/task/$1/children"; } 2>/dev/null
    else
        for f in /proc/[0-9]*/stat; do
            { read -r s < "$f"; } 2>/dev/null || continue
            s="${s##*) }"; s="${s#* }"
            [[ "${s%% *}" == "$1" ]] || continue
            c="${f#/proc/}"; ck+=("${c%/stat}")
        done
    fi
    for c in "${ck[@]}"; do
        [[ " ${3:-} " == *" $c "* ]] && continue
        a=(); { mapfile -d '' -t a < "/proc/$c/cmdline"; } 2>/dev/null
        [[ "${a[*]}" == "$2" ]] && { CHILD="$c"; return 0; }
    done
    return 1
}
# file_names_live <file> <token>: the file holds one pid, alive and carrying the token.
file_names_live() {
    local p
    p="$(head -1 "$1" 2>/dev/null)"
    [[ "$p" =~ ^[0-9]+$ ]] && grep -qasF -- "NDT_SIGNAL_TEST_TOKEN=$2" "/proc/$p/environ" 2>/dev/null
}
# CLK_TCK -- clock ticks per second, the unit of a start time in /proc/<pid>/stat.
CLK_TCK="$(getconf CLK_TCK 2>/dev/null)"; [[ "$CLK_TCK" =~ ^[0-9]+$ ]] || CLK_TCK=100
send() {   # send <TERM|INT> <the pid signalled>: TERM to the pid, INT to its group
    if [[ "$1" == INT ]]; then kill -s INT -- "-$2"; else kill -s "$1" "$2"; fi
}

# [Co-developed with claude code -- Adam] The moment of a run, in two looks (2026-11-05). Both run
# inside `one` and read and set its locals (bash scoping is dynamic).
# moment_near -- a cheap look, with the run going and no fork once the premise line is seen: may
# its moment be here? find_moment -- the whole look, with the run held: sets tree and moment (and,
# for `held`, held) when it is.
moment_near() {
    case "$mode" in
        fixture|cleanup)
            (( premised )) || { grep -qE "$SPREMISE" "$out" 2>/dev/null && premised=1; }
            (( premised )) ;;
        *)  child_running "$suite" "sleep 1" ;;
    esac
}
find_moment() {
    tree=""; moment=""; held=""
    case "$mode" in
        fixture|cleanup)
            if grep -qE "$SPREMISE" "$out" 2>/dev/null; then
                mapfile -t live < <(token_pids "$tok" | grep -vx -e "$spid" -e "$suite")
                for d in "$( (( SPRIVATE )) && echo "$tmpd" || echo /tmp)/$SPREFIX"*; do
                    [[ -f "$d/$SREG" ]] || continue
                    (( SPRIVATE )) || [[ " ${before[*]} " != *" $d "* ]] || continue
                    mapfile -t fixtures < <(printf '%s\n' "${live[@]}" | grep -xF -f "$d/$SREG" | grep -x '[0-9][0-9]*')
                    (( ${#fixtures[@]} )) && { tree="$d"; moment="fixture pid(s) ${fixtures[*]} alive, listed in $d/$SREG"; break; }
                done
            fi ;;
        app)
            if child_running "$suite" "sleep 1"; then
                for d in /tmp/"$SPREFIX"*; do
                    [[ " ${before[*]} " != *" $d "* ]] || continue
                    file_names_live "$d/.test_run/pids/app_te.pid" "$tok" || continue
                    tree="$d"; moment="app_spawn's sleep 1 is pid $CHILD; app_te.pid names live pid $(head -1 "$d/.test_run/pids/app_te.pid")"
                    break
                done
            fi ;;
        two)
            if child_running "$suite" "sleep 1"; then
                for d in "$tmpd/$SPREFIX"*; do
                    file_names_live "$d/twolayer_child" "$tok" || continue
                    tree="$d"; moment="the inserted sleep 1 is pid $CHILD; the two-layer child $(head -1 "$d/twolayer_child") is alive"
                    break
                done
            fi ;;
        held)
            if child_running "$suite" "sleep 1"; then
                for d in "$tmpd/$SPREFIX"*; do
                    for p in $(children_of "$suite"); do
                        [[ "$(readlink "/proc/$p/fd/0" 2>/dev/null)" == "$d/hold" ]] || continue
                        tree="$d"; held="$p"; moment="the inserted sleep 1 is pid $CHILD; the held parent $p, a child of the suite in its group, waits on $d/hold"
                        break 2
                    done
                done
            fi ;;
    esac
    [[ -n "$tree" ]]
}

# one <label> <mode> <SIG> <expected rc> [<the second signal, for mode cleanup>]
one() {
    local label="$1" mode="$2" sig="$3" want="$4" second="${5:-}" tok tmpd out spid suite="" t0 t1 rc i tree="" d p f0="$FAIL"
    local deadline runfile name moment="" what n sid pg left_ms held="" premised=0 late="" went="" near="" attempt tok0 lastl
    local -a before=() fixtures=() left=() live=() kids=()
    suite_info "$label"
    variant_of "$label" "$mode"
    name="$label $mode $sig${second:++$second}"
    tok0="$label-$mode-$sig$second-$$-$RANDOM$RANDOM"; tok="$tok0"; TOKENS+=("$tok")
    tmpd="$WORK/tmp-$label-$mode-$sig$second"; out="$WORK/out-$label-$mode-$sig$second.log"
    mkdir -p "$tmpd"
    runfile="$SFILE"
    if [[ -n "$VOLD" ]]; then
        # Beside the suite, so every path it derives from its own location is the real one; the
        # name is one .gitignore keeps out of a commit, and cleanup removes it.
        runfile="$HERE/.spawn-gate-$$-signal-$label-$mode-$sig$second-$(basename "$SFILE")"
        n="$(python3 -c 'import sys
s = open(sys.argv[1]).read(); n = s.count(sys.argv[3])
if n == 1: open(sys.argv[2], "w").write(s.replace(sys.argv[3], sys.argv[4], 1))
print(n)' "$SFILE" "$runfile" "$VOLD" "$VNEW")"
        if [[ "$n" != 1 ]]; then
            check "$name: the copy's one edit has exactly one place to go in ${SFILE##*/}" 1 "$n"
            rm -f "$runfile"; return
        fi
    fi
    echo "$name${VDESC:+ (a copy, with $VDESC)}"
    # Wait for the run's moment (see HOW above). For `fixture` and `cleanup`: a fixture premise
    # printed AND a live process of this run in the suite's own fixture register; the register it
    # is in is the suite's temp tree. A suite may stop its first fixture again within a second
    # (test_ndt_ovs_claim.sh does) and run on with only a poll's sleep or a `bash -c` of its own
    # alive: a signal sent then gives the leftover checks nothing to find, so that moment does
    # not count.
    #
    # [Co-developed with claude code -- Adam] HELD (2026-11-05; see the header). A cheap look with
    # the run going (moment_near), then the run held and the whole moment read (find_moment); it
    # stays held from there until its signal has gone. Read with the run going, as it was, the
    # moment could be old by the time the signal went, several forks of checks and notes later: a
    # suite could by then have finished on its own and be in its cleanup, which ignores the
    # signal, and such a run ends 0 or 1. That race was reproduced for `down` with this test
    # starved of CPU; it fits two CI failures of `cleanup` cells (`down` TERM+TERM, `orphans`
    # INT+INT) whose exit status was not printed.
    # [Co-developed with claude code -- Adam] LATE (2026-11-06; see the header): attempts.
    deadline=$(( SECONDS + FIRST_WAIT ))
    for (( attempt = 1; ; attempt++ )); do
        if (( attempt > 1 )); then tok="$tok0-a$attempt"; TOKENS+=("$tok"); fi
        (( SPRIVATE )) || { shopt -s nullglob; before=(/tmp/"$SPREFIX"*); shopt -u nullglob; }
        # [Co-developed with claude code -- Adam] Emptied here, by this shell, so no line of an
        # earlier attempt can be read as this one's premise (2026-11-06).
        : > "$out"
        if [[ "$sig" == INT ]]; then
            # [Co-developed with claude code -- Adam] The caller, as l1_unit_tests.sh calls a suite.
            TMPDIR="$tmpd" NDT_SIGNAL_TEST_TOKEN="$tok" \
                setsid env --default-signal=INT bash -c 'bash "$1"; echo "the caller carried on after rc $?"' _ "$runfile" \
                </dev/null >"$out" 2>&1 {NAP_FD}<&- &
        else
            TMPDIR="$tmpd" NDT_SIGNAL_TEST_TOKEN="$tok" \
                setsid env --default-signal=INT bash "$runfile" </dev/null >"$out" 2>&1 {NAP_FD}<&- &
        fi
        spid=$!
        suite=""; premised=0; near=""; late=""; tree=""; moment=""; held=""; live=(); HOLDS=0
        while (( SECONDS < deadline )); do
            ended "$spid" && break
            if [[ -z "$suite" ]]; then
                if [[ "$sig" == TERM ]]; then suite="$spid"
                else for p in $(children_of "$spid"); do [[ "$(argv_of "$p")" == "bash $runfile " ]] && suite="$p"; done; fi
            fi
            if [[ -n "$suite" ]] && moment_near; then
                near=1
                if ! leads_own_session "$spid"; then
                    # Not held, and not signalled either: the check below says why.
                    find_moment; [[ -n "$tree" ]] && break
                elif hold "$spid" "$suite"; then
                    find_moment
                    if [[ -n "$tree" ]]; then
                        ending "$suite" "$out" || break
                        late="held with $moment, the suite was already on its own way out"
                    fi
                    tree=""; moment=""; held=""
                    release "$spid"
                fi
            fi
            if [[ "$mode" == fixture || "$mode" == cleanup ]]; then nap 0.1; else nap 0.02; fi
        done
        [[ -n "$tree" ]] && ! ended "$spid" && break
        # Late: it came near its moment (its premise was seen) and ended on its own, with no held
        # look seeing the moment while the suite was still in its main flow (see LATE above).
        if [[ -n "$near" ]] && ended "$spid" && (( attempt < ATTEMPTS && SECONDS < deadline )); then
            wait "$spid" 2>/dev/null; reap_token "$tok"
            lastl="$(tail -1 "$out" | cut -c1-80)"
            echo "  note     attempt $attempt of $ATTEMPTS late (came near its moment, held $HOLDS time(s), ${late:-no held look found the moment while the suite was still in its main flow}); the suite ended on its own, last line: $lastl; $REAPED process(es) of it reaped: started again"
            continue
        fi
        break
    done
    case "$mode" in
        fixture|cleanup) what="a pid in its own fixture register is alive" ;;
        app) what="app_spawn is in its sleep 1, the app it started alive" ;;
        two) what="spawn_two_layer is in the inserted sleep 1, its fixture alive" ;;
        held) what="the held parent, not a group leader, is alive and the suite in the inserted sleep 1" ;;
    esac
    if ended "$spid" || [[ -z "$tree" ]]; then
        release "$spid"
        check "$name: within ${FIRST_WAIT}s, $what, the suite still running and not on its own way out" yes \
              "no (attempt $attempt of $ATTEMPTS, every one late or without a moment; $(state_of "$spid"); ${#live[@]} other process(es) of the run alive;${late:+ $late;} last line: $(tail -1 "$out" | cut -c1-80))"
        kill -KILL "$spid" 2>/dev/null; wait "$spid" 2>/dev/null; reap_token "$tok"
        [[ -n "$tree" && -d "$tree" && "${tree##*/}" == "$SPREFIX"* ]] && rm -rf "$tree"
        [[ "$runfile" != "$SFILE" ]] && rm -f "$runfile"
        return
    fi
    if [[ "$sig" == TERM ]]; then
        check "$name: the pid signalled is the shell running the suite" yes \
              "$([[ "$(argv_of "$spid")" == *"$runfile"* ]] && echo yes || echo no)"
    else
        check "$name: the suite runs in a child of the pid whose group is signalled, its caller" yes \
              "$([[ "$suite" != "$spid" && "$(argv_of "$spid")" == "bash -c "* ]] && echo yes || echo no)"
    fi
    # [Co-developed with claude code -- Adam] Its own session, too (2026-10-03): whatever a suite's
    # cleanup kills by group then cannot reach this test or whatever runs it.
    sid="$(ps -o sid= -p "$spid" 2>/dev/null | tr -d ' ')"
    pg="$(ps -o pgid= -p "$spid" 2>/dev/null | tr -d ' ')"
    check "$name: and that pid leads its own process group and session" "$spid $spid" "$pg $sid"
    if [[ "$pg $sid" != "$spid $spid" ]]; then
        # [Co-developed with claude code -- Adam] Not signalled (2026-10-03): the run is not in a
        # group of its own, so a cleanup that kills a group could reach this test and whatever
        # runs it, and the signal itself (INT goes to the group) could too.
        echo "  note     not signalled: the run does not lead a process group and session of its own"
        release "$spid"
        kill -KILL "$spid" 2>/dev/null; wait "$spid" 2>/dev/null; reap_token "$tok"
        [[ -d "$tree" && "${tree##*/}" == "$SPREFIX"* ]] && rm -rf "$tree"
        [[ "$runfile" != "$SFILE" ]] && rm -f "$runfile"
        return
    fi
    if [[ "$mode" == held ]]; then
        # [Co-developed with claude code -- Adam] The premise `held` is there for (2026-10-03): the
        # parent leads no group of its own, so it is in the suite's. Were it a leader, a cleanup
        # that killed "its" group would kill only what it should, and the cell would pass
        # whatever the cleanup did.
        check "$name: the held parent is in the suite's group" "$(ps -o pgid= -p "$suite" 2>/dev/null | tr -d ' ')" \
              "$(ps -o pgid= -p "$held" 2>/dev/null | tr -d ' ')"
        check "$name:   and that group is not its own pid" no \
              "$([[ "$(ps -o pgid= -p "$held" 2>/dev/null | tr -d ' ')" == "$held" ]] && echo yes || echo no)"
    fi
    echo "  note     signalled with $moment"
    echo "  note     the run's session $sid; this test's session $(ps -o sid= -p $$ | tr -d ' ')"
    mapfile -t kids < <(children_of "$suite")
    t0="$(now_ms)"
    send "$sig" "$spid"
    release "$spid"
    if [[ "$mode" == cleanup ]]; then
        # The second signal, once the cleanup that the first one started is in its `sleep 0.3` -- a
        # child of the suite's shell that was not one before the first signal. A second INT goes to
        # the group, a second TERM to the suite's own shell.
        # [Co-developed with claude code -- Adam] Looked for with the run held, and sent before it
        # is let go (2026-11-05): the sleep is seen alive and stopped, the suite's shell stopped, so
        # the signal lands inside the sleep however late this test gets to it. Between two holds
        # the run goes for one nap. It used to be looked for with the run going and its premise
        # read from the clock afterwards, which a slow enough watcher failed: the signal went after
        # the sleep. The clock stays as a note, read at the hold.
        CHILD=""; left_ms=""; went=""
        deadline=$(( SECONDS + CLEANUP_WAIT ))
        while (( SECONDS < deadline )); do
            ended "$suite" && break
            # [Co-developed with claude code -- Adam] The session re-read before every stop, as in
            # the first loop (2026-11-06).
            leads_own_session "$spid" || break
            if hold "$spid" "$suite"; then
                if child_running "$suite" "sleep 0.3" "${kids[*]}" && proc_stat "$CHILD" && [[ "${PSTAT[0]}" == T ]]; then
                    left_ms=$(( 300 - (HELD_MS - PSTAT[19] * 1000 / CLK_TCK) ))
                    if [[ "$second" == INT ]]; then send INT "$spid"; else send TERM "$suite"; fi
                    went=yes
                fi
                release "$spid"
                [[ -n "$went" ]] && break
            fi
            nap 0.01
        done
        # (Worked out first, not inside the check's argument: check_process_by_name.py's reader
        # cannot follow that many nested quotes, and then refuses the whole file.)
        what="no (not sent; the suite's shell: $(state_of "$suite"))"
        [[ -n "$went" ]] && what=yes
        check "$name: a second $second, sent while its cleanup is in its sleep 0.3" yes "$what"
        [[ -n "$went" ]] && echo "  note     the second $second went with the run held in that sleep, about $left_ms ms of it left at the hold"
    fi
    deadline=$(( SECONDS + HARD_LIMIT ))
    while (( SECONDS < deadline )); do ended "$spid" && break; sleep 0.1; done
    t1="$(now_ms)"
    if ! ended "$spid"; then
        echo "             still running ${HARD_LIMIT}s after the signal: killed (SIGNAL_HARD_LIMIT)"
        kill -KILL "$spid" 2>/dev/null
    fi
    wait "$spid"; rc=$?
    if [[ "$sig" == TERM ]]; then
        check "$name: the run ends with $want" "$want" "$rc"
    else
        check "$name: the run ends with $want, the suite killed by INT and its caller with it" "$want" \
              "$rc$(grep -m1 '^the caller carried on' "$out" | sed 's/^/ (/; s/$/)/')"
    fi
    check "$name: within ${END_WITHIN}s of the signal" yes \
          "$( (( t1 - t0 <= END_WITHIN * 1000 )) && echo yes || echo "no ($(( (t1 - t0) / 1000 ))s)")"
    # A fixture killed on the way out can take a moment to leave /proc.
    for (( i = 0; i < 30; i++ )); do mapfile -t left < <(token_pids "$tok"); (( ${#left[@]} )) || break; sleep 0.1; done
    check "$name: no process of this run is left" "" \
          "$(for p in "${left[@]}"; do printf '%s(%s) ' "$p" "$(argv_of "$p" | cut -c1-40)"; done)"
    check "$name: its temp tree is gone" no "$([[ -n "$tree" && -e "$tree" ]] && echo "yes ($tree)" || echo no)"
    if (( FAIL > f0 )); then
        echo "             the suite's last lines:"; tail -3 "$out" | cut -c1-120 | sed 's/^/               /'
    fi
    # Nothing of a red run outlives this test: its processes by pid, its tree by its exact path.
    reap_token "$tok"
    [[ -n "$tree" && -d "$tree" && "${tree##*/}" == "$SPREFIX"* ]] && rm -rf "$tree"
    [[ "$runfile" != "$SFILE" ]] && rm -f "$runfile"
}

PLAN=()
for l in "${LABELS[@]}"; do PLAN+=("$l fixture TERM 143" "$l fixture INT 130"); done
for l in "${LABELS[@]}"; do PLAN+=("$l cleanup INT 130 INT" "$l cleanup TERM 143 TERM" "$l cleanup INT 130 TERM"); done
# app, two and held only under INT: the reaper does not ask which signal ended the run, and each
# run waits 11-13 s for its moment. INT is the one whose caller a wrong group kill would take with
# it, and held under INT alone fails each of the three ways the reaper can be got wrong that held
# is there for, all seen red on the shared lib (2026-10-03): a group kill of the child's real group
# (the run ends 137, not 130), `kill -KILL 0` for a child that leads no group (137 again), and no
# reaper call in the window suite's cleanup (the held parent is still there when the run is over).
# A held TERM run was dropped for the 12 s it cost.
selected liveness && PLAN+=("liveness app INT 130")
selected window && PLAN+=("window two INT 130" "window held INT 130")
for run in "${PLAN[@]}"; do
    read -r l mode sig want second <<<"$run"
    if (( SECONDS >= TOTAL_LIMIT )); then
        check "$l $mode $sig${second:++$second}: run, before SIGNAL_TOTAL_LIMIT (${TOTAL_LIMIT}s) was used up" yes "no (${SECONDS}s used)"
        continue
    fi
    one "$l" "$mode" "$sig" "$want" "$second"
done

echo
if (( FAIL > 0 )); then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
