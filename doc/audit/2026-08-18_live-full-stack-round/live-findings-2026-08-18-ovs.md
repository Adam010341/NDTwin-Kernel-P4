# Live full-stack round, 2026-08-18 — OVS/Ryu, 128 hosts

Stack: Ryu :8080/:6653 → NTG `testbed_topo.py` (10 switches / 128 hosts, 288 edges) →
kernel :8000 (`04b8933`) → NSR + Visualizer (readers) → Simulation-Platform-Manager,
Energy-Saving-App, Traffic-Engineering-App (periodic, 15s).

Brought up entirely unattended via `ndtwin-lab` — no human step. Converged after 69s.

[Co-developed with claude code -- Adam]

---

## F-1. A punt-to-controller rule is diagnosed as a missing topology link

**Observation.** One warning in an otherwise error-free kernel log:

```
[2026-08-18 17:02:29.013] [warning] [FlowLinkUsageCollector.cpp:2753 calFlowPathByQueried]
edge not found by dpid/port 5:4294967293; the topology file has no link there,
so paths through it stay empty
```

`4294967293` = `0xFFFFFFFD` = **`OFPP_CONTROLLER`**, an OpenFlow *reserved* port.

**Mechanism (read, not inferred).** `FlowLinkUsageCollector.cpp` around :2690–:2717:

```cpp
uint32_t outPort = effect->outputPorts.front();      // no reserved-port filter
path.push_back(std::make_pair(graph[srcSw].dpid, outPort));
auto nextEdgeOpt = m_topologyAndFlowMonitor->findEdgeByDpidAndPort(
    std::make_pair(graph[srcSw].dpid, outPort));
if (!nextEdgeOpt.has_value()) {
    ok = false;
    walkFailures.record(..., "edge not found by dpid/port {}:{}; the topology file "
                             "has no link there, so paths through it stay empty");
    break;
}
```

and then `it->second.flowPath = ok ? std::move(path) : sflow::Path{};`

**Reachability, verified on a live switch.** `GET /stats/flow/1` — 130 rules on s1,
OUTPUT histogram `[('2',96), ('CONTROLLER',2), ('3',1), ...]`. The two CONTROLLER rules are:

```
prio 65535  table 0  match {'dl_dst':'01:80:c2:00:00:0e','dl_type':35020}  actions ['OUTPUT:CONTROLLER']   # LLDP
prio 0      table 0  match {}                                             actions ['OUTPUT:CONTROLLER']   # table-miss
```

Both are permanent and present on every switch (installed by `--observe-links` and by the
Ryu app's table-miss). The prio-0 rule **matches every flow**, so any flow that has no
specific forwarding rule on some switch along its path resolves to `OFPP_CONTROLLER`.

**Why it is a defect.** Not the erasure — `ok ? path : Path{}` is deliberate and
defensible (an untraceable path is reported as no path rather than a wrong partial one).
The defect is the **diagnosis**: the message sends the reader to
`setting/StaticNetworkTopology*.json` to look for a missing link, and no topology file can
ever contain a link to port 4294967293. The real cause is "this flow hit the table-miss
rule; it is being punted to the controller, not forwarded."

The same function already distinguishes two causes carefully (`no-table:{dpid}` vs
`no-rule:{dpid}`). This is a third cause — *matched a rule, but the rule does not forward* —
that currently falls into the fourth branch and gets the wrong label.

**Suggested shape.** Test `outPort >= 0xFFFFFF00` before the edge lookup and record it as
its own cause, naming the reserved port (`CONTROLLER`, `FLOOD`, `NORMAL`, ...). Same
`ok = false` outcome; different, true message.

**Status:** not fixed. Diagnostic-only — no wrong data reaches any consumer.

---

## N-1. Energy-Saving-App powered off 3 of 10 switches in 60s — correct, recorded so the
## rest of the round is read against the right baseline

At 17:03:08 and 17:04:07 the app chose `case4` and powered off **s5, s7, s9**
(`Group(root=4)=[s5,s6]`, `Group(root=6)=[s7,s8]`, `Group(root=8)=[s9,s10]` — one per group).
Correct behaviour on a zero-traffic network.

The twin tracked it exactly: `nodes up 135/138`, `edges up 268/288`, DOWN nodes
`['s5','s7','s9']`, and all 20 down edges are precisely the links incident to those three.

**A dead end worth writing down.** `GET /stats/flow/5` returns **HTTP 404 in 0.9 ms** while
every other dpid returns 200 with ~35 KB. `ovs-vsctl list-br` shows 7 bridges — s5, s7, s9
are gone, not merely disconnected. I first read this as "the twin claims 10/10 while three
switches are missing". It is not: my 10/10 reading was taken at 17:01, *before* the app
started. Checking the timestamps rather than the two states inverted the conclusion.

---

## F-2. The contract suite cannot coexist with the Energy-Saving-App

**Observation.** `run_layers.sh api ovs --traffic` → 3 layers FAIL. The headline:

```
   BROKEN  /ndt/get_graph_data
           - switch(es) not up: s5(dpid=5), s7(dpid=7), s9(dpid=9)
           - 20 edge(s) down/disabled: 1:1->5:1, 2:1->5:2, ... (+15 more)
           note: used by all 7 tools/apps -- if this breaks, everything breaks
```

Nothing broke. The Energy-Saving-App — one of the seven components this suite exists to
protect — had correctly powered down three idle switches, and the twin reported that
accurately (135/138 nodes, 268/288 edges, and all 20 down edges are exactly the links
incident to s5/s7/s9).

**Mechanism.** `tools/contract_test/spec.py:161` `inv_all_switches_up` and `:184`
`inv_edges_enabled` assert unconditionally that every switch and every edge is up. The
docstring says why it was written:

> The single highest-value invariant for P4 work. In P4 mode the graph currently stays
> isEnabled=false because nothing calls /ndt/inform_switch_entered ...

It was built to catch a **P4 wiring failure** and is applied to every run in both modes.
A deliberately powered-down switch is indistinguishable from a switch that never connected.

**Why it matters.** The suite is a false-alarm generator whenever the power app is running,
which is exactly the failure mode the testing manual warns about ("說明書自己變成假警報的
來源"). Worse, the note it prints — *"if this breaks, everything breaks"* — trains the reader
to treat a correct, healthy, degraded-by-design network as a catastrophe.

**Suggested shape.** The invariant needs to separate "down" from "administratively down".
The kernel already distinguishes them: `admin_disabled` is a per-node field and was `false`
here, while `is_up` was `false`. An invariant keyed on *unexplained* downness — down but not
admin_disabled, and not accounted for by a recent `set_switches_power_state` — keeps the P4
detection it was built for without firing on the power app.

**Status:** not fixed. Test-harness defect, not a product defect.

---

## F-3. The contract schema contradicts the documented `-1` sentinel

```
   BROKEN  /ndt/get_cpu_utilization      - 192.168.123.15: expected >= 0, got -1
   BROKEN  /ndt/get_memory_utilization   - 192.168.123.15: expected >= 0, got -1
```

Four places, three agree and one does not:

| where | says |
|---|---|
| `doc/2026-01-02_ndt_api.md` | "A value of -1 means SNMP query failed or data is unavailable" |
| `Web-GUI/.../DeviceInformation.tsx` | `cpuUtilization === -1 ? t('device.unavailable') : ...` |
| kernel after `04b8933` | emits `-1` for a down switch |
| **`tools/contract_test/spec.py:451`** | **`MapOf(Num(min=0, max=100))` — rejects `-1`** |

Verified live, all three sibling endpoints, 10 keys each, `-1` for exactly the three
powered-off switches (s5=.15, s7=.17, s9=.19) and no strings anywhere.

**Honest attribution.** `04b8933` did not create the incompatibility, it changed the error
message. Before it, a down switch's key was *absent*, so `len(data)` was 9 and
`inv_util_map_covers_switches` (`spec.py:325`, checks count) failed with "only 9 switch(es)
reported, expected 10". The suite failed on a degraded network either way. What is new is
that the failure is now a **schema** violation, and the schema is the thing that is wrong.

**Status:** not fixed. `min=0` should be `min=-1`, or the schema should accept the sentinel
explicitly.

---

## F-4. Stale comment left behind by `04b8933` (mine)

`tools/contract_test/spec.py:459`:

```python
# Values may be an int or an explanatory string ("The switch is down.").
dict(name="get_temperature", ..., schema=MapOf(OneOf(Num(), Str()), ...))
```

`04b8933` replaced that string with `-1`. The comment now describes behaviour that no longer
exists and the `Str()` branch of the `OneOf` is dead. It passes, so nothing caught it.

I updated the kernel and the API document and missed the contract spec — three places needed
the change and I did two.

**Status:** not fixed.

---

## N-2. `/ndt/disable_switch` — known gap, not exercised this round

L3 reports `MISSING /ndt/disable_switch  not in the kernel's dispatch table`. Already
documented in `tools/contract_test/README.md:226`. The verdict comes from the static
declaration in `components.py:73`, not from live traffic: this round the app used
`set_switches_power_state` (5 POSTs) and never called `disable_switch`. Latent, not active.

## N-3. Paths the round did exercise cleanly

`link_failure_detected` fired **20 times** when the three switches went down — the notify
path Ryu → kernel works. Request mix over the round: `get_graph_data` 1426,
`get_detected_flow_data` 858, cpu/memory 656 each, `acquire_lock`/`release_lock` 61/78,
`install_flow_entry` 10, batch install 10, `received_a_simulation_case` 14,
`app_register` 5. Kernel log: **0 errors** across 16324 lines.

---

## F-5. A rejected flow rule is reported as installed for ~8s, then vanishes silently

**The sharpest finding of the round.** Controlled experiment, quiet network (NTG stopped),
three sources polled every 2s from the moment of the POST.

```
POST /ndt/install_flow_entry
{"dpid":1,"priority":777,"match":{"ipv4_dst":"10.0.0.99"},"actions":[{"type":"OUTPUT","port":2}]}
-> HTTP 200 {"accepted":1,"status":"queued",
             "detail":"entries accepted for programming; per-entry outcomes are
                       reported in the kernel log, not in this response"}

   t    switch(ovs-ofctl)   ryu(/stats/flow/1)   kernel(get_switch_openflow_table_entries)
   0s   130                 130                  131/HIT [{"port": 2, "type": "OUTPUT"}]
   2s   130                 130                  131/HIT [{"port": 2, "type": "OUTPUT"}]
   4s   130                 130                  131/HIT [{"port": 2, "type": "OUTPUT"}]
   7s   130                 130                  131/HIT [{"port": 2, "type": "OUTPUT"}]
   9s   130                 130                  130
  ...   130                 130                  130          (through 84s)
```

The switch never had it. Ryu never had it. The kernel asserted it existed for ~8 seconds
and then silently stopped.

**Why the rule was rejected — and why that makes the finding sharper, not weaker.**
The match `{"ipv4_dst": ...}` has no `eth_type` prerequisite, which OpenFlow 1.3 requires;
OVS rejects it. That is *correct* switch behaviour. Control experiment with the prerequisite
supplied:

```
{"dpid":1,"priority":778,"match":{"eth_type":2048,"ipv4_dst":"10.0.0.97"}, ...}
-> switch=1 ryu=1 at t=2,6,12,20,30s   (installs, persists)
```

So the write path works. The defect is confined to what happens when the switch says no.

**The fingerprint.** During the 8s window the phantom's actions are
`[{"port": 2, "type": "OUTPUT"}]` — a JSON object among 130 strings in the same array, and
byte-identical to the POST body. The kernel is echoing the *request*, not reporting the
*table*. That is what proves it is an optimistic local insert rather than a stale poll.

**What makes it a defect rather than eventual consistency.**

1. The rejection is never surfaced. `grep -cE '\[error\]|\[critical\]'` over the whole
   16k-line kernel log: **0**. No warning either, within 90 lines of the request.
2. Ryu's log has no rejection message.
3. The response body says *"per-entry outcomes are reported in the kernel log, not in this
   response"*. **The one place the API tells you to look is empty.** A caller that follows
   the documented procedure exactly learns nothing.
4. Five components poll flow tables. Any of them reading inside that ~8s window sees a rule
   that does not exist, in a format none of the others use.

**Relation to the known queued-write gap.** The three-model questioner round recorded
"HTTP 200 queued, rule NOT PRESENT" — but there the kernel *did* log
`[error] dispatched install failed for dpid 1 (priority 500)`. Here there is no log line at
all, and the kernel additionally *shows* the phantom. This is a distinct, worse instance.

**Status:** not fixed. Recorded for adjudication — the fix touches the write path's error
reporting, which is the same contract seven components depend on.

**Delete path is fine.** `delete_flow_entry` on the valid 778 rule removed it from the
switch within 8s.

---

## F-6. L5 fault injection fails on a healthy 128-host OVS stack: the default settle is
## 10x shorter than the recovery its own catalogue documents

```
$ bash tools/test_workflow/faults.sh run L-2 --pair 10.0.0.1,10.0.0.100 --iface s1-eth1
  before: moving
  injected 100% loss on s1-eth1 (parent 5:0x1)
  during: still (catalogue expects moving)
  after:  moving
  qdisc state unchanged (169 lines)
FAIL L-2: before=moving during=still after=moving
```

By the catalogue's own words this reads as a regression:

> expect=moving is now correct for BOTH data planes and **a 'still' on either is a regression**

It is not. `faults.sh:94` — `FAULTS_SETTLE_S="${FAULTS_SETTLE_S:-5}"`. Five seconds. The same
catalogue entry, rewritten 2026-08-17 from 23 live runs, records:

> 15.7 s mean over n=10 on a 4-host topology, **50.1 s over n=3 on the 128-host one**

**Controlled re-run, only the settle changed:**

| `FAULTS_SETTLE_S` | verdict |
|---|---|
| 5 (default) | FAIL — `during=still` |
| 70 | **PASS** — `during=moving` |

Same fault, same pair, same interface, `qdisc state unchanged (169 lines)` in both rounds, so
the injection was identical and left no residue either time.

**The shape.** The 08-17 round measured the recovery time correctly and wrote it into the
entry's prose. Nobody moved the parameter. The file now contains both the true recovery time
and a default that guarantees failure against it — and the failure message tells the reader
they have found a regression.

Note this also implies the 4-host case (15.7 s mean) fails at the 5 s default, so the
mis-calibration is not specific to the large topology.

**Status:** not fixed. One-line default change plus a per-topology note, but it is a test
parameter so it wants Adam's call.

**This is the third instance today of the same failure mode** — F-2 (contract suite vs the
power app), F-6 (settle vs recovery time), and the retired-then-corrected 291 s sentence the
entry itself documents. Tests that report a healthy system as broken cost more than missing
tests, because they train the reader to discount red.

---

## F-7. A power off/on cycle permanently strips link shaping from both ends, and the twin
## keeps advertising the configured bandwidth

**Observation.** After powering s5/s7/s9 off (by the Energy-Saving-App) and back on (by me,
via `set_switches_power_state`), exactly **20 of 160** switch interfaces have lost their
TCLink htb qdisc:

```
s1-eth1: qdisc htb 5: root refcnt 15 r2q 10 default 0x1     <- never cycled
s5-eth1: qdisc noqueue 0: root refcnt 2                     <- cycled
```

The 20: `s5-eth1..4  s7-eth1..4  s9-eth1..4` (the cycled switches, all four ports each)
plus `s6-eth3 s6-eth4  s8-eth3 s8-eth4  s10-eth1..4` (**the peer ends of those links**).

**Internal control that isolates the cause.** Within switch s6: `eth3`/`eth4` face s9 and
lost their shaping; `eth1`/`eth2` face s4, which was never cycled, and kept it. Same switch,
same process, same everything — the only difference is whether the neighbour was
power-cycled. This rules out anything switch-wide or tool-wide.

Also ruled out: my own fault injection. `faults.sh` reported `qdisc state unchanged
(169 lines)` after both rounds, and its L-3 log line reads `injected 30% loss on s5-eth1
(root)` — i.e. s5-eth1 was *already* unshaped when the injector found it. L-2 only touched
s1-eth1, which still has htb.

**What the twin says about the same 20 links:**

```
edges touching s5/s7/s9: 20
link_bandwidth_bps values twin reports: {1000000000, 10000000000}
is_up: 20/20
```

Identical to the 268 untouched edges. Nothing distinguishes them.

**Why it matters.** The physical links are now unshaped — they run at veth line rate, not the
1/10 Gbps the topology configures. So for those 20 edges:

- `link_bandwidth_utilization_percent` is computed against a cap that no longer exists
- the Traffic-Engineering-App looks for congested links and these can no longer congest
- the Energy-Saving-App's own `increaseBandwith/decreaseBandwith` inputs are affected

and it is **silent** — no log line, and the twin's numbers look entirely normal.

The sting: powering switches off and on is the Energy-Saving-App's entire purpose. Every
cycle it performs degrades the emulated network's fidelity, cumulatively, until the topology
is rebuilt. A long-running lab drifts toward a fully unshaped fabric.

**Open question I did not resolve** (stated as a question, not a conclusion): whether this is
Mininet's TCLink not being reapplied when the bridge is recreated, or the power path
deleting and recreating the veth pair without shaping. Distinguishing them needs a read of
the OVS power path, which I did not do.

**Status:** not fixed, not diagnosed to root cause. Highest-value item of the OVS round
alongside F-5.

---

# CORRECTION to F-7 (written 2026-08-18 19:30, after re-measurement)

**The F-7 entry above is wrong and is superseded by this section.** It is left in place
because how it went wrong is the point.

## What I claimed, and why it was wrong

I measured 20 unshaped interfaces and 20 down edges, saw the numbers match, and concluded a
power cycle had stripped shaping from both ends of every affected link. **The match was a
coincidence.** `testbed_topo.py` declares the 8 core links at `bw=10000`, and
`/usr/lib/python3/dist-packages/mininet/link.py:238` sets `bwParamMax = 1000` and *ignores*
anything above it with an error message. Sixteen of my twenty had never been shaped at all.

My "internal control" was also wrong: I said s6-eth3/eth4 lost shaping because s6 faced a
cycled switch. **s6 was never cycled.** Those two ports are unshaped because they are
10 Gbps core ports.

This is the [[arithmetic-that-fits-is-not-the-mechanism]] shape, again: an arithmetic
coincidence accepted as a mechanism without reading the line that produces it.

## What is actually true — confirmed on a fresh topology

A second, independent OVS stack (never power-cycled) measured **htb on 144 / 160** switch
interfaces. The 16 without it, listed and compared character for character, are **exactly**
the 16 the topology declares at 10 Gbps:

```
s5-eth3 s5-eth4 s6-eth3 s6-eth4 s7-eth3 s7-eth4 s8-eth3 s8-eth4
s9-eth1 s9-eth2 s9-eth3 s9-eth4 s10-eth1 s10-eth2 s10-eth3 s10-eth4
```

| | fresh topology | after cycling s5/s7/s9 |
|---|---|---|
| interfaces with htb | **144** / 160 | **140** / 160 |

**F-7a (power cycle) is real but small: 4 interfaces**, not 20 — `s5-eth1/2` and `s7-eth1/2`,
the 1 Gbps ports on the cycled switches. s9's four ports are all core, so already unshaped.
The peer ends are unaffected (`s1-eth1` measured as `htb 5: root` both times), so the effect
is *asymmetric*: the cycled switch's egress loses its cap in one direction only.
`OVSPowerStrategy::powerOff` saves the port list but not the qdisc, and `powerOn` re-adds the
ports without re-applying shaping.

**F-7b (core never shaped) is real and permanent, but latent, not active.**

## Measured: the core cap can never bind on this topology

| configuration | aggregate |
|---|---|
| s1→s3, 4 pairs | 1.91 Gbps |
| s1→s3 + s2→s4, 8 pairs — **crosses the core** | **3.39 Gbps** |
| s1→s2 + s3→s4, 8 pairs — **never touches the core** | **3.81 Gbps** |
| s1→s3 with the core capped at `netem rate 10gbit` | 1.88 Gbps (vs 1.75 uncapped) |

Doubling the sources doubled the throughput, so the core is not the constraint. Capping it at
the declared 10 Gbps changed nothing, within noise.

**The binding constraint is the topology, not the hardware.** s5 has two access-facing ports
(from s1 and s2) at 1 Gbps, so it can receive at most 2 Gbps from below and split it over two
core links — **at most 2 Gbps on any one core link, 5x under the declared cap**. A faster
machine converges toward the topology's ~8 Gbps ceiling, never toward 10.

**A first measurement was confounded and is discarded**: both arms sourced from s1 alone and
so hit s1's own 2 Gbps of uplink long before the core, which made "the core makes no
difference" look measured when the core had not been loaded at all.

## Revised severity

Not "the twin advertises a fiction". The 10 Gbps declaration correctly describes the network
being modelled; the emulator declines to implement it and says so in a message nobody reads.
It affects no measurement taken today.

**It is a latent fidelity gap that becomes active the moment someone adds access switches
under an aggregation switch or raises access-link bandwidth** — at which point the cap still
will not bind and nothing will warn. That is the sentence worth putting in the report,
because it says exactly when it starts to matter.

Options (a) apply 10 Gbps shaping is now known to be a no-op; (b) scale the topology 10x down
is the only one that changes behaviour; (c) have the twin report unshaped links honestly is
cheap and correct. All three live in NTG's repo, not ours, except (c).
