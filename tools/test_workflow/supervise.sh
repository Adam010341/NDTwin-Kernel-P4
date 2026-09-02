#!/usr/bin/env bash
#
# supervise.sh <state-prefix> <command...>
#
# Runs <command...> and records HOW IT ENDED. Nothing else: no restart, no policy, no output of
# its own on the child's streams, which it inherits unchanged.
#
# [Co-developed with claude code -- Adam]
# KNOWN-ISSUES B-5. Before this, a kernel that aborted on shutdown and a kernel that stopped
# cleanly left identical evidence. start_bg launched the component with `setsid "$@" ... &` and
# never waited for it; stop_one polled `kill -0` until the pid disappeared. A pid disappearing is
# all either of them ever knew, and "it exited" and "it exited cleanly" are not the same claim.
# The kernel had been aborting with SIGABRT on every Ctrl-C shutdown for as long as the defect
# existed, and no log in this repository could have shown it.
#
# What gets written, beside the pidfile:
#
#   <prefix>.child.pid   the pid actually running <command...>, which is NOT the pid start_bg
#                        records. start_bg records this supervisor (the process-group leader that
#                        stop_one signals); the process that does the work is one level down, and
#                        every earlier attempt to reason about "the kernel's pid" was reasoning
#                        about a wrapper. Both numbers are now on disk, each labelled.
#   <prefix>.exit        status / signal / reason / when, written before this script exits
#   <prefix>.exit.log    one line per run, appended -- the history .exit cannot keep, since the
#                        next start overwrites it
#
# Deliberately NOT written to the child's stdout, which start_bg has pointed at the component's
# log. Two reasons, and the second is the one that matters: tools/contract_test/check_logs.py
# fails a log containing "SIGABRT", so a line of this script's own prose would become the
# evidence for a crash that the runtime is perfectly capable of reporting itself. An instrument
# that can trip its own detector cannot be used to tell you whether the thing it watches failed.
#
# The exit status is propagated: this script exits with exactly what the child returned, so a
# caller that does wait for it sees the child's answer rather than this script's.
#
# LIMIT, stated because it is the one thing a reader would otherwise assume away: bash's `wait`
# reports a signal death as 128+signum and cannot distinguish it from a plain exit() of the same
# number. For the kernel the distinction is not in doubt -- main returns 0 or EXIT_FAILURE -- so
# any 128+N from it is a signal, and .exit says which reading is which rather than picking one
# silently.
set -uo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: supervise.sh <state-prefix> <command...>" >&2
    exit 2
fi

PREFIX="$1"; shift

# A previous run's answer must not be readable as this one's. Removed before the child starts, so
# the window in which a stale file could be believed is closed at the earliest possible moment.
rm -f "$PREFIX.exit" "$PREFIX.child.pid"

"$@" &
CHILD=$!
echo "$CHILD" >"$PREFIX.child.pid"

# Forwarded for the case stop_one does NOT cover: a signal sent to this pid alone (`kill $pid`
# read out of the pidfile) rather than to the process group. stop_one sends `kill -TERM -$pid`,
# which the child already receives directly; the duplicate is harmless.
forward() { kill -"$1" "$CHILD" 2>/dev/null; }
trap 'forward TERM' TERM
trap 'forward INT' INT
trap 'forward HUP' HUP

# `wait` returns 128+signum when the SHELL is interrupted by a trapped signal, which is not the
# child's answer. Re-wait while the child is still alive.
RC=0
while :; do
    wait "$CHILD"; RC=$?
    (( RC > 128 )) && kill -0 "$CHILD" 2>/dev/null && continue
    break
done

SIG=""
REASON="exited normally with status $RC"
if (( RC == 0 )); then
    REASON="exited cleanly (status 0)"
elif (( RC > 128 && RC < 192 )); then
    SIG=$(( RC - 128 ))
    SIGNAME="$(kill -l "$SIG" 2>/dev/null || echo "signal $SIG")"
    REASON="terminated by SIG$SIGNAME ($SIG) -- or exit($RC), which bash cannot distinguish"
    if (( SIG == 6 )); then
        REASON="ABORTED: SIGABRT ($SIG). A C++ runtime abort -- check the log above for"
        REASON="$REASON 'terminate called', which is what a joinable std::thread destroyed at"
        REASON="$REASON shutdown prints"
    fi
fi

{
    echo "status=$RC"
    echo "signal=${SIG:-none}"
    echo "child_pid=$CHILD"
    echo "supervisor_pid=$$"
    echo "at=$(date -Is)"
    echo "command=$*"
    echo "reason=$REASON"
} >"$PREFIX.exit"

# The history .exit cannot keep: it is overwritten by the next start, and "the kernel aborted on
# the run before last" is exactly the kind of thing that gets erased before anyone looks.
printf '%s\tstatus=%s\tchild=%s\t%s\n' "$(date -Is)" "$RC" "$CHILD" "$REASON" >>"$PREFIX.exit.log"

exit "$RC"
