#!/usr/bin/env bash
# Segment W's red-first, reproducible: the tests at HEAD against the production code of the base
# 580767a8 (before any W change). [Co-developed with claude code -- Adam]
#   proxy: git archive HEAD's p4_proxy + tools, with link_heartbeat.py removed and
#          topology_manager.py / main.py / api_routes.py put back to their 580767a8 bytes;
#          the four new modules and the two changed first-cut tests must be red there.
#   ndt:   test_ndt_heartbeat.sh at HEAD against 580767a8's ndt (beside its own siblings).
set -u
WT="$1"; BASE=580767a8; PY="$WT/p4_proxy/venv/bin/python"; T=$(mktemp -d "${TMPDIR:-/tmp}/hbw-red-XXXXXX"); bad=0
trap 'rm -rf "$T"' EXIT
echo "HEAD $(git -C "$WT" rev-parse HEAD)   base $(git -C "$WT" rev-parse $BASE)"
git -C "$WT" archive HEAD p4_proxy tools | tar -x -C "$T"
rm -rf "$T/p4_proxy/p4_src/build"; ln -s "$WT/p4_proxy/p4_src/build" "$T/p4_proxy/p4_src/build"; ln -s "$WT/setting" "$T/setting"
rm -f "$T/p4_proxy/proxy_agent/link_heartbeat.py"
for f in topology_manager.py main.py api_routes.py; do git -C "$WT" show "$BASE:p4_proxy/proxy_agent/$f" > "$T/p4_proxy/proxy_agent/$f"; done
out=$(cd "$T/p4_proxy" && PYTHONPATH=. PYTHONDONTWRITEBYTECODE=1 HOME="$T" timeout 300 "$PY" -m unittest \
    tests.test_link_heartbeat tests.test_heartbeat_watchdog tests.test_heartbeat_fabric tests.test_flowentry_read_only \
    tests.test_route_binding.AWriteWithNoBindingIs501OnTheRenamedFixtureTest.test_an_external_control_plane_refuses_first_as_it_always_did \
    tests.test_link_state_entry.TheEntryIsNotWiredInThisCutTest.test_its_one_caller_is_the_watchdog_pass_ingesting_the_heartbeat 2>&1)
printf '%s\n' "$out" | grep -E '^(FAIL|ERROR):|^Ran|^OK|^FAILED'
grep -q '^FAILED' <<<"$out" || { echo "  🔴 the proxy tests are NOT red against the base's production code"; bad=1; }
for t in test_link_heartbeat test_heartbeat_watchdog test_heartbeat_fabric; do
    grep -qF "_FailedTest.$t)" <<<"$out" && echo "  red: tests.$t does not import at the base (proxy_agent.link_heartbeat missing)" \
        || { echo "  🔴 tests.$t imported at the base"; bad=1; }
done
for id in test_an_external_control_plane_refuses_first_as_it_always_did test_its_one_caller_is_the_watchdog_pass_ingesting_the_heartbeat; do
    grep -qE "^(FAIL|ERROR): $id " <<<"$out" && echo "  red: $id" || { echo "  🔴 green at the base: $id"; bad=1; }
done
N="$T/ndt"; mkdir -p "$N"
for f in ndt ports.sh sudo_surface.sh components.env; do git -C "$WT" show "$BASE:tools/test_workflow/$f" > "$N/$f" 2>/dev/null || rm -f "$N/$f"; done
nout=$(TMPDIR="$T" NDT_UNDER_TEST="$N/ndt" timeout 600 bash "$WT/tests/shell/test_ndt_heartbeat.sh" 2>&1)
echo "test_ndt_heartbeat.sh at HEAD against the base's ndt: $(tail -1 <<<"$nout")"
grep -q ', 0 failed' <<<"$(tail -1 <<<"$nout")" && { echo "  🔴 not red"; bad=1; }
echo "RED-FIRST: $([[ $bad == 0 ]] && echo 'red against the base, as it must be' || echo BROKEN)"
exit $bad
