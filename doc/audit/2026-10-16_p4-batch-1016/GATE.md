# The 10-16 P4 batch: merge head and gate

Four branches, each one commit on 39bdb614, merged into one head and gated once there.
Raw logs: audit-raw, `scratch/overnight-2026-09-05/logs/gates-0910/merged-trunk-1016/`.

## The head

| Commit | What |
|---|---|
| 9c44b205 | Merge branch 'feat/p4-journal-r5-tests' (0b95d0b8: more table-entry replay tests and journal mutants) |
| 000828f5 | Merge branch 'feat/p4-port-guard-offline' (56371d1b: the port-guard test runs offline) |
| 5948fb6b | Merge branch 'feat/p4-5tuple-mask' (34717da8: in_port masked to its 9-bit width and validated) |
| a0805b84 | Merge branch 'feat/p4-proxy-listen-local' (7e0a1dd5: the proxy listens on 127.0.0.1 unless NDTWIN_PROXY_HOST says otherwise) |
| cc0bca4b | p4_proxy: adapt the port-guard test to the proxy's listen address |

All four merges were clean; the fourth merge's tree equals the trial merge made before the gate
(a8114b55). For each of the 18 paths the merges changed, the merged blob equals the one branch tip
that changed it.

cc0bca4b exists because two branches that were green alone were not green together: the listen-local
branch prints `HTTP API listening on 127.0.0.1:8081`, and the port-guard test counted every
`127.0.0.1:<port>` in the proxy's output as a place the proxy dialled. The commit drops that line before
counting, keeps NDTWIN_PROXY_HOST out of the test's proxy, and adds an offline test of the rule.
- With NDTWIN_PROXY_HOST=not-an-address at a0805b84: 10 ran, 3 failed. At cc0bca4b, with and without the
  variable: 11 ran, OK.
- The new offline test fails when the filter line is deleted.

## The gate (all at cc0bca4b; every step rc 0)

| Step | Result |
|---|---|
| mutate_table_journal | 198 mutations, 0 survived |
| mutate_table_entry | 84, 0 survived |
| mutate_table_entry_owner / p4_rule_install_time / rule_journal_is_wired | 27 / 27 / 14, 0 survived |
| mutate_roles_binding | 194, 0 survived |
| mutate_app_package / telemetry_by_name / p4_priority_refusal / p4_probe / p4_exercise_tools | 48 / 23 / 9 / 6 / 37, 0 survived |
| mutate_stack_telemetry_identity | 4 mutations, 0 survived; 1 control, 0 went red |
| mutate_l1_shell_scoring | 62 killed, 0 survived |
| check_gate_anchors | 137/137 cells ok |
| p4lane / klane | FAILURES=0 / FAILURES=0 |
| no stray table-entry journal | 2135 tests in one process and 52 files one by one; the checkout's journal unchanged |
| journal tests seen red | 224 of 224 |
| test_ndt_app_package / test_l1_shell_scoring | 408 checks / 165 checks, 0 failed |
| p4_health cells and collect, Python 3.12 and 3.8 | 203 / 192 OK each |
| S0 and the replay trial | COMPLETE / ALL CHECKS PASS |
| p4_health mutation gate, four shards | `GATE: 517 mutations, 0 survived, shards 4/4 ok, commit cc0bca4b, tree fd872b3d` |

tools/p4_health at cc0bca4b is tree fd872b3d, the same tree the 10-15 gate ran.

Every step held a lock shared with the other work running on the machine that night. Each step also
checked that nothing was listening on :8081 before it started.

[Co-developed with claude code -- Adam]
