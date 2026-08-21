#!/usr/bin/env bash
# The teardown guards, driven against the shipped scripts.
#
# [Co-developed with claude code -- Adam]
# Each case here is a defect that was reproduced live before it was fixed:
#
#   * `stop_one` killed whatever pid was in the pidfile -- and it sends `kill -TERM -$pid`, the
#     whole process GROUP -- with no check that the number still belonged to the process it
#     recorded. An unrelated process was killed, "stopped kernel" printed, the teardown
#     assertion went five for five and the exit code was 0.
#   * `app_stop` claimed "same pid hygiene as stop_one" while copying only the pid<2 check, so a
#     pidfile replaced by a symlink was followed and the target killed, reporting success.
#   * `in_flight` matched the bare string `iperf3`, so an idle server that was serving nothing
#     blocked every teardown, with `--force` as the only way out -- training the habit that
#     disarms the guard for the run it exists to protect.
#
# The negative cases matter as much as the positive ones: a guard that refuses everything is
# indistinguishable from a broken teardown, so this also asserts that a process the stack really
# did start is still stopped.
#
# Isolation: PID_DIR is redirected to a temp directory (components.env takes it from the
# environment), so the shared .test_run/pids/ is never written. No ndtwin-lab verb is called and
# `mn -c` never runs, so a live lab is unaffected.
#
# Run:  bash tools/test_workflow/test_teardown_guards.sh
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STACK="$HERE/stack.sh"

TMP="$(mktemp -d -t ndt_teardown_test.XXXXXX)"
export PID_DIR="$TMP/pids" LOG_DIR="$TMP/logs" RUN_DIR="$TMP"
mkdir -p "$PID_DIR" "$LOG_DIR"
pass=0; fail=0
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

say() { if [[ "$1" == ok ]]; then printf '  ok    %s\n' "$2"; pass=$(( pass + 1 ));
        else printf '  FAIL  %s\n' "$2"; fail=$(( fail + 1 )); fi; }

# A detached victim, located by reading /proc directly -- no pattern ever enters an argv, so
# nothing here can be matched by `mn -c`'s pkill or by itself.
victim() {
    setsid sleep "$1" >/dev/null 2>&1 &
    sleep 0.4
    local d args
    for d in /proc/[0-9]*; do
        args="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
        [[ "$args" == "sleep $1 " ]] && { echo "${d#/proc/}"; return 0; }
    done
    return 1
}

echo "stop_one: a pid that started after its pidfile is a different process"
V="$(victim 901)" || { echo "could not start a victim"; exit 1; }
echo "$V" > "$PID_DIR/kernel.pid"
touch -d '5 minutes ago' "$PID_DIR/kernel.pid"   # what a recycled pid looks like
out="$(NO_COLOR=1 bash "$STACK" down 2>&1)"
kill -0 "$V" 2>/dev/null && say ok "the unrelated process survived" || say FAIL "it was killed"
case "$out" in *"refusing to stop kernel"*) say ok "the refusal is explained";;
               *) say FAIL "no refusal message";; esac
[[ -f "$PID_DIR/kernel.pid" ]] && say ok "the stale pidfile is kept, not silently removed" \
                               || say FAIL "pidfile removed"
kill -KILL "$V" 2>/dev/null; rm -f "$PID_DIR"/*

echo "stop_one: a process the stack really started is still stopped"
V="$(victim 902)" || exit 1
echo "$V" > "$PID_DIR/kernel.pid"                # written after it started: legitimate
NO_COLOR=1 bash "$STACK" down >/dev/null 2>&1
sleep 1
if kill -0 "$V" 2>/dev/null; then say FAIL "legitimate process NOT stopped -- guard too strict"
                                  kill -KILL "$V" 2>/dev/null
else say ok "legitimate process stopped"; fi
[[ -f "$PID_DIR/kernel.pid" ]] && { say FAIL "pidfile left behind"; rm -f "$PID_DIR"/*; } \
                               || say ok "pidfile cleared"

echo "app_stop: a symlinked pidfile is refused"
V="$(victim 903)" || exit 1
echo "$V" > "$TMP/elsewhere.pid"
mkdir -p "$REPO/.test_run/pids"
LINK="$REPO/.test_run/pids/app_nsr.pid"
if [[ -e "$LINK" || -L "$LINK" ]]; then
    say FAIL "$LINK already exists; refusing to disturb it (skipping this case)"
else
    ln -s "$TMP/elsewhere.pid" "$LINK"
    out="$(cd "$REPO" && NO_COLOR=1 ./tools/test_workflow/ndt apps stop nsr 2>&1)"; rc=$?
    kill -0 "$V" 2>/dev/null && say ok "the link target survived" || say FAIL "killed through the link"
    (( rc != 0 )) && say ok "non-zero exit" || say FAIL "reported success (rc=$rc)"
    case "$out" in *symlink*) say ok "the refusal is explained";; *) say FAIL "no symlink message";; esac
    rm -f "$LINK"
fi
kill -KILL "$V" 2>/dev/null

echo "in_flight: an idle iperf3 server is not a measurement; a client is"
eval "$(sed -n '/^in_flight() {/,/^}/p' "$HERE/ndt")"
probe() { printf '%s\n' "$1" | { while read -r line; do
        for cmd in matrix.sh measure.sh cpu_probe.py; do
            case "$line" in *"$cmd"*) echo BUSY; continue 2 ;; esac
        done
        case "$line" in *"iperf3 -c"*|*"iperf3 --client"*) echo BUSY ;; *) echo idle ;; esac
    done; }; }
for spec in "iperf3 -s:idle" "iperf3 -s -p 5299:idle" "iperf3 -c 10.0.0.2 -t 30:BUSY" \
            "iperf3 --client 10.0.0.2:BUSY" "bash matrix.sh 5:BUSY" "sleep 60:idle"; do
    line="${spec%:*}"; want="${spec##*:}"; got="$(probe "$line")"
    [[ "$got" == "$want" ]] && say ok "$line -> $got" || say FAIL "$line -> $got (want $want)"
done

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
