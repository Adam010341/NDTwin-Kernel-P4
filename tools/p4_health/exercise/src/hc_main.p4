/* P4 health check -- the program the probe loads on every switch.
 *
 * [Co-developed with claude code -- Adam]
 *
 * One source, compiled twice: as is (s2-s4) and with -DHC_ALT (s1: one more table, and a parser
 * that selects on the ingress port). -DHC_MUTANT_NO_COUNT / _NO_TTL / _NO_QSTAMP change action
 * bodies only, so their p4info is byte-identical to the plain build (S0 asserts that);
 * -DHC_MUTANT_FWD_88B5 forwards the heartbeat frame instead of dropping it and exists only for
 * S0's drop-check control (design section 3).
 *
 * Every UDP marker uses the dport of its cell; the HC_DPORT_* values are mirrored in
 * tools/p4_health/cells/table.py and a test compares the two.
 */
#include <core.p4>
#include <v1model.p4>

#define HC_DPORT_K1    40011
#define HC_DPORT_K2    40012
#define HC_DPORT_MT1   40021
#define HC_DPORT_MT3   40023
#define HC_DPORT_R2    40031
#define HC_DPORT_D1    40041
#define HC_DPORT_P2    40050
#define HC_DPORT_C1    40061
#define HC_DPORT_MCAST 40062
#define HC_DPORT_Q1    40071
#define HC_DPORT_TTL1  40081
#define HC_DPORT_RC1   40091
#define HC_DPORT_HR1   40092
#define HC_DPORT_HR2   40093
#define HC_DPORT_VB1   40095
#define HC_DPORT_CH6   40096

const bit<16> TYPE_HB       = 0x88B5;
const bit<16> TYPE_IPV4     = 0x0800;
const bit<16> TYPE_IPV6     = 0x86DD;
const bit<16> TYPE_VLAN     = 0x8100;
const bit<16> TYPE_TUNNEL   = 0x1212;
const bit<16> TYPE_SRCROUTE = 0x1234;
const bit<16> TYPE_HCL2     = 0x1236;
const bit<16> TYPE_UALT     = 0x1238;
const bit<8>  PROTO_TCP     = 6;
const bit<8>  PROTO_UDP     = 17;
const bit<8>  PROTO_SHIM    = 0xFD;
const bit<9>  CPU_PORT      = 510;
const bit<32> CLONE_SESSION = 7;
const bit<8>  FLAG_RESUB    = 0x04;
const bit<8>  FLAG_RECIRC   = 0x08;
#define MAX_HOPS 8

typedef bit<9>  egressSpec_t;
typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;

@controller_header("packet_in")
header packet_in_t {
    bit<9>  ingress_port;
    bit<7>  _pad;
}

@controller_header("packet_out")
header packet_out_t {
    bit<9>  egress_port;
    bit<7>  _pad;
}

header ethernet_t { macAddr_t dstAddr; macAddr_t srcAddr; bit<16> etherType; }
header vlan_t     { bit<3> pcp; bit<1> dei; bit<12> vid; bit<16> etherType; }
header myTunnel_t { bit<16> proto_id; bit<16> dst_id; }
header srcRoute_t { bit<1> bos; bit<15> port; }
header hcl2_t     { bit<16> dst_id; bit<16> proto; bit<32> tag; }
header ipv6_t {
    bit<4> version; bit<8> trafficClass; bit<20> flowLabel;
    bit<16> payloadLen; bit<8> nextHdr; bit<8> hopLimit;
    bit<128> srcAddr; bit<128> dstAddr;
}
header alt6_t     { bit<16> dst_id; bit<16> kind; }
/* Q3(b): the union whose members the parser chooses between (0x86DD or 0x1238). */
header_union l3alt_t { ipv6_t v6; alt6_t x; }
header ipv4_t {
    bit<4> version; bit<4> ihl; bit<8> diffserv; bit<16> totalLen;
    bit<16> identification; bit<3> flags; bit<13> fragOffset;
    bit<8> ttl; bit<8> protocol; bit<16> hdrChecksum;
    ip4Addr_t srcAddr; ip4Addr_t dstAddr;
}
header ipv4_opt_t { varbit<320> options; }
/* CH4: a shim between IPv4 and UDP. */
header shim_t     { bit<8> next_proto; bit<8> len; bit<16> tag; }
header udp_t      { bit<16> srcPort; bit<16> dstPort; bit<16> length_; bit<16> checksum; }
header tcp_t {
    bit<16> srcPort; bit<16> dstPort; bit<32> seqNo; bit<32> ackNo;
    bit<4> dataOffset; bit<4> res; bit<8> flags; bit<16> window;
    bit<16> checksum; bit<16> urgentPtr;
}
/* VB1: a length byte and a variable-length tail after UDP. */
header tail_len_t { bit<8> len; }
header tail_t     { varbit<2040> data; }
/* CH6: a shim after L4. */
header l4shim_t   { bit<32> tag; }

struct digest_t { ip4Addr_t src; bit<16> sport; bit<16> dport; }

struct metadata {
    bit<16> dst_id;
    bit<8>  port_tag;
    bit<8>  stamp;
    bit<8>  t_mark;
    bit<32> color;
    bit<32> dcolor;
    bit<1>  vs_hit;
    bit<1>  from_host;
    bit<1>  mp_choice;
    bit<32> v6_lo;
    @field_list(1)
    bit<8>  resubmitted;
}

struct headers {
    packet_out_t           packet_out;
    packet_in_t            packet_in;
    ethernet_t             ethernet;
    vlan_t                 vlan;
    myTunnel_t             myTunnel;
    srcRoute_t[MAX_HOPS]   srcRoutes;
    hcl2_t                 hcl2;
    l3alt_t                l3alt;
    ipv4_t                 ipv4;
    ipv4_opt_t             ipv4_opt;
    shim_t                 shim;
    udp_t                  udp;
    tcp_t                  tcp;
    tail_len_t             tail_len;
    tail_t                 tail;
    l4shim_t               l4shim;
}

/*************************************************************************
 *  PARSER
 *************************************************************************/
parser HcParser(packet_in packet, out headers hdr, inout metadata meta,
                inout standard_metadata_t standard_metadata) {

    /* VS1 (Q3(b)): a parser value set the control plane fills at runtime. */
    value_set<bit<16>>(4) vs_ports;

    state start {
#ifdef HC_ALT
        /* CH8: the port-keyed parser, s1 only. Host ports are 1..3 on s1. */
        transition select(standard_metadata.ingress_port) {
            CPU_PORT: parse_packet_out;
            1: parse_from_host;
            2: parse_from_host;
            3: parse_from_host;
            default: parse_ethernet;
        }
#else
        transition select(standard_metadata.ingress_port) {
            CPU_PORT: parse_packet_out;
            default: parse_ethernet;
        }
#endif
    }

    state parse_packet_out {
        packet.extract(hdr.packet_out);
        transition parse_ethernet;
    }

    state parse_from_host {
        meta.from_host = 1;
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_HB:       accept;          /* the heartbeat: nothing past the ethernet header */
            TYPE_VLAN:     parse_vlan;
            TYPE_TUNNEL:   parse_tunnel;
            TYPE_SRCROUTE: parse_srcroute;
            TYPE_HCL2:     parse_hcl2;
            TYPE_IPV6:     parse_v6;
            TYPE_UALT:     parse_alt6;
            TYPE_IPV4:     parse_ipv4;
            default:       accept;
        }
    }

    state parse_vlan {
        packet.extract(hdr.vlan);
        transition select(hdr.vlan.etherType) {
            TYPE_IPV4: parse_ipv4;
            default:   accept;
        }
    }

    state parse_tunnel {
        packet.extract(hdr.myTunnel);
        meta.dst_id = hdr.myTunnel.dst_id;
        transition select(hdr.myTunnel.proto_id) {
            TYPE_IPV4: parse_ipv4;
            default:   accept;
        }
    }

    state parse_srcroute {
        packet.extract(hdr.srcRoutes.next);
        transition select(hdr.srcRoutes.last.bos) {
            1:       parse_ipv4;
            default: parse_srcroute;
        }
    }

    state parse_hcl2 {
        packet.extract(hdr.hcl2);
        meta.dst_id = hdr.hcl2.dst_id;
        transition accept;
    }

    state parse_v6 {
        packet.extract(hdr.l3alt.v6);
        meta.v6_lo = hdr.l3alt.v6.dstAddr[31:0];
        transition accept;
    }

    state parse_alt6 {
        packet.extract(hdr.l3alt.x);
        meta.dst_id = hdr.l3alt.x.dst_id;
        transition accept;
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.ihl) {
            5:       parse_l4;
            default: parse_ipv4_options;
        }
    }

    state parse_ipv4_options {
        packet.extract(hdr.ipv4_opt, (bit<32>)(((bit<16>)hdr.ipv4.ihl - 5) * 32));
        transition parse_l4;
    }

    state parse_l4 {
        transition select(hdr.ipv4.protocol) {
            PROTO_UDP:  parse_udp;
            PROTO_TCP:  parse_tcp;
            PROTO_SHIM: parse_shim;
            default:    accept;
        }
    }

    state parse_shim {
        packet.extract(hdr.shim);
        transition select(hdr.shim.next_proto) {
            PROTO_UDP: parse_udp;
            default:   accept;
        }
    }

    state parse_udp {
        packet.extract(hdr.udp);
        transition select(hdr.udp.dstPort) {
            vs_ports:      parse_vs;
            HC_DPORT_VB1:  parse_tail;
            HC_DPORT_CH6:  parse_l4shim;
            default:       accept;
        }
    }

    state parse_vs {
        meta.vs_hit = 1;
        transition accept;
    }

    state parse_tail {
        packet.extract(hdr.tail_len);
        packet.extract(hdr.tail, (bit<32>)hdr.tail_len.len * 8);
        transition accept;
    }

    state parse_l4shim {
        packet.extract(hdr.l4shim);
        transition accept;
    }

    state parse_tcp {
        packet.extract(hdr.tcp);
        transition accept;
    }
}

/*************************************************************************
 *  CHECKSUM VERIFICATION
 *************************************************************************/
control HcVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}

/*************************************************************************
 *  INGRESS
 *************************************************************************/
control HcIngress(inout headers hdr, inout metadata meta,
                  inout standard_metadata_t standard_metadata) {

    counter(1024, CounterType.packets_and_bytes) c_in;
    direct_counter(CounterType.packets_and_bytes) dc_k2;
    meter(64, MeterType.bytes) m_in;
    direct_meter<bit<32>>(MeterType.bytes) dm_mt3;
    register<bit<32>>(16) r_mark;
    action_profile(32w16) ap_prof;
    action_selector(HashAlgorithm.crc16, 32w16, 32w14) as_sel;

    action drop() {
        mark_to_drop(standard_metadata);
    }

    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
        standard_metadata.egress_spec = port;
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
#ifdef HC_MUTANT_NO_TTL
        hdr.ipv4.ttl = hdr.ipv4.ttl;
#else
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
#endif
    }

    table ipv4_lpm {
        key = { hdr.ipv4.dstAddr: lpm; }
        actions = { ipv4_forward; drop; NoAction; }
        size = 1024;
        default_action = drop();
    }

    /* HR1/HR2 (Q3(b)): the same next hop as ipv4_forward, chosen by a hash or a coin. */
    table t_multipath {
        key = { hdr.ipv4.dstAddr: exact; meta.mp_choice: exact; }
        actions = { ipv4_forward; NoAction; }
        size = 64;
        default_action = NoAction();
    }

    action tunnel_forward(egressSpec_t port) {
        standard_metadata.egress_spec = port;
    }

    table tunnel_exact {
        key = { meta.dst_id: exact; }
        actions = { tunnel_forward; drop; }
        size = 64;
        default_action = drop();
    }

    action v6_forward(macAddr_t dstAddr, egressSpec_t port) {
        standard_metadata.egress_spec = port;
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        hdr.l3alt.v6.hopLimit = hdr.l3alt.v6.hopLimit - 1;
    }

    table v6_host {
        key = { meta.v6_lo: exact; }
        actions = { v6_forward; drop; }
        size = 64;
        default_action = drop();
    }

    action set_port_tag(bit<8> tag) {
        meta.port_tag = tag;
    }

    /* T3: written at runtime through POST /p4/table_entry. */
    table port_exact {
        key = { standard_metadata.ingress_port: exact; }
        actions = { set_port_tag; NoAction; }
        size = 64;
        default_action = NoAction();
    }

    action stamp(bit<8> v) {
        meta.stamp = v;
    }

    /* T2: a table with no key. The compiled default is stamp(0); s2's runtime file sets 0x2A. */
    table t_default_only {
        actions = { stamp; }
        default_action = stamp(0);
    }

#ifdef HC_ALT
    /* PL1: the one table only the s1 build has. */
    table alt_port_stamp {
        key = { standard_metadata.ingress_port: exact; }
        actions = { stamp; NoAction; }
        size = 16;
        default_action = NoAction();
    }
#endif

    action set_mark(bit<8> v) {
        meta.t_mark = v;
    }

    table t_ternary {                       /* T4, T7 */
        key = { hdr.ipv4.srcAddr: ternary; }
        actions = { set_mark; NoAction; }
        size = 64;
        default_action = NoAction();
    }

    table t_range {                         /* T5 */
        key = { hdr.udp.dstPort: range; }
        actions = { set_mark; NoAction; }
        size = 64;
        default_action = NoAction();
    }

    table t_optional {                      /* T6 */
        key = { hdr.ipv4.protocol: optional; }
        actions = { set_mark; NoAction; }
        size = 64;
        default_action = NoAction();
    }

    action dc_hit() {
        meta.t_mark = 1;
    }

    table t_dcount {                        /* K2 */
        key = { hdr.udp.dstPort: exact; }
        actions = { dc_hit; NoAction; }
        counters = dc_k2;
        size = 16;
        default_action = NoAction();
    }

    action dm_read() {
        dm_mt3.read(meta.dcolor);
    }

    table t_dmeter {                        /* MT3 */
        key = { hdr.udp.dstPort: exact; }
        actions = { dm_read; NoAction; }
        meters = dm_mt3;
        size = 16;
        default_action = NoAction();
    }

    table t_ap {                            /* AP1 (Q3(b)) */
        key = { hdr.udp.dstPort: exact; }
        actions = { set_mark; NoAction; }
        implementation = ap_prof;
        size = 16;
    }

    table t_as {                            /* AS1 (Q3(b)) */
        key = { hdr.udp.dstPort: exact; hdr.ipv4.srcAddr: selector; }
        actions = { set_mark; NoAction; }
        implementation = as_sel;
        size = 16;
    }

    action idle_hit() {
        meta.t_mark = 2;
    }

    table t_idle {                          /* IT1 (Q3(b)) */
        key = { hdr.udp.dstPort: exact; }
        actions = { idle_hit; NoAction; }
        support_timeout = true;
        size = 16;
        default_action = NoAction();
    }

    apply {
        /* The heartbeat: the FIRST statement, ahead of every table and every entry. */
        if (hdr.ethernet.etherType == TYPE_HB) {
#ifdef HC_MUTANT_FWD_88B5
            standard_metadata.egress_spec = 1;
#else
            mark_to_drop(standard_metadata);
#endif
            exit;
        }

        if (hdr.packet_out.isValid()) {     /* P3 */
            standard_metadata.egress_spec = hdr.packet_out.egress_port;
            hdr.packet_out.setInvalid();
            exit;
        }

        port_exact.apply();
        t_default_only.apply();
#ifdef HC_ALT
        alt_port_stamp.apply();
#endif

        if (hdr.srcRoutes[0].isValid()) {   /* CH2: source routing, popped one hop at a time */
            if (hdr.srcRoutes[0].bos == 1) {
                hdr.ethernet.etherType = TYPE_IPV4;
            }
            standard_metadata.egress_spec = (bit<9>)hdr.srcRoutes[0].port;
            hdr.srcRoutes.pop_front(1);
            if (hdr.ipv4.isValid()) {
                hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
            }
        } else if (hdr.myTunnel.isValid() || hdr.hcl2.isValid() || hdr.l3alt.x.isValid()) {
            tunnel_exact.apply();           /* CH1, CH7, HU1's 0x1238 member */
        } else if (hdr.l3alt.v6.isValid()) {
            v6_host.apply();                /* HU1 */
        } else if (hdr.ipv4.isValid()) {
            ipv4_lpm.apply();
            if (hdr.udp.isValid()) {
                t_ternary.apply();
                t_range.apply();
                t_optional.apply();
                t_dcount.apply();
                t_dmeter.apply();
                t_ap.apply();
                t_as.apply();
                t_idle.apply();

                if (hdr.udp.dstPort == HC_DPORT_K1) {
#ifdef HC_MUTANT_NO_COUNT
                    c_in.count(32w1);
#else
                    c_in.count(32w0);
#endif
                }
                if (hdr.udp.dstPort == HC_DPORT_MT1) {
                    m_in.execute_meter<bit<32>>(32w0, meta.color);
                }
                if (hdr.udp.dstPort == HC_DPORT_R2) {
                    /* SC-reg: the value is the one the marker chose, carried in its sport. */
                    r_mark.write(32w0, (bit<32>)hdr.udp.srcPort);
                }
                if (hdr.udp.dstPort == HC_DPORT_D1) {
                    digest<digest_t>(1, {hdr.ipv4.srcAddr, hdr.udp.srcPort, hdr.udp.dstPort});
                }
                if (hdr.udp.dstPort == HC_DPORT_P2) {
                    standard_metadata.egress_spec = CPU_PORT;
                }
                if (hdr.udp.dstPort == HC_DPORT_C1) {
                    clone(CloneType.I2E, CLONE_SESSION);
                }
                if (hdr.udp.dstPort == HC_DPORT_MCAST) {
                    standard_metadata.mcast_grp = 1;
                }
                if (hdr.udp.dstPort == HC_DPORT_HR1 || hdr.udp.dstPort == HC_DPORT_HR2) {
                    if (hdr.udp.dstPort == HC_DPORT_HR1) {
                        hash(meta.mp_choice, HashAlgorithm.crc16, 1w0,
                             { hdr.ipv4.srcAddr, hdr.ipv4.dstAddr, hdr.ipv4.protocol,
                               hdr.udp.srcPort, hdr.udp.dstPort }, 2w2);
                    } else {
                        random(meta.mp_choice, 1w0, 1w1);
                    }
                    t_multipath.apply();
                }
                if (hdr.udp.dstPort == HC_DPORT_RC1 && (hdr.ipv4.diffserv & FLAG_RESUB) == 0) {
                    if (meta.resubmitted == 0) {
                        meta.resubmitted = 1;
                        resubmit_preserving_field_list(1);
                    } else {
                        hdr.ipv4.diffserv = hdr.ipv4.diffserv | FLAG_RESUB;
                    }
                }
            }
        }
    }
}

/*************************************************************************
 *  EGRESS
 *************************************************************************/
control HcEgress(inout headers hdr, inout metadata meta,
                 inout standard_metadata_t standard_metadata) {

    /* Q1 / SC-qstamp: bit 15 of the identification says "stamped", bits 14..0 carry
     * enq_qdepth. Only for a marker that arrived with identification 0 (section 12 item 3). */
    action do_qstamp() {
#ifdef HC_MUTANT_NO_QSTAMP
        hdr.ipv4.identification = hdr.ipv4.identification;
#else
        hdr.ipv4.identification = 16w0x8000 | (bit<16>)standard_metadata.enq_qdepth[14:0];
#endif
    }

    table q_stamp {
        actions = { do_qstamp; NoAction; }
        default_action = do_qstamp();
    }

    apply {
        if (standard_metadata.egress_port == CPU_PORT) {
            hdr.packet_in.setValid();
            hdr.packet_in.ingress_port = standard_metadata.ingress_port;
        }
        if (hdr.ipv4.isValid() && hdr.udp.isValid()) {
            if (hdr.udp.dstPort == HC_DPORT_Q1 && hdr.ipv4.identification == 0) {
                q_stamp.apply();
            }
            if (hdr.udp.dstPort == HC_DPORT_RC1 && (hdr.ipv4.diffserv & FLAG_RECIRC) == 0
                    && standard_metadata.egress_port != CPU_PORT) {
                hdr.ipv4.diffserv = hdr.ipv4.diffserv | FLAG_RECIRC;
                recirculate_preserving_field_list(1);
            }
        }
    }
}

/*************************************************************************
 *  CHECKSUM COMPUTATION
 *************************************************************************/
control HcComputeChecksum(inout headers hdr, inout metadata meta) {
    apply {
        update_checksum(
            hdr.ipv4.isValid(),
            { hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.diffserv, hdr.ipv4.totalLen,
              hdr.ipv4.identification, hdr.ipv4.flags, hdr.ipv4.fragOffset, hdr.ipv4.ttl,
              hdr.ipv4.protocol, hdr.ipv4.srcAddr, hdr.ipv4.dstAddr, hdr.ipv4_opt.options },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}

/*************************************************************************
 *  DEPARSER
 *************************************************************************/
control HcDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.packet_in);
        packet.emit(hdr.ethernet);
        packet.emit(hdr.vlan);
        packet.emit(hdr.myTunnel);
        packet.emit(hdr.srcRoutes);
        packet.emit(hdr.hcl2);
        packet.emit(hdr.l3alt);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.ipv4_opt);
        packet.emit(hdr.shim);
        packet.emit(hdr.udp);
        packet.emit(hdr.tcp);
        packet.emit(hdr.tail_len);
        packet.emit(hdr.tail);
        packet.emit(hdr.l4shim);
    }
}

V1Switch(HcParser(), HcVerifyChecksum(), HcIngress(), HcEgress(),
         HcComputeChecksum(), HcDeparser()) main;
