/* Heartbeat drop-check fixtures: what a program does with a frame whose ethertype it does not
 * know. One source, one -D per behaviour. [Co-developed with claude code -- Adam] */
#include <core.p4>
#include <v1model.p4>

#define CPU_PORT 255

header ethernet_t { bit<48> dst; bit<48> src; bit<16> etherType; }
@controller_header("packet_in")
header packet_in_t { bit<16> ingress_port; }
struct headers_t { packet_in_t packet_in; ethernet_t ethernet; }
struct learn_t { bit<48> src; bit<9> port; }
struct meta_t { }

parser P(packet_in pkt, out headers_t hdr, inout meta_t m, inout standard_metadata_t sm) {
    state start { pkt.extract(hdr.ethernet); transition accept; }
}
control VC(inout headers_t hdr, inout meta_t m) { apply { } }
control I(inout headers_t hdr, inout meta_t m, inout standard_metadata_t sm) {
    apply {
        if (hdr.ethernet.etherType == 0x0800) {
            sm.egress_spec = 1;
        } else {
#if defined(FLOOD)
            /* an unknown ethertype goes out of another data port: 1, or 2 when it came in on 1 */
            sm.egress_spec = (sm.ingress_port == 1) ? (bit<9>)2 : (bit<9>)1;
#elif defined(PUNT)
            /* an unknown ethertype goes to the controller */
            sm.egress_spec = CPU_PORT;
            hdr.packet_in.setValid();
            hdr.packet_in.ingress_port = (bit<16>)sm.ingress_port;
#elif defined(DIGEST)
            /* an unknown ethertype is learned (a digest to the controller) and dropped */
            digest<learn_t>(1, {hdr.ethernet.src, sm.ingress_port});
            mark_to_drop(sm);
#elif defined(CLONE)
            /* an unknown ethertype is cloned to mirror session 5 and dropped */
            clone(CloneType.I2E, 5);
            mark_to_drop(sm);
#elif defined(MCAST)
            /* an unknown ethertype is flooded through multicast group 1, which a controller fills */
            sm.mcast_grp = 1;
#else
            /* an unknown ethertype is dropped */
            mark_to_drop(sm);
#endif
        }
    }
}
control E(inout headers_t hdr, inout meta_t m, inout standard_metadata_t sm) { apply { } }
control CC(inout headers_t hdr, inout meta_t m) { apply { } }
control D(packet_out pkt, in headers_t hdr) { apply { pkt.emit(hdr.packet_in); pkt.emit(hdr.ethernet); } }
V1Switch(P(), VC(), I(), E(), CC(), D()) main;
