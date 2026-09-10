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
STACK="$REPO/tools/test_workflow/stack.sh"
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
