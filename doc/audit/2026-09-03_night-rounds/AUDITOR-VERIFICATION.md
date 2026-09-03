# Auditor verification of the morning fix branches

2026-09-03, 10:30–10:50. [Co-developed with claude code -- Adam]

Each fix agent reported its own gate. This file records what the **auditor re-ran
independently**, in a throwaway worktree of the branch, without the agent present. An agent's
own "0 survived" is a claim; the rows below are observations.

Method for every row: `git worktree add --detach <scratch> <branch>` (the shared worktree's
HEAD is never moved), run the gate there, read the exit code, keep the named-test detail.

| Branch | Re-run | Observed |
|---|---|---|
| `fix/deterministic-path-tiebreak` (`966734be`) | `tests/shell/mutate_path_determinism.sh` | baseline 10 tests green; **5 mutations, 0 survived**, exit 0; each mutant reddened *the test the script names* (M1→`test_every_host_pair_is_insertion_order_independent`, M2→`test_topology_manager_all_pairs_is_stable`, M3→`test_no_switch_on_a_shortest_path_is_left_dark`, M4→`test_advertised_hops_match_each_switch_own_next_hop`, M5→`test_same_answer_under_different_hash_seeds`); baseline byte-identical afterwards |
| `fix/ports-that-block-restart` (`62a3aea8`) | `tests/shell/mutate_ports_that_block_restart.sh` | baseline 18 checks, 0 failed; **9 mutations, 0 survived**; `ports.sh` and `ndt` byte-identical afterwards |
| `fix/topology-load-fails-before-listen` (`896f6674`) | `tests/python/test_make_topology.py`, plus the generator both ways | 29 tests OK as a script and under `unittest` discovery; `--hosts 300` → rc=1 naming the 254-address ceiling; control `--hosts 8` → rc=0, still emits a full model |
| `fix/p4-priority-not-silently-dropped` (`9d64a36a`) | `tests/shell/mutate_p4_priority_refusal.sh` | **7 mutations, 0 survived**, exit 0; each caught by the test the script names, including the four that must NOT fire (the kernel's priority-less delete, `makeModifyJob`'s absent-priority 0, the -1 non-strict sentinel, a five-tuple match); `api_routes.py` byte-identical afterwards |

## What this does NOT establish

- **The tie-break is not confirmed live.** No fabric was brought up; the eight-bring-up
  reproduction that produced the defect has not been re-run against the fix. The gate proves
  the selector is a pure function of the topology, not that a real bring-up now agrees.
- **`fix/topology-load-fails-before-listen` has an unbuilt C++ half.** `src/main.cpp` and
  `TopologyAndFlowMonitor.{hpp,cpp}` on that branch have never been compiled. The ordering
  claim ("no port is bound when the load fails") has no test, because the test needs the
  binary. Treat the C++ half as a design, not a delivery.
- **No branch in this batch was confirmed against a live fabric.** Every gate above is offline:
  unit level for the Python, script level for the shell. The lab ran test rounds all night, so
  none of these fixes has met real traffic.

## Defect found while verifying

`tests/shell/mutate_ports_that_block_restart.sh` and `tests/shell/test_ports_that_block_restart.sh`
are committed mode `100644`. Invoking them the way every other gate in `tests/shell/` is invoked
fails with `Permission denied`; they only run via an explicit `bash`. `mutate_path_determinism.sh`
on the sibling branch is `100755`. Fix with `git update-index --chmod=+x` before merging.
