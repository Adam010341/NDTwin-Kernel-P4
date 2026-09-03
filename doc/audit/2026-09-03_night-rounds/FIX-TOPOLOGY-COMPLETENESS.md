# The topology round now reads the status line

[Co-developed with claude code -- Adam]

Fixes round 6's N1 and N2 (`round6-bug-shapes/14_SUMMARY.log`, arms in `11_`, `12_`, `09_`, `10_`).
Branch `fix/topology-round-reads-status`. Not pushed.

## What was wrong

`TopologyAndFlowMonitor.cpp:588-590` tested `!body.empty()` and nothing else, so the round's
completeness check could not see an error response at all. Measured last night, each arm held for
at least three poll intervals:

| `/v1.0/topology/links` answered | old verdict | new verdict |
|---|---|---|
| HTTP 500 + `{"error": ...}` | Complete | Partial, `reported_failure` |
| 200 + a JSON object, not an array | Complete | Partial, `wrong_shape` |
| 200 + `<html>not json</html>` | Complete | Partial, `unparseable` |
| 200 + empty body | Partial (the only one that worked) | Partial, `no_response` |
| 200 + `[]` or a populated array | Complete | Complete, `ok` |

The status was not merely ignored, it was *unreachable*: `utils::execCommand` is a popen() that
returns stdout and discards the exit status. `curl -sS` alone makes a 500 and a 200 the same
object. So the missing `if` could not have been written without first changing the wire format.

## What changed

1. **The wire.** `buildTopologyFetchCommand` appends
   `--write-out '\n@@ndt-topology-http-status@@%{http_code}'`. `--write-out` prints to the same
   stdout the body does, which is the one channel that survives popen. `%{http_code}` is `000`
   when curl never got a status line, which is the same fault the empty body already caught, so
   the two agree instead of competing.
2. **The rule.** New pure static `classifyEndpointReply`: splits from the *right* on the marker,
   then judges status → emptiness → parses → is an array. Five outcomes, spelled with the
   flow-table path's own vocabulary (`StaleTableCarryForward.hpp`): `ok`, `no_response`,
   `reported_failure`, `unparseable`, plus one new token `wrong_shape` added to **both** paths.
   🔴 `[]` is still an answer — an OVS fabric serves it on all three endpoints until LLDP
   finishes, which is every boot.
3. **The round.** `classifyPollRound` counts *reads*, not bodies. `Complete` now means all three
   endpoints were read.
4. **What gets applied.** An unreadable reply reaches the writers as `""` — the "did not answer"
   path they already had. Before this a 500's error body was handed to `updateLinks` and iterated:
   the only trace the whole failure left in the log was 16 lines of *"ignoring a links entry with
   no src/dst endpoint"*, which reads as a malformed fabric rather than a failed read.
5. **The channels.** The partial-round line now names each failed role with its reason and status,
   and `/ndt/get_graph_data` carries a new top-level `topology_round`:
   `{"kind":"partial","complete":false,"endpoints":{"links":{"outcome":"reported_failure",
   "http_status":500},...}}`. Additive: `GRAPH_DATA` is a non-strict `Obj`
   (`tools/contract_test/spec.py:235`, `schema.py:138`), the same additive rule the flow-table path
   used for `stale_since` / `stale_polls` / `last_error`. Read *before* the nodes and edges, so the
   verdict can never describe a fresher round than the graph beneath it.
6. **N2.** `classifyFlowStatsReply` gains `NotUnderstood`, placed after the entry scan and before
   the latency rule — which is the only place it can go, because a value that is not a list has no
   entries to find, so the scan passed over it and being *fast* then made it `Usable`. The switch
   is now carried forward marked `last_error=wrong_shape`, like its two neighbours.
   `{"3": []}` is untouched: that is a switch honestly reporting no rules.

## Publish-with-a-flag, not keep-the-snapshot

The flow-table path keeps the previous snapshot. This one should not, and the difference is not
taste:

- **The failure modes are mirror images.** There, the fresh array *replaces* the cache wholesale,
  so omitting a switch is a positive false claim — "this switch has zero rules" — which is exactly
  what blanked every flow's path on 2026-08-07. Here, all three writers are **monotone-up**: they
  set `isUp`/`isEnabled` true and never false, and never remove a vertex or an edge. A partial
  round therefore cannot manufacture a "down"; it can only fail to lift one. Dropping the half that
  answered would convert a partial answer into no answer — a move in the *pessimistic* direction,
  which is the direction of the bug A-2 exists for (40 links down, 10 switches disabled, fabric
  forwarding at 0% loss).
- **The observed wedge makes it concrete.** `get_link` is the blocking one, so the live shape is
  `/links` wedged with `/switches` healthy. All-or-nothing means the twin never learns any switch
  came back.
- **There is no snapshot to keep.** `updateSwitches` has already mutated the shared graph under
  `m_graphMutex` before `updateLinks` runs. Real atomicity means a shadow graph swapped across a
  mutex shared with the liveness worker and the REST layer: a design change, not this fix.

One principle underneath both: **never assert what you did not read.** There that means keeping the
old rows; here it means not applying the unread endpoint and saying so in every channel. The
loud-lie risk is the healthy round being called partial — which is why the `[]` case and a
populated 200 are both in the gate.

## Gate

Four cases plus the healthy one, in `tests/test_TopologyPollRound.cpp`
(`TopologyRoundReadsStatus.*`). Every arm asserts both the classification **and** the round verdict
+ the API object, because "nothing in the log and nothing in the API" was the actual defect.
Everything that existed before this change used an empty body, i.e. the one case that already
worked — a gate built only from those would have passed at 05:58 last night.

**Injection verified before the reaction, on the real wire.** `fake_southbound.py` was driven
through all five modes; an *independent* probe (`curl -o /dev/null -w '%{http_code}'` plus a body
read) confirmed each degradation took effect, and only then was the exact command the code builds
run against it. Transcript: `topology-status-wire.log` beside this file. This is what closes the
gap the unit tests cannot: that `--write-out` really does deliver the status through
`utils::execCommand`.

### Result

Seen failing first, then green. Built into `build-topocheck` only (`-j2` under the shared lock);
the `test_routing_strategy` binary was linked by hand from the existing objects because the shared
`tests/CMakeLists.txt` names `test_TelemetryHealth.cpp`, whose implementation a killed agent never
committed -- that file, and not this change, is what stops the CMake target from building.

    19/19 green in TopologyRoundReadsStatus + TopologyPollRound + TopologyPollRoundWiring
    879/881 green over the whole suite; the two failures are PowerManagerShutdownDeathTest,
      another session's uncommitted B-5 work, red before this change too.

    6 mutations, 0 survived
      M1 status check removed (the original `!body.empty()` behaviour) -> 2 tests red
      M2 wrong-shape body accepted                                     -> 2 tests red
      M3 unparseable body accepted                                     -> 2 tests red
      M4 classifyPollRound always Complete                             -> 9 tests red
      M5 classifyPollRound never Complete (the loud lie)               -> 18 tests red
      M6 --write-out dropped from the fetch command                    -> 1 test red

M5 is the one that matters for the snapshot-vs-flag argument: it is the failure mode a
too-strict fix would ship, and the gate refuses it as loudly as it refuses M1.

## What this commit leaves behind

Every source file this change touches also held **other sessions' uncommitted hunks** in the shared
worktree, so a whole-file commit would have swept three other agents' work into a commit whose
message does not describe it. This commit was assembled in a private worktree from **hunk-filtered
patches**, keeping only the hunks listed below and dropping the rest:

| file | hunks kept | hunks dropped, and whose |
|---|---|---|
| `src/ndt_core/http/HttpSession.cpp` | 1 of 3 | the `/ndt/get_sflow_stats` route (`:301`) and `handleGetAvgLinkUsage` / `handleGetSflowStats` (`:2201`) -- the killed telemetry agent's, rescued by the auditor onto `fix/telemetry-health-visible` (`c7f78c58`) |
| `include/ndt_core/collection/TopologyAndFlowMonitor.hpp` | 7 of 9 | `isStaticTopologyLoaded` / `configureTopologyApiUrls` -- D15's, on `fix/d15-dataplane-kind-race` (`75c2b526`) |
| `src/ndt_core/collection/TopologyAndFlowMonitor.cpp` | 11 of 13 | same, D15's |
| `include/…/DeviceConfigurationAndPowerManager.hpp` | 1 of 3 | `refreshDataPlaneKind` / the `DataPlaneKind` cache -- D15's |
| `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp` | 3 of 5 | same, D15's |

`tests/test_TopologyPollRound.cpp`, `StaleTableCarryForward.hpp` and these two doc files were clean
and are committed whole. Verified after filtering: `git diff trunk --stat` lists only these nine
files, and none of `isStaticTopologyLoaded`, `configureTopologyApiUrls`, `refreshDataPlaneKind`,
`getPowerStrategyForDpid`, `DataPlaneKind` or `get_sflow_stats` appears anywhere in the committed
**source** -- the only mentions are in the table above.
