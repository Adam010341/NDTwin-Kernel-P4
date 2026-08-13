# P4 Source Code Specification

This directory contains the P4 programs that define the data plane behavior of the BMv2 switches.

## Key Files
- `ndtwin_switch.p4`: The main P4 program written for the V1Model architecture. It defines the packet processing pipeline, including parsing, match-action tables, and deparsing.
- `build/ndtwin_switch.json`: The compiled JSON representation of the P4 program, which is loaded into the `simple_switch_grpc` target.
- `build/ndtwin_switch.p4info.txt`: The P4Runtime interface definition file, detailing the IDs and structures of tables, actions, and fields used by the control plane.

`build/` is gitignored: both artefacts are generated, and must be regenerated whenever
`ndtwin_switch.p4` changes or the switches will run a pipeline that no longer matches the
p4info the proxy loads.

## Data Plane Design

1. **Headers**: Ethernet, IPv4, TCP, UDP, ICMP, plus two controller headers
   (`packet_in`, `packet_out`).

   There are deliberately only two. P4Runtime's reference implementation matches
   `@controller_header` by **name** and recognises `"packet_in"` and `"packet_out"` only
   (`PI/proto/frontend/src/packet_io_mgr.cpp`, `PacketIOMgr::p4_change`). A third header
   compiles into the p4info and is then silently ignored, and every CPU packet is parsed with
   `packet_in`'s width regardless -- so a separate `sample` header would have had its first two
   bytes stripped and reported as an ingress port. Telemetry metadata therefore lives *inside*
   `packet_in`, with a `reason` field distinguishing a sample from a genuine packet-in.

2. **Parser**: Ethernet → IPv4 → L4. L4 is parsed only when `fragOffset == 0`, since the L4
   header appears in the first fragment only. TCP/UDP ports, and ICMP type/code, are lifted
   into metadata (`l4_src_port` / `l4_dst_port`) so the ternary table can key on them without
   reading a header that may be invalid. ICMP type/code occupy the port fields to match how
   the kernel's `FlowKey` represents them (see `doc/2026-01-02_ndt_api.md`).

3. **Ingress Control (`MyIngress`)** applies, in order:
   - `flow_5tuple` — **ternary**, keyed on ingress port, src/dst IPv4, protocol and both L4
     ports, with real P4Runtime priority. This is what NDTwin applications and the Intent
     Translator actually emit. An LPM table cannot express it: LPM has no priority, precedence
     is prefix length, so rules the kernel believed were ordered were not.
   - `ipv4_lpm` — destination-based fallback, unchanged in shape, applied only when the
     ternary table misses.
   - `l2_forward` — exact match on destination MAC, for ARP and other non-IPv4 frames. These
     were previously dropped silently because no `egress_spec` was set, so hosts could not
     resolve each other without the static ARP entries the topology script pre-populates.
   - LLDP goes to the CPU: it is the proxy's link-discovery mechanism.

   `ipv4_forward` checks TTL before decrementing. It used to decrement unconditionally, so a
   packet arriving with TTL 0 wrapped to 255 and could keep circulating.

4. **Telemetry sampling**: 1 packet in `SAMPLE_RATE` (256, matching OVS's `sampling=256` in
   `testbed_topo.py`, so the kernel's rate arithmetic is unchanged) is cloned to the CPU port
   with `clone_preserving_field_list`. Sampling is random rather than every-Nth because that
   is what sFlow's model assumes. Packets already headed for the CPU are never sampled, which
   would otherwise duplicate packet-ins and confuse discovery.

   The clone carries `packet_in` with `reason = PKTIN_REASON_SAMPLE`, plus the ingress port,
   egress port, original frame length and sampling rate — none of which survive on the wire,
   and all of which the sFlow emitter needs. PI turns these into typed P4Runtime metadata, so
   the proxy reads fields by id rather than unpacking bits.

   **The proxy must configure clone session 250** (`SAMPLE_SESSION`) toward the CPU port, or
   bmv2 drops every copy with no error anywhere. `P4RuntimeClient.write_clone_session()` does
   this after `SetForwardingPipelineConfig` — the session belongs to the pipeline's PRE, so
   programming it earlier is discarded. Session ids must be in `[1, 32768)` and
   `class_of_service` must be 0; PI rejects anything else.

5. **Counters**: `direct_counter` on both `flow_5tuple` and `ipv4_lpm`, so per-entry byte and
   packet counts can be reported through `/stats/flow/<dpid>` in the Ryu shape the kernel's
   Classifier expects. A per-port `egress_port_counter` indexed by egress port provides link
   totals. Cloned copies are deliberately excluded from the port counter: they are not real
   egress traffic and would double-count.

6. **Checksum & Deparser**: Recomputes the IPv4 checksum and reassembles the headers.

## Compilation

```bash
p4c-bm2-ss --arch v1model \
  -o build/ndtwin_switch.json \
  --p4runtime-files build/ndtwin_switch.p4info.txt \
  ndtwin_switch.p4
```

Always pass `--p4runtime-files` with that exact path. Without it, `p4c` writes
`ndtwin_switch.p4.p4info.txt` instead, and a second, stale p4info in `build/` is a real
hazard: it looks plausible, the proxy will load it if pointed at it, and any construct missing
from it fails silently — a counter absent from the p4info makes counter reads return `(0, 0)`
rather than erroring. `tools/test_workflow/l0_build_check.sh p4` compiles with the correct
flags.
