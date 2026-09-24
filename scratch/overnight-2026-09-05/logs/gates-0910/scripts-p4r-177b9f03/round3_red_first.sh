#!/usr/bin/env bash
# Round 3 red-first, reproducible: the round-3 TESTS (HEAD) against 3ff87a10's PRODUCTION code
# (TICKET-P4-roles section 7 ruling 6).
# [Co-developed with claude code -- Adam]
#
# Tree = git archive HEAD (p4_proxy, tools, setting), then every production file round 3 changed
# is put back to its 3ff87a10 bytes. The behaviour tests round 3 added must go RED here (they are
# listed below, each with the item it belongs to); guard tests -- green on both codes by design,
# they keep a fix from over-reaching -- are listed separately and are seen red only through their
# named mutations in tests/shell/mutate_roles_binding.sh. Exit 0 when exactly the expected set is
# red, 1 otherwise.
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-roles-0924
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1d79823a-41f9-4ae4-931e-5766b73d61e4/scratchpad
PY=$WT/p4_proxy/venv/bin/python
OLD=3ff87a10
T=$SP/redfirst; rm -rf "$T"; mkdir -p "$T"
git -C "$WT" archive HEAD p4_proxy tools setting | tar -x -C "$T"
rm -rf "$T/p4_proxy/p4_src/build"; ln -s "$WT/p4_proxy/p4_src/build" "$T/p4_proxy/p4_src/build"
for f in main topology_manager; do
    git -C "$WT" show "$OLD:p4_proxy/proxy_agent/$f.py" > "$T/p4_proxy/proxy_agent/$f.py"
done
echo "tree: HEAD $(git -C "$WT" rev-parse HEAD) tests, $OLD production (main, topology_manager)"
EXPECTED_RED="
F1 tests.test_readopt.ADeleteOnAFabricThatSkipsItsRoutesTest.test_withdrawing_a_rule_for_a_host_behind_another_switch_restores_nothing_through_it
F2 tests.test_readopt.ReadoptOnAFabricThatSkipsItsRoutesTest.test_with_no_host_of_its_own_it_promises_no_watchdog_that_does_not_run
F3 tests.test_readopt.ReadoptOnAFabricWhoseRouteTablesNdtwinOwnsTest.test_a_skipped_refill_on_an_owned_switch_says_the_fabric_skipped_its_routes
F3 tests.test_readopt.ReadoptOnAFabricWhoseRouteTablesNdtwinOwnsTest.test_before_startup_an_owned_switch_says_startup_has_not_decided
"
GUARDS="
F1 tests.test_readopt.ADeleteOnAFabricThatSkipsItsRoutesTest.test_an_attached_host_is_still_restored_in_place
F1 tests.test_readopt.ADeleteOnAFabricThatSkipsItsRoutesTest.test_on_a_fabric_that_installs_routes_the_remote_host_is_restored_as_before
F2 tests.test_readopt.ReadoptOnAFabricThatSkipsItsRoutesTest.test_where_the_watchdog_runs_the_pending_note_stays
F4 tests.test_flow_stats_route.TheNdtwinClientsHttpBodyIsByteIdenticalToTheBaseTest.test_the_recorder_in_the_repo_is_the_one_that_recorded
"
ids() { awk 'NF==2{print $2}' <<<"$1"; }
out=$(env -C "$T/p4_proxy" PYTHONPATH="$T/p4_proxy" PYTHONDONTWRITEBYTECODE=1 TMPDIR="$SP/tmp" \
      "$PY" -m unittest -v $(ids "$EXPECTED_RED") $(ids "$GUARDS") 2>&1)
red=$(sed -n -E 's/^(FAIL|ERROR): [^ ]+ \(([^)]*)\).*/\2/p' <<<"$out" | sort -u)
bad=0
echo; echo "== behaviour tests: must be RED on $OLD's code"
while read -r item id; do
    [[ -z "$id" ]] && continue
    if /usr/bin/grep -qxF "$id" <<<"$red"; then echo "  red    [$item] $id"
    else echo "  GREEN  [$item] $id   <-- expected red"; bad=1; fi
done <<<"$EXPECTED_RED"
echo; echo "== guards: green on both codes by design (seen red through their named mutations)"
while read -r item id; do
    [[ -z "$id" ]] && continue
    if /usr/bin/grep -qxF "$id" <<<"$red"; then echo "  RED    [$item] $id   <-- unexpected"; bad=1
    else echo "  green  [$item] $id"; fi
done <<<"$GUARDS"
echo; /usr/bin/grep -E '^Ran |^OK|^FAILED' <<<"$out"
rm -rf "$T"
echo "ROUND3-RED-FIRST: $([[ $bad == 0 ]] && echo 'every behaviour test red on the old code, every guard green' || echo 'SOMETHING UNEXPECTED')"
exit $bad
