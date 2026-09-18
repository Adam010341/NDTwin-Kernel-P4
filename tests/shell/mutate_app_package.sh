#!/usr/bin/env bash
#
# Mutation gate for the P4 app package: the baseline literals, the knob, the model-derived host
# table and switch list, the election id, `external` mode's read-only refusal plus its
# disclosure, the fabric side both entry points share, and -- from TICKET-P2 section 3.7 -- the
# per-switch pipeline (G4): which program each switch is launched with, which of them are not
# NDTwin's, and the one-switch model that has no cable to declare.
# TICKET-P1 section 2.4 and TICKET-P2 section 3.7.
#
# [Co-developed with claude code -- Adam]
#
# A test that has never been seen to fail is a decoration, and this feature's central claim --
# "with no package on disk the fabric behaves exactly as it did" -- is the kind that is trivially
# green whatever the code does. So every literal `app_package.baseline()` returns, every step
# `external` mode skips, and every request that has to carry `self.election_id` gets its own
# mutation, and each one names the single test that must go red.
#
# 🔴 THE MUTANT IS A COPY. Every mutation is applied to a copy of p4_proxy under a temp dir and
# the tests run there. Nothing under p4_proxy/ is written -- another session may be executing
# those files right now -- and all six sources plus four test files are re-hashed at the end.
# `setting/` is linked rather than copied: the models are the fabric's, several megabytes, and
# nothing here mutates them.
#
# 🔴 ONE MUTATION IS DELIBERATELY NOT HERE, because it would be EQUIVALENT in this tree and a
# gate that reports a survivor for an unkillable mutant teaches people to ignore it:
#
#   * "set DEFAULT_SWITCH_DPIDS back to tuple(range(1, 11))" AT ITS ASSIGNMENT. Both shipped
#     models declare dpids 1..10, so the constant and the reader produce the same tuple there.
#     M10 mutates `switch_dpids` itself instead, which a model declaring (4, 9) can tell apart.
#
# 🔴 Two that an earlier version of this header wrongly called equivalent, and are not (the P1-A
# judge was right about both):
#
#   * "put the quarters formula back in build_host_table" (M22). It IS equivalent against the two
#     NDTwin models -- that agreement is the content of
#     test_the_proxy_host_table_matches_the_formula_it_replaces_* -- but not against a pod-topo
#     shaped model, where four hosts sit on four different switches on port 1 in four different
#     /24s and the formula answers port 3 and 10.0.0.<i> for all of them. The discriminating
#     model is the fix, not dropping the mutation.
#   * "change PACKAGE_DEFAULT_ELECTION_ID" (M23). What needs a live third-party controller is
#     proving that 65535 WINS an arbitration; that the documented default is the literal
#     (0, 65535), and that it outbids the baseline (0, 1), is a pure assertion about a manifest
#     that names no election id.
#
# 🔴 A THIRD ONE, AND THIS ONE IS NOT EQUIVALENT -- IT IS UNKILLABLE FROM INSIDE ONE PROCESS,
# which is a different and worse thing, so it is declared here rather than left out silently:
#
#   * "topo_log.Tee.stop() closes the saved descriptors in the same loop that restores them,
#     before joining the pump" (the shape the code had until 2026-09-18). It loses whatever the
#     pump had not yet written, and -- the reason it was fixed -- a closed descriptor number is
#     one the next open() in the process receives, so a late chunk of the topology log can land
#     in an unrelated file. It was found by MEASUREMENT under a real pty and the fix was
#     confirmed the same way. It is not in the list below because both arms were run three
#     times each against a file-backed fd 1 and a 400 kB write, and both KEPT the line: the
#     writer blocks on a full pipe, so the pump has already drained by the time stop() runs. A
#     mutation nobody can make fail is a decoration, and a gate that shipped one would teach
#     people to skim this file. What IS asserted, deterministically, is the property that makes
#     the ordering safe rather than lucky -- the pump owns its own descriptor (M34).
#
# Usage:  tests/shell/mutate_app_package.sh
#         PROXY_PY=/path/to/python tests/shell/mutate_app_package.sh
# Assumes: nothing about the cwd.
# Exit:    0 every mutation caught, 1 a mutation survived, 2 refused (no interpreter, or the
#          baseline was red), 3 a source file changed underneath the gate.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PKG="$REPO/p4_proxy/mininet/app_package.py"
READER="$REPO/p4_proxy/mininet/topo_from_json.py"
MAIN="$REPO/p4_proxy/proxy_agent/main.py"
CLIENT="$REPO/p4_proxy/proxy_agent/p4_client.py"
ROUTES="$REPO/p4_proxy/proxy_agent/api_routes.py"
PROFILE="$REPO/p4_proxy/proxy_agent/profile.py"
TEST_PKG="$REPO/p4_proxy/tests/test_app_package.py"
TEST_PROXY="$REPO/p4_proxy/tests/test_app_package_proxy.py"
TEST_STARTUP="$REPO/p4_proxy/tests/test_startup.py"
TEST_WRITES="$REPO/p4_proxy/tests/test_p4_client_writes.py"
TOPOMGR="$REPO/p4_proxy/proxy_agent/topology_manager.py"
TEST_READOPT="$REPO/p4_proxy/tests/test_readopt.py"
# TICKET-P1D: the fabric side of the same feature. TESTBED holds the ONE bring-up both entry
# points call, BRIDGE is the entry point `ndtwin-lab topo-start` actually launches, and TOPOLOG
# is where its output goes now that a dead pane is no longer the only copy.
TESTBED="$REPO/p4_proxy/mininet/p4_testbed_topo.py"
BRIDGE="$REPO/p4_proxy/mininet/ntg_bmv2_topo.py"
TOPOLOG="$REPO/p4_proxy/mininet/topo_log.py"
TEST_BRINGUP="$REPO/p4_proxy/tests/test_fabric_bring_up.py"
TEST_TOPOLOG="$REPO/p4_proxy/tests/test_topo_log.py"

MODULES="tests.test_app_package tests.test_app_package_proxy tests.test_startup \
tests.test_p4_client_writes tests.test_readopt tests.test_fabric_bring_up \
tests.test_topo_log"

# The interpreter. A git worktree has no venv of its own (p4_proxy/venv/ is gitignored and lives
# in the main checkout), so the main worktree is consulted before giving up -- asked of git
# rather than spelled as somebody's home directory, which would make this gate runnable on one
# machine. Override with PROXY_PY= .
MAIN_WT="$(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
PY=""
for c in "${PROXY_PY:-}" "$REPO/p4_proxy/venv/bin/python" "$REPO/p4_proxy/venv/bin/python3" \
         "${MAIN_WT:-/nonexistent}/p4_proxy/venv/bin/python"; do
    [[ -n "$c" && -x "$c" ]] || continue
    "$c" -c 'import fastapi, networkx, grpc' >/dev/null 2>&1 || continue
    PY="$c"; break
done
[[ -n "$PY" ]] || {
    echo "REFUSE: found no interpreter with fastapi/networkx/grpc. Set PROXY_PY=<path>." >&2
    echo "        A gate that cannot run its tests has not checked anything, so it does not" >&2
    echo "        get to exit 0." >&2
    exit 2
}
echo "interpreter: $PY"

BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-apppkg-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
# Every mutant lives at $BK/<label>, so each one's `p4_proxy` root is that directory and the
# repo root the tests derive from it is $BK. The models and the compiled p4info are read, never
# written, so they are linked in once rather than copied per mutation.
ln -s "$REPO/setting" "$BK/setting"

BASE_PKG=$(sha256sum "$PKG" | cut -d' ' -f1)
BASE_READER=$(sha256sum "$READER" | cut -d' ' -f1)
BASE_MAIN=$(sha256sum "$MAIN" | cut -d' ' -f1)
BASE_CLIENT=$(sha256sum "$CLIENT" | cut -d' ' -f1)
BASE_ROUTES=$(sha256sum "$ROUTES" | cut -d' ' -f1)
BASE_PROFILE=$(sha256sum "$PROFILE" | cut -d' ' -f1)
BASE_TEST_PKG=$(sha256sum "$TEST_PKG" | cut -d' ' -f1)
BASE_TEST_PROXY=$(sha256sum "$TEST_PROXY" | cut -d' ' -f1)
BASE_TEST_STARTUP=$(sha256sum "$TEST_STARTUP" | cut -d' ' -f1)
BASE_TEST_WRITES=$(sha256sum "$TEST_WRITES" | cut -d' ' -f1)
BASE_TOPOMGR=$(sha256sum "$TOPOMGR" | cut -d' ' -f1)
BASE_TEST_READOPT=$(sha256sum "$TEST_READOPT" | cut -d' ' -f1)
BASE_TESTBED=$(sha256sum "$TESTBED" | cut -d' ' -f1)
BASE_BRIDGE=$(sha256sum "$BRIDGE" | cut -d' ' -f1)
BASE_TOPOLOG=$(sha256sum "$TOPOLOG" | cut -d' ' -f1)
BASE_TEST_BRINGUP=$(sha256sum "$TEST_BRINGUP" | cut -d' ' -f1)
BASE_TEST_TOPOLOG=$(sha256sum "$TEST_TOPOLOG" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

# The tests import proxy_agent the way the proxy is launched, so the mutant needs the package,
# the tests beside it, and mininet/ (app_package, topo_from_json and grpc_ports all live there).
# PYTHONDONTWRITEBYTECODE so a mutant cannot be run from a .pyc of its unmutated self -- a .pyc
# is revalidated against (mtime-in-SECONDS, size), and two same-size mutants written in one
# second are exactly the trap mutate_ryu_rest_topology_bounded.sh documents.
run_against() {
    ( cd "$1" && PYTHONPATH="$1" PYTHONDONTWRITEBYTECODE=1 timeout 300 \
        "$PY" -m unittest $MODULES -v 2>&1 )
}

report() {   # $1 = mutation name, $2 = mutant dir, $3 = the test case that must go red
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_against "$2"); rc=$?
    # 🔴 A SUITE THAT DID NOT FINISH IS NOT A VERDICT, in either direction. `timeout 300`
    # returns 124, and unittest prints its `FAIL: <name>` section at the END -- so a mutant
    # that hangs the run produces no named failure and would be scored a survivor of nothing.
    # 2026-09-18 is why this is here: M33 came back SURVIVED under a non-tty harness because
    # the mutant left fd 1 hijacked and shredded the report on its way out, and the one-line
    # diagnostic the gate printed was a bare `FAIL`. Named, and it fails the gate.
    # (mutate_startup_clears_by_pid.sh has had this branch since it was written.)
    if [[ "$rc" -eq 124 ]]; then
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 HUNG   %-70s (the suite never finished -- never a catch)\n' "$1"
        return
    fi
    if [[ "$rc" -ne 0 ]] && /usr/bin/grep -qE "^(FAIL|ERROR): $3 " <<<"$out"; then
        printf '  caught   %-70s (%s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-70s (%s stayed green -- that case proves nothing)\n' "$1" "$3"
        /usr/bin/grep -E '^(FAIL|ERROR|OK|Ran )' <<<"$out" | sed 's/^/             /'
    fi
}

# A mutant is a whole copy of p4_proxy's importable tree plus the compiled artefacts: the reader,
# the profile, the proxy, the client and the route are one chain, and a mutation to any of them
# has to be exercised through the real import rather than through a stub of the other four. The
# anchor must be unique, so a mutation cannot quietly land somewhere other than where it says.
#
# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py can
# read this gate: it learns which argument is the anchor and which is the file from a function's
# own `local ... file="$2" old="$3"` line, and a gate it cannot read is a gate it is not checking
# (finding #28).
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$d/"
    mkdir -p "$d/p4_src"
    cp -r "$REPO/p4_proxy/p4_src/build" "$d/p4_src/" 2>/dev/null
    find "$d" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
    python3 - "$d/${file#"$REPO/p4_proxy/"}" "$old" "$new" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, "anchor not unique (%d hits): %s" % (s.count(a), a[:70])
open(p, "w").write(s.replace(a, b))
PY
    echo "$d"
}

echo "baseline (must be green before any mutation):"
base="$BK/base"; mkdir -p "$base"
cp -r "$REPO/p4_proxy/proxy_agent" "$REPO/p4_proxy/tests" "$REPO/p4_proxy/mininet" "$base/"
mkdir -p "$base/p4_src"; cp -r "$REPO/p4_proxy/p4_src/build" "$base/p4_src/" 2>/dev/null
find "$base" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
run_against "$base" | /usr/bin/grep -E '^(Ran |OK|FAILED)'
run_against "$base" >/dev/null 2>&1 || { echo "  baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- the baseline literals: the claim "nothing changed without a package" --------------------

m=$(mutant m1 "$PKG" \
    'BASELINE_ELECTION_ID: Tuple[int, int] = (0, 1)' \
    'BASELINE_ELECTION_ID: Tuple[int, int] = (0, 2)')
report "M1: the baseline bids an election id the fabric has never bid" "$m" \
       "test_the_baseline_election_id_is_the_literal_zero_one"

m=$(mutant m2 "$PKG" \
    'BASELINE_CPU_PORT = 255' \
    'BASELINE_CPU_PORT = 510')
report "M2: the baseline CPU port moves, so packet-ins go to a port nothing reads" "$m" \
       "test_the_baseline_cpu_port_is_the_literal_255"

m=$(mutant m3 "$PKG" \
    'BASELINE_PREFIX_LEN = 24' \
    'BASELINE_PREFIX_LEN = 16')
report "M3: the baseline host prefix length is not the /24 the fabric has always used" "$m" \
       "test_the_baseline_host_prefix_length_is_the_literal_24"

m=$(mutant m4 "$PKG" \
    '        if self.is_baseline:
            return None
        return {h.name: list(h.commands) for h in self.hosts}' \
    '        return {h.name: list(h.commands) for h in self.hosts}')
report "M4: baseline host commands are {} not None, so the all-pairs ARP is switched off" "$m" \
       "test_the_baseline_runs_no_host_commands_and_says_so_with_none_not_empty"

# --- the knob -------------------------------------------------------------------------------

m=$(mutant m5 "$PKG" \
    '    directory = read_knob(knob_path)
    return baseline() if directory is None else load(directory)' \
    '    read_knob(knob_path)
    return baseline()')
report "M5: the knob is read and then ignored -- the whole feature does nothing" "$m" \
       "test_a_knob_naming_a_package_is_the_package_not_the_baseline"

m=$(mutant m6 "$PKG" \
    '        last_octet = str(ip).rsplit(".", 1)[-1]
        if not last_octet.isdigit() or int(last_octet) != int(name[1:]):' \
    '        last_octet = str(ip).rsplit(".", 1)[-1]
        if False:')
report "M6: the h<N>-matches-the-last-octet rule is not checked" "$m" \
       "test_a_host_whose_name_does_not_match_its_address_is_refused"

# 🔴 M7 CHANGED SUBJECT WHEN G4 LANDED, and the sentence it is about did not.
# Until TICKET-P2 a non-null `pipeline` was REFUSED, and M7 removed the refusal: the package was
# then accepted and silently given NDTwin's pipeline. G4 made the field legal, so the refusal is
# gone -- but the same silent substitution is now one line away, through the door that was opened
# for it: parse the field and store None. Same failure, same mutation slot, new anchor.
m=$(mutant m7 "$PKG" \
    '        pipeline = _switch_pipeline(spec.get("pipeline"), package_dir, sw)' \
    '        pipeline = None  # MUTANT: read, then thrown away')
report "M7: a package naming its own pipeline is accepted and silently given NDTwin's" "$m" \
       "test_the_loader_resolves_each_switchs_pipeline_to_two_absolute_paths"

# --- the host table and the switch list -----------------------------------------------------

m=$(mutant m8 "$MAIN" \
    '        dpid, port = where
        mac_str = topo_from_json.mac_str(mac, name)' \
    '        dpid, port = where[0], where[1] + 1
        mac_str = topo_from_json.mac_str(mac, name)')
report "M8: every host is entered one port along from where the model says" "$m" \
       "test_the_proxy_host_table_matches_the_formula_it_replaces_at_four_hosts"

m=$(mutant m9 "$MAIN" \
    '        where = attach.get(name)
        if where is None:' \
    '        where = attach.get(name, (1, 3))
        if where is None:')
report "M9: a host with no access link is placed anyway instead of being refused" "$m" \
       "test_a_host_with_no_access_link_is_refused_rather_than_skipped"

m=$(mutant m10 "$MAIN" \
    '    return tuple(dpid for dpid, _name in topo_from_json.switches(model))' \
    '    return tuple(range(1, 11))')
report "M10: the switch list is the old range(1, 11) rather than the model's" "$m" \
       "test_the_switch_list_comes_from_the_model_not_from_a_range"

# --- G3: the election id on the wire --------------------------------------------------------

m=$(mutant m11 "$CLIENT" \
    '        message.election_id.high = self.election_id[0]
        message.election_id.low = self.election_id[1]' \
    '        message.election_id.high = 0
        message.election_id.low = 1')
report "M11: every request bids the old hardcoded (0, 1) whatever the package said" "$m" \
       "test_an_ipv4_route_insert_carries_this_clients_election_id"

m=$(mutant m12 "$CLIENT" \
    '        message.election_id.high = self.election_id[0]' \
    '        message.election_id.high = 0')
report "M12: only the low half of the bid is sent, so nothing can bid above 2**64-1" "$m" \
       "test_the_arbitration_bid_carries_both_halves_of_this_clients_election_id"

m=$(mutant m13 "$CLIENT" \
    '        req.arbitration.device_id = self.device_id
        self._bid(req.arbitration)' \
    '        req.arbitration.device_id = self.device_id
        req.arbitration.election_id.low = 1')
report "M13: the arbitration stream bids (0, 1) while the unary calls bid the package's" "$m" \
       "test_the_arbitration_bid_carries_both_halves_of_this_clients_election_id"

# --- G3: external mode reads only, and says what it skipped ----------------------------------

m=$(mutant m14 "$CLIENT" \
    '        if not self.arbitration:
            raise ControlPlaneReadOnly(' \
    '        if False:
            raise ControlPlaneReadOnly(')
report "M14: a read-only client writes after all -- the pipeline push wipes every table" "$m" \
       "test_an_external_client_refuses_a_pipeline_push"

m=$(mutant m15 "$CLIENT" \
    '        if not self.arbitration:
            print(f"[{self.device_id}] external control plane: no arbitration stream, no "' \
    '        if False:
            print(f"[{self.device_id}] external control plane: no arbitration stream, no "')
report "M15: a read-only client opens an arbitration stream and bids for mastership" "$m" \
       "test_it_opens_no_stream_and_starts_no_receiver_thread"

m=$(mutant m16 "$MAIN" \
    '        if read_only or not client.json_path:' \
    '        if not client.json_path:')
report "M16: external startup pushes the pipeline anyway" "$m" \
       "test_an_external_control_plane_pushes_no_pipeline"

m=$(mutant m17 "$MAIN" \
    '    skipped = list(EXTERNAL_SKIPS) if read_only else []' \
    '    skipped = []')
report "M17: the skipped steps are not reported -- skipping becomes silence" "$m" \
       "test_an_external_startup_names_every_step_it_skipped"

m=$(mutant m18 "$MAIN" \
    '    if not read_only:
        try:
            topo.start_lldp_discovery()' \
    '    if True:
        try:
            topo.start_lldp_discovery()')
report "M18: external startup beacons LLDP onto somebody else's fabric" "$m" \
       "test_an_external_control_plane_starts_no_lldp_and_no_watchdog"

m=$(mutant m19 "$MAIN" \
    '        if read_only:
            # Not "telemetry failed" -- telemetry was never attempted.' \
    '        if False:
            # Not "telemetry failed" -- telemetry was never attempted.')
report "M19: external startup programs a clone session into somebody else's pipeline" "$m" \
       "test_an_external_control_plane_programs_no_clone_session"

m=$(mutant m20 "$ROUTES" \
    '        for dpid, entry in state.get("switches", {}).items():
            entry["entries_recorded"] = recorded.get(str(dpid), 0)' \
    '        pass')
report "M20: switch_state does not say how many package entries went unapplied" "$m" \
       "test_every_switch_reports_how_many_package_entries_were_recorded_but_not_applied"

m=$(mutant m21 "$ROUTES" \
    '    if control_plane_report is not None:
        state["control_plane"] = control_plane_report()' \
    '    if False:
        state["control_plane"] = control_plane_report()')
report "M21: switch_state carries no control_plane at all" "$m" \
       "test_a_skipped_step_is_named_on_the_endpoint"

m=$(mutant m22 "$MAIN" \
    '        topo.add_host(ip=ip, mac=mac_str, switch_dpid=dpid, port=port)
        added.append((ip, mac_str, dpid, port))' \
    '        _i, _per = int(name[1:]), len(topo_from_json.hosts(model)) // 4
        ip, dpid, port = f"10.0.0.{_i}", 1 + (_i - 1) // _per, 3 + (_i - 1) % _per
        topo.add_host(ip=ip, mac=mac_str, switch_dpid=dpid, port=port)
        added.append((ip, mac_str, dpid, port))')
report "M22: the quarters formula is back, so the model is read and then ignored" "$m" \
       "test_a_pod_topo_shaped_model_is_followed_where_the_formula_would_be_wrong"

m=$(mutant m23 "$PKG" \
    'PACKAGE_DEFAULT_ELECTION_ID: Tuple[int, int] = (0, 65535)' \
    'PACKAGE_DEFAULT_ELECTION_ID: Tuple[int, int] = (0, 1)')
report "M23: a package that names no election id silently bids the baseline (0, 1)" "$m" \
       "test_a_package_that_names_no_election_id_gets_the_documented_default"

m=$(mutant m24 "$CLIENT" \
    '        update.type = p4runtime_pb2.Update.INSERT
        entry = update.entity.table_entry
        self._build_5tuple_entry(entry, keys, priority)' \
    '        req.election_id.high, req.election_id.low = 0, 1
        update.type = p4runtime_pb2.Update.INSERT
        entry = update.entity.table_entry
        self._build_5tuple_entry(entry, keys, priority)')
report "M24 (ticket M7): ONE unary stops carrying self.election_id and reverts to (0, 1)" "$m" \
       "test_a_five_tuple_insert_carries_this_clients_election_id"

m=$(mutant m25 "$TOPOMGR" \
    '            if not new.arbitration:' \
    '            if False:')
report "M25: readopt under an external control plane blames a mastership race instead" "$m" \
       "test_readopt_under_an_external_control_plane_says_so"

m=$(mutant m26 "$PKG" \
    '    _hosts_agree_with_the_model(hosts, model_hosts, topology, where)' \
    '    pass')
report "M26: the manifest's hosts are not checked against the model they must describe" "$m" \
       "test_an_address_the_two_disagree_on_is_refused"

# --- the fabric side: the copy that actually runs (TICKET-P1D) --------------------------------
#
# 🔴 EVERY MUTATION BELOW REPRODUCES A STATE THIS REPO WAS ACTUALLY IN ON 2026-09-18. The
# app-package work landed in p4_testbed_topo.main(); `ndtwin-lab topo-start` launches
# ntg_bmv2_topo.py; and that file carried a transcribed copy of the bring-up which had kept
# every literal. These are that copy's literals, put back one at a time.

m=$(mutant m27 "$TESTBED" \
    '    switches = [net.get(name) for _dpid, name in topo_from_json.switches(model)]' \
    "    switches = [net.get(f's{i}') for i in range(1, 11)]")
report "M27: the switch list goes back to range(1, 11), so a 4-switch fabric dies at s5" "$m" \
       "test_the_bridges_main_never_asks_for_s5"

m=$(mutant m28 "$TESTBED" \
    '    host_commands = package.host_commands()
    if host_commands is None:' \
    '    host_commands = package.host_commands()
    if True:')
report "M28: the all-pairs ARP runs over the package's own host commands" "$m" \
       "test_the_all_pairs_arp_does_not_run_under_a_package"

m=$(mutant m29 "$BRIDGE" \
    '    # 🔴 BEFORE anything else can fail.
    tee.start()' \
    '    # 🔴 BEFORE anything else can fail.
    pass')
report "M29: the bridge never opens its log, so a crash is only ever in a dead pane" "$m" \
       "test_the_log_is_started_before_main_runs"

m=$(mutant m30 "$BRIDGE" \
    '            tee.stop()
        (enter_cli or run_ntg_cli)(net)' \
    '            pass
        (enter_cli or run_ntg_cli)(net)')
report "M30: the tee keeps fd 1, so NTG's prompt renders as plain text into a pipe" "$m" \
       "test_the_tee_comes_off_for_the_prompt_and_goes_back_on_for_teardown"

m=$(mutant m31 "$TESTBED" \
    '            for i in range(0, len(peers), 32):' \
    '            for i in range(0, len(peers), 4096):')
report "M31: the 128-host ARP fan-out is one command again, the one Mininet truncates" "$m" \
       "test_the_arp_fan_out_is_chunked_at_32_peers_per_command"

m=$(mutant m32 "$TOPOLOG" \
    '        if os.path.getsize(path) == 0:
            return None' \
    '        if False:
            return None')
report "M32: an empty log is rotated, so one restart pushes a real generation off the end" "$m" \
       "test_an_empty_log_is_not_rotated"

m=$(mutant m33 "$TOPOLOG" \
    '        for fd, saved in sorted(self._saved.items()):' \
    '        for fd, saved in sorted({}.items()):')
report "M33: stop() never gives the real descriptors back" "$m" \
       "test_stop_gives_the_real_descriptors_back"

m=$(mutant m34 "$TOPOLOG" \
    '            terminal_fd = os.dup(1)' \
    '            terminal_fd = self._saved[1]')
report "M34: the pump shares a descriptor stop() closes, so a late chunk lands anywhere" "$m" \
       "test_the_pump_does_not_share_a_descriptor_stop_will_close"

m=$(mutant m35 "$BRIDGE" \
    "if __name__ == '__main__':
    run()" \
    "if __name__ == '__main__':
    main()")
report "M35: the script entry point skips run(), so the log is never opened at all" "$m" \
       "test_running_the_module_as_a_script_goes_through_run_not_main"

# --- the data plane the first live package run could not use ----------------------------------

m=$(mutant m36 "$TESTBED" \
    '    renamed = []
    for host in hosts:
        old = rename_default_intf(host)' \
    '    renamed = []
    for host in []:
        old = rename_default_intf(host)')
report "M36: a package's hosts keep h1-eth0, so every command names a device that is not there" "$m" \
       "test_every_host_gets_its_interface_renamed_to_eth0"

m=$(mutant m37 "$TESTBED" \
    '            output = (host.cmd(command) or "").strip()' \
    '            host.cmd(command)
            output = ""')
report "M37: a host command's output is discarded again -- SIOCADDRT goes back to being silent" "$m" \
       "test_what_a_host_command_printed_is_reported_and_counted"

m=$(mutant m38 "$TESTBED" \
    '        return HostSetup(commands=None, renamed=(), noisy=())' \
    '        for host in hosts:
            rename_default_intf(host)
        return HostSetup(commands=None, renamed=(), noisy=())')
report "M38: the baseline renames too, so h1-eth0 stops being what every other reader sees" "$m" \
       "test_nothing_is_renamed_under_the_baseline"

# --- G4: the per-switch pipeline (TICKET-P2 section 3.7, M-A1..M-A3 and M-A7..M-A9) -----------
#
# 🔴 EVERY ONE OF THESE IS A FABRIC THAT COMES UP. That is what makes them worth a line: a
# switch running the wrong compiled program does not fail to start, does not log an error and
# does not report anything to the twin -- it forwards, plausibly, according to a program nobody
# asked it to run. The exercise that discriminates is `firewall`, the only shipped one whose
# topology.json uses tutorials' per-switch `program` override (s1 firewall.json, s2-s4 basic).

m=$(mutant m39 "$PKG" \
    '        for spec in self.switches:
            if spec.dpid == int(dpid) and spec.pipeline:' \
    '        for spec in []:
            if spec.dpid == int(dpid) and spec.pipeline:')
report "M39 (M-A1): pipeline_for ignores the per-switch override and answers fabric-wide" "$m" \
       "test_pipeline_for_answers_per_switch_not_fabric_wide"

m=$(mutant m40 "$TESTBED" \
    '                               json_path=package.pipeline_for(dpid, proxy_root)[1],' \
    '                               json_path=package.pipeline_for(1, proxy_root)[1],')
report "M40 (M-A2): every bmv2 is launched with dpid 1's json, the shape before G4" "$m" \
       "test_each_switch_is_launched_with_its_own_program"

m=$(mutant m41 "$TESTBED" \
    '        if not os.path.exists(json_paths[dpid]):' \
    '        if dpid == 1 and not os.path.exists(json_paths[dpid]):')
report "M41 (M-A3): the pre-flight checks only dpid 1's json, so s2 dies after mn -c" "$m" \
       "test_plan_fabric_checks_every_switch_not_just_the_first"

m=$(mutant m42 "$READER" \
    '        if len(dpids) == 1:' \
    '        if True:')
report "M42 (M-A7): zero cables is accepted at any switch count, so islands look like a fabric" "$m" \
       "test_two_switches_with_no_cable_between_them_is_still_refused"

m=$(mutant m43 "$PKG" \
    '    if not (real == root or real.startswith(root + os.sep)):' \
    '    if False:')
report "M43 (M-A8): a pipeline may point outside the package it is supposed to be part of" "$m" \
       "test_a_pipeline_that_escapes_the_package_directory_is_refused"

m=$(mutant m44 "$PKG" \
    '        return self.pipeline_for(dpid, base_dir) == baseline().pipeline_for(dpid, base_dir)' \
    '        return True  # MUTANT: everything is NDTwins pipeline')
report "M44 (M-A9): pipeline_is_ndtwin is always True, so nothing downstream ever skips" "$m" \
       "test_pipeline_is_ndtwin_is_false_for_a_package_that_brought_its_own"

# Not in the ticket's list, and here for the reason the ticket gives for the others: an operator
# reading a bring-up log has to be able to tell "the telemetry is off because this fabric runs
# somebody else's program" from "the telemetry broke", and by the time the proxy discloses it in
# `switch_state` the fabric is already up. A disclosure nothing can redden is a decoration.
m=$(mutant m45 "$TESTBED" \
    '    foreign = [dpid for dpid in dpids if not package.pipeline_is_ndtwin(dpid, proxy_root)]' \
    '    foreign = []  # MUTANT: the log never mentions a foreign pipeline')
report "M45: the bring-up log never says which switches are not on NDTwin's pipeline" "$m" \
       "test_the_plan_says_out_loud_which_switches_are_not_on_ndtwins_pipeline"

# --- negative controls -----------------------------------------------------------------------
#
# A gate that reddens on anything is not a gate. These are edits that change no behaviour these
# suites specify, and each must leave the named test GREEN -- which `report` scores as a
# SURVIVOR, so they are run separately and the survivor count is not touched.

control() {  # $1 = label, $2 = mutant dir, $3 = what must stay green
    local out rc
    out=$(run_against "$2"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  green    %-70s (%s)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  🔴 RED   %-70s -- these suites are change detectors, not a specification\n' "$1"
        /usr/bin/grep -E '^(FAIL|ERROR):' <<<"$out" | head -4 | sed 's/^/             /'
    fi
}

m=$(mutant n1 "$PKG" \
    '#: The only format this reader understands.' \
    '# MUTANT: a comment, and nothing else.
#: The only format this reader understands.')
control "N1 (control): a comment-only edit to app_package.py" "$m" "the whole suite stays green"

m=$(mutant n2 "$MAIN" \
    '    package = profile.current() if package is None else package
    read_only = package.read_only' \
    '    package = profile.current() if package is None else package
    # MUTANT: a comment, and nothing else.
    read_only = package.read_only')
control "N2 (control): a comment-only edit inside startup()" "$m" "the whole suite stays green"

m=$(mutant n3 "$TESTBED" \
    '        proxy_root = os.path.join(base, "..")' \
    '        # MUTANT: a comment, and nothing else.
        proxy_root = os.path.join(base, "..")')
control "N3 (control): a comment-only edit where MultiSwitchTopo resolves the pipeline" "$m" \
        "the whole suite stays green"

echo
[[ "$(sha256sum "$PKG" | cut -d' ' -f1)" == "$BASE_PKG" ]] || { echo "🔴 baseline CHANGED -- app_package.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$READER" | cut -d' ' -f1)" == "$BASE_READER" ]] || { echo "🔴 baseline CHANGED -- topo_from_json.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$MAIN" | cut -d' ' -f1)" == "$BASE_MAIN" ]] || { echo "🔴 baseline CHANGED -- main.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$CLIENT" | cut -d' ' -f1)" == "$BASE_CLIENT" ]] || { echo "🔴 baseline CHANGED -- p4_client.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$ROUTES" | cut -d' ' -f1)" == "$BASE_ROUTES" ]] || { echo "🔴 baseline CHANGED -- api_routes.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$PROFILE" | cut -d' ' -f1)" == "$BASE_PROFILE" ]] || { echo "🔴 baseline CHANGED -- profile.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_PKG" | cut -d' ' -f1)" == "$BASE_TEST_PKG" ]] || { echo "🔴 baseline CHANGED -- test_app_package.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_PROXY" | cut -d' ' -f1)" == "$BASE_TEST_PROXY" ]] || { echo "🔴 baseline CHANGED -- test_app_package_proxy.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_STARTUP" | cut -d' ' -f1)" == "$BASE_TEST_STARTUP" ]] || { echo "🔴 baseline CHANGED -- test_startup.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_WRITES" | cut -d' ' -f1)" == "$BASE_TEST_WRITES" ]] || { echo "🔴 baseline CHANGED -- test_p4_client_writes.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TOPOMGR" | cut -d' ' -f1)" == "$BASE_TOPOMGR" ]] || { echo "🔴 baseline CHANGED -- topology_manager.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_READOPT" | cut -d' ' -f1)" == "$BASE_TEST_READOPT" ]] || { echo "🔴 baseline CHANGED -- test_readopt.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TESTBED" | cut -d' ' -f1)" == "$BASE_TESTBED" ]] || { echo "🔴 baseline CHANGED -- p4_testbed_topo.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$BRIDGE" | cut -d' ' -f1)" == "$BASE_BRIDGE" ]] || { echo "🔴 baseline CHANGED -- ntg_bmv2_topo.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TOPOLOG" | cut -d' ' -f1)" == "$BASE_TOPOLOG" ]] || { echo "🔴 baseline CHANGED -- topo_log.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_BRINGUP" | cut -d' ' -f1)" == "$BASE_TEST_BRINGUP" ]] || { echo "🔴 baseline CHANGED -- test_fabric_bring_up.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$TEST_TOPOLOG" | cut -d' ' -f1)" == "$BASE_TEST_TOPOLOG" ]] || { echo "🔴 baseline CHANGED -- test_topo_log.py was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (10 sources, 7 test files)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi

# [Co-developed with claude code -- Adam]
