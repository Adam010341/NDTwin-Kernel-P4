// SPDX-FileCopyrightText: 2018 Nate Foster
// SPDX-License-Identifier: Apache-2.0
/* -*- P4_16 -*- */
/*
 * The tutorials `basic` SOLUTION with NDTwin's cooperative telemetry included, and nothing
 * else changed. TICKET-P3 2.6.
 *
 * [Co-developed with claude code -- Adam]
 *
 * This file is a FIXTURE, not an exercise: its job is to be the evidence that
 * p4_proxy/p4_src/ndtwin_telemetry.p4 is includable by somebody else's program and that the
 * p4info that comes out carries the five `packet_in` field names the proxy looks up by name.
 * tools/p4_exercise/tests/test_telemetry_include.py compiles it (skipping if p4c-bm2-ss is not
 * installed) and reads the result.
 *
 * Every edit against fixtures/basic/solution/basic.p4 is marked `NDTWIN:` below, and there are
 * seven of them -- the five the include's header comment lists, plus the two instantiations.
 * Diff the two files to see that the forwarding logic is untouched: that is the claim being
 * made, that an author keeps their own program and gains a twin.
 */
#include <core.p4>
#include <v1model.p4>

// NDTWIN 1: the include. Must come after v1model -- it uses clone_preserving_field_list,
// random, truncate and standard_metadata.instance_type.
#include "ndtwin_telemetry.p4"

const bit<16> TYPE_IPV4 = 0x800;

/*************************************************************************
*********************** H E A D E R S  ***********************************
*************************************************************************/

typedef bit<9>  egressSpec_t;
typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;

header ethernet_t {
    macAddr_t dstAddr;
    macAddr_t srcAddr;
    bit<16>   etherType;
}

header ipv4_t {
    bit<4>    version;
    bit<4>    ihl;
    bit<8>    diffserv;
    bit<16>   totalLen;
    bit<16>   identification;
    bit<3>    flags;
    bit<13>   fragOffset;
    bit<8>    ttl;
    bit<8>    protocol;
    bit<16>   hdrChecksum;
    ip4Addr_t srcAddr;
    ip4Addr_t dstAddr;
}

struct metadata {
    // NDTWIN 3: the three fields that survive the clone, plus the draw.
    ndtwin_telemetry_t ndtwin;
}

struct headers {
    // NDTWIN 2: the two controller headers, first, because the deparser emits packet_in first.
    packet_out_header_t packet_out;
    packet_in_header_t  packet_in;
    ethernet_t   ethernet;
    ipv4_t       ipv4;
}

/*************************************************************************
*********************** P A R S E R  ***********************************
*************************************************************************/

parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {

    state start {
        // NDTWIN 4: a frame the controller injected carries a packet-out header, and reading it
        // as Ethernet would shift every field by one byte.
        transition select(standard_metadata.ingress_port) {
            NDTWIN_CPU_PORT: parse_ndtwin_packet_out;
            default: parse_ethernet;
        }
    }

    state parse_ndtwin_packet_out {
        packet.extract(hdr.packet_out);
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition accept;
    }

}

/*************************************************************************
************   C H E C K S U M    V E R I F I C A T I O N   *************
*************************************************************************/

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply {  }
}


/*************************************************************************
**************  I N G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {
    // NDTWIN 6: the sampler, instantiated beside the exercise's own tables.
    NdtwinTelemetrySample() ndtwin_sample;

    action drop() {
        mark_to_drop(standard_metadata);
    }

    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
        standard_metadata.egress_spec = port;
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }

    table ipv4_lpm {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            ipv4_forward;
            drop;
            NoAction;
        }
        size = 1024;
        default_action = drop();
    }

    apply {
        if (hdr.ipv4.isValid()) {
            ipv4_lpm.apply();
        }
        // NDTWIN 5a: last, so the sample records the egress port forwarding just chose.
        ndtwin_sample.apply(meta.ndtwin, standard_metadata);
    }
}

/*************************************************************************
****************  E G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {
    // NDTWIN 7: the emitter.
    NdtwinTelemetryEmit() ndtwin_emit;

    apply {
        // NDTWIN 5b: first, and the copy leaves here. `basic` does nothing else in egress, so
        // the `return` guards nothing today -- it is written anyway, because the next program
        // to copy this pattern will have a counter here and would count the clones.
        bool ndtwin_is_sample = false;
        ndtwin_emit.apply(hdr.packet_in, hdr.packet_out, meta.ndtwin, standard_metadata,
                          ndtwin_is_sample);
        if (ndtwin_is_sample) {
            return;
        }
    }
}

/*************************************************************************
*************   C H E C K S U M    C O M P U T A T I O N   **************
*************************************************************************/

control MyComputeChecksum(inout headers  hdr, inout metadata meta) {
     apply {
        update_checksum(
        hdr.ipv4.isValid(),
            { hdr.ipv4.version,
              hdr.ipv4.ihl,
              hdr.ipv4.diffserv,
              hdr.ipv4.totalLen,
              hdr.ipv4.identification,
              hdr.ipv4.flags,
              hdr.ipv4.fragOffset,
              hdr.ipv4.ttl,
              hdr.ipv4.protocol,
              hdr.ipv4.srcAddr,
              hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}

/*************************************************************************
***********************  D E P A R S E R  *******************************
*************************************************************************/

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        // NDTWIN 5c: the controller header first, then the frame as it was received.
        packet.emit(hdr.packet_in);
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
    }
}

/*************************************************************************
***********************  S W I T C H  *******************************
*************************************************************************/

V1Switch(
MyParser(),
MyVerifyChecksum(),
MyIngress(),
MyEgress(),
MyComputeChecksum(),
MyDeparser()
) main;
