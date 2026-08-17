# P4 vs OVS on a matched topology: what the 291-second blackhole actually was

**2026-08-17.** Twenty-three live measurements — ten per 4-host cell, three on the 128-host cell
— all taken the same afternoon with one method. Raw ping logs in `raw/`, the measurement script
beside this file.

**In one line:** on a matched topology P4 fails over **2.0 s faster than OVS** (13.7 s vs 15.7 s,
p = 0.0098). That is a real difference and a small one — the 291 s it replaces was mostly a
kernel defect that has since been fixed.

[Co-developed with claude code -- Adam]

---

## 1. Why this was run

The record carried a striking comparison: the same unidirectional link failure **self-heals in
12.5 s on P4** and **blackholes for 291 s with zero self-heal on OVS**, while the twin reports the
flow healthy throughout. It has been read as evidence about the two data planes.

It cannot support that reading, because the two sides were never measured on the same network:

| | P4 side | OVS side |
|---|---|---|
| topology script | `p4_proxy/mininet/p4_testbed_topo.py` | `testbed_topo.py` |
| hosts | 4 | **128** |
| directed edges | 40 | **288** |
| link shaping | none | TCLink `bw=1000/10000` |

Data plane, controller, path diversity and link shaping all changed at once. A difference in the
result cannot be attributed to any one of them. This round holds the topology constant.

## 2. Method

One measurement = inject 100 % loss on the link the traffic is actually using, and watch a
continuous ping through it.

- **Continuous ping, 5 packets/s, `-D` timestamps.** The outage is read off the gap between
  consecutive replies, not inferred from a before/after probe.
- **The injected link is resolved at run time** — from `ovs-ofctl dump-flows s1` in OVS mode, from
  the proxy's `all_destination_paths` in P4 mode. A previous run's reroute moves the path, so a
  hard-coded interface injects into a link nothing is using, which is indistinguishable from
  "recovered instantly".
- **The netem is re-read every 5 s for the whole fault window.** A run where it was ever absent is
  discarded. All nine runs here passed that check.
- **Recovery is only credited while the fault is still present.** In every run the fault outlived
  the recovery, so what was measured is a reroute and not the removal of the fault.
- **tc form follows the interface.** `root netem` where the topology does not shape; `parent`
  under the htb class where it does. Using the root form on a shaped interface destroys the htb
  and silently changes the fault.

Fault: 100 % loss, one direction, on an on-path link out of `s1`. Pair `10.0.0.1 -> 10.0.0.2`
(4-host cells) and `10.0.0.1 -> 10.0.0.33` (128-host cell; `.2` shares `s1` there and would not
leave the switch).

## 3. Results

| cell | n | mean | sd | range |
|---|---|---|---|---|
| **P4 / 4 hosts** | 10 | **13.7 s** | 1.6 | 11.0 – 16.4 |
| **OVS / 4 hosts** | 10 | **15.7 s** | 1.5 | 13.7 – 18.1 |
| **OVS / 128 hosts** | 3 | **50.1 s** | 3.4 | 47.0 – 53.7 |

Individual runs, in the order taken:

```
P4  / 4 hosts   12.1  11.0  14.8  16.4  15.2  14.1  13.1  14.5  13.3  12.3
OVS / 4 hosts   15.4  13.7  16.2  18.1  16.8  15.6  14.6  15.0  13.9  17.7
OVS / 128 hosts 53.7  49.5  47.0
```

Every one of the 23 runs showed exactly one outage followed by full recovery, with the netem
verified still present at the moment traffic resumed. **No run failed to recover.**

**The method reproduces the historical figure.** The first P4 run came out at 12.1 s against the
12.5 s on record — measured independently, on a different bmv2 build, months later.

### 3.1 P4 vs OVS, tested

The two 4-host cells were taken to n=10 specifically because at n=3 their ranges overlapped and
the comparison could not be called either way.

| | value |
|---|---|
| difference (OVS − P4) | **2.03 s** |
| Welch *t* | 2.89, df 17.9 |
| two-tailed *p* | **0.0098** |
| 95 % CI of the difference | **0.55 s – 3.50 s** (excludes 0) |
| relative | P4 is **13 %** faster |

**P4 does fail over faster than OVS on identical topology, and the margin is 13 %.** The ranges
still overlap run-to-run (P4 reaches 16.4 s, OVS starts at 13.7 s), so no single pair of runs
demonstrates it; it takes the sample to see it. Anyone quoting this should quote the interval,
not the means alone.

## 4. What the 291 s decomposes into

**The kernel defect is the dominant term, and it is the only one that changes the *kind* of
outcome.** On the *same* 128-host topology the same fault went from "291 s, never recovers" to
**50.1 s, recovers by itself**. The network did not change; the code did. `faults.sh`'s own L-2
entry names the repair: the BFS both-directions check. Everything below is a difference in how
long, not in whether.

**Topology size is real and clean.** 15.7 s at 4 hosts against 50.1 s at 128 hosts, a **3.2×**
slowdown. The two ranges do not come close to overlapping (18.1 max vs 47.0 min), so this holds
even at n=3 on the larger cell.

**The data plane is the smallest term, and it is now measured rather than asserted.** P4 13.7 s
against OVS 15.7 s: a **2.0 s** advantage to P4, p = 0.0098, CI 0.55–3.50 s (§3.1). Real, and
**13 %**.

Putting the three side by side on the same fault:

| term | size | kind of effect |
|---|---|---|
| the kernel defect (since fixed) | 291 s → 50.1 s on the same topology | **never recovers → recovers** |
| topology size (4 → 128 hosts) | 3.2× | how long |
| data plane (OVS → P4) | 1.13× | how long |

So the original comparison was, in order of magnitude: a defect that has since been fixed, then
network size, then — a distant third — the data plane. **The 291 s figure must not be cited as
evidence about OVS.** The defensible claim from this round is the narrow one: *on identical
topology, P4 restores traffic about 2 seconds sooner than OVS, roughly 13 %.*

## 5. Limitations

- **n=10 on the 4-host cells, n=3 on the 128-host one.** The topology effect is far larger than
  its spread, so n=3 carries it; the data-plane effect needed all ten.
- **The 2.0 s result is a single-fault, single-pair, single-machine measurement.** It says P4
  reroutes sooner after *this* fault on *this* topology. It is not a general statement about the
  two data planes, and nothing here measures how the gap scales — the 128-host cell was only run
  on OVS.
- **P4 ran on the `-O3` bmv2 build**, the historical 12.5 s on the `-O0` one. The two agree to
  0.4 s, which suggests failover time is set by control-plane detection rather than forwarding
  speed — suggestive, not demonstrated.
- **The p-value was computed with a stdlib numeric integration of the Student-*t* CDF**, not
  scipy (not installed on this machine). The 95 % CI, which is what the conclusion rests on, uses
  the standard table value for df ≈ 18 and needs no such approximation.
- **The two 4-host cells rerouted over different equal-cost links** (P4 `s1->s5`, OVS `s1->s6`).
  Structurally symmetric — one hop via an aggregation switch — but not the same physical link.
- **P4 at 128 hosts was not measured.** Deliberate: the three cells already separate both
  effects, and the fourth only tests for an interaction. The topology author reached the same
  conclusion independently — `p4_testbed_topo.py` carries the comment *"128 hosts in BMv2 might
  be too heavy"*.

## 6. Three fixture defects found while building this

Each one produced a *green-looking* system that was not doing what it claimed.

**`mn -c` kills the controller the topology needs.** Mininet's cleanup killalls a list that
includes `ryu-manager` (`mininet/clean.py`). Copying `os.system('sudo mn -c')` from the P4
topology into an OVS one is harmless-looking and fatal: it kills Ryu just before the switches try
to reach it. Symptom: bridges up, `ovs-vsctl get-controller s1` correct, Ryu simply gone.

**Ryu's static topology path was hard-coded** ([intelligent_router.py:25](../../../intelligent_router.py)).
The kernel takes its model from `--topology`; the router took its own from a module-level
constant, and nothing checked that they agreed. Pointed at different models, the router installs
routes for the hosts *its* file declares: on a 10-switch/4-host fabric `s1` got
`nw_dst=10.0.0.2 actions=output:4` — a port that switch does not have. **Every host pair was
100 % loss while Ryu's topology view and the kernel's graph both reported 10 switches, 40 edges,
all up and enabled.** Now overridable via `NDTWIN_RYU_TOPO_FILE`, default unchanged.

**Ryu learns host IPs only from packets it is punted.** `testbed_topo.py` pings all 128 hosts in
parallel immediately after `net.start()` — *before* the router installs its proactive rules — and
those packet-ins are what populate `ipv4`. A fixture without that burst gets flow rules installed
first, so later traffic is forwarded in the data plane, never reaches the controller, and `ipv4`
stays empty forever. `updateHosts` skips hosts with an empty `ipv4`, so they and their edges
report **down** while every switch reports up. Measured side by side: **128/128 hosts carry IPs
in the 128-host cell, 0/4 in the 4-host cell**, after thousands of pings. This refines
[[ndtwin-static-arp-blocks-host-discovery]]: it is not the ping burst as such, it is the burst
landing *before* the rules do.

None of the three affects the numbers in §3 — those were measured with real ICMP through the data
plane, and the switch and link state was correct in every cell. The third does mean the 4-host
cells' host-level twin view is incomplete, so **that cell should not be used for host-level
assertions** until the fixture does a pre-rule ping burst.

## 7. Reproducing

```bash
# 4-host cells need the matched model on both sides:
export NDTWIN_RYU_TOPO_FILE=$PWD/setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json
export TOPO_OVS=$NDTWIN_RYU_TOPO_FILE
# Ryu first, topology second -- stack.sh refuses the other order (the /stats/flow wedge).
bash tools/test_workflow/stack.sh up ovs      # start the topology when it prompts:
sudo -n /usr/local/sbin/ndtwin-lab ovs-topo-4host
# then, per measurement:
bash measure_failover.sh ovs 10.0.0.2 60 run.log
```

For the P4 cell: `ndtwin-lab topo-start`, `stack.sh up p4`, then
`measure_failover.sh p4 10.0.0.2 60 run.log`.
For the 128-host cell: no env overrides, `ndtwin-lab ovs-topo-start`, dst `10.0.0.33`.
