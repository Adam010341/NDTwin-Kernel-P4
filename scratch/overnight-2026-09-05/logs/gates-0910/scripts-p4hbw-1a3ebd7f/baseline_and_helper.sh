#!/usr/bin/env bash
# Segment W: (1) the root helper is not changed and the installed copy is it; (2) NDTwin's own
# pipeline's evidence chain from the first cut still holds at this head. [Co-developed with claude code -- Adam]
set -u
WT="$1"; BASE=580767a8; PY="$WT/p4_proxy/venv/bin/python"; bad=0
echo "HEAD $(git -C "$WT" rev-parse HEAD)"
d=$(git -C "$WT" diff --stat "$BASE" HEAD -- tools/test_workflow/ndtwin-lab)
echo "helper diff $BASE..HEAD: [${d}] (empty = unchanged)"; [[ -z "$d" ]] || bad=1
r=$(sha256sum "$WT/tools/test_workflow/ndtwin-lab" | cut -d' ' -f1); i=$(sha256sum /usr/local/sbin/ndtwin-lab 2>/dev/null | cut -d' ' -f1)
echo "helper sha256 repo      $r"; echo "helper sha256 installed $i"; [[ "$r" == "$i" ]] || { echo "  (installed != repo)"; bad=1; }
d=$(git -C "$WT" diff --stat "$BASE" HEAD -- p4_proxy/proxy_agent/p4_client.py p4_proxy/proxy_agent/ryu_flow_stats.py p4_proxy/proxy_agent/route_binding.py p4_proxy/proxy_agent/ryu_topology.py p4_proxy/mininet)
echo "write/read-back path diff $BASE..HEAD (p4_client, ryu_flow_stats, route_binding, ryu_topology, mininet): [${d}] (empty = unchanged)"; [[ -z "$d" ]] || bad=1
echo "the first cut's byte-identity classes and the LLDP watchdog suite, at this head:"
( cd "$WT/p4_proxy" && PYTHONPATH=. PYTHONDONTWRITEBYTECODE=1 "$PY" -m unittest \
    tests.test_p4_client_writes.TheNdtwinPipelinesWritesAreByteIdenticalToTheBaseTest \
    tests.test_ryu_flow_stats.TheNdtwinPipelinesFlowStatsAreByteIdenticalToTheBaseTest \
    tests.test_flow_stats_route.TheNdtwinClientsHttpBodyIsByteIdenticalToTheBaseTest \
    tests.test_link_watchdog tests.test_lldp_beacon 2>&1 | grep -E '^(Ran|OK|FAILED|FAIL:|ERROR:)' ) || bad=1
echo "BASELINE-AND-HELPER: $([[ $bad == 0 ]] && echo 'helper unchanged and installed; NDTwin pipeline chain green' || echo BROKEN)"
exit $bad
