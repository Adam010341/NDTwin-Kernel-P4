#!/usr/bin/env bash
#
# P1 live DIAGNOSTIC (not an acceptance step) -- where do exercises/p4runtime's tunnelled
# packets go when the exercise's own controller is primary and h1 <-> h2 still shows 100% loss?
#
# [Co-developed with claude code -- Adam]
#
# Written 2026-09-18 after step 03's first runs: the SKELETON mycontroller.py was primary, s1's
# ingressTunnelCounter counted every h1 ping, both EGRESS counters stayed 0, and every ping died.
# The proxy, the adapter and the fabric wiring were all suspects. This script brings the same
# fabric up the same way (03's steps 1-3, verbatim), starts the SAME skeleton controller, and
# then, instead of asserting, records what a claim would need:
#   80  the bmv2 manifest with its `-i port@iface` mapping (which veth is which port),
#   81  the veth peer of every sX-ethN in the root namespace (from /sys/class/net/*/iflink),
#   82-84  per-interface tx/rx/drop counters before and after ONE h1 -> h2 ping (5 packets),
#          so the last interface whose counter moved is where the packets stopped,
#   85  s1's and s2's table entries, read with the third-party client (reads only),
#   86-88  bmv2 log tails, the exercise's own P4Runtime request logs, the controller's tail.
# None of it needs root; nothing here writes to a switch.
#
# What it found (run 2026-09-18T052357Z): s1-eth1 rx +5, s1-eth2 tx +0, and TWO table entries
# per switch where the exercise's solution installs three -- the transit rule is the exercise's
# TODO, so the skeleton controller forwards nothing and the fabric was never at fault. Step 03
# now runs the skeleton as its red control and `solution/mycontroller.py` as the green arm.
#
# Run:  bash doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/04_diag_p4runtime.sh
# Exit: 0 when the fabric came up and the diagnostic tail ran (it asserts nothing about loss),
#       1 when the fabric or the controller could not be started, 2 refused before starting.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"

EXERCISE="${EXERCISE_DIR:-$HOME/tutorials/exercises/p4runtime}"
PKG="$PKG_ROOT/p4runtime"
PROBE="$REPO/p4_proxy/reference/p4runtime_mastership_probe.py"

start_step 04_diag_p4runtime

# count_s1 -- s1's non-default table entries, read with the third-party client.
#
# 🔴 THE THIRD-PARTY CLIENT, not proxy_agent/p4_client.py. A repro written on top of the suspect
# client proves nothing -- p4runtime_mastership_probe.py's own docstring, and the reason it
# exists. Only `channel` and `count_entries` are used: both are reads, neither opens a stream,
# and NEITHER of the destructive scenarios in that file is invoked.
count_s1() {
    "$PY" - "$PROBE" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("probe", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
ch = m.channel("127.0.0.1:%d" % m.grpc_port(1))
stub = m.p4runtime_pb2_grpc.P4RuntimeStub(ch)
print(m.count_entries(stub, 1))
PY
}

# --- 1. the package ----------------------------------------------------------------------------
say "converting $EXERCISE -> $PKG"
[[ -d "$EXERCISE" ]] || die "no exercise at $EXERCISE (set EXERCISE_DIR= to point elsewhere)"
[[ -r "$EXERCISE/mycontroller.py" ]] || die "no mycontroller.py in $EXERCISE -- step 3 has nothing to run"
rm -rf "$PKG"
"$PY" "$REPO/tools/p4_exercise/convert.py" "$EXERCISE" \
      --topology topology.json --p4 advanced_tunnel.p4 --out "$PKG" \
      > "$RUN/10_convert.txt" 2>&1 || die "convert.py failed -- see $(basename "$RUN")/10_convert.txt"
tail -2 "$RUN/10_convert.txt" | sed 's/^/   /'

say "pre-flight"
set +e
"$PY" "$REPO/tools/p4_exercise/preflight.py" "$PKG" > "$RUN/11_preflight.txt" 2>&1
PF_RC=$?
set -e
tail -1 "$RUN/11_preflight.txt" | sed 's/^/   /'
(( PF_RC != 0 )) && { sed 's/^/   /' "$RUN/11_preflight.txt"; die "pre-flight FAILED (rc $PF_RC); nothing was started."; }

# 🔴 THE CLAIM IS TAKEN HERE, after convert and pre-flight -- neither touches the lab, and a
# package that will not pre-flight must not have held the lab while it was being rejected.
take_claim "P1 live acceptance 3: --app p4runtime, external control plane"

# --- 2. the fabric, brought up EMPTY -------------------------------------------------------------
say "ndt up p4 --app $PKG   (external: it comes up empty on purpose)"
set +e
"$NDT" up p4 --app "$PKG" > "$RUN/20_up.txt" 2>&1
UP_RC=$?
set -e
note "rc=$UP_RC -> $(basename "$RUN")/20_up.txt"
tail -10 "$RUN/20_up.txt" | sed 's/^/     /'
(( UP_RC != 0 )) && fail "'ndt up p4 --app' exited $UP_RC (see 20_up.txt)"

SS0="$RUN/30_switch_state_before.json"
get_json "$PROXY_URL/p4/switch_state" "$SS0" || fail "no switch_state"
"$NDT" status > "$RUN/31_status.txt" 2>&1 || true
if [[ -s "$SS0" ]]; then
    MODE="$(jqp "$SS0" "(d.get('control_plane') or {}).get('mode')")"
    SKIPPED="$(jqp "$SS0" "sorted((d.get('control_plane') or {}).get('skipped') or [])")"
    ENTRIES="$(jqp "$SS0" "sorted({s.get('entries_recorded') for s in ((d.get('switches') or {}).values() if isinstance(d.get('switches'), dict) else (d.get('switches') or []))})")"
    N_SW="$(jqp "$SS0" "len(d.get('switches') or [])")"
    note "control_plane.mode  $MODE"
    note "control_plane.skipped $SKIPPED"
    note "entries_recorded    $ENTRIES"
    note "switches            $N_SW"
    [[ "$MODE" == external ]] || fail "control_plane.mode is '$MODE', want external"
    [[ "$N_SW" == 3 ]]        || fail "switch_state names $N_SW switches, this package declares 3"
    [[ "$ENTRIES" == "[0]" ]] || fail "entries_recorded is $ENTRIES -- an external package brings its own entries"
    # Every step the proxy did NOT take has to be named. A short list is a proxy that did half
    # the work of a control plane while reporting that it did none.
    # The names the proxy actually emits (P1-A's startup(); live 2026-09-18:
    # clone_session, install_initial_routes, link_watchdog, lldp_discovery, pipeline_push, sflow_telemetry).
    for s in pipeline_push clone_session lldp_discovery link_watchdog install_initial_routes sflow_telemetry; do
        /usr/bin/grep -qF "'$s'" <<<"$SKIPPED" || fail "control_plane.skipped does not name '$s': $SKIPPED"
    done
fi

# --- 3. the exercise's own controller -------------------------------------------------------------
say "starting the exercise controller under setsid"
# 🔴 NOT $PY. The tutorials' p4runtime_lib imports p4.tmp.p4config_pb2, which the proxy venv does
# not carry (checked 2026-09-18: p4_proxy/venv -> ModuleNotFoundError: No module named 'p4.tmp';
# /home/adam/p4dev-python-venv -> imports ok). The import is proved here, in the interpreter
# that will run the controller, so a missing module is a named refusal and not "the controller
# exited within 10s".
CTRL_PY="${CTRL_PY:-/home/adam/p4dev-python-venv/bin/python}"
[[ -x "$CTRL_PY" ]] || fail "no controller interpreter at $CTRL_PY (set CTRL_PY= to point elsewhere)"
TUTORIALS_UTILS="$(dirname "$(dirname "$EXERCISE")")/utils"
if ! "$CTRL_PY" -c "import sys; sys.path.insert(0, '$TUTORIALS_UTILS'); import grpc, p4runtime_lib.bmv2, p4runtime_lib.helper; from p4.tmp import p4config_pb2" \
        > "$RUN/39_controller_imports.txt" 2>&1; then
    sed 's/^/     /' "$RUN/39_controller_imports.txt"
    fail "$CTRL_PY cannot import the tutorials' p4runtime_lib from $TUTORIALS_UTILS -- the controller would die at import"
fi
note "controller interpreter $CTRL_PY imports p4runtime_lib + p4.tmp"
CTRL_LOG="$RUN/40_controller.log"
# PYTHONUNBUFFERED: the controller is killed by pid at teardown, and a block-buffered stdout
# leaves 40_controller.log empty (live 2026-09-18: 0 bytes after a run that had written rules).
setsid env PYTHONUNBUFFERED=1 "$CTRL_PY" "$REPO/tools/p4_exercise/run_external_controller.py" "$PKG" mycontroller.py \
    > "$CTRL_LOG" 2>&1 < /dev/null &
CTRL_PID=$!
note "pid $CTRL_PID -> $(basename "$CTRL_LOG")   (the EXIT trap stops it by this pid; never pkill)"
sleep 10
if ! kill -0 "$CTRL_PID" 2>/dev/null; then
    sed 's/^/     /' "$CTRL_LOG"
    CTRL_PID=""
    fail "the controller exited within 10s -- see 40_controller.log"
fi
head -20 "$CTRL_LOG" | sed 's/^/     /'

# ===== DIAGNOSTIC TAIL (04 only): where do the tunnelled packets go? ===========================
# The 2026-09-18 03 run: s1.ingressTunnelCounter(100) counted every h1 ping and
# s2.ingressTunnelCounter(200) every h2 ping, but both EGRESS counters stayed 0 -- the
# encapsulated packets leave s1 port 2 / s2 port 2 and never arrive. This captures the fabric's
# real wiring and per-interface kernel counters around one ping; none of it needs root.
H1_IP="$(model_hosts "$PKG" | sed -n '1p' | cut -d' ' -f2)"
H2_IP="$(model_hosts "$PKG" | sed -n '2p' | cut -d' ' -f2)"
say "DIAG: manifest (bmv2 argv with its -i port@iface mapping)"
cp /tmp/ndtwin_p4_switches.json "$RUN/80_manifest.json" 2>/dev/null || note "no manifest at /tmp/ndtwin_p4_switches.json"
/usr/bin/grep -oE '\-i [0-9]+@[a-z0-9-]+' "$RUN/80_manifest.json" 2>/dev/null | sed 's/^/   /' | head -12
say "DIAG: veth peers of every switch interface (root namespace)"
{
  ip -o link show
  echo "---"
  for i in $(ls /sys/class/net | /usr/bin/grep -E '^s[0-9]+-eth[0-9]+$' | sort -V); do
    idx="$(cat /sys/class/net/$i/ifindex)"; peer="$(cat /sys/class/net/$i/iflink)"
    peername="$(ip -o link show | awk -F': ' -v p="$peer" '$1==p{print $2}' | cut -d@ -f1)"
    echo "$i ifindex=$idx peer_ifindex=$peer peer=${peername:-<other-namespace>}"
  done
} > "$RUN/81_veth_peers.txt" 2>&1
/usr/bin/grep -E '^s[0-9]+-eth' "$RUN/81_veth_peers.txt" | sed 's/^/   /'
snap() { for i in $(ls /sys/class/net | /usr/bin/grep -E '^s[0-9]+-eth[0-9]+$' | sort -V); do printf '%-10s tx=%-6s rx=%-6s txdrop=%s rxdrop=%s\n' "$i" "$(cat /sys/class/net/$i/statistics/tx_packets)" "$(cat /sys/class/net/$i/statistics/rx_packets)" "$(cat /sys/class/net/$i/statistics/tx_dropped)" "$(cat /sys/class/net/$i/statistics/rx_dropped)"; done; }
say "DIAG: one ping h1 -> h2 (5 packets) with interface counters before/after"
snap > "$RUN/82_ifcounters_before.txt"
set +e
PR="$(ping_loss h1 "$H2_IP" 5 "$RUN/83_ping_raw.txt")"
set -e
note "ping_loss h1 -> $H2_IP: $PR"
snap > "$RUN/84_ifcounters_after.txt"
note "interface counter deltas (tx/rx packets):"
paste -d' ' "$RUN/82_ifcounters_before.txt" "$RUN/84_ifcounters_after.txt" | awk '{split($2,a,"=");split($3,b,"=");split($7,c,"=");split($8,d,"="); printf "   %-10s tx +%d  rx +%d\n",$1,c[2]-a[2],d[2]-b[2]}'
say "DIAG: s1 and s2 table entries via the third-party client"
for dev in 1 2; do
  "$PY" - "$PROBE" "$dev" <<'PY' > "$RUN/85_entries_s${dev}.txt" 2>&1 || true
import importlib.util, sys
spec = importlib.util.spec_from_file_location("probe", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
dev = int(sys.argv[2]); ch = m.channel("127.0.0.1:%d" % m.grpc_port(dev)); stub = m.p4runtime_pb2_grpc.P4RuntimeStub(ch)
req = m.p4runtime_pb2.ReadRequest(); req.device_id = dev; e = req.entities.add(); e.table_entry.table_id = 0
for resp in stub.Read(req):
    for ent in resp.entities:
        print(ent)
PY
  note "s$dev: $(/usr/bin/grep -c 'table_entry' "$RUN/85_entries_s${dev}.txt") table entries -> 85_entries_s${dev}.txt"
done
say "DIAG: bmv2 logs and the exercise's request logs"
for s in s1 s2 s3; do tail -40 "/tmp/${s}_bmv2.log" > "$RUN/86_${s}_bmv2_tail.txt" 2>/dev/null || note "no /tmp/${s}_bmv2.log"; done
cp /home/adam/tutorials/exercises/p4runtime/logs/s1-p4runtime-requests.txt "$RUN/87_s1_requests.txt" 2>/dev/null || true
cp /home/adam/tutorials/exercises/p4runtime/logs/s2-p4runtime-requests.txt "$RUN/87_s2_requests.txt" 2>/dev/null || true
tail -30 "$CTRL_LOG" > "$RUN/88_controller_tail.txt" 2>/dev/null || true
say "DIAG done -- teardown follows"
