// Synthetic negative case: a parser value set (filled by the control plane at runtime)
// [Co-developed with claude code -- Adam]

#include <core.p4>
#include <v1model.p4>
header ethernet_t { bit<48> dstAddr; bit<48> srcAddr; bit<16> etherType; }
header ipv4_t { bit<4> version; bit<4> ihl; bit<8> diffserv; bit<16> totalLen; bit<16> identification; bit<3> flags; bit<13> fragOffset; bit<8> ttl; bit<8> protocol; bit<16> hdrChecksum; bit<32> srcAddr; bit<32> dstAddr; }
header l4_t { bit<16> srcPort; bit<16> dstPort; }

header tun_t { bit<16> proto; bit<16> id; }
struct headers { ethernet_t ethernet; tun_t tun; ipv4_t ipv4; l4_t l4; }
struct metadata { }
parser P(packet_in pkt, out headers hdr, inout metadata meta, inout standard_metadata_t sm) {
  value_set<bit<16>>(4) tunnel_types;
  state start { pkt.extract(hdr.ethernet);
    transition select(hdr.ethernet.etherType) { 0x0800: parse_ipv4; tunnel_types: parse_tun; 0x0bad: reject; default: accept; } }
  state parse_tun { pkt.extract(hdr.tun); transition select(hdr.tun.proto) { 0x0800: parse_ipv4; default: accept; } }
  state parse_ipv4 { pkt.extract(hdr.ipv4); transition accept; }
}

control VC(inout headers hdr, inout metadata meta) { apply { } }
control IG(inout headers hdr, inout metadata meta, inout standard_metadata_t sm) { apply { sm.egress_spec = 1; } }
control EG(inout headers hdr, inout metadata meta, inout standard_metadata_t sm) { apply { } }
control CC(inout headers hdr, inout metadata meta) { apply { } }
control DP(packet_out pkt, in headers hdr) { apply { pkt.emit(hdr); } }
V1Switch(P(), VC(), IG(), EG(), CC(), DP()) main;

