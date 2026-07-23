/*
 * NDTwin P4 Data Plane Switch
 * Architecture: v1model
 * Target: BMv2
 */

#include <core.p4>
#include <v1model.p4>

// ===========================================================================
// CONSTANTS
// ===========================================================================
const bit<16> TYPE_IPV4 = 0x0800;
const bit<16> TYPE_LLDP = 0x88CC;
const bit<9>  CPU_PORT  = 255;  // Default BMv2 CPU port for Packet-In/Out

// ===========================================================================
// HEADERS
// ===========================================================================
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

// Custom header for Packet-In (Controller needs to know which ingress port)
@controller_header("packet_in")
header packet_in_header_t {
    bit<9> ingress_port;
    bit<7> _pad;
}

// Custom header for Packet-Out (Controller tells switch which egress port)
@controller_header("packet_out")
header packet_out_header_t {
    bit<9> egress_port;
    bit<7> _pad;
}

struct metadata {
    // Empty for now, can be expanded later
}

struct headers {
    packet_out_header_t packet_out;
    packet_in_header_t  packet_in;
    ethernet_t          ethernet;
    ipv4_t              ipv4;
}

// ===========================================================================
// PARSER
// ===========================================================================
parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {

    state start {
        // If the packet came from the CPU, it has a packet_out header
        transition select(standard_metadata.ingress_port) {
            CPU_PORT: parse_packet_out;
            default: parse_ethernet;
        }
    }

    state parse_packet_out {
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

// ===========================================================================
// CHECKSUM VERIFICATION
// ===========================================================================
control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply {  }
}

// ===========================================================================
// INGRESS PROCESSING
// ===========================================================================
control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {

    action drop() {
        mark_to_drop(standard_metadata);
    }

    action ipv4_forward(macAddr_t dstAddr, bit<9> port) {
        // Set next hop MAC and egress port
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        standard_metadata.egress_spec = port;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }

    action send_to_cpu() {
        // Send unmatched packets to controller
        standard_metadata.egress_spec = CPU_PORT;
        hdr.packet_in.setValid();
        hdr.packet_in.ingress_port = standard_metadata.ingress_port;
    }

    table ipv4_lpm {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            ipv4_forward;
            drop;
            send_to_cpu;
            NoAction;
        }
        size = 1024;
        default_action = send_to_cpu(); // By default, send to controller (Packet-In)
    }

    apply {
        if (hdr.packet_out.isValid()) {
            standard_metadata.egress_spec = hdr.packet_out.egress_port;
        } else if (hdr.ipv4.isValid()) {
            ipv4_lpm.apply();
        } else if (hdr.ethernet.isValid() && hdr.ethernet.etherType == TYPE_LLDP) {
            send_to_cpu();
        }
    }
}

// ===========================================================================
// EGRESS PROCESSING
// ===========================================================================
control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {
                 
    counter(512, CounterType.packets_and_bytes) egress_port_counter;
    
    apply {
        // Count all packets leaving on this egress port
        egress_port_counter.count((bit<32>)standard_metadata.egress_spec);
        
        // If it's a packet out from CPU, we just forward it based on the header
        if (hdr.packet_out.isValid()) {
            hdr.packet_out.setInvalid();
        }
    }
}

// ===========================================================================
// CHECKSUM COMPUTATION
// ===========================================================================
control MyComputeChecksum(inout headers hdr, inout metadata meta) {
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

// ===========================================================================
// DEPARSER
// ===========================================================================
control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        // Emit headers in order (CPU headers first if valid)
        packet.emit(hdr.packet_in);
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
    }
}

// ===========================================================================
// SWITCH INSTANTIATION
// ===========================================================================
V1Switch(
    MyParser(),
    MyVerifyChecksum(),
    MyIngress(),
    MyEgress(),
    MyComputeChecksum(),
    MyDeparser()
) main;

//# Developed in collaboration with Gemini 3.1 Pro.
