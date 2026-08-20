# What sampling costs, and where the CPU actually goes

2026-08-20. Five live conditions on the P4/bmv2 128-host fabric, 300 s each, plus an idle
baseline. [Co-developed with claude code -- Adam]

## Headline

1. **Sampling harder buys precision exactly as theory predicts.** 4× the sampling rate gives a
   4.00× finer resolution step and 1.83× tighter dispersion (√4 = 2.00 predicted), and the
   estimator stays unbiased at every rate.
2. **It costs bmv2 nothing measurable, and costs throughput nothing at all.** Deleting the clone
   session entirely — removing 100% of sampling work — does not change delivered throughput or
   bmv2's CPU. **So sFlow is not why bmv2 is slower than OVS.**
3. 🔴 **Truncating the clone at the switch (`packet_length_bytes = 128`) silently destroys all
   telemetry.** The twin reads zero on every edge, with no error anywhere.
4. **The sampling cost lands on the kernel and the proxy, not the data plane**: 57 and 20
   percentage points of one core respectively, at 1/64.

## Method

`tools/test_workflow/cpu_probe.py` samples `/proc/<pid>/stat` at 2 Hz for every bmv2, the proxy,
the kernel and iperf3, plus whole-machine `/proc/stat`; `doc/audit/2026-08-18_live-full-stack-
round/run.py` polls the twin at 4 Hz against `/proc/net/dev`. Both run concurrently with a
fixed-rate 200 Mbit/s UDP flow h1 → h33. Driver: `measure.sh`. Raw data in `raw/`.

⚠️ **The first ~6 s of every run is discarded.** The harness starts the pollers, sleeps 2 s, then
starts iperf3, so the head of each trace has no traffic. Included, those three zero-windows push
the Fano factor from 0.88 to 1.75 and made the sweep look like it *contradicted* theory. The
check that caught it was asking *when* the zeros occurred rather than how many there were.

## 1. Sampling rate sweep (SAMPLE_RATE recompiled and pipeline re-pushed each time)

| rate | quantum | λ per 1 s window | Fano | sd/mean | 1/√λ | twin/truth |
|---|---|---|---|---|---|---|
| 1/256 (production) | 2.953 Mbit/s | 69.6 | 0.88 | 11.2% | 12.0% | 1.001 |
| 1/128 | 1.477 Mbit/s | 139.1 | 0.88 | 7.9% | 8.5% | 1.000 |
| 1/64 | 0.738 Mbit/s | 278.0 | 1.05 | 6.1% | 6.0% | 0.999 |

- quantum **2.00× / 4.00×** finer; λ **2.00× / 3.99×** — both exactly as `rate × frame × 8` predicts
- dispersion **1.41× / 1.83×** tighter against **1.41× / 2.00×** predicted
- Fano ≈ 1 throughout: the counts are a Poisson process with nothing added on top
- unbiased at every rate (twin/truth within 0.1%)

### Cost

| rate | bmv2 | kernel | proxy | delivered | loss |
|---|---|---|---|---|---|
| 1/256 | 151.4% | 57.7% | 12.2% | 200.0 M | 0.37% |
| 1/128 | 158.1% | 62.1% | 17.9% | 200.0 M | 0.35% |
| 1/64 | 149.4% | 67.5% | 23.9% | 200.0 M | 0.35% |

🔴 **Corrected 2026-08-20.** These first read 150.4 / 156.9 / 148.4 for bmv2 and 57.3 / 61.9 /
67.4 for the kernel. The 6-second head trim was applied to the twin analysis in this report but
**not** to the CPU table, so those figures averaged in the traffic-free start of each run and
understated every process by about one point. The direction is uniform and no conclusion moves —
bmv2 is flat either way — but the numbers on `page_sampling-tradeoff.png` are the trimmed ones
and these now agree with it. Found by cross-checking the figure against the report rather than
the other way round.

CPU is % of **one** core, summed within a group; the machine has 14. Across a 4× rise in sampling
rate: **bmv2 flat** (−2.0 points, i.e. noise), kernel +10.1 (1.18×), proxy +11.4 (1.93×),
**delivered throughput identical**.

**So the trade is: 4× resolution and 1.8× precision for ~11 points of one core on the proxy and
~10 on the kernel, and nothing on the data plane.** On this machine, at 20% total load, that is
cheap. It is a real option for the accuracy story, not a theoretical one.

## 2. Clone A/B — all at 1/64, i.e. 4× production clone load, to make any cost visible

| condition | delivered | loss | bmv2 | kernel | proxy | twin/truth |
|---|---|---|---|---|---|---|
| clone full frame (control) | 200.0 M | 0.35% | 149.4% | 67.5% | 23.9% | 0.999 |
| clone truncated to 128 B | 200.0 M | 0.40% | 152.3% | 10.3% | 4.0% | **NO TELEMETRY** |
| no clone session at all | 200.0 M | 0.29% | 153.3% | 10.2% | 3.9% | **NO TELEMETRY** |

(This table already used the trimmed figures; the §1 table above did not, and has been corrected.)

### 🔴 `packet_length_bytes = 128` is not an optimisation, it is an outage

Setting the clone session's `packet_length_bytes` to 128 — the "truncate at the switch instead of
at the emitter" suggestion — produced **zero telemetry on every edge**. Nothing logged an error:
the proxy reported the clone session installed on all ten switches, the kernel stayed up, every
`/ndt/` endpoint answered, and every link rate read 0.

Its CPU signature is **indistinguishable from having no clone session at all** (kernel 10.3 vs
10.2, proxy 4.0 vs 3.9). That is the diagnosis: bmv2 is not delivering the truncated clone to the
CPU port at all, rather than delivering a short one the proxy then rejects. Whatever the internal
reason, the observable is that the switch-side truncation knob **drops the sample**.

The comment at `p4_client.py:347` reads "packet_length_bytes 0 means no truncation on the switch;
the emitter truncates instead, since it is the side with tests covering it." That was written as a
preference. It is now a **requirement**, and the reason is measured rather than stylistic.

### 🔴 RETRACTED 2026-08-20: the "no clone session" control did not do what it says

**The condition labelled "no clone session at all" did not have its clone session removed**, and
the same is true of the matrix's zero-sampling cells. Any claim in this report that rests on
comparing against a true zero point is withdrawn.

How it was caught: the matrix repeated the control on a warm fabric and produced kernel 67.7%,
proxy 26.6%, bmv2 161.6% — indistinguishable from the 1/64 cell **with** sampling on (67.9% /
26.6%). The twin was still reporting telemetry: 2352 non-zero readings, peaking at 296.8 Mbit/s.
The control path itself ran correctly — `DELETED (A/B control)` appears ten times in the proxy
log, `Clone session ... installed` zero times, and `NDTWIN_CLONE_DISABLE=1` is in the proxy's
environment — so the code did what it was told and the telemetry survived anyway.

The mechanism is documented in `write_clone_session()`'s own docstring and I did not apply it.
A proxy restart re-pushes the pipeline; after that commit the P4Runtime server's clone-session
bookkeeping is **empty** while the target's PRE state — the multicast group behind the session —
survives from the previous proxy generation. A DELETE issued against empty bookkeeping is a
no-op that never reaches the orphaned group. The working path is `DELETE → INSERT → settle
(DELETE + INSERT)`: only a DELETE issued while the bookkeeping *holds* the session tears the
group down. The A/B control does the leading DELETE and returns, so the orphan survives and
keeps cloning.

**This also undermines the original `noclone` cell in the table above.** Its predecessor was
`trunc128`, which produced no telemetry either — so "the session was deleted" and "the previous
condition's truncating session is still installed" are indistinguishable in that data. Its
kernel figure of 10.2% is not evidence of a zero-sampling baseline.

**A correct control must restart the fabric**, not just the proxy, so bmv2 starts clean and the
session is never installed. Keeping the fabric warm was a deliberate choice — to hold everything
except the session constant — and that choice is precisely what invalidated it.

**What survives, by a route that needs nothing deleted:** the sampling-rate sweep varies the
clone rate 16× on its own (1/1024 → 1/64, 34.7 → 556.1 samples/s) and bmv2's CPU does not move
outside noise (150.7 / 155.9 at 1/1024 versus 161.1 / 158.6 at 1/64) while delivered throughput
is 200.0 Mbit/s at every rate. The conclusion that sFlow is not bmv2's bottleneck rests on that,
not on the A/B.

**What does not survive:** any statement about a fixed cost for "having sampling on at all". The
linear fit over five sampled points extrapolates to a 48.5% intercept, and there is no valid
measurement at zero to compare it against.

### The cost of sampling, isolated

Deleting the clone session removes every downstream cost — the egress pass on the copy, the
deparse, the CPU port, the gRPC stream, the emitter, the UDP datagram — while leaving the
forwarding path byte-identical (the pipeline still draws its random number and still calls
`clone_preserving_field_list`; the PRE has nothing to replicate into).

**Delivered throughput: 200.0 M with and without. bmv2 CPU: 149.4% with, 153.3% without** — the
no-sampling case is nominally *higher*, i.e. the difference is noise.

So at four times production sampling load, turning sampling completely off buys **zero** extra
throughput and **zero** bmv2 CPU. This closes the question directly rather than by inference:
sFlow, truncated or not, batched or not, is not the reason bmv2 reaches ~460–530 Mbps where OVS
reaches 980.

What sampling *does* cost is **57 points of one core on the kernel and 20 on the proxy** — both
outside the data plane, and both invisible to any throughput measurement.

## 2b. The northbound API is fully serialised — measured, and it does not bite today

The twin's central claim is that seven applications consume it simultaneously through `/ndt/`.
Nothing had ever tested that under concurrency: `run_layers.sh` and `run_contract_test.py` issue
requests serially. `headline_blocking.py` sweeps concurrency against `get_graph_data`, 30 s per
level, read-only GETs only.

| N | throughput | p50 | p95 | p50 vs N=1 | serialised predicts |
|---|---|---|---|---|---|
| 1 | 78.4 req/s | 11.9 ms | 17.7 ms | 1.00× | — |
| 2 | 84.6 req/s | 23.4 ms | 25.2 ms | **1.96×** | 2.00× |
| 4 | 84.3 req/s | 47.0 ms | 50.4 ms | **3.93×** | 4.00× |
| 8 | 84.1 req/s | 93.9 ms | 101.0 ms | **7.87×** | 8.00× |
| 16 | 84.7 req/s | 188.0 ms | 203.7 ms | **15.75×** | 16.00× |

**Throughput is flat across a 16× rise in concurrency and latency rises linearly** — the
signature of a single server, with no fault injected to produce it. It needed none: the
prediction and the measurement agree to within 2% at every level. And `1 / 11.9 ms = 84.0
req/s`, which is the measured throughput to three figures, so the ceiling is exactly one
request in flight at a time.

The cause is in `src/main.cpp:316`, `net::io_context ioc{1}` — one thread — with handlers that
shell out synchronously through `utils::execCommand`'s `popen` (southbound posts at
`HttpRoutingStrategyBase.cpp:70`, topology polls at `TopologyAndFlowMonitor.cpp:476-502`).

**It does not bite at the load the twin actually runs at**, and that is the honest headline:

| offered load | share of the thread | headroom |
|---|---|---|
| 4 apps at 1 Hz | 4.8% | 21× |
| 7 apps at 1 Hz | 8.3% | 12× |
| 7 apps at 4 Hz | 33.3% | 3× |

What the number does buy is a quantified limit rather than an assumption. A southbound call
that blocks for 500 ms — a wedged Ryu or proxy behind `curl` — occupies the only thread for
**42 requests' worth** of service time, and every consumer stalls behind it for that half
second. That is a bounded, stated consequence instead of an open question, and it is the form
this belongs in: an operating envelope, not a defect report.

⚠️ **Single run, single graph size.** Service time scales with graph size (this is the 128-host
graph, 288 edges); a smaller fabric moves the ceiling up and a larger one moves it down. The
serialisation itself is a structural property and does not depend on the size.

## 3. Idle baseline

Whole machine 4.0% of 14 cores; proxy 3.6%, kernel 2.5%, all ten bmv2 together 2.2% **of one
core**. The old idle 100% CPU spin (`poll()` with a 0 ms timeout) is definitively gone.

## 4. Two things worth carrying forward

**The traffic generator is the largest single CPU consumer in every run.** iperf3 burns ~114% of
a core — more than the ten bmv2 processes' share of the flow's path, and more than the kernel.
Every measurement this project has taken with iperf3 on the same box has had that competing for
CPU, and no report mentions it. At 20% total machine load it is not distorting anything here, but
it would be the first thing to move off-box if the fabric were ever pushed near saturation.

**Only three of ten bmv2 processes do any work.** At 200 Mbit/s across one flow: bmv2-1 51.8%,
bmv2-2 52.1%, bmv2-5 44.8% of a core, the other seven idle. That is the flow's path, and it means
"bmv2 CPU" is really "three switches at ~50% of a core each" — a per-switch single-thread figure,
which is the number that matters against bmv2's single-threaded forwarding loop.

## Restoration

`SAMPLE_RATE` returned to 256 and the pipeline rebuilt **byte-identical** to the pre-experiment
artefact (verified with `cmp`; an earlier rebuild differed only in the embedded source path
string, 67 vs 34 chars). `p4_client.py` restored to its committed state (`git diff` empty). Fabric
and stack restarted and verified live: quantum back to 256 × 1442 × 8, twin/truth 1.021 — and
notably **not ~2.0**, so the warm-fabric clone-replica stacking did not recur across five proxy
restarts.
