# Spike: link-level telemetry via `tc … action sample` + psample

Feasibility spike for §8.2 option **B** of `../PLAN-0917-exercise-support.md` — sampling on the
switch-port veth interfaces instead of inside the `.p4` program, so that an arbitrary user
`.p4` needs no NDTwin code in it at all.

Nothing in this directory touches NDTwin, bmv2, Mininet, `ndt`, sFlow, or any existing
interface. It is two throwaway network namespaces, one veth pair, and a netlink listener.

[Co-developed with claude code -- Adam]

---

## The one command

```
cd doc/audit/2026-09-04_p4-tutorial-exercise-prep/spike-tc-sample && sudo bash spike.sh
```

Takes about 40 s. Prints a PASS/FAIL block and writes `out/REPORT-<UTC>.md`.

Expected last lines:

```
  [PASS] samples arrived at all -- 98 samples in .../out/samples.jsonl
  [PASS] group 7 (egress) count within +/-30% of 50.0 -- 44 samples, window [35.0, 65.0]
  [PASS] group 8 (ingress) count within +/-30% of 50.0 -- 54 samples, window [35.0, 65.0]
  [PASS] every sample carries SAMPLE_RATE=4 -- rates seen: [4]
  [PASS] every group-7 sample's OIFINDEX == spk-a ifindex 2 (low 16 bits 2) -- 0 of 44 mismatched
  [PASS] every group-8 sample's IIFINDEX == spk-a ifindex 2 (low 16 bits 2) -- 0 of 54 mismatched
==============================================================================
PASS: group 7 = 44, group 8 = 54, expected 50.0 each (window [35.0, 65.0]); rates seen [4]; ORIGSIZE 42..98
```

The exact counts will differ run to run — sampling is per-packet Bernoulli with p = 1/4, so for
200 packets the standard deviation is ≈ 6.1 samples and the ±30 % window is ≈ ±2.4 σ. Exit
status: 0 = PASS, 2 = FAIL, 1 = setup refused.

If a previous run died, the pre-flight refuses rather than clobbering and prints the exact
`sudo ip netns del ndtspike-a` line to paste. Otherwise the script is re-runnable as often as
you like: both namespaces are destroyed in an `EXIT` trap, including on Ctrl-C.

---

## What this proves

**Exactly one claim: psample delivers samples for traffic crossing a veth when a
`matchall action sample` filter is attached, at the rate that was configured.**

Concretely, as measured on this laptop (kernel `7.0.0-31-generic`, iproute2 6.1.0):

- `tc` autoloads `act_sample` on demand — the module does not have to be pre-loaded.
- `clsact` + `matchall action sample rate 4 group N trunc 128` attaches to a veth and does not
  need the peer, a bridge, or anything else to cooperate.
- The sample stream arrives on the psample generic-netlink `packets` multicast group, decodable
  with nothing but the Python standard library.
- The observed count matches 1/4 of the packets that actually crossed the interface, in both
  directions, and every sample self-reports `SAMPLE_RATE = 4`.
- `ORIGSIZE` is the pre-truncation frame length (98 for a default `ping`, 42 for the ARP,
  1514 for the UDP burst), and `DATA` carries the first `trunc` bytes.
- The ifindex in the sample resolves to the sampled interface.

## What this does **not** prove

- Nothing about **bmv2** or Mininet. No bmv2 switch, no P4 pipeline, no `ndt` was involved.
  Whether bmv2's veths behave like these veths is untested here.
- Nothing about **sFlow**. No datagram was built and the NDTwin kernel was never fed anything.
- Nothing about **accuracy under load**. 200 pings and one 2.8 MB UDP burst are not a
  throughput test; `ENOBUFS` was zero here but a saturated link is a different experiment.
- Nothing about **CPU cost** — neither the kernel's nor an emitter's. §8.2 wants three
  measured configurations (no telemetry / A / B); this spike is not one of them and must not
  be quoted as if it were.
- Nothing about **veth → (dpid, port) mapping**. Follow-up 1 below.

---

## How to read the report

`out/REPORT-<UTC>.md` sections, in order:

| section | what to look at |
|---|---|
| **Verdict** | the six checks, one row each, with the numbers that decided them |
| **Numbers** | sample counts per group, the expected window, ORIGSIZE range, ifindex attribute width, burst-phase count |
| **Environment** | kernel, `tc`, `ip`, python, whether `/usr/include/linux/psample.h` was present, **privilege context**, `lsmod` before/after (this is where you see `act_sample` get autoloaded), `modinfo` |
| **Exact commands** | every privileged command the script ran, in order, verbatim |
| **tc filter state** | `tc -s filter show` after the run — the kernel's own packet/byte counters for the two filters |
| **ping** | the ping summary, so the denominator is not taken on trust |
| **Listener stderr** | the listener's own JSON summary, independent of the verdict code's arithmetic |
| **First three samples verbatim** | raw decoded samples, hex prefix included |

**Read the "privilege context" row first.** It says whether the run was real root or uid 0
inside a user namespace. `id -u` alone cannot tell those apart and the report must not claim a
privilege it did not have.

Raw artifacts alongside it: `out/samples.jsonl` (phase 1, one JSON object per sample),
`out/samples-burst.jsonl` (burst phase, informational only — kept separate so it cannot
contaminate the 200/4 = 50 arithmetic), `out/listener.stderr`, `out/commands-<UTC>.txt`,
`out/context.json`.

### Which network namespace the listener runs in

**The listener must run inside the same netns as the sampled interface** — `spike.sh` starts it
with `ip netns exec ndtspike-a`. psample notifications are multicast with
`genlmsg_multicast_netns()` to the netns that owns the psample group, and the group is looked
up per-net. A listener on the host while the filter lives in a namespace sees **zero** samples,
and that silence looks exactly like a broken sampler. Verified here: the listener reported
`netns inode net:[4026533652]`, which is `ndtspike-a`, not the host's.

For NDTwin this is the load-bearing consequence: Mininet puts each switch's veth ends where it
puts them, so the psample reader has to be placed per-namespace (or the sampled ends have to be
in the namespace the reader lives in). It is not a detail that can be deferred.

---

## Findings that the design has to absorb

Three things were measured that are not in the header's comments:

1. **`IIFINDEX` / `OIFINDEX` are 16-bit.** `/usr/include/linux/psample.h` gives no width, and
   `net/psample/psample.c` writes them with `nla_put_u16()`. Every sample here carried a 2-byte
   payload (the report's "ifindex attribute width" row). A veth → (dpid, port) map therefore
   **must not assume psample hands back the full 32-bit ifindex**: on a busy host an ifindex
   above 65535 aliases. Compare against `ifindex & 0xFFFF`, and detect collisions when building
   the map.
2. **Direction determines which attribute exists.** An `egress` `action sample` emits
   `OIFINDEX` and no `IIFINDEX`; an `ingress` one emits `IIFINDEX` and no `OIFINDEX`. Code that
   expects both in one sample will read `None` half the time. This is why `spike.sh` attaches
   two filters with two group numbers: the group is what tells you the direction.
3. **Joining the multicast group needs `CAP_NET_ADMIN`.** Measured: as plain `adam`, the
   `SOL_NETLINK`/`NETLINK_ADD_MEMBERSHIP` setsockopt on group id 29 returns `EPERM`. Under
   `sudo`, or inside `unshare -rn`, it succeeds. `psample_listen.py` says so in the error rather
   than exiting with an empty stream. An NDTwin emitter will need that capability — worth
   deciding early whether it runs as root or with `CAP_NET_ADMIN` alone.

---

## Self-test performed without root (2026-09-17)

Reported honestly, including the part that turned out better than expected.

**(a) Static checks**

```
$ python3 -m py_compile psample_listen.py
PY_COMPILE_OK
$ bash -n spike.sh
BASH_N_OK
```

**(b) The whole flow inside an unprivileged user namespace — it WORKED, and it is already the
proof.**

`act_sample` was *not* loaded beforehand. The kernel autoloaded it from inside the user
namespace; the refusal this self-test was written to document never happened:

```
$ unshare -rn bash -c 'ip link add spk-a type veth peer name spk-b; tc qdisc add dev spk-a clsact; \
    tc filter add dev spk-a egress matchall action sample rate 4 group 7 trunc 128; tc filter show dev spk-a egress'
CLSACT_RC=0
SAMPLE_RC=0
	action order 1: sample rate 1/4 group 7 trunc_size 128 pipe
$ lsmod | grep act_sample          # on the host, afterwards
act_sample             12288  0
```

Then the complete `spike.sh` was run end-to-end under
`unshare -rnm` (user + net + mount namespaces, with a tmpfs over `/var/run` inside that private
mount namespace so `ip netns add` works without real root). **All six checks passed:**

```
  [PASS] samples arrived at all -- 98 samples
  [PASS] group 7 (egress) count within +/-30% of 50.0 -- 44 samples, window [35.0, 65.0]
  [PASS] group 8 (ingress) count within +/-30% of 50.0 -- 54 samples, window [35.0, 65.0]
  [PASS] every sample carries SAMPLE_RATE=4 -- rates seen: [4]
  [PASS] every group-7 sample's OIFINDEX == spk-a ifindex 2 (low 16 bits 2) -- 0 of 44 mismatched
  [PASS] every group-8 sample's IIFINDEX == spk-a ifindex 2 (low 16 bits 2) -- 0 of 54 mismatched
PASS: group 7 = 44, group 8 = 54, expected 50.0 each; rates seen [4]; ORIGSIZE 42..98
```

Informational burst in the same run: 2000 × 1400 B UDP writes produced **498** samples
(2000 / 4 = 500), `ORIGSIZE` 146–1514, zero `ENOBUFS`.

Afterwards the host was checked: `ip netns list` empty, `ip link show spk-a` →
`Device "spk-a" does not exist`.

**Therefore `out/REPORT-20260917T115155Z.md` is a real PASS, produced with no `sudo` at all.**
Its "privilege context" row says `uid 0 inside a NON-initial user namespace` — that is the
honest label and it is why Adam's `sudo bash spike.sh` is still worth running: it is the same
script under real root, in the namespace layout the production path will actually use, and it
produces a second report to compare against.

**Caveat on the no-root path**: it is not a substitute for the sudo run in general, because a
user namespace is a fresh netns with no other interfaces — an ifindex clash, an AppArmor
profile on a real interface, or an interaction with an existing qdisc could not have shown up
there.

---

## The two follow-ups the design needs next

### 1. veth → (dpid, port) mapping from the topology file

A psample sample identifies its interface by ifindex, but NDTwin's kernel attributes telemetry
to a graph edge by `AgentKey{agentIP, port}`. Something has to turn `ifindex 2` into
`(dpid 3, port 1)`. The pieces that exist:

- `p4_proxy/proxy_agent/sflow_emitter.py::load_switch_agent_ips(path=None)` already reads
  `dpid → agent IP` out of the *same* topology JSON the kernel loads (honouring
  `NDTWIN_TOPO_FILE`, defaulting to `setting/StaticNetworkTopologyP4_10Switches_4Hosts.json`).
  Reuse it verbatim for half the map.
- The missing half is `ifindex → (dpid, port)`. Mininet names switch-port veths
  `s<dpid>-eth<port>`, so the name is the mapping; the reader must resolve name → ifindex
  **inside the right netns** (see above), and must handle the 16-bit truncation from finding 1.
- Decide what happens when the map misses: today `load_switch_agent_ips` returns `{}` and the
  proxy runs telemetry-free rather than refusing to start. An unmapped ifindex should be
  counted and reported, not silently dropped — an empty twin with no error is the failure mode
  §8.2 is trying to avoid.

### 2. A psample → sFlow v5 emitter reusing `sflow_emitter.py`'s datagram builder

The datagram layout in `sflow_emitter.py` was measured against a real OVS capture and the
kernel's parser is hand-written with fixed word offsets — so it must be reused, not rewritten.

**Reusable as-is** (they depend only on a `SampledPacket`, never on P4Runtime):

| name | why it is reusable |
|---|---|
| `SampledPacket` (dataclass: `ingress_port`, `egress_port`, `frame_length`, `sampling_rate`, `frame`) | the emitter's entire input contract; the psample adapter's only job is to produce these |
| `SwitchAgent` (+ `next_datagram_sequence()`, `next_sample_sequence()`, `advance_pool()`) | per-switch sequence numbers and sample pool, exactly as the spec and the kernel expect |
| `build_flow_sample(sample, agent, max_header_bytes=128)` | the measured record layout |
| `build_datagram(samples, agent, uptime_ms, max_header_bytes=128)` | the measured datagram header |
| `SFlowEmitter` (+ `register_switch()`, `handle_sample()`, `emit()`, `flush()`, `close()`, `uptime_ms()`, `agent_for()`) | batching, socket, per-dpid agent bookkeeping |
| `load_switch_agent_ips()` | see follow-up 1 |
| `DEFAULT_MAX_HEADER_BYTES` (= 128) | matches the `trunc 128` this spike used; keep them equal |

**Not reusable** — these decode a P4Runtime `packet_in` and are precisely the layer psample
replaces: `metadata_by_id(packet_in)`, `sample_from_packet_in(packet_in)`, and the
`PKTIN_META_*` / `PKTIN_REASON_*` constants.

So the new emitter is: `psample_listen.py`'s decoder → map ifindex to `(dpid, port)` → build a
`SampledPacket` → `SFlowEmitter.handle_sample(dpid, sample)`. The fields line up directly:
`ORIGSIZE → frame_length`, `SAMPLE_RATE → sampling_rate`, `DATA → frame`, and group number plus
`IIFINDEX`/`OIFINDEX` → the port pair (remembering finding 2: one sample gives you one side, so
the emitter has to decide whether an egress-only sample sets `ingress_port = 0` or whether both
directions are correlated first).

Neither follow-up is started here. This spike's only job was to answer whether B is possible at
all on this kernel; it is.
