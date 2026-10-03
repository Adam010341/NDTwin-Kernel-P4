// Synthetic case: IPv4 options as varbit, length computed from ihl (evaluable from bytes)
// [Co-developed with claude code -- Adam]

#include <core.p4>
#include <v1model.p4>
header ethernet_t { bit<48> dstAddr; bit<48> srcAddr; bit<16> etherType; }
header ipv4_t { bit<4> version; bit<4> ihl; bit<8> diffserv; bit<16> totalLen; bit<16> identification; bit<3> flags; bit<13> fragOffset; bit<8> ttl; bit<8> protocol; bit<16> hdrChecksum; bit<32> srcAddr; bit<32> dstAddr; }
header l4_t { bit<16> srcPort; bit<16> dstPort; }

header ipv4_opts_t { varbit<320> options; }
header tcp_t { bit<16> srcPort; bit<16> dstPort; bit<32> seqNo; bit<32> ackNo; bit<4> dataOffset; bit<4> res; bit<8> flags; bit<16> window; bit<16> checksum; bit<16> urgentPtr; }
header udp_t { bit<16> srcPort; bit<16> dstPort; bit<16> length_; bit<16> checksum; }
struct headers { ethernet_t ethernet; ipv4_t ipv4; ipv4_opts_t opts; tcp_t tcp; udp_t udp; }
struct metadata { }
parser P(packet_in pkt, out headers hdr, inout metadata meta, inout standard_metadata_t sm) {
  state start { pkt.extract(hdr.ethernet);
    transition select(hdr.ethernet.etherType) { 0x0800: parse_ipv4; default: accept; } }
  state parse_ipv4 { pkt.extract(hdr.ipv4);
    pkt.extract(hdr.opts, (bit<32>)(((bit<16>)hdr.ipv4.ihl - 5) * 32));
    transition select(hdr.ipv4.protocol) { 6: parse_tcp; 17: parse_udp; default: accept; } }
  state parse_tcp { pkt.extract(hdr.tcp); transition accept; }
  state parse_udp { pkt.extract(hdr.udp); transition accept; }
}

control VC(inout headers hdr, inout metadata meta) { apply { } }
control IG(inout headers hdr, inout metadata meta, inout standard_metadata_t sm) { apply { sm.egress_spec = 1; } }
control EG(inout headers hdr, inout metadata meta, inout standard_metadata_t sm) { apply { } }
control CC(inout headers hdr, inout metadata meta) { apply { } }
control DP(packet_out pkt, in headers hdr) { apply { pkt.emit(hdr); } }
V1Switch(P(), VC(), IG(), EG(), CC(), DP()) main;

