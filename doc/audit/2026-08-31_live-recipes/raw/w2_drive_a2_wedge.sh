#!/usr/bin/env bash
# A-2 sec5.3 live: wedge the control plane, watch the clock, the log and the curl children.
# Recipe: doc/audit/2026-08-30_known-issues-wave/11_behavior-evidence.md sec5.3
# [Co-developed with claude code -- Adam]
#
# Why the pattern lives in a variable and never on a command line: a /proc scan driven by an
# inline `bash -c` counts ITSELF, because the shell's own cmdline contains the literal search
# string. Measured on this machine 2026-08-31 (previous session, trap (b)). A script FILE does
# not have that offset -- this process's cmdline is the script path.
set -u

REPO=/home/adam/Desktop/NDTwin-Kernel
LOG="$REPO/.test_run/logs/kernel.log"
RYU_LOG="$REPO/.test_run/logs/ryu.log"
IPT=/usr/sbin/iptables
# The two forms sudoers grants verbatim. Nothing else is permitted; -A, -F, -L all prompt.
DROP_ADD=(-I INPUT -p tcp --dport 8080 -j DROP)
DROP_DEL=(-D INPUT -p tcp --dport 8080 -j DROP)

CURL_SIG='--connect-timeout 2 --max-time 5'
WARN_SIG='topology poll got no answer'
INFO_SIG='topology poll answered again'
POLL_SIG='topology from the control plane'

WEDGE_SECONDS=${WEDGE_SECONDS:-115}
RECOVER_SECONDS=${RECOVER_SECONDS:-80}

ts() { date -Is; }
hr() { printf '\n===== %s =====\n' "$1"; }

# --- identify the kernel process without pgrep -f -------------------------------------------
# /proc is the verdict; ps is only a candidate index (same rule 6045cab applies in ndt).
kernel_pid() {
    local p comm
    for p in /proc/[0-9]*; do
        [[ -r "$p/comm" ]] || continue
        read -r comm < "$p/comm" 2>/dev/null || continue
        [[ "$comm" == "ndtwin_kernel" ]] && { basename "$p"; return 0; }
    done
    return 1
}

# Count live curl children carrying the bounded-fetch signature. Independent of the log: this is
# the witness that the polling thread is still running, and how long each request lives.
curl_children() {
    local p n=0 cl
    for p in /proc/[0-9]*; do
        [[ -r "$p/cmdline" ]] || continue
        cl=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
        case "$cl" in
            *"$CURL_SIG"*) n=$((n+1)) ;;
        esac
    done
    printf '%s' "$n"
}

alive() { [[ -d "/proc/$1" ]]; }

# --- 0. pre-conditions: prove the thing exists before asserting it stopped -------------------
hr "0. PRE-CONDITIONS  $(ts)"

KPID=$(kernel_pid) || { echo "FATAL: no ndtwin_kernel process"; exit 1; }
echo "kernel pid        $KPID"
echo "kernel started    $(awk '{print $22}' /proc/$KPID/stat) (jiffies since boot)"
echo "kernel threads    $(awk '/^Threads:/{print $2}' /proc/$KPID/status)"

RPID=""
for p in /proc/[0-9]*; do
    [[ -r "$p/cmdline" ]] || continue
    c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
    case "$c" in *ryu-manager*|*intelligent_router*) RPID=$(basename "$p"); break ;; esac
done
echo "ryu pid           ${RPID:-NOT-FOUND}"

echo "-- the three polled endpoints answer right now (positive control) --"
for ep in switches hosts links; do
    printf '  %-9s http=%s\n' "$ep" \
        "$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
             "http://localhost:8080/v1.0/topology/$ep")"
done

echo "-- the poll is demonstrably running before the wedge --"
echo "  poll INFO lines so far : $(grep -c "$POLL_SIG" "$LOG")"
echo "  WARN lines so far      : $(grep -c "$WARN_SIG" "$LOG")   (must be 0)"
echo "  recovery lines so far  : $(grep -c "$INFO_SIG" "$LOG")   (must be 0)"
echo "  kernel.log bytes       : $(stat -c %s "$LOG")"
WARN_BEFORE=$(grep -c "$WARN_SIG" "$LOG")
INFO_BEFORE=$(grep -c "$INFO_SIG" "$LOG")

echo "-- no DROP rule is in effect (functional check; sudoers grants no -L) --"
echo "  switches endpoint answered above; a DROP would give 000"

# --- 1. wedge --------------------------------------------------------------------------------
hr "1. WEDGE ON  $(ts)"
T0=$(date +%s)
sudo -n "$IPT" "${DROP_ADD[@]}"
echo "iptables -I rc=$?  at $(ts)"

echo "-- confirm the wedge actually took (this is the injection assertion) --"
echo "  switches now http=$(curl -s -o /dev/null --max-time 4 -w '%{http_code}' \
    http://localhost:8080/v1.0/topology/switches)  (000 == wedged)"
echo "  ryu process still alive: $(alive "$RPID" && echo yes || echo NO)"

echo "-- sampling curl children every 1s for ${WEDGE_SECONDS}s --"
printf '   %-10s %-6s %-5s %s\n' elapsed curls kalive note
last=0
while :; do
    now=$(date +%s); el=$((now-T0))
    (( el >= WEDGE_SECONDS )) && break
    n=$(curl_children)
    if (( n != last )); then
        printf '   %-10s %-6s %-5s %s\n' "${el}s" "$n" \
            "$(alive "$KPID" && echo yes || echo NO)" \
            "$( ((n>last)) && echo 'poll pass started' || echo 'requests ended')"
        last=$n
    fi
    sleep 1
done

hr "1b. LOG AFTER ${WEDGE_SECONDS}s OF WEDGE  $(ts)"
echo "  WARN lines now         : $(grep -c "$WARN_SIG" "$LOG")   (want exactly 1 more than $WARN_BEFORE)"
echo "  recovery lines now     : $(grep -c "$INFO_SIG" "$LOG")   (want still $INFO_BEFORE)"
echo "  kernel process alive   : $(alive "$KPID" && echo yes || echo NO)"
echo "  kernel threads         : $(awk '/^Threads:/{print $2}' /proc/$KPID/status)"
echo "-- the WARN line verbatim --"
grep -n "$WARN_SIG" "$LOG"
echo "-- curl's own stderr diagnosis (-sS), if it reached the log --"
grep -n "curl:" "$LOG" | tail -5

# --- 2. recovery -----------------------------------------------------------------------------
hr "2. WEDGE OFF  $(ts)"
sudo -n "$IPT" "${DROP_DEL[@]}"
echo "iptables -D rc=$?  at $(ts)"
echo "  switches now http=$(curl -s -o /dev/null --max-time 4 -w '%{http_code}' \
    http://localhost:8080/v1.0/topology/switches)  (200 == unwedged)"

echo "-- waiting ${RECOVER_SECONDS}s for the poll to answer again --"
sleep "$RECOVER_SECONDS"

hr "2b. LOG AFTER RECOVERY  $(ts)"
echo "  WARN lines final       : $(grep -c "$WARN_SIG" "$LOG")"
echo "  recovery lines final   : $(grep -c "$INFO_SIG" "$LOG")   (want exactly 1 more than $INFO_BEFORE)"
echo "-- the recovery line verbatim --"
grep -n "$INFO_SIG" "$LOG"
echo "-- poll INFO lines final : $(grep -c "$POLL_SIG" "$LOG")"
echo "  kernel process alive   : $(alive "$KPID" && echo yes || echo NO)"

# --- 3. teardown of the injection, verified by state not by rc -------------------------------
hr "3. RULE REMOVAL VERIFIED  $(ts)"
echo "-- second -D must fail with 'Bad rule'; that is the state check, not the rc --"
sudo -n "$IPT" "${DROP_DEL[@]}" 2>&1
echo "second -D rc=$?  (non-zero + 'Bad rule' == the rule is gone)"
echo "-- and the endpoint answers, which is the functional half --"
echo "  switches http=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
    http://localhost:8080/v1.0/topology/switches)"

hr "DONE  $(ts)"
