#!/usr/bin/env bash
#
# The exit-status pipeline: supervise.sh, start_bg and stop_one. KNOWN-ISSUES B-5.
#
# [Co-developed with claude code -- Adam]
#
# What this exists for: before it, "the kernel exited" and "the kernel exited cleanly" were the
# same observation. start_bg launched every component with `setsid "$@" &` and never waited for
# it; stop_one polled `kill -0` until the number went away. A pid going away is all either of
# them knew. The kernel had been aborting with SIGABRT on every Ctrl-C shutdown -- reproduced
# 7/7 -- and nothing in this repository recorded it, so the defect was not merely unfixed, it was
# unobservable.
#
# The three endings that must stay distinguishable, because they mean different things:
#
#   0    stopped cleanly
#   134  SIGABRT -- the C++ runtime aborted (B-5)
#   143  SIGTERM's default action, which is what `ndt down` produces TODAY on a healthy kernel,
#        since main registers a handler for SIGINT only. This one is NOT a failure, and a
#        pipeline that called every non-zero status a failure would redden every teardown.
#
# Isolation: PID_DIR/LOG_DIR are redirected to a temp directory, no component of the real stack
# is started, and no ndtwin-lab verb is called. Nothing here touches a live lab.
#
# Run:  bash tests/shell/test_supervise_exit_status.sh

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# STACK_UNDER_TEST points this at a COPY, the same seam SUPERVISE_UNDER_TEST is. It is how the
# orphan-sweep group below was seen RED (against the pre-fix stack.sh, 2026-09-11) without
# writing to a file another session may be running -- a copy needs supervise.sh, components.env
# and ports.sh beside it, because stack.sh sources all three from its own directory.
STACK="${STACK_UNDER_TEST:-$REPO/tools/test_workflow/stack.sh}"
# The mutation gate (tests/shell/mutate_supervise_pidfile_cleanup.sh) points this at a COPY.
# The start_bg/stop_one groups below go through stack.sh, which finds supervise.sh beside
# itself and is therefore always the tree's own -- so a mutant is exercised by the groups that
# call this variable directly, which is where the pidfile cleanup lives.
SUPERVISE_SH="${SUPERVISE_UNDER_TEST:-$REPO/tools/test_workflow/supervise.sh}"
CHECK_LOGS="$REPO/tools/contract_test/check_logs.py"

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

TMP="$(mktemp -d -t ndt_supervise_test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export PID_DIR="$TMP/pids" LOG_DIR="$TMP/logs" RUN_DIR="$TMP"
mkdir -p "$PID_DIR" "$LOG_DIR"

field() { sed -n "s/^$2=//p" "$1" 2>/dev/null; }

echo "supervise.sh records how the child ended"

# --- a clean exit ----------------------------------------------------------------------------
bash "$SUPERVISE_SH" "$TMP/clean" bash -c 'exit 0' >/dev/null 2>&1
check "status of a clean exit" "0" "$(field "$TMP/clean.exit" status)"
check "propagates the child's status" "0" "$?"

# --- a non-zero exit -------------------------------------------------------------------------
bash "$SUPERVISE_SH" "$TMP/seven" bash -c 'exit 7' >/dev/null 2>&1
rc=$?
check "status of a failed exit" "7" "$(field "$TMP/seven.exit" status)"
check "propagates a non-zero status" "7" "$rc"
check "a plain exit names no signal" "none" "$(field "$TMP/seven.exit" signal)"

# --- an abort: THE case B-5 is about ---------------------------------------------------------
#
# 🔴 `exit 134`, NOT `kill -ABRT $$`. Raising a real SIGABRT from /usr/bin/bash puts an Ubuntu
# crash-report dialog on the machine owner's screen: apport handles executables that came from a
# package, and bash is one. (The kernel is not, which is why its own aborts never popped one.)
# A test must not do that, and the machine's crash settings are not ours to change.
#
# Nothing is lost here. What this case asserts is that the RECORDING path reads 134 as an abort,
# and supervise.sh gets its number from bash's `wait`, which reports 128+signum for a signal and
# cannot distinguish that from an exit() of the same value -- a limit supervise.sh states rather
# than hides. The genuinely-killed-by-a-signal path is covered further down by the SIGTERM case,
# where the signal is real and no core is dumped.
bash "$SUPERVISE_SH" "$TMP/aborted" bash -c 'exit 134' >/dev/null 2>&1
rc=$?
check "an abort is recorded as 134" "134" "$(field "$TMP/aborted.exit" status)"
check "an abort names signal 6" "6" "$(field "$TMP/aborted.exit" signal)"
check "propagates 134" "134" "$rc"
case "$(field "$TMP/aborted.exit" reason)" in
    *ABORTED*SIGABRT*) check "the reason says it aborted" "yes" "yes" ;;
    *) check "the reason says it aborted" "yes" "no: $(field "$TMP/aborted.exit" reason)" ;;
esac

# --- the pid that did the work, and the history ----------------------------------------------
# 🔴 Read from .exit, not from .child.pid. Both numbers still have to be on disk, each
# labelled -- that is B-5's claim -- but since 2026-09-11 (R7 I-3) supervise.sh removes
# .child.pid on its way out, because after the wait it names a pid that is gone and
# .test_run/pids/ is the registry a teardown signals. The number is not lost: it is child_pid=
# here and child= in .exit.log. Asserting on the transient file would have made this cell an
# argument for keeping a dead number in the registry.
check "the child pid is recorded" "yes" \
    "$([[ -n "$(field "$TMP/aborted.exit" child_pid)" ]] && echo yes || echo no)"
check "the child pid is not the supervisor's" "different" \
    "$([[ "$(field "$TMP/aborted.exit" child_pid)" == "$(field "$TMP/aborted.exit" supervisor_pid)" ]] \
        && echo same || echo different)"
check "🔴 and the transient pidfile is not left naming it" "gone" \
    "$([[ -f "$TMP/aborted.child.pid" ]] && echo present || echo gone)"
# .exit is overwritten by the next run; .exit.log is the part that survives it.
bash "$SUPERVISE_SH" "$TMP/aborted" bash -c 'exit 0' >/dev/null 2>&1
check "the latest .exit is the latest run" "0" "$(field "$TMP/aborted.exit" status)"
check "the abort still exists in the history" "1" \
    "$(grep -c 'status=134' "$TMP/aborted.exit.log" 2>/dev/null)"

# --- through start_bg and stop_one ------------------------------------------------------------
echo
echo "start_bg + stop_one report the ending"

# stack.sh returns early when sourced: this defines its functions without running a command.
# shellcheck source=/dev/null
source "$STACK"

# A component that ends 134 on its own, before anyone asks it to stop -- the shape of a kernel
# that aborts at shutdown and is then "stopped" by a down that finds nothing to kill.
# `exit 134` rather than a real SIGABRT, for the apport reason given above.
start_bg crashy "$LOG_DIR/crashy.log" bash -c 'exit 134' >/dev/null 2>&1
for _ in $(seq 1 20); do [[ -s "$PID_DIR/crashy.exit" ]] && break; sleep 0.2; done
check "start_bg's component has its ending recorded" "134" \
    "$(field "$PID_DIR/crashy.exit" status)"
out="$(stop_one crashy 2>&1)"
case "$out" in
    *"did not stop cleanly"*) check "stop_one reports the abort" "yes" "yes" ;;
    *) check "stop_one reports the abort" "yes" "no: $out" ;;
esac

# The healthy path: a long-lived component stopped by stop_one, which signals the process GROUP.
# 143 must be reported without being called a failure -- it is what `ndt down` does to a kernel
# that has no SIGTERM handler, which is every kernel today.
start_bg sleeper "$LOG_DIR/sleeper.log" bash -c 'exec sleep 300' >/dev/null 2>&1
sleep 0.5
CHILD="$(cat "$PID_DIR/sleeper.child.pid" 2>/dev/null)"
check "the child pid is recorded and alive" "alive" \
    "$(kill -0 "$CHILD" 2>/dev/null && echo alive || echo gone)"
check "the recorded pid leads the child's process group" "same" \
    "$([[ "$(ps -o pgid= -p "$CHILD" | tr -d ' ')" == "$(cat "$PID_DIR/sleeper.pid")" ]] \
        && echo same || echo different)"
out="$(stop_one sleeper 2>&1)"
check "the child really died" "gone" "$(kill -0 "$CHILD" 2>/dev/null && echo alive || echo gone)"
check "a SIGTERM stop is recorded as 143" "143" "$(field "$PID_DIR/sleeper.exit" status)"
case "$out" in
    *"did not stop cleanly"*) check "a normal stop is not called a crash" "yes" "no: $out" ;;
    *) check "a normal stop is not called a crash" "yes" "yes" ;;
esac

# --- the pidfiles it leaves behind (R7 I-3) ---------------------------------------------------
#
# 🔴 Measured 2026-09-11 02:52:03 and again 02:52:27 (hunt-0911/R7-reconciler.md round 14), 57 s
# and 81 s after the event. One directory, two files, opposite stories:
#
#     ryu.pid        20717    /proc/20717 does not exist
#     ryu.child.pid  20722    /proc/20722 does not exist
#     ryu.exit       at=2026-09-11T02:51:06  status=143  reason=terminated by SIGTERM (15)
#
# The exit RECORD was written and the live pidfiles were not removed. stop_one removes them, so
# this only happens when the component was not stopped through stop_one -- an interrupted
# bring-up, an outside kill -- which is precisely when the registry is least explicable.
# .test_run/pids/ is what `ndt down` signals and what ndt's port_owner_local reads to decide a
# listener is "ours", so a dead number left in it is the pid-reuse fuse under both.
#
# 🔴 AND <prefix>.pid IS LEFT ALONE, which is the half that matters and is pinned twice below.
# Removing it as well was tried and this suite went red on `stop_one reports the abort` with an
# empty message: stop_one opens `[[ -f "$pidfile" ]] || return 0`, and report_exit -- the whole
# of B-5's observability -- is behind that gate. The file whose absence proves the component is
# dead is also the file that makes anyone look. A stale <prefix>.pid is DISCLOSED by `ndt
# status` instead (stack_pidfile_row), and whether stop_one should report an orphaned .exit is
# in FIX-NDT-3-SUMMARY section 7.
echo
echo "supervise.sh removes the child pidfile it can prove is dead, and only that one (R7 I-3)"

rm -f "$TMP/mine".*
bash -c 'echo $$ > "$1.pid"; exec bash "$2" "$1" bash -c "exit 143"' _ "$TMP/mine" "$SUPERVISE_SH" >/dev/null 2>&1
check "🔴 the child pidfile is gone once the ending is recorded" "gone" \
    "$([[ -f "$TMP/mine.child.pid" ]] && echo present || echo gone)"
check "🔴 and <prefix>.pid is NOT removed -- stop_one needs it to report the ending" "present" \
    "$([[ -f "$TMP/mine.pid" ]] && echo present || echo gone)"
check "  the ending itself was still recorded" "143" "$(field "$TMP/mine.exit" status)"
check "  the child pid is still readable, from the record" "1" \
    "$([[ -n "$(field "$TMP/mine.exit" child_pid)" ]] && echo 1 || echo 0)"
check "  and the history line too" "1" "$(grep -c 'status=143' "$TMP/mine.exit.log" 2>/dev/null)"

# 🔴 The ordering, asserted rather than assumed: the record is what a reader is sent to when a
# pidfile has gone, so a version that reaped the pidfile and then failed to write .exit would be
# strictly worse than the defect.
rm -f "$TMP/order".*
bash -c 'echo $$ > "$1.pid"; exec bash "$2" "$1" bash -c "exit 0"' _ "$TMP/order" "$SUPERVISE_SH" >/dev/null 2>&1
check "🔴 .exit exists in the state .child.pid does not" "yes" \
    "$([[ -f "$TMP/order.exit" && ! -f "$TMP/order.child.pid" ]] && echo yes || echo no)"

# 🔴 The control that stops "remove the pidfile" from widening into "remove any pidfile": while
# the child is RUNNING, .child.pid must be there -- it is the only place the worker's pid is
# readable before the ending is recorded, and stack.sh:946 reads /proc/<that pid>/comm.
#
# 🔴 Driven through $SUPERVISE_SH and not through start_bg, which is what this cell was written
# with first: start_bg finds supervise.sh BESIDE stack.sh, so a mutant is never the file it runs
# and this cell could not see one. mutate_supervise_pidfile_cleanup.sh M3 reported SURVIVED and
# that is what it was telling us -- the case was asserting a true thing about the wrong file.
rm -f "$TMP/alive2".*
bash "$SUPERVISE_SH" "$TMP/alive2" bash -c 'exec sleep 300' >/dev/null 2>&1 &
SUPPID=$!
for _ in $(seq 1 60); do [[ -s "$TMP/alive2.child.pid" ]] && break; sleep 0.1; done
check "🔴 a RUNNING component still has its child pidfile" "present" \
    "$([[ -s "$TMP/alive2.child.pid" ]] && echo present || echo gone)"
ALIVE2_CHILD="$(cat "$TMP/alive2.child.pid" 2>/dev/null)"
# By recorded pid, never by pattern. supervise.sh forwards TERM to the child it is waiting on.
kill -TERM "$SUPPID" 2>/dev/null
wait "$SUPPID" 2>/dev/null
[[ -n "$ALIVE2_CHILD" ]] && kill -TERM "$ALIVE2_CHILD" 2>/dev/null
check "  and it is gone once that run has ended" "gone" \
    "$([[ -f "$TMP/alive2.child.pid" ]] && echo present || echo gone)"

# --- which endings fail the command ------------------------------------------------------------
#
# The acceptance criteria for making a crash on shutdown fail `ndt down`: an injected fatal
# status must be red, the ordinary 143 must be green, and 0 must be green. 143 is not negotiable:
# it is what `ndt down` produces on every healthy kernel today, because main handles SIGINT only.
echo
echo "cmd_down fails on a fatal ending, and only on one"

for st in 132 134 135 136 137 139; do
    if fatal_exit_status "$st"; then check "status $st is fatal" "yes" "yes"
    else check "status $st is fatal" "yes" "no"; fi
done
for st in 0 1 2 130 143; do
    if fatal_exit_status "$st"; then check "status $st is NOT fatal" "no" "yes"
    else check "status $st is NOT fatal" "no" "no"; fi
done

# Seam: this run has no stack of its own, and cmd_down's other failure mode is a port that is
# still listening. Overriding port_open keeps the verdict below about the ENDINGS, which is what
# these cases are for; the port guard has its own tests.
port_open() { return 1; }

write_exit() { printf 'status=%s\nsignal=%s\nreason=%s\n' "$2" "${3:-none}" "injected by the test" \
    >"$PID_DIR/$1.exit"; }

rm -f "$PID_DIR"/*
write_exit kernel 134 6
out="$(cmd_down 2>&1)"; rc=$?
check "an aborted kernel fails down" "1" "$rc"
case "$out" in *kernel*134*) check "and down names it" "yes" "yes" ;;
               *) check "and down names it" "yes" "no: $out" ;; esac
out="$(cmd_down 2>&1)"; rc=$?
check "the same crash is not reported twice" "0" "$rc"

rm -f "$PID_DIR"/*
write_exit kernel 137 9
out="$(cmd_down 2>&1)"; rc=$?
check "an OOM-killed kernel (137) fails down" "1" "$rc"

rm -f "$PID_DIR"/*
write_exit kernel 143 15
out="$(cmd_down 2>&1)"; rc=$?
check "the ordinary SIGTERM ending (143) does NOT fail down" "0" "$rc"

rm -f "$PID_DIR"/*
write_exit kernel 0
out="$(cmd_down 2>&1)"; rc=$?
check "a clean exit does not fail down" "0" "$rc"
rm -f "$PID_DIR"/*

# --- the orphaned .exit, and the pidfile beside it (FIX-NDT-3 section 7-2) ---------------------
#
# 🔴 stop_one opens `[[ -f "$pidfile" ]] || return 0`, so report_exit -- the whole of B-5's
# observability -- never sees the record of a component whose pidfile has gone. cmd_down's own
# sweep covered the FATAL half by reimplementing report_exit's fatal branch inline; a component
# that ended with a plain non-zero status was read by nobody at all. And the stale pidfile R7
# found sitting beside such a record (I-3, 02:52:03) survived the very command whose own status
# row tells the operator to run it.
#
# Adam's ruling 09-11 (FIX-NDT-4 #19): the sweep calls report_exit, so both halves come out of
# ONE writer, and it clears the registry files of a component that is provably not running.
#
# 🔴 sweep_orphan_exits is driven DIRECTLY here, and cmd_down end-to-end in one case below.
# Through cmd_down alone the interesting states are unreachable: stop_one stops whatever is
# running and removes its pidfile, so "the sweep left a live component's registry alone" cannot
# be constructed at that level -- and that is the direction a careless sweep gets wrong.
echo
echo "the orphan sweep: report the ending, clear only what is provably dead"

# 🔴 NOT `out="$(sweep_orphan_exits)"`. A command substitution is a subshell, so
# STACK_FATAL_ENDINGS would be set in a process that then exits -- and the case that checks it
# would read an empty string and call the sweep silent. Output through a file, function in THIS
# shell, which is also the only way the STACK_EXITS_REPORTED case below means anything.
sweep_now() {
    STACK_FATAL_ENDINGS=""; STACK_EXITS_REPORTED=""
    sweep_orphan_exits >"$TMP/sweep.out" 2>&1
    out="$(cat "$TMP/sweep.out")"
}

# One name per case, so a leftover from the previous case cannot be the reason the next one
# passes. `.exit` records are written by write_exit above.
rm -f "$PID_DIR"/*
write_exit ryu 7
sweep_now
check "🔴 a non-fatal, non-zero ending with no pidfile is NAMED" "yes" \
    "$(case "$out" in *"ryu exit status 7"*) echo yes ;; *) echo "no: $out" ;; esac)"
check "  and it is not called a fatal ending" "" "$STACK_FATAL_ENDINGS"

rm -f "$PID_DIR"/*
write_exit ryu 134 6
sweep_now
check "a FATAL ending with no pidfile is still fatal" "ryu(134)" "$STACK_FATAL_ENDINGS"
check "  and report_exit removed the record it delivered" "gone" \
    "$([[ -f "$PID_DIR/ryu.exit" ]] && echo present || echo gone)"

# The stale pidfile R7 read out of .test_run/pids/, beside the record that explains it.
rm -f "$PID_DIR"/*
DEAD_PID="$(bash -c 'echo $$')"
if [[ "$DEAD_PID" =~ ^[0-9]+$ && ! -d "/proc/$DEAD_PID" ]]; then
    write_exit ryu 143 15
    echo "$DEAD_PID" > "$PID_DIR/ryu.pid"
    echo "$DEAD_PID" > "$PID_DIR/ryu.child.pid"
    printf 'ryu-manager\n' > "$PID_DIR/ryu$CMD_SUFFIX"
    sweep_now
    check "🔴 R7 I-3: the pidfile naming a dead pid is swept" "gone" \
        "$([[ -f "$PID_DIR/ryu.pid" ]] && echo present || echo gone)"
    check "  and the child pidfile with it" "gone" \
        "$([[ -f "$PID_DIR/ryu.child.pid" ]] && echo present || echo gone)"
    check "  and the recorded command line" "gone" \
        "$([[ -f "$PID_DIR/ryu$CMD_SUFFIX" ]] && echo present || echo gone)"
    check "  the ending was reported while doing it" "yes" \
        "$(case "$out" in *"ryu exit status 143"*) echo yes ;; *) echo "no: $out" ;; esac)"
    check "  and it says which files it removed, not just that it did" "yes" \
        "$(case "$out" in *"ryu.pid"*) echo yes ;; *) echo "no: $out" ;; esac)"
else
    check "could not get a provably dead pid -- this group did NOT run" "skipped" "skipped"
fi

# 🔴 THE OTHER DIRECTION, and the one a careless sweep gets wrong: a component that is RUNNING
# keeps its registry. "Clear the stale ones" turning into "clear them" would delete the files
# `ndt down` signals and port_owner_verdict reads, out from under a live stack.
rm -f "$PID_DIR"/*
( exec -a "/nonexistent/NDT-TEST-FIXTURE/ryu-live" sleep 30 ) >/dev/null 2>&1 </dev/null &
LIVE_PID=$!
echo "$LIVE_PID" > "$PID_DIR/ryu.pid"
write_exit ryu 0
sweep_now
check "🔴 a LIVE component's pidfile is NOT swept" "present" \
    "$([[ -f "$PID_DIR/ryu.pid" ]] && echo present || echo gone)"
check "  and its old record is not reported over it" "" \
    "$(case "$out" in *"ryu exit status"*) echo "reported: $out" ;; *) echo "" ;; esac)"
kill -KILL "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null

# 🔴 One report per ending, not two. stop_one reports what it stopped, and a non-fatal record is
# deliberately NOT removed by report_exit (the next start_bg clears it), so without an
# accumulator the sweep announces the same ending a second time in the same teardown.
rm -f "$PID_DIR"/*
STACK_FATAL_ENDINGS=""; STACK_EXITS_REPORTED=""
write_exit ryu 143 15
{ report_exit ryu; sweep_orphan_exits; } >"$TMP/sweep.out" 2>&1
out="$(cat "$TMP/sweep.out")"
check "🔴 an ending stop_one already reported is not reported again" "1" \
    "$(grep -c 'ryu exit status 143' <<<"$out")"

# ...and end to end, which is the statement the finding is about: `ndt down` reports the ending
# of a component whose pidfile has gone.
rm -f "$PID_DIR"/*
STACK_FATAL_ENDINGS=""; STACK_EXITS_REPORTED=""
write_exit ryu 7
out="$(cmd_down 2>&1)"; rc=$?
check "🔴 cmd_down names the orphaned ending" "yes" \
    "$(case "$out" in *"ryu exit status 7"*) echo yes ;; *) echo "no: $out" ;; esac)"
check "  and a non-fatal one does not fail the teardown" "0" "$rc"
rm -f "$PID_DIR"/*

# --- the log gate must recognise the message the kernel actually printed ----------------------
echo
echo "check_logs.py fails a log containing the B-5 abort"

printf 'terminate called without an active exception\n' >"$TMP/aborted.log"
"$CHECK_LOGS" "$TMP/aborted.log" >"$TMP/checkout.txt" 2>&1
check "an aborted log is failed, not passed" "1" "$?"
case "$(cat "$TMP/checkout.txt")" in
    *CRASH*|*crash*) check "and it is reported as a crash" "yes" "yes" ;;
    *) check "and it is reported as a crash" "yes" "no" ;;
esac

echo
if [[ $FAIL -gt 0 ]]; then
    echo "Ran $((PASS + FAIL)) checks, $FAIL failed"
    exit 1
fi
echo "Ran $((PASS + FAIL)) checks, all passed"
