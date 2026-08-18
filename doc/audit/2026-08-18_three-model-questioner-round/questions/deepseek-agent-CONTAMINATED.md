# NDTwin — Operator's Question List (with pre-registered FINE/WORRYING answers)

## 1. Provenance — what I actually read

The scratchpad path given in the task (`/tmp/claude-1000/.../scratchpad/questioner-view`) is not
accessible from my tools (the sandbox refuses it). I therefore read the same material through its
accessible copies in `/home/adam/Desktop/NDTwin-Kernel`. The task described the repo root as
"an API contract document, two topology definition files, and a README". The matching files are:

- **API contract**: `doc/2026-01-02_ndt_api.md` (3,259 lines; `/ndt/*` endpoints §1–§41).
- **Topology file 1 (OVS/Ryu)**: `testbed_topo.py` (10 switches, 128 hosts, TCLink-shaped).
- **Topology file 2 (P4/bmv2)**: `scratch/p4_testbed_topo.py` (same 16 inter-switch links, 4 hosts).
- Also read as close relatives of the topo files: `tools/test_workflow/ovs_4host_topo.py`
  (the OVS "matched cell" that pairs with the P4 one) and `scratch/ntg_bmv2_topo.py`.
- **READMEs**: `doc/README.md` (status of the API doc: 現役/active, 41 endpoints) and
  `tools/test_workflow/README.md` (startup order, convergence conditions, one-shot discovery).
- **Static topology JSONs** (`setting/StaticNetworkTopologyP4_10Switches_4Hosts.json` and the
  OVS twin) — read to pin down dpids 1–10, switch mgmt IPs 192.168.123.11–20, hosts 10.0.0.1–4.
- I additionally read two handoff notes under `~/Documents/NDTwin documentation/` (2026-08-12,
  2026-08-13) which describe the live environment. These are **not part of the four given
  files**; every claim that comes only from them is marked "handoff".

If the actual questioner-view files differ from the copies I read, the questions below still
stand — they are phrased against endpoints and topology facts that all of these agree on
(endpoint names, dpids 1–10 / 106225808…, switch IPs 192.168.123.x, host IPs 10.0.0.x).

## 2. OBSERVED (stated in the documents, with references)

From **`doc/2026-01-02_ndt_api.md`**:

- §3 `GET /ndt/get_graph_data`: nodes carry `is_up`, `is_enabled`, `admin_disabled`; the JSON
  `is_enabled` is the folded value `isEnabled && !adminDisabled` (lines 130–160). In OVS mode
  `is_up` comes from Ryu topology polls plus a `pingWorker` that runs `ovs-vsctl list-br` once a
  second and sets vertices up/down for bridges it finds/misses (164–170). In P4 mode discovery
  marks everything up and real liveness comes from `GET /p4/switch_state`: verdict **Up** if
  `probe_ok == true` regardless of probe age ("a stale success stays Up indefinitely"); **Down**
  only if `probe_ok == false` AND `probe_age_s ≤ 15` AND no fresh LLDP beacon; everything else is
  **Unknown**, which writes nothing to the graph (176–208).
- §3: `src_ip`/`dst_ip` integer fields are 32-bit in **network byte order**; `16777226` is
  `10.0.0.1` (213–223).
- §4 `GET /ndt/get_detected_flow_data`: flows from sFlow with `estimated_flow_sending_rate_bps_*`,
  packet rates, `first_sampled_time`/`latest_sampled_time`, full `path` as [node, interface] hops
  (333–444). §30 top-k variant sorts by the proceeding-timeslot packet rate (2369–2483).
- §5 `GET /ndt/get_switch_openflow_table_entries`: "raw OpenFlow flow table entries directly
  from each switch" (472–514). No P4-mode semantics stated for this endpoint.
- §6 `GET /ndt/get_power_report`: MININET mode values are synthetic but deterministic per dpid,
  30 000–149 999 mW (30–150 W); TESTBED mode is SSH/SNMP from the switch IP (541–584). The doc
  does **not** say what the report does for a switch that has been powered off.
- §7/§8 power state get/set keyed by **switch IP** (612–766). §8: MININET/OVS off = remove the
  OVS bridge; P4 off = stop that one `simple_switch_grpc` via root helper `ndtwin-p4-power`,
  on = relaunch + proxy readopt; failures are reported honestly (500), not faked (689–696).
- §9–§11, §23 flow-entry install/delete/modify: responses return `"status":"queued"` —
  "accepted for programming, **not** programmed"; per-entry outcomes are only in the kernel log
  (768–775). Unknown-dpid contract: all-unknown → 404 with `unknown_dpids`; partial → 200 with
  `rejected`/`rejected_dpids` keys added (777–815).
- §12/§13 CPU/memory and §21 temperature: MININET values are **synthetic and frozen**
  (deterministic per-IP constants), not measurements (1047–1086, 1595–1607).
- §22 `GET /ndt/get_path_switch_count` (per-pair or all pairs; 404 only for a specific pair not
  in the records) — populated via §40 `POST /ndt/inform_all_destination_paths` from Ryu's
  `intelligent_router.py` or the P4 proxy (1654–1750, 3121–3174).
- §24 `GET /ndt/get_average_link_usage`: average over **usable inter-switch links only**
  (`isUp && isEnabled && !adminDisabled`, host-facing links excluded), only links with
  non-zero `link_bandwidth_usage_bps` included (2036–2044).
- §25 sums `link_bandwidth_usage_bps` over edges whose **dst dpid = given dpid** (2087–2110);
  §26 sums the number of flows over the same edges (2138–2160).
- §29 release_lock answers 200 "released" unconditionally, even for a lock you do not hold
  (2353–2366).
- §31–§36 group/meter entry endpoints: **P4 mode returns 501 Not Implemented** for all six
  (2516–2525, 2537–2538, 2747–2750).
- §38 `GET /ndt/get_static_topology_json`: raw topology file, IPs as dotted-quad **strings**,
  no live state (2943–3000).
- §39 historical_logging works (200) even under `--no-ai` — a 2026-08-17 measured correction;
  an older claim said 500 (3033–3039).
- §41 intent_translator: 503 under `--no-ai` (3210–3217).

From **`testbed_topo.py` (OVS)**:

- 10 switches, 128 hosts; edge links bw=1000, aggregation–core links bw=10000 (46–61); hosts on
  s1–s4, ports ≥3 (63–90); switch mgmt IPs 192.168.123.11–.20 (182–204); host IPs 10.0.0.1–128
  with static ARP (212–226).
- sFlow enabled with `sampling=256 polling=0`, and the file's comment states: in MININET mode
  the kernel **discards every counter sample** and derives link utilisation from **flow samples**
  instead; counter samples are only read on the TESTBED path (119–136).
- The same comment records measured behaviour of `getAvgLinkUsage`: h1→h2 (both on dpid 1) reads
  0.0 because the metric counts **switch-to-switch edges only**; cross-fabric traffic reads
  0.166/0.256/0.278 and returns to 0.0 when traffic stops (129–133).

From **`scratch/p4_testbed_topo.py` (P4/bmv2)**:

- Same 16 inter-switch links and port numbers as the OVS topo (223–239); 4 hosts h1–h4 on
  s1–s4 **port 3** (241–254); gRPC ports 50051–50060, thrift 9091–9100, device_id 1–10.
- Per-switch manifest `/tmp/ndtwin_p4_switches.json` (name→pid/ports) exists so one switch can
  be powered off without killing the other nine (16–21).
- Startup verifies each switch is alive **and** its gRPC port accepts connections, reporting
  failures instead of the old unconditional success banner (256–273, 466–479).

From **`tools/test_workflow/ovs_4host_topo.py`** (the OVS matched cell):

- Built specifically so OVS and P4 are compared on the **same** topology (7–37); 4 hosts on
  s1–s4 port 3, same IPs/MACs/ARP/offloads as the P4 side.
- Comment: Ryu learns a host's IP only from packets punted **before** proactive rules are
  installed; `updateHosts` skips hosts with empty ipv4, so those hosts and their edges read
  **down** in the twin while all switches read up (138–164).

From **`tools/test_workflow/README.md`**:

- Startup order differs by mode (Ryu→Mininet→kernel for OVS; bmv2 Mininet→proxy→kernel for P4)
  (88–97).
- `TopologyAndFlowMonitor::run()` pulls the control plane's `/v1.0/topology/*` and destination
  paths **once at startup with no retry loop** — "whatever the control layer doesn't know at
  that moment, the kernel will never know" (112–115).
- Convergence conditions: OVS = 10 switches + 32 links from Ryu + non-empty
  `all_destination_paths` (≥60 s because of a `hub.sleep(60)` in `intelligent_router.py`);
  P4 = 14 nodes in the proxy's path list (117–139).
- Kernel listens on :8000 (components/env context); Mininet is manual (174–177).

From **handoff notes** (outside the four files; live-environment facts, marked as such):

- As of 2026-08-13 the live stack was **P4** (10 bmv2 + proxy + kernel, 40/40 edges up).
- Known unfixed defect: SIGSTOP one bmv2 → `/p4/switch_state` head-of-line-blocks ~60 s
  (normally ~8 ms) → kernel reads **no** switch state → graph drops from 40/40 to 32/40. Single
  failure amplified to fabric-wide state loss; fix pending Adam's choice.
- sFlow is 1/256-sampled; pings need ~500 pps (`-i 0.002`) to reliably produce samples.
- Detected flows age to zero within a few seconds after traffic stops.
- Cut a link with `tc netem loss 100%` on **both ends**, never `ifconfig down` (on bmv2 that
  stops the whole switch's forwarding and produced 3 false link-down reports out of 5).
- The runbook's standing rule: the verdict must include whether **ping actually stopped**, not
  just what the endpoints say.

## 3. INFERRED (my model, not stated anywhere — used to set FINE/WORRYING)

- Because MININET link utilisation is derived from flow samples (topo file comment) and
  §4's flow list is also from sFlow, a busy edge's `flow_set` and the global detected-flow list
  are two views of the **same underlying sample stream** and should agree. (Inference; the
  docs never state this agreement explicitly.)
- A transit switch in steady state should have roughly equal total incoming and total outgoing
  traffic. (Physics, not documented.)
- The live instance the operator is sitting at is most likely P4 mode (handoff, not the files).
- `get_power_report` **ought** to stop billing a powered-off switch (entry gone or ~0); the API
  doc never says what it does, so my pre-registered fine/worrying is my own model of "correct".
- The path shown in `get_detected_flow_data` and the count in `get_path_switch_count` for the
  same host pair should be mutually consistent, since both trace back to the same
  `inform_all_destination_paths` data on the OVS side (§40 description).
- In OVS mode, `is_up` follows the bridge's presence via the 1 Hz `ovs-vsctl list-br` poll, so
  a power-off (bridge removal) should flip `is_up` within ~2 s. (Inference from §3's stated
  mechanism.)
- In P4 mode, a switch that stops answering probes should flip `is_up` to false once a failed
  probe exists with `probe_age_s ≤ 15` and no fresh beacon, i.e. roughly within ~30 s — but the
  documented policy says a **stale success** keeps it Up forever, and the handoff says a hung
  switch can instead take the whole graph down via the shared poll. Both are pre-registered
  below as worrying.

---

## 4. QUESTIONS (ordered: most decisive first)

> Commands assume the kernel is on `localhost:8000`, the 4-host matched cell (10.0.0.1–4) or the
> 128-host topo (10.0.0.1–128); adapt the host pair to whichever topology is loaded.

---

**Q1. When the physical network changes under it — a live link is cut — does the twin's graph,
path and usage picture move with reality, and do the packets agree with the picture?**
  ASK ME TO RUN: Start an iperf3 flow from a host on one edge switch to a host on another
  (e.g. 10.0.0.1 → 10.0.0.4 in the 4-host cell, or 10.0.0.1 → 10.0.0.100 in the 128-host one)
  inside Mininet, with a parallel `ping -i 0.2` as ground truth; from
  `GET /ndt/get_graph_data` pick the inter-switch edge that currently carries the flow
  (usage > 0); cut it on **both ends** with `tc qdisc add dev <eth> root netem loss 100%`;
  sample `get_graph_data` + `get_detected_flow_data` every 2 s for 60 s; then `tc qdisc del`
  on both ends and sample for another 30 s.
  FINE IF: within ~20 s the cut edge reads `is_up: false`, the iperf flow's reported path no
  longer includes that edge (it moves to the alternate route and the surviving edges' usage
  rises), ping loss is only brief, and after restore the edge returns to `is_up: true`.
  WORRYING IF: the twin reports a network that isn't there — either packets have rerouted (ping
  continues) while the twin still shows the cut edge up and the flow on the old path, or the
  twin shows a clean reroute while ping has actually blackholed; both are the silent failure
  this twin exists to prevent.

**Q2. Does a flow entry installed through the write API actually become part of the switch's
real table, and does deleting it actually remove it?**
  ASK ME TO RUN: `POST /ndt/install_flow_entry` for a real switch dpid (take one from
  `get_graph_data`) with a distinctive low-priority match (e.g. `eth_type: 2048`,
  `ipv4_dst: "10.0.0.254"`) and a valid OUTPUT action; wait ~5 s; `GET
  /ndt/get_switch_openflow_table_entries`; then `POST /ndt/delete_flow_entry` for the same
  match; wait ~5 s; read the table again; grep the kernel log around both POSTs for the
  per-entry outcome the doc says is reported there.
  FINE IF: the responses say "queued", the entry appears in the table read within a few
  seconds, the kernel log shows the controller accepted it, and it is gone after the delete.
  WORRYING IF: "queued" is returned but the entry never appears anywhere — or the log says it
  was rejected while the table shows it, or it survives the delete: the write path's 200 is
  then a promise the read path contradicts, silently, and TE would be rerouting with rules
  that were never programmed.

**Q3. When you power a switch off, do the twin's three power/liveness views agree with each
other, and does it stop billing that switch as consuming power?**
  ASK ME TO RUN: Pick a switch carrying the active flow (e.g. s5, mgmt IP 192.168.123.15);
  `POST /ndt/set_switches_power_state?ip=192.168.123.15&action=off`; immediately and at +10 s
  run `GET /ndt/get_graph_data`, `GET /ndt/get_switches_power_state?ip=192.168.123.15`, and
  `GET /ndt/get_power_report`; then `POST …&action=on` and sample all three again.
  FINE IF: either the off is refused with a hard 500 plus a logged reason (helper missing /
  readopt failed — the documented honest failure), or it returns Success and the switch then
  reads `is_up: false` with its edges down, power state "OFF", and `get_power_report` no
  longer lists it at 30–150 W; after `on`, all three return to up / "ON" / listed.
  WORRYING IF: the API says Success but the graph still shows the switch up and its process
  still runs — or the three views disagree (state "OFF" but `is_up: true`, or the power report
  still billing 30–150 W for a switch that is off): Energy-Saving-App would believe it shut a
  switch it didn't, or that an off switch still burns power.

**Q4. [P4 mode only] When one switch hangs rather than dies, does the twin notice exactly that
switch — and does it keep the other nine switches' liveness intact?**
  ASK ME TO RUN: Get one `simple_switch_grpc` PID (via `ps`, not `pgrep -f`), `sudo -n kill
  -STOP <pid>`, then poll `GET /ndt/get_graph_data` every 2 s for 90 s; `sudo -n kill -CONT
  <pid>` and poll another 60 s. (If sudo refuses the kill, skip this question and say so.)
  FINE IF: within ~30 s that one switch — and only its incident edges — flips to
  `is_up: false` while the other nine stay up, and it recovers after CONT.
  WORRYING IF: the hung switch stays `is_up: true` forever (the API doc's documented
  stale-success-stays-Up policy: a dead switch reading "up" indefinitely), **or** the opposite
  failure: the whole graph degrades with many switches flapping down because one unresponsive
  switch stalls the shared `/p4/switch_state` poll (the handoff's known unfixed defect) —
  both directions are a liveness view an operator cannot act on.

**Q5. The graph's per-edge usage/`flow_set` and the detected-flow endpoint describe the same
sFlow stream — do they actually agree?**
  ASK ME TO RUN: With iperf running, take back-to-back snapshots of `GET /ndt/get_graph_data`
  and `GET /ndt/get_detected_flow_data`; for every inter-switch edge with
  `link_bandwidth_usage_bps > 0`, check (a) its `flow_set` is non-empty and every flow in it
  exists in the detected list with the same 5-tuple and similar rate, and (b) that detected
  flow's `path` includes that edge.
  FINE IF: every busy edge's `flow_set` is a subset of the detected flows and the paths and
  rates are consistent.
  WORRYING IF: a busy edge has an empty or stale `flow_set`, or names flows that are absent
  from the detected list, or reports rates wildly different from the flow endpoint: two
  endpoints built from the same measurements would be telling different stories to different
  apps (Visualizer sees one network, Traffic-Engineering another).

**Q6. When the traffic stops, does the twin's picture of traffic stop?**
  ASK ME TO RUN: Stop the iperf from Q1; sample `GET /ndt/get_graph_data` and
  `GET /ndt/get_detected_flow_data` at t=0, +5 s, +15 s, +30 s.
  FINE IF: the edge usage decays to ~0 and the flow disappears from the detected list (or its
  `latest_sampled_time` stops advancing and its rates drop to 0) within ~15 s.
  WORRYING IF: usage/rates stay pinned at their loaded values, or the flow lingers with an old
  timestamp indefinitely: stale traffic data looks confident, and Energy-Saving-App would keep
  declining to power switches down because it still "sees" load that no longer exists.

**Q7. Does the live API honour its own network-byte-order contract for the integer IP fields?**
  ASK ME TO RUN: With the 10.0.0.1 → 10.0.0.4 flow active, read `src_ip`/`dst_ip` from
  `GET /ndt/get_detected_flow_data` (and the host `ip` arrays of `get_graph_data`).
  FINE IF: `src_ip` for 10.0.0.1 is `16777226` and `dst_ip` for 10.0.0.4 is `67108874`
  (the documented network-byte-order-on-little-endian values), consistently.
  WORRYING IF: the values are host-order (`167772161`/`167772164`) or any third encoding:
  every consumer decoding per the contract would be looking at the wrong addresses and making
  routing/power decisions about traffic that isn't the traffic it thinks it sees — and no
  endpoint would error.

**Q8. At the OVS/P4 boundary, do the endpoints honestly refuse what the data plane cannot do,
and does the flow-table read match what is really on the switches?**
  ASK ME TO RUN: On the live instance, `POST /ndt/install_group_entry` with a real dpid,
  `group_id: 1`, type ALL, one OUTPUT bucket, and note the status/body; then
  `GET /ndt/get_switch_openflow_table_entries` and compare its entries against the real
  switches — `ovs-ofctl dump-flows <bridge>` in OVS mode, or in P4 mode whatever the proxy /
  bmv2 actually has programmed.
  FINE IF: on a P4 instance the group call returns **501 Not Implemented** (as §31 documents)
  while on OVS it returns a real success — and in both modes the table endpoint's entries
  correspond to entries that genuinely exist on the data plane.
  WORRYING IF: a P4 instance answers 200 with a plausible success for a group entry (an
  unsupported feature silently "succeeding" — nothing on the data plane would ever match it,
  and nobody would notice), or the table endpoint lists entries the real switches do not have
  (a cached table being served as live).

**Q9. Is every hop a flow is reported to take an edge that actually exists in the graph, and do
the two path views agree on how many switches the path has?**
  ASK ME TO RUN: Take the active flow's `path` from `get_detected_flow_data`; for each
  consecutive hop check that (node, out-interface) of hop i and the node of hop i+1 form an
  edge that exists in `get_graph_data` (host side has dpid 0); then call
  `GET /ndt/get_path_switch_count?src_ip=10.0.0.1&dst_ip=10.0.0.4` and count the switch nodes
  in the flow's path.
  FINE IF: every hop matches a real edge and `switch_count` equals the number of switches in
  the path the twin itself reports for that flow.
  WORRYING IF: a path names an edge or interface that isn't in the graph (paths computed
  against a stale or different topology), or the count disagrees with the switches actually
  traversed, or the pair 404s while traffic demonstrably flows between them: Traffic-
  Engineering would be rerouting around links, or across lengths, that don't exist.

**Q10. Does `get_average_link_usage` equal what the graph itself says, computed the way the
doc defines it?**
  ASK ME TO RUN: From one `get_graph_data` snapshot, recompute by hand the average of
  `link_bandwidth_usage_bps` (as % of capacity) over inter-switch edges that are
  `is_up: true`, `is_enabled: true`, `admin_disabled: false` and usage > 0 — host-facing
  edges excluded — then call `GET /ndt/get_average_link_usage` and compare.
  FINE IF: the endpoint matches your recomputation within rounding.
  WORRYING IF: it differs in a way that suggests it included host-facing links, zero-usage
  links or disabled links — or it is frozen while the graph moves: the single number
  Energy-Saving-App reads would be computed from a different network than the graph describes.

**Q11. Is the type of the node `ip` arrays in `get_graph_data` consistent across every node?**
  ASK ME TO RUN: `GET /ndt/get_graph_data` and list the `ip` values of every node (switches
  and hosts); `GET /ndt/get_static_topology_json` for comparison.
  FINE IF: every node's `ip` values are the same type everywhere (integers, as in the doc's
  worked example), consistently.
  WORRYING IF: some nodes carry integer IPs and others dotted-quad strings (or all strings
  where the worked example shows integers): a consumer written for the documented shape
  breaks on some nodes only — intermittent, input-dependent, and silent until an app mislabels
  a host.

---
## 5. THE SINGLE THING I would most want to see with my own eyes

A side-by-side, same-timestamp capture during one link cut under load: the packets on one side
(`tcpdump`/`ping -i 0.2` inside Mininet, with wall-clock timestamps) and `get_graph_data` +
`get_detected_flow_data` on the other — the moment the world changes, do the twin's is_up,
path, and usage numbers move when the packets move, and in the same direction? Everything else
is a slower, weaker version of that one question.
