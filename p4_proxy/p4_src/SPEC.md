# P4 Source Code Specification

This directory contains the P4 programs that define the data plane behavior of the BMv2 switches.

## Key Files
- `ndtwin_switch.p4`: The main P4 program written for the V1Model architecture. It defines the packet processing pipeline, including parsing, match-action tables, and deparsing.
- `build/ndtwin_switch.json`: The compiled JSON representation of the P4 program, which is loaded into the `simple_switch_grpc` target.
- `build/ndtwin_switch.p4info.txt`: The P4Runtime interface definition file, detailing the IDs and structures of tables, actions, and fields used by the control plane.

## Data Plane Design
1. **Headers**: Defines Ethernet and IPv4 headers.
2. **Parser**: Parses Ethernet and IPv4 headers based on EtherType.
3. **Ingress Control (`MyIngress`)**:
   - Contains the `ipv4_lpm` table.
   - Matches on `hdr.ipv4.dstAddr` (Longest Prefix Match).
   - Actions include `ipv4_forward` (modifies MAC addresses, decrements TTL, and sets egress port) and `drop`.
4. **Egress Control (`MyEgress`)**: Currently passes packets through without modification.
5. **Checksum & Deparser**: Recomputes IPv4 checksums and reassembles the packet headers.

## Compilation
To compile the P4 code, use the `p4c-bm2-ss` compiler (provided by the `p4lang/p4c` toolchain):
```bash
p4c-bm2-ss --p4v 16 --p4runtime-files build/ndtwin_switch.p4info.txt -o build/ndtwin_switch.json ndtwin_switch.p4
```
