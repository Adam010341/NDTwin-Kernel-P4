#!/usr/bin/env bash
#
# FINDINGS #47 live experiment: how long :8000 (TCP) and :6343 (UDP) stay bound after the kernel's
# own pid is gone, and whether a restart inside that window succeeds.
#
# [Co-developed with claude code -- Adam]
#
# This is round3 step 03's recipe, run against two binaries built from the same commit with the
# same compiler on the same machine, differing only by the fix:
#   BEFORE  5c64d432 as it stands (worktree wt-before)
#   AFTER   fix/cloexec-listening-sockets
#
# 🔴 NEVER KILLS BY NAME. Every kill targets a pid this script captured at launch ($!), and the
# only other process it touches is one whose pid `ss -H -p` printed as the holder of the port.
# No pkill, no pgrep.
#
# Usage:  port_release_experiment.sh <kernel-binary> <label> <trials> <outdir>
set -uo pipefail

BIN="${1:?kernel binary}"
LABEL="${2:?label}"
TRIALS="${3:-8}"
OUT="${4:?output directory}"
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../.." && pwd)"
TOPO="${TOPO:-$REPO/setting/StaticNetworkTopologyP4_10Switches_4Hosts.json}"

mkdir -p "$OUT"
BINDIR="$(cd "$(dirname "$BIN")" && pwd)"
BINNAME="$(basename "$BIN")"

say() { printf '%s\n' "$*"; }

# --- port state -------------------------------------------------------------------------------
tcp_bound()  { [[ -n "$(ss -H -ltn "sport = :8000" 2>/dev/null)" ]]; }
udp_bound()  { [[ -n "$(ss -H -uln "sport = :6343" 2>/dev/null)" ]]; }
tcp_users()  { ss -H -ltnp "sport = :8000" 2>/dev/null | sed 's/.*users:/users:/' | tr -d '\n'; }
udp_users()  { ss -H -ulnp "sport = :6343" 2>/dev/null | sed 's/.*users:/users:/' | tr -d '\n'; }
# 🔴 A ZOMBIE IS NOT ALIVE. `[[ -d /proc/$pid ]]` stays true for a process that has exited and not
# yet been reaped, and this script's shell is the parent of every kernel it starts. The first run
# of section C reported "second kernel ALIVE" six times for a kernel whose own stdout said
# "cannot start telemetry collection ... Exiting" -- a failure recorded as a success, which is the
# exact reporting defect this repository keeps finding elsewhere. State comes after the last ')'
# because /proc/<pid>/stat's comm field is parenthesised and may itself contain spaces.
pid_alive() {
    local s
    s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    [[ "${s##*) }" == Z* ]] && return 1
    return 0
}

# Starts the kernel and echoes ITS pid.
#
# 🔴 Deliberately not `setsid` here, even though this repository wraps long runs in setsid. setsid
# forks when its caller is already a process-group leader, and then `$!` is setsid's pid, not the
# kernel's -- so every `kill -9 "$KPID"` below would kill a wrapper and leave the kernel running.
# The SCRIPT is launched under setsid instead; the kernels inherit that session.
#
# 🔴 The redirection covers the WHOLE subshell and the kernel is `exec`ed into it. The obvious
# form -- `( cd "$BINDIR" && ./kernel > "$1" 2>&1 & echo $! )` -- deadlocks: bash runs the
# `cd && kernel` AND-list in a background subshell whose own stdout is still the command
# substitution's pipe, so `KPID=$(start_kernel ...)` never sees EOF and the script hangs with a
# kernel running and nothing measuring it. Measured, not theorised: it hung on the first run.
start_kernel() {   # -> echoes the KERNEL's pid
    ( cd "$BINDIR" && exec ./"$BINNAME" --mode mininet --topology "$TOPO" --no-ai ) \
        > "$1" 2>&1 &
    echo $!
}

# Waits for both ports; returns 1 (and says so) if the kernel never opened them, so that a kernel
# that died on startup is reported as a failed run rather than measured as a fast release.
await_up() {   # $1 = pid, $2 = its stdout file
    local i
    for i in $(seq 1 80); do
        tcp_bound && udp_bound && return 0
        pid_alive "$1" || break
        sleep 0.25
    done
    say "  !! kernel $1 never opened both ports (alive=$(pid_alive "$1" && echo yes || echo no))"
    tail -5 "$2" | sed 's/^/     /'
    return 1
}

say "#### FINDINGS #47 port-release experiment -- $LABEL ####"
say "date        $(date -Is)"
say "binary      $BIN"
say "sha256      $(sha256sum "$BIN" | cut -d' ' -f1)"
say "topology    $TOPO"
say "trials      $TRIALS"
say "uname       $(uname -r)"
say "loadavg     $(cut -d' ' -f1-3 /proc/loadavg)   (other builds may be running; recorded so the numbers are read in context)"
say "proxy :8081 $(ss -H -ltn 'sport = :8081' >/dev/null 2>&1 && ss -H -ltn 'sport = :8081' | grep -q . && echo 'LISTENING (see raw/blackhole_8081.py -- accepts and never answers, which is what keeps a poll curl alive)' || echo 'nothing listening -- every poll curl is refused in 0 ms and dies before the kernel does')"
say ""

if tcp_bound || udp_bound; then
    say "REFUSING TO START: :8000 or :6343 is already bound. Holders:"
    say "  tcp $(tcp_users)"
    say "  udp $(udp_users)"
    exit 2
fi

# =================================================================================================
# A. who holds the ports while the kernel is alive
# =================================================================================================
say "=== A. holders while the kernel is alive ==="
KPID=$(start_kernel "$OUT/${LABEL}_A_kernel.out")
say "kernel pid  $KPID"
await_up "$KPID" "$OUT/${LABEL}_A_kernel.out" || exit 3
sleep 3   # let the 1 Hz poll fork a few sh/curl children before we look
say "-- ss -ltnp :8000 --"
say "   $(tcp_users)"
say "-- ss -ulnp :6343 --"
say "   $(udp_users)"
say "-- children of $KPID (ps by ppid; never pgrep -f) --"
ps -eo pid,ppid,comm --no-headers 2>/dev/null | awk -v p="$KPID" '$2==p {print "   "$1" "$3}'
say ""

# =================================================================================================
# B. release time after SIGKILL, $TRIALS times
# =================================================================================================
say "=== B. seconds each port stays bound after the kernel's pid is gone (SIGKILL) ==="
say "trial  tcp8000_s  udp6343_s  holders_at_t+0.3s"
kill -9 "$KPID" 2>/dev/null
declare -a TCPS UDPS
for i in $(seq 1 "$TRIALS"); do
    if (( i > 1 )); then
        KPID=$(start_kernel "$OUT/${LABEL}_B${i}_kernel.out")
        await_up "$KPID" "$OUT/${LABEL}_B${i}_kernel.out" || { say "  trial $i skipped"; continue; }
        # let the poll threads fork a few children before killing it
        sleep 3
        kill -9 "$KPID" 2>/dev/null
    fi
    t0=$(date +%s.%N)
    while pid_alive "$KPID"; do sleep 0.01; done
    tgone=$(date +%s.%N)
    snap=""
    tcp_t=""; udp_t=""
    while :; do
        now=$(date +%s.%N)
        el=$(awk -v a="$now" -v b="$tgone" 'BEGIN{printf "%.3f", a-b}')
        [[ -z "$snap" ]] && awk -v e="$el" 'BEGIN{exit !(e>=0.3)}' && snap="tcp[$(tcp_users)] udp[$(udp_users)]"
        [[ -z "$tcp_t" ]] && ! tcp_bound && tcp_t="$el"
        [[ -z "$udp_t" ]] && ! udp_bound && udp_t="$el"
        [[ -n "$tcp_t" && -n "$udp_t" ]] && break
        awk -v e="$el" 'BEGIN{exit !(e>15)}' && { tcp_t="${tcp_t:->15}"; udp_t="${udp_t:->15}"; break; }
        sleep 0.05
    done
    TCPS+=("$tcp_t"); UDPS+=("$udp_t")
    printf '%-6s %-10s %-10s %s\n' "$i" "$tcp_t" "$udp_t" "${snap:-<none>}"
    sleep 0.5
done
say ""
say "-- distribution --"
printf 'tcp8000: %s\n' "${TCPS[*]}"
printf 'udp6343: %s\n' "${UDPS[*]}"
printf '%s\n' "${TCPS[@]}" | sort -g | awk 'NR==1{min=$1} {a[NR]=$1; s+=$1} END{printf "tcp8000  n=%d min=%s max=%s mean=%.3f\n", NR, min, a[NR], s/NR}'
printf '%s\n' "${UDPS[@]}" | sort -g | awk 'NR==1{min=$1} {a[NR]=$1; s+=$1} END{printf "udp6343  n=%d min=%s max=%s mean=%.3f\n", NR, min, a[NR], s/NR}'
say ""

# =================================================================================================
# C. restart 0.2 s after SIGKILL -- inside the window the defect creates
# =================================================================================================
say "=== C. restart 0.2 s after SIGKILL, 6 trials (inside the old ~2 s window) ==="
cwin=0
for i in $(seq 1 6); do
    KPID=$(start_kernel "$OUT/${LABEL}_C${i}_first.out")
    await_up "$KPID" "$OUT/${LABEL}_C${i}_first.out" || { say "  trial $i skipped"; continue; }
    sleep 3
    kill -9 "$KPID" 2>/dev/null
    while pid_alive "$KPID"; do sleep 0.01; done
    sleep 0.2
    bound_before="tcp=$(tcp_bound && echo 1 || echo 0) udp=$(udp_bound && echo 1 || echo 0)"
    NPID=$(start_kernel "$OUT/${LABEL}_C${i}_second.out")
    sleep 8
    # The question is "did the restart work", so the verdict is the API answering -- not the
    # process merely existing. A kernel that bound neither port and exited is a failed restart
    # however long its zombie lingers.
    alive=$(pid_alive "$NPID" && echo yes || echo no)
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8000/ndt/get_graph_data 2>/dev/null)
    if [[ "$alive" == yes && "$code" == 200 ]]; then
        printf 'trial %s: %s -> SUCCEEDED (pid %s alive, api=%s)\n' "$i" "$bound_before" "$NPID" "$code"
        cwin=$((cwin+1))
    else
        printf 'trial %s: %s -> FAILED (pid %s alive=%s, api=%s). kernel said:\n' \
            "$i" "$bound_before" "$NPID" "$alive" "${code:-none}"
        grep -aE "bind\(\)|cannot start telemetry|cannot listen" "$OUT/${LABEL}_C${i}_second.out" \
            | sed 's/\x1b\[[0-9;]*m//g; s/^/    /'
    fi
    kill -9 "$NPID" 2>/dev/null
    while pid_alive "$NPID"; do sleep 0.01; done
    sleep 4
done
say ""
say "restart-inside-window: $cwin/6 succeeded"
say ""

# =================================================================================================
# D. negative control: restart 3.0 s after SIGKILL -- outside the window
# =================================================================================================
say "=== D. NEGATIVE CONTROL: restart 3.0 s after SIGKILL, 3 trials ==="
dwin=0
for i in $(seq 1 3); do
    KPID=$(start_kernel "$OUT/${LABEL}_D${i}_first.out")
    await_up "$KPID" "$OUT/${LABEL}_D${i}_first.out" || { say "  control $i skipped"; continue; }
    sleep 3
    kill -9 "$KPID" 2>/dev/null
    while pid_alive "$KPID"; do sleep 0.01; done
    sleep 3.0
    NPID=$(start_kernel "$OUT/${LABEL}_D${i}_second.out")
    sleep 8
    alive=$(pid_alive "$NPID" && echo yes || echo no)
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8000/ndt/get_graph_data 2>/dev/null)
    if [[ "$alive" == yes && "$code" == 200 ]]; then
        printf 'control %s: SUCCEEDED (pid %s alive, api=%s)\n' "$i" "$NPID" "$code"
        dwin=$((dwin+1))
    else
        printf 'control %s: FAILED (pid %s alive=%s, api=%s) -- the control is supposed to succeed\n' \
            "$i" "$NPID" "$alive" "${code:-none}"
        grep -aE "bind\(\)|cannot start telemetry|cannot listen" "$OUT/${LABEL}_D${i}_second.out" \
            | sed 's/\x1b\[[0-9;]*m//g; s/^/    /'
    fi
    kill -9 "$NPID" 2>/dev/null
    while pid_alive "$NPID"; do sleep 0.01; done
    sleep 3
done
say "restart-outside-window: $dwin/3 succeeded"
say ""
say "#### end $LABEL -- $(date -Is) ####"
