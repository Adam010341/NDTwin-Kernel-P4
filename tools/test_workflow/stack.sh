#!/usr/bin/env bash
#
# Bring the NDTwin stack up and down in the right order, and wait for it to converge.
#
# Why this exists: the components have a strict dependency order, and starting the next
# one too early produces failures that look like bugs. Step 3 -> 4 in particular MUST
# wait -- a lot of "it looks broken" is really "the topology has not converged yet".
#
#   1. control plane   Ryu (OVS) or the P4 proxy agent (P4)
#   2. data plane      Mininet topology
#   3. kernel          ndtwin_kernel
#   4. readers         Visualizer / NSR / Web-GUI
#   5. traffic         NTG
#   6. apps            Energy-Saving / Traffic-Engineering  (these change the network)
#
# This script covers steps 1-3 plus convergence, because those are the ones that must be
# scripted to be reproducible. Steps 4-6 are launched per test scenario.
#
# Mininet needs root, so `up` re-execs the topology under sudo. Everything else runs as
# the invoking user.
#
# Usage:
#   ./stack.sh up ovs           # Ryu   + OVS Mininet   + kernel
#   ./stack.sh up p4            # proxy + bmv2 Mininet  + kernel
#   ./stack.sh wait             # block until the kernel reports a converged topology
#   ./stack.sh status
#   ./stack.sh down
#   ./stack.sh logs
#
# [Co-developed with claude code -- Adam]

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=components.env
source "$HERE/components.env"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
else
    R=''; G=''; Y=''; D=''; N=''
fi

mkdir -p "$LOG_DIR" "$PID_DIR"
MODE_FILE="$RUN_DIR/mode"

info() { echo "${D}$*${N}"; }
ok()   { echo "${G}$*${N}"; }
warn() { echo "${Y}$*${N}"; }
err()  { echo "${R}$*${N}" >&2; }

# prompt_for_mininet <script> -- Mininet needs root and drops into an interactive CLI, so it
# cannot be started from here; ask the operator to run it in another terminal.
prompt_for_mininet() {
    local script="$1"
    if [[ ! -f "$script" ]]; then err "  topology script missing: $script"; return 1; fi
    warn "  Mininet is interactive (it drops into a CLI) and needs root."
    warn "  Start it in a separate terminal:"
    echo
    echo "      sudo python3 $script"
    echo
    read -r -p "  Press Enter once Mininet is up (or Ctrl-C to abort)... " _ || true
}

# countdown <seconds> <what> -- a visible wait, so it does not look like a hang.
countdown() {
    local left="${1:-}" what="$2"
    # Must be a plain integer. `sleep` accepts suffixes and decimals ("60s", "0.5") but bash
    # arithmetic does not, and (( left > 0 )) on such a value fails the *condition* rather than
    # the script -- the loop body never runs, "done" prints, and 0 is returned. That silently
    # skips the whole wait and reports success, which is the failure this wait exists to prevent.
    if [[ ! "$left" =~ ^[0-9]+$ ]]; then
        err "  invalid wait value: '${left}' (want a plain integer number of seconds)"
        return 1
    fi
    if (( left == 0 )); then
        info "  $what: skipped (wait set to 0)"
        return 0
    fi
    # No \r animation when redirected: it just clutters a log file. Matches the [[ -t 1 ]]
    # colour detection above.
    if [[ ! -t 1 ]]; then
        info "  $what (${left}s)"
        sleep "$left"
        return 0
    fi
    while (( left > 0 )); do
        printf '\r  %s: %3ds remaining ' "$what" "$left"
        sleep 1
        left=$(( left - 1 ))
    done
    # Pad over the longest transient suffix (": NNNs remaining ") so none of it is left behind.
    printf '\r  %s: done%*s\n' "$what" 20 ''
}

# --- process helpers -------------------------------------------------------------

# start_bg <name> <logfile> <command...>
start_bg() {
    local name="$1" log="$2"; shift 2
    if is_running "$name"; then
        warn "  $name already running (pid $(cat "$PID_DIR/$name.pid"))"
        return 0
    fi
    setsid "$@" >"$log" 2>&1 &
    echo $! >"$PID_DIR/$name.pid"
    info "  started $name (pid $!) -> $log"
}

is_running() {
    local pidfile="$PID_DIR/$1.pid"
    [[ -f "$pidfile" ]] || return 1
    local pid; pid="$(cat "$pidfile")"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

stop_one() {
    local name="$1" pidfile="$PID_DIR/$name.pid"
    [[ -f "$pidfile" ]] || return 0

    # Refuse to follow a symlink: with a predictable path an attacker could point the
    # pidfile at something else entirely.
    if [[ -L "$pidfile" ]]; then
        err "  $pidfile is a symlink; refusing to read it"
        return 1
    fi

    local pid; pid="$(cat "$pidfile")"

    # Validate before interpolating into kill. Two real hazards:
    #   * a pidfile containing "1" makes `kill -TERM -1` -- which signals EVERY process the
    #     user is allowed to signal, i.e. their whole session, not just init
    #   * anything non-numeric gets interpolated into the command as-is
    # Require a plain integer of at least 2, since 0 and 1 both have special meanings for
    # kill and no legitimate child of this script can have them.
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || [[ "$pid" -lt 2 ]]; then
        err "  $pidfile does not contain a usable pid (${pid:-empty}); not killing anything"
        rm -f "$pidfile"
        return 1
    fi

    if kill -0 "$pid" 2>/dev/null; then
        # Negative pid targets the whole process group (setsid above), so children die too.
        kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
        for _ in $(seq 1 20); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$pid" 2>/dev/null; then
            warn "  $name did not exit on TERM; sending KILL"
            kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
        else
            info "  stopped $name"
        fi
    fi
    rm -f "$pidfile"
}

port_open() {
    # bash /dev/tcp avoids depending on nc/ss being installed.
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && exec 3>&- && return 0
    return 1
}

wait_for_port() {
    local port="$1" label="$2" timeout="${3:-30}"
    printf '  waiting for %s on :%s ' "$label" "$port"
    for _ in $(seq 1 $((timeout * 2))); do
        if port_open "$port"; then echo " ${G}up${N}"; return 0; fi
        printf '.'
        sleep 0.5
    done
    echo " ${R}timeout${N}"
    return 1
}

http_get() {
    # --fail so a 4xx/5xx is not mistaken for success.
    curl -sf --max-time 5 "$1" 2>/dev/null
}

# --- convergence -----------------------------------------------------------------

# The important one. Polls get_graph_data until every switch in the topology file is both
# up and enabled, so downstream tests never run against a half-learned graph.
cmd_wait() {
    local timeout="${1:-90}"
    local topo
    topo="$(awk '{print $2}' "$MODE_FILE" 2>/dev/null)"
    [[ -z "$topo" ]] && topo="$TOPO_OVS"

    local expected
    # The path is passed as argv, not interpolated into the source: a topology path
    # containing a quote would otherwise break the script or inject Python.
    expected="$(python3 -c '
import json, sys
t = json.load(open(sys.argv[1]))
print(sum(1 for n in t["nodes"] if n.get("vertex_type") == 0))' "$topo" 2>/dev/null)"
    [[ -z "$expected" ]] && { err "cannot read topology: $topo"; return 2; }

    echo "waiting for topology convergence (expect $expected switches up+enabled, timeout ${timeout}s)"
    local start; start=$(date +%s)
    local last=""
    while true; do
        local body; body="$(http_get "$NDT_URL/ndt/get_graph_data")"
        if [[ -n "$body" ]]; then
            local state
            state="$(printf '%s' "$body" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('unparseable'); raise SystemExit
sw=[n for n in d.get('nodes',[]) if n.get('vertex_type')==0]
up=sum(1 for n in sw if n.get('is_up'))
en=sum(1 for n in sw if n.get('is_enabled'))
print(f'{len(sw)} {up} {en} {len(d.get(\"edges\",[]))}')" 2>/dev/null)"
            if [[ "$state" != "$last" ]]; then
                read -r total up en edges <<<"$state" 2>/dev/null || true
                info "  switches=$total up=$up enabled=$en edges=$edges"
                last="$state"
            fi
            read -r total up en _edges <<<"$state" 2>/dev/null || true
            if [[ "${total:-0}" == "$expected" && "${up:-0}" == "$expected" \
                  && "${en:-0}" == "$expected" ]]; then
                ok "converged after $(( $(date +%s) - start ))s"
                return 0
            fi
        fi
        if (( $(date +%s) - start > timeout )); then
            err "did not converge within ${timeout}s (last: ${last:-no response})"
            warn "in P4 mode this is expected until Phase 6: nothing calls"
            warn "/ndt/inform_switch_entered, so is_enabled stays false."
            return 1
        fi
        sleep 2
    done
}

# --- up ---------------------------------------------------------------------------

cmd_up() {
    local mode="${1:-}"
    case "$mode" in
        ovs|p4) ;;
        *) err "usage: $0 up {ovs|p4}"; return 2 ;;
    esac

    local topo script
    if [[ "$mode" == "p4" ]]; then
        topo="$TOPO_P4"; script="$P4_TOPO_SCRIPT"
    else
        topo="$TOPO_OVS"; script="$OVS_TOPO_SCRIPT"
    fi
    echo "Bringing up the $mode stack"
    echo "  topology: $topo"
    echo

    # The two modes start in *opposite* orders, because the direction of the southbound
    # connection is reversed:
    #
    #   OVS: Ryu is the server. Switches dial out to it (ovs-vsctl set-controller
    #        tcp:127.0.0.1:6633), so Ryu has to be listening before Mininet starts.
    #   P4:  bmv2 is the server -- simple_switch_grpc listens on 0.0.0.0:50051-50060 -- and the
    #        proxy is a gRPC *client* connecting to each one. So Mininet has to be up first, or
    #        the proxy's first real RPC gets ECONNREFUSED and uvicorn exits before opening :8081.
    #
    # Treating both as "control plane first" is what used to break P4 mode.
    if [[ "$mode" == "ovs" ]]; then
        echo "[1/3] control plane (Ryu)"
        if [[ ! -x "$RYU_MANAGER" ]]; then
            err "  ryu-manager not found: $RYU_MANAGER"; return 1
        fi
        # rest_topology serves /v1.0/topology/*, which is the kernel's *pull* path for switch
        # state. --observe-links alone only loads ryu.topology.switches, which fires the
        # events the custom app pushes from -- the REST endpoints 404, and the kernel's
        # updateSwitches() silently swallows that (the 404 body is HTML, so json::parse
        # throws and the handler returns). Without this the push path is the only one, and a
        # kernel that starts late can never recover.
        start_bg ryu "$LOG_DIR/ryu.log" \
            bash -c "cd '$KERNEL_DIR' && '$RYU_MANAGER' --observe-links '$RYU_APP' ryu.app.rest_topology"
        wait_for_port 8080 "Ryu REST" 40 || {
            err "  Ryu did not open :8080; see $LOG_DIR/ryu.log"; return 1; }

        echo "[2/3] data plane (Mininet, needs sudo)"
        prompt_for_mininet "$script" || return 1
    else
        echo "[1/3] data plane (bmv2 Mininet, needs sudo)"
        warn "  bmv2 must be listening before the proxy starts: the proxy is a gRPC client,"
        warn "  and it exits if it cannot reach the switches."
        prompt_for_mininet "$script" || return 1

        echo "[2/3] control plane (P4 proxy agent)"
        if [[ ! -x "$P4_PROXY_PY" ]]; then
            err "  P4 proxy interpreter not found: $P4_PROXY_PY"
            err "  create it: python3 -m venv p4_proxy/venv && p4_proxy/venv/bin/pip install -r p4_proxy/requirements.txt"
            return 1
        fi
        # The agent must run with p4_proxy as cwd; it resolves p4info/json relative to it.
        start_bg p4_proxy "$LOG_DIR/p4_proxy.log" \
            env PYTHONPATH="$KERNEL_DIR/p4_proxy" \
            bash -c "cd '$KERNEL_DIR/p4_proxy' && '$P4_PROXY_PY' proxy_agent/main.py"
        wait_for_port 8081 "P4 proxy agent" 30 || {
            err "  proxy did not open :8081; see $LOG_DIR/p4_proxy.log"
            err "  if the log shows ECONNREFUSED to :5005x, bmv2 is not running -- start it first"
            return 1; }
    fi

    # The kernel must come last, and not immediately: TopologyAndFlowMonitor::run() pulls
    # /v1.0/topology/* and the destination paths exactly once and then exits, so whatever the
    # controller knows at that moment is all the kernel ever learns. The user manual requires
    # at least 60s after Mininet for LLDP discovery to converge first.
    # https://ndtwin.org/docs/ndtwin-user-manual/ndtwin-kernel/operate-an-emulated-software-network/native-linux-excution-environment/
    countdown "$CONVERGE_WAIT" "waiting for link discovery to converge" || return 1

    # -- 3. kernel --
    echo "[3/3] kernel"
    if [[ ! -x "$KERNEL_DIR/build/bin/ndtwin_kernel" ]]; then
        err "  kernel binary missing; run tools/test_workflow/l1_unit_tests.sh first"
        return 1
    fi
    # Both dataplanes run under mode=mininet; the topology file is what selects OVS vs bmv2.
    start_bg kernel "$LOG_DIR/kernel.log" \
        bash -c "cd '$KERNEL_DIR/build' && ./bin/ndtwin_kernel --mode mininet --topology '$topo' --no-ai"
    wait_for_port 8000 "kernel API" 40 || {
        err "  kernel did not open :8000; see $LOG_DIR/kernel.log"; return 1; }

    # Recorded only now that the stack is actually up. Written up-front, a failed start left
    # the mode claiming e.g. p4 while an OVS stack was still running, so 'wait' checked
    # convergence against the wrong topology.
    echo "$mode $topo" >"$MODE_FILE"

    echo
    ok "stack up. next: $0 wait"
}

# --- status / down / logs ---------------------------------------------------------

cmd_status() {
    local mode; mode="$(cat "$MODE_FILE" 2>/dev/null || echo 'unknown')"
    echo "mode: $mode"
    echo
    printf '  %-14s %-10s %s\n' COMPONENT PROCESS ENDPOINT
    for name in ryu p4_proxy kernel; do
        local proc="-"
        is_running "$name" && proc="running"
        printf '  %-14s %-10s' "$name" "$proc"
        case "$name" in
            ryu)      port_open 8080 && echo " :8080 open" || echo " :8080 closed" ;;
            p4_proxy) port_open 8081 && echo " :8081 open" || echo " :8081 closed" ;;
            kernel)   port_open 8000 && echo " :8000 open" || echo " :8000 closed" ;;
        esac
    done
    echo
    if port_open 8000; then
        local body; body="$(http_get "$NDT_URL/ndt/get_graph_data")"
        if [[ -n "$body" ]]; then
            printf '%s' "$body" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sw=[n for n in d.get('nodes',[]) if n.get('vertex_type')==0]
print('  graph: %d switches (%d up, %d enabled), %d hosts, %d edges' % (
    len(sw), sum(1 for n in sw if n.get('is_up')),
    sum(1 for n in sw if n.get('is_enabled')),
    sum(1 for n in d.get('nodes',[]) if n.get('vertex_type')==1),
    len(d.get('edges',[]))))" 2>/dev/null || echo "  graph: unparseable response"
        else
            echo "  graph: no response from get_graph_data"
        fi
    fi
}

cmd_down() {
    echo "Shutting down (reverse order)"
    # Kernel first so it stops polling a controller that is going away.
    for name in kernel p4_proxy ryu; do stop_one "$name"; done
    warn "Mininet was started manually; clean it up with:  sudo mn -c"
    rm -f "$MODE_FILE"
    ok "done"
}

cmd_logs() {
    echo "logs in $LOG_DIR:"
    ls -1t "$LOG_DIR" 2>/dev/null | sed 's/^/  /' || echo "  (none)"
    echo
    echo "check the kernel log against the allowlist:"
    echo "  $CONTRACT_DIR/check_logs.py $LOG_DIR/kernel.log"
}

case "${1:-}" in
    up)     shift; cmd_up "$@" ;;
    wait)   shift; cmd_wait "$@" ;;
    status) cmd_status ;;
    down)   cmd_down ;;
    logs)   cmd_logs ;;
    *)
        cat <<EOF
usage: $0 <command>

  up {ovs|p4}   bring the stack up in the order that mode requires, then the kernel
                  ovs: Ryu -> Mininet -> wait -> kernel   (switches dial out to Ryu)
                  p4:  Mininet -> proxy -> wait -> kernel  (proxy dials out to bmv2)
  wait [secs]   block until every switch is up AND enabled (default 90s)
  status        show process/port/graph state
  down          stop kernel, proxy/Ryu (Mininet needs 'sudo mn -c')
  logs          list logs and show the log-check command

run artefacts: $RUN_DIR
EOF
        exit 2 ;;
esac
