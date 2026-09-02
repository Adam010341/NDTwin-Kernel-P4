# Round 1 (night) -- the OVS plane, closed out. SUMMARY.

[Co-developed with claude code -- Adam]

**Binary of record: `ae8b752f8d6d693317c0ea3f9a230e7d0f0c5616acb6e4f5191417e2858feb4a`**, read from
`/proc/<kernel pid>/exe`. NOT the CHECKPOINT's `a8ba99c2` -- a concurrent session replaced
`build/bin/ndtwin_kernel` at 23:35:33, 26 s after I sampled it and 5 min before my fabric came up
(`15_binary_swapped_midround.log`). It carries an **unmerged B-5 shutdown fix**. Nothing in this
round measures shutdown/exit-status/thread teardown, so no finding here sits on top of that fix;
per-finding judgement is in FINDINGS.md. Repo HEAD moved `81d49d73 -> dbe07a8c -> fbe4dd8f` during
the round, with up to 36 uncommitted files from other sessions.

Deviation from CHECKPOINT (e): it says log to `.../2026-09-02_live-round/raw/` as `E6...`; the
persona brief says this directory. The persona brief won.

## A. Confirmed defects, with recipes

**D1. `ndt up ovs4` does not roll back a failed bring-up.** HIGH.
`02_ndt_up_failure_leaves_fabric_running.log`. The `:8000`-already-held check lives in stack.sh
phase [3/3], *after* Ryu, the tmux topo session and a 15-process / 36-veth data plane are built.
On failure all of it is left running with no kernel. Contrast: `stack.sh up ovs` refuses up front
when a Mininet is live (`27_...log`, rc=1).
*Recipe:* hold `:8000` with any listener, `ndt up ovs4`, then `ps`/`ss`.

**D2 + D3. `ndt status --check` is unusable on the OVS plane, and has zero discriminative power there.** HIGH.
`05_...log`, `07_t2_status_check_false_red_on_ovs.log`. On a provably healthy ovs4 fabric it
returns rc=1 "the kernel graph does not match the topology file", and the `configuration` block
reports `hosts 128` and the **P4** 128-host file. Both come from `p4_proxy/mininet/host_count_override`
(`ndt:420,508,606`), a P4-only knob that `ndt up ovs4` never writes (`ndt:849,865`). Worse: the
check compares only (hosts, edges), and `P4_10Switches_4Hosts.json` and `OVS_10Switches_4Hosts.json`
are **both (4, 40)** -- so with the override at 4 it goes GREEN while comparing an OVS fabric
against a P4 file.

**D4. `ndt up ovs4` configures no sFlow on any bridge.** HIGH. `11_`, `12_`.
`sflow` is `[]` on all ten bridges, 0 sflow records in the OVS DB, while the kernel listens on
:6343. Every rate and utilisation on **that fabric** is structurally zero and
`/ndt/get_average_link_usage` still answers `{"avg_link_usage":0.0,"status":"success"}`.
*Control:* 3000 packets / 0% loss / 33.5 s h1->h2; before and after are identical zeros.
*Scope (narrowed after cross-check):* the **4-host `ovs4`** fabric only. `ndt:813-819` shows
`ovs4 -> ovs-topo-4host -> ovs_4host_topo.py` (**0** sFlow refs) while `ndt up ovs` (128) ->
`ovs-topo-start` -> NTG's `testbed_topo.py`, which defines `enable_sflow()` at :110 and **calls it
at :190**. 128-host OVS results are not impeached.
*Fix spec = that contrast.* Three independent instruments agree: `check_logs.py` (T-5),
`ndt check` (twin 0.0 vs /proc/net/dev 9.2 Mbit/s, ratio 0.00), chaos INV-04 (wire 480 B/s, twin 0).
*Downstream:* it blocks R-5 F-1 (`18_`), makes R-2 untestable (`32_`), and feeds the Energy app a
fabricated-zero utilisation (`31_`).

**D5. `/ndt/delete_group_entry` is a silent no-op.** HIGH.
`21_delete_group_meter_says_deleted_but_persists.log`. Returns `200 {"outcome":"deleted"}`; the
group is still on the switch indefinitely (`duration_sec` keeps rising). Groups leak permanently --
re-installing the id returns 409 "already exists". The kernel log says nothing: 5
`handleDeleteGroupEntry` invocations, 0 delete-failure lines.
*Two positive controls, same run:* `delete_meter_entry` really does delete (`[88,555]->[88]`), and
Ryu's own `/stats/groupentry/delete` really does remove group 77. Read-back channel is Ryu
throughout, never the API that wrote it. **Reproduced 4x** (gids 555, 601, 602, 603).

**D6. X-5 / B-1's OVS half is RED -- the phantom window exists.** HIGH.
`22_x5_b1_phantom_window_ovs.log`. The kernel serves the REQUEST-SHAPE cache row at t=0.257 s and
holds it ~1.0 s; the real polled-shape row arrives at t=13.4 s. Identical recipe on P4 (C22):
`first_sighting=never`. Probe resolution 0.25 s vs a ~1.0 s window, so "too slow to see it" is
excluded. Side observation: OVS **accepted** `OUTPUT:999`, a port that does not exist.

**D7. `ndt check` -- the telemetry double-count tripwire -- cannot trip.** MEDIUM. `26_`.
It correctly diagnosed ratio 0.00 "under-counting" and named the interfaces, then exited **0**.
`cmd_check()` is a pure reporter with no return path; all three verdicts exit 0.

**D8. `ndt clean` / `down --deep` never check `:6653` / `:6633`.** HIGH. `34_`.
`grep -c '6653\|6633' tools/test_workflow/ndt` = **0**; the sweep is `ndt:1112 for p in 8000 8080 8081`.
So `CLEAN_RC=0` cannot tell you Ryu is gone, and a next fabric can silently attach to a previous
round's controller (`ovs_4host_topo.py:31-34`: an unspecified port "silently masks a controller
that is not up yet").

**D9. chaos.py INV-01 false-fails on every OVS run.** MEDIUM. `33_`, `chaos_null.json`.
In a null round it reports "graph claims 10 switches up, only 0 BMv2 processes exist". BMv2 is the
P4 data plane; 0 is correct on OVS. It drags `false_positive_floor` to 1. Its bmv2 provenance scan
separately reported `running: {"/bin/bash": 1}`.

**D10. Reporting asymmetry for unreachable switches.** LOW-MED. `23_`, `37_`.
Unreadable-but-present -> served with `stale_since/stale_polls/last_error`. Powered-OFF -> silently
dropped from the response (10 -> 9), no markers at all.

**D11. `/ndt/modify_nickname` rewrites the tracked topology JSON in full.** MEDIUM. `39_`.
One nickname write produced a **1772-line diff (886+/886-) that is semantically identical to HEAD**
-- the kernel re-serialises the file at 2-space indent instead of 4 and flips the top-level key
order. In a worktree shared by several sessions this is a generator of exactly the "diff suddenly
ballooned" hazard CLAUDE.md warns about. I caused it and restored it by explicit single-file path.

## B. Fixes verified GOOD (doors closed)

- **X-11 / R-5, the whole reason this round existed** (`16_t6_x11_50_r5_ovs.log`, first ever run of
  `50_r5_ovs.sh`, 9 checks 0 FAIL): **F-5 STILL PRESENT** (kernel asserted a rule Ryu never had,
  peaked 1 ended 0; object-shaped actions = it is echoing the POST body) and **F-5b STILL PRESENT**
  (0 dispatch-failure lines over 835 log lines while the P4 arm logs it). **The F-5b differential is
  now closed** -- it is a whole finding, not half. F-1 unreachable *because of D4* (`18_`); F-2/F-3
  unreachable (no switch went down).
- **X-9 / F-6 endpoint half: PASS** (`37_`, `x9_table_response.json`) -- 10/10 switches carry
  `stale_since=1788366888, stale_polls=2, last_error='no_response'`. The CHECKPOINT said these
  fields appeared in no captured response anywhere.
- **X-10 / F-13: PASS**, matrix closed (`20_`) -- all six endpoints return **200** on OVS (correct
  inversion of P4's 501); the "already exists" arm returns **409** with a precise body.
- **X-6 / B-2b: PASS** (`24_`) -- a quote round-trips intact; four shell-metacharacter payloads
  stored verbatim, canary never created, no component accused, state restored.
- **X-7 / B-4: PASS** (`25_`) -- captured on the wire at a stand-in simulator: 162 bytes with all
  three apostrophes intact. (Minor: the kernel double-encodes the simulator's JSON into a string.)
- **X-3 / T-9: PASS** (`06_`) -- `/proc/<ryu>/cmdline` shows the vendored
  `tools/ryu_apps/rest_topology_bounded.py` by absolute path; `ryu.app.ofctl_rest` is loaded by
  dotted name in the same argv, which is the contrast that makes the distinction real.
- **X-2 / T-7: CONFIRMED** (`36_`) -- the `--max-time 5` arm reached for the first time:
  one edge-triggered WARN `after 12.033s` with `curl: (28) Operation timed out after 5002 ms`.
  Caveats kept: predicted ~15 s vs measured 12.033 s, unattributed; and my curl-child witness was
  broken (curl is a grandchild via `sh`).
- **X-4 / T-8: PASS on the current `ndt`** (`30_`) -- re-run was *required*, because
  `tools/test_workflow/ndt` is now `617b5540`, not the `67412ba4` the 08-31 pass measured. All four
  interfaces correct; the pre-fix control (`c10ac7c`, wiring-checked first) reproduced the old bug.
- **T-22: PASS** (`35_`) -- with `graph_energy_before.json` present it correctly did nothing
  ("recorded as powered off: none") instead of rebuilding a healthy fabric.
- Also PASS: T-3 (40/40, rc=0), T-4 (rc=0), T-13 (`stack.sh` all arms, correct rcs 2/0/1/0/0),
  T-14 (`PASS: P4 matches the OVS baseline`), T-16 (L-3, injection asserted, qdiscs restored),
  T-18 (14 checks 0 FAIL), T-20 (7 checks 0 FAIL, and it closed the **live** half of
  `assert_window_span`), T-21 (480 samples, 0 overruns).

## C. Refuted -- hypotheses of mine that died, which is worth as much

- **`50_r5_ovs.sh`'s "ovs-ofctl unusable" was CORRECT**, not a weak instrument (`17_`): sudoers
  grants NOPASSWD only for ovs-vsctl / ifconfig / mnexec / ndtwin-lab / ndtwin-p4-power. F-5 really
  did rest on 2 sources. My own `ovs-ofctl dump-ports` in log 12 had silently failed for the same
  reason -- annotated in place.
- **`compare_baseline.py` was not producing a false FAIL** (`27_`): I passed baseline/candidate
  backwards. In the documented order it PASSES. (It does label positionally with no content check --
  a usability hazard, logged as such.)
- **My own X-9 verdict was wrong** (`23_` corrected by `37_`): I concluded "not implemented on the
  endpoint" from a powered-off switch, which is the wrong trigger. My own later experiment refuted it.
- **My "ndt check exits 0" and several rc claims were initially `head`'s exit code** (`27_`) -- the
  pipeline-tail mistake `50_r5_ovs.sh`'s own header (H-21) warns about. All re-captured without pipes.
- **The controller-continuity worry: my chain is intact** (`34_`). Despite D8, the Ryu the failed
  bring-up left (pid 992388) was provably gone before the retry -- process scan empty AND my own
  listener check, which *did* include 6633/6653, printed "(all free)". The Ryu serving my fabric is
  pid 1006083, started 23:40:32, inside the retry window. **No post-log-04 conclusion needs a
  "surviving controller" caveat.**

## D. Not done, and why

| id | why |
|---|---|
| **T-19** `20_apps_lifecycle.sh` | Deferred on memory. It starts the viz JavaFX JVM while another session ran 2x cc1plus (943+475 MB); free RAM sat at 1.2-3.1 GB against the coordinator's 3 GB floor, and Adam's Chrome already hit ENOMEM at 23:33. `19_free_mem_checkpoints.log`. Blocks `analyse_app_te_log.py` (needs a te crash-loop log). |
| **T-15** `p4_power_helper.py` powering a switch | P4 plane only. |
| **T-17** `faults.sh N-4` | One `ovs-vswitchd` serves all 10 bridges; SIGSTOP would freeze the entire fabric, and it is the host daemon the CHECKPOINT says to leave alone. Needs P4. |
| **T-23** injection arms | `chaos.py --controls/--full` REFUSE to inject: the claim does not declare `exclusive_cpu=yes`. Correct behaviour. **Human decision.** `--null` did run live. |
| R-5 F-2 / F-3 OVS arms | Need a degraded fabric; the Energy app powered nothing off (see below). |

## E. Open questions for a human

1. **The Energy-Saving-App powered nothing off in 4 cycles on ovs4, though its own decision chain
   predicts it should** (util 0.0% vs `LOW_WATER_MARK` 0.40). `31_`. The harness refuses to
   explain it away. Entangled with D4: the 0.0% input is itself fabricated. Not separated.
2. **`chaos.py` injection needs `exclusive_cpu=yes`** on the lab claim. I did not alter a claim
   shared with later rounds.
3. **`build/bin/ndtwin_kernel` changed under a claimed lab mid-measurement.** The claim protocol
   does not cover builds, and `a8ba99c2` is no longer recoverable from disk (the three archived
   copies are all the production `e3bad23c`; the b5 pair is archived separately).

## F. Updated T-list (T-1..T-23) -- verdict + evidence path

All paths relative to `doc/audit/2026-09-03_night-rounds/round1-ovs/`.

| id | verdict now | evidence |
|---|---|---|
| T-1 `ndt up ovs4` | **PASS** (2nd attempt; 1st failed on a port race and exposed D1) | `04_t1_ndt_up_ovs4_retry.log`; `01_`, `02_` |
| T-2 `ndt status --check` on OVS | **FAIL (instrument)** -- false red + wrong config + zero discrimination | `05_`, `07_` |
| T-3 `run_contract_test.py` L2 OVS | **PASS** 40/40, rc=0 | `08_`; 22 bodies in `contract_ovs/` |
| T-4 `l3_component_check.py` OVS | **PASS** rc=0, 7 components, same known `/ndt/disable_switch` gap; `--check-drift` false positive reproduces | `09_` |
| T-5 `check_logs.py` OVS +/- `--powered-off` | **PASS (instrument)**, rc=1 both arms. `--powered-off 9` is **inert on OVS**: "dpid(s) declared powered off produced no matching log line: [9]" | `10_` |
| T-6 `50_r5_ovs.sh` | **PASS (ran)**, first ever execution, 9 checks 0 FAIL -- see X-11 | `16_` |
| T-7 `rider_a2-max-time` | **PASS (ran)**, ran last, destroyed the control plane as designed | `36_` |
| T-8 orphan-stop rider | **PASS** on `ndt` 617b5540 (08-31's pass had expired) | `30_` |
| T-9 vendored Ryu app loaded | **PASS**, from argv | `06_` |
| T-10 `ndt apps orphans` | **PASS** (clean: rc=0; and rc=1 correctly under T-8) | `26_`, `30_` |
| T-11 `ndt ntg` | **PASS**; note it edits a **sibling repo's** config -- restored | `26_` |
| T-12 `ndt check` | **RAN, and is a MEDIUM defect**: diagnoses correctly, always exits 0 | `26_` |
| T-13 `stack.sh` direct | **PASS**, rcs 2 / 0 / 1 / 0 / 0; refuses to clobber a live Mininet | `27_` |
| T-14 `compare_baseline.py` | **PASS** in the documented arg order | `27_` |
| T-15 `p4_power_helper.py` | **NOT RUN** -- P4 plane only | -- |
| T-16 `faults.sh L-3` | **PASS**, injection asserted, qdiscs restored | `28_` |
| T-17 `faults.sh N-4` | **BLOCKED on this plane** -- one `ovs-vswitchd` serves all 10 bridges | `28_` |
| T-18 `10_r1_endpoint_callers.sh` | **PASS (ran)** 14 checks 0 FAIL; R-1 correctly UNTESTABLE | `29_` |
| T-19 `20_apps_lifecycle.sh` | **NOT RUN** -- memory (viz JVM vs a live C++ build) | `19_` |
| T-20 `25_apps_energy.sh` | **PASS (ran)** 7 checks 0 FAIL; closed `assert_window_span` **live** | `31_` |
| T-21 `30_/35_ r2_r3` | **PASS (ran)** rc=0/0, 480 samples 0 overruns; R-2 untestable here | `32_` |
| T-22 `90_restore.sh` | **PASS** -- correctly restored nothing rather than rebuilding | `35_` |
| T-23 `chaos.py` live | **PARTIAL**: `--null` ran (rc=0, false-positive floor 1, INV-01 false-fails); `--controls`/`--full` **BLOCKED** on `exclusive_cpu` | `33_` |

## G. Updated X-list (X-1..X-12) -- verdict + evidence path

| id | fix | verdict now | evidence |
|---|---|---|---|
| X-1 | A-2 (a) `topology-round-partial` | **NOT OBSERVED.** T-7 produced a *fully* failed poll, not a half-answered round; the literal never appeared. The half-answer case was not constructed. | `36_` |
| X-2 | A-2 (b) `--max-time 5` | **CONFIRMED** -- 1 edge-triggered WARN `after 12.033s`, `curl: (28) ... after 5002 ms`. Caveats: predicted 15 s, measured 12.033 s (unattributed); curl-child witness broken | `36_` |
| X-3 | A-2 (c) vendored Ryu app | **PASS**, from `/proc/<pid>/cmdline` | `06_` |
| X-4 | A-1 orphan rider | **PASS** on current `ndt`, with a wiring-checked pre-fix control | `30_` |
| X-5 | B-1 OVS half | **RED -- the phantom window exists** (0.257 s -> ~1.0 s wide) | `22_` |
| X-6 | B-2b single quote | **PASS** -- round-trips intact, no shell, no component accused | `24_` |
| X-7 | B-4 sim case with a quote | **PASS** -- 162 bytes captured on the wire, apostrophes intact | `25_` |
| X-8 | A-4f OVS power-cycle half | **BLOCKED by D4.** No sFlow was ever configured, so no record can "come back". The power cycle itself works (Success both ways, 10->9->10); `telemetry_status` stayed `unknown` on 40/40 edges, which is D4's consequence, not an A-4f result | `23_`, `12_` |
| X-9 | F-6 endpoint half | **PASS** -- 10/10 switches carry `stale_since`/`stale_polls`/`last_error`. (My first verdict was wrong; corrected.) | `37_`, `x9_table_response.json`; `23_` corrected |
| X-10 | F-13 cells 7-12 + OVS | **PASS**, 12-cell matrix closed: 200 on OVS, 409 with a precise body for "already exists" | `20_` |
| X-11 | R-5 F-5b / F-5 / F-1 | **F-5 STILL PRESENT; F-5b STILL PRESENT and the differential is CLOSED; F-1 unreachable, blocked behind D4** | `16_`, `18_` |
| X-12 | B-5 kernel exit code | **NOT ATTEMPTED** here -- a sibling session ran the B-5 matrix on this machine tonight and the binary I measured already contains its unmerged fix | `15_` |
