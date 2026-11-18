#!/usr/bin/env bash
#
# `stack.sh stop <name>...` stops the named components and nothing else.
#
# [Co-developed with claude code -- Adam]
#
# `stack.sh down` stops all three components (kernel, p4_proxy, ryu) and then asserts that the port
# table is clear. A caller that started only some of them -- a failed `ndt up` over a stack that was
# already running -- needs the narrower verb: stop the one it started, leave the others, and do not
# call the machine dirty because a component it never touched still holds its port.
#
# What is asserted, and what each stands against:
#   * the named components are stopped and the others keep their process and their registry files
#     (against a `stop` that is `down` with a different name);
#   * a name that is not a component is refused, rc 2, before anything is stopped -- a valid name
#     beside it is not stopped either (against a typo that stops half of what was asked);
#   * no name at all is a usage error, rc 2 (against a `stop` that quietly stops nothing and says ok);
#   * a symlinked pidfile is refused, as stop_one refuses it, and the process behind it is not
#     signalled; so is a pidfile older than the process it names (a recycled number);
#   * no port table is read: a stranger holding a port is not this verb's business;
#   * a component that ended on a fatal signal is reported and fails the command; a dead component
#     that was NOT named has its stale registry files cleared and reported (sweep_orphan_exits), and a
#     live one that was not named is left alone;
#   * a component with no pidfile is nothing to stop: rc 0.
#
# Real processes: each fixture component is a `sleep` in its own session, started so that its parent is
# gone (the way stack.sh's components are), killed by its exact pid at the end, with its own 300 s
# backstop. Nothing here touches a lab, a port, root or the network.
#
# Env:  STACK_UNDER_TEST=<path to a stack.sh>   (the mutation gate points this at a copy)
# Run:  bash tests/shell/test_stack_stop.sh
set -uo pipefail
export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="${STACK_UNDER_TEST:-$HERE/../../tools/test_workflow/stack.sh}"
[[ -r "$STACK" ]] || { echo "no stack.sh at $STACK"; exit 2; }
for sib in components.env ports.sh; do
    [[ -r "$(dirname "$STACK")/$sib" ]] \
        || { echo "stack.sh needs $sib beside it; not at $(dirname "$STACK")/$sib"; exit 2; }
done

PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             %s\n' "$1" "$2"; }
check() { [[ "$2" == "$3" ]] && t_ok "$1" || t_bad "$1" "expected: [$2]  actual: [$3]"; }
has()   { grep -qF -- "$2" <<<"$3" && t_ok "$1" || t_bad "$1" "no match for '$2' in: $3"; }
hasnt() { grep -qF -- "$2" <<<"$3" && t_bad "$1" "unexpected '$2' in: $3" || t_ok "$1"; }
section() { printf '\n%s\n' "$1"; }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/stack-stop-XXXXXX")"
PIDS_STARTED=""
cleanup() {
    local p
    for p in $PIDS_STARTED; do kill -KILL "$p" 2>/dev/null; done
    rm -rf "$FIX"
}
trap cleanup EXIT
export RUN_DIR="$FIX" LOG_DIR="$FIX/logs" PID_DIR="$FIX/pids"
mkdir -p "$LOG_DIR" "$PID_DIR"

# a fixture component: a sleep in its own session whose parent is gone, registered under <name>
# AFTER it started (a pidfile older than its process is stop_one's "recycled number").
spawn() {   # spawn <name>  -- sets SPAWNED to its pid
    local name="$1" pid
    pid="$(bash -c 'setsid sleep 300 >/dev/null 2>&1 & echo $!')"
    PIDS_STARTED="$PIDS_STARTED $pid"
    printf '%s\n' "$pid" > "$PID_DIR/$name.pid"
    SPAWNED="$pid"
}
# alive <pid> -- running, and not a zombie waiting to be reaped
alive() {
    local line rest
    [[ -r "/proc/$1/stat" ]] || { echo gone; return; }
    read -r line < "/proc/$1/stat" 2>/dev/null || { echo gone; return; }
    rest="${line##*) }"
    [[ "${rest%% *}" == Z ]] && { echo gone; return; }
    echo alive
}
reset_fix() {
    local p
    for p in $PIDS_STARTED; do kill -KILL "$p" 2>/dev/null; done
    PIDS_STARTED=""
    rm -rf "$PID_DIR" "$LOG_DIR"; mkdir -p "$PID_DIR" "$LOG_DIR"
}
# run_stack <args> -- the real command, unsourced; its output and then RC=<n>
run_stack() { bash "$STACK" "$@" 2>&1; echo "RC=$?"; }
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }
pidfile_present() { [[ -e "$PID_DIR/$1.pid" || -L "$PID_DIR/$1.pid" ]] && echo present || echo gone; }

# ==========================================================================================
section "1. the named component is stopped, the others are not"
reset_fix; spawn kernel; K="$SPAWNED"; spawn p4_proxy; P="$SPAWNED"; spawn ryu; R="$SPAWNED"
OUT="$(run_stack stop p4_proxy)"
check "stop p4_proxy exits 0"                                   "0" "$(rc_of "$OUT")"
has   "  and says it stopped p4_proxy"                          "stopped p4_proxy" "$OUT"
check "🔴 the proxy process is gone"                            "gone" "$(alive "$P")"
check "  and its pidfile"                                       "gone" "$(pidfile_present p4_proxy)"
check "🔴 the kernel is still running"                          "alive" "$(alive "$K")"
check "🔴 and so is ryu"                                        "alive" "$(alive "$R")"
check "  the kernel's pidfile is untouched"                     "$K" "$(cat "$PID_DIR/kernel.pid" 2>/dev/null)"
check "  and ryu's"                                             "$R" "$(cat "$PID_DIR/ryu.pid" 2>/dev/null)"
hasnt "  no teardown banner: this is not 'down'"                "Shutting down" "$OUT"

reset_fix; spawn kernel; K="$SPAWNED"; spawn p4_proxy; P="$SPAWNED"; spawn ryu; R="$SPAWNED"
OUT="$(run_stack stop kernel ryu)"
check "two names: exit 0"                                       "0" "$(rc_of "$OUT")"
check "🔴 the kernel is gone"                                   "gone" "$(alive "$K")"
check "🔴 so is ryu"                                            "gone" "$(alive "$R")"
check "🔴 the proxy, not named, is still running"               "alive" "$(alive "$P")"
check "  and keeps its pidfile"                                 "$P" "$(cat "$PID_DIR/p4_proxy.pid" 2>/dev/null)"

# ==========================================================================================
section "2. a name that is not a component, and no name, are refused before anything is stopped"
reset_fix; spawn kernel; K="$SPAWNED"
OUT="$(run_stack stop kernel bogus)"
check "🔴 an unknown name beside a valid one: rc 2"             "2" "$(rc_of "$OUT")"
has   "  the refusal names it"                                  "bogus" "$OUT"
check "🔴 and the valid one was not stopped either"             "alive" "$(alive "$K")"
OUT="$(run_stack stop)"
check "no name at all: rc 2"                                    "2" "$(rc_of "$OUT")"
has   "  with a usage line"                                     "usage" "$OUT"
check "  and nothing was stopped"                               "alive" "$(alive "$K")"

# ==========================================================================================
section "3. stop_one's refusals carry over: a symlinked pidfile, and a pidfile older than its process"
reset_fix; spawn p4_proxy; P="$SPAWNED"
mv "$PID_DIR/p4_proxy.pid" "$FIX/real.pid"; ln -s "$FIX/real.pid" "$PID_DIR/p4_proxy.pid"
OUT="$(run_stack stop p4_proxy)"
check "🔴 a symlinked pidfile is refused: rc 1"                 "1" "$(rc_of "$OUT")"
has   "  and says it is a symlink"                              "is a symlink; refusing to read it" "$OUT"
check "🔴 the process behind it was not signalled"              "alive" "$(alive "$P")"

reset_fix
touch -d '1 hour ago' "$PID_DIR/p4_proxy.pid"
spawn p4_proxy; P="$SPAWNED"; touch -d '1 hour ago' "$PID_DIR/p4_proxy.pid"
OUT="$(run_stack stop p4_proxy)"
check "🔴 a pidfile older than its process is a recycled number: rc 1" "1" "$(rc_of "$OUT")"
has   "  and says so"                                           "a different process that reuses the number" "$OUT"
check "🔴 that process was left alone"                          "alive" "$(alive "$P")"

# ==========================================================================================
section "4. a component with no pidfile is nothing to stop"
reset_fix; spawn kernel; K="$SPAWNED"
OUT="$(run_stack stop ryu)"
check "no pidfile: rc 0"                                        "0" "$(rc_of "$OUT")"
hasnt "  and nothing is said to be stopped"                     "stopped" "$OUT"
check "  the kernel was not touched"                            "alive" "$(alive "$K")"

# ==========================================================================================
section "5. no port table is read"
# `down` ends by reading every row of the port table and failing on a held port. `stop` must not:
# the ports a component it did not name still holds are not its concern. The reading is replaced by
# a recorder in a sourced shell, so no port needs to be held.
reset_fix; spawn p4_proxy; P="$SPAWNED"
: > "$FIX/port_reads"
OUT="$(bash -c "source '$STACK' >/dev/null 2>&1
ndt_port_open() { echo \"\$1\" >> '$FIX/port_reads'; return 0; }
ndt_port_rows() { echo 'x' >> '$FIX/port_reads'; }
cmd_stop p4_proxy; echo \"RC=\$?\"" 2>&1)"
check "stop p4_proxy through the function: exit 0"              "0" "$(rc_of "$OUT")"
check "🔴 no port was read"                                     "0" "$(wc -l < "$FIX/port_reads" | tr -d ' ')"
check "  and the proxy is stopped"                              "gone" "$(alive "$P")"

# ==========================================================================================
section "6. endings are reported, the stale registry of a component that was not named is cleared"
reset_fix; spawn kernel; K="$SPAWNED"
printf 'status=134\nreason=killed by SIGABRT\n' > "$PID_DIR/p4_proxy.exit"
OUT="$(run_stack stop p4_proxy)"
has   "a fatal ending of the named component is reported"       "p4_proxy did not stop cleanly: killed by SIGABRT" "$OUT"
check "🔴 and fails the command"                                "1" "$(rc_of "$OUT")"
check "  the record is delivered once"                          "gone" "$([[ -e "$PID_DIR/p4_proxy.exit" ]] && echo present || echo gone)"
check "  the unnamed kernel is still running"                   "alive" "$(alive "$K")"

reset_fix; spawn kernel; K="$SPAWNED"
printf '99999999\n' > "$PID_DIR/ryu.pid"; printf '99999999\n' > "$PID_DIR/ryu.child.pid"
printf 'status=0\nreason=exited\n' > "$PID_DIR/ryu.exit"
touch -d '1 hour ago' "$PID_DIR/ryu.pid"
OUT="$(run_stack stop kernel)"
check "stopping the kernel"                                     "0" "$(rc_of "$OUT")"
has   "🔴 a dead component that was not named has its stale registry cleared, and it says so" "cleared ryu's stale registry files" "$OUT"
check "  its pidfile is gone"                                   "gone" "$(pidfile_present ryu)"

# ==========================================================================================
printf '\nRan %d checks, %d failed\n' "$((PASS+FAIL))" "$FAIL"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
