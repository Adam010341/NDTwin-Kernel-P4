// SPDX-License-Identifier: Apache-2.0
// [Co-developed with claude code -- Adam]
//
// TICKET-P4-roles section 2.2-6: a destination-route table in which EVERY name differs from
// ndtwin_switch.p4's. tutorials' `basic` declares MyIngress.ipv4_lpm / hdr.ipv4.dstAddr /
// MyIngress.ipv4_forward(dstAddr, port) -- character for character NDTwin's own five names --
// so a test run only on basic cannot tell code that reads the binding from code that still
// spells the literals. Here the table, the match field, the action and both parameters are
// renamed, the parameters are declared in the OTHER order (port first, so their p4info ids are
// swapped relative to NDTwin's), and the port is bit<8> rather than bit<9> (so it goes on the
// wire in one byte, not two). A second table with an action no renderer knows is here for the
// flow-stats half of the ticket.
//
// Structurally tutorials' basic.p4 (SPDX-FileCopyrightText: 2018 Nate Foster); compiled with
//   p4c-bm2-ss --p4v 16 --p4runtime-files build/renamed_route.p4.p4info.txtpb \
//              -o build/renamed_route.json renamed_route.p4
// from inside this directory, so the json's `program` is relative.
#include <core.p4>
#include <v1model.p4>

const bit<16> ETHERTYPE_IP4 = 0x800;

header eth_t {
    bit<48> dst_mac;
    bit<48> src_mac;
    bit<16> ethertype;
}

header ip4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  tos;
    bit<16> total_len;
    bit<16> ident;
    bit<3>  flags;
    bit<13> frag;
    bit<8>  ttl;
    bit<8>  proto;
    bit<16> csum;
    bit<32> src;
    bit<32> dst;
}

struct meta_t { }

struct hdrs_t {
    eth_t eth;
    ip4_t ip4;
}

parser RouteParser(packet_in packet, out hdrs_t hdr, inout meta_t meta,
                   inout standard_metadata_t standard_metadata) {
    state start {
        packet.extract(hdr.eth);
        transition select(hdr.eth.ethertype) {
            ETHERTYPE_IP4: parse_ip4;
            default: accept;
        }
    }
    state parse_ip4 {
        packet.extract(hdr.ip4);
        transition accept;
    }
}

control RouteVerify(inout hdrs_t hdr, inout meta_t meta) {
    apply { }
}

control RouteIngress(inout hdrs_t hdr, inout meta_t meta,
                     inout standard_metadata_t standard_metadata) {
    action discard() {
        mark_to_drop(standard_metadata);
    }

    action send_via(bit<8> out_port, bit<48> next_mac) {
        standard_metadata.egress_spec = (bit<9>) out_port;
        hdr.eth.src_mac = hdr.eth.dst_mac;
        hdr.eth.dst_mac = next_mac;
        hdr.ip4.ttl = hdr.ip4.ttl - 1;
    }

    action tag_proto(bit<8> tag) {
        hdr.ip4.tos = tag;
    }

    table dest_routes {
        key = {
            hdr.ip4.dst: lpm;
        }
        actions = {
            send_via;
            discard;
            NoAction;
        }
        size = 1024;
        default_action = discard();
    }

    table proto_tags {
        key = {
            hdr.ip4.proto: exact;
        }
        actions = {
            tag_proto;
            NoAction;
        }
        size = 16;
        default_action = NoAction();
    }

    apply {
        if (hdr.ip4.isValid()) {
            proto_tags.apply();
            dest_routes.apply();
        }
    }
}

control RouteEgress(inout hdrs_t hdr, inout meta_t meta,
                    inout standard_metadata_t standard_metadata) {
    apply { }
}

control RouteChecksum(inout hdrs_t hdr, inout meta_t meta) {
    apply {
        update_checksum(
            hdr.ip4.isValid(),
            { hdr.ip4.version, hdr.ip4.ihl, hdr.ip4.tos, hdr.ip4.total_len, hdr.ip4.ident,
              hdr.ip4.flags, hdr.ip4.frag, hdr.ip4.ttl, hdr.ip4.proto, hdr.ip4.src,
              hdr.ip4.dst },
            hdr.ip4.csum,
            HashAlgorithm.csum16);
    }
}

control RouteDeparser(packet_out packet, in hdrs_t hdr) {
    apply {
        packet.emit(hdr.eth);
        packet.emit(hdr.ip4);
    }
}

V1Switch(RouteParser(), RouteVerify(), RouteIngress(), RouteEgress(), RouteChecksum(),
         RouteDeparser()) main;
