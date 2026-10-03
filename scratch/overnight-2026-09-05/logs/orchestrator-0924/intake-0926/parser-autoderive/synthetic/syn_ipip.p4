// Synthetic case: IPv4-in-IPv4 (protocol 4). Two structural IPv4 headers on one path.
// [Co-developed with claude code -- Adam]
#include <core.p4>
#include <v1model.p4>
header ethernet_t { bit<48> dstAddr; bit<48> srcAddr; bit<16> etherType; }
header ipv4_t { bit<4> version; bit<4> ihl; bit<8> diffserv; bit<16> totalLen; bit<16> identification; bit<3> flags; bit<13> fragOffset; bit<8> ttl; bit<8> protocol; bit<16> hdrChecksum; bit<32> srcAddr; bit<32> dstAddr; }
header udp_t { bit<16> srcPort; bit<16> dstPort; bit<16> length_; bit<16> checksum; }
struct headers { ethernet_t ethernet; ipv4_t outer; ipv4_t inner; udp_t udp; }
struct metadata { }
parser P(packet_in pkt, out headers hdr, inout metadata meta, inout standard_metadata_t sm) {
  state start { pkt.extract(hdr.ethernet);
    transition select(hdr.ethernet.etherType) { 0x0800: parse_outer; default: accept; } }
  state parse_outer { pkt.extract(hdr.outer); transition select(hdr.outer.protocol) { 4: parse_inner; 17: parse_udp; default: accept; } }
  state parse_inner { pkt.extract(hdr.inner); transition select(hdr.inner.protocol) { 17: parse_udp; default: accept; } }
  state parse_udp { pkt.extract(hdr.udp); transition accept; }
}
control VC(inout headers hdr, inout metadata meta) { apply { } }
control IG(inout headers hdr, inout metadata meta, inout standard_metadata_t sm) { apply { sm.egress_spec = 1; } }
control EG(inout headers hdr, inout metadata meta, inout standard_metadata_t sm) { apply { } }
control CC(inout headers hdr, inout metadata meta) { apply { } }
control DP(packet_out pkt, in headers hdr) { apply { pkt.emit(hdr); } }
V1Switch(P(), VC(), IG(), EG(), CC(), DP()) main;
