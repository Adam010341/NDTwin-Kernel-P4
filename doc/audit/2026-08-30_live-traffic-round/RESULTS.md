# Live-traffic round (full-stack #3) — results

**2026-08-30, 20:23 – 23:10 CST.** Six arms, all on kernel `1208d22`:

| arm | fabric | why it ran |
|---|---|---|
| **1** | P4 / BMv2, **128 hosts** | the registered working point (PREREG §1) |
| **2** | OVS / Ryu, **128 hosts** | TR-2 / F-1 is only reachable there |
| **3** | P4 / BMv2, **4 hosts** | TR-1's timing half is structurally unmeasurable at 128 — see below |
| **4** | P4 / BMv2, 4 hosts | the programmed-vs-visible check that corrected FINDING-06 |
| **5** | P4 / BMv2, 4 hosts | TR-5 energy watch (Adam authorised the power-off verb at 22:24) |
| **6** | OVS / Ryu, 4 hosts | TR-5's second arm |

Unless a section says otherwise, figures below are arm 1.
Registered by [PREREG.md](PREREG.md) (`5cbd672`) before any data. Executed by
`live-traffic-round`, dispatched by `8/29 auditor`.

[Co-developed with claude code -- Adam]

---

## Provenance — what was measured

| | |
|---|---|
| kernel source | `1208d22` (a **source** identifier, not a build id); worktree clean of tracked changes |
| kernel binary | `build/bin/ndtwin_kernel`, sha256 `66f437a56dd09a91311b7acf18b59ae07ff86e0e1e7f3bcfccd7724c69be0e42` |
| how identified | rebuilt from `1208d22` at 12:25:34Z; the rebuild reproduced the existing binary **byte for byte** |
| bmv2 | `/usr/local/bmv2-fast/bin/simple_switch_grpc` (the performance build), confirmed by `ndt` as the running binary |
| topology | `setting/StaticNetworkTopologyP4_10Switches_128Hosts.json`, `host_count_override` = 128 |
| PREREG registered | `faffdbe` — **not** what was measured. Recorded here rather than by editing the PREREG. |

🔑 Three source files had **mtimes newer than the binary**, which reads as "possibly stale". They
were not: `git diff HEAD` on them is empty and a full rebuild produced an identical binary. Their
mtimes came from the branch-surgery re-checkout. `memory: benchmark-must-name-the-binary-it-measured`
— mtime does not even give a lower bound. Details and my own false alarm in `raw/arm1-p4-128/build_arm1.log`.

## Traffic actually applied, measured through the datapath (PREREG §2)

Read from `tx_bytes`/`rx_bytes` on each host's own `h<N>-eth1` **inside its namespace** — never
from iperf3's summary.

| | asked | offered | delivered | loss |
|---|---|---|---|---|
| 8 base pairs, all cross-quarter (s1↔s3, s1↔s4, s2↔s3, s2↔s4), 840 s | 10 Mbit/s | **10.29** | 9.83–10.28 | 0.1–4.4 % |
| 16 churn pairs, one new pair every 30 s, 90 s each | 5 Mbit/s | **5.15** | 4.71–4.90 | 4.7–8.4 % |

Peak concurrent offered ≈ **95 Mbit/s**. Single-pair calibration beforehand: **102 Mbit/s offered,
102 delivered**, essentially lossless. All 16 churn pairs started; every pair was
never-before-used, so each is a genuine new-flow event.

## Verdicts

| | registered question | verdict |
|---|---|---|
| **TR-1** | R-2 with discriminating power | **gate HELD** (both arms); timing untestable at 128 hosts, **answered at 4** — [TR1-timing-4host.md](TR1-timing-4host.md) |
| **TR-2** | F-1 on OVS | arm 2 **ran**. Punt path **bypassed** (proactive routing), instrument-blindness **refuted**. F-1 stays *unreachable*, **not** *passed*. |
| **TR-3** | does the exposure window grow under contention? | **NO.** And 🔴 **corrected**: it is a *view-staleness* window (the rule is on the switch in ~20 ms), not an unprogrammed one. [FINDING-06](FINDING-06_dispatch-is-a-10.7s-cycle-not-a-queue.md) |
| **TR-4** | `contract_test` against the live kernel | **PASS, 39/39** (+ 52-check self-test) |
| **TR-5** | energy observation base | **COLLECTED, both arms.** 0 switches off each; mechanism identified — [FINDING-08](FINDING-08_energy-app-locks-itself-out.md) |
| **TR-6** | the manual's 128-host example | **PASS, works as printed** |

Plus three system findings that were not registered questions:
[FINDING-06](FINDING-06_dispatch-is-a-10.7s-cycle-not-a-queue.md) (the table view is blind for up to 10.7 s) and
[FINDING-07](FINDING-07_install-flow-entry-drops-the-priority.md) (priority rewritten to 0), and
[FINDING-08](FINDING-08_energy-app-locks-itself-out.md) (the Energy-App locks itself out).

---

### TR-1 — the gate held, and that is the round's main result

**The hard precondition holds.** `GET /ndt/get_detected_flow_data` returned `[]` on the idle
fabric and **8 → 12 flows** under traffic, tracking the churn as new pairs joined:

```
20:36:53 flows=8    h1_tx=127,255,892      20:37:45 flows=11   h1_tx=193,531,092
20:37:08 flows=9    h1_tx=146,238,492      20:38:00 flows=10   h1_tx=212,847,452
20:37:30 flows=9    h1_tx=174,478,462      20:38:15 flows=12   h1_tx=232,536,312
```

This settles the question PREREG §0 was written around. T-4's R-2 was unfalsifiable because
**1800/1800 samples had `flows` empty** — and that was the *quiet network*, not a broken
telemetry path. With traffic, the path is populated and changes. Over the 1020 s sampler run:
**13 flow keys observed, 12 of which changed at least once.**

**But the timing half is untestable at 128 hosts, and the reason is structural.** The sampler's
own health gate fired first — 833 samples, **50 % overruns** against a 5 % tolerance, effective
rate 0.818 Hz against a requested 2 Hz — so it declared section 2 unusable rather than printing
intervals anyway. Decomposing the cost per sample explains it exactly:

| endpoint | p50 | bytes |
|---|---|---|
| `get_detected_flow_data` | 1 ms | 2 |
| `get_graph_data` | 35 ms | 118 KB |
| **`/ryu_server/all_destination_paths`** | **699 ms** | **931 KB** |
| **one sample = all three** | **735 ms** → max **1.36 Hz** | |

And the sampler *correctly refuses* `--interval 1.0`: "cannot resolve a 1 Hz recompute or a 1 s
consumer cadence. Use 0.5 or less." So at 128 hosts the two requirements are **mutually
unsatisfiable**: R-2 needs ≤ 500 ms sampling and the endpoints cost 735 ms.

🔑 This is not a failure of effort and it should not be retried by sampling harder. It is
`memory: instrument-must-not-mimic-its-own-finding` in its plainest form — *the ladder is shorter
than the thing it measures*. R-2's timing question is answerable at 4 hosts (16 256 destination
paths become 12) and **not** at 128 with this method. Recorded for the next round rather than
worked around.

*Not established:* whether any consumer actually polls `all_destination_paths` at 1 Hz. `viz` and
`te` poll at 1 Hz (`NetworkTopologyApp.java:424`, `Traffic-engineering-App.py:41`) but which
endpoint each one hits was not read this round, so "the apps cannot meet their cadence at 128
hosts" is **not** claimed.

### TR-4 — 39/39, live

Discharges the one verification `T-7b` could not run (its §0.0). The self-test passed 52 checks
first, each demonstrated in **both** directions (accepts the valid case, catches the injected
bad one), so a live pass is not a pass from a blind instrument.

All lock endpoints pass live: `acquire_lock` 200, `acquire_lock_conflict` **423**, `renew_lock`
200, `release_lock` 200, `acquire_lock_after_release` 200, `release_lock_not_held` **412**,
`acquire_lock_invalid_type` **400**. The 412 is inside the known `[412, 400, 404]` tolerance —
noted, not re-litigated, per PREREG §3.

### TR-6 — the manual's 128-host example works as printed

The live half is this whole round: `ndt up p4 128` built the fabric in **133 s** (10 switches in
36 s, 16 256 destination paths converged in 53 s), `ndt` reported *"model matches fabric: 128
hosts (kernel graph, topology file and 128 host namespaces all agree)"*, and 24 host pairs
carried traffic across switch boundaries. No timing is offered as a performance claim (PREREG §5).

The manual's Step 6.5 also makes a **protective** claim — *"It cross-checks these two and refuses
to start if they disagree"* — so it was force-tested in both directions against
`p4_testbed_topo._topology_model_path`:

| | result |
|---|---|
| positive control: matched inputs | resolves to the 128-host model — so a refusal below is a refusal, not a broken function |
| 4-host model + count 128 | **refused** (`TopologyModelError`) — the exact 2026-08-21 defect the code comment says was fixed |
| 128-host model + count 4 | **refused** — the guard works in the direction nobody wrote it for, too |

*Interpreter note:* this needs `/usr/bin/python3`. The default `python3` here is conda's and has
no `mininet`; and only `p4_proxy/mininet` may go on `sys.path` — adding `p4_proxy` makes
`import mininet.net` resolve to the repo directory and the module cannot load at all. Both traps
were hit before the test ran. `memory: python-tests-need-the-venv-interpreter`.

### TR-5 — collected on both arms, and it did not reproduce FINDING-05

Adam authorised the power-off verb at 22:24; the watch ran on P4 4-host and OVS 4-host under a
fresh claim with zero in-window commits and no `agy`. **Both arms powered off 0 switches** at
0.0 % link utilisation — where the contaminated 15:30 P4 run powered off three.

The cause is identified from the app's own output rather than left open: `acquire_lock` returns
**423 once per second**, the loop at `energy_saving_app.cpp:952` retries and never runs a switch
cycle, and the holder is the app's own first instance — whose two `release_lock()` calls both sit
behind a simulation round-trip that cannot complete with no Simulation-Platform-Manager running.
The lock's 300 s TTL outlasts the 241 s watch, and it **survives the process**.

Consequence for this round's own instrument: the watch's "4 full 60 s app cycles" is wall clock,
not decisions. **Only one cycle ever decided anything, so PREREG §3 TR-5's "≥2 decision cycles
per arm" was not met on either arm** — and the script reported it as met.

**Do not close FINDING-05 on this.** Two variables changed at once (kernel `89c1754`→`1208d22`,
and `agy` removed). Full reasoning, the refuted "the old lock always granted" hypothesis, and the
one cheap arm that would settle it: [FINDING-08](FINDING-08_energy-app-locks-itself-out.md).

### TR-2 — arm 2 **did** run; F-1 is unreachable **by churn**, and now we know why

TR-2 registered a break condition: *"new pairs pass traffic with no punt-path evidence anywhere —
meaning the punt path is bypassed or the instrument cannot see it; the two are distinguished
before scoring."* Both branches were tested. **It is bypassed.**

OVS/Ryu arm, 128 hosts, 10 switches, 32 links, up in 52 s. Two traffic blocks (300 s and 150 s),
**21 new never-before-used pairs**. Result: `edge not found` in `kernel.log` = **0**, throughout.

| branch | evidence |
|---|---|
| **(a) punt path bypassed** — SUPPORTED | Ryu installs paths **proactively**: bring-up logs `switches=10 links=32 paths=installed` before the kernel starts. Read back through Ryu: every switch carries **128 destination routes** (1280 across the fabric) *before any traffic*. **A new src→dst pair cannot miss a table it is already in**, so churn cannot manufacture a table-miss. |
| **(b) instrument blind** — REFUTED | The punt rules are visible **and carrying traffic**: per switch, `{dl_dst: 01:80:c2:00:00:0e, dl_type: 35020}` (LLDP) with 671 packets, and a genuine table-miss rule `priority=0, match={}` with 648 packets / 63 663 B over 594 s. 20 punt rules across 10 switches. The reader sees the punt path when it is used. |

Two further controls, so "0" is a measured zero:

* **The kernel was ingesting flows while this was measured.** `get_detected_flow_data` returned
  **8–13 flows** continuously through a traffic block, so the path walk that emits the message
  (`FlowLinkUsageCollector.cpp:2898`) had flows to walk. Zero `edge not found` across all of it.
* **The pattern can match.** `lib.sh`'s registry self-tests `kernel_reserved_port_out` against a
  real sample and a near-miss before every script runs.

🔑 **PREREG §2's premise does not hold, and running it is how that was found.** The pre-registration
says churn *"is what gives F-1 its table-miss events"*. Table misses require **reactive**
forwarding; this controller is **proactive**. No amount of churn produces one. That is a
correction to the registered design, not a result about F-1.

**F-1's verdict stays `unreachable`, not `fixed`.** Its specific mechanism needs a flow whose
*output port* is `OFPP_CONTROLLER` (4294967293) to enter the collector's path walk. The punt rules
exist in the tables the kernel polls, but whether the collector ever walks one was **not**
established. Calling it fixed on this evidence would be scoring an untested branch as a pass.

*Also observed, worth one line:* on OVS, offered and delivered matched to two decimal places on
every pair (**~0 % loss**), against **0.1–8.4 %** on the P4/BMv2 arm. That is a ratio, so it
survives the divisor problem noted below. The OVS arm's absolute **rate** column is **unusable** —
two traffic blocks were run against a single pre/post ledger pair, so the per-pair divisor is
wrong. Stated rather than quietly dropped.

### Arm 3 — a 4-host P4 fabric, to answer what 128 hosts made unmeasurable

Because TR-1's timing question turned out to be structurally unanswerable at 128 hosts (above), a
third arm was run at the size where it *is* answerable. Endpoint cost per sample:

| | 128 hosts | 4 hosts |
|---|---|---|
| `all_destination_paths` | 699 ms / 931 KB (16 256 paths) | **1 ms / 742 B** (12 paths) |
| one full sample | **735 ms** | **~4 ms** |

184× cheaper, so a 0.5 s ladder is finally much shorter than the 1 Hz phenomenon it measures.
Result in [TR1-timing-4host.md](TR1-timing-4host.md).

---

## Preconditions: one was not met

`00_preflight.sh` returned **21 checks, 1 FAIL** — a qemu process, against PREREG §4.3's "no VM
anywhere in the window". It is **Claude Desktop's own `claude-cowork-vm`** (2 vCPU, ~3.3 % of one
core), not the installation-manual VM, which is stopped and snapshotted as its handoff said.
The round proceeded with the covariate declared, and the gate's wording is itself recorded as a
harness ticket: it attributes any qemu to "the installation-manual VM", which `comm` cannot
support. Full reasoning, measured sizes and the narrower gate:
[COVARIATES-and-preflight-override.md](COVARIATES-and-preflight-override.md).

Everything the claim *can* enforce was clean: `exclusive_cpu=yes` and holding (load1 1.07 / 14
cores), `measuring nothing`, ports 8000/8080/8081/9000 free, no stale manifest, **zero in-window
`git commit`s repo-wide**.

## Instrument defects found in this round's own harness

Five, all mine, all found before they reached a verdict — which is the expected yield on a
first live run (`memory: new-tools-are-the-first-thing-under-test`).

1. `hcounter` read `h<N>-eth0`; the interface is `-eth1`. Would have made every datapath counter
   unreadable. Caught by an abort, not by a zero.
2. `local tag=… f="…$tag…"` — one `local` statement, dies under `set -u`.
3. The ledger divided every pair by the ledger window instead of the pair's own on-air time,
   understating each churn pair 11× (0.45 vs 5.15 Mbit/s) at a value that looked plausible.
4. `entries_of()` returned the top-level list — ten `{dpid,flows}` wrappers, none carrying a
   `priority` — so it found nothing and said so confidently. **Caught only by the control asking
   "and can you see a *real* rule?"**
5. `scan()` keyed on `priority`, the one field the system rewrites → the false
   "never programmed" conclusion. See FINDING-07.

And one wrong verdict on correct data: the spread-based discriminator in `tr3_simultaneity.py`
(FINDING-06, last section).

## Artefacts

`raw/arm1-p4-128/` — `r2_samples.jsonl.gz` (56 MB, full response bodies, 833 samples),
`tr3_*.tsv/.jsonl`, `tr4_contract_test.log`, `tr1_analysis.log`, `tr1_endpoint_cost.txt`,
`tr6_manual_128host.txt`, `ledger/{pre,post}.tsv`, `traffic_pairs.tsv`, `binary-provenance.txt`,
`build_arm1.log`, `verdicts.jsonl`.
Harness: `harness/` — `round.env`, `traffic_mesh.sh`, `tr3_f5_window.py`,
`tr3_simultaneity.py`, `tr3_grid_analyse.py`. The T-4 harness is **reused, not copied**.
