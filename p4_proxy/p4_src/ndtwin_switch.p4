/*
 * NDTwin P4 Data Plane Switch
 * Architecture: v1model
 * Target: BMv2
 *
 * Phase 4 of doc/2026-07-27_p4_bmv2_support_plan.md.
 *
 * [Co-developed with claude code -- Adam]
 *
 * What changed and why:
 *
 *  - L4 is parsed (TCP/UDP/ICMP) and ARP is handled. Previously only Ethernet and IPv4 were
 *    parsed, so NDTwin's 5-tuple rules could not be expressed at all, and ARP -- along with
 *    every other non-IPv4 frame -- was silently dropped because no egress_spec was set.
 *
 *  - A ternary flow_5tuple table with real priority sits in front of ipv4_lpm. LPM tables
 *    have no priority concept: precedence is prefix length, so two rules the kernel believed
 *    were ordered were not. Applications and the Intent Translator emit OpenFlow 5-tuple
 *    matches with priorities, and those now translate faithfully.
 *
 *  - Sampled copies of traffic are cloned to the CPU port at 1/256, carrying the ingress
 *    port, egress port and original frame length. This is what feeds the sFlow emitter in
 *    Phase 5; the rate matches OVS's sampling=256 so the kernel's rate arithmetic is
 *    unchanged. Sampling is random rather than every-Nth because that is what sFlow's model
 *    assumes.
 *
 *  - TTL is checked before decrementing. It was decremented unconditionally, so a packet
 *    arriving with TTL 0 wrapped to 255 and could circulate.
 */

#include <core.p4>
#include <v1model.p4>

// ===========================================================================
// CONSTANTS
// ===========================================================================
const bit<16> TYPE_IPV4 = 0x0800;
const bit<16> TYPE_ARP  = 0x0806;
const bit<16> TYPE_LLDP = 0x88CC;

const bit<8>  IP_PROTO_ICMP = 1;
const bit<8>  IP_PROTO_TCP  = 6;
const bit<8>  IP_PROTO_UDP  = 17;

const bit<9>  CPU_PORT = 255;  // Default BMv2 CPU port for Packet-In/Out

// Mirror session the proxy agent must configure; sampled copies are cloned here.
const bit<32> SAMPLE_SESSION = 250;

// Sample 1 in SAMPLE_RATE packets. Matches OVS's sampling=256 in testbed_topo.py, so the
// kernel's existing rate calculations apply unchanged.
const bit<16> SAMPLE_RATE = 256;

// Bytes of each sampled copy actually sent to the CPU port. The rest is discarded in egress,
// before the copy ever reaches the proxy.
//
// [Co-developed with claude code -- Adam]
// WHY. The 08-25 ladder measured the ceiling: at 1-in-8 the receiver starts losing real traffic
// (5.1%, then 45.3 / 70.8 / 85.2 climbing to 1-in-1), and the per-process CPU says the proxy
// plateaus at ~145% exactly there while bmv2 PEAKS at 206% and then falls -- starved, not
// saturated. So the wall is the telemetry pipeline, and until now every sampled copy carried a
// full 1442 B frame the proxy had to read.
//
// SAFE FOR THE RATE MATHS. sFlow needs the ORIGINAL frame length, and that travels in
// meta.sample_frame_length -> hdr.packet_in.frame_length, which is set from ingress metadata and
// is unaffected by how many bytes of payload survive. Truncating changes what is copied, not
// what is reported.
//
// 🔴 NOT THE SAME KNOB AS THE ONE THAT FAILED. bmv2's runtime `packet_length_bytes=128` on the
// mirror session was measured on 08-20 and silently killed telemetry outright (every edge read
// zero, no error anywhere). This is the P4 `truncate()` extern, a different mechanism -- but it
// has the same failure MODE, so PREREG-D §2 requires a 1/256 cell to pass (ratio ~= 1.00, samples
// non-zero) plus independent proof that truncation actually happened, BEFORE climbing.
const bit<32> SAMPLE_TRUNC_BYTES = 128;

// Index of the metadata field list preserved across the ingress-to-egress clone.
const bit<8> FL_SAMPLE = 1;

// Why a packet reached the controller. Lets the proxy dispatch on metadata rather than
// guessing from the frame.
const bit<8> PKTIN_REASON_PACKET_IN = 0;   // unmatched packet, or an LLDP beacon
const bit<8> PKTIN_REASON_SAMPLE    = 1;   // telemetry sample, for the sFlow emitter

// bmv2's instance_type values. v1model.p4 documents but does not declare these, so programs
// define them themselves; 1 is an ingress-to-egress clone, i.e. one of our sampled copies.
const bit<32> BMV2_INSTANCE_TYPE_INGRESS_CLONE = 1;

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

header tcp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<32> seqNo;
    bit<32> ackNo;
    bit<4>  dataOffset;
    bit<4>  res;
    bit<8>  flags;
    bit<16> window;
    bit<16> checksum;
    bit<16> urgentPtr;
}

header udp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<16> length_;
    bit<16> checksum;
}

header icmp_t {
    bit<8>  icmpType;
    bit<8>  icmpCode;
    bit<16> checksum;
}

/*
 * Custom header for Packet-In.
 *
 * This carries telemetry samples as well as genuine packet-ins, distinguished by `reason`.
 * They cannot be separate controller headers: P4Runtime's reference implementation matches
 * @controller_header by *name* and recognises only "packet_in" and "packet_out"
 * (PI/proto/frontend/src/packet_io_mgr.cpp, PacketIOMgr::p4_change). A third header compiles
 * into the p4info and is then silently ignored, so every CPU packet would be parsed with this
 * header's width regardless -- stripping the wrong number of bytes off a sample and reporting
 * them as an ingress port. Folding the fields in here means PI hands the proxy typed metadata
 * and no byte-level unpacking is needed on either side.
 *
 * egress_port, frame_length and sampling_rate are meaningful for samples only, and zero
 * otherwise.
 */
@controller_header("packet_in")
header packet_in_header_t {
    bit<8>  reason;
    bit<9>  ingress_port;
    bit<9>  egress_port;
    bit<16> frame_length;   // original length, before any truncation
    bit<16> sampling_rate;  // so the emitter reports what the switch actually used
    bit<6>  _pad;           // 8+9+9+16+16+6 = 64 bits, a whole number of bytes
}

// Custom header for Packet-Out (controller tells the switch which egress port)
@controller_header("packet_out")
header packet_out_header_t {
    bit<9> egress_port;
    bit<7> _pad;
}

struct metadata {
    // Preserved across the clone so egress can populate sample_header. Ingress metadata is
    // otherwise not visible to the cloned copy.
    @field_list(FL_SAMPLE)
    bit<9>  sample_ingress_port;
    @field_list(FL_SAMPLE)
    bit<9>  sample_egress_port;
    @field_list(FL_SAMPLE)
    bit<16> sample_frame_length;

    // L4 ports lifted out of whichever L4 header is present, so the ternary table can key on
    // them uniformly. Zero for ICMP and for unparsed protocols -- keying directly on
    // hdr.tcp.srcPort would read an invalid header for a UDP or ICMP packet.
    bit<16> l4_src_port;
    bit<16> l4_dst_port;

    bit<16> sample_rand;
}

struct headers {
    packet_out_header_t packet_out;
    packet_in_header_t  packet_in;
    ethernet_t          ethernet;
    ipv4_t              ipv4;
    tcp_t               tcp;
    udp_t               udp;
    icmp_t              icmp;
}

// ===========================================================================
// PARSER
// ===========================================================================
parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {

    state start {
        meta.l4_src_port = 0;
        meta.l4_dst_port = 0;
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
            default: accept;   // ARP, LLDP, IPv6: forwarded by the ingress logic below
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        // Only parse L4 for unfragmented packets: a non-zero fragment offset means the L4
        // header is in the first fragment only, so reading it here would consume payload.
        transition select(hdr.ipv4.fragOffset, hdr.ipv4.protocol) {
            (0, IP_PROTO_TCP):  parse_tcp;
            (0, IP_PROTO_UDP):  parse_udp;
            (0, IP_PROTO_ICMP): parse_icmp;
            default: accept;
        }
    }

    state parse_tcp {
        packet.extract(hdr.tcp);
        meta.l4_src_port = hdr.tcp.srcPort;
        meta.l4_dst_port = hdr.tcp.dstPort;
        transition accept;
    }

    state parse_udp {
        packet.extract(hdr.udp);
        meta.l4_src_port = hdr.udp.srcPort;
        meta.l4_dst_port = hdr.udp.dstPort;
        transition accept;
    }

    state parse_icmp {
        packet.extract(hdr.icmp);
        // The kernel's FlowKey carries ICMP type/code in the port fields (see
        // doc/2026-01-02_ndt_api.md), so mirroring that here keeps the two consistent.
        meta.l4_src_port = (bit<16>)hdr.icmp.icmpType;
        meta.l4_dst_port = (bit<16>)hdr.icmp.icmpCode;
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

    // Per-table counters, so the proxy can report per-entry byte/packet counts through
    // /stats/flow/<dpid> in the Ryu shape the Classifier expects.
    direct_counter(CounterType.packets_and_bytes) flow_5tuple_counter;
    direct_counter(CounterType.packets_and_bytes) ipv4_lpm_counter;

    action drop() {
        mark_to_drop(standard_metadata);
    }

    action ipv4_forward(macAddr_t dstAddr, bit<9> port) {
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        standard_metadata.egress_spec = port;
        // Guard the decrement: this was unconditional, so a packet arriving with TTL 0
        // wrapped to 255 and could keep circulating.
        if (hdr.ipv4.ttl > 0) {
            hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
        }
    }

    /// Forwarding that does not rewrite L2, for frames with no IPv4 header (ARP).
    action forward_l2(bit<9> port) {
        standard_metadata.egress_spec = port;
    }

    action send_to_cpu() {
        standard_metadata.egress_spec = CPU_PORT;
        hdr.packet_in.setValid();
        hdr.packet_in.reason = PKTIN_REASON_PACKET_IN;
        hdr.packet_in.ingress_port = standard_metadata.ingress_port;
        // Sample-only fields. Set explicitly: an uninitialised header field is undefined in
        // P4, so leaving them out would send the proxy arbitrary values.
        hdr.packet_in.egress_port = 0;
        hdr.packet_in.frame_length = 0;
        hdr.packet_in.sampling_rate = 0;
        hdr.packet_in._pad = 0;
    }

    /*
     * Ternary 5-tuple table with genuine priority, in front of the LPM table.
     *
     * Keys are the fields NDTwin applications actually match on. in_port is included because
     * OpenFlow rules may scope a match to an ingress port. Ports come from metadata rather
     * than the L4 headers directly, so an ICMP or fragmented packet does not read an invalid
     * header.
     */
    table flow_5tuple {
        key = {
            standard_metadata.ingress_port: ternary;
            hdr.ipv4.srcAddr:               ternary;
            hdr.ipv4.dstAddr:               ternary;
            hdr.ipv4.protocol:              ternary;
            meta.l4_src_port:               ternary;
            meta.l4_dst_port:               ternary;
        }
        actions = {
            ipv4_forward;
            drop;
            send_to_cpu;
            NoAction;
        }
        size = 1024;
        default_action = NoAction();   // fall through to ipv4_lpm
        counters = flow_5tuple_counter;
    }

    /// Destination-based fallback, unchanged in shape so existing rules keep working.
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
        default_action = send_to_cpu();
        counters = ipv4_lpm_counter;
    }

    /// ARP and other non-IPv4 frames the fabric still has to carry.
    table l2_forward {
        key = {
            hdr.ethernet.dstAddr: exact;
        }
        actions = {
            forward_l2;
            send_to_cpu;
            drop;
            NoAction;
        }
        size = 512;
        // Unknown L2 destinations go to the controller, which can learn or flood. Previously
        // ARP was dropped outright, which meant hosts could not resolve each other without
        // the static ARP entries the topology script pre-populates.
        default_action = send_to_cpu();
    }

    apply {
        if (hdr.packet_out.isValid()) {
            // Controller-injected packet: obey the requested egress port and do not sample.
            standard_metadata.egress_spec = hdr.packet_out.egress_port;
            return;
        }

        if (hdr.ipv4.isValid()) {
            // Ternary first so an explicit 5-tuple rule beats the destination-based default.
            if (!flow_5tuple.apply().hit) {
                ipv4_lpm.apply();
            }
        } else if (hdr.ethernet.isValid() && hdr.ethernet.etherType == TYPE_LLDP) {
            // LLDP beacons are the proxy's link-discovery mechanism.
            send_to_cpu();
        } else if (hdr.ethernet.isValid()) {
            l2_forward.apply();
        }

        // --- telemetry sampling -------------------------------------------------------
        // Never sample a packet already destined for the CPU: that would duplicate
        // packet-ins and confuse the proxy's discovery logic.
        if (standard_metadata.egress_spec != CPU_PORT) {
            random(meta.sample_rand, (bit<16>)0, SAMPLE_RATE - 1);
            if (meta.sample_rand == 0) {
                meta.sample_ingress_port = standard_metadata.ingress_port;
                meta.sample_egress_port = standard_metadata.egress_spec;
                meta.sample_frame_length = (bit<16>)standard_metadata.packet_length;
                clone_preserving_field_list(CloneType.I2E, SAMPLE_SESSION, FL_SAMPLE);
            }
        }
    }
}

// ===========================================================================
// EGRESS PROCESSING
// ===========================================================================
control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {

    // Per-port totals, indexed by egress port. Used for link utilisation.
    counter(512, CounterType.packets_and_bytes) egress_port_counter;

    apply {
        if (standard_metadata.instance_type == BMV2_INSTANCE_TYPE_INGRESS_CLONE) {
            /*
             * This is a sampled copy on its way to the CPU. Attach the metadata the proxy
             * needs to build an sFlow flow sample, and strip any controller headers that
             * were valid on the original.
             */
            // packet_in cannot already be valid here: a packet is only cloned when its
            // egress_spec is not CPU_PORT, and send_to_cpu is what makes it valid.
            hdr.packet_in.setValid();
            hdr.packet_in.reason = PKTIN_REASON_SAMPLE;
            hdr.packet_in.ingress_port = meta.sample_ingress_port;
            hdr.packet_in.egress_port = meta.sample_egress_port;
            hdr.packet_in.frame_length = meta.sample_frame_length;
            hdr.packet_in.sampling_rate = SAMPLE_RATE;
            hdr.packet_in._pad = 0;
            hdr.packet_out.setInvalid();
            // Send only the head of the copy. Must come after packet_in is populated: the count
            // is of bytes ON THE WIRE, so it covers the emitted packet_in header too, and
            // setting it earlier would be measuring a packet that does not exist yet.
            truncate(SAMPLE_TRUNC_BYTES);
            return;   // do not count the copy: it is not real egress traffic
        }

        // Count real traffic only, indexed by the port it actually left on.
        egress_port_counter.count((bit<32>)standard_metadata.egress_port);

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
        // The controller header first, then the frame as it was received.
        packet.emit(hdr.packet_in);
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.tcp);
        packet.emit(hdr.udp);
        packet.emit(hdr.icmp);
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
