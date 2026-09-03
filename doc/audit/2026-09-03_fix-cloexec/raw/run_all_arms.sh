#!/usr/bin/env bash
#
# FINDINGS #47: the four arms, run back to back so the only differences are the two that matter.
#
# [Co-developed with claude code -- Adam]
#
#            :8081 refused (no proxy)     :8081 accepts and never answers
#   BEFORE   before-noproxy               before-wedgedproxy
#   AFTER    after-noproxy                after-wedgedproxy
#
# The right-hand column is the discriminating one. The left-hand column is kept because it is the
# reason the first attempt at this experiment showed nothing: with :8081 refusing, the kernel's
# poll `curl`s die in milliseconds, so at the moment the kernel is killed there is no child to
# inherit anything and even the unfixed binary releases the port immediately. The window in the
# finding is as wide as the kernel's longest-lived child, and nothing else.
#
# 🔴 The blackhole is stopped by the pid it printed. No pkill, no pgrep.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BEFORE_BIN="${BEFORE_BIN:?before binary}"
AFTER_BIN="${AFTER_BIN:?after binary}"
TRIALS="${TRIALS:-8}"

run_arm() {   # $1 = label, $2 = binary
    echo "### $(date -Is)  arm $1"
    bash "$HERE/port_release_experiment.sh" "$2" "$1" "$TRIALS" "$HERE/$1" \
        > "$HERE/$1.log" 2>&1 </dev/null
    echo "### $(date -Is)  arm $1 exit $?"
}

start_blackhole() {
    python3 "$HERE/blackhole_8081.py" > "$HERE/blackhole.out" 2>&1 </dev/null &
    BH=$!
    local i
    for i in $(seq 1 40); do
        [[ -n "$(ss -H -ltn 'sport = :8081' 2>/dev/null)" ]] && break
        sleep 0.25
    done
    echo "blackhole pid $BH; :8081 $(ss -H -ltn 'sport = :8081' | wc -l) listener(s)"
}
stop_blackhole() {
    [[ -n "${BH:-}" ]] || return 0
    kill -TERM "$BH" 2>/dev/null
    local i
    for i in $(seq 1 40); do [[ -d "/proc/$BH" ]] || break; sleep 0.25; done
    [[ -d "/proc/$BH" ]] && kill -9 "$BH" 2>/dev/null
    BH=""
    echo "blackhole stopped; :8081 listeners now: $(ss -H -ltn 'sport = :8081' | wc -l)"
}
trap stop_blackhole EXIT

# --- the discriminating pair, with a wedged proxy -----------------------------------------------
start_blackhole
run_arm before-wedgedproxy "$BEFORE_BIN"
run_arm after-wedgedproxy  "$AFTER_BIN"
stop_blackhole

# --- the control pair, with nothing on :8081 ----------------------------------------------------
run_arm before-noproxy "$BEFORE_BIN"
run_arm after-noproxy  "$AFTER_BIN"

echo "### all arms done $(date -Is)"
