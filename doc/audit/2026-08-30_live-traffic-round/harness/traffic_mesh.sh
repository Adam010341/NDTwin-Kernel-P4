#!/bin/bash
# =================================================================================================
# traffic_mesh.sh -- put a churning multi-pair load on the fabric and PROVE, through the datapath,
# what was offered and what was delivered.
#
# PREREG §2. Three things it must do that the 08-28 chaos harness's traffic.sh did not:
#   1. N>=8 pairs, not one, and every pair crosses at least one switch boundary;
#   2. CHURN -- a new, never-before-used src->dst pair every ~30 s. That is what manufactures the
#      table-miss events F-1 needs and the changing flow set R-2/TR-1 needs. A steady mesh is
#      just a quiet network with a bigger number on it;
#   3. the offered rate is read from NETWORK-DEVICE COUNTERS INSIDE THE NAMESPACES, per pair,
#      never from iperf3's own summary. iperf3 reports what it handed to the socket. The
#      OvS-control round already paid for that distinction once: a "1 Gbit/s offered" figure that
#      was an htb shaper's ceiling, not a fabric measurement.
#
# 🔴 Kill is BY RECORDED PID, and by walking /proc for descendants. `pkill -f` / `pgrep -f`
#    appear nowhere: seven self-kills to date. Host discovery uses the same `ps -eo pid=,args=`
#    + "mininet:h<N>" convention as ndt's own host_pid() (tools/test_workflow/ndt:1141) so there
#    is no second opinion about which namespace is which host.
#
# 🔑 Every flow carries `-t <seconds>` and every server carries `-1`. The traffic block therefore
#    TERMINATES ON ITS OWN. `stop` is the abort path, not the normal path -- a design where the
#    only way to end the load is to kill something is a design where a missed kill silently
#    contaminates the next measurement.
#
#   usage:
#     ./traffic_mesh.sh calibrate            one pair, ramp, report what the datapath carried
#     ./traffic_mesh.sh start <secs> <mbps>  base mesh + churn, backgrounded; writes .traffic.pids
#     ./traffic_mesh.sh ledger <tag>         snapshot every participating counter, now
#     ./traffic_mesh.sh report               offered vs delivered, per pair, from the snapshots
#     ./traffic_mesh.sh stop                 abort path: TERM recorded pids + descendants, verify
#
# [Co-developed with claude code -- Adam]
# =================================================================================================
. "$(dirname "${BASH_SOURCE[0]}")/round.env"
. "$T4H/lib.sh"

PIDFILE="$OUT/traffic.pids"
LEDGER_DIR="$OUT/ledger"
PAIRLIST="$OUT/traffic_pairs.tsv"
M="sudo -n mnexec -a"

# --- the pairs -----------------------------------------------------------------------------------
# Host placement is read from the model, not assumed: topo_from_json.host_links() puts h1-h32 on
# s1, h33-h64 on s2, h65-h96 on s3, h97-h128 on s4. Every pair below is chosen ACROSS quarters, so
# no pair can be served by a single switch's local table. A same-switch pair would still pass an
# "is there traffic" check while exercising none of the path machinery under test.
BASE_PAIRS=(
  "h1:h65"    "h2:h97"    "h33:h66"   "h34:h98"
  "h3:h35"    "h67:h99"   "h4:h100"   "h36:h68"
)
# Never used by BASE_PAIRS, and each used at most once: "new pair" has to mean new.
CHURN_PAIRS=(
  "h5:h69"    "h6:h101"   "h37:h70"   "h38:h102"
  "h7:h71"    "h8:h103"   "h39:h72"   "h40:h104"
  "h9:h73"    "h10:h105"  "h41:h74"   "h42:h106"
  "h11:h75"   "h12:h107"  "h43:h76"   "h44:h108"
)

# --- 4-host fabric: a different pair set, chosen by what EXISTS, not by a flag -------------------
# The pairs above name h1..h108 and are meaningless on the 4-host model. Selecting the set from a
# flag would let a mistyped flag silently measure two hosts that are not there; selecting it from
# the fabric cannot. On 4 hosts every pair is cross-switch anyway (one host per edge switch), and
# the churn pool is the remaining ordered pairs -- 4 hosts give 12, so "never-before-used" is
# still satisfiable, just not sixteen times over.
# 🔴 The first version of this test was `ps -eo args= | grep -qx '.*mininet:h5'`. It ALWAYS
# matched -- because `ps` lists the grep itself, whose own argv ends in `mininet:h5`, and `-x`
# is satisfied by `.*` eating `grep -qx .*`. So on a 4-host fabric it selected the 128-host pair
# set, host_pid died on h65, and NO TRAFFIC STARTED while a 600 s sampler happily recorded an
# idle fabric -- i.e. it silently recreated the exact condition this whole round exists to escape.
# The tag is assembled at run time and compared field-wise, which is what ndt:1141 does and why.
_fabric_has_host() {
    local tag="mininet" want="$1" line
    tag="${tag}:${want}"
    while read -r line; do [[ "${line##* }" == "$tag" ]] && return 0; done \
        < <(ps -eo args= 2>/dev/null)
    return 1
}
if ! _fabric_has_host h5; then
    BASE_PAIRS=( "h1:h3" "h2:h4" )
    CHURN_PAIRS=( "h1:h4" "h2:h3" "h3:h1" "h4:h2" "h1:h2" "h3:h4" )
fi

host_pid() {
    local tag="mininet" pid args
    tag="${tag}:$1"
    while read -r pid args; do
        [[ "${args##* }" == "$tag" ]] && { printf '%s' "$pid"; return 0; }
    done < <(ps -eo pid=,args= 2>/dev/null)
    return 1
}

host_ip() { printf '10.0.0.%s' "${1#h}"; }

# Read one netdev counter from inside a host's namespace. Prints a number, or the empty string --
# never a 0 that could be mistaken for "the counter says zero".
#
# 🔑 The interface is h<N>-eth**1**, not -eth0. p4_testbed_topo.py:406 attaches every host with
# `addLink(name, switch, port1=1, ...)`, and mininet numbers a node's interfaces from that port
# number -- so the host's only fabric-facing device is index 1 and there is no -eth0 at all.
# Measured, not assumed: `mnexec -a <h1 pid> ls /sys/class/net` prints exactly `h1-eth1` and `lo`.
# Written as -eth0 first, which would have made EVERY counter read empty. The abort in
# cmd_calibrate would have caught it -- an unreadable counter dies rather than returning 0 -- but
# a version of this that defaulted to 0 would instead have reported a silent, plausible
# "0 Mbit/s offered" over a fabric that was carrying traffic perfectly well.
hcounter() {
    local h="$1" dir="$2" pid v
    pid="$(host_pid "$h")" || { printf ''; return 0; }
    v="$($M "$pid" cat "/sys/class/net/${h}-eth1/statistics/${dir}_bytes" 2>/dev/null || true)"
    [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf ''
}

# --- descendants, for the abort path -------------------------------------------------------------
# /proc walk, not pgrep. Returns pids whose ppid chain reaches $1.
descendants() {
    local root="$1" p ppid
    for p in /proc/[0-9]*; do
        p="${p#/proc/}"
        ppid="$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null || true)"
        [[ "$ppid" == "$root" ]] && { printf '%s\n' "$p"; descendants "$p"; }
    done
}

# =================================================================================================
cmd_calibrate() {
    harness_begin traffic_calibrate
    local src=h1 dst=h65 port=5299 want="${1:-100}"
    local spid dpid
    spid="$(host_pid $src)" || die "no namespace for $src -- is the fabric up?"
    dpid="$(host_pid $dst)" || die "no namespace for $dst"
    info "calibrating with ONE pair $src($spid) -> $dst($dpid) at ${want} Mbit/s offered, 8 s"

    # The port must be free, or the server we measure is not the server we started (chaos
    # harness, 2026-08-29: a survivor held :5201 and a run reported "0 records" from a client
    # that had transferred nothing).
    if $M "$dpid" ss -ltun 2>/dev/null | grep -q ":$port"; then
        die "$dst already has something bound on :$port -- a survivor. Find it before measuring."
    fi

    ( exec $M "$dpid" iperf3 -s -1 -p "$port" >"$OUT/calib_srv.log" 2>&1 ) &
    local srv=$!
    sleep 1.5

    local tx0 rx0 tx1 rx1
    tx0="$(hcounter $src tx)"; rx0="$(hcounter $dst rx)"
    [[ -n "$tx0" && -n "$rx0" ]] || die "could not read netdev counters in the namespaces; every rate below would be unbacked"

    ( exec $M "$spid" iperf3 -c "$(host_ip $dst)" -p "$port" -u -b "${want}M" -t 8 -i 0 \
        >"$OUT/calib_cli.log" 2>&1 ) &
    local cli=$!
    sleep 9

    tx1="$(hcounter $src tx)"; rx1="$(hcounter $dst rx)"
    local offered=$(( (tx1 - tx0) * 8 / 8 / 1000000 ))   # Mbit over 8 s == Mbit/s
    local delivered=$(( (rx1 - rx0) * 8 / 8 / 1000000 ))
    info "datapath: offered ${offered} Mbit/s, delivered ${delivered} Mbit/s (asked for ${want})"
    printf 'asked_mbps\toffered_mbps\tdelivered_mbps\n%s\t%s\t%s\n' "$want" "$offered" "$delivered" \
        > "$OUT/calibration.tsv"

    # The gate that matters: the counters MOVED. An idle fabric and a broken injection look
    # identical downstream (memory: injections-must-assert-their-own-success).
    gate "the source namespace's own netdev counted the offered traffic" \
         "$( (( tx1 - tx0 > 1000000 )) && echo 0 || echo 1 )" "$(( tx1 - tx0 )) B in 8 s"
    gate "the destination namespace's own netdev counted traffic arriving" \
         "$( (( rx1 - rx0 > 1000000 )) && echo 0 || echo 1 )" "$(( rx1 - rx0 )) B in 8 s"
    kill "$srv" "$cli" 2>/dev/null || true
    summary
}

# =================================================================================================
cmd_start() {
    harness_begin traffic_start
    local secs="${1:-600}" mbps="${2:-3}" churn_mbps="${3:-2}"
    [[ -f "$PIDFILE" ]] && die "$PIDFILE exists; run '$0 stop' first rather than stacking runs"
    mkdir -p "$LEDGER_DIR"
    : > "$PIDFILE"
    : > "$PAIRLIST"

    info "base mesh: ${#BASE_PAIRS[@]} pairs at ${mbps} Mbit/s each for ${secs}s"
    info "churn:     one NEW pair every 30 s at ${churn_mbps} Mbit/s, 90 s each, ${#CHURN_PAIRS[@]} available"

    local i=0 pair src dst sp dp port
    for pair in "${BASE_PAIRS[@]}"; do
        src="${pair%%:*}"; dst="${pair##*:}"; port=$(( 5300 + i ))
        sp="$(host_pid "$src")" || die "no namespace for $src"
        dp="$(host_pid "$dst")" || die "no namespace for $dst"
        ( exec $M "$dp" iperf3 -s -1 -p "$port" >"$OUT/srv_${src}_${dst}.log" 2>&1 ) &
        printf '%s\n' "$!" >> "$PIDFILE"
        sleep 0.2
        ( exec $M "$sp" iperf3 -c "$(host_ip "$dst")" -p "$port" -u -b "${mbps}M" -t "$secs" -i 0 \
            >"$OUT/cli_${src}_${dst}.log" 2>&1 ) &
        printf '%s\n' "$!" >> "$PIDFILE"
        printf 'base\t%s\t%s\t%s\t%s\t%s\n' "$src" "$dst" "$port" "$mbps" "$(date +%s)" >> "$PAIRLIST"
        i=$(( i + 1 ))
    done
    ok "${#BASE_PAIRS[@]} base pairs launched (server+client each, all pids recorded)"

    # The churn loop runs detached so this script can return and the round can get on with
    # sampling. It writes its own pids into the same file as it goes.
    (
      j=0
      for pair in "${CHURN_PAIRS[@]}"; do
          sleep 30
          (( j * 30 < secs - 90 )) || break
          src="${pair%%:*}"; dst="${pair##*:}"; port=$(( 5400 + j ))
          sp="$(host_pid "$src")" || continue
          dp="$(host_pid "$dst")" || continue
          ( exec $M "$dp" iperf3 -s -1 -p "$port" >"$OUT/srv_${src}_${dst}.log" 2>&1 ) &
          printf '%s\n' "$!" >> "$PIDFILE"
          sleep 0.2
          ( exec $M "$sp" iperf3 -c "$(host_ip "$dst")" -p "$port" -u -b "${churn_mbps}M" -t 90 -i 0 \
              >"$OUT/cli_${src}_${dst}.log" 2>&1 ) &
          printf '%s\n' "$!" >> "$PIDFILE"
          printf 'churn\t%s\t%s\t%s\t%s\t%s\n' "$src" "$dst" "$port" "$churn_mbps" "$(date +%s)" >> "$PAIRLIST"
          j=$(( j + 1 ))
      done
    ) >"$OUT/churn.log" 2>&1 &
    printf '%s\n' "$!" >> "$PIDFILE"
    ok "churn loop launched (pid $!), pair list accumulates in $PAIRLIST"
    summary
}

# =================================================================================================
# ledger <tag> -- every participating host's counters, at one instant, with the wall clock.
cmd_ledger() {
    # Two statements, not one. `local tag=X f="…$tag…"` dies under `set -u` with
    # "tag: unbound variable": bash creates every name in a `local` list as an unset local BEFORE
    # running the assignments, so the second initialiser reads the shadow, not the value.
    local tag="${1:?ledger needs a tag}"
    local f="$LEDGER_DIR/$tag.tsv"
    mkdir -p "$LEDGER_DIR"
    local seen=() pair src dst h
    for pair in "${BASE_PAIRS[@]}" "${CHURN_PAIRS[@]}"; do seen+=("${pair%%:*}" "${pair##*:}"); done
    {
        printf '# tag=%s epoch=%s utc=%s\n' "$tag" "$(date +%s)" "$(date -u +%FT%TZ)"
        printf 'host\ttx_bytes\trx_bytes\n'
        for h in $(printf '%s\n' "${seen[@]}" | sort -u -V); do
            printf '%s\t%s\t%s\n' "$h" "$(hcounter "$h" tx)" "$(hcounter "$h" rx)"
        done
    } > "$f"
    printf '%s\n' "$f"
}

# =================================================================================================
cmd_report() {
    harness_begin traffic_report
    local a="$LEDGER_DIR/pre.tsv" b="$LEDGER_DIR/post.tsv"
    [[ -f "$a" && -f "$b" ]] || die "need both $a and $b -- run 'ledger pre' before the traffic and 'ledger post' after"
    local t0 t1 dt
    t0="$(awk -F'epoch=' 'NR==1{split($2,x," ");print x[1]}' "$a")"
    t1="$(awk -F'epoch=' 'NR==1{split($2,x," ");print x[1]}' "$b")"
    dt=$(( t1 - t0 ))
    (( dt > 0 )) || die "ledger window is ${dt}s -- the two snapshots are not ordered"
    info "ledger window: ${dt}s  ($(date -d "@$t0" +%T) -> $(date -d "@$t1" +%T))"
    python3 - "$a" "$b" "$dt" "$PAIRLIST" > "$OUT/traffic_ledger.txt" <<'PY'
import sys, os
a,b,dt,pl = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
BASE_SECS  = int(os.environ.get("TRAFFIC_BASE_SECS",  "840"))
CHURN_SECS = int(os.environ.get("TRAFFIC_CHURN_SECS", "90"))
def rd(p):
    d={}
    for ln in open(p):
        if ln.startswith('#') or ln.startswith('host\t'): continue
        f=ln.rstrip('\n').split('\t')
        if len(f)==3: d[f[0]]=(f[1],f[2])
    return d
A,B=rd(a),rd(b)
pairs=[l.rstrip('\n').split('\t') for l in open(pl)] if pl else []
print(f"ledger window {dt}s; rates use each pair's own on-air time "
      f"(base {BASE_SECS}s, churn {CHURN_SECS}s). Counters are namespace netdev, read inside each host.")
print(f"{'pair':<14}{'kind':<7}{'asked':>8}{'offered':>10}{'delivered':>11}{'loss%':>8}")
tot_off=tot_dlv=0.0
for p in pairs:
    if len(p)<5: continue
    kind,src,dst,port,mbps=p[0],p[1],p[2],p[3],p[4]
    if src not in A or src not in B or dst not in A or dst not in B: continue
    # Divide by the pair's OWN on-air duration, not by the ledger window. Base pairs ran for the
    # whole block; each churn pair ran 90 s. Using the ledger window for both -- as the first
    # version did -- reported every churn pair at 0.45 Mbit/s when it had actually offered 5.16,
    # an 11x understatement that looked entirely plausible next to its 5 Mbit/s target.
    # 🔑 The two ledger snapshots bound the window; they do not tell you how long each flow was in
    # it. That has to come from the pair list, which records each start epoch.
    dur = float(BASE_SECS) if kind == 'base' else float(CHURN_SECS)
    try:
        off=(int(B[src][0])-int(A[src][0]))*8/dur/1e6
        dlv=(int(B[dst][1])-int(A[dst][1]))*8/dur/1e6
    except ValueError:
        print(f"{src+'->'+dst:<14}{kind:<7}{'?':>8}{'COUNTER UNREADABLE':>30}"); continue
    loss = (1-dlv/off)*100 if off>0 else float('nan')
    tot_off+=off; tot_dlv+=dlv
    print(f"{src+'->'+dst:<14}{kind:<7}{mbps:>8}{off:>10.2f}{dlv:>11.2f}{loss:>8.1f}")
print(f"{'TOTAL':<21}{'':>8}{tot_off:>10.2f}{tot_dlv:>11.2f}")
print()
print("offered  = tx_bytes delta on the SOURCE host's own eth0, i.e. bytes that entered the fabric.")
print("delivered= rx_bytes delta on the DESTINATION host's eth0, i.e. bytes the fabric carried out.")
print("Neither number comes from iperf3. A host's rx also counts churn traffic addressed to it and")
print("any ARP/LLDP it receives, so per-pair loss% is a bound, not an exact figure; the TOTAL row")
print("is the one PREREG §2 asks for.")
PY
    cat "$OUT/traffic_ledger.txt"
    summary
}

# =================================================================================================
cmd_stop() {
    [[ -f "$PIDFILE" ]] || { echo "no $PIDFILE; nothing recorded to stop"; return 0; }
    local p kids k
    while read -r p; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        kids="$(descendants "$p" | sort -rn || true)"
        for k in $kids; do kill -TERM "$k" 2>/dev/null || true; done
        kill -TERM "$p" 2>/dev/null || true
    done < "$PIDFILE"
    sleep 2
    local still=0
    while read -r p; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        [[ -d "/proc/$p" ]] && { kill -KILL "$p" 2>/dev/null || true; }
    done < "$PIDFILE"
    sleep 1
    while read -r p; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        [[ -d "/proc/$p" ]] && { echo "  🔴 pid $p STILL alive after TERM+KILL"; still=$(( still + 1 )); }
    done < "$PIDFILE"
    mv "$PIDFILE" "$PIDFILE.stopped.$(date +%s)"
    if (( still > 0 )); then echo "🔴 $still recorded pid(s) survived -- do NOT start another run"; return 1; fi
    echo "ok: all recorded traffic pids gone (verified via /proc, not via kill's exit status)"
}

case "${1:-}" in
    calibrate) shift; cmd_calibrate "$@" ;;
    start)     shift; cmd_start "$@" ;;
    ledger)    shift; cmd_ledger "$@" ;;
    report)    shift; cmd_report "$@" ;;
    stop)      shift; cmd_stop "$@" ;;
    *) echo "usage: $0 calibrate|start <secs> <mbps>|ledger <tag>|report|stop" >&2; exit 2 ;;
esac
