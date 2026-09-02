# Round 4 (night) -- traffic and measurement. SUMMARY.

[Co-developed with claude code -- Adam]

**Binary of record: `a8ba99c25f0393159d5111815c406c7fe85ee1f2842c3cd390f05094417fdc06`**
(`sha256sum build/bin/ndtwin_kernel` at 02:57:48 before anything ran, `00_binary_and_env.log`), and
the running kernel's `/proc/1328839/exe` hashed to the same value (`03_fabric_verified.log`). Repo
HEAD at round start and end: **`1f06848f9a9b49d8a2f9ad97e553a6bbc04860b3`** ("Night round 3"), branch
`trunk`. Nothing built, nothing committed, nothing pushed.

Plane: **P4 / bmv2, 10 switches, 4 hosts** (`ndt up p4 4`). Chosen because round 1's D4 proved the
`ovs4` fabric configures no sFlow at all, so it structurally cannot answer a question about sampling.
Sampling is **1/256 Bernoulli** (`ndtwin_switch.p4:52,405` -- `random(...); if (== 0) clone`, so
inter-sample gaps are exponential, not a fixed stride).

🔴 Every per-flow bit/s below carries COMMON-BRIEF section 11's no-denominator bias. **Cited, not
re-derived.** It is optimistic, which matters in one place and is argued there (finding 3).

---

## 0. The two assigned leads, both settled

### Lead 4 -- three windows answer "how many flows". **SETTLED: CONFIRMED, and the boundary is measured.**

The three windows, read from source at 1f06848f (`01_three_windows_static.log`):
**2 s** per-edge `flowSet` TTL (`TopologyAndFlowMonitor.cpp:3496`, consumed by
`/ndt/get_num_of_flows_passing_a_switch` at `HttpSession.cpp:2249`); **3 s** `kFlowActiveWindowMs`
(`FlowLinkUsageCollector.hpp:78`) as the API **default**, because `HttpSession.hpp:63` sets
`kFlowDataApiDefault = ActiveOnly`; **15 s** `FLOW_IDLE_TIMEOUT` (`.hpp:35`), reachable only with
`?liveness=all`/`retained`.

Sweep A: **one** flow, count held at 1, payload held at 1400 B, only the offered rate moving. 10 cells,
each with a quiet cell taken immediately before it, 30 one-second polls each. **iperf3 reported 0%
loss on the wire in every single cell** -- the flow was really there, every time.

| offered | pps | samples/s | A: 2 s edge | B: **3 s, the API DEFAULT** | C: 15 s `?liveness=all` |
|---|---|---|---|---|---|
| 20 Mbit/s | 1786 | 18.5 | 30/30 | 30/30 | 30/30 |
| 5 Mbit/s | 446 | 4.71 | 30/30 | 30/30 | 30/30 |
| **2 Mbit/s** | 179 | 1.78 | **21/30 = 0.70** | 30/30 | 30/30 |
| 1 Mbit/s | 89 | 1.00 | 17/30 = 0.57 | 26/30 = 0.87 | 30/30 |
| 500 kbit/s | 45 | 0.38 | 11/30 = 0.37 | 21/30 = 0.70 | 30/30 |
| **250 kbit/s** | 22 | 0.17 | 6/30 = 0.20 | **16/30 = 0.53** | 30/30 |
| 125 kbit/s | 11 | 0.14 | 4/30 = 0.13 | 12/30 = 0.40 | 30/30 |
| 60 kbit/s | 5 | 0.10 | 2/30 | 9/30 = 0.30 | **28/30 = 0.93** |
| 30 kbit/s | 3 | <0.1 | 0/30 | 3/30 | 13/30 |
| 15 kbit/s | 1 | <0.1 | 2/30 | 3/30 | 20/30 |

**Where the disagreement starts and stops** (1400 B frames, 3 sampling hops, 1/256):
- **>= 5 Mbit/s (>=446 pps): all three agree, 30/30.**
- **2 Mbit/s (179 pps): it STARTS** -- the 2 s edge count falls to 0.70 while the other two are 1.00.
- **250 kbit/s (22 pps): the API DEFAULT crosses 50%.** A flow sending continuously and delivered
  with zero loss is missing from `/ndt/get_detected_flow_data` in half of all one-second polls,
  while `?liveness=all` still returns it 30/30.
- 125 kbit/s (11 pps): the widest gap -- default 0.40, edge 0.13, table 1.00.
- 60 kbit/s (5 pps): the 15 s table begins to fail too.
- **<= 30 kbit/s (<=3 pps): it STOPS**, by all three converging on "absent". (r30k/r15k differ in the
  wrong direction; at ~0.02 samples/s that is Poisson noise on 30 polls, not a reversal.)

**Sweep B is the mechanism, and it changes how the boundary must be quoted.** Offered bit rate held
at 1 Mbit/s, flow count held at 1, only the frame shrinking:

| payload | packets sent | samples/s | 2 s edge | 3 s default |
|---|---|---|---|---|
| 1400 B | 4 465 | 1.07 | 0.70 | 0.97 |
| 600 B | 10 417 | 2.21 | 0.93 | 1.00 |
| 250 B | 25 000 | 5.22 | 0.97 | 1.00 |
| 100 B | 62 499 | 12.4 | 1.00 | 1.00 |

Identical bandwidth, identical 0% loss, visibility moving from 0.70 to 1.00 on frame size alone.
**The boundary is in packets per second, not bit/s**: ~22 pps for the default's 50% point, ~89 pps
for the edge count's, and it shifts by up to 14x with a workload's frame size. Quoting the band in
Mbit/s without the frame size is not transferable. (Sweep B's 1400 B cell also reproduces sweep A's
1 Mbit/s cell 15 minutes later: 21/30 vs 17/30 and 29/30 vs 26/30.)

*Controls:* 12 quiet cells, one immediately before each load cell, same command, no traffic -- **0/8
on all three windows in 12 of 12**. A decoy flow key (10.0.0.3 -> 10.0.0.4, never sent) read absent in
**456 of 456** polls while the real flow read present. Forced-green at 20 Mbit/s: 30/30 everywhere.
Per-cell predictions from a written model were pre-registered in `05_` **before** those cells ran.

### Lead 5 -- sFlow drops, the four counters, and whether any API can see them. **SETTLED, in three parts.**

**(a) Samples ARE lost, and the boundary is measured** (`09_lead5_drop_ladder.log`). Offered load
built by the repository's own producer (`p4_proxy/proxy_agent/sflow_emitter.build_datagram`), so the
datagram shape is the one the kernel parses; the sender's own count is ground truth; the forced-green
cell (20 datagrams/s) proved they are accepted -- the synthetic flow appears in the table.

| offered | sent | lost | fraction |
|---|---|---|---|
| 2 000/s | 20 000 | 0 | 0% |
| 20 000/s | 200 000 | 0 | 0% |
| 60 000/s | 600 000 | 0 | 0% |
| **150 000/s** | 1 500 000 | 5 145 | **0.34%** |
| **654 709/s** | 6 548 000 | 4 745 333 | **72.5%** |

Confirmed through a second channel that is not the collector: the `drops` column for the `:6343`
socket in `/proc/net/udp` moved 0 -> 5 145 -> 4 750 478, matching the kernel's own
`sock_ovfl_total` of 5 145 and 4 747 168.

**(b) There is no API path to any of it. CONFIRMED** (`08_lead5_no_api_path.log`). 15 GETs, 3 POSTs
and 11 probes at the usual metrics paths; **105 distinct JSON keys** across every body the kernel
returns. The only key matching any loss word is `dropped_after_stop`, which belongs to the **flow
dispatcher**, not the collector. `/metrics`, `/stats`, `/health`, `/healthz`, `/ndt/metrics`,
`/ndt/stats`, `/ndt/get_sflow_stats`, `/ndt/get_collector_stats`, `/ndt/get_telemetry_status`,
`/sflow/stats`, `/ndt/get_drop_counters`: all **404**. The nearest thing that exists is per-edge
`last_sample_age_seconds` / `telemetry_status`, which says how old the newest sample is and never how
many were lost. The single reader of the four counters is a log line
(`FlowLinkUsageCollector.cpp:2130-2170`); `rx` has **no steady-state channel at all**, because the
INFO at `:2163` fires once per process (`announcedHealthy`) and everything after it is TRACE.

**(c) The specific mechanism in the lead -- round-robin app-level drop -- did NOT fire. NOT-OBSERVED,
and the code path is unreachable in practice.** `app_drop_total` stayed **0** through **9 548 120**
offered datagrams across steps 09, 11 and 13, including 6 548 000 at 654 709/s. Structural reason:
`SO_RCVBUF` is 4 MB (`.cpp:665`), which at ~768 B skb truesize per 224 B datagram holds ~5 000
datagrams, while the worker queues hold `20 x 4096 = 81 920` (`main.cpp:418`) -- **16x more**, so the
socket must overflow first. Step 13 tested the other direction too: at a fixed 60 000/s (a rate that
loses nothing), raising the work per sample from 1 to **5 000 distinct flow keys** -- the flow table
really did go 1 -> 5000 -> 1 -- cost +15.7% kernel CPU and still produced **zero** drops, flanked by
1-key control arms either side. So the observed loss is **indiscriminate socket-level loss, not one
worker in twenty**; the structural claim about `rr % numWorkers` and the non-requeueing `tryPush`
(the blocking `push` is commented out at `.cpp:112-126`) stands as a code fact only.

---

## 1. The round's theme: does measurement break under load? **YES, silently.**

`11_theme_under_report_under_load.log`. Three cells, the **same** real traffic in all three
(iperf3 UDP 20 Mbit/s, 1400 B, h1->h2, 55 s, flow count 1). The only thing that changed is the load
offered to the collector's socket. A and C are controls taken 1 and 2 minutes either side of B with
the identical command. All three wire ground truths are byte-identical: `131 MBytes 20.0 Mbit/s
0/98213 (0%)`.

| cell | sFlow flood | twin's reported rate for that flow (median of 30 polls) | error |
|---|---|---|---|
| A control before | none | 19 688 106 bit/s | -1.6% |
| **B** | **541 547 datagrams/s** | **7 136 938 bit/s** | **-64.3% (2.76x under-report)** |
| C control after | none | 20 672 512 bit/s | +3.4% |

**And while that was true:** every endpoint answered HTTP 200 `"status":"success"` in under 5 ms --
*faster* than in the control cell; the flow read `active` **30/30 in all three windows in all three
cells**, so a liveness consumer saw nothing move; and `avg_link_usage` went **the wrong way**,
0.0103 -> 0.0221 -> 0.0133, because the flood's samples were credited to a real edge. The only trace
anywhere is 33 WARN lines in `kernel.log` (0 in A, 33 in B, 0 in C) -- and by (b) above, no API
carries that fact.

**Why it is loss and not CPU starvation:** the known no-denominator bias grows *with* the drain
period, so a starved kernel would over-report. The number fell 64%. The surviving fraction 0.357 sits
inside the 0.28-0.36 that step 09's ladder predicts at this offered rate. The bias also explains A and
C reading 19.7 M and 20.7 M against a true 20.0 M -- and it makes B's under-report a **lower bound**.

---

## 2. Other confirmed findings

**R1. Rule churn: the dispatch counters can be made to disagree with the switch by an unbounded
factor.** MEDIUM-HIGH. `12_churn_counters_vs_switch.log`. 20 installs at 19.3/s, all HTTP 200,
`dispatched +20 succeeded +20 failed 0` in **both** arms. Distinct matches -> the switch gains **20**
rows (ratio 1.00, the control that proves the counter *can* agree). One repeated match -> the switch
gains **1** (ratio **20.00**). Nothing in the body, the counters or `recent_failures` separates an add
from a replace, so from outside the switch you cannot derive how many rules exist, and the gap equals
the number of replaces. Switch read through the proxy's `GET :8081/stats/flow/1` (P4Runtime
`read_table_entries`, a different process), never the API that wrote the entries. Cleanup verified
back to the 4-row baseline. *(bmv2's own thrift CLI is currently unusable on this machine -- the p4dev
venv has no `thrift` module and `find / -name Thrift.py` returns nothing.)*

**R2. A delete of a rule that does not exist is counted as a success.** MEDIUM. `12_`. 15
`delete_flow_entry` POSTs for `ipv4_dst 10.0.0.250`, never installed: all 200, `dispatched +15,
succeeded +15, failed 0`, switch rows unchanged at 4.

**R3. The collector accepts sFlow from any source and never looks at who sent it.** MEDIUM.
`01_`, `09_`, `11_`. It binds `INADDR_ANY:6343` (`.cpp:683-686`), and the source address is written
into `msg_hdr.msg_name` at `:766` and **read at no other line in the file** (`grep srcAddrs` returns
exactly two hits, both writes). Attribution comes from the agent address *inside* the datagram, which
the sender chooses. Demonstrated live: datagrams from an ordinary local process claiming to be
`192.168.123.11` port 1->2 raised that edge's published utilisation while the edge carried nothing
extra (`11_`, the 0.0103 -> 0.0221 move).

**R4. `rx` is unobservable in steady state.** MEDIUM. `01_`, kernel.log line 67. The one INFO
`sFlow ingest healthy: rx=10, app_drop=0, addressed=10, sock_ovfl_total=0` at 03:03:16 is the only
one the process will ever emit; the rest is TRACE, and the WARN only fires on a non-zero drop delta.
So "no WARN" and "we received nothing" are indistinguishable to anyone outside the process -- the same
shape as the `no sFlow datagram has arrived in 60s` warning that the code already, correctly, added.

**Observation (not filed as a defect): the API publishes IPs byte-reversed.** `10.0.0.1` comes back as
`src_ip: 16777226` (`0x0100000A`), not `167772161`. Verified against a live row before any cell ran;
every parser in this round uses `struct.unpack("<I", inet_aton(...))`. Worth a line in the API doc.

---

## 3. Refuted / not observed -- doors closed

- **"One slow worker discards a fixed fraction of all traffic."** NOT OBSERVED in 9 548 120 offered
  datagrams, by two different routes (more packets, and 5 000x more work per packet), with a
  structural reason why it is 16x further away than the socket-level path. See lead 5 (c).
- **"Collector overload makes a real flow disappear from the API."** NOT OBSERVED. Under a 72%-loss
  flood the 20 Mbit/s flow stayed `active` 30/30 in all three windows -- because uniform loss on
  18.5 samples/s still leaves ~5/s, which clears the 3 s window. The harm is to the **value**, not to
  the presence. Reporting the presence claim would have been wrong.
- **"`avg_link_usage` falls under sample loss."** REFUTED for this setup: it *rose*, 2x, because the
  offered load was itself attributable telemetry (R3). Loss and fabrication push it opposite ways and
  this experiment cannot separate them; the per-flow rate can, and does.
- **My own first probe read IPs in network byte order** and found nothing; corrected before any cell
  ran, not after. **My first sweep launch used `setsid ... &`** and detached, so a 20 Mbit/s flow
  overlapped the first cell -- caught by `ps`, that cell was discarded and re-run, and a stray-iperf3
  guard plus a pre-cell flow-table check were added to the driver. Both recorded, not deleted.

---

## 4. Not done, and why

| id | why |
|---|---|
| The OVS-plane arms of everything here | Round 1 D4: `ovs4` configures no sFlow, so it cannot answer any of this. The 128-host `ovs` fabric does (`testbed_topo.py:190`) but bringing one up was not affordable inside this round. |
| Multi-flow arms (does the band move with flow count?) | The design rule forbids moving flow count and per-flow rate together, and there was time for two clean one-variable sweeps, not four. The model says the per-flow band does not move with flow count; that is unverified. |
| `viz` process chain | `viz` was never started this round (round 3 already captured it -- V1). |
| Pushing to app-level drop with a deliberately stalled worker | Would need a code change or a debugger attach; out of scope for a measurement round. |

---

## 5. For a human to decide

1. **The API default's 50% point is ~22 packets/s per flow.** Anything slower than that is invisible
   to `/ndt/get_detected_flow_data` half the time, while `?liveness=all` shows it. Both answers are
   defensible; publishing them without saying which window produced them is not. The doc should state
   the window **in packets**, because that is the unit the mechanism uses.
2. **Sample loss is invisible to every consumer of the API.** The counters exist, are correct, and are
   printed to a log nobody reads. A `telemetry_health` field on the responses whose numbers the loss
   degrades -- or one endpoint carrying the four counters -- would close it. This is the cheapest fix
   with the largest effect on whether high-traffic numbers can be trusted.
3. **Whether high-traffic numbers can be trusted at all:** on THIS fabric, yes -- bmv2 at 1/256 emits
   ~18 samples/s at 20 Mbit/s and the first loss appeared at 150 000/s, four orders of magnitude away.
   The exposure is not the data plane; it is that **anything on the machine or the network can reach
   `:6343`** (R3) and both starve and poison the collector, and no endpoint would show it.
4. **`succeeded` in `/ndt/get_flow_dispatch_status` counts accepted operations, including no-ops.**
   It is not a rule count and it is not evidence a rule changed. Either rename it or add the switch's
   own count beside it.

---

## 6. Lab state at end of round

`14_teardown.log`. Verified through channels other than `ndt down`'s own claim: the four pids
captured before teardown (kernel 1328839, proxy 1328635, bmv2 1328263, my iperf3 server 1331560) are
each gone by `ps` on the exact pid; **0** `ndtwin_kernel`, **0** `simple_switch`, **0** `java`, **0**
`iperf3`, **0** `ryu-manager` by `ps -eo comm=` (never `pgrep -f`); **0** processes tagged
`mininet:*`; and all 28 of 8000 / 8080 / 8081 / 9000 / **6653** / **6633** / **6343** / 30050-30060 /
9091-9100 free, with no socket bound to 6343 in `/proc/net/udp` at all. The port check was taken
**40 s** after the kernel pid disappeared, comfortably past round 3's measured 2.0-2.2 s window in
which a dead kernel's orphaned `curl`/`sh` still hold `:8000` and `:6343`. 1837 MB free, 7707 MB
available. No apps were ever started this round.

Aside worth one line for whoever writes the next harness: **the iperf3 server this round started
inside h2 (`sudo -n mnexec -a <h2> iperf3 -s -D`) is root-owned, so an unprivileged `kill` is
refused** ("Operation not permitted") and it survived SIGTERM from the user who launched it. It was
stopped by exact pid through the same allowed path (`sudo -n mnexec -a <h2 ns pid> kill -KILL <pid>`)
while h2's namespace still existed. Anything that starts a server that way and tears the fabric down
first has no channel left to stop it.

**Tracked files:** exactly one was changed, and not by hand -- `ndt up p4 4` rewrote
`p4_proxy/mininet/host_count_override` 128 -> 4. Restored to 128 by explicit single-file path
(`git checkout -- p4_proxy/mininet/host_count_override`), never a directory pathspec; `git status`
for that path is now empty. Everything else in `git status` belongs to other sessions. This round's
own files are all untracked, under `doc/audit/2026-09-03_night-rounds/round4-traffic-measurement/`.
**Nothing committed, nothing pushed.** Claim `auditor` **kept** -- 231 min left at 03:44.

**HEAD moved under me**, as it did for rounds 1 and 3: `1f06848f` at round start ->
`7e2c4135` ("KNOWN-ISSUES G-10, and pin down what A-8's machine was actually running") at round end,
another session's commit. **The binary did not move**: `sha256sum build/bin/ndtwin_kernel` read
`a8ba99c2...` before the first cell and again after teardown, and the running kernel's
`/proc/1328839/exe` hashed to the same value. Every number in this round is attributable to that
binary, which predates both commits.
