// Synthetic negative case: a select on metadata derived from ingress_port
// [Co-developed with claude code -- Adam]

#include <core.p4>
#include <v1model.p4>
header ethernet_t { bit<48> dstAddr; bit<48> srcAddr; bit<16> etherType; }
header ipv4_t { bit<4> version; bit<4> ihl; bit<8> diffserv; bit<16> totalLen; bit<16> identification; bit<3> flags; bit<13> fragOffset; bit<8> ttl; bit<8> protocol; bit<16> hdrChecksum; bit<32> srcAddr; bit<32> dstAddr; }
header l4_t { bit<16> srcPort; bit<16> dstPort; }

header tun_t { bit<16> proto; bit<16> id; }
struct headers { ethernet_t ethernet; tun_t tun; ipv4_t ipv4; }
struct metadata { bit<1> from_core; }
parser P(packet_in pkt, out headers hdr, inout metadata meta, inout standard_metadata_t sm) {
  state start { meta.from_core = (sm.ingress_port >= 3) ? 1w1 : 1w0; pkt.extract(hdr.ethernet);
    transition select(meta.from_core, hdr.ethernet.etherType) { (1, 0x88b5): parse_tun; (_, 0x0800): parse_ipv4; default: accept; } }
  state parse_tun { pkt.extract(hdr.tun); transition parse_ipv4; }
  state parse_ipv4 { pkt.extract(hdr.ipv4); transition accept; }
}

control VC(inout headers hdr, inout metadata meta) { apply { } }
control IG(inout headers hdr, inout metadata meta, inout standard_metadata_t sm) { apply { sm.egress_spec = 1; } }
control EG(inout headers hdr, inout metadata meta, inout standard_metadata_t sm) { apply { } }
control CC(inout headers hdr, inout metadata meta) { apply { } }
control DP(packet_out pkt, in headers hdr) { apply { pkt.emit(hdr); } }
V1Switch(P(), VC(), IG(), EG(), CC(), DP()) main;

