#!/usr/bin/env bash
# Put real traffic on the P4 fabric, inside mininet netns, and PROVE it landed.
#
#   ./traffic.sh start <seconds>    # h2 -> h1, backgrounded, leaves .traffic.pids
#   ./traffic.sh stop
#
# Why this is a file and not a line in a report: measurement commands belong in scripts, where
# they can be re-read and re-run, and where a shell bracket cannot silently change what ran.
#
# 🔴 Every assertion here exists because its absence already cost a run. On 2026-08-29 a reader
# sweep reported "0 records at 20 s" from a client that had transferred nothing: the previous
# run's server had survived cleanup and still held :5201, so the new server died with "Address
# already in use" and the client got "Connection refused". An empty flow table is what a healthy
# idle fabric looks like too, so the failure was invisible. `injections-must-assert-their-own-
# success`: no traffic and no detection produce the same output.
#
# Kill is BY RECORDED PID only. Never `pkill -f` / `pgrep -f` -- seven self-kills to date.
#
# [Co-developed with claude code -- Adam]
set -u

H1_PID=3434673      # 10.0.0.1
H2_PID=3434675      # 10.0.0.2
PIDFILE="$(dirname "$0")/.traffic.pids"
M="sudo -n mnexec -a"

die() { echo "🔴 $*" >&2; exit 1; }

start() {
    local secs="${1:-60}"
    [ -f "$PIDFILE" ] && die "$PIDFILE exists; run '$0 stop' first rather than stacking runs"

    # 1. the port must be FREE, or the server we start is not the server we measure
    if $M "$H1_PID" ss -ltn 2>/dev/null | grep -q ':5201'; then
        die "h1 already has something listening on :5201 -- a survivor from an earlier run. \
Stop it before measuring, or this run reports the old server's behaviour."
    fi

    $M "$H1_PID" iperf3 -s -1 -p 5201 >/tmp/claude-1000/iperf3_srv.log 2>&1 &
    local srv=$!
    sleep 1.5

    # 2. the server must actually be listening -- backgrounding proves nothing
    $M "$H1_PID" ss -ltn 2>/dev/null | grep -q ':5201' \
        || { kill "$srv" 2>/dev/null; die "server did not reach LISTEN; see /tmp/claude-1000/iperf3_srv.log"; }

    $M "$H2_PID" iperf3 -c 10.0.0.1 -p 5201 -t "$secs" -i 0 \
        >/tmp/claude-1000/iperf3_cli.log 2>&1 &
    local cli=$!
    printf '%s\n%s\n' "$srv" "$cli" > "$PIDFILE"
    sleep 3

    # 3. the CLIENT must have moved bytes. "the process is running" is not "traffic exists":
    #    process-liveness lies in two directions and this is the one that matters here.
    local before after
    before=$($M "$H2_PID" cat /sys/class/net/h2-eth1/statistics/tx_bytes 2>/dev/null || echo 0)
    sleep 2
    after=$($M "$H2_PID" cat /sys/class/net/h2-eth1/statistics/tx_bytes 2>/dev/null || echo 0)
    [ "$after" -gt "$((before + 1000000))" ] \
        || die "h2 tx_bytes moved only $((after - before)) B in 2 s -- the client is not \
transferring. Anything measured now would be measuring an idle fabric."

    echo "ok: traffic up, h2->h1, $(( (after - before) / 250000 )) Mbit/s observed on the wire"
    echo "    pids $(tr '\n' ' ' < "$PIDFILE") -> $PIDFILE"
}

stop() {
    [ -f "$PIDFILE" ] || { echo "no $PIDFILE; nothing recorded to stop"; return 0; }
    while read -r p; do
        [ -n "$p" ] && kill "$p" 2>/dev/null && echo "  killed recorded pid $p"
    done < "$PIDFILE"
    rm -f "$PIDFILE"
    sleep 1
    if $M "$H1_PID" ss -ltn 2>/dev/null | grep -q ':5201'; then
        die "something is STILL listening on h1:5201 after killing the recorded pids. \
Do not start another run against it -- find it first."
    fi
    echo "ok: stopped, :5201 free"
}

case "${1:-}" in
    start) start "${2:-60}" ;;
    stop)  stop ;;
    *)     echo "usage: $0 start [seconds] | stop" >&2; exit 2 ;;
esac
