# Fixed and closed defects

This file keeps the codes of defects that are fixed, turned out not to be defects, or were decided not to change. Open defects are listed in `doc/KNOWN-ISSUES.md`.
A code is never reused. A new code continues after the highest number used for its letter in either file.
Cite a fixed defect as `doc/FIXED-ISSUES.md` followed by its code, and an open one against `doc/KNOWN-ISSUES.md`.
Status is one of: fixed, partly fixed, not a defect, decided not to change. The last column names the code that fixes or guards the behaviour on main and, where one exists, the test.

## Letter A

| code | what was wrong | status | where it is fixed or guarded on main |
|---|---|---|---|
| A-1 | On a P4 switch, powering on right after powering off reported success and did nothing. | fixed | `src/ndt_core/power_management/P4PowerStrategy.cpp`; `tests/test_P4PowerStrategy.cpp` |
| A-2 | The topology poll could block forever and nothing reported it. | fixed | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp`; `tools/ryu_apps/rest_topology_bounded.py`; `tests/test_TopologyPollRound.cpp` |
| A-3 | Top-k kept reporting a stopped flow's old rate for about 15 seconds. | fixed | `include/common_types/SFlowType.hpp` |
| A-4 | The OVS 4-host cell had no link telemetry because no sFlow was configured. | fixed | `tools/test_workflow/ovs_4host_topo.py`; `tests/python/test_ovs4_sflow.py` |
| A-4d | On P4, installing a rule and then deleting it black-holed the destination. | fixed | `p4_proxy/proxy_agent/topology_manager.py`; `p4_proxy/tests/test_delete_restores_route.py` |
| A-4e | modify_flow_entry ignored the priority and rewrote another application's rule. | fixed | `src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp`; `tests/test_RoutingStrategies.cpp` |
| A-4f | After an OVS power cycle the bridge lost its sFlow record and link telemetry stayed at 0. The record is now restored on power-on; when the restore cannot be done or verified the power-on answers 502 naming this code. | fixed | `src/ndt_core/power_management/OVSPowerStrategy.cpp`; `tests/shell/mutate_a4f_sflow_power_cycle.sh` |
| A-4g | BLOCK_HOST did nothing on P4 while both data planes always answered success. | fixed | `src/ndt_core/intent_translator/IntentTranslator.cpp`; `p4_proxy/tests/test_refused_install_status.py` |
| A-5 | Every kernel restart truncated the previous run's log. | fixed | `tools/test_workflow/stack.sh`; `tests/shell/test_stack_log_rotation.sh` |
| A-6 | The P4 proxy announced "this run is ruined" on every start, and application cleanup printed sudo noise. | fixed | `p4_proxy/proxy_agent/main.py`; `src/ndt_core/application_management/ApplicationManager.cpp` |
| A-7 | Failures of queued writes were invisible to every API. | fixed | `src/ndt_core/http/HttpSession.cpp`; `tests/test_DispatchOutcomeLog.cpp` |
| A-7b | get_flow_dispatch_status.succeeded answered a different question from the one its name asks. | fixed | `src/ndt_core/http/HttpSession.cpp`; `tests/shell/mutate_dispatch_status_honest.sh` |
| A-8 | Three test tools reported failure while the system was working correctly. | fixed | `tools/contract_test/check_logs.py`; `tests/python/test_check_logs_powered_off.py` |
| A-9 | The Energy-Saving-App's routing_lock stays taken for the length of its lease and is retaken within a second. The kernel side (lock lease ids) is fixed; the application's release paths are not (see A-4b in `doc/KNOWN-ISSUES.md`). | partly fixed | `include/ndt_core/lock_management/LockManager.hpp`; `tests/test_LockLeaseExpiry.cpp` |
| A-10 | /ndt/delete_group_entry on OVS was a silent no-op and leaked the group id. | fixed | `src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp`; `tests/shell/mutate_delete_group_entry.sh` |
| A-11 | A failed ndt up ovs4 did not roll back what it had started. | fixed | `tools/test_workflow/ndt` |
| A-12 | The ovs4 topology configured no sFlow (the same defect as A-4). | fixed | `tools/test_workflow/ovs_4host_topo.py`; `tests/python/test_ovs4_sflow.py` |
| A-13 | `ndt down` killed the kernel with SIGTERM instead of letting it shut down, so its subsystems were never stopped and its per-app folders under /srv/nfs/sim stayed behind. The shutdown itself, until then reached only by Ctrl-C, could abort or hang: the sFlow collector joined its worker threads from two threads at once. A component still running when `ndt down` stops waiting is now killed and fails the teardown. | fixed | `src/main.cpp`; `src/ndt_core/collection/FlowLinkUsageCollector.cpp`; `tools/test_workflow/stack.sh`; `tests/shell/test_kernel_stops_on_term.sh` |
| A-14 | Two sudo -n calls in ndt were not covered by the sudoers rules the manual gives. | fixed | `doc/2026-11-05_user-guide.md`; `tools/test_workflow/ndt` |

## Letter B

| code | what was wrong | status | where it is fixed or guarded on main |
|---|---|---|---|
| B-1 | A rule the switch had rejected was served by the twin as present (a phantom rule). | fixed | `src/ndt_core/routing_management/Controller.cpp`; `tests/test_PhantomFilterCoversOvs.cpp`; `tests/test_PendingEntryFilter.cpp` |
| B-2b | A single quote in a request made the kernel blame a healthy component (shell injection). | fixed | `src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp`; `tests/python/test_shell_command_construction.py` |
| B-2c | The P4 proxy answered 500 to a CIDR ipv4_dst. Cited before as B-2c-b, the same 500 for a non-numeric or out-of-range L4 port or protocol is B-22 below. | fixed | `p4_proxy/proxy_agent/match_shape.py`; `p4_proxy/tests/test_unsupported_match.py` |
| B-2d | The lock endpoints silently substituted routing_lock when no lock was named. | fixed | `include/ndt_core/lock_management/LockManager.hpp` |
| B-4 | A simulation case containing a quote answered 202 but was never sent. | fixed | `src/ndt_core/application_management/SimulationRequestManager.cpp` |
| B-5 | Every normal kernel shutdown ended in terminate (abort). | fixed | `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp`; `tests/test_PowerManagerShutdown.cpp` |
| B-6 | A link failure declared through the API was silently undone by the next 30 s topology poll. | fixed | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp`; `tests/shell/mutate_declared_link_failure_survives_poll.sh` |
| B-7 | set_switches_power_state answered 500 for an unknown IP. | fixed | `src/ndt_core/http/HttpSession.cpp` |
| B-8 | Two POST read endpoints answered 200 and 0 for an unknown dpid. | fixed | `src/ndt_core/http/HttpSession.cpp` |
| B-10 | Naming a switch made ndt status --check report that the topology file had been edited. | fixed | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp`; `tools/test_workflow/ndt` |
| B-11 | A topology file could declare a host with no address. | fixed | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp`; `tests/test_TopologyInputValidation.cpp` |
| B-12 | An unknown brand_name was silently mapped to HARDWARE. | fixed | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp`; `tests/test_TopologyInputValidation.cpp` |
| B-13 | link_bandwidth_bps 0 passed every check and made utilisation null. | fixed | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp`; `tests/test_TopologyInputValidation.cpp` |
| B-14 | An out-of-range vertex_type was accepted from a file but rejected with 400 from the API. | fixed | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp`; `tests/test_TopologyInputValidation.cpp` |
| B-15 | A loose spelling of an address let two hosts share one address. | fixed | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp`; `tests/test_TopologyInputValidation.cpp` |
| B-16 | inject_link_recovery removed netem it had not attached and still answered ok. | fixed | `include/utils/InjectedNetemLedger.hpp`; `tests/test_HttpSessionRouting.cpp` |
| B-22 | A flow rule whose L4 port or protocol (`tp_*`, `tcp_*`, `udp_*`, `ip_proto`, `nw_proto`) was not a number, or did not fit its key (a protocol above 255, a port above 65535, a negative value), was answered 500 by the P4 proxy on add, modify and delete. It is now a 400 that names the field, and nothing is sent to the switch. Through the kernel the request is still answered 200 `queued` and the 400 appears in the dispatch status (`GET /ndt/get_flow_dispatch_status`), because the kernel's own shape check does not cover L4 fields. Cited before as B-2c-b. | fixed | `p4_proxy/proxy_agent/topology_manager.py`; `p4_proxy/tests/test_l4_match_values.py`; `tests/shell/mutate_table_entry.sh` |
| B-23 | A link_recovery_detected report could end an injected link failure, and leave its netem attached, once the control plane had reported the injected link broken. Only inject_link_recovery ends an injection now. | fixed | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp`; `src/ndt_core/http/HttpSession.cpp`; `tests/test_HttpSessionRouting.cpp`; `tests/shell/mutate_withdrawal_needs_observed_failure.sh` |
| B-x | get_detected_flow_data listed ended flows, about 92% of its rows under churn (the ended-flow half of the old B-x entry; the reverse half, a low-rate flow dropping out of the default view, is open as B-21 in doc/KNOWN-ISSUES.md). | fixed | `include/common_types/SFlowType.hpp`; `tests/test_FlowLiveness.cpp` |

## Letter C

| code | what was wrong | status | where it is fixed or guarded on main |
|---|---|---|---|
| C-3 | The temperature loop called front() before filtering by vertex type (undefined behaviour). | fixed | `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp`; `tests/test_SimulatedDeviceMetrics.cpp`; `tests/shell/mutate_first_address_of.sh` |
| C-4 | B-1's phantom-rule filter did not cover the OVS write path. | fixed | `src/ndt_core/routing_management/Controller.cpp`; `tests/test_PhantomFilterCoversOvs.cpp` |
| C-5 | A mixed data-plane topology was accepted although the message said it would be refused. | fixed | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp`; `tests/test_TopologyInputValidation.cpp` |
| C-5b | A topology with no switches was accepted. | fixed | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp`; `tests/test_TopologyInputValidation.cpp` |
| C-5c | A switch marked exempt was still dialled with Brocade OIDs and SSH. | fixed | `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp` |
| C-5d | get_power_report showed exempt switches like measured ones. | fixed | `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp` |
| C-6 | A full bmv2 table answered HTTP 200 "Failed to add route". | fixed | `p4_proxy/proxy_agent/api_routes.py`; `p4_proxy/tests/test_flowentry_endpoints.py` |
| C-7 | A priority delete on P4 always failed while the caller got 200 queued; it is now refused with 501. | fixed | `include/ndt_core/routing_management/FlowJob.hpp`; `tests/test_FlowBatchPartition.cpp` |

## Letter D

| code | what was wrong | status | where it is fixed or guarded on main |
|---|---|---|---|
| D-2 | A proposal to shorten the LLDP beacon interval for faster failure detection; a tuning experiment, and the interval is still 5 s. The code is also used in `ndt` for a different finding that is fixed: `ndt status` and `ndt check` showed the bmv2 build's 1/256 sampling rate on an OVS fabric. | not a defect | `p4_proxy/proxy_agent/topology_manager.py`; `tests/shell/test_ndt_check_sample_rate.sh`; `tests/shell/test_ndt_sample_rate_reads_both_bounds.sh` |

## Letter E

| code | what was wrong | status | where it is fixed or guarded on main |
|---|---|---|---|
| E-2 | Latent faults one flag away; the recursive shared lock in getTopKFlowInfoJson is fixed, the other latent items have no user-visible effect in a default setup. | partly fixed | `src/ndt_core/collection/FlowLinkUsageCollector.cpp`; `tests/shell/test_topk_no_recursive_shared_lock.sh`; `tests/test_TopKFlowInfoLocking.cpp` |

## Letter F

| code | what was wrong | status | where it is fixed or guarded on main |
|---|---|---|---|
| F-1 | get_cpu_utilization and get_memory_utilization returned identical, fabricated values. | fixed | `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp`; `tests/python/test_unavailable_metric_sentinel.py` |
| F-4 | A dead inter-switch link was revived to is_up=true on every poll. | fixed | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp`; `tests/test_OptimisticTopologyReporting.cpp` |
| F-5 | The phantom rule under another number: the same defect as B-1. | fixed | same as B-1: `src/ndt_core/routing_management/Controller.cpp`; `tests/test_PhantomFilterCoversOvs.cpp`; `tests/test_PendingEntryFilter.cpp` |
| F-6 | A switch whose table read failed was dropped from get_switch_openflow_table_entries. | fixed | `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp`; `tests/test_StaleTableCarryForward.cpp` |
| F-8 | left_link_bandwidth_bps was hard-coded to 1 Gbit/s before the first sample. | fixed | `src/ndt_core/http/HttpSession.cpp` |
| F-13 | Group and meter modify/delete on a missing entry (and install on an existing one) answered 200. | fixed | `src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp`; `tests/test_GroupMeterExistence.cpp` |
| F-14 | A host was never marked down. | fixed | `src/ndt_core/collection/TopologyAndFlowMonitor.cpp`; `tests/test_OptimisticTopologyReporting.cpp` |
| F-15 | bmv2 gRPC ports sat inside the ephemeral range, so switches failed to start at random. | fixed | `p4_proxy/mininet/grpc_ports.py`; `tests/python/test_grpc_port_block.py` |
| F-16 | A dead switch's host-facing edges stayed up. | fixed | `src/ndt_core/http/HttpSession.cpp`; `tests/test_OptimisticTopologyReporting.cpp` |

## Letter G

| code | what was wrong | status | where it is fixed or guarded on main |
|---|---|---|---|
| G-2 | Five defects of the whole-machine test harness and ndt (clock, port check, restore chain, host-count helper). | fixed | `tools/test_workflow/ndt`; `tests/shell/test_harness_instruments.sh` |
| G-3 | A chaos-harness control called two routes that do not exist, so the 404 "reproduced" a defect. | fixed | `tests/python/test_chaos_c07_control.py` |
| G-4 | ndt status could not tell that sampling was switched off. | fixed | `tools/test_workflow/ndt` |
| G-6 | ndt apps sim and energy printed "started" with rc 0 while the app might be dead, and stop said "stopped". | fixed | `tools/test_workflow/ndt`; `tests/shell/mutate_g6_apps_liveness.sh` |
| G-7 | ndtwin-lab hard-coded one person's absolute paths and could not be overridden; a config file now overrides them, but the built-in defaults still point at that person's home. | partly fixed | `tools/test_workflow/ndtwin-lab`; `tests/shell/mutate_g7_ndtwin_lab_config.sh` |
| G-8 | The User Manual only symlinked ndt, and with ndtwin-lab absent ndt up failed without saying why. | fixed | `tools/test_workflow/ndt`; `doc/2026-11-05_user-guide.md` |
| G-9 | The ndtwin-lab cleanup called pkill -f four times. | fixed | `tools/test_workflow/ndtwin-lab`; `tests/shell/mutate_g9_cleanup_no_pkill_f.sh` |
| G-10 | The testbed_topo.py self-test printed three OK lines although 128 pings had failed. | fixed | `testbed_topo.py`; `tests/python/test_testbed_banner.py` |
| G-11 | ndt apps stop killed only the bash wrapper; the JVM survived and three liveness checks lied. | fixed | `tools/test_workflow/ndt` |
| G-12 | A dead app left flow rules and locks behind and no command reported that the lab was not clean. | fixed | `tools/test_workflow/ndt`; `tests/shell/test_apps_residue.sh` |
| G-13 | The P4 flow table had no time axis: duration_sec was always 0. The proxy now stamps every rule it installs; `ndt apps stop`, `ndt apps orphans` and `ndt status --check` still cannot date a rule on P4. That remainder is the documented limitation "On P4, `ndt` cannot tell when a rule was installed" in `doc/KNOWN-ISSUES.md`. | partly fixed | `p4_proxy/proxy_agent/rule_install_times.py`; `p4_proxy/tests/test_rule_install_times.py` |
| G-14 | The ndt residue window was blind to energy and simulation apps started by a helper. | fixed | `tools/test_workflow/ndt`; `tests/shell/test_ndt_helper_apps_window.sh` |
| G-15 | run_layers.sh guessed the model from mode and host count instead of asking the kernel. | fixed | `tools/test_workflow/run_layers.sh`; `tests/shell/test_run_layers_asks_kernel.sh` |
| G-17 | A warning_allowlist.txt entry had no call site. | fixed | `tools/contract_test/warning_allowlist.txt`; `tests/python/test_warning_allowlist_entries.py` |
| G-20 | The down_reason vocabulary was written in seven places; not a defect, and a drift guard now compares them. | not a defect | `tests/python/test_contract_spec.py` |
| G-21 | orphans_verdict.sh read a network half that answered nothing as CLEAN. | fixed | `tools/test_workflow/orphans_verdict.sh`; `tests/shell/test_orphans_verdict.sh` |
| G-22 | Two --check test suites read a 148 KB file in the main checkout instead of their own tree. | fixed | `tests/shell/test_ndt_honesty.sh`; `tests/shell/test_ndt_status_check_baseline.sh` |
| G-23 | NDT_TOPO accepted a model of a different network. | fixed | `tools/test_workflow/ndt`; `tests/shell/test_ndt_up_down_robust.sh` |
| G-24 | ndt up overlapping a running ndt down reused the fabric that was being torn down. | fixed | `tools/test_workflow/ndt`; `tests/shell/test_ndt_up_down_robust.sh` |
| G-25 | apps orphans and the tool that reads it judged a half-running stack CLEAN. | fixed | `tools/test_workflow/orphans_verdict.sh`; `tests/shell/test_orphans_verdict.sh` |
| G-26 | ndt help and two return-code tables contained six false sentences. | fixed | `tools/test_workflow/ndt`; `tests/shell/test_ndt_honesty.sh` |
| G-27 | After ndt down no later process could date a rule (the residue window was lost). | fixed | `tools/test_workflow/ndt`; `tests/shell/test_ndt_helper_apps_window.sh` |
| G-28 | ndt claim was not atomic: two owners could both get rc 0 in the same second. | fixed | `tools/test_workflow/ndt`; `tests/shell/test_ndt_down_claim_guard.sh` |
| G-29 | A measuring= claim did not stop its owner's own ndt down from tearing the fabric down. | fixed | `tools/test_workflow/ndt`; `tests/shell/test_ndt_down_claim_guard.sh` |
| G-30 | The ndt down refusal printed a command that broke when pasted. | fixed | `tools/test_workflow/ndt`; `tests/shell/test_ndt_down_claim_guard.sh` |
| G-31 | The claim's "in use" note was silently not updated in the two cases that needed it. | fixed | `tools/test_workflow/ndt` |
| G-32 | The northbound API ignored the lab claim; write replies now carry a lab_claim object (report, do not block). | fixed | `src/ndt_core/http/HttpSession.cpp`; `tests/shell/mutate_lab_claim_on_writes.sh` |
| G-34 | Files under .test_run/pids/ contradicted each other (dead pidfile plus exit record) and nothing said so. | fixed | `tools/test_workflow/ndt`; `tools/test_workflow/stack.sh` |
| G-37 | mutate_cpu_report_no_ip.sh could not go green while its anchor check printed ok(12). | fixed | `tests/shell/mutate_cpu_report_no_ip.sh` |
| G-38 | Two live "sudo pkill -f simple_switch_grpc" calls sat in product code. | fixed | `p4_proxy/mininet/p4_testbed_topo.py`; `tests/shell/mutate_startup_clears_by_pid.sh` |
| G-40 | process_is_a_switch identified a switch by a substring of the whole command line before sending SIGKILL. | fixed | `p4_proxy/mininet/p4_testbed_topo.py` |
| G-41 | The sudoers tc whitelist next to the NOPASSWD mnexec grant is not a security boundary; the user guide now says the grants make the user root. | decided not to change | `doc/2026-11-05_user-guide.md` |
| G-42 | The teardown marker had no owner. | fixed | `tools/test_workflow/ndt`; `tests/shell/test_ndt_up_down_robust.sh` |
| G-43 | ndt down of a live P4 fabric always returned rc 1, contradicting its own clean verification. | fixed | `tools/test_workflow/ndt`; `tests/shell/test_ndt_up_down_robust.sh` |
| G-44 | ndt clean had no guard against a teardown in flight. | fixed | `tools/test_workflow/ndt`; `tests/shell/test_ndt_up_down_robust.sh` |
| G-45 | ndt clean told you "this stack did not start it" about your own fabric. | fixed | `tools/test_workflow/ndt`; `tests/shell/test_ndt_up_down_robust.sh` |
| G-46 | ndt help said --deep sweeps three ports, but it sweeps the whole table. | fixed | `tools/test_workflow/ndt`; `tests/shell/test_ndt_honesty.sh` |
| G-47 | A refused ndt up p4 <n> still rewrote host_count_override. | fixed | `tools/test_workflow/ndt`; `tests/shell/test_ndt_app_package.sh` |
| G-48 | A live-cell assertion on the knob was always green in the main checkout and red on a clean clone. | fixed | `tools/test_workflow/live_cells/up_refuses_a_model_of_another_network.sh` |
| G-49 | A mid-way rc of ndt down was written into the claim note as "did NOT verify clean". | fixed | `tools/test_workflow/ndt` |
| G-50 | A fix that quotes the defect's own string made "string must be absent" checks go red on the fixed tree. | fixed | `tools/test_workflow/live_cells/link_failure_cuts_both_ends_or_neither.sh` |
| G-51 | A claim handover left a trace but no interface reported it. | fixed | `tools/test_workflow/ndt` |
| G-52 | The API reference described the declared-link-failure fix (B-6) and its follow-ups as unmerged after they had merged. | fixed | `doc/2026-01-02_ndt_api.md` |
| G-53 | The rc tables of ndt up, down and clean disagreed, and refused, dirty and nothing-measured collapsed into one. | fixed | `tools/test_workflow/ndt`; `tests/shell/test_manual_rc_table.sh` |
| G-54 | A stale app_*.pid made status --check count the whole flow table as that app's residue. | fixed | `tools/test_workflow/ndt` |
| G-54b | The word "residue" meant two different things in ndt. | fixed | `tools/test_workflow/ndt` |
| G-55 | "No rules in that window" and "no rules on the wire" printed the same message. | fixed | `tools/test_workflow/ndt`; `tests/shell/test_apps_residue.sh` |
| G-56 | Two mutations sharing one anchor made check_gate_anchors undercount ok(N). | fixed | `tests/shell/check_gate_anchors.py`; `tests/shell/mutate_check_process_by_name.sh` |
| G-57 | The machine-wide process scan let another worktree's fixture veto this tree's restore, and ndt down could signal it. | fixed | `tools/test_workflow/ndt` |
| G-58 | Live tools under doc/audit/ fell out of every scan; the tools listed in AUDIT_EXCEPTIONS are scanned now, but `drive_exercise.py` (the P4 tutorial exercise driver, which reads `/proc/<pid>/cmdline`) is still not registered. | partly fixed | `tests/shell/check_process_by_name.py` |
| G-60 | test_ovs4_sflow.py compared against another project's testbed_topo.py on a false premise; the ndt message that names that file is still stale. | partly fixed | `tests/python/test_ovs4_sflow.py`; `tools/test_workflow/ndt` |
| G-63 | On a fresh checkout the first ndt up p4 let root create .test_run/logs, and stack.sh then could not write its log. | fixed | `tools/test_workflow/ndt`; `p4_proxy/mininet/topo_log.py` |

## Letter I

| code | what was wrong | status | where it is fixed or guarded on main |
|---|---|---|---|
| I-3 | host_count_override written as 128 counted as clean in git, so ndt status lost its "can change behaviour" warning. (The same code was also used for what is now G-34.) | fixed | `tools/test_workflow/ndt`; `tests/shell/test_ndt_round_baseline.sh` |

## Letter L

| code | what was wrong | status | where it is fixed or guarded on main |
|---|---|---|---|
| L-1 | run_layers.sh compared against a different network's model and reported the difference as a product failure. | fixed | `tools/test_workflow/run_layers.sh`; `tests/shell/mutate_run_layers_topology_from_fabric.sh` |
| L-3 | check_gate_anchors.py skipped four gate scripts it could not read, yet looked like a pass. | fixed | `tests/shell/check_gate_anchors.py`; `tests/shell/mutate_check_gate_anchors.sh` |
| L-5 | The dispatch-drift scan did not recognise the utils::pathIs registration form and reported false drift. | fixed | `tests/shell/mutate_l3_dispatch_drift.sh`; `tests/python/test_l3_dispatch_drift.py` |

## Letter T

| code | what was wrong | status | where it is fixed or guarded on main |
|---|---|---|---|
| T-9 | A harness work item: instrument defects of the whole-machine harness and ndt (see G-2). | fixed | same as G-2: `tools/test_workflow/ndt`; `tests/shell/test_harness_instruments.sh` |
| T-10 | A harness work item: five harness defects (clock, port check, restore chain and others; see G-2). | fixed | same as G-2: `tests/shell/test_harness_instruments.sh` |
| T-11 | A work item for the phantom rule: a queued, unprogrammed request was served as a flow-table row (see B-1). | fixed | same as B-1: `src/ndt_core/routing_management/Controller.cpp`; `tests/test_PhantomFilterCoversOvs.cpp`; `tests/test_PendingEntryFilter.cpp` |
