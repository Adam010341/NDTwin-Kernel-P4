# L0–L4 on the fast bmv2: zero failures attributable to the binary; the ladder's reds were ours

[Co-developed with claude code -- Adam]

Run 2026-08-21 night at `32ff719`+. Raw outputs `l0_l4_run.txt` (first full ladder),
`l2_l4_corrected.txt` (contract layers rerun with the harness invocation fixed),
`p4_client_live.log` (the opt-in live-switch write test). Driver scripts alongside.

B2 ③'s criterion, written on the 8/20 slide: **"L0–L4 整套在 fast build 上通過."** Upstream
warns the fast flag set "cannot be used to achieve passing results on all p4c tests," so the
run is the evidence, not a formality.

## Verdict

**Not a clean ladder pass — but every red traces to something other than the fast binary,
each dispatched below, and the binary's own evidence is uniformly green.** The honest
statement for the slide is: *the fast build introduced zero new failures anywhere in L0–L4;
the ladder's residual reds are pre-existing plane gaps and harness defects, itemised.* A
stock-binary control ladder would formalise "zero new" and was not run tonight.

## Layer by layer

| layer | first run | after attribution |
|---|---|---|
| L0 build | **PASS** (all 10 targets, incl. the P4 pipeline) | — |
| L1 units | FAIL, 5 groups | **all 5 dispatched, 0 remain** (below) |
| L2/L3 contract (p4) | FAIL, 7 endpoints | **5 remain — all pre-existing P4-plane gaps** |
| log allowlist | FAIL | startup-only lines; not binary-related |
| L4 differential | FAIL, 48 diffs | **4 remain, all one endpoint, direction favours P4** |

### The five L1 groups

1–2. `test_readopt`, `test_bmv2_binary_override` — broken by the same-day JSON-wiring commit:
`p4_testbed_topo.py` imports its sibling `topo_from_json` bare, which resolves as a script
but not under the tests' spec-loader. **Fixed** (sys.path guard in `p4_testbed_topo.py`);
both files green under the venv afterwards.

3–4. `test_find_host_by_ip` (added tonight), `test_walk_instrumentation` (red in this lane
since the day it was added) — module-level networkx imports in the kernel-side lane that
runs plain python3. **Fixed twice over**: skip guards in both files (graceful under a bare
interpreter), and the lane now picks a networkx-carrying interpreter the same way the P4
section picks its protobuf one — so the suites actually *run* in L1 rather than skip, which
is what the harness's own "a skipped test is not a passing test" rule demands.

5. `test_slim_client_json.sh` — **mis-attributed in this report's first revision**, which
named `test_p4_client` here from its SKIPPED line without checking it against the failure
counter (the opt-in skip has a non-counting branch; the review session re-ran the ladder and
caught it). The real fifth group: this shell test, added the previous day, ends with
"passed 12, failed 0" while the lane's parser greps for "Ran N" — so it read as
NO TESTS RAN from the day it was born, with all 12 checks passing inside its log. **Fixed**:
it now emits the same "Ran N checks" summary as `test_faults.sh`.

Separately, `test_p4_client` (all-skipped by its three-layer opt-in design, not counted as
a group) was **run tonight against the live fast bmv2** with all three gates satisfied:
pipeline config pushed, clone session 250→255 installed, routes written — `Ran 1 ... OK`,
exit 0 (`p4_client_live.log`). The most direct fast-binary evidence in the ladder: real
P4Runtime writes, accepted.

After the fixes the lane reads **L1: 0 problem groups**.

### The harness's own two bugs (first run's L2/L3/L4 noise)

* `TOPO_P4` was left at its 4-host default while the fabric ran 128 hosts — every
  graph-shape check compared a *correct* 128-host answer against the wrong declared file.
* `--traffic` was passed with no generator running, on both planes — every flow-presence
  check failed by construction.

The corrected rerun (`l2_l4_corrected.txt`) flips `get_graph_data` and
`get_detected_flow_data` to PASS and collapses L4 from 48 unexpected diffs to 4.

### What genuinely remains

* **L2, P4 plane (5 endpoints)**: `/stats/flow` still the `[]` stub
  (`get_switch_openflow_table_entries`), `get_power_report` empty,
  `get_cpu_utilization`/`get_memory_utilization`/`get_temperature` null. All pre-existing
  P4-plane gaps of the documented fabricated/absent-telemetry family; none involve the
  data-plane binary.
* **L4 (4 diffs, one endpoint)**: `get_path_switch_count` returns real data on P4
  (`src_ip`/`dst_ip`/`switch_count`) and an error shape on OVS (its own L2 run 404s it).
  The asymmetry points at the OVS/kernel side, not P4 — allowlist-with-reason or fix the
  OVS side; either way not a fast-build defect.

## Also banked

* First-ever L4 OVS reference captured on this machine (`.test_run/baseline/ovs`), taken at
  `NDTWIN_RYU_SETTLE_S=60` and verified healthy — 288 edges, 0 down, 128 hosts with IPs.
  The evidence is a direct count of the banked `get_graph_data.json` (done independently by
  this session and the review session): the run log's own "links 0 total, 0 down" line was
  the driver reading a `links` key on a graph whose key is `edges` — a vacuous check on an
  empty default that looks clean. The driver is fixed and now warns on zero edges instead
  of reading it as health. The baseline itself was never wrong; the check was.
* Earlier tonight the entire beacon sweep (four P4 fabric boots, ~50 minutes of runtime,
  detection and forwarding all nominal) ran on this same fast binary — corroborating live
  mileage beyond the ladder.

## What would close B2 ③ fully

1. A stock-binary control ladder (same invocation) to formalise "zero new failures".
2. The five P4-plane contract gaps either fixed or allowlisted with reasons.
3. A traffic-loaded run of the contract layers (tonight's were idle by harness necessity).
