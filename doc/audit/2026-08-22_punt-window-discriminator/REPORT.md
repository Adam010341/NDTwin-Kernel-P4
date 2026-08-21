# Why Ryu never learns host IPv4 after boot: the learning window closes when the rules land

[Co-developed with claude code -- Adam]

Run 2026-08-22 00:02 at `f05da99` by the review session, OVS plane, 128 hosts, settle=10
(the committed default). Raw output `t6_punt_window.txt`, script `t6_punt_window.sh`.

## The question this closes

`2026-08-21_bringup-manual-verification/README.md` §1b recorded a three-way contradiction it
declared unresolvable: today 0/128 hosts have IPv4 in Ryu (so 256 host edges stay down),
a prior record says 128/128, and `TopologyAndFlowMonitor.cpp`'s comment says a ping burst
teaches Ryu — "三者不可能都對". The macro arms were already both measured on 2026-08-21:
settle=10 → 0/128 persisting ≥4 min; settle=60 (the L4 baseline capture) → 128/128 with IPs.
What was missing was the mechanism. This is the intervention that pins it.

## Design

One boot, one variable. The host tracker's only IPv4 source is packet-ins, so the same ping
is sent twice — once when it cannot punt, once when it must:

* **control arm** — rules intact: `h1 → 10.0.0.33`, delivered in the data plane end to end.
* **test arm** — delete s1's `ipv4_dst=10.0.0.33` rule over Ryu REST (deletion asserted,
  1 → 0), then the same ping. First packet misses table 0 and hits the priority-0
  `OUTPUT:CONTROLLER` entry (confirmed present before the test).

## Result

| step | hosts with ipv4 |
|---|---|
| after boot (settle=10) | **0/128** |
| after 3/3 delivered pings, rules intact | **0/128** |
| after 5 punted pings (100% loss — the static app does not reactive-forward) | **1/128 — exactly `10.0.0.1`, the packet-in's src** |

Bonus, end to end: 35 s later the kernel graph shows host edges up **0 → 2/256** — precisely
h1's two directed edges. The kernel-side chain (`updateHosts` → `findEdgeByHostIp`) works the
moment an IPv4 exists; the whole 256-edges-down regression is upstream of the kernel.

## What this establishes

1. **The learning window is [switch connect, all-pairs install] — i.e. the settle window.**
   After install, IPv4 traffic matches proactive rules and never punts (control arm); static
   ARP (set by `testbed_topo.py`) closes the ARP path permanently. Nothing can teach Ryu a
   host after the window shuts, which is why waiting longer and "灌真流量" both do nothing.
2. **The three "irreconcilable" observations are one mechanism at three settings.**
   settle=60 catches `testbed_topo.py`'s own post-build ping burst → 128/128 (the 2026-08-07
   record, and again tonight's L4 baseline). settle=10 misses it → 0/128. The cpp comment
   "ping burst teaches Ryu" is true only inside the window. Remaining loose end: 07-29's
   1/128 *at settle 60* — consistent in kind (one host punted in-window) and that epoch's
   start orchestration differed; not re-litigated here.
3. **The planned fix direction is sound, with one requirement.** C3's "把固定 settle 換成等
   Ryu 真的學到 host" works only because the wait extends the pre-install window — and it
   must *actively ping inside the window* (or wait for the topo's burst) or it will wait
   forever on a quiet fabric. A fix that waits after install would wait forever, period.
4. Side-observation, known family: a rule deleted out-of-band (REST, no link event) is not
   reinstalled — traffic to that destination blackholes at the controller (5/5 lost) until a
   topology event triggers `_route_reinstall_worker`. Same shape as "rejected requests still
   act": the twin's route table and the switch's diverge silently.

## Files

| file | what |
|---|---|
| `t6_punt_window.sh` | the intervention, teardown included; claims the lab under `review-0821` |
| `t6_punt_window.txt` | raw output of the run this report quotes |
