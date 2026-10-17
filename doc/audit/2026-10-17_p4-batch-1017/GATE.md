# The 10-17 P4 batch: merge head and gate

Four branches merged on 13d5e905 into one head and gated once there.
Raw logs: audit-raw, `scratch/overnight-2026-09-05/logs/gates-0910/merged-trunk-1017/` (Stage D in its
`nslab/` subdirectory).

## The head

| Commit | What |
|---|---|
| 1f5c5dc2 | Merge branch 'feat/p4-bmv2-listen-local' (f6cce88c: bmv2's gRPC server listens on 127.0.0.1 unless NDTWIN_BMV2_HOST says otherwise; host-firewall advice for the Thrift port) |
| ed86bdd1 | Merge branch 'feat/p4-modify-at-slot-priority' (b6089a07: modify lands on the entry at its slot's priority) |
| 327a4adf | Merge branch 'feat/p4-register-thrift' (badb363c: direct-counter reads over P4Runtime, register reads over Thrift; contains feat/p4-register-read 3bd635ce) |
| 67146b0f | Merge branch 'feat/p4-paper-apps' (e6b582d2: int-v1 and ONTAS as app packages, the Thrift CLI translator) |
| f254e07b | doc: give the Thrift firewall rule for any dpid (after the gate, documentation only) |

The third merge had one conflict, in p4_client.py just above `_FIVE_TUPLE_KEY_BITS`: the two new
direct-counter methods were kept, followed by trunk's comment on the key widths in bits. Across the 56
paths the merges changed, 50 are blob-equal to the one branch tip that changed them; the 6 changed by
two sides (p4_client.py, api_routes.py, main.py, topology_manager.py, stack.sh, KNOWN-ISSUES.md) keep
every line each side added. No C++ file changed, so the kernel build was not redone.

f254e07b changed only the testing manual and KNOWN-ISSUES.md. The eight suites that read those files
and check_gate_anchors gave the same counts before and after it (anchors 139/139).

## The gate (all at 67146b0f; every step rc 0)

Stage C ran on the laptop, Stage D on nslab (row A-14 of NSLAB-USAGE-RULES.md: four VMs of 4 vCPU,
Ubuntu 24.04, python3 3.12.3, p4c 1.2.5.16, the same locale as the laptop; P4 build byte-identical).

| Step | Result |
|---|---|
| mutate_table_journal / mutate_table_entry / mutate_table_entry_owner | 198 / 84 / 27 mutations, 0 survived |
| mutate_roles_binding | 194, 0 survived |
| mutate_p4_register_thrift / mutate_p4_direct_counter | 65 / 33, 0 survived |
| mutate_p4_priority_refusal / mutate_p4_exercise_tools | 43 / 77, 0 survived |
| mutate_link_telemetry / mutate_startup_clears_by_pid | 57 / 22, 0 survived |
| mutate_app_package / telemetry_by_name / p4_rule_install_time / rule_journal_is_wired / p4_probe | 48 / 23 / 27 / 14 / 6, 0 survived |
| mutate_stack_telemetry_identity | 4 mutations, 0 survived; 1 control, 0 went red |
| mutate_l1_shell_scoring | 62 killed, 0 survived |
| check_gate_anchors | 139/139 cells ok |
| p4lane / klane | FAILURES=0 / FAILURES=0 |
| no stray table-entry journal | 2317 tests in one process and 57 files one by one; the checkout's journal unchanged |
| journal tests seen red | 224 of 224 |
| test_ndt_app_package / test_l1_shell_scoring | 408 / 167 checks, 0 failed |
| p4_health cells and collect, Python 3.12, 3.8 and the proxy venv | 204 OK each |
| p4_health recover / gate scripts | 163 / 79 checks, 0 failed |
| register and Thrift unit suites | test_bm_thrift 25, test_register_route 49, OK |
| converter and live-step suites | 305 OK; test_live_p1_09 / 10 / common 25 / 30 / 220 checks, 0 failed |
| offline bmv2 trials, stock and fast | slot priority FAILS=[]; register read 41/41 and impostor/replace 27/27 checks; int-v1 17/17, ONTAS 12/12 verdicts |
| S0 and the replay trial | COMPLETE / ALL CHECKS PASS |
| p4_health mutation gate, four shards | `GATE: 530 mutations, 0 survived, shards 4/4 ok, commit 67146b0f, tree fd39f8cc` |

tools/p4_health at 67146b0f is tree fd39f8cc, the register branch's. test_l1_shell_scoring has two
checks more than 10-16 (167 vs 165): the two live-step suites the paper-apps branch added.

Against the 10-16 gate, the 517 mutants both runs share have the same verdict; 5 of them are also caught
by tests the register branch added. The 13 new register-cell mutants are caught, as they were in a
laptop run of those 13 at the same commit.

## What did not go to plan

- The laptop rebooted at about 17:54 during the kernel lane. The gate clone was rebuilt at the same
  commit and the lane re-run; the 53 steps before it ran in the first clone, the last 5 in the second,
  so the check that no test left `p4_proxy/.run` behind covers only the second clone.
- A disk cleanup at 16:33 removed a lane script the kernel lane reads; it was restored byte-identical
  from audit-raw before the lane ran.
- The pre-step guard waited 40 minutes on another project's ssh client whose command line named a
  `driver.sh` on a remote machine; the guard was narrowed to skip ssh clients, with a control showing a
  local `driver.sh` still blocks.

[Co-developed with claude code -- Adam]
