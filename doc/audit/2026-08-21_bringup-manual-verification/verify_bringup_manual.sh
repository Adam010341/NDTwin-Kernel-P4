#!/bin/bash
# Walk doc/2026-08-17_testing-manual.md section 2 end to end, exactly as written, and capture
# verbatim output. Every claim the manual makes about timings, exit codes and refusals gets
# executed here; anything that disagrees is a defect in the manual, not in the run.
#
# Why a script file and not a command line: `ndt status` runs pgrep/ps against the Mininet
# process tag, the bmv2 binary name and "iperf3 -c". A command line containing those strings
# matches itself and corrupts the counts. A script's argv is just its own path.
# [Co-developed with claude code -- Adam]
set -u

REPO=/home/adam/Desktop/NDTwin-Kernel
NDT="$REPO/tools/test_workflow/ndt"
export NDT_OWNER=manual-verify-0821
export TERM="${TERM:-dumb}"

OUT="${1:?usage: verify_bringup_manual.sh <output-log>}"
exec > >(tee "$OUT") 2>&1

hr()   { echo; echo "================================================================"; echo "== $*"; echo "================================================================"; }
step() { echo; echo "---- $* ----"; }

# Timed runner: prints the command, its wall time and its exit code. The exit code is read
# immediately into a variable -- reading $? after any other command (even echo) reports the
# wrong thing, which this repo has misread three times.
run() {
    local label="$1"; shift
    local t0 t1 rc
    step "$label"
    echo "\$ $*"
    t0=$(date +%s.%N)
    "$@"
    rc=$?
    t1=$(date +%s.%N)
    printf '[rc=%d  %.1fs]\n' "$rc" "$(echo "$t1 - $t0" | bc)"
    return $rc
}

# ---------------------------------------------------------------------------------
hr "0. GUARD -- refuse to touch a lab someone else holds"

CLAIM="$REPO/.test_run/lab.claim"
if [[ -f "$CLAIM" ]]; then
    owner="$(sed -n 's/^owner=//p' "$CLAIM" | head -1)"
    exp="$(sed -n 's/^expires=//p' "$CLAIM" | head -1)"
    now="$(date +%s)"
    if [[ "$owner" != "$NDT_OWNER" && "$exp" =~ ^[0-9]+$ ]] && (( now < exp )); then
        echo "REFUSING: lab is claimed by '$owner' until $(date -d "@$exp" '+%H:%M:%S')"
        exit 1
    fi
    echo "claim file present but not live (owner=$owner) -- proceeding"
else
    echo "no claim file -- lab is free"
fi

run "claim the lab for this run" "$NDT" claim 45 "verifying the bring-up manual (section 2)"
echo "[claim taken as $NDT_OWNER]"

hr "1. STARTING STATE  (manual 2.0 / 2.11)"
run "ndt status" "$NDT" status

# ---------------------------------------------------------------------------------
hr "2. CLEAR THE ENVIRONMENT  (manual 2.1)"
echo "manual claims: down ~13s; clean checks bmv2 / mn procs / topo session / manifest / 3 ports"

run "ndt down" "$NDT" down
run "ndt clean  (expect rc=0)" "$NDT" clean; echo "[clean rc above must be 0]"

step "manual 2.1 says clean does NOT assert these -- record them so we know the truth"
echo "\$ tc qdisc show | grep -c netem"
tc qdisc show 2>/dev/null | grep -c netem
echo "\$ sudo -n ovs-vsctl list-br | grep -c ."
sudo -n ovs-vsctl list-br 2>/dev/null | grep -c . || echo 0
echo "\$ ip -o link show type veth | wc -l"
ip -o link show type veth 2>/dev/null | wc -l

# ---------------------------------------------------------------------------------
hr "3. REFUSALS THE MANUAL PROMISES  (manual 2.2 / 2.4)"

run "ndt up ovs 16   (manual 2.2: must refuse, rc=2)" "$NDT" up ovs 16
echo "[expected rc=2 and a message naming ovs / ovs4 / p4 16]"

run "ndt ntg   (manual 2.6: reports cli or prompt)" "$NDT" ntg

# ---------------------------------------------------------------------------------
hr "4. P4 / bmv2 BRING-UP  (manual 2.2: ~35-40s)"
run "ndt up p4 128" "$NDT" up p4 128

hr "5. P4 ACCEPTANCE  (manual 2.3)"
run "ndt status --check   (expect rc=0)" "$NDT" status --check
echo "[--check rc above must be 0]"

step "cross-quadrant reachability -- the manual's claim that the view can be green while the network is dead"
for pair in "h1 10.0.0.64" "h64 10.0.0.128" "h128 10.0.0.1"; do
    set -- $pair
    hp="$(ps -eo pid=,args= | awk -v t="mininet:$1\$" '$0 ~ t {print $1; exit}')"
    if [[ -z "$hp" ]]; then echo "  $1 -> $2 : NO HOST PID FOUND"; continue; fi
    echo "\$ sudo -n mnexec -a $hp ping -c 2 -W 2 -q $2"
    sudo -n mnexec -a "$hp" ping -c 2 -W 2 -q "$2" 2>&1 | tail -3
done

step "manual 2.5: is the running fabric the fast build?"
echo "\$ ps -eo args= | grep -o '/[^ ]*simple_switch_grpc' | sort -u"
ps -eo args= | grep -o '/[^ ]*simple_switch_grpc' | sort -u

hr "6. TEAR DOWN P4  (manual 2.8)"
run "ndt down" "$NDT" down
run "ndt clean  (expect rc=0)" "$NDT" clean

# ---------------------------------------------------------------------------------
hr "7. OVS / Ryu BRING-UP  (manual 2.2: ~25s)"
run "ndt up ovs" "$NDT" up ovs

hr "8. OVS ACCEPTANCE  (manual 2.3)"
run "ndt status --check   (expect rc=0)" "$NDT" status --check

step "cross-quadrant reachability on OVS"
for pair in "h1 10.0.0.64" "h64 10.0.0.128" "h128 10.0.0.1"; do
    set -- $pair
    hp="$(ps -eo pid=,args= | awk -v t="mininet:$1\$" '$0 ~ t {print $1; exit}')"
    if [[ -z "$hp" ]]; then echo "  $1 -> $2 : NO HOST PID FOUND"; continue; fi
    echo "\$ sudo -n mnexec -a $hp ping -c 2 -W 2 -q $2"
    sudo -n mnexec -a "$hp" ping -c 2 -W 2 -q "$2" 2>&1 | tail -3
done

step "manual 2.2 fold: which OpenFlow port did the switches actually dial?"
echo "\$ sudo -n ovs-vsctl get-controller s1 s5 s10"
sudo -n ovs-vsctl get-controller s1 s5 s10 2>&1
echo "\$ ss -ltn | grep -E ':(6653|6633|8080)'"
ss -ltn 2>/dev/null | grep -E ':(6653|6633|8080)' || echo "(none)"

hr "9. TEAR DOWN OVS  (manual 2.8)"
run "ndt down" "$NDT" down
run "ndt clean  (expect rc=0)" "$NDT" clean

hr "10. RELEASE"
run "ndt release" "$NDT" release
run "ndt status" "$NDT" status

hr "DONE -- transcript at $OUT"
