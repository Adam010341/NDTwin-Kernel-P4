#!/usr/bin/env bash
#
# L-1: run_layers.sh must test against the fabric that is running, not against whatever
# components.env defaults to.
#
# [Co-developed with claude code -- Adam]
#
# `topo_for_mode()` used to be `p4) echo "$TOPO_P4"`. On 2026-09-02 the fabric was the 128-host
# P4 model and TOPO_P4 is the 4-host file, so L2/L3 reported `host count is 128, topology file
# says 4` and `edge count is 288, topology file says 40` (raw/C39_r5_triage.log:5-9) -- a red on
# a healthy system. `40_r5_p4.sh:336` greps that output for `BROKEN` to decide whether A-8 is
# present, so the instrument manufactured the finding it was being read for.
#
# 🔴 What this file pins is DISCRIMINATING POWER, not greenness. Two directions, and the second
# is the one a careless fix loses:
#
#   * with the defect present (the model ignores the fabric) case 2 must go red;
#   * with the defect absent, a fabric size that NO model describes must be REFUSED, not
#     quietly served the default -- case 5. A selector that always returns a path is exactly
#     the failure being repaired, one level further out.
#
# No fabric, no kernel, no lab claim: NDTWIN_RUN_LAYERS_LIB_ONLY=1 stops run_layers.sh above its
# mode dispatch, the models are fixtures in a temp dir, and the fabric host count is injected by
# overriding fabric_host_count(). The counting itself is tested separately (case 1) against a
# captured-shape `ps` stream, because that is the half an injected count cannot cover.
#
# Run:  bash tests/shell/test_run_layers_topology_from_fabric.sh
# Env:  RUN_LAYERS_UNDER_TEST=<path>   score another copy (the mutation gate uses this)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="${RUN_LAYERS_UNDER_TEST:-$HERE/../../tools/test_workflow/run_layers.sh}"

PASS=0; FAIL=0
t_ok()  { PASS=$((PASS+1)); printf '  ok       %s\n' "$1"; }
t_bad() { FAIL=$((FAIL+1)); printf '  FAILED   %s\n    %s\n' "$1" "$2"; }
done_() { echo "Ran $((PASS+FAIL)) checks, $FAIL failed"; [[ "$FAIL" -eq 0 ]]; exit $?; }

# shellcheck source=/dev/null
if ! NDTWIN_RUN_LAYERS_LIB_ONLY=1 source "$DRIVER" >/dev/null 2>&1; then
    echo "  FAILED   could not source $DRIVER with NDTWIN_RUN_LAYERS_LIB_ONLY=1"
    echo "Ran 1 checks, 1 failed"
    exit 1
fi

TMPROOT="$(mktemp -d /tmp/run-layers-topo-XXXXXX)"
cleanup() { [[ -n "${TMPROOT:-}" && "$TMPROOT" == /tmp/run-layers-topo-* ]] && rm -rf "$TMPROOT"; }
trap cleanup EXIT

# --- fixture models ------------------------------------------------------------------------
# Only the field the selector reads: vertex_type 1 is a HOST, 0 a SWITCH
# (include/common_types/GraphTypes.hpp:23).
SETTING_DIR="$TMPROOT/setting"
mkdir -p "$SETTING_DIR"
write_model() {   # $1 = filename, $2 = host count
    python3 - "$SETTING_DIR/$1" "$2" <<'PY'
import json, sys
path, hosts = sys.argv[1], int(sys.argv[2])
nodes = [{"vertex_type": 0, "dpid": i} for i in range(1, 11)]
nodes += [{"vertex_type": 1, "dpid": 0} for _ in range(hosts)]
json.dump({"nodes": nodes, "edges": []}, open(path, "w"))
PY
}
write_model StaticNetworkTopologyP4_10Switches_4Hosts.json 4
write_model StaticNetworkTopologyP4_10Switches_128Hosts.json 128
write_model StaticNetworkTopologyOVS_10Switches_4Hosts.json 4
# The real tree's OVS default really does have 128 hosts, which is why the two families
# overlap on host count and the family has to be part of the query.
write_model StaticNetworkTopologyMininet_10Switches.json 128

KERNEL_DIR="$TMPROOT"
TOPO_P4="$SETTING_DIR/StaticNetworkTopologyP4_10Switches_4Hosts.json"
TOPO_OVS="$SETTING_DIR/StaticNetworkTopologyMininet_10Switches.json"

# The fabric size, injected. Overriding the function is the seam; the real one is exercised
# by case 1 below.
LIVE_HOSTS=0
fabric_host_count() { echo "$LIVE_HOSTS"; }

# [Co-developed with claude code -- Adam] -- E-2.
# topo_for_mode now asks the kernel before it derives anything. THIS suite is about the
# derivation, and it must not depend on whether something happens to be listening on :8000 --
# a kernel running next door would otherwise answer, and every case below would be measuring
# that kernel instead of the fixtures. Stubbed to "did not say", which is the branch that
# reaches the derivation. The kernel branch has its own suite:
# tests/shell/test_run_layers_asks_kernel.sh.
kernel_graph_json() { return 1; }

# choose <mode> -- run topo_for_mode and stash stdout / stderr / rc.
choose() {
    CHOSEN="$(topo_for_mode "$1" 2>"$TMPROOT/err")"; CHOSE_RC=$?
    CHOSE_ERR="$(cat "$TMPROOT/err")"
}

# --- 1. the counting itself, against a ps stream --------------------------------------------
# Written the way `ps -eo args=` prints it: the mininet tag is the LAST field.
ps_fixture() {
    printf '%s\n' \
        "/usr/bin/python3 /usr/local/bin/mn --custom x.py --topo t" \
        "bash -c sleep 1000 mininet:h1" \
        "bash -c sleep 1000 mininet:h2" \
        "bash -c sleep 1000 mininet:h128" \
        "bash -c sleep 1000 mininet:s1" \
        "bash -c sleep 1000 mininet:s10" \
        "bash -c sleep 1000 mininet:host" \
        "grep mininet:h9 /var/log/syslog" \
        "/usr/local/bin/simple_switch_grpc -i 1@s1-eth1"
}
n="$(ps_fixture | fabric_hosts_in)"
if [[ "$n" == "3" ]]; then
    t_ok "fabric_hosts_in counts host namespaces only (3 of 9 lines)"
else
    t_bad "fabric_hosts_in counts host namespaces only (3 of 9 lines)" \
          "got $n; switches, a non-numeric suffix and a mid-line mention must not count"
fi

# --- 2. THE DEFECT: a 128-host fabric must not be tested against the 4-host model ------------
LIVE_HOSTS=128
choose p4
want="$SETTING_DIR/StaticNetworkTopologyP4_10Switches_128Hosts.json"
if [[ "$CHOSE_RC" -eq 0 && "$CHOSEN" == "$want" ]]; then
    t_ok "128-host fabric selects the 128-host P4 model, not the configured 4-host one"
else
    t_bad "128-host fabric selects the 128-host P4 model, not the configured 4-host one" \
          "rc=$CHOSE_RC chose [$CHOSEN]"
fi

# --- 3. and it did not simply become "always the biggest" ------------------------------------
LIVE_HOSTS=4
choose p4
if [[ "$CHOSE_RC" -eq 0 && "$CHOSEN" == "$TOPO_P4" ]]; then
    t_ok "4-host fabric selects the 4-host P4 model"
else
    t_bad "4-host fabric selects the 4-host P4 model" "rc=$CHOSE_RC chose [$CHOSEN]"
fi

# --- 4. no fabric visible: the configured default, unchanged ---------------------------------
LIVE_HOSTS=0
choose p4
if [[ "$CHOSE_RC" -eq 0 && "$CHOSEN" == "$TOPO_P4" ]]; then
    t_ok "no fabric visible falls back to the configured model"
else
    t_bad "no fabric visible falls back to the configured model" "rc=$CHOSE_RC chose [$CHOSEN]"
fi

# --- 5. DISCRIMINATING POWER: a size no model describes must be refused ----------------------
LIVE_HOSTS=12
choose p4
if [[ "$CHOSE_RC" -eq 3 && -z "$CHOSEN" ]] && grep -q '12 host' <<<"$CHOSE_ERR"; then
    t_ok "a fabric size no model describes is refused (rc 3), not served the default"
else
    t_bad "a fabric size no model describes is refused (rc 3), not served the default" \
          "rc=$CHOSE_RC chose [$CHOSEN]; stderr: ${CHOSE_ERR:0:120}"
fi

# --- 6. families do not cross ----------------------------------------------------------------
LIVE_HOSTS=4
choose ovs
want="$SETTING_DIR/StaticNetworkTopologyOVS_10Switches_4Hosts.json"
if [[ "$CHOSE_RC" -eq 0 && "$CHOSEN" == "$want" ]]; then
    t_ok "an OVS run never picks a P4 model of the same size"
else
    t_bad "an OVS run never picks a P4 model of the same size" "rc=$CHOSE_RC chose [$CHOSEN]"
fi

LIVE_HOSTS=128
choose ovs
if [[ "$CHOSE_RC" -eq 0 && "$CHOSEN" == "$TOPO_OVS" ]]; then
    t_ok "a 128-host OVS fabric picks the Mininet model, not the P4 one"
else
    t_bad "a 128-host OVS fabric picks the Mininet model, not the P4 one" \
          "rc=$CHOSE_RC chose [$CHOSEN]"
fi

# --- 7. NDT_TOPO still overrides everything ---------------------------------------------------
LIVE_HOSTS=128
NDT_TOPO="$SETTING_DIR/StaticNetworkTopologyP4_10Switches_4Hosts.json"
choose p4
unset NDT_TOPO
if [[ "$CHOSE_RC" -eq 0 && "$CHOSEN" == "$TOPO_P4" ]]; then
    t_ok "NDT_TOPO overrides the derivation"
else
    t_bad "NDT_TOPO overrides the derivation" "rc=$CHOSE_RC chose [$CHOSEN]"
fi

# --- 8. an unknown data plane is a usage error, distinct from "cannot derive" -----------------
LIVE_HOSTS=4
choose ""
if [[ "$CHOSE_RC" -eq 2 && -z "$CHOSEN" ]]; then
    t_ok "an unknown data plane returns the usage code (2), distinct from the refusal (3)"
else
    t_bad "an unknown data plane returns the usage code (2), distinct from the refusal (3)" \
          "rc=$CHOSE_RC chose [$CHOSEN]"
fi

done_
