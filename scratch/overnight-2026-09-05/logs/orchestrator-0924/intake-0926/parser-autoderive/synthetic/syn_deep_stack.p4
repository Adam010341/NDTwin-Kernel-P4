// Synthetic limit case: 16-byte telemetry entries in front of IPv4 (INT-like), up to 8 of them
// [Co-developed with claude code -- Adam]

#include <core.p4>
#include <v1model.p4>
header ethernet_t { bit<48> dstAddr; bit<48> srcAddr; bit<16> etherType; }
header ipv4_t { bit<4> version; bit<4> ihl; bit<8> diffserv; bit<16> totalLen; bit<16> identification; bit<3> flags; bit<13> fragOffset; bit<8> ttl; bit<8> protocol; bit<16> hdrChecksum; bit<32> srcAddr; bit<32> dstAddr; }
header l4_t { bit<16> srcPort; bit<16> dstPort; }

header hop_t { bit<1> last; bit<7> hop; bit<8> pad; bit<16> port; bit<32> qdepth; bit<64> ts; }
struct headers { ethernet_t ethernet; hop_t[8] hops; ipv4_t ipv4; l4_t l4; }
struct metadata { }
parser P(packet_in pkt, out headers hdr, inout metadata meta, inout standard_metadata_t sm) {
  state start { pkt.extract(hdr.ethernet);
    transition select(hdr.ethernet.etherType) { 0x0800: parse_ipv4; 0x1235: parse_hop; default: accept; } }
  state parse_hop { pkt.extract(hdr.hops.next); transition select(hdr.hops.last.last) { 1: parse_ipv4; default: parse_hop; } }
  state parse_ipv4 { pkt.extract(hdr.ipv4); transition select(hdr.ipv4.protocol) { 17: parse_l4; default: accept; } }
  state parse_l4 { pkt.extract(hdr.l4); transition accept; }
}

control VC(inout headers hdr, inout metadata meta) { apply { } }
control IG(inout headers hdr, inout metadata meta, inout standard_metadata_t sm) { apply { sm.egress_spec = 1; } }
control EG(inout headers hdr, inout metadata meta, inout standard_metadata_t sm) { apply { } }
control CC(inout headers hdr, inout metadata meta) { apply { } }
control DP(packet_out pkt, in headers hdr) { apply { pkt.emit(hdr); } }
V1Switch(P(), VC(), IG(), EG(), CC(), DP()) main;

