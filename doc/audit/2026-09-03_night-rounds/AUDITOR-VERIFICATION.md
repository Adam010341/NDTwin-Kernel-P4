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

---

## The two branches whose gates had never been run (11:00-11:30)

Both were built by the auditor in a throwaway worktree, `-j2`, in their own systemd unit.
**Both results contradict the branch author's prediction**, which is the whole reason for
building them.

### `fix/d15-dataplane-kind-race` — compiles, gate **3 of 4**

Build: clean, 98 targets, zero `FAILED:` lines. The author predicted 4/4 PASS.

```
[  PASSED  ] 3 tests.
[  FAILED  ] DataPlaneKindOrderingTest.TheStartupSequenceMainUsesYieldsABmv2Verdict
tests/test_DataPlaneKindOrdering.cpp:202: Value of: m_manager->dataPlaneKindDetermined()
  Actual: false   Expected: true
```

**Diagnosis, verified first-hand** (a Muse Spark agent reached the same conclusion
independently; these are the lines I read myself):

- `src/main.cpp:409` `topologyAndFlowMonitor->start();` … `:432`
  `deviceConfigurationAndPowerManager->start();`
- `DeviceConfigurationAndPowerManager.cpp:165` — `start()` calls `refreshDataPlaneKind()`
- the failing test calls **only** `startMonitor()` (fixture: `m_monitor->start()`), then asserts.
  It never calls `m_manager->start()` — the step in main's sequence that computes the verdict.

⇒ **The fix is not what failed.** The test's *second* assertion, `dataPlaneIsBmv2()`, passed in
the same run — the lazy re-derive works. Only the passive getter is false, and the design says
that is legitimate ("not yet known" ≠ "not bmv2"). The sibling test that passes,
`AVerdictTakenBeforeTheTopologyExistsIsNotCached`, differs only in **assertion order**: it calls
`dataPlaneIsBmv2()` first, which triggers the re-derive.

🔴 **And the repair is coupled to another branch.** Making the test do what its name says means
calling `m_manager->start()`. On this branch that spawns **three** threads
(`m_pingThread`, `m_statusUpdateThread`, `m_openflowTablesUpdateThread`) while `stop()` joins
**two** — the B-5 defect, still present here; `fix/b5-kernel-shutdown` is the branch that adds the
third join. A test that starts the manager would therefore `std::terminate` on teardown.
⇒ **D15's gate cannot be closed on D15's own branch. B-5 has to land first.**

I did **not** edit the test to make it pass. A test edited until it is green proves nothing.

### `fix/telemetry-health-visible` — **did not compile**

```
tests/test_TelemetryHealth.cpp:19:19: error: 'FlowLinkUsageCollector' does not name a type
```

Cause: the class is declared inside `namespace sflow`
(`include/ndt_core/collection/FlowLinkUsageCollector.hpp:30`), and every sibling test that
compiles qualifies it (`test_SFlowParsing.cpp:140`). The rescued file did not.
Two-line qualification applied by the auditor (`b7aad224`), then rebuilt: **it compiles, and the
gate is 17 of 18.**

```
TelemetryHealth.AppDropsAloneMoveTheVerdict
  classifyIngestHealth(true, 900, 0, 100, 1.0)  ->  loss 100/1000 = exactly 0.10
  expected "severe_loss", got "lossy"
```

Bands are `kIngestLossyFraction = 0.01` / `kIngestSevereLossFraction = 0.10`
(`FlowLinkUsageCollector.hpp:373,375`), applied strictly (`lossFraction > …`, `.cpp:1780`).
The failing case is the **only** one that lands on the edge — `TheBandsAreOrderedAndDistinct`
probes 0.5%, 5%, 50%. ⇒ **no green test constrains the boundary**, and `>` → `>=` would break
nothing currently passing. The test's own comment predicted the shape — "an unexercised path is
where a wrong constant survives" — without knowing it had caught itself, because it was never run.
Not decided here: it is a published `status` value, so it belongs to whoever owns the branch.

This is the same file that broke another agent's build in the shared tree at 84/86 and forced it
to hand-link its gate binary. One uncompiled file cost two other rounds real time.
