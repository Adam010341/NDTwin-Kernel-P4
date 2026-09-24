#!/usr/bin/env bash
# Round 2 red-first, reproducible: the round-2 TESTS (HEAD) against 57aae1bf's PRODUCTION code.
# [Co-developed with claude code -- Adam]
#
# Tree = git archive HEAD (p4_proxy, tools, setting), then every production file round 2 changed
# is put back to its 57aae1bf bytes. The behaviour tests round 2 added must go RED here (they are
# listed below, each with the item it belongs to); guard tests -- green on both codes by design,
# they keep a fix from over-reaching -- are listed separately and are seen red only through their
# named mutations in tests/shell/mutate_roles_binding.sh. Exit 0 when exactly the expected set is
# red, 1 otherwise.
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p4-roles-0924
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/1d79823a-41f9-4ae4-931e-5766b73d61e4/scratchpad
PY=$WT/p4_proxy/venv/bin/python
OLD=57aae1bf
T=$SP/redfirst; rm -rf "$T"; mkdir -p "$T"
git -C "$WT" archive HEAD p4_proxy tools setting | tar -x -C "$T"
rm -rf "$T/p4_proxy/p4_src/build"; ln -s "$WT/p4_proxy/p4_src/build" "$T/p4_proxy/p4_src/build"
for f in main api_routes ryu_flow_stats topology_manager; do
    git -C "$WT" show "$OLD:p4_proxy/proxy_agent/$f.py" > "$T/p4_proxy/proxy_agent/$f.py"
done
echo "tree: HEAD $(git -C "$WT" rev-parse HEAD) tests, $OLD production (main, api_routes, ryu_flow_stats, topology_manager)"
EXPECTED_RED="
item1 tests.test_readopt.ReadoptOnAFabricThatSkipsItsRoutesTest.test_readopting_the_ndtwin_switch_writes_no_route_through_the_unbound_one
item1 tests.test_readopt.ReadoptOnAFabricThatSkipsItsRoutesTest.test_it_says_the_refill_stopped_at_the_attached_hosts_and_why
item1 tests.test_readopt.ReadoptOnAFabricWhoseRouteTablesNdtwinOwnsTest.test_a_fabric_that_skipped_its_routes_at_startup_is_not_refilled_now
item1 tests.test_readopt.ReadoptOnAFabricWhoseRouteTablesNdtwinOwnsTest.test_before_startup_has_run_a_foreign_switch_is_not_refilled
item1 tests.test_readopt.OnlyTheAttachedHostsTest.test_the_default_is_every_host_as_before
item1 tests.test_readopt.OnlyTheAttachedHostsTest.test_restricted_each_switch_routes_only_to_its_own_hosts_and_counts_only_those
item1 tests.test_declared_links.WhichFabricsSeedAndWhenRoutesComeBackTest.test_a_fabric_that_skips_its_routes_tells_the_route_writer
item1 tests.test_declared_links.WhichFabricsSeedAndWhenRoutesComeBackTest.test_a_fabric_whose_routes_ndtwin_owns_does_not_restrict_the_writer
item1 tests.test_declared_links.WhichFabricsSeedAndWhenRoutesComeBackTest.test_an_all_ndtwin_fabric_does_not_restrict_the_writer
item2 tests.test_route_binding.TheLiteralsLiveOnlyInTheBaselineTest.test_no_module_spells_the_four_route_names_outside_baseline_and_the_named_exceptions
item3 tests.test_ryu_flow_stats.OnAForeignPipelineAnUnknownActionIsLeftOutAndCountedTest.test_the_renamed_fixtures_own_rows_list_its_four_routes_and_count_its_tag_row
item3 tests.test_ryu_flow_stats.OnAForeignPipelineAnUnknownActionIsLeftOutAndCountedTest.test_a_row_with_no_usable_match_is_counted_whatever_its_action
item3 tests.test_ryu_flow_stats.OnAForeignPipelineAnUnknownActionIsLeftOutAndCountedTest.test_an_unknown_action_on_a_bound_foreign_switch_is_not_listed
item3 tests.test_ryu_flow_stats.OnAForeignPipelineAnUnknownActionIsLeftOutAndCountedTest.test_on_an_unbound_foreign_switch_the_same_rows_are_counted
item8 tests.test_declared_links.LinkDiscoveryIsTheModeNotTheSeedCountTest.test_a_foreign_fabric_that_declares_no_link_still_says_declared
item8 tests.test_declared_links.LinkDiscoveryIsTheModeNotTheSeedCountTest.test_a_seed_that_raises_says_declared_and_names_the_error
item8 tests.test_declared_links.LinkDiscoveryIsTheModeNotTheSeedCountTest.test_a_seed_that_worked_reports_its_count_and_no_error
item8 tests.test_declared_links.LinkDiscoveryIsTheModeNotTheSeedCountTest.test_a_fabric_that_declares_nothing_reports_null
item8 tests.test_declared_links.LinkDiscoveryIsTheModeNotTheSeedCountTest.test_none_is_for_an_external_control_plane_only
item8 tests.test_declared_links.WhichFabricsSeedAndWhenRoutesComeBackTest.test_a_topology_double_without_the_seeding_call_does_not_stop_startup
item8 tests.test_switch_state.TheDeclaredLinksReportOnTheEndpointTest.test_the_seed_outcome_is_a_top_level_key_not_a_per_switch_one
item8 tests.test_switch_state.TheDeclaredLinksReportOnTheEndpointTest.test_a_fabric_that_declares_nothing_serves_null_rather_than_no_key
item8 tests.test_switch_state.TheDeclaredLinksReportOnTheEndpointTest.test_an_uninjected_seed_reporter_adds_no_key
item8 tests.test_switch_state.TheDeclaredLinksReportOnTheEndpointTest.test_the_proxy_wires_the_reporter_at_import
"
GUARDS="
item1 tests.test_readopt.ReadoptOnAFabricThatSkipsItsRoutesTest.test_on_a_fabric_that_installs_routes_the_same_readopt_refills_every_host
item1 tests.test_readopt.ReadoptOnAFabricWhoseRouteTablesNdtwinOwnsTest.test_a_package_owned_switch_is_not_refilled_on_a_fabric_that_installs_routes
item2 tests.test_route_binding.TheLiteralsLiveOnlyInTheBaselineTest.test_the_renderer_reads_the_route_match_field_back_as_nw_dst
item3 tests.test_ryu_flow_stats.OnAForeignPipelineAnUnknownActionIsLeftOutAndCountedTest.test_a_default_row_is_never_counted
item4 tests.test_flow_stats_route.TheNdtwinClientsHttpBodyIsByteIdenticalToTheBaseTest.test_the_body_is_the_one_the_base_answered_byte_for_byte
item4 tests.test_flow_stats_route.TheNdtwinClientsHttpBodyIsByteIdenticalToTheBaseTest.test_a_client_bound_to_the_baseline_answers_the_same_bytes
item4 tests.test_flow_stats_route.TheNdtwinClientsHttpBodyIsByteIdenticalToTheBaseTest.test_the_constant_is_the_recording
item5 tests.test_route_binding.AWriteWithNoBindingIs501OnTheRenamedFixtureTest.test_a_five_tuple_delete_on_a_foreign_switch_answers_501
item5 tests.test_route_binding.AWriteWithNoBindingIs501OnTheRenamedFixtureTest.test_a_five_tuple_modify_on_a_foreign_switch_answers_501
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
echo "ROUND2-RED-FIRST: $([[ $bad == 0 ]] && echo 'every behaviour test red on the old code, every guard green' || echo 'SOMETHING UNEXPECTED')"
exit $bad
