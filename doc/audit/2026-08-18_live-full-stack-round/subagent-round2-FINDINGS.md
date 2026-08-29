# NDTwin live-lab findings — run of 2026-08-18

Written incrementally. **Observation** = exact command + output. **Inference** = my reading, flagged as such.

## Status log
- `t0` — session start. Repo `/home/adam/Desktop/NDTwin-Kernel`, branch `fix/flow-rate-divide-by-zero`,
  HEAD `04b8933`. (Brief's snapshot said `2fc430c`; tree is further along. Not a defect, recorded for
  unambiguous later reference.)
- `t0` zero-state verified before touching anything:
  - `pgrep -af '[n]dtwin_kernel' / '[s]imple_switch' / '[r]yu-manager' / '[m]ininet'` -> all empty
  - `sudo -n ovs-vsctl list-br` -> empty
  - `ip -o link show | grep -c veth` -> **3** (pre-existing baseline, NOT from this lab; see below)
  - `ss -ltnp | grep -E ':8000|:8080|:8081|:6653|:5005'` -> empty

---

Findings (`F-n`) and clean results (`C-n`) are interleaved below in the order they were found,
OVS first and then P4. **Jump to the end for the severity ranking, what I did not get to, and the
zero-state reconciliation.**

Supporting artefacts in this directory: `snap.sh` + `cmp.py` (one-shot twin/control-plane/data-plane
comparison), `tel.py` (joint telemetry vs `/proc/net/dev` sampler), `kernel_ovs.log`, `kernel_p4.log`,
`ryu_ovs.log`, `p4_proxy.log`, the traffic configs, and the captured graph snapshots.

---

### F-1 (LOW/MEDIUM, both data planes, fidelity) — `get_cpu_utilization` and `get_memory_utilization` return byte-identical bodies in Mininet mode; all three "device health" metrics are pure functions of the switch IP string

**Observed** (OVS stack up, 10 switches, no traffic):
```
$ curl -s http://localhost:8000/ndt/get_cpu_utilization
{"192.168.123.11":14,"192.168.123.12":54,"192.168.123.13":36,"192.168.123.14":44,"192.168.123.15":39,
 "192.168.123.16":56,"192.168.123.17":25,"192.168.123.18":28,"192.168.123.19":52,"192.168.123.20":26}
$ curl -s http://localhost:8000/ndt/get_memory_utilization
   ... identical, `diff` reports no difference ...
$ curl -s http://localhost:8000/ndt/get_temperature
{"192.168.123.11":29,"192.168.123.12":44,"192.168.123.13":26, ...}
```

**Mechanism — CONFIRMED by reading the code, not inferred from the numbers:**
- `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:945`
  (`fetchMemoryReportInternal`): `memory = 10 + (std::hash<std::string>{}(ip_str) % 50);`
- same file `:1545` (`fetchCpuReportInternal`): `cpu = 10 + (std::hash<std::string>{}(ip_str) % 50);`
  — character-for-character the same expression, same seed, same modulus.
- same file `:1622` (`fetchTemperatureReportInternal`): `temp = 25 + (std::hash<std::string>{}(ip_str) % 25);`

Cross-check that the third one is the *same* hash and not an independent stream:
`.11` cpu=14 => hash%50==4 => hash%25==4 => temp should be 29; observed 29.
`.12` cpu=54 => hash%50==44 => hash%25==19 => temp should be 44; observed 44. Both hold.

**Consequences (inference, flagged as such):**
1. CPU and memory can never disagree. Any consumer trying to tell "CPU-bound" from "memory-bound"
   is reading one number twice. The Web-GUI's `DeviceInformation.tsx` shows all three side by side.
2. All three are constant for the lifetime of a deployment — they do not move with load at all, so
   a soak test that runs traffic and watches switch health sees a flat line and cannot distinguish
   "the twin is not updating" from "the switch is idle". The 10s `statusUpdateWorker` refresh
   re-computes the same constant.
3. The `-1`-for-down-switch sentinel work (commented at `:917-932` and `:1518-1533`, dated
   2026-08-18) is the only thing that ever makes these values move. Verified live under F-6 below.

**Not a crash, not a wrong HTTP code.** Filed as fidelity: the twin reports a number it did not
measure and cannot vary, and two distinct endpoints are aliases.

### C-1 (CLEAN) — OVS static topology fidelity is exact

Single-shot snapshot (`scratch/lab/snap.sh`, all 8 fetches issued in parallel, wall span **0.02 s**,
so this is one comparison and not two moments):

```
twin nodes=138 edges=288 | ryu switches=10 links=32 hosts=128
twin vertex_type counts: {0: 10, 1: 128}
twin edges: sw-sw=32 sw-host=256 host-host=0
ryu directed sw-sw links=32  twin sw-sw=32
in ryu not twin: []   in twin not ryu: []
twin switches down: []  not-enabled: []   twin edges not is_up: 0
```
Every (src_dpid, src_port, dst_dpid, dst_port) quad agrees with Ryu's LLDP view; 128 hosts each
contribute exactly 2 directed edges. No phantom, no missing. Recorded because a 138-node/288-edge
ingest is exactly the shape where the "should replace, can only add" family usually shows up.

Aside worth noting from bring-up (`scratch/lab/stack_ovs.out`): the convergence poller printed
`links=32 -> links=31 -> links=32` before settling. One LLDP link briefly disappeared mid-discovery.
The twin's own convergence gate rode it out. Not chased further.

### F-2 (MEDIUM, OVS) — a unidirectional link failure makes the twin report the *healthy* reverse direction as down for up to one poll interval (30 s)

**Setup.** Injected egress-only 100% loss on `s1-eth1` (= s1 port 1, the s1->s5 link), using the
non-destructive `parent` form so TCLink's htb survives:
```
$ sudo -n tc qdisc show dev s1-eth1
qdisc htb 5: root refcnt 15 r2q 10 default 0x1 direct_packets_stat 0 direct_qlen 1000
$ sudo -n tc qdisc add dev s1-eth1 parent 5:1 handle 10: netem loss 100%   # rc=0
$ sudo -n tc qdisc show dev s1-eth1
qdisc htb 5: root ...
qdisc netem 10: parent 5:1 limit 1000 loss 100%          <- injection asserted present
```

**Observed**, polling Ryu and the twin together every 10 s (abridged; full series in the transcript):
```
t+00..30  ryu_links=32 ryu[s1:1->s5]=True  ryu[s5:1->s1]=True | twin[1->5]=True  twin[5->1]=True  down=0
t+40      ryu_links=31 ryu[s1:1->s5]=False ryu[s5:1->s1]=True | twin[1->5]=False twin[5->1]=False down=2   <-- BOTH down
t+50..170 ryu_links=31 ryu[s1:1->s5]=False ryu[s5:1->s1]=True | twin[1->5]=False twin[5->1]=True  down=1   <-- correct
```
Ground truth for the reverse direction the whole time: `s5-eth1` was never touched, and Ryu kept
reporting `s5:1 -> s1:1`. Data-plane reachability was unaffected — `ping -c 20 10.0.0.1 -> 10.0.0.65`
during the fault: **20 received, 0% packet loss**.

**Mechanism — CONFIRMED by code + logs, not inferred from timing:**
- `intelligent_router.py:876` POSTs `/ndt/link_failure_detected` on Ryu's `Link deleted` event.
  `.test_run/logs/ryu.log:2505` `Link deleted: Link: Port<dpid=1, port_no=1, LIVE> to Port<dpid=5, port_no=1, LIVE>`
  and the matching arrival `.test_run/logs/kernel.log:233-234`
  `handleLinkFailure ... link failed on 1:1 -> 5:1`.
- `src/ndt_core/http/HttpSession.cpp:421-459` (`handleLinkFailure`) marks the forward edge down **and
  then unconditionally looks up and marks the reverse edge down too** — it has no evidence the reverse
  direction failed, and Ryu's event carries none.
- `src/ndt_core/collection/TopologyAndFlowMonitor.cpp:858-864` (`updateLinks`) only ever assigns
  `isUp = true`. So the healthy reverse direction is restored on the *next poll*, not immediately.
- Poll cadence, `TopologyAndFlowMonitor.cpp:2032-2034`: 5 s while converging (first 90 s), then **30 s**.

**Consequence (inference).** For up to 30 s after any single-direction link fault, `get_graph_data`
reports a working link as down. Traffic-Engineering-App and the Visualizer both read exactly this
field. The end state is right; the transient is a false positive on the one direction that still works.

**Note on a doc claim that is now too strong.** `TopologyAndFlowMonitor.cpp:2019-2023` states
"a poll can fill in what was missed but cannot resurrect an edge the push path correctly took down."
That is true only when Ryu agrees the edge is gone. Demonstrated separately: with the physical link
**healthy**, a hand-POSTed `/ndt/link_failure_detected` for `1:1 -> 5:1` returned
`200 {"status":"link failure processed"}` and both directions read `is_up=false`; **20 s later the
poll had set both back to `true`** and `total_down_edges` was 0 again, and stayed 0 for 130 s.
That behaviour is arguably correct self-healing — recording it because the comment asserts it cannot
happen, and because it means the push endpoint is advisory only: an app that reports a failure the
control plane does not see gets silently overruled within one poll, with no response or log saying so.

### F-3 (LOW, both planes) — `ecmp_groups` in `get_graph_data` is static-file fiction; the switches have no groups at all

**Observed**, taken while the s1->s5 link was down:
```
$ curl -s .../ndt/get_graph_data | ... s1 ecmp
  s1 is_up True ecmp [{"members": [{"port_id": 1, "type": "port"}, {"port_id": 2, "type": "port"}]}]
$ sudo -n mnexec -a 1 ovs-ofctl -O OpenFlow13 dump-groups s1
OFPST_GROUP_DESC reply (OF1.3) (xid=0x2):        <- empty: s1 has ZERO groups
```
The twin advertises a 2-member ECMP group on a switch whose real group table is empty, and it keeps
port 1 in that group while the twin itself is simultaneously reporting the port-1 link as down.
Two fields in the same response contradict each other.

**Inference (not yet code-confirmed):** this is the static topology JSON echoed back, never
reconciled against `/stats/groupdesc`. Consumers cannot use `ecmp_groups` for anything real.

### F-4 (HIGH, OVS) — a dead switch-to-switch link is permanently resurrected to `is_up=true`, because `updateHosts` marks an edge up on an IP match alone and a switch's own management IP is learned by Ryu as a host

**Setup.** Disconnect s10 from the controller without touching the bridge or any link — the classic
SDN control-channel loss:
```
$ sudo -n ovs-vsctl get-controller s10        -> tcp:127.0.0.1:6653   (recorded for restore)
$ sudo -n ovs-vsctl del-controller s10        -> rc=0
$ sudo -n ovs-vsctl get-controller s10        -> (empty; disconnected)
```
Ryu immediately dropped s10 and all 8 of its directed links (`.test_run/logs/ryu.log:4061-4089`,
`Link deleted:` x8) and pushed all 8 to the kernel
(`.test_run/logs/kernel.log:304-340`, `handleLinkFailure ... link failed on 10:1 -> 5:4` etc).

**Observed**, polling together every 12 s:
```
ryu_sw=9 ryu_links=24 ovs_br=10 | twin s10 up=True | twin edges@10 up=0/8 | total down=8
   ... 5 samples ...
ryu_sw=9 ryu_links=24 ovs_br=10 | twin s10 up=True | twin edges@10 up=2/8 | total down=6   <-- and stable there
```
Which two:
```
  5:4 -> 10:1  is_up=True     <-- RESURRECTED
  10:1 -> 5:4  is_up=True     <-- RESURRECTED
  6:4 -> 10:2  is_up=False    7:4 -> 10:3 False    8:4 -> 10:4 False
  10:2 -> 6:4  is_up=False   10:3 -> 7:4 False    10:4 -> 8:4 False
```
Ryu's link list at the same instant contains **nothing** with dpid 10. Kernel's own liveness line
confirms it is stable, not a blip: `edges up` went 288 -> 280 -> **282** and stayed at 282
(`kernel.log:353, 373`). No `handleLinkRecovery` was logged after the resurrection, so an HTTP push
is excluded; the writer is the 30 s topology poll.

**Mechanism — CONFIRMED, by finding the actual input that drives it:**
1. `testbed_topo.py:24` gives every switch a management IP `192.168.123.<10+n>` and puts it on the
   switch's **first data port**, verified live:
   `ip -4 -o addr show dev s10-eth1` -> `inet 192.168.123.20/24`.
2. Ryu therefore learns that address as a *host*:
```
$ curl -s http://localhost:8080/v1.0/topology/hosts | (filter for non-10.0.0.x)
  total ryu hosts: 132   non-10.0.0.x entries: 1
  mac 8a:6f:b2:73:51:db  ipv4 ['192.168.123.20']  port dpid=0000000000000005 port_no=00000004 name=s5-eth4
```
   and `8a:6f:b2:73:51:db` is exactly `s10-eth1`'s MAC (`ip -o link show dev s10-eth1`).
   The kernel already notices it cannot place this "host": `kernel.log` carries
   `Host (8a:6f:b2:73:51:db) not found in static network topology file` **14 times** — once per poll.
3. It warns about the *vertex* and then proceeds to write the *edges* anyway.
   `src/ndt_core/collection/TopologyAndFlowMonitor.cpp:682-689`:
   `findEdgeByHostIp(ip)` (definition ~`:1470`) returns **the first edge whose `srcIp` vector
   contains that address — with no check that it is a host edge at all**. For `192.168.123.20`
   the first such edge is `10:1 -> 5:4`, and it is set `isUp = true`.
4. `TopologyAndFlowMonitor.cpp:720-729`: attachment dpid 5 -> s5 (`192.168.123.15`), then
   `findEdgeBySrcAndDstIp(.15, .20)` -> the first edge with that src and dst -> `5:4 -> 10:1`,
   also set `isUp = true`.

Those are precisely the two edges observed, and no others — the prediction from the code matches the
observation edge-for-edge, which is why I am calling this confirmed rather than plausible.

**Why it matters.** The twin permanently reports a link as up whose switch is off the control plane
and whose links Ryu has deleted. It is not a transient: it is re-asserted every 30 s forever, and it
survives anything that tries to mark the link down — `/ndt/link_failure_detected` will be undone by
the very next poll. Any consumer that routes on `get_graph_data` will keep choosing a dead link.

**Generalisation (inference).** The guard is missing, not mis-set: `findEdgeByHostIp` will hand
`updateHosts` *any* edge whose `srcIp` matches, so any device on the fabric that happens to carry an
address the static topology assigns to a switch can pin arbitrary switch-to-switch edges up. In this
deployment that device is the switch itself, so the condition is permanent and built in.

### F-5 (MEDIUM, OVS) — twin reports a controller-less switch as `is_up: true`; switch liveness is "does an OVS bridge exist", not "is it reachable by the control plane"

Same experiment, same single snapshot as F-4:
```
ryu switches = 9 (s10 absent)      ovs-vsctl list-br = 10 (s10 present)
twin s10: is_up=True  is_enabled=True     -- for the whole 2-minute observation
```
**Mechanism — CONFIRMED by code:**
`src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:761-777` decides OVS switch
liveness with `ovsLivenessFor(swName, listOvsBridges)` — the output of `ovs-vsctl list-br`. The
bridge still exists, so the verdict is `Up`. Nothing in the poll path consults Ryu's switch list:
`TopologyAndFlowMonitor.cpp:558-573` (`updateSwitches`) only ever sets `isUp = true`, and the only
`setVertexDown` callers in the tree are the two power strategies and this liveness worker
(`grep -rn 'setVertexDown' src/`).

So in OVS mode a switch is "up" iff a bridge with that name exists on the host. A switch that has
lost its OpenFlow channel — unreachable, unprogrammable, invisible to Ryu — is indistinguishable
from a healthy one. Note this is the *opposite* asymmetry to the P4 branch above it
(`:726-749`), which does key on a round-tripped P4Runtime RPC.

### F-6 (MEDIUM, both planes) — "tables are left as they were" is false at the API: a switch whose flow-table read fails is *deleted* from `get_switch_openflow_table_entries`

The four skip paths in `fetchOpenFlowTablesInternal` each state, in comments, that the previous table
is kept (`DeviceConfigurationAndPowerManager.cpp:1070-1081` empty body, `:1091-1109` unparseable,
`:1122-1139` reported failure, `:1140-1156` suspected timeout). That is true of the **Classifier**,
which is simply not fed the switch. It is **not** true of the HTTP endpoint.

**Mechanism — CONFIRMED by code:** `fetchOpenFlowTablesInternal` builds a *fresh* `result` array and
only `push_back`s switches it read successfully (`:1164`); `openflowTablesUpdateWorker` then does
`m_cachedOpenFlowTables = std::move(newTables)` (`:1890`) — a wholesale replace. A skipped switch is
therefore not stale, it is gone.

**Confirmed live** (predicted from the code first, then measured):
```
BEFORE                          dpids: [1,2,3,4,5,6,7,8,9,10]
$ sudo -n ovs-vsctl del-controller s10
t+8s  .. t+40s  dpids in get_switch_openflow_table_entries: [1,2,3,4,5,6,7,8,9]     <- s10 deleted
$ sudo -n ovs-vsctl set-controller s10 tcp:127.0.0.1:6653
```
Matching log line, edge-triggered so it appears once per outage, 51 times over the session:
`no flow-table response from localhost:8080 (switch 10 and possibly others); tables are left as they were`

**Consequence (inference).** A consumer of this endpoint cannot distinguish "switch has no rules"
from "switch was unreadable" from "switch does not exist" — the key is simply absent in all three
cases, and the log line promises behaviour the response does not have. Combined with F-5 (the twin
still calls s10 `is_up: true`) the API is internally inconsistent about the same switch in the same
moment: present and up in `get_graph_data`, absent from `get_switch_openflow_table_entries`.

### F-7 (LOW, both planes, performance) — the Classifier is re-fed the whole accumulated table array once per switch, inside the fetch loop

`DeviceConfigurationAndPowerManager.cpp:1164-1167`:
```cpp
result.push_back({{"dpid", dpid}, {"flows", flows}});
// TODO: Test Classifier
m_classifier->updateFromQueriedTables(result);     // <-- inside the per-switch loop
```
`result` grows as the loop runs, and `updateFromQueriedTables` (`Classifier.cpp`) iterates *every*
element it is given and calls `updateOneSwitch` on each. With N switches the first switch's table is
parsed N times, the second N-1 times, and so on: **N(N+1)/2 switch-ingests per poll instead of N**.
Measured shape here: 10 switches x ~130 rules -> 55 ingests / ~7150 rule parses every 10 s where
10 / 1300 would do.

**Correctness:** I read `updateOneSwitch` to check this is not also a *wrong-answer* bug. It is
epoch-based upsert-then-sweep with no time-delta or rate arithmetic, so repeating it with identical
input is idempotent. Recording it as performance only — but the statement is one line inside the
loop that belongs after it, and at the 64-switch ceiling the repo already documents it becomes 2080
ingests per poll.

### C-2 (CLEAN) — the flow-stats wedge guards hold, and OVS recovery is complete

- Control-plane loss produced **zero** `error]` lines in `kernel.log` for the whole session
  (`grep -c 'error]' .test_run/logs/kernel.log` -> **0**), and the empty-response path was
  edge-triggered rather than logging once per switch per poll, as its comment claims.
- After `set-controller s10 tcp:127.0.0.1:6653`, eight consecutive joint samples read
  `ryu_sw=10 ryu_links=32 | twin down edges=0 sw_down=[]`. Full recovery, no residue.
- The `tc` fault was reverted cleanly: `tc qdisc show dev s1-eth1` returned to exactly
  `qdisc htb 5: root refcnt 15 r2q 10 default 0x1 direct_packets_stat 0 direct_qlen 1000`,
  i.e. TCLink's htb survived, which is the thing `faults.sh` warns is usually destroyed.

## OVS — traffic-running phase
Tools running concurrently for everything below: Energy-Saving-App, Simulation-Platform-Manager
(`ndtwin-lab energy-start` / `sim-start`), Network-State-Recorder (pid 890023),
Traffic-Engineering-App (pid 890067, periodic mode), Network-Traffic-Visualizer (JavaFX, drawing
138 nodes), plus NTG as the traffic source. Web-GUI skipped (no Node on this machine).
Traffic: `scratch/lab/flow_ovs_measure.json` — 4 fixed 20 Mbit/s far-distance UDP flows for 210 s
plus 1 flow/s of 5 Mbit/s 30 s UDP, over a 4 min interval.

### F-8 (MEDIUM, OVS — and P4 by construction) — `left_link_bandwidth_bps` is a hard-coded 1 Gbit/s for every link until sFlow first samples it, so a 10 Gbit/s core link advertises one tenth of its capacity

**Observed.** Two snapshots of `get_graph_data`, checking the invariant
`left_link_bandwidth_bps == link_bandwidth_bps - link_bandwidth_usage_bps`:
```
IDLE, before any traffic:    288 edges, 16 are 10 Gbit/s links, of those reporting left=1 Gbit/s: 16   (all of them)
UNDER TRAFFIC, 6 min later:  288 edges, 16 are 10 Gbit/s links, of those reporting left=1 Gbit/s:  9
```
and those 9 are the ones whose `link_bandwidth_usage_bps` is still 0, e.g.
```
(5,3)->(9,1)  bw=10000000000  left=1000000000  usage=0
(9,4)->(8,3)  bw=10000000000  left=1000000000  usage=0     ... 9 in total
```
No edge is inconsistent in the other direction, and every 1 Gbit/s edge is consistent.

**Mechanism — CONFIRMED by code:**
- `include/common_types/GraphTypes.hpp:15` `#define MININET_INTERFACE_SPEED 1000000000`
- `include/common_types/GraphTypes.hpp:376` `uint64_t leftBandwidthFromFlowSample = MININET_INTERFACE_SPEED;`
  — the member default is a **constant 1 Gbit/s**, not `linkBandwidth`.
- `src/ndt_core/http/HttpSession.cpp:554-555` — in `DeploymentMode::MININET` the API reports
  `left_link_bandwidth_bps` from `leftBandwidthFromFlowSample`, not from `leftBandwidth`.
- `src/ndt_core/collection/TopologyAndFlowMonitor.cpp:321` initialises the *other* field correctly
  (`ep.leftBandwidth = ep.linkBandwidth;`) when the static topology is loaded — so the file's
  10 Gbit/s is read, stored in the field Mininet mode does not report, and the reported field keeps
  its constant default.
- `TopologyAndFlowMonitor.cpp:1090-1092` is the only writer: `leftIn = linkBandwidth - estimatedIn`,
  reached only when an sFlow datagram is attributed to that edge. Hence "corrected on first sample",
  which is exactly the idle-16 -> traffic-9 transition measured above.

**Consequence (inference).** Any consumer doing admission control or placement on
`left_link_bandwidth_bps` — which is what the field is for, and what Traffic-Engineering-App reads —
sees 1 Gbit/s of headroom on an idle 10 Gbit/s link. The error is silent, and it is *worst* on the
core links, i.e. the ones a TE decision most depends on.

### F-9 (LOW/MEDIUM, OVS) — link usage is quantised to 3,084,288 bps, so any link carrying less than ~3 Mbit/s reads as 0 or as 3.08 Mbit/s

**Observed**, under traffic, all non-zero switch-to-switch `link_bandwidth_usage_bps` values:
```
12337152 21590016 33927168 40095744 46264320 46264320 49348608 70938624 74022912 101781504 107950080 166551552
all multiples of 3084288?  True      quotients: 4 7 11 13 15 15 16 23 24 33 35 54
```
Host-facing edges show the base quantum itself: `3084288`, `6168576`.
`3084288 = 256 (the configured sFlow sampling rate, `ovs-vsctl list sflow` -> `sampling: 256`)
x 1506 bytes x 8`.

**Checked and NOT what I first thought.** My first hypothesis was that the collector multiplies a
fixed 1506-byte frame size. That is false for the per-flow path: bits-per-packet across 18 live flows
was `{12068.9: 6, 12065.7: 3, 12058.9: 1, 12048.0: 2, ...}` and the "proceeding 1 s" field also
carried small-packet flows at `560`, `568`, `608`, `624` bits/packet — so real sampled frame lengths
are used (`FlowLinkUsageCollector.cpp:1220,1281,1434` `frameLength * samplingRate`). The quantisation
is therefore an inherent sampling-granularity effect, not a constant. Recording it because the
granularity is coarse enough to matter: with sampling 1-in-256 a link is invisible until it carries
~3 Mbit/s, and `link_bandwidth_utilization_percent` inherits the same step (0.31% per step on a
1 Gbit/s link, 0.03% on a 10 Gbit/s one).

### F-10 (OPEN — measured, mechanism NOT established) — twin's aggregate switch-to-switch link usage runs consistently above the kernel's own byte counters

Joint sampler (`scratch/lab/tel.py`) reads `/proc/net/dev` and `get_graph_data` in the same pass;
ground truth is the tx-byte delta over each 25 s window on `s*-eth1..4`, twin is the sum of
`link_bandwidth_usage_bps` over all 32 directed switch-to-switch edges at the end of that window.
```
window   twin_ss_total_bps   gt_ss_total_bps   twin/gt
  2         613,773,312         617,726,910      0.99
  3         681,627,648         631,186,777      1.08
  4         740,229,120         632,956,521      1.17
  5         758,734,848         622,423,668      1.22
  6         814,252,032         623,364,699      1.31
  7         724,807,680         641,888,341      1.13
  8         811,167,744         626,478,351      1.29
  9         721,723,392         620,446,281      1.16
```
Per-link ranking agrees well (`s6-eth4`/`s10-eth4` are the top two in both, every window), so the
attribution is right; it is the magnitude that runs high, 8 of 9 windows positive.

**This is deliberately filed as unresolved.** Two candidate explanations I could not separate in the
time available, and I am not willing to assert either:
(a) an instantaneous 1 s twin estimate compared against a 25 s ground-truth average, with bursty
    traffic — a methodology artefact, not a defect;
(b) `FlowLinkUsageCollector.cpp:1434-1447` credits each sample to the ingress edge **and** to the
    sampling switch's egress edge; if the next-hop switch independently samples the same packet, the
    shared link could be counted from both ends. The comment says this is intentional, and a naive
    double-count would predict ~2x rather than the observed 1.1-1.3x, so the arithmetic does *not*
    fit the theory — which is why I am not claiming it.
The clean experiment (a single fixed-rate UDP flow on a known path, no varied traffic, twin sampled
at 1 s to match its own window) was not run. Recommended as the next step.

### C-3 (CLEAN) — flow detection, path resolution and the analytics endpoints behave under load
- `get_detected_flow_data` returned 18-38 flows tracking the generator's arrival/departure, and
  **every flow had a full path**: path-length histogram `{7: 21}`, `empty-path flows: 0`.
  This is the failure mode the contract's `inv_flow_paths_non_empty` exists for, and it held.
- `get_path_switch_count?src_ip=10.0.0.1&dst_ip=10.0.0.65` -> `switch_count: 5`, which is the true
  hop count for this fat-tree (s1-s5-s9-s7-s3); intra-switch pairs correctly return 1. The
  no-parameter form returned all 996 kB of pairs, HTTP 200.
- Zero-traffic behaviour of the analytics endpoints is clean, no divide-by-zero and no 500s:
  `get_num_of_flows_passing_a_switch {"dpid":1}` -> `{"num_of_flows":0,"status":"success"}`,
  `get_total_input_traffic_load_passing_a_switch` -> `{"total_input_traffic_load_bps":0,...}`,
  `get_average_link_usage` -> `{"avg_link_usage":0.0,"status":"success"}`.
- `link_bandwidth_utilization_percent` is internally consistent with usage/bandwidth on every edge.
- `inform_all_destination_paths` is POST-only; a GET correctly 404s and a POST with the wrong body
  gives `400 {"details":"[json.exception.out_of_range.403] key 'all_destination_paths' not found"}`
  rather than a 500.

### F-11 (HIGH, both planes, design) — `/ndt/release_lock` has no notion of an owner: any caller can release a lock another application holds

The kernel exposes `acquire_lock` / `renew_lock` / `release_lock` as the mutual-exclusion primitive
between seven independent applications. The request body carries **only** `{"type", "ttl"}` — no
token, no app id, no lease handle — and nothing is returned that could act as one.

**Observed**, one client acquiring and a *different, unidentified* client releasing:
```
1. POST acquire_lock {"type":"routing_lock","ttl":120}   -> 200 {"status":"locked","ttl":120,"type":"routing_lock"}
2. POST acquire_lock {"type":"routing_lock","ttl":120}   -> 423 {"error":"Lock acquisition failed"}   (proves it is held)
3. POST release_lock {"type":"routing_lock"}             -> 200 {"status":"released","type":"routing_lock"}   <-- STOLEN
4. POST acquire_lock {"type":"routing_lock","ttl":5}     -> 200 {"status":"locked",...}                       <-- taken by a third party
```
Step 3 supplied no credential of any kind and the kernel had no way to reject it.

**Mechanism — CONFIRMED by code:** `grep -n 'owner\|holder\|token\|app_name\|client'
include/ndt_core/lock_management/LockManager.hpp` returns **nothing**; the lock is keyed on type
alone. `HttpSession::handleReleaseLock` (`src/ndt_core/http/HttpSession.cpp`) parses only `type`,
and an **absent body releases `LockManager::DEFAULT_LOCK_TYPE_STR`** — so a bare
`POST /ndt/release_lock` with no body drops whatever lock that default names.

**This is not hypothetical here.** With the Energy-Saving-App running unmodified alongside the other
tools, its own log recorded:
```
[error] [http.cpp:475 release_lock] release_lock: bad HTTP code 412 or null body:
        {"detail":"Lock 'routing_lock' is not held or is an invalid type","error":"Release failed"}
```
i.e. an application that believed it held `routing_lock` found it gone. (I cannot prove *what* took
it in that instance — my own probe above ran later — so I am reporting the app error as
corroboration that the window is reachable in normal operation, not as proof of the same cause.)

**Correct behaviour observed alongside it**, worth recording:
- TTL really expires: acquire with `ttl:5`, wait 8 s, acquire again -> 200.
- `renew_lock` on a lock nobody holds -> `412 {"detail":"Lock 'topology_lock' is expired, not held,
  or invalid type"}`.
- Double-acquire -> 423. Mutual exclusion works; it is only unprotected against release.

### F-12 (LOW, tooling) — the contract test now fails on the kernel's own newly-intended behaviour

`run_contract_test.py --with-traffic --topology setting/StaticNetworkTopologyMininet_10Switches.json`
-> **35/39**, failing `get_cpu_utilization` and `get_memory_utilization` with
`192.168.123.15: expected >= 0, got -1`.

`-1` is the *documented sentinel for a switch that is down*, added deliberately on 2026-08-18
(`DeviceConfigurationAndPowerManager.cpp:917-937` and `:1518-1538`, with the API document and
`Web-GUI/src/components/DeviceInformation.tsx` both cited in the comment). The schema in
`tools/contract_test/spec.py` was not updated with it, so the gate now red-flags the fix. s5 was
genuinely down at the time (powered off by the Energy-Saving-App), so the kernel was right and the
test was wrong.

The other two failures in that run were *correct* reports of the same live condition
(`20 edge(s) down/disabled`, `no flows detected` after the traffic interval ended) rather than
defects — recorded so the 35/39 is not mistaken for four bugs.

### C-4 (CLEAN) — the power path works end to end, including the real bridges

The Energy-Saving-App, running unmodified, decided on `avgLinkUtilization 0` to shut switches down.
Single joint snapshot afterwards:
```
get_switches_power_state:  ...15":"OFF"  ...17":"OFF"  ...19":"OFF"   (s5, s7, s9)   others ON
twin nodes:                s5 up=False   s7 up=False   s9 up=False    others up=True
ovs-vsctl list-br:         s1 s10 s2 s3 s4 s6 s8            <- the bridges are really gone
ryu switches:              [1, 2, 3, 4, 6, 8, 10]
twin down edges:           20
```
Twin, control plane and data plane all agree, and the `-1` health sentinel fired for exactly the
down switches. This is the one liveness path in OVS mode that is genuinely evidence-based, and it is
the direct counter-example to F-5: `ovsLivenessFor` gets it right when the bridge is actually removed.

### F-13 (MEDIUM, OVS; 6 endpoints with zero contract coverage) — modify/delete of a group or meter entry that does not exist reports success, and the switch is unchanged

None of `install|modify|delete_{group,meter}_entry` appear in `tools/contract_test/spec.py`
(9 of the kernel's 41 endpoints are uncovered; these are 6 of them). Exercised live against OVS with
`ovs-ofctl` as ground truth for every step.

**Observed** (twin response, then the switch's real table):
```
A install_group_entry  {"dpid":1,"type":"ALL","group_id":9001,"buckets":[{"actions":[{"type":"OUTPUT","port":1}]}]}
     -> 200 {"status":"Group entry installed"}
     dump-groups s1  ->  group_id=9001,type=all,bucket=actions=output:1          CORRECT
D install_meter_entry  {"dpid":1,"meter_id":9001,"flags":"KBPS","bands":[{"type":"DROP","rate":1000}]}
     -> 200 {"status":"Meter entry installed"}
     dump-meters s1  ->  meter=9001 kbps bands= type=drop rate=1000              CORRECT

F modify_group_entry   group_id 7777 (never created)   -> 200 {"status":"Group entry modified"}
G modify_meter_entry   meter_id  7777 (never created)  -> 200 {"status":"Meter entry modified"}
H delete_group_entry   group_id 7777 (never created)   -> 200 {"status":"Group entry deleted"}
I delete_meter_entry   meter_id  7777 (never created)  -> 200 {"status":"Meter entry deleted"}
     dump-groups s1  ->  group_id=9001 ... (only)      dump-meters s1 -> meter=9001 ... (only)
     i.e. nothing named 7777 ever existed, before or after -- four confident successes for
     four operations that did nothing.
```

**Mechanism — CONFIRMED by code.** `HttpSession::handleInstallGroupEntry` and siblings hand the raw
body to `FlowRoutingManager`, which in OVS mode is `HttpRoutingStrategyBase`
(`src/ndt_core/routing_management/HttpRoutingStrategyBase.cpp:207-239`): every one of the six is a
bare `post("/stats/groupentry/modify", j, ...)` with **no validation and no read-back**. Ryu answers
200 for a well-formed REST call; the switch's rejection of a MODIFY/DELETE for an unknown id comes
back asynchronously as an OpenFlow error that Ryu's REST layer never surfaces. The kernel maps
"Ryu accepted the REST call" to "the rule now exists".

This is the same shape the repo has already fixed once for `install_flow_entry`
(`doc`-recorded "rejected requests can still act"): here it is the mirror image — the request is
*accepted* and does nothing, and the caller is told it worked.

**Clean results in the same sweep** (recorded because these are the paths that were hardened and the
hardening holds):
```
B install_group_entry, dpid 99 (not in topology)
     -> 404 {"controller_status":404,"error":"no routing strategy for dpid 99","status":"error"}
C install_group_entry, no dpid at all
     -> 400 {"controller_status":400,"error":"install group entry requires a dpid","status":"error"}
E install_meter_entry, body "{not json"
     -> 400 {"error":"JSON parsing error","details":"[json.exception.parse_error.101] ..."}   (not 500)
```
and the two entries I really created were removed again, verified: `dump-groups` and `dump-meters`
on s1 both came back empty.

### C-5 (CLEAN) — `set_switches_power_state` restores a powered-off switch end to end
```
POST /ndt/set_switches_power_state?ip=192.168.123.{15,17,19}&action=on  -> 200 {"<ip>":"Success"} x3
20 s later: get_switches_power_state -> all ten "ON"
            ovs-vsctl list-br        -> s1 s10 s2 s3 s4 s5 s6 s7 s8 s9   (all ten bridges back)
            ryu switches             -> [1,2,3,4,5,6,7,8,9,10]
```
Note the request shape is **query parameters**, not a JSON body: a JSON body of the shape an app
might guess (`{"switches":{"<ip>":"ON"}}`) is correctly rejected with
`400 {"error":"Missing or invalid ip/action"}` rather than silently doing nothing.

### F-14 (MEDIUM, OVS) — a host can never be marked down; the twin reports an unreachable host as up forever

**Observed.** h128 (10.0.0.128, attached to s4 port 34), chosen because no traffic used it:
```
before:  host 10.0.0.128 up=True enabled=True   edge 4:34->0:1 up=True   edge 0:1->4:34 up=True
$ sudo -n mnexec -a 853203 ip link set h128-eth1 down
  ip -o link show h128-eth1        -> state DOWN          (injection asserted, not assumed)
  ping -c 2 -W 1 10.0.0.1          -> "connect: Network is unreachable"
after 75 s (>2 topology poll cycles at 30 s):
         host 10.0.0.128 up=True enabled=True   edge 4:34->0:1 up=True   edge 0:1->4:34 up=True
```
Interface restored to `state UP` afterwards.

**Mechanism — CONFIRMED by code.** `grep -rn 'setVertexDown' src/` gives four call sites: two power
strategies and `DeviceConfigurationAndPowerManager`'s liveness worker, and that worker's loop body is
guarded by `if (graph[v].vertexType == VertexType::SWITCH)` (`:680`). No path in the tree can set a
**host** vertex down. `updateHosts` (`TopologyAndFlowMonitor.cpp:647,687,727`) only ever assigns
`isUp = true`, and Ryu's host tracker never removes a learned host either, so no input exists that
could express it.

**Consequence (inference).** `get_graph_data`'s 128 host entries are "hosts Ryu has ever seen", not
"hosts that are up". The `is_up` field on a host is a constant `true` after first discovery. Anything
computing reachability, capacity or an SLA per host is working from a value that carries no
information.

**Aside noticed while doing this:** every host edge is stored with `src_dpid = 0, src_interface = 1`
(`4:34->0:1`, `0:1->4:34`), so all 128 host-side edges share the key `(0,1)`. Nothing currently looks
an edge up by that key, but `findEdgeByDpidAndPortNoLock` would return an arbitrary one of the 128 if
anything ever did.

### C-6 (CLEAN) — `twin_audit` finds no contradictions under live traffic
```
$ p4_proxy/venv/bin/python tools/twin_audit/twin_audit.py audit
  ... 19 pairs, each: ping moving / paths moving forward=1 reverse=1 / counters moving ...
  19 pair(s) audited, 0 contradiction(s)
```
Every flow the twin called active was carrying packets at that moment, in both directions, with the
twin's newest sample 1 s old. Run with all six runnable tools attached, so this is the loaded case.

## OVS phase — closing tally

Kernel log for the whole OVS run (`scratch/lab/kernel_ovs.log`, copied before teardown):
`grep -c 'error]'` -> **0**. Warning histogram (numbers masked):
```
  55  no flow-table response from localhost:N (switch N and possibly others); tables are left as they were   <- F-6
  18  Host (Na:Nf:bN:N:N:db) not found in static network topology file                                       <- F-4
   3  parse error ... last read: '{no'                                (my deliberate malformed-JSON probes)
   3  Leaving /srv/nfs/sim/N in place ...                             (pre-existing NFS/squash condition)
   3  Found stale application folder from a previous run              (pre-existing)
   2  refusing flow batch: none of its N entries names a switch ...   (my probes)
   1  Responding N for a failed southbound operation: no routing strategy for dpid N     (my probe B)
   1  Responding N for a failed southbound operation: install group entry requires a dpid (my probe C)
   1  Rejecting simulation case: missing required field(s) ...        (contract test)
   1  Received unsupported request: GET /ndt/there_is_no_such_endpoint (contract test)
   1  Received unsupported request: GET /ndt/inform_all_destination_paths (my probe)
```
Every warning is either one of my own error-path probes, a pre-existing environment condition, or one
of the two findings above. Nothing unexplained, and no ERROR line in ~1 h of a fully loaded stack
including a controller-channel loss, a link fault, an energy-app power cycle and a traffic run.
That is a genuinely good result for the log-hygiene work.

Teardown reconciliation after the OVS phase (before P4 bring-up):
`kernel 0 / bmv2 0 / ryu 0 / mininet procs 0 / ovs bridges none / veth 3 (the pre-existing docker
bridge) / no listener on 8000, 8080, 8081, 6653, 5005x`. Tracked-file diff: only
`.vscode/settings.json`, which was already modified before this session started.

## P4/bmv2 phase

### F-15 (MEDIUM, P4, environment/robustness) — bmv2 gRPC ports are allocated inside the kernel's ephemeral port range, so switches randomly fail to start; the error message then blames the wrong cause

**Observed.** First P4 bring-up, from a machine reconciled to zero (`pgrep -cf '[s]imple_switch'` -> 0,
no bridges, nothing listening on 5005x — verified immediately before):
```
$ pgrep -cf '[s]imple_switch_grpc'   ->  8      (expected 10; s2 and s6 missing)
$ wc -c /tmp/ndtwin_p4_switches.json ->  3643   (manifest also has only 8 entries)
topo pane:
  s2: process exited; gRPC port 50052 was already in use -- most likely a leftover
      simple_switch_grpc from an earlier run (full log: /tmp/s2_bmv2.log)
  s6: process exited; gRPC port 50056 was already in use -- ... (same)
/tmp/s2_bmv2.log:
  E0818 21:01:01.579 chttp2_server.cc:1045 ... '0.0.0.0:50052' ... bind: "Address already in use", errno:98
```

**Mechanism — CONFIRMED, and it is NOT what the message says:**
```
$ cat /proc/sys/net/ipv4/ip_local_port_range      ->  32768   60999
$ cat /proc/sys/net/ipv4/ip_local_reserved_ports  ->  (empty)
$ ss -ltn | ports 50000-50100 (moments later)     ->  50051 50053 50054 50055 50057 50058 50059 50060
                                                      i.e. 50052 and 50056 are FREE
```
The bmv2 listen ports 50051-50060 (`p4_proxy/mininet/p4_testbed_topo.py:105,135`) lie **inside** the
ephemeral source-port range, and none of them are reserved. Any unrelated outbound connection on the
box — and the topology build makes plenty — can hold 50052 as a client source port for the moment
bmv2 tries to bind it. There was no leftover switch: the ports were free before the run and free
after it. (The Thrift ports 9091-9100 are below 32768 and are not exposed to this.)

**Two defects, not one:**
1. The port choice is unsafe. This is a random, silent, partial-startup failure — 8 of 10 switches —
   and every experiment run on top of it would be quietly measuring a different topology.
2. The diagnostic is confidently wrong. "most likely a leftover simple_switch_grpc from an earlier
   run" sends the operator to hunt zombies that do not exist, which is exactly the failure the repo's
   own memory notes record as costing hours. The helper *does* correctly detect and report the
   failure, which is good; it is the attributed cause that misleads.

The bring-up script's own guard caught it (`ASSERT FAIL: bmv2 did not all start`) and refused to go
on to the proxy and kernel, so nothing downstream was measured against a broken fabric. Retrying.

### C-7 (CLEAN) — P4 topology fidelity is exact, and P4 switch liveness is genuinely evidence-based

Single-shot comparison, twin vs the P4 proxy at `:8081`:
```
twin nodes=14 edges=40 | proxy sw=10 links=32 hosts=4
twin edges: sw-sw=32 sw-host=8      proxy directed sw-sw=32   twin=32
in proxy not twin: []   in twin not proxy: []      switches down: []   edges down: 0
```
**Killing a switch is detected**, unlike the OVS case in F-5:
```
$ sudo -n mnexec -a 1 kill -9 907677          # bmv2 s3, pid from /tmp/ndtwin_p4_switches.json
  assert /proc/907677 exists? NO    bmv2 count 10 -> 9
t+12s   proxy_sw=10 proxy_links=32 | twin sw_down=[]      down_edges=0
t+24s   proxy_sw=9  proxy_links=28 | twin sw_down=['s3']  down_edges=4     <- detected, ~24 s
t+36..120s  stable at the same reading
get_cpu_utilization -> {"192.168.123.13": -1}       (the down-switch sentinel, correct)
```
This is `DeviceConfigurationAndPowerManager.cpp:726-749`'s `p4LivenessFor` doing what its comment
claims — keyed on a round-tripped P4Runtime RPC. The OVS branch beside it (F-5) is the one that
cannot tell a controller-less switch from a healthy one.

### F-16 (MEDIUM, both planes) — when a switch dies, only its switch-to-switch edges are marked down; its host-facing edges stay up, so a stranded host still looks connected

Same experiment, listing every edge incident to the dead s3:
```
  sw-sw    3:1->7:1   is_up=False        sw-sw    7:1->3:1   is_up=False
  sw-sw    3:2->8:1   is_up=False        sw-sw    8:1->3:2   is_up=False
  sw-host  3:3->0:1   is_up=True   <--   sw-host  0:1->3:3   is_up=True   <--
```
h3 (10.0.0.3) is attached to s3 and to nothing else, so with s3 dead it is unreachable — yet both
directions of its attachment edge read up, and (per F-14) the host vertex reads up too.

**Mechanism (inference, partially code-supported).** Switch-to-switch edges go down only because the
control plane pushes `/ndt/link_failure_detected` for each deleted link; the P4 proxy has no notion
of a *host* link to delete, and `updateHosts` never sets false. `EdgeProperties::adminDisabled`'s
comment says `disableSwitchAndEdges` marks "every edge incident to the switch" — but that is the
administrative power-off path, not the liveness path, so a switch that *crashes* never takes its
host edges with it. I did not read `disableSwitchAndEdges` end to end, so the "why the two paths
differ" half is inference.

### C-8 (CLEAN) — the six group/meter endpoints refuse honestly on P4 (the exact opposite of F-13 on OVS)
```
install|modify|delete_{group,meter}_entry  ->  501 for all six
  {"controller_status":501,"status":"error","error":"group entry install is not supported on a
   P4/bmv2 data plane: ... Previously this was POSTed to a nonexistent proxy route and the 404
   went unnoticed."}
```
Six for six, with a message that names the reason and the history. Contrast F-13: on OVS the same
six endpoints answer 200 "modified"/"deleted" for entries that do not exist. The P4 strategy is the
one that got the attention.

### Reproduced on P4 without change
- **F-1** — `get_cpu_utilization` and `get_memory_utilization` are byte-identical (`diff` empty).
- **F-8** — 16 of 40 edges have `left != bw - usage`; all sixteen are the 10 Gbit/s links, all
  reporting `left_link_bandwidth_bps = 1000000000`. On P4 that is **every single 10 G link in the
  fabric**, at idle, before anything has been sampled.
- **F-6** — with s3 dead, `get_switch_openflow_table_entries` returns dpids `[1,2,4,5,6,7,8,9,10]`;
  dpid 3 is deleted from the response rather than left stale.
- **F-2's revert half** — a hand-POSTed `link_failure_detected` for `1:1 -> 5:1` returned
  `200 {"status":"link failure processed"}` and both directions read `is_up=false` immediately;
  by the next sample 12 s later both were back to `true`, because the proxy still reports the link.

### Not a defect, checked deliberately
`install_flow_entry` with **no `priority`** on P4 -> `200 {"accepted":1,"status":"queued"}`, and the
rule really is on the switch: `get_switch_openflow_table_entries` shows
`{"match":{"dl_type":2048,"nw_dst":"10.0.9.9"},"actions":["OUTPUT:2"],"priority":0}`. Response and
switch agree, so this is *not* the historical "400 but installed anyway" shape — P4 defaults the
priority to 0 and says so. (Rule removed again with `delete_flow_entry`.)

### F-17 (HIGH, both planes) — `get_average_link_usage` averages over only the *busy* links, so it cannot fall as the fabric empties — and this is the number the Energy-Saving-App uses

> 🔴 **前向更正 2026-08-29 — 標題後半「this is the number the Energy-Saving-App uses」不成立。**
> **正文以下原樣保留**（這是 2026-08-18 當時的認知；改掉就看不到這個錯誤活了多久、經過幾手）。
> ESA 宣告了這個端點的 client（`include/app/http.hpp:34`、定義在 `src/app/http.cpp:393`）
> 但**零呼叫端**；關機決策在 `src/app/energy_saving_app.cpp:926`，讀的是
> `group_avg_link_utilization`（`src/common/types.cpp:396`），從 graph 算，**碰不到這個端點**。
> 七個兄弟 repo 全掃過無其他呼叫者。
> **「只平均忙碌鏈路」這個機制本身仍然成立**，被推翻的只有消費端歸屬。
> 現行裁決與消費端盤點：`doc/audit/2026-08-29_f17-fix-impact/FINDINGS.md`、
> `doc/KNOWN-ISSUES.md` §C 的 F-17 二次更正。

**Observed**, twin read in a single pass together with the graph it is computed from (P4, under traffic):
```
reported avg_link_usage = 0.0032157354666666666
  sw-sw edges: n=32   mean utilisation over ALL 32 = 0.120590%
                      mean utilisation over the 12 NON-ZERO ones = 0.321574%   -> /100 = 0.00321574
  all edges:   n=40   mean over all = 0.212338%   mean over non-zero = 0.424675%
```
The reported value equals `mean-over-non-zero / 100` to six significant figures, and to nothing else.
(An OVS snapshot gives the same shape — `mean_nonzero%/100 = 0.0314` against a reported `0.0363`
seconds later while traffic was changing — consistent but not exact, so the P4 same-pass read is the
one I am relying on.)

**Mechanism — CONFIRMED, I went and read the line that does the division:**
`TopologyAndFlowMonitor::getAvgLinkUsage`:
```cpp
if (g[e].linkBandwidthUsage != 0 && src is not HOST && dst is not HOST) {
    noneZeroEdgeNum++;
    sum += double(g[e].linkBandwidthUsage) / double(g[e].linkBandwidth);
}
...
return sum / double(noneZeroEdgeNum);
```
An idle link is excluded from the **denominator**, not counted as a zero.

**Why this matters, and why I rate it high.** The quantity is meant to answer "how busy is the
fabric?", and it is what `Energy-Saving-App` reads to decide whether to power switches down (its own
log line: `run_switch_cycle_once ... avgLinkUtilization 0`). As links go idle they leave the average
rather than pull it down, so:
- a fabric with 1 link at 30% and 31 idle reports **0.30**, the same as a fabric with all 32 at 30%;
- the figure only reaches 0 when *every* link is idle, at which point the app has no gradient to act on;
- it is a fraction (0..1) while every sibling field (`link_bandwidth_utilization_percent`) is a percent.

**The header documents a different function than the one that runs.**
`include/ndt_core/http/HttpSession.hpp:596-605` says: "For each qualifying directed edge, utilization
is computed as `linkBandwidthUsage / linkBandwidth` and the handler returns the arithmetic mean
across all qualifying edges", where the same doc-block defines "qualifying" purely in terms of
`isUp`/`isEnabled`/`adminDisabled`. The `linkBandwidthUsage != 0` filter is not mentioned anywhere in
the contract the other component's author would read — and that doc block goes out of its way to warn
that "a header that teaches the superseded predicate is a header that misdescribes the input to
another component's decisions."

Minor, same function: two `SPDLOG_LOGGER_INFO` calls sit inside the loop, one per busy edge per call
(measured: 96 lines from 8 calls, 12 per call). Harmless at the Energy-App's cadence, but it scales
with edges x callers.

### F-18 (OPEN — measured, mechanism NOT established) — on P4 the twin *understates* aggregate link usage, the opposite sign to OVS

Same sampler as F-10, same method, P4 fabric under a 3-minute NTG run:
```
window   twin_ss_total_bps   gt_ss_total_bps   twin/gt
  2         152,600,576         195,367,125      0.78
  3         115,492,864         191,696,085      0.60
  4         157,421,568         201,365,432      0.78
  5         151,207,936         188,095,160      0.80
  6         144,924,672         201,006,043      0.72
  7         177,278,976         196,370,539      0.90
```
Per-link ranking again agrees (`s8-eth4`, `s10-eth1`, `s10-eth2`, `s10-eth4` lead in both), so
attribution is sound; the magnitude runs **low** here where OVS ran **high** (F-10). Two different
sampling paths — OVS sFlow at the bridge vs the P4 pipeline's clone-based sampling — so a single
explanation is unlikely, and I am not proposing one. Recorded as an open, reproducible measurement
with the harness (`scratch/lab/tel.py`) left in place.

### C-9 (CLEAN) — the P4 power path kills and resurrects real bmv2 processes, and the manifest tracks it
```
Energy-Saving-App powered off s5, s7, s9 on the P4 fabric:
  get_switches_power_state -> ...15":"OFF" ...17":"OFF" ...19":"OFF"
  pgrep -cf '[s]imple_switch_grpc' -> 7          (three processes really gone)
  proxy switches -> [1,2,3,4,6,8,10]             (three really off the control plane)
  /tmp/ndtwin_p4_switches.json s5 entry -> "pid": null   (manifest updated, not left stale)
POST set_switches_power_state?ip=...&action=on x3:
  pgrep -cf '[s]imple_switch_grpc' -> 10
  proxy switches -> [1,...,10]     twin sw_down=[]  down_edges=0     power state all "ON"
```
Also verified earlier in the session on a *crashed* (SIGKILL'd) switch: `set_switches_power_state
action=on` restarted bmv2 s3 and the manifest picked up the new pid (907677 -> 911656). Restart, not
just a flag flip.

### P4 contract test
`run_contract_test.py --with-traffic --topology setting/StaticNetworkTopologyP4_10Switches_4Hosts.json`
-> **35/39**, failing exactly the same four as OVS and for exactly the same reasons:
`get_graph_data` and `get_detected_flow_data` correctly reporting the live condition at that moment
(s5/s7/s9 powered off by the Energy-Saving-App; the traffic interval had ended), and
`get_cpu_utilization`/`get_memory_utilization` hitting F-12 (the `-1` down-switch sentinel the schema
was never updated for). No P4-specific contract regression.

### C-10 (CLEAN) — P4 proxy log has no unexplained errors, and the startup-order race in `inform_switch_entered` self-heals
`grep -c 'error]' scratch/lab/kernel_p4.log` -> **0** for the whole P4 run. The proxy log's 17
error-ish lines are all accounted for:
- 10 x `[Kernel] switch N entered: FAILED ConnectionError ... /ndt/inform_switch_entered?dpid=N`
  at proxy startup. The P4 bring-up order starts the proxy *before* the kernel, so the first push of
  every switch is lost. **It retries** — later lines read `[Kernel] switch 5 entered: ok` for all ten,
  and the kernel logged 12 `Inform Switch Entered`. Worth knowing because `inform_switch_entered` is
  the only path that sets `isEnabled=true`, so a version that did not retry would leave the whole
  fabric disabled after a normal bring-up. It does retry.
- `[3]/[5]/[7]/[9] Stream receiver error: Stream removed` and one
  `Failed to add route: UNAVAILABLE ... Connection refused` — those are exactly the switches I
  SIGKILL'd and the three the Energy-Saving-App powered off. Correct reporting of a real event.

P4 kernel warning histogram: every entry is one of my own error-path probes (malformed JSON, unknown
dpids, invalid lock type, `--no-ai` intent translator, `not_a_number` dpid) or the pre-existing
`/srv/nfs/sim` squashed-NFS condition. Nothing unexplained.

---

# Summary

## Findings ranked by severity

| # | Sev | Plane | One line |
|---|-----|-------|----------|
| **F-4** | HIGH | OVS | A dead switch-to-switch link is permanently re-marked `is_up=true` every poll, because `updateHosts` marks an edge up on an IP match alone and each switch's own management IP is learned by Ryu as a host on the neighbour's port. |
| **F-11** | HIGH | both | `release_lock` has no owner concept: any caller can release another application's lock with one unauthenticated POST. An empty body releases the default lock. |
| **F-17** | HIGH | both | `get_average_link_usage` averages over only the busy links, so it cannot fall as the fabric empties — and it is the input to the Energy-Saving-App's shutdown decision. The header documents a different formula. 🔴 **前向更正 2026-08-29（正文原樣保留）**：後兩句都不成立——ESA 的 client 零呼叫端、決策讀自己的 `group_avg_link_utilization`；標頭 `HttpSession.hpp:580-584` 現在描述的就是實作的公式。**「只平均忙碌鏈路」仍成立。** 見 `doc/audit/2026-08-29_f17-fix-impact/FINDINGS.md` |
| **F-5** | MED | OVS | Switch liveness is "does an OVS bridge exist", not "is it reachable". A switch that lost its OpenFlow channel reads `is_up: true` (P4's equivalent path, C-7, does this correctly). |
| **F-6** | MED | both | A switch whose flow-table read fails is *deleted* from `get_switch_openflow_table_entries`, while four code comments promise "the previous table stays". |
| **F-8** | MED | both | `left_link_bandwidth_bps` defaults to a hard-coded 1 Gbit/s until first sampled, so every 10 Gbit/s core link advertises one tenth of its headroom. All 16 on P4 at idle. |
| **F-13** | MED | OVS | `modify`/`delete` of a non-existent group or meter returns 200 "modified"/"deleted" and changes nothing. 6 endpoints with zero contract coverage. |
| **F-14** | MED | both | A host can never be marked down — no code path exists. `is_up` on a host is a constant `true` after discovery. |
| **F-16** | MED | both | When a switch dies, only its switch-to-switch edges go down; its host-facing edges stay up, so a stranded host still looks connected. |
| **F-15** | MED | P4 | bmv2 gRPC ports live inside the ephemeral port range, so switches randomly fail to start (2 of 10 on my first attempt); the error message then blames a leftover process that does not exist. |
| **F-2** | MED | both | A unidirectional link failure marks the *healthy* reverse direction down for up to one 30 s poll. |
| **F-1** | LOW/MED | both | `get_cpu_utilization` and `get_memory_utilization` are byte-identical — the same `10 + hash(ip) % 50` expression — and all three health metrics are constant functions of the switch IP. |
| **F-9** | LOW/MED | OVS | Link usage is quantised to 3.08 Mbit/s (sampling 1-in-256), so sub-3 Mbit/s links read 0 or 3.08 M. |
| **F-7** | LOW | both | The Classifier is re-fed the whole accumulated table array once per switch, inside the fetch loop: N(N+1)/2 ingests per poll instead of N. Correctness-neutral, verified. |
| **F-12** | LOW | tooling | The contract test now fails on the kernel's own new `-1` down-switch sentinel; `spec.py` was not updated with it. |
| **F-3** | LOW | both | `ecmp_groups` is static-file fiction — the switches have no groups at all, and it keeps a port in the group while the same response calls that port's link down. |
| **F-10 / F-18** | OPEN | both | Aggregate link usage vs kernel byte counters is biased **high** on OVS (1.08-1.31x over 8 windows) and **low** on P4 (0.60-0.90x over 6). Measured and reproducible; mechanism deliberately NOT claimed. |

## Clean results (paths that could plausibly have broken and did not)

C-1 OVS topology fidelity exact (288/288 edges agree with Ryu, one 0.02 s snapshot) ·
C-2 flow-stats wedge guards hold, zero ERROR lines in a fully loaded hour, complete recovery from
control-plane loss, `tc` fault reverted with TCLink's htb intact ·
C-3 flow detection and path resolution under load (every flow a full 7-hop path, `switch_count` right,
no divide-by-zero at zero traffic) ·
C-4 OVS power path agrees across twin, Ryu and the real bridges ·
C-5 `set_switches_power_state` restores a powered-off switch end to end ·
C-6 `twin_audit` 19 pairs, 0 contradictions under live traffic with all six tools attached ·
C-7 P4 topology fidelity exact **and** P4 switch liveness genuinely evidence-based (SIGKILL detected
in ~24 s) · C-8 the six group/meter endpoints refuse honestly on P4 with a 501 that names the reason ·
C-9 P4 power path kills and resurrects real bmv2 processes and updates the manifest ·
C-10 P4 proxy's `inform_switch_entered` startup race self-heals by retry.

Also clean and worth stating plainly: **zero `error]` lines in the kernel log across both stacks**,
through a controller-channel loss, a unidirectional link fault, two energy-app power cycles, a
SIGKILL'd switch, ~10 minutes of traffic and every deliberate error-path probe I could think of.
Every warning in both runs is attributable.

## What I did not get to

- **The controlled bandwidth experiment that would close F-10/F-18.** One fixed-rate UDP flow on a
  known path, no varied traffic, twin polled at 1 s to match its own estimator window, ground truth
  from the two interface counters on that path only. Everything needed is in `scratch/lab/tel.py`.
- **Web-GUI** — Node is not installed, so 6 of the 7 tools ran, not 7.
- **`modify_device_name` / `modify_nickname` success paths** — they rewrite the tracked topology JSON.
  The contract test covers them; I skipped them rather than dirty the tree.
- **`intent_translator/text` success path** — the kernel runs `--no-ai`; only the error path was exercised.
- **`historical_logging` enable + read-back**, and `received_a_simulation_case` / `simulation_completed`
  success paths (only their error paths were probed).
- **F-4 on P4.** The mechanism needs a device carrying a switch's management IP to be learned as a
  host; the P4 topology has 4 hosts and I did not check whether the proxy's host table exposes the
  same collision. Worth 10 minutes.
- **Concurrent-writer stress.** Two apps writing flow rules at once, or `install_flow_entry` racing
  the Classifier's sweep. Everything I ran was one writer at a time.
- **Sustained soak.** The longest continuous run was ~1 h on OVS; nothing here speaks to leaks.

## Zero-state reconciliation

Teardown order: tools -> `stack.sh down` -> `ndtwin-lab topo-stop` -> `ndtwin-lab cleanup` (alone),
then reconciled in a separate command.

```
ndtwin_kernel 0   simple_switch 0   ryu-manager 0   proxy_agent 0   testbed_topo 0
network_state_recorder 0   Traffic-engineering-App 0   NetworkTopologyApp 0
energy_saving_app 0   simulation_platform 0   iperf 0   mnexec 0
mininet: process tags 0            ndtwin-lab status: "no lab sessions", bmv2 0, mininet 0
ovs-vsctl list-br: 0 bridges       s*-eth* interfaces: 0
veth: 3   -- the pre-existing docker bridge br-634fc31085ec, present and unchanged since t0
TCP listeners on 8000 / 8080 / 8081 / 6653 / 50050-50060: none
UDP listener on 6343 (sFlow): none
```
Counted with `ps -eo pid,args` filtered against my own shell, **not** `pgrep -cf` — my first attempt
reported `simple_switch: 2` and `ryu-manager: 2` because the `echo` labels in the same command line
contained those literals and pgrep matched my own shell. The bracket trick does not save you when the
unbracketed word appears elsewhere on the line.

**Tracked files:** the only diff is `.vscode/settings.json`, which was already modified before this
session began (it is in the `git status` snapshot taken at t0). I created no tracked files, modified
none, and ran no `git commit`, `git push` or branch change. Everything I wrote is under
`scratch/lab/` (untracked). Two flow rules and one group and one meter entry were installed on live
switches during testing and all four were explicitly removed and verified gone before teardown; the
`tc netem` injection was reverted and the qdisc tree confirmed byte-identical to its pre-injection state.
