#!/usr/bin/env bash
#
# Does `ndt apps stop` stop the APP, or only the process whose pid it wrote down?
#
# [Co-developed with claude code -- Adam]
#
# What went wrong, measured twice. 2026-09-02 (ADDENDUM-01-viz-orphan-contamination.md): the viz
# launcher was sent SIGTERM, `ndt apps stop viz` printed `ok viz stopped` with rc 0, and the two
# JVMs under it ran for another 1h54m at 111% of a core while app_viz.log grew to 875,463,322
# bytes on a filesystem at 85%. 2026-09-03 round 3 (round3-restart-concurrency/14_viz_process_
# chain.log) reproduced it deliberately: STOP_RC=0, `pid 1320231 gone`, `SURVIVOR pid 1320234`,
# `SURVIVOR pid 1320294`, and then `ndt apps orphans` -> `ok no untracked app processes`, rc 0.
# The same afternoon Adam hit it by hand and maven ran for another 43 minutes.
#
# Two mechanisms, and this suite is about both:
#
#   1. app_spawn started the app in NDT'S OWN process group, so there was no group to signal --
#      only the pid of the wrapper. `setsid` is what gives the app a session of its own, and the
#      checks below assert the property (pgid == pid == sid, and different from this shell's),
#      not the presence of the word.
#   2. every witness that could have contradicted the success was pidfile- or argv-shaped, and
#      the survivors are exactly the processes those two cannot see: a JVM's command line
#      carries no `network_traffic_visualizer.sh` (round 3 counted it: 0 occurrences in either
#      JVM). The independent channels -- the process group, and who holds a WRITABLE fd on the
#      app's own log -- are asserted here to find what the old ones structurally could not.
#
# 🔴 Two directions, because "stop harder" has an obvious wrong answer. `kill -TERM -<pgid>` on
# the group ndt itself is in kills ndt, the shell that ran it, and everything else in that
# session. Group 7 asserts the refusal, and it does it in a process of its own (setsid) so that
# a version which signals instead of refusing kills THAT process and this suite still reports
# a failure rather than dying with it.
#
# Safety on a shared machine:
#   * REPO is redirected to a temp dir, so no real .test_run/pids or .test_run/logs entry is
#     read, written or deleted.
#   * app_sig is replaced with a signature no process on this machine carries, so neither the
#     argv scan nor any kill path can reach a real app.
#   * every channel that can signal is bounded by something this suite owns: a process group it
#     created, or a log file inside its own temp dir.
#   * fixtures self-reap after FIXTURE_TTL seconds even if this script is SIGKILLed, and the
#     cleanup signals exact pids and one process group it verified is not its own.
#
# Env:  NDT_UNDER_TEST=<path>   (the mutation gate points this at a copy)
# Run:  bash tests/shell/test_apps_stop_kills_the_group.sh
set -uo pipefail

export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# shellcheck source=/dev/null
source "$NDT" || { echo "  FAILED   could not source $NDT"; echo "Ran 1 checks, 1 failed"; exit 1; }

TMPROOT="$(mktemp -d /tmp/ndt-appsgroup-XXXXXX)"
REPO="$TMPROOT"
mkdir -p "$TMPROOT/.test_run/pids" "$TMPROOT/.test_run/logs"
FIXDIR="$TMPROOT/fixture"
mkdir -p "$FIXDIR"
FIXTURE_TTL=120

# 🔴 The fixture's name carries this run's pid, so `app_sig` below is unique to THIS invocation.
# It has to be: app_stop's argv scan is machine-wide by design, so with a fixed name a second
# copy of this suite -- the mutation gate's next mutant, or a developer running it by hand --
# is a process carrying the signature, and the two runs stop each other's fixtures. Measured on
# 2026-09-03: the gate's own baseline went red that way while a hand-run of the suite was in
# flight, and the failures looked exactly like the defect under test ("the pidfile holds a live
# pid" FAILED). A shared name in a machine-wide scan is the same mistake in the instrument that
# the code under test is being fixed for.
FIXSIG="ndt-groupfix-$$-launcher.sh"
FIXWORKER="ndt-groupfix-$$-worker"
FIXSTUBBORN="ndt-groupfix-$$-stubborn"

# A signature no process on this machine carries. Everything below that can signal goes through
# a channel bounded by this suite's own temp dir or its own process group, but the argv scan is
# machine-wide by design, and this is what keeps it away from a real Traffic-Engineering-App.
app_sig() { case "$1" in te) echo "$FIXSIG" ;; esac; }

# The shape that survived: a wrapper carrying the signature, whose children carry none and
# inherit its stdout. Two levels, like network_traffic_visualizer.sh -> maven -> JVM.
cat > "$FIXDIR/$FIXSIG" <<EOF
#!/usr/bin/env bash
here="\$(cd "\$(dirname "\$0")" && pwd)"
"\$here/$FIXWORKER" 0 &
end=\$(( SECONDS + $FIXTURE_TTL ))
while (( SECONDS < end )); do sleep 1; done
EOF
#
# 🔴 The deepest child drops the inherited stdout when NDT_GROUPFIX_CLOSE_STDOUT is set. That is
# not decoration: without it, every descendant holds a writable fd on the log, the log-writer
# channel alone would reach the whole tree, and the process-group signal -- the thing this fix
# adds -- could be deleted with every check still green. A JVM that reopens its own logging is
# this case in the field. With it, the depth-1 worker is reachable by the GROUP and by nothing
# else, so "nothing of the tree survives" is a statement about the group kill.
# 🔴 The depth-0 worker hands off to a fresh child when it is TERMed. Without that, a per-pid
# kill of everything the scan listed is indistinguishable from signalling the group, and the
# mutation that deletes the group signal survives this suite (measured: it did, first run).
# What the group signal covers and a pid list cannot is a process that appears AFTER the list
# was taken -- a supervisor restarting its worker, a maven forking the next JVM. The handoff
# makes that deterministic instead of a race: it happens exactly when the kill arrives.
cat > "$FIXDIR/$FIXWORKER" <<EOF
#!/usr/bin/env bash
d="\${1:-0}"
if (( d < 1 )); then "\$0" 1 & fi
if (( d < 1 )); then trap '( exec sleep 20 ) & exit 0' TERM; fi
if (( d >= 1 )) && [[ -n "\${NDT_GROUPFIX_CLOSE_STDOUT:-}" ]]; then exec >/dev/null 2>&1; fi
end=\$(( SECONDS + $FIXTURE_TTL ))
while (( SECONDS < end )); do printf 'frame depth=%s pid=%s\n' "\$d" "\$\$"; sleep 0.05; done
EOF
export NDT_GROUPFIX_CLOSE_STDOUT=1
chmod +x "$FIXDIR/$FIXSIG" "$FIXDIR/$FIXWORKER"

# --- fixture bookkeeping ----------------------------------------------------------
#
# A FILE, not an array, for the reason tests/shell/test_ndt_app_orphans.sh gives: these are
# registered from inside command substitutions, and an array appended there is appended in a
# subshell the trap never sees. A suite about orphans must not leak any.
FIXTURE_REG="$TMPROOT/fixtures"
: > "$FIXTURE_REG"
GROUP_REG="$TMPROOT/groups"
: > "$GROUP_REG"

# ppid_of / descendants -- this suite's OWN walk of /proc, independent of the code under test.
# "Did the whole tree go away" must not be answered by the same function that decides what the
# tree is; every pid counted here was reached by following ppid from the launcher.
ppid_of() {
    local line rest
    read -r line 2>/dev/null < "/proc/$1/stat" || return 1
    rest="${line##*) }"
    [[ "$rest" == "$line" ]] && return 1
    rest="${rest#* }"
    echo "${rest%% *}"
}
descendants() {   # <root> -- root and everything under it, one pid per line
    local root="$1" p q pp w i
    local -a wave=("$root") next=() all=("$root")
    for i in 1 2 3 4 5 6; do
        next=()
        for p in /proc/[0-9]*; do
            q="${p#/proc/}"
            pp="$(ppid_of "$q")" || continue
            for w in "${wave[@]}"; do
                [[ "$pp" == "$w" ]] && { next+=("$q"); all+=("$q"); break; }
            done
        done
        (( ${#next[@]} == 0 )) && break
        wave=("${next[@]}")
    done
    printf '%s\n' "${all[@]}"
}
alive_count() {   # how many of the pids on stdin still exist
    local pid n=0
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        [[ -d "/proc/$pid" ]] && n=$((n + 1))
    done
    echo "$n"
}

cleanup_fixtures() {
    local pid pg mine
    mine="$(proc_pgid "$$" 2>/dev/null || echo 0)"
    while read -r pg; do
        [[ "$pg" =~ ^[0-9]+$ ]] || continue
        # Never this suite's own group, whatever a mutated ndt may have written there.
        [[ "$pg" == "$mine" ]] && continue
        kill -KILL "-$pg" 2>/dev/null
    done < "$GROUP_REG"
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )) || continue
        [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
        kill -KILL "$pid" 2>/dev/null
    done < "$FIXTURE_REG"
    [[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/ndt-appsgroup-* ]] && rm -rf "$TMPROOT"
    return 0
}
trap cleanup_fixtures EXIT INT TERM

# start_app -- start the fake app through the REAL app_spawn; echo the recorded pid.
# Asserts nothing itself; the checks read what it produced.
start_app() {
    app_spawn te "$FIXDIR" "./$FIXSIG" >/dev/null 2>&1
    local pid pg
    pid="$(cat "$(app_pidfile te)" 2>/dev/null)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        echo "$pid" >> "$FIXTURE_REG"
        pg="$(proc_pgid "$pid" 2>/dev/null || true)"
        [[ -n "$pg" ]] && echo "$pg" >> "$GROUP_REG"
        # Give the worker and its child time to exist before anything asks about them.
        sleep 1
        descendants "$pid" >> "$FIXTURE_REG"
    fi
    echo "$pid"
}

MY_PGID="$(proc_pgid "$$")"

# --- 1. the /proc primitives, against an independent instrument -------------------
echo "reading /proc (cross-checked against ps, which is a different implementation)"

PS_PGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
PS_SID="$(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')"
check "proc_pgid agrees with ps about this shell"  "$PS_PGID" "$MY_PGID"
check "proc_sid agrees with ps about this shell"   "$PS_SID"  "$(proc_sid "$$")"
check "proc_pgid of a pid that does not exist"     ""         "$(proc_pgid 999999 2>/dev/null)"
check "proc_pgid of a non-numeric pid"             ""         "$(proc_pgid "not-a-pid" 2>/dev/null)"

# A comm with a space AND a ')' in it: /proc/<pid>/stat does not escape it, so a parser that
# splits on the first ')' or on whitespace reads the wrong field and every group check built on
# it silently compares the wrong numbers.
cat > "$FIXDIR/we ird) name" <<EOF
#!/usr/bin/env bash
sleep $FIXTURE_TTL
EOF
chmod +x "$FIXDIR/we ird) name"
"$FIXDIR/we ird) name" >/dev/null 2>&1 &
ODD=$!
echo "$ODD" >> "$FIXTURE_REG"
sleep 0.3
check "a comm containing ') ' does not fool the parser" \
      "$(ps -o pgid= -p "$ODD" 2>/dev/null | tr -d ' ')" "$(proc_pgid "$ODD")"
# Reaped here, and waited for, so that the "no fixtures leaked" check at the bottom is about
# leaks and not about this one still serving its purpose -- and so bash does not print the job's
# death notice after the summary line, where a log scraper would read it as output of the run.
kill -TERM "$ODD" 2>/dev/null; wait "$ODD" 2>/dev/null

# --- 2. app_spawn gives the app a session of its own ------------------------------
echo "app_spawn (the property, not the word 'setsid')"

APP="$(start_app)"
check "the pidfile holds a live pid"               yes "$(yn test -d "/proc/$APP")"
# The 2026-08-20 regression this file's comment warns about: `setsid CMD & echo $!` recorded the
# pid of a transient shell, stop killed that, and the recorder ran on. The pid must BE the app.
check "the recorded pid is the app itself"         yes "$(yn pid_is_app "$APP" te)"
check "the app is its own process group leader"    "$APP" "$(proc_pgid "$APP")"
check "the app is its own session leader"          "$APP" "$(proc_sid "$APP")"
check "  and that group is NOT this shell's"       no  "$(has "$MY_PGID" "$(proc_pgid "$APP")")"
check "the .pgid file records that group"          "$APP" "$(cat "$(app_pgidfile te)" 2>/dev/null)"

mapfile -t TREE < <(descendants "$APP")
check "the fixture really has descendants"         yes "$( (( ${#TREE[@]} >= 3 )) && echo yes || echo no)"
KIDGROUPS=""
for p in "${TREE[@]}"; do KIDGROUPS="$KIDGROUPS $(proc_pgid "$p" 2>/dev/null)"; done
check "every descendant is in the app's group"     no  "$(has " $MY_PGID" "$KIDGROUPS")"

# The children are exactly what the old witnesses cannot see. If this check ever goes green for
# the wrong reason -- a fixture whose argv happens to carry the signature -- then every "the new
# channel found it" check below would be satisfied by the old channel too.
SIGHITS=0
for p in "${TREE[@]}"; do
    [[ "$p" == "$APP" ]] && continue
    pid_is_app "$p" te && SIGHITS=$((SIGHITS + 1))
done
check "no descendant carries the app's signature"  0 "$SIGHITS"

# --- 3. the process-group channel -------------------------------------------------
echo "the process group channel"

mapfile -t GRP < <(app_group_pids "$APP")
check "app_group_pids finds the whole group"       yes "$( (( ${#GRP[@]} >= 3 )) && echo yes || echo no)"
check "  including a child with no signature"      yes "$(has " ${TREE[1]} " " ${GRP[*]} ")"
check "  and not this shell"                       no  "$(has " $$ " " ${GRP[*]} ")"

# 🔴 The refusal that keeps the mechanism from turning on its owner.
app_group_pids "$MY_PGID" >/dev/null 2>&1
check "app_group_pids REFUSES this shell's group (rc 2)" 2 "$?"
check "  and prints nothing for it"                ""  "$(app_group_pids "$MY_PGID" 2>/dev/null)"
app_group_pids 1 >/dev/null 2>&1
check "app_group_pids refuses pgid 1"              2 "$?"
app_group_pids "" >/dev/null 2>&1
check "app_group_pids refuses an empty pgid"       2 "$?"

# --- 4. the log-fd channel --------------------------------------------------------
echo "the log-writer channel (who holds the log open, not who mentions it)"

mapfile -t WRITERS < <(app_log_writers te)
check "the log's writers are found"                yes "$( (( ${#WRITERS[@]} >= 2 )) && echo yes || echo no)"
check "  including a child with no signature"      yes "$(has " ${TREE[1]} " " ${WRITERS[*]} ")"

# A READER of the same file must not be reported: `tail -f` on a log is not the app, and this is
# the difference between "holds the fd" and "holds it for writing".
tail -f "$(app_logfile te)" >/dev/null 2>&1 &
READER=$!
echo "$READER" >> "$FIXTURE_REG"
sleep 0.5
mapfile -t WRITERS2 < <(app_log_writers te)
check "a reader of the log is NOT a writer"        no  "$(has " $READER " " ${WRITERS2[*]} ")"
kill -TERM "$READER" 2>/dev/null; wait "$READER" 2>/dev/null

check "an app with no log of its own has no writers" "" "$(app_log_writers nsr)"

# A channel that names half the machine is broken, not prolific -- and these pids get signalled.
# Both other channels are silenced for this one check, so what is being read is the discard and
# not the group channel's own (correct) answer about the live fixture.
app_log_writers() { seq 2 200; }
app_recorded_pgid() { return 1; }
app_survivors te
check "a channel naming 199 processes is discarded" 0 "${#APP_SURVIVORS[@]}"
check "  and says so instead of reporting clean"    yes "$(has "broken channel" "$APP_SURVIVOR_BLIND")"
unset -f app_log_writers app_recorded_pgid
# shellcheck source=/dev/null
source "$NDT" >/dev/null 2>&1                        # restore the real one
REPO="$TMPROOT"
app_sig() { case "$1" in te) echo "$FIXSIG" ;; esac; }

# --- 5. the verifier, on its own ---------------------------------------------------
#
# Separately from stop, because the verifier is the only thing standing between "the signal was
# sent" and "the app is gone", and every other check here would stay green if it were replaced
# by `return 0`. A gate that cannot see that is a gate that would sign off on the 09-02 message.
echo "the verifier"

app_verify_stopped te >/dev/null 2>&1
check "🔴 the verifier says NO while the app is running" 1 "$?"
VOUT="$(app_verify_stopped te 2>&1)"
check "  and names a pid it can see"               yes "$(has "${TREE[1]}" "$VOUT")"

# A stop whose signals do nothing must not print `ok ... stopped`. This is the 2026-09-02
# transcript in miniature: STOP_RC=0 and "ok viz stopped", with the app still running.
app_kill_group() { return 0; }
app_kill_pid() { return 0; }
app_kill_by_existence() { return 0; }
OUT="$(app_stop te 2>&1)"; RC=$?
check "🔴 a stop that killed nothing returns 1"    1 "$RC"
check "  and does not say 'stopped'"               no  "$(has "te stopped" "$OUT")"
check "  and the app is indeed still running"      yes "$(yn pid_is_app "$APP" te)"
unset -f app_kill_group app_kill_pid app_kill_by_existence
# shellcheck source=/dev/null
source "$NDT" >/dev/null 2>&1
REPO="$TMPROOT"
app_sig() { case "$1" in te) echo "$FIXSIG" ;; esac; }

# A child that ignores SIGTERM is stopped anyway, and is not reported gone until it is. What
# makes this checkable at all is that the proof is EXISTENCE: pid_is_app answers "not this app"
# for a process carrying no signature, so a killer that asks it reports success immediately --
# about a process that is still there. That is the false-success shape this whole file is about.
cat > "$FIXDIR/$FIXSTUBBORN" <<EOF
#!/usr/bin/env bash
trap '' TERM
end=\$(( SECONDS + $FIXTURE_TTL ))
while (( SECONDS < end )); do sleep 0.2; done
EOF
chmod +x "$FIXDIR/$FIXSTUBBORN"
setsid "$FIXDIR/$FIXSTUBBORN" >/dev/null 2>&1 &
STUBBORN=$!
echo "$STUBBORN" >> "$FIXTURE_REG"
sleep 0.5
check "the stubborn fixture is alive and ignoring TERM" yes \
      "$(kill -TERM "$STUBBORN" 2>/dev/null; sleep 1; yn test -d "/proc/$STUBBORN")"
app_kill_by_existence "$STUBBORN" te "a fixture that ignores TERM" >/dev/null 2>&1
check "🔴 a TERM-ignoring child is escalated to KILL" 0 "$?"
check "  and it really is gone"                    no  "$(yn test -d "/proc/$STUBBORN")"

# --- 6. stop kills the whole tree -------------------------------------------------
echo "stop"

mapfile -t BEFORE < <(descendants "$APP")
OUT="$(app_stop te 2>&1)"; RC=$?
sleep 1
LEFT="$(printf '%s\n' "${BEFORE[@]}" | alive_count)"
check "stop returns 0"                             0 "$RC"
check "🔴 nothing of the tree survives"            0 "$LEFT"
# Separately from the tree, because they are different claims. The line above is about the pids
# that existed when the stop began; this one is about the GROUP, which also contains whatever
# was born after that list was taken -- the child the depth-0 worker hands off to when it is
# TERMed. A stop that kills a pid list empties the first and not the second.
check "🔴 the app's process group is empty"        0 "$( { app_group_pids "$APP" || true; } | grep -c . )"
check "  and it says what it verified"             yes "$(has "no process group, log writer or listener left" "$OUT")"
check "  the group is named in the transcript"     yes "$(has "process group $APP" "$OUT")"
check "the pidfile is gone"                        no  "$(yn test -e "$(app_pidfile te)")"
check "the .pgid file is gone"                     no  "$(yn test -e "$(app_pgidfile te)")"

# The log stops growing, which is the disk half of the finding.
B1="$(stat -c %s "$(app_logfile te)" 2>/dev/null)"; sleep 1
B2="$(stat -c %s "$(app_logfile te)" 2>/dev/null)"
check "the log stops growing after stop"           "$B1" "$B2"

# --- 7. the 09-02 state: the launcher is dead, the children are not ---------------
echo "orphaned children (no pidfile, no signature, still running)"

APP2="$(start_app)"
mapfile -t TREE2 < <(descendants "$APP2")
kill -TERM "$APP2" 2>/dev/null; sleep 1
rm -f "$(app_pidfile te)"                           # the crash took the pidfile with it
KIDS_ALIVE="$(printf '%s\n' "${TREE2[@]:1}" | alive_count)"
check "the launcher is gone and the children are not" yes "$( (( KIDS_ALIVE >= 1 )) && [[ ! -d "/proc/$APP2" ]] && echo yes || echo no)"

# The argv scan cannot see them, and that is the point: it is what answered "no" on 09-02.
SNAP=""
app_ps_snapshot() { [[ -n "$SNAP" ]] && printf '%s\n' "$SNAP"; return 0; }
app_probe te
check "the pidfile-and-argv probe says not-running" not-running "$APP_STATE"

OUT="$(apps_orphans 2>&1)"; RC=$?
check "🔴 apps orphans exits 1 (it answered 0 on 09-02)" 1 "$RC"
check "  names the app"                            yes "$(has "te: children with no pidfile" "$OUT")"
check "  names a surviving pid"                    yes "$(has "${TREE2[1]}" "$OUT")"
check "  and names the channel that found it"      yes "$(has "writing to" "$OUT")"

OUT="$(app_stop te 2>&1)"; RC=$?
sleep 1
check "stop of an orphan returns 0"                0 "$RC"
check "🔴 the orphaned children are gone"          0 "$(printf '%s\n' "${TREE2[@]}" | alive_count)"
check "  and it did not call them 'not running'"   no  "$(has "te not running" "$OUT")"

# --- 8. 🔴 the other direction: the tool must not be its own target ---------------
#
# Each of these runs in a session of its own, started with setsid, and reports back on stdout.
# A version of app_kill_group that signals instead of refusing kills THAT process; the check
# then sees no report and goes red, instead of this suite dying with it.
echo "refusals (a stop that kills its own caller is not a better stop)"

cat > "$TMPROOT/selfgroup.sh" <<'HELPER'
#!/usr/bin/env bash
# $1 = ndt under test, $2 = mode, $3 = a temp root of its own, $4 = the fixture signature
set -uo pipefail
export NO_COLOR=1
# shellcheck source=/dev/null
source "$1" || { echo "SOURCE-FAILED"; exit 1; }
REPO="$3"
mkdir -p "$REPO/.test_run/pids" "$REPO/.test_run/logs"
app_sig() { case "$1" in te) echo "$FIXSIG" ;; esac; }
mine="$(proc_pgid "$$")"
case "$2" in
    refuse-own-group)
        app_kill_group "$mine" te 1 >/dev/null 2>&1; rc=$?
        echo "SURVIVED rc=$rc pgid=$mine"
        ;;
    uncorroborated-file-group)
        # A group id from the .pgid file that nothing else confirms. It is signalled only with
        # corroboration, because an empty group's id is reused like any other pid -- and the
        # target here is a live group with a process in it.
        setsid bash -c 'sleep 30' >/dev/null 2>&1 &
        victim=$!
        sleep 0.5
        vg="$(proc_pgid "$victim")"
        app_kill_group "$vg" te 0 >/dev/null 2>&1; rc=$?
        sleep 1
        [[ -d "/proc/$victim" ]] && alive=yes || alive=no
        kill -KILL "$victim" 2>/dev/null
        echo "REFUSED rc=$rc victim_alive=$alive"
        ;;
    stop-app-in-my-own-group)
        # An app started by an ndt from before this fix: no session of its own, so its group IS
        # the caller's. Stop must not signal that group -- and must still finish the job through
        # the channel that does not need one.
        fix="$3/fixture"
        ( cd "$fix" && exec nohup "./$4" >>"$REPO/.test_run/logs/app_te.log" 2>&1 ) &
        pid=$!
        echo "$pid" > "$REPO/.test_run/pids/app_te.pid"
        sleep 2
        out="$(app_stop te 2>&1)"; rc=$?
        sleep 1
        # Counted first, then reaped: the count IS the assertion, and a helper that cleaned up
        # before counting would answer 0 for every version of ndt. The pattern carries this
        # run's own temp root, so no other run's fixtures -- and nothing else on the machine --
        # can match it. Never pkill -f: each pid is read from /proc and signalled by number.
        left=0; leftpids=""
        for p in /proc/[0-9]*; do
            q="${p#/proc/}"
            c="$(tr '\0' ' ' 2>/dev/null < "/proc/$q/cmdline")"
            case "$c" in *"$3/fixture/ndt-groupfix-"*) left=$((left + 1)); leftpids="$leftpids $q" ;; esac
        done
        echo "SURVIVED rc=$rc left=$left refused=$(case "$out" in *"refusing to signal it"*) echo yes ;; *) echo no ;; esac)"
        for q in $leftpids; do kill -TERM "$q" 2>/dev/null; done
        sleep 1
        for q in $leftpids; do [[ -d "/proc/$q" ]] && kill -KILL "$q" 2>/dev/null; done
        ;;
esac
HELPER
chmod +x "$TMPROOT/selfgroup.sh"

H1="$(setsid bash "$TMPROOT/selfgroup.sh" "$NDT" refuse-own-group "$TMPROOT/h1" "$FIXSIG" 2>/dev/null)"
check "🔴 app_kill_group refuses its own group -- the caller lives" yes "$(has "SURVIVED" "$H1")"
check "  and says so with rc 2"                    yes "$(has "rc=2" "$H1")"

H2="$(setsid bash "$TMPROOT/selfgroup.sh" "$NDT" uncorroborated-file-group "$TMPROOT/h2" "$FIXSIG" 2>/dev/null)"
check "an uncorroborated .pgid group is refused"   yes "$(has "rc=2" "$H2")"
check "  and its members are still alive"          yes "$(has "victim_alive=yes" "$H2")"

mkdir -p "$TMPROOT/h3"; cp -r "$FIXDIR" "$TMPROOT/h3/fixture"
# 🔴 Without NDT_GROUPFIX_CLOSE_STDOUT: with no group to signal, the log fd is the only
# channel left, and this case may only claim "stopped anyway" for children it can reach.
H3="$(env -u NDT_GROUPFIX_CLOSE_STDOUT setsid bash "$TMPROOT/selfgroup.sh" "$NDT" stop-app-in-my-own-group "$TMPROOT/h3" "$FIXSIG" 2>/dev/null)"
check "🔴 stopping an app that shares the caller's group does not kill the caller" \
      yes "$(has "SURVIVED" "$H3")"
check "  the group signal is refused, with a reason" yes "$(has "refused=yes" "$H3")"
check "  and the app is stopped anyway (log fd)"   yes "$(has "left=0" "$H3")"

# --- 9. the disk half: the log has a size, a threshold, and a way down ------------
echo "log size (875 MB in 1h54m, on a filesystem at 85%)"

APP3="$(start_app)"
sleep 2
SIZE="$(app_log_bytes te)"
check "app_log_bytes reports a size"               yes "$( [[ "$SIZE" =~ ^[0-9]+$ ]] && (( SIZE > 0 )) && echo yes || echo no)"
OUT="$(apps_status 2>&1)"
check "apps status prints the log size"            yes "$(has "log " "$OUT")"

APP_LOG_MAX_BYTES=512
OUT="$(apps_status 2>&1)"
check "  and warns when it is over the cap"        yes "$(has "over 512 B" "$OUT")"

PRE="$(app_log_bytes te)"
OUT="$(apps_trim te 2>&1)"
POST="$(app_log_bytes te)"
check "trim truncates the log"                     yes "$( (( POST < PRE )) && echo yes || echo no)"
check "  keeps the tail"                           yes "$(yn test -s "$(app_logfile te).tail")"
check "  and says what it did"                     yes "$(has "truncated" "$OUT")"
# 🔴 The property that makes truncation work at all: app_spawn opens the log with `>>`, so the
# writer's next line lands at offset 0. Opened with `>` the offset survives the truncate and the
# file jumps straight back to its old size as a sparse file -- `du` drops, `ls -l` does not, and
# the disk is not saved.
sleep 2
AFTER="$(app_log_bytes te)"
check "🔴 the running app resumes at offset 0"     yes "$( (( AFTER < PRE )) && echo yes || echo no)"
check "  and is still running"                     yes "$(yn pid_is_app "$APP3" te)"

APP_LOG_MAX_BYTES=268435456
OUT="$(apps_trim te 2>&1)"
check "trim leaves an under-cap log alone"         yes "$(has "left alone" "$OUT")"

app_stop te >/dev/null 2>&1

# --- 10. and the same verb on a clean machine -------------------------------------
#
# The other direction for group 7: a pre-run gate that answers "orphan" for every app is as
# useless as one that answers "clean" for every app, and it stops every measurement instead of
# none. Asked here after everything above has been stopped.
echo "the same question, with nothing running"

OUT="$(apps_orphans 2>&1)"; RC=$?
check "a clean machine has no orphans (rc 0)"      0 "$RC"
check "  and it says so"                           yes "$(has "no untracked app processes" "$OUT")"

# --- done -------------------------------------------------------------------------
LEAKED="$(printf '%s\n' "$(cat "$FIXTURE_REG")" | alive_count)"
check "this suite leaked no fixtures"              0 "$LEAKED"

echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
