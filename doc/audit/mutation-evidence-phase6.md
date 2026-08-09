# Mutation evidence -- Phase 6 tests (commit 6f30a2f)

Gate run for the two test files added in `6f30a2f`:

- `p4_proxy/tests/test_startup.py` (13 tests) against `p4_proxy/proxy_agent/main.py`
- `p4_proxy/tests/test_link_watchdog.py` (34 tests) against `p4_proxy/proxy_agent/topology_manager.py`

Interpreter: `venv/bin/python3` only. The `python3` on PATH is a conda install with no `grpc` /
`networkx`; under it whole suites skip and the run still prints `OK`.

```
cd /home/adam/Desktop/NDTwin-Kernel/p4_proxy
PYTHONPATH=. venv/bin/python3 -m unittest -v tests.test_startup
PYTHONPATH=. venv/bin/python3 -m unittest -v tests.test_link_watchdog
```

Baseline at 6f30a2f, unmutated: `Ran 13 tests ... OK` and `Ran 34 tests ... OK`.
Each mutation was applied to the production file only, run, then reverted with
`git checkout --`, verified clean with `git diff --quiet`, and the suite re-run green before the
next mutation.

## main.py / test_startup.py

| id | mutation (literal, as applied) | tests that failed | first failure message | verdict |
|----|--------------------------------|-------------------|-----------------------|---------|
| M1 | `usable = [i for i in clients if i not in broken]` -> `usable = list(clients)` | `test_a_switch_whose_pipeline_push_failed_is_not_claimed`, `test_one_dead_switch_does_not_stop_the_others_from_being_set_up` | `AssertionError: Lists differ: [1, 2] != [1]` (test_startup.py:120, `parts["kernel"].entered`) | KILLED |
| M2 | telemetry block (`agent_ips = agent_ips_loader()` .. end of that for-loop) moved verbatim to immediately above `broken = set()` | all 13 (errors) | `UnboundLocalError: cannot access local variable 'broken' where it is not associated with a value` at main.py:130 (`if i in broken:`) | KILLED, but see note M2 below |
| M2b | as M2, plus `broken = set()` hoisted above the moved block so the telemetry loop runs first against an empty `broken` -- a genuine order inversion with no UnboundLocalError | `test_a_broken_switch_gets_no_clone_session_attempted`, `test_the_clone_session_is_programmed_after_the_pipeline_not_before`, `test_one_dead_switch_does_not_stop_the_others_from_being_set_up` | `AssertionError: 'clone' unexpectedly found in ['clone', 'pipeline']` (test_startup.py:178); ordering test gave `AssertionError: Lists differ: ['clone', 'pipeline'] != ['pipeline', 'clone']` | KILLED |
| M3 | deleted `if i in broken:` / `continue` from the telemetry loop (loop body now starts `agent_ip = agent_ips.get(i)`) | `test_a_broken_switch_gets_no_clone_session_attempted`, `test_one_dead_switch_does_not_stop_the_others_from_being_set_up` | `AssertionError: 'clone' unexpectedly found in ['pipeline', 'clone']` (test_startup.py:178) | KILLED |
| M4 | `telemetry.append(i)` moved out of `if client.write_clone_session():` to run unconditionally just after `client.sample_callback = sflow.handle_sample` | `test_a_failed_clone_session_does_not_cost_the_switch_its_place_in_the_graph` | `AssertionError: Lists differ: [1, 2] != [2]` (test_startup.py:170, `summary["telemetry"]`) | KILLED |
| M5 | `not_entered = [i for i in usable if i not in entered]` -> `not_entered = []` | `test_a_switch_the_kernel_refuses_is_reported_not_silently_dropped` | `AssertionError: Lists differ: [] != [2] : a switch the kernel did not acknowledge must be named; its vertex stays disabled and every path through it will be empty` (test_startup.py:147) | KILLED |
| M6 | deleted `topo.start_link_watchdog()`, leaving the `try:` with only its `print` | `test_a_loop_that_fails_to_start_does_not_abort_the_rest_of_startup`, `test_all_three_loops_are_started` | `AssertionError: Lists differ: ['liveness'] != ['liveness', 'watchdog']` (test_startup.py:208) | KILLED |
| M7 | deleted `client.sample_callback = sflow.handle_sample` | `test_the_sample_callback_is_wired_so_arriving_samples_have_somewhere_to_go` | `AssertionError: None != <bound method FakeSflow.handle_sample ...>` (test_startup.py:190) | KILLED |
| M8 | `agent_ip = agent_ips.get(i)` + `if agent_ip is None: print(...); continue` -> `agent_ip = agent_ips.get(i) or "0.0.0.0"` (no skip) | `test_a_switch_with_no_agent_ip_gets_no_telemetry_but_is_still_claimed` | `AssertionError: {1: '192.168.123.11', 2: '0.0.0.0'} != {1: '192.168.123.11'}` (test_startup.py:161) | KILLED |
| M9 | removed the `try:`/`except Exception as e:` around `topo.start_lldp_discovery()`, leaving `topo.start_lldp_discovery()` + its `print` bare | `test_a_loop_that_fails_to_start_does_not_abort_the_rest_of_startup` (error) | `RuntimeError: cannot start` propagating out of `startup` at main.py:204 | KILLED |
| M10 | deleted `for dpid, client in clients.items(): topo.add_switch(dpid, client)` | `test_every_connected_switch_is_registered_with_the_topology_manager` | `AssertionError: Lists differ: [] != [1, 2]` (test_startup.py:217) | KILLED |
| M11 | `entered = [i for i in usable if kernel.switch_entered(i)]` -> `for i in usable: kernel.switch_entered(i)` then `entered = list(usable)` | `test_a_switch_the_kernel_refuses_is_reported_not_silently_dropped` | `AssertionError: Lists differ: [1, 2] != [1]` (test_startup.py:146, `summary["entered"]`) | KILLED |

## topology_manager.py / test_link_watchdog.py

| id | mutation (literal, as applied) | tests that failed | first failure message | verdict |
|----|--------------------------------|-------------------|-----------------------|---------|
| M12 | `down = (now - entry["at"]) > self._link_timeout(entry)` -> `>=` | `test_exactly_at_the_timeout_is_not_yet_a_failure` | `AssertionError: Lists differ: [(1, 1, 5, 1)] != []` (test_link_watchdog.py:119) | KILLED |
| M13 | `LINK_BEACON_TIMEOUT_S = 3 * LLDP_BEACON_INTERVAL_S` -> `1 * LLDP_BEACON_INTERVAL_S` | `test_one_missed_beacon_is_not_a_failure` | `AssertionError: Lists differ: [(1, 1, 5, 1)] != []` (test_link_watchdog.py:126) | KILLED |
| M14 | deleted `entry["acked"] = False` from the `if down != entry["down"]:` branch (branch now only `entry["down"] = down`) | 15 tests: `test_transitions_are_still_tracked_without_a_kernel_to_tell`, `test_a_link_can_fail_and_recover_more_than_once`, `test_a_link_whose_beacons_return_is_reported_recovered`, `test_recovery_is_reported_once`, `test_a_beacon_arriving_while_the_report_is_in_flight_is_not_acknowledged_away`, `test_a_notifier_that_raises_does_not_end_the_pass`, `test_a_report_the_kernel_did_not_accept_is_retried`, `test_an_accepted_report_is_not_retried`, `test_a_seeded_link_that_never_speaks_is_eventually_reported`, `test_a_seeded_link_that_speaks_graduates_to_the_steady_state_timeout`, `test_seeding_does_not_overwrite_a_link_that_has_already_spoken`, `test_a_failure_is_reported_once_not_on_every_pass`, `test_a_link_silent_past_the_timeout_is_reported_failed`, `test_each_direction_is_tracked_independently`, `test_the_report_carries_the_four_values_in_the_order_the_kernel_reads_them` | `AssertionError: Lists differ: [] != [(1, 1, 5, 1)]` (test_link_watchdog.py:246) | KILLED |
| M15 | `if entry is not None and entry["down"] == down:` -> `if entry is not None:` (the ack step of `check_link_beacons`) | **none** -- `Ran 34 tests in 0.006s` / `OK` | -- | **SURVIVED** (see note M15) |
| M16 | `if self._notify_link(link, down):` -> bare `self._notify_link(link, down)`; ack + `(reported_down if down else reported_up).append(link)` now unconditional, `else: still_unacked.append(link)` deleted | `test_a_notifier_that_raises_does_not_end_the_pass`, `test_a_report_the_kernel_did_not_accept_is_retried` | `AssertionError: Lists differ: [] != [(1, 1, 5, 1)]` (test_link_watchdog.py:237, `["unacked"]`) | KILLED |
| M17 | `if lldp_info[0] != device_id:` -> `if True:` (link-recording block in `handle_packet_in`) | `test_a_beacon_from_the_switch_that_received_it_is_not_a_link` | `AssertionError: Lists differ: [(4, 2, 4, 2)] != []` (test_link_watchdog.py:146) | KILLED |
| M18 | deleted `entry["seen"] = True` from the else-branch in `handle_packet_in` (branch now only `entry["at"] = now`) | `test_a_seeded_link_that_speaks_graduates_to_the_steady_state_timeout` | `AssertionError: (1, 1, 5, 1) not found in []` (test_link_watchdog.py:289) | KILLED |
| M19 | `return LINK_BEACON_TIMEOUT_S if entry.get("seen", True) else LINK_STARTUP_GRACE_S` -> `return LINK_BEACON_TIMEOUT_S` | `test_a_seeded_link_is_not_reported_before_the_startup_grace_expires` | `AssertionError: Lists differ: [(1, 1, 5, 1), (5, 1, 1, 1), ... ] != []` -- 32 seeded links all reported down (test_link_watchdog.py:274) | KILLED |
| M20 | deleted `if link not in self._link_beacons:` from `seed_expected_links`, so the seed always overwrites | `test_seeding_does_not_overwrite_a_link_that_has_already_spoken` | `AssertionError: (1, 1, 5, 1) not found in []` (test_link_watchdog.py:295) | KILLED |
| M21 | `if self._lldp_stop.wait(LLDP_BEACON_INTERVAL_S): break` -> `time.sleep(LLDP_BEACON_INTERVAL_S)` | `test_stopping_waits_rather_than_only_setting_a_flag`, `test_the_beacon_thread_can_be_stopped` | `AssertionError: 'lldp-beacon' unexpectedly found in ['MainThread', 'lldp-beacon', 'lldp-beacon']` (test_link_watchdog.py:347) | KILLED (no hang; suite took 6.0s vs 0.007s baseline) |
| M22 | in `stop_lldp_discovery`, `thread.join(timeout)` -> `pass` (guard `if thread is not None and thread.is_alive():` kept) | `test_stopping_waits_rather_than_only_setting_a_flag`, `test_the_beacon_thread_can_be_stopped` | `AssertionError: 'lldp-beacon' unexpectedly found in ['MainThread', 'lldp-beacon']` (test_link_watchdog.py:347) | KILLED (no hang, 0.007s; kill is a race so re-verified 5/5 `FAILED (failures=2)`) |
| M23 | in `start_lldp_discovery`, deleted `if self._lldp_running: return` | `test_starting_twice_does_not_leave_two_beacon_threads` | `AssertionError: <Thread(lldp-beacon, started daemon ...)> is not <Thread(lldp-beacon, started daemon ...)>` (test_link_watchdog.py:354) | KILLED (no hang, 0.007s) |
| M24 | deleted `"links": self.link_liveness(),` from the `switch_liveness()` return dict | `test_it_appears_in_the_switch_state_payload_the_kernel_polls` (error) | `KeyError: 'links'` (test_link_watchdog.py:320) | KILLED |
| M25 | `report = self._kernel.link_failure if down else self._kernel.link_recovery` -> `self._kernel.link_recovery if down else self._kernel.link_failure` | `test_a_notifier_that_raises_does_not_end_the_pass`, `test_a_report_the_kernel_did_not_accept_is_retried`, `test_an_accepted_report_is_not_retried`, `test_a_failure_is_reported_once_not_on_every_pass`, `test_a_link_silent_past_the_timeout_is_reported_failed`, `test_the_report_carries_the_four_values_in_the_order_the_kernel_reads_them` | `AssertionError: Lists differ: [] != [(1, 1, 5, 1)]` (test_link_watchdog.py:237, `["unacked"]`) | KILLED |
| M26 | `link = (lldp_info[0], lldp_info[1], device_id, ingress_port)` -> `(device_id, ingress_port, lldp_info[0], lldp_info[1])` | 12 tests: `test_it_appears_in_the_switch_state_payload_the_kernel_polls`, `test_it_reports_the_age_the_down_state_and_whether_the_kernel_knows` (error), `test_transitions_are_still_tracked_without_a_kernel_to_tell`, `test_a_link_whose_beacons_return_is_reported_recovered`, `test_a_beacon_arriving_while_the_report_is_in_flight_is_not_acknowledged_away`, `test_a_notifier_that_raises_does_not_end_the_pass`, `test_a_report_the_kernel_did_not_accept_is_retried`, `test_a_seeded_link_that_speaks_graduates_to_the_steady_state_timeout`, `test_seeding_does_not_overwrite_a_link_that_has_already_spoken`, `test_a_link_silent_past_the_timeout_is_reported_failed`, `test_each_direction_is_tracked_independently`, `test_the_report_carries_the_four_values_in_the_order_the_kernel_reads_them` | `KeyError: '1:1->5:1'` (test_link_watchdog.py:307) | KILLED |
| M27 | in `_notify_link`, `if self._kernel is None: return True` -> `return False` | `test_transitions_are_still_tracked_without_a_kernel_to_tell` | `AssertionError: Lists differ: [] != [(1, 1, 5, 1)]` (test_link_watchdog.py:246) | KILLED |

## Notes on the mutations that need one

### M2 -- killed, but not by the assertion it was aimed at

Moving the telemetry block above `broken = set()` verbatim makes `if i in broken:` read a local
that has not been bound yet, so `startup` raises before it does anything interesting and all 13
tests error identically:

```
UnboundLocalError: cannot access local variable 'broken' where it is not associated with a value
```

That is a kill, but it is the kill you would get from any syntax-level breakage -- it says nothing
about whether `test_the_clone_session_is_programmed_after_the_pipeline_not_before` can detect a real
order inversion. M2b is the corrected form: identical move, plus `broken = set()` hoisted above the
moved block so the code runs. Under M2b the ordering test fails on its own terms
(`['clone', 'pipeline'] != ['pipeline', 'clone']`), so that test does have real evidence behind it.

### M15 -- SURVIVED: cause (1), the test genuinely cannot catch it

The mutated line as it ended up in the file:

```python
                with self._liveness_lock:
                    entry = self._link_beacons.get(link)
                    if entry is not None:
                        entry["acked"] = True
```

`test_a_beacon_arriving_while_the_report_is_in_flight_is_not_acknowledged_away` exists precisely for
this guard, and it still passed. This is **not** a case of the mutation missing its target: the
mutated line is reached. Proof, by replacing the guard body with raises:

```python
                    if entry is not None and entry["down"] != down:
                        raise AssertionError("M15 PROBE A: divergent case DID occur")
                    if entry is not None and entry["down"] == down:
                        raise AssertionError("M15 PROBE B: guard body reached (down == reported)")
```

- PROBE B raised in **15** tests -- the line is thoroughly reached.
- PROBE A raised in **0** tests -- the condition the guard discriminates on
  (`entry["down"] != down` at ack time) never becomes true anywhere in the suite.

Why: `handle_packet_in` writes only `entry["at"]` and `entry["seen"]` for an existing entry. It
never writes `entry["down"]`. So the test's `on_report` hook -- which calls `beacon()`, i.e.
`handle_packet_in` -- cannot flip `down` mid-report. `down` is recomputed only on the *next*
`check_link_beacons` pass, by which time the ack has already happened. The test therefore exercises
the fail-then-recover sequence (which is real, and which M14 shows it does catch) but not the
in-flight divergence its docstring describes.

Worth flagging beyond the test: `entry["down"]` is assigned in exactly one place,
`topology_manager.py:824` inside `check_link_beacons`, and `check_link_beacons` has exactly one
production caller -- the single `link-watchdog` thread (`topology_manager.py:879`). With one writer
on one thread, `entry["down"] == down` cannot be false in production either. The guard is currently
defending against a state the code cannot reach. It is cheap and correct to keep as protection
against a future second caller, but the test claiming to cover it does not, and no test can until
either a second concurrent pass exists or `handle_packet_in` is given the power to clear `down`.
