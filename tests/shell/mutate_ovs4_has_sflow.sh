#!/usr/bin/env bash
#
# Mutation gate for finding #4 -- `ovs4` configures no sFlow, so every rate and utilisation on
# that plane is structurally zero and the API still says success.
#
# [Co-developed with claude code -- Adam]
#
# It drives two suites, because the fix has two halves and each is worthless without the other:
#
#   tests/python/test_ovs4_sflow.py        tools/test_workflow/ovs_4host_topo.py -- the sFlow
#                                          configuration itself, and its agreement with the
#                                          kernel's model file and with testbed_topo.py.
#   tests/shell/test_ovs4_sflow_verify.sh  `ndt`'s sflow_state / verify_sflow -- the half that
#                                          turns a fabric which is not sampling into a red
#                                          bring-up instead of `up. ready`.
#
# Each mutation puts back one piece of the defect, or one plausible weakening of the check, and
# must turn its named case red. A mutation nobody catches means that case proves nothing.
#
# 🔴 Three directions, not one:
#
#   (defect)     the thing that happened: nothing sampling, or sampling something the kernel
#                cannot use -- an agent address the model does not declare, a target on the
#                wrong port.
#   (loosening)  the shapes a check written as "is sflow set?" signs off on: the same bridge
#                configured twice, a record attached to a bridge the topology does not build,
#                nine of ten. These are why the checks count records and compare addresses
#                rather than asking whether the column is non-empty.
#   (control)    the opposite failure: an implementation that calls every fabric broken, or
#                stops a bring-up because it could not ask. Those satisfy every case in the
#                first two groups and produce a tool nobody can run. Each must turn a case
#                labelled "control" red.
#
# 🔴 Guards its own baseline: mutations are applied to COPIES in a temp dir and the suites are
# pointed at them with OVS4_TOPO_UNDER_TEST / NDT_UNDER_TEST. The files in tools/test_workflow
# are never written -- another session may be executing them right now.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TOPO="$REPO/tools/test_workflow/ovs_4host_topo.py"
NDT="$REPO/tools/test_workflow/ndt"
PY_TEST="$REPO/tests/python/test_ovs4_sflow.py"
SH_TEST="$HERE/test_ovs4_sflow_verify.sh"

# The venv interpreter, not the system python: tests/python are run under one of these two on
# this machine and a bare `python3` is not the same environment.
PY="${OVS4_TEST_PY:-}"
if [[ -z "$PY" ]]; then
    for c in "$REPO/test_env/bin/python" "$REPO/p4_proxy/venv/bin/python" \
             /home/adam/Desktop/NDTwin-Kernel/test_env/bin/python; do
        [[ -x "$c" ]] && { PY="$c"; break; }
    done
fi
[[ -x "$PY" ]] || { echo "no venv interpreter found -- set OVS4_TEST_PY"; exit 2; }

BK=$(mktemp -d "${TMPDIR:-/tmp}/ndt-ovs4sflow-mutate-XXXXXX")
trap 'rm -rf "$BK"' EXIT
BASE_TOPO=$(sha256sum "$TOPO" | cut -d' ' -f1)
BASE_NDT=$(sha256sum "$NDT" | cut -d' ' -f1)

SURVIVORS=0
MUTATIONS=0

run_py() { OVS4_TOPO_UNDER_TEST="$1/ovs_4host_topo.py" NDT_UNDER_TEST="$1/ndt" \
           timeout 300 "$PY" -m unittest discover -s "$REPO/tests/python" \
           -p 'test_ovs4_sflow.py' -v 2>&1; }
run_sh() { NDT_UNDER_TEST="$1/ndt" timeout 300 bash "$SH_TEST" 2>&1; }

report_py() {   # $1 = mutation name, $2 = mutant dir, $3 = the test method that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_py "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qE "^(FAIL|ERROR): $3 " <<<"$out"; then
        printf '  caught   %-58s (py %s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (py %s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^(FAIL|ERROR|OK|Ran)' <<<"$out" | sed 's/^/             /'
    fi
}

report_sh() {   # $1 = mutation name, $2 = mutant dir, $3 = the case that must fail
    local out rc
    MUTATIONS=$((MUTATIONS+1))
    out=$(run_sh "$2"); rc=$?
    if [[ "$rc" -ne 0 ]] && grep -qF "FAILED   $3" <<<"$out"; then
        printf '  caught   %-58s (sh %s went red)\n' "$1" "$3"
    else
        SURVIVORS=$((SURVIVORS+1))
        printf '  SURVIVED %-58s (sh %s stayed green -- that case proves nothing)\n' "$1" "$3"
        grep -E '^  (ok|FAILED)' <<<"$out" | sed 's/^/             /'
    fi
}

# A mutant is a whole directory: `ndt` sources ports.sh and sudo_surface.sh from beside itself,
# and the python suite reads ports.sh from beside the `ndt` it is given, so all four files
# travel together and a mutation to any of them is exercised through the real seam. The anchor
# must be unique, so a mutation cannot quietly land somewhere other than where it is described.
#
# The parameters are NAMED rather than used positionally so tests/shell/check_gate_anchors.py
# can read this gate: it learns which argument is the anchor and which is the file from this
# function's own `local ... file="$2" old="$3"` line, and a gate it cannot read is a gate it is
# not checking (finding #28 -- two gates written the same night extracted zero anchors and
# nobody would have known).
mutant() {   # $1 = label, $2 = file to mutate, $3 = the anchor, $4 = its replacement
    local label="$1" file="$2" old="$3" new="$4"
    local d="$BK/$label"; mkdir -p "$d"
    cp "$TOPO" "$d/ovs_4host_topo.py"
    cp "$NDT" "$d/ndt"; chmod +x "$d/ndt"
    cp "$REPO/tools/test_workflow/ports.sh" "$d/ports.sh"
    cp "$REPO/tools/test_workflow/sudo_surface.sh" "$d/sudo_surface.sh"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PY'
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
cp "$TOPO" "$base/ovs_4host_topo.py"
cp "$NDT" "$base/ndt"; chmod +x "$base/ndt"
cp "$REPO/tools/test_workflow/ports.sh" "$base/ports.sh"
cp "$REPO/tools/test_workflow/sudo_surface.sh" "$base/sudo_surface.sh"
run_py "$base" | tail -1
run_sh "$base" | tail -1
run_py "$base" >/dev/null 2>&1 || { echo "  python baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
run_sh "$base" >/dev/null 2>&1 || { echo "  shell baseline is RED -- fix that first, mutations prove nothing on a red baseline"; exit 2; }
echo

# --- the defect itself: the topology configures no sFlow ---------------------------------------

m=$(mutant m1 "$TOPO" \
    '    configure_sflow(switches)' \
    '    pass  # configure_sflow(switches)')
report_py "M1: main() stops configuring sFlow (the defect, verbatim)" "$m" \
          "test_main_configures_sflow"

m=$(mutant m2 "$TOPO" \
    '    for bridge, intf_names in bridges:' \
    '    for bridge, intf_names in bridges[:-1]:')
report_py "M2 (loosening): nine of the ten bridges are configured" "$m" \
          "test_every_bridge_is_configured"

m=$(mutant m3 "$TOPO" \
    'SFLOW_COLLECTOR_PORT = 6343' \
    'SFLOW_COLLECTOR_PORT = 6344')
report_py "M3: the target port stops being the collector's" "$m" \
          "test_ndt_verifies_against_the_same_port"

m=$(mutant m4 "$TOPO" \
    '        configured.append(bridge)' \
    '        run(sflow_create_argv(bridge, iface))
        configured.append(bridge)')
report_py "M4 (loosening): every bridge is configured twice" "$m" \
          "test_no_bridge_is_configured_twice"

m=$(mutant m5 "$TOPO" \
    '        run(sflow_create_argv(bridge, iface))
        configured.append(bridge)' \
    "        run(sflow_create_argv(bridge + '1', iface))
        configured.append(bridge)")
report_py "M5 (loosening): the record lands on a bridge that does not exist" "$m" \
          "test_no_bridge_outside_the_fabric"

m=$(mutant m6 "$TOPO" \
    'SFLOW_AGENT_IP_FIRST = 11' \
    'SFLOW_AGENT_IP_FIRST = 21')
report_py "M6: the agent addresses stop being the model file's" "$m" \
          "test_the_helper_agrees_with_the_model_on_every_switch"

m=$(mutant m7 "$TOPO" \
    '        run(agent_ip_argv(iface, sflow_agent_ip(bridge)))' \
    '        pass  # run(agent_ip_argv(iface, sflow_agent_ip(bridge)))')
report_py "M7: the agent interface never gets an address at all" "$m" \
          "test_each_switch_gets_the_address_the_model_declares"

m=$(mutant m8 "$TOPO" \
    '    subprocess.run(argv, check=True)' \
    '    subprocess.run(argv, check=False)')
report_py "M8: the exit status is discarded again (os.system's shape)" "$m" \
          "test_the_default_runner_checks_the_exit_status"

m=$(mutant m9 "$TOPO" \
    "        f'sampling={SFLOW_SAMPLING}'," \
    "        'sampling=1',")
report_py "M9: a second set of sFlow parameters, unlike the reference" "$m" \
          "test_header_sampling_polling_match_the_reference"

m=$(mutant m10 "$TOPO" \
    '        run(agent_ip_argv(iface, sflow_agent_ip(bridge)))
        run(sflow_create_argv(bridge, iface))' \
    '        run(sflow_create_argv(bridge, iface))
        run(agent_ip_argv(iface, sflow_agent_ip(bridge)))')
report_py "M10: the record is created before the agent has an address" "$m" \
          "test_the_address_is_assigned_before_the_record_is_created"

# --- 🔴 the other direction on the topology side --------------------------------------------------

m=$(mutant n1 "$TOPO" \
    '        if iface is None:' \
    '        if True:')
report_py "N1 (control): no fabric can be configured at all" "$m" \
          "test_every_bridge_is_configured"

# --- the verify half: a fabric that is not sampling must not report ready ------------------------

m=$(mutant m11 "$NDT" \
    '    verify_sflow "$ovs_topo" || rc=1' \
    '    :')
report_sh "M11: up_ovs stops verifying telemetry (the bring-up that said ready)" "$m" \
          "up_ovs calls verify_sflow"

m=$(mutant m12 "$NDT" \
    '        if [[ "$n_refs" -eq 0 ]]; then' \
    '        if false; then')
# Named at the case that DISCRIMINATES. With the zero-reference branch gone the bridge falls
# through to the target check and the run is still red -- but on "sFlow target is ''", a message
# that sends the reader to the collector address for a bridge that has no record at all. A
# mutation whose only effect is to make the diagnosis wrong is still a mutation.
report_sh "M12: a bridge with no sFlow record reads as fine" "$m" \
          "  ... and names a bridge that samples nothing"

m=$(mutant m13 "$NDT" \
    '    sflow_query name,sflow bridge || { NDT_SFLOW_WHY="$(sflow_why)"; return 2; }' \
    '    sflow_query name,sflow bridge || true')
# 🔴 Named at a case that fails the FIRST query alone. Failing both together, this mutation
# survives: the guard on the second query reaches the same verdict by the same route, so the
# exit status, the wording and the message are all unchanged and nothing anywhere shows that
# the first guard is gone. It took a fake that can fail one query at a time to see it -- the
# instrument had to be sharpened before the mutation could be caught, which is the whole reason
# a survivor is worth more than a green line. [Co-developed with claude code -- Adam]
# And named at the REASON, not the exit status. rc 2 is reached by three different routes here
# (either query refusing, and "no bridges came back"), so the status alone has less
# discriminating power than it looks: with this guard gone the empty bridge list produces a 2
# by the third route and the operator is told the fabric has no bridges, for a database that
# would not answer. What survives a mutation is what the check is really asserting.
report_sh "M13: the bridge query's own refusal guard is gone" "$m" \
          "  ... reported with the reason ovs-vsctl gave"

m=$(mutant m13b "$NDT" \
    '    sflow_query _uuid,agent,targets sflow || { NDT_SFLOW_WHY="$(sflow_why)"; return 2; }' \
    '    sflow_query _uuid,agent,targets sflow || true')
report_sh "M13b: the record query's own refusal guard is gone" "$m" \
          "a failed record query is 'could not tell'"

m=$(mutant m14 "$NDT" \
    '        elif [[ -n "${want_ip[$name]:-}" && "$actual" != "${want_ip[$name]}" ]]; then' \
    '        elif false; then')
report_sh "M14: the agent address is no longer compared to the model" "$m" \
          "an agent address the model does not declare is red"

m=$(mutant m15 "$NDT" \
    '        actual="$(iface_ipv4 "$agent")"' \
    '        actual="${want_ip[$name]:-}"')
report_sh "M15: the agent address is read from the model, not measured" "$m" \
          "an agent interface with no IPv4 is red"

m=$(mutant m16 "$NDT" \
    '    if [[ "$n_records" -gt "${#names[@]}" ]]; then' \
    '    if false; then')
report_sh "M16 (loosening): records no bridge references stop being counted" "$m" \
          "an sFlow record no bridge references is red"

m=$(mutant m17 "$NDT" \
    '        if [[ "$n_refs" -gt 1 ]]; then' \
    '        if false; then')
# Discriminating case again: two references leave $u holding two uuids, which matches no record,
# so the target check fires and the run is red for a reason that has nothing to do with the
# duplicate. The message is what the count buys.
report_sh "M17 (loosening): a bridge may reference any number of records" "$m" \
          "  ... and says a bridge samples to one"

m=$(mutant m18 "$NDT" \
    '        if [[ "$port" != "$SFLOW_PORT" ]]; then' \
    '        if false; then')
report_sh "M18: the target port stops being checked" "$m" \
          "a target on the wrong port is red"

m=$(mutant m19 "$NDT" \
    '    if ndt_sudo_refused; then
        echo "sudo refused ovs-vsctl"' \
    '    if true; then
        echo "sudo refused ovs-vsctl"')
report_sh "M19: every failure to ask is blamed on sudo" "$m" \
          "  ... and the reason is ovs-vsctl's, not sudo's"

# --- 🔴 the other direction on the verify side -----------------------------------------------------
# Each of these passes every mutation above. Without the controls this gate would sign off on a
# check that fails every fabric, or one that stops a bring-up because it could not ask -- and
# the second of those is the exact regression sudo_surface.sh was written to prevent.

m=$(mutant n2 "$NDT" \
    '    [[ "${#NDT_SFLOW_PROBLEMS[@]}" -eq 0 ]] && return 0' \
    '    [[ "${#NDT_SFLOW_PROBLEMS[@]}" -lt 0 ]] && return 0')
report_sh "N2 (control): no fabric ever passes" "$m" \
          "control: the healthy fabric passes"

m=$(mutant n3 "$NDT" \
    '        elif ! grep -qx -- "$host" <<<"$locals"; then' \
    '        elif [[ "$host" != "127.0.0.1" ]]; then')
report_sh "N3 (control): only ovs4's collector address is accepted" "$m" \
          "control: the 128-host topology's collector alias passes"

m=$(mutant n4 "$NDT" \
    '        2) warn "sFlow: NOT tested -- ${NDT_SFLOW_WHY:-reason unrecorded}"' \
    '        2) warn "sFlow: NOT tested -- ${NDT_SFLOW_WHY:-reason unrecorded}"; return 1 #')
report_sh "N4 (control): a missing sudo grant stops the bring-up" "$m" \
          "control: a refusal does not fail the bring-up"

echo
[[ "$(sha256sum "$TOPO" | cut -d' ' -f1)" == "$BASE_TOPO" ]] || { echo "🔴 baseline CHANGED -- ovs_4host_topo.py was written during the gate"; exit 3; }
[[ "$(sha256sum "$NDT" | cut -d' ' -f1)" == "$BASE_NDT" ]]   || { echo "🔴 baseline CHANGED -- ndt was written during the gate"; exit 3; }
echo "baseline byte-identical: yes (ovs_4host_topo.py and ndt)"
if [[ "$SURVIVORS" -eq 0 ]]; then
    echo "mutation gate: $MUTATIONS mutations, 0 survived"; exit 0
else
    echo "mutation gate: $MUTATIONS mutations, $SURVIVORS survived"; exit 1
fi
