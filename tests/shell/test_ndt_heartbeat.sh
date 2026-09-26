#!/usr/bin/env bash
#
# `ndt`'s half of the veth heartbeat (TICKET-P4-heartbeat segment W), driven OFFLINE.
#
# [Co-developed with claude code -- Adam]
#
# The ticket's lifecycle bullet: `ndt up p4 --app` on a foreign fabric STARTS the heartbeat,
# `ndt down` STOPS it, `ndt status` SHOWS it, and NDTwin's own pipeline (LLDP) never starts it.
# The root helper does the work (`sudo ndtwin-lab heartbeat start|stop|status`, segment H) and
# is not touched by this ticket -- its sha is pinned and installed -- so everything asserted here
# is what `ndt` asks of it, when, and what `ndt` does with the answer.
#
# What is asserted, and what each stands against:
#
#   * a foreign package fabric: one `heartbeat start`, AFTER `topo-start` and BEFORE stack.sh
#     starts the proxy, so the proxy's first watchdog pass already has a report to read;
#   * NOT on the baseline fabric, NOT on a package running NDTwin's own pipeline, NOT on an
#     external control plane (the proxy reads only there, so nobody would read the report);
#   * a heartbeat that does not start does NOT fail the bring-up -- the fabric is up, only
#     detection is off, and the proxy says so -- and rc 3 (no inter-switch link) is not a warning;
#   * `ndt down` stops it before `topo-stop`, and a stop that fails is a failed teardown (rc 1,
#     named in the claim note); with no pidfile nothing is asked at all (the sudo count of every
#     existing teardown cell stays what it was);
#   * a rollback stops it, and so does a bring-up that replaces a running topology;
#   * `ndt status` prints a `heartbeat` row from the report file -- running, stale, stopped,
#     absent, unreadable -- and names a frame that reached a host;
#   * the two paths are the root helper's own.
#
# Everything that would describe THIS machine is stubbed, including the heartbeat's pidfile and
# report: they are fixture paths, never /run/ndtwin-lab.
#
# Run:  bash tests/shell/test_ndt_heartbeat.sh
# Env:  NDT_UNDER_TEST=<path>   (tests/shell/mutate_p4_heartbeat_w.sh points it at a copy)
# Exit: 0 every check passed, 1 some check failed
set -uo pipefail
export NO_COLOR=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NDT="${NDT_UNDER_TEST:-$HERE/../../tools/test_workflow/ndt}"
REAL_REPO="$(cd "$HERE/../.." && pwd)"
HELPER="$REAL_REPO/tools/test_workflow/ndtwin-lab"
[[ -r "$NDT" ]] || { echo "  FAILED   no ndt at $NDT"; echo "Ran 1 checks, 1 failed"; exit 1; }

PASS=0; FAIL=0
check() {   # <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok       %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAILED   %s\n             expected: [%s]\n             actual:   [%s]\n' "$1" "$2" "$3"; fi
}
has()   { /usr/bin/grep -qF -- "$2" <<<"$3" && { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; } \
          || { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             no match for: [%s]\n' "$1" "$2"; }; }
hasnt() { /usr/bin/grep -qF -- "$2" <<<"$3" && { FAIL=$((FAIL+1)); printf '  FAILED   %s\n             unexpected: [%s]\n' "$1" "$2"; } \
          || { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }; }
section() { printf '\n%s\n' "$1"; }

FIX="$(mktemp -d "${TMPDIR:-/tmp}/ndt-heartbeat-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT INT TERM
mkdir -p "$FIX/.test_run/pids" "$FIX/.test_run/logs" "$FIX/tools/test_workflow" \
         "$FIX/p4_proxy/mininet" "$FIX/setting" "$FIX/etc" "$FIX/run"
echo '{"switches":[{"dpid":1}]}' > "$FIX/manifest.json"
cp "$REAL_REPO/setting/StaticNetworkTopologyP4_10Switches_4Hosts.json" "$FIX/setting/" 2>/dev/null
printf 'helper\n' > "$FIX/installed-ndtwin-lab"
for m in app_package.py topo_from_json.py grpc_ports.py link_telemetry.py; do
    ln -sf "$REAL_REPO/p4_proxy/mininet/$m" "$FIX/p4_proxy/mininet/$m"
done
HB_PID="$FIX/run/heartbeat.pid"
HB_JSON="$FIX/run/heartbeat.json"

# --- package fixtures: pod-topo-sized, FOUR hosts on FOUR switches ---------------------------
# mkpkg <dir> <mode> <pipeline stem or ""> -- every switch on that pipeline (empty: NDTwin's).
mkpkg() {
    local d="$1" mode="$2" pipe="${3:-}"
    mkdir -p "$d/ndtwin"
    [[ -n "$pipe" ]] && { mkdir -p "$d/build"; : > "$d/build/$pipe.p4.p4info.txtpb"; echo '{}' > "$d/build/$pipe.json"; }
    python3 - "$d" "$mode" "$pipe" <<'PY'
import json, os, sys
d, mode, pipe = sys.argv[1], sys.argv[2], sys.argv[3]
nodes, edges, hosts = [], [], {}
for i in range(1, 5):
    nodes.append({"device_name": "s%d" % i, "bridge_name": "s%d" % i, "dpid": i,
                  "vertex_type": 0, "device_layer": 2, "ip": ["192.168.123.%d" % (10 + i)],
                  "mac": 0, "ecmp_groups": []})
for i in range(1, 5):
    ip = "10.0.%d.%d" % (i, i)
    nodes.append({"device_name": "h%d" % i, "dpid": 0, "vertex_type": 1,
                  "device_layer": 3, "ip": [ip], "mac": i})
    hosts["h%d" % i] = {"ip": ip, "prefix_len": 24,
                        "mac": ":".join("%02x" % ((i >> sh) & 0xFF) for sh in (40, 32, 24, 16, 8, 0)),
                        "commands": []}
    edges.append({"src_dpid": 0, "src_interface": 1, "dst_dpid": i, "dst_interface": 1})
    edges.append({"src_dpid": i, "src_interface": 1, "dst_dpid": 0, "dst_interface": 1})
json.dump({"nodes": nodes, "edges": edges, "links": []},
          open(os.path.join(d, "ndtwin", "topology.json"), "w"), indent=2, sort_keys=True)
pipeline = ({"p4info": "build/%s.p4.p4info.txtpb" % pipe, "bmv2_json": "build/%s.json" % pipe}
            if pipe else None)
json.dump({"format": 1, "name": os.path.basename(d), "topology": "ndtwin/topology.json",
           "hosts": hosts,
           "switches": {str(i): {"name": "s%d" % i, "pipeline": pipeline, "entries": None}
                        for i in range(1, 5)},
           "control_plane": {"mode": mode, "election_id": [0, 65535],
                             "grpc_base": 30050, "device_id": "dpid"},
           "bmv2": {"cpu_port": 255}, "links": []},
          open(os.path.join(d, "package.json"), "w"), indent=2, sort_keys=True)
PY
}
PKG_FOREIGN="$FIX/packages/basic";        mkpkg "$PKG_FOREIGN" ndtwin   basic
PKG_NDTWIN="$FIX/packages/ndtwin-pipe";   mkpkg "$PKG_NDTWIN"  ndtwin   ""
PKG_EXTERNAL="$FIX/packages/p4runtime";   mkpkg "$PKG_EXTERNAL" external advanced_tunnel

# A recording fake stack.sh, on the same event log as sudo, so ORDER can be asserted.
cat > "$FIX/stack.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'stack %s\n' "$*" >> "$EVENTS"
if [[ -e "$STACK_FAIL" ]]; then echo "  proxy did not open :8081"; exit 1; fi
echo "started p4_proxy"
echo "started kernel"
exit 0
FAKE
chmod +x "$FIX/stack.sh"
cat > "$FIX/fakepy" <<'FAKE'
#!/usr/bin/env bash
exec bash "$@"
FAKE
chmod +x "$FIX/fakepy"
cat > "$FIX/preflight.sh" <<'FAKE'
#!/usr/bin/env bash
echo "PASS -- every check passed"
exit 0
FAKE
chmod +x "$FIX/preflight.sh"
export EVENTS="$FIX/events.log" STACK_FAIL="$FIX/stack-must-fail"

# `sudo` records every call on the event log and answers the heartbeat verbs the way the helper
# does: `start` writes the pidfile and answers $HB_START_RC (with the helper's own sentences),
# `stop` removes it and answers $HB_STOP_RC.
STUBS='
REPO="'"$FIX"'"
HERE="'"$FIX"'/tools/test_workflow"
LAB="'"$FIX"'/installed-ndtwin-lab"
STACK="'"$FIX"'/stack.sh"
MANIFEST="'"$FIX"'/manifest.json"
CLAIM="$REPO/.test_run/lab.claim"; HANDOFF="$REPO/.test_run/lab.handoff"
LAB_CONF="'"$FIX"'/etc/ndtwin-lab.conf"
LAB_DEFAULT_KERNEL_DIR="'"$FIX"'"
HB_PIDFILE="'"$HB_PID"'"
HB_REPORT="'"$HB_JSON"'"
LINK_TELEMETRY_MANIFEST="'"$FIX"'/ndtwin_link_telemetry.json"
export P4_PROXY_PY="'"$FIX"'/fakepy"
export NDT_APP_PREFLIGHT="'"$FIX"'/preflight.sh"
export NDT_PROXY_LOG="'"$FIX"'/.test_run/logs/p4_proxy.log"
export NDT_TOPO_LOG="'"$FIX"'/.test_run/logs/topo.log"
sudo() {
    printf "sudo %s\n" "$*" >> "$EVENTS"
    case "$*" in
        *topo-start*) echo 99 > "'"$FIX"'/bmv2_count" ;;
        *"heartbeat start"*)
            case "${HB_START_RC:-0}" in
                0) echo 4242 > "'"$HB_PID"'"
                   echo "heartbeat started (pid 4242; report: /run/ndtwin-lab/heartbeat.json, log: /run/ndtwin-lab/heartbeat.log)" ;;
                3) echo "heartbeat plan: 1 switch(es), no inter-switch link" ;;
                *) echo "ndtwin-lab heartbeat: refusing to start: no fabric is running" >&2 ;;
            esac
            return "${HB_START_RC:-0}" ;;
        *"heartbeat stop"*)
            (( ${HB_STOP_RC:-0} == 0 )) && { rm -f "'"$HB_PID"'"; echo "heartbeat stopped (pid 4242)"; }
            (( ${HB_STOP_RC:-0} != 0 )) && echo "ndtwin-lab heartbeat: pid 4242 is STILL the heartbeat daemon after TERM and KILL" >&2
            return "${HB_STOP_RC:-0}" ;;
    esac
    return 0
}
sleep() { :; }
bmv2_count() { cat "'"$FIX"'/bmv2_count" 2>/dev/null || echo 0; }
mn_count() { echo 0; }
fabric_host_count() { cat "'"$FIX"'/fabric_hosts" 2>/dev/null || echo 0; }
topo_session() { [[ -e "'"$FIX"'/topo_session" ]]; }
foreign_claim() { :; }
in_flight() { :; }
guard_no_live_ovs() { return 0; }
stale_pipeline() { return 1; }
preflight() { return 0; }
claim_note_up() { :; }
claim_note_down() { printf "CLAIM_NOTE_DOWN rc=%s unverified=[%s]\n" "$1" "$2"; }
bmv2_binary() { echo "simple_switch_grpc (stub)"; }
sample_rate() { echo 256; }
rate_label() { echo "1/256"; }
wait_reaped() { return 0; }
app_probe() { APP_STATE=not-running; APP_LIVE_PIDS=(); }
mark_teardown_start() { return 0; }
mark_teardown_end() { return 0; }
lab_subject() { echo "4 bmv2 switch(es)"; }
stack_down_deferrable_ports() { :; }
ndt_port_residue() { :; }
teardown_in_flight() { return 1; }
curl() { return 1; }
git_lines() { :; }
port_open() { return 1; }
cmd_clean() { return 0; }
registry_clear_stale() { return 0; }
verify_p4() { echo "VERIFY_P4 pipe=${4:-<none>}"; return 0; }
'

_drive() {
    bash -c "source '$NDT' >/dev/null 2>&1
$1
$2
echo \"RC=\$?\"" 2>&1
}
drive() { _drive "$STUBS" "$1"; }
rc_of() { sed -n 's/^RC=//p' <<<"$1" | tail -1; }
q() { printf '%q' "$1"; }
reset_fix() {
    rm -f "$EVENTS" "$FIX/bmv2_count" "$FIX/fabric_hosts" "$FIX/topo_session" "$STACK_FAIL" \
          "$HB_PID" "$HB_JSON" "$FIX/p4_proxy/mininet/app_package_override" \
          "$FIX/.test_run/up.target" "$FIX/.test_run/host_count_override.pre-up"
    : > "$EVENTS"
    printf '4\n' > "$FIX/p4_proxy/mininet/host_count_override"
}
events() { cat "$EVENTS"; }
# 🔴 THE HELPER'S VERB, not the word: this fixture's own directory is named ndt-heartbeat-*, so
# every sudo line carries "heartbeat" in its path. (The first draft counted the word, and every
# negative cell read the fixture's name.)
hb_calls() { count_of 'ndtwin-lab heartbeat'; }
count_of() { local n; n="$(/usr/bin/grep -cF -- "$1" "$EVENTS" 2>/dev/null)"; [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }
# line_of <text> -- the line number of its first occurrence in the event log, or 0.
line_of() { local n; n="$(/usr/bin/grep -nF -- "$1" "$EVENTS" | head -1 | cut -d: -f1)"; printf '%s' "${n:-0}"; }
before() { local a b; a="$(line_of "$1")"; b="$(line_of "$2")"; (( a > 0 && b > 0 && a < b )) && echo yes || echo "no ($1 at $a, $2 at $b)"; }

# =============================================================================================
section "1. a foreign package fabric starts the heartbeat -- after the fabric, before the proxy"
# =============================================================================================
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_FOREIGN"); up_p4")"
check "🔴 the bring-up succeeds"                                 "0" "$(rc_of "$OUT")"
check "🔴 exactly one 'heartbeat start'"                         "1" "$(count_of 'ndtwin-lab heartbeat start')"
check "🔴 after topo-start"                                      "yes" "$(before 'topo-start' 'ndtwin-lab heartbeat start')"
check "🔴 before stack.sh starts the proxy"                      "yes" "$(before 'ndtwin-lab heartbeat start' 'stack up p4')"
has   "  the helper's answer is printed"                         "heartbeat started (pid 4242" "$OUT"
has   "  and ndt says what it is for"                            "heartbeat running" "$OUT"
check "  nothing was stopped on the way up"                      "0" "$(count_of 'ndtwin-lab heartbeat stop')"

# The same fabric already up (the reuse branch): start is asked again, and the helper's own
# "already running" is what makes that harmless -- ndt does not keep a second copy of that rule.
reset_fix
echo 4 > "$FIX/bmv2_count"; echo 4 > "$FIX/fabric_hosts"; : > "$FIX/topo_session"
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_FOREIGN"); up_p4")"
check "  a reused fabric: rc 0"                                  "0" "$(rc_of "$OUT")"
has   "  (it did take the reuse branch)"                         "already up" "$OUT"
check "🔴 a reused foreign fabric asks for the heartbeat too"    "1" "$(count_of 'ndtwin-lab heartbeat start')"

# =============================================================================================
section "2. 🔴 NOT on NDTwin's own pipeline, NOT on the baseline, NOT on an external plane"
# =============================================================================================
reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_NDTWIN"); up_p4")"
check "  a package on NDTwin's pipeline comes up"                "0" "$(rc_of "$OUT")"
has   "  (the pipeline kind was read as ndtwin)"                 "VERIFY_P4 pipe=ndtwin" "$OUT"
check "🔴 and never asks for a heartbeat (it has LLDP)"          "0" "$(hb_calls)"

reset_fix
OUT="$(drive 'up_p4 4')"
check "  the baseline fabric comes up"                           "0" "$(rc_of "$OUT")"
check "🔴 and never asks for a heartbeat"                        "0" "$(hb_calls)"

reset_fix
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_EXTERNAL"); up_p4")"
check "  an external package comes up"                           "0" "$(rc_of "$OUT")"
has   "  (the pipeline kind was read as foreign)"                "VERIFY_P4 pipe=foreign:" "$OUT"
check "🔴 and does not start one: the proxy reads only there"    "0" "$(hb_calls)"

# =============================================================================================
section "3. 🔴 a heartbeat that does not start does not fail the bring-up"
# =============================================================================================
reset_fix
OUT="$(drive "export HB_START_RC=1; NDT_APP_DIR=$(q "$PKG_FOREIGN"); up_p4")"
check "🔴 rc 0 -- the fabric IS up"                              "0" "$(rc_of "$OUT")"
check "  the proxy and kernel were still started"                "1" "$(count_of 'stack up p4')"
has   "🔴 and it says detection is off"                          "heartbeat did NOT start (rc 1)" "$OUT"
has   "  with the helper's reason"                               "refusing to start: no fabric is running" "$OUT"
check "  and no rollback happened"                               "0" "$(count_of 'topo-stop')"

reset_fix
OUT="$(drive "export HB_START_RC=3; NDT_APP_DIR=$(q "$PKG_FOREIGN"); up_p4")"
check "  rc 3 (no inter-switch link): rc 0"                      "0" "$(rc_of "$OUT")"
has   "  said as what it is"                                     "no inter-switch link" "$OUT"
hasnt "🔴 and not as a failure"                                  "did NOT start" "$OUT"

# =============================================================================================
section "4. 🔴 'ndt down' stops it before the topology, and a stop that fails is a failed teardown"
# =============================================================================================
reset_fix
echo 4242 > "$HB_PID"
OUT="$(NDT_OWNER=t drive 'cmd_down')"
check "  the teardown succeeds"                                  "0" "$(rc_of "$OUT")"
check "🔴 one 'heartbeat stop'"                                  "1" "$(count_of 'ndtwin-lab heartbeat stop')"
check "🔴 before topo-stop"                                      "yes" "$(before 'ndtwin-lab heartbeat stop' 'topo-stop')"
check "  after stack.sh down (the proxy reading it is gone first)" "yes" "$(before 'stack down' 'ndtwin-lab heartbeat stop')"
has   "  the helper's answer is printed"                         "heartbeat stopped (pid 4242)" "$OUT"

reset_fix
OUT="$(NDT_OWNER=t drive 'cmd_down')"
check "🔴 no pidfile: the helper is not asked at all"            "0" "$(hb_calls)"
check "  and the teardown's own two sudo calls are the only ones" "2" "$(count_of 'sudo ')"

reset_fix
echo 4242 > "$HB_PID"
OUT="$(NDT_OWNER=t drive 'export HB_STOP_RC=1; cmd_down')"
check "🔴 a stop that failed: rc 1"                              "1" "$(rc_of "$OUT")"
has   "  it says so"                                             "heartbeat stop exited 1" "$OUT"
has   "🔴 and the claim note says what was not verified"         "unverified=[the heartbeat daemon" "$OUT"
check "  and the teardown still went on to the topology"         "1" "$(count_of 'topo-stop')"

# =============================================================================================
section "5. 🔴 a rollback stops it, and so does replacing a running topology"
# =============================================================================================
reset_fix
: > "$STACK_FAIL"
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_FOREIGN"); up_p4")"
check "  a proxy that never came up: rc 1"                       "1" "$(rc_of "$OUT")"
check "🔴 the rollback stopped the heartbeat"                    "1" "$(count_of 'ndtwin-lab heartbeat stop')"
check "🔴 before it stopped the topology"                        "yes" "$(before 'ndtwin-lab heartbeat stop' 'topo-stop')"
check "  and after the stack"                                    "yes" "$(before 'stack down' 'ndtwin-lab heartbeat stop')"

# A running topology of the wrong size is replaced: its heartbeat goes first, or the new
# bring-up's `start` answers "already running" for the OLD fabric's daemon, which then exits
# when its fabric disappears and leaves the new one with none.
reset_fix
echo 4 > "$FIX/bmv2_count"; echo 2 > "$FIX/fabric_hosts"; : > "$FIX/topo_session"
echo 4242 > "$HB_PID"
OUT="$(drive "NDT_APP_DIR=$(q "$PKG_FOREIGN"); up_p4")"
check "  the replacement comes up"                               "0" "$(rc_of "$OUT")"
check "🔴 the old heartbeat was stopped before the old topology" "yes" "$(before 'ndtwin-lab heartbeat stop' 'topo-stop')"
check "  and a new one started after the new topology"           "yes" "$(before 'topo-start' 'ndtwin-lab heartbeat start')"

# =============================================================================================
section "6. 'ndt status' shows it, from the report file (no sudo)"
# =============================================================================================
report() {   # report <status> <written seconds ago> [forwarded_to_hosts] [period]
    python3 - "$HB_JSON" "$1" "$2" "${3:-0}" "${4:-5}" <<'PY'
import json, sys, time
path, status, ago, hosts, period = sys.argv[1], sys.argv[2], float(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
now = time.time()
json.dump({"format": 1, "source": "heartbeat", "status": status, "pid": 4242,
           "session": "7cdb12ddde5e2a2c", "period_s": period,
           "stop_reason": None if status == "running" else "stopped by SIGTERM",
           "written_wall": now - ago, "started_wall": now - 600,
           "directions": [{"id": i} for i in range(8)],
           "side_effects": {"forwarded_to_hosts": hosts, "forwarded_between_switches": 0,
                            "misdelivered": 0, "foreign_frames": 0}}, open(path, "w"))
PY
}
row() { drive 'heartbeat_row' | /usr/bin/grep -v '^RC='; }

reset_fix
check "  no report at all"                                       "no report" "$(row | /usr/bin/grep -oF 'no report')"
report running 1.5
has   "🔴 a fresh running report reads running, with its pid"    "running (pid 4242" "$(row)"
has   "  and its directions"                                     "8 direction(s)" "$(row)"
report running 40
has   "🔴 a running report nobody rewrote reads STALE"           "STALE" "$(row)"
report stopped 3600
has   "  a stopped report reads stopped, with why"               "stopped (stopped by SIGTERM)" "$(row)"
report running 1 2
has   "🔴 a frame that reached a host is named"                  "2 heartbeat frame(s) reached a host" "$(row)"
printf '{not json' > "$HB_JSON"
has   "  an unreadable report says so"                           "unreadable" "$(row)"
check "🔴 reading it needs no sudo"                              "0" "$(count_of 'sudo')"

# The wiring: cmd_status prints that row in its `running` block.
STATUS_STUBS='
claim_line() { echo none; }; claim_prev_row() { :; }; claim_override_row() { :; }
lab_version_report() { :; }; lab_version_problem() { :; }; up_target_field() { :; }
last_kernel_plane() { :; }; kernel_exit_field() { :; }; host_count() { echo 4; }
topo_for_hosts() { echo setting/StaticNetworkTopologyP4_10Switches_4Hosts.json; }
live_dataplane_kind() { echo p4; }; source_ahead_of_build() { return 1; }
ovs_bridge_count() { echo 0; }; ovs_daemon_running() { return 1; }; lock_probe() { echo free; }
netem_count() { echo 0; }; ndt_sudo_report() { return 0; }; ndt_sudo_rows() { echo one-row; }
http_get_graph() { :; }; http_get_flow_entries() { echo "[]"; }; verify_p4_graph() { :; }
check_up_target() { return 0; }; UP_TARGET_PROBLEMS=(); app_pidfile_stale_row() { :; }
stack_pidfile_row() { STACK_PIDFILE_PROBLEMS=(); }; status_residue_row() { STATUS_RESIDUE_PROBLEMS=(); }
heartbeat_row() { echo "HEARTBEAT-ROW-SENTINEL"; }
'
OUT="$(_drive "$STUBS$STATUS_STUBS" 'cmd_status')"
has   "🔴 cmd_status prints the heartbeat row"                   "HEARTBEAT-ROW-SENTINEL" "$OUT"

# =============================================================================================
section "7. the paths are the root helper's own"
# =============================================================================================
helper_dir="$(sed -n 's/^HB_RUN_DIR=//p' "$HELPER")"
ndt_pid="$(sed -n 's/^HB_PIDFILE=//p' "$NDT")"
ndt_rep="$(sed -n 's/^HB_REPORT=//p' "$NDT")"
check "🔴 ndt's pidfile is the helper's HB_PIDFILE"              "$helper_dir/heartbeat.pid" "$ndt_pid"
has   "  (which the helper spells that way)"                     'HB_PIDFILE=$HB_RUN_DIR/heartbeat.pid' "$(cat "$HELPER")"
check "🔴 ndt's report is the file the helper's daemon writes"   "$helper_dir/heartbeat.json" "$ndt_rep"
has   "  (which the helper names that way)"                      '$HB_RUN_DIR/heartbeat.json' "$(cat "$HELPER")"

echo
echo "Ran $((PASS+FAIL)) checks, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
