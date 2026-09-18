/* -*- P4_16 -*- */
/*
 * ndtwin_telemetry.p4 -- the cooperative telemetry path, as an include for somebody else's
 * program. TICKET-P3 2.6 ("telemetry A").
 *
 * [Co-developed with claude code -- Adam]
 *
 * WHAT THIS IS FOR. NDTwin's twin is fed by sFlow. bmv2 has no sFlow agent, so in P4 mode the
 * samples are made by the pipeline: 1-in-SAMPLE_RATE packets are cloned to the CPU port with a
 * controller header carrying the ports, the original frame length and the rate, and the proxy
 * turns each one into an sFlow datagram (p4_proxy/proxy_agent/sflow_emitter.py). A program that
 * does not do this reports zero on every link, every rate and every flow path -- and zero is
 * exactly what a broken fabric reports too.
 *
 * ndtwin_switch.p4 has always carried this path. An exercise's own program has not, which is
 * why `telemetry: cooperative` is refused for a pipeline whose p4info has no `packet_in`
 * header. This file is the way out for an author who wants their own program AND a live twin:
 * the same header layout, the same session, the same rate, the same truncation, extracted so it
 * can be included.
 *
 * 🔴 ndtwin_switch.p4 IS NOT CHANGED, and does not include this file. TICKET-P3 0.7 forbids it
 * (the compiled artefacts under p4_src/build/ are the fabric's baseline and a recompile would
 * move every sha in flight), so the two copies are deliberate duplication for now, with
 * tools/p4_exercise/tests/test_telemetry_include.py asserting that the field names and widths
 * this file declares are the ones ndtwin_switch.p4 declares. When the duplication is collapsed,
 * that test is what says the collapse changed nothing.
 *
 * HOW TO USE IT. Five lines in the including program, and it needs all five -- a parser state
 * and a deparser emit are not `apply` statements and cannot be hidden behind a control:
 *
 *   1. after `#include <v1model.p4>`:
 *          #include "ndtwin_telemetry.p4"
 *   2. in `struct headers`, as the FIRST TWO members (the deparser emits packet_in first):
 *          packet_out_header_t packet_out;
 *          packet_in_header_t  packet_in;
 *   3. in `struct metadata`:
 *          ndtwin_telemetry_t ndtwin;
 *   4. in the parser's `start` state, so a packet the controller injected is not re-parsed as
 *      Ethernet (skip this if the program never receives a packet-out):
 *          transition select(standard_metadata.ingress_port) {
 *              NDTWIN_CPU_PORT: parse_ndtwin_packet_out;
 *              default: parse_ethernet;
 *          }
 *      plus the state itself:
 *          state parse_ndtwin_packet_out {
 *              packet.extract(hdr.packet_out);
 *              transition parse_ethernet;
 *          }
 *   5. in the deparser, BEFORE every other emit:
 *          packet.emit(hdr.packet_in);
 *
 * and then one `apply` line in each of the two controls:
 *
 *   ingress, as the LAST statement of `apply` (it reads the egress_spec forwarding chose):
 *          ndtwin_sample.apply(meta.ndtwin, standard_metadata);
 *   egress, as the FIRST statement of `apply`:
 *          ndtwin_emit.apply(hdr.packet_in, hdr.packet_out, meta.ndtwin, standard_metadata,
 *                            ndtwin_is_sample);
 *          if (ndtwin_is_sample) { return; }
 *
 * with the two instantiations beside the controls' own tables:
 *
 *          NdtwinTelemetrySample() ndtwin_sample;      // in the ingress control
 *          NdtwinTelemetryEmit()   ndtwin_emit;        // in the egress control
 *          bool ndtwin_is_sample = false;              // in the egress control
 *
 * tools/p4_exercise/tests/fixtures/basic_telemetry/basic_telemetry.p4 is the worked example:
 * it is the tutorials `basic` solution with exactly those edits and nothing else.
 *
 * 🔴 THE `return` IN EGRESS IS NOT OPTIONAL. The cloned copy is not real egress traffic. A
 * program that counts it, rewrites its MACs or decrements its TTL is measuring and mangling a
 * packet that exists only to be told about -- and per-port counters that include the clones
 * read high by exactly the sampling rate, which looks like traffic rather than like a bug.
 *
 * REQUIRES v1model: `clone_preserving_field_list`, `random`, `truncate` and
 * `standard_metadata.instance_type` are all v1model's. Include it first.
 */

#ifndef NDTWIN_TELEMETRY_P4_
#define NDTWIN_TELEMETRY_P4_

// ===========================================================================
// CONSTANTS -- every one of these is a contract with something outside this file
// ===========================================================================

//: BMv2's CPU port. The proxy's clone session sends copies here and the parser reads a
//: packet-out header off anything arriving on it. `bmv2.cpu_port` in the app package must be
//: this number, or the switch is launched with a different one and the two disagree silently.
const bit<9> NDTWIN_CPU_PORT = 255;

//: The PRE clone session the proxy programs (p4_client.write_clone_session). A copy cloned to a
//: session that does not exist is dropped by bmv2 with no error anywhere.
const bit<32> NDTWIN_SAMPLE_SESSION = 250;

//: Sample 1 in this many packets. Matches OVS's sampling=256 in testbed_topo.py, so the
//: kernel's rate arithmetic is the same on both fabrics, and matches the `LINK_SAMPLE_RATE`
//: the link-telemetry path uses so the three telemetry sources are comparable.
const bit<16> NDTWIN_SAMPLE_RATE = 256;

//: Bytes of each sampled copy that actually travel to the CPU. The kernel reads the 5-tuple out
//: of the first ~40 bytes; the ORIGINAL length is reported separately in `frame_length`, so
//: truncation changes what is copied and not what is measured.
const bit<32> NDTWIN_SAMPLE_TRUNC_BYTES = 128;

//: Index of the metadata field list preserved across the ingress-to-egress clone. Ingress
//: metadata is otherwise invisible to the copy.
const bit<8> NDTWIN_FL_SAMPLE = 1;

//: Why a packet reached the controller. The proxy dispatches on this rather than guessing from
//: the frame: a telemetry sample must never reach the LLDP parser.
//:
//: PACKET_IN is for the INCLUDING program's own send-to-CPU action, if it has one, so nothing
//: in this file reads it and p4c says so: `[--Wwarn=unused] 'NDTWIN_PKTIN_REASON_PACKET_IN' is
//: unused`. That warning is expected and is not an error (`@unused` does not silence a
//: top-level const in p4c 1.2.5). Deleting the constant would make every program that sends a
//: genuine packet-in invent its own name for the same 0, and the proxy dispatches on it.
const bit<8> NDTWIN_PKTIN_REASON_PACKET_IN = 0;
const bit<8> NDTWIN_PKTIN_REASON_SAMPLE    = 1;

//: bmv2's instance_type for an ingress-to-egress clone. v1model documents but does not declare
//: these, so every program that needs one declares it.
const bit<32> NDTWIN_BMV2_INSTANCE_TYPE_INGRESS_CLONE = 1;

// ===========================================================================
// CONTROLLER HEADERS
// ===========================================================================

/*
 * 🔴 THE FIELD NAMES ARE THE API. P4Runtime numbers `metadata` entries POSITIONALLY in the
 * p4info, and the proxy looks them up BY NAME (sflow_emitter.packet_in_metadata_ids) precisely
 * so that a program which declares them in another order still works. Renaming one, or dropping
 * it, is what `TelemetryHeaderMissing` reports -- and the proxy refuses to start a switch whose
 * package asked for cooperative telemetry and whose p4info is missing any of the five.
 *
 * Samples and genuine packet-ins share this ONE header and are told apart by `reason`. They
 * cannot be two headers: P4Runtime's reference implementation matches @controller_header by
 * name and recognises only "packet_in" and "packet_out" (PI, PacketIOMgr::p4_change), so a
 * third compiles into the p4info and is then silently ignored -- every CPU packet would be
 * parsed with this header's width regardless.
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

@controller_header("packet_out")
header packet_out_header_t {
    bit<9> egress_port;
    bit<7> _pad;
}

// ===========================================================================
// METADATA
// ===========================================================================

/*
 * The three fields that have to survive the clone, plus the draw that decides whether to make
 * one. They are annotated with @field_list rather than copied by hand in egress because ingress
 * metadata is NOT visible to a cloned copy: without the annotations the egress control reads
 * zeroes, the emitter reports every sample as arriving on port 0, and the kernel attributes
 * every byte to an edge that does not exist.
 */
struct ndtwin_telemetry_t {
    @field_list(NDTWIN_FL_SAMPLE)
    bit<9>  sample_ingress_port;
    @field_list(NDTWIN_FL_SAMPLE)
    bit<9>  sample_egress_port;
    @field_list(NDTWIN_FL_SAMPLE)
    bit<16> sample_frame_length;

    bit<16> sample_rand;
}

// ===========================================================================
// INGRESS: decide, and clone
// ===========================================================================

/*
 * One draw per packet, at the END of ingress.
 *
 * 🔴 AT THE END, because `standard_metadata.egress_spec` is what forwarding just decided and
 * the sample records it. Applied before the program's tables, every sample would report
 * egress_port 0 -- and 0 is a real port number, so the kernel would credit the bytes to a link
 * that exists.
 *
 * A packet already on its way to the CPU is never sampled: that would duplicate packet-ins and
 * feed the discovery path frames it must not see.
 */
control NdtwinTelemetrySample(inout ndtwin_telemetry_t tm,
                              inout standard_metadata_t standard_metadata) {
    apply {
        if (standard_metadata.egress_spec != NDTWIN_CPU_PORT) {
            random(tm.sample_rand, (bit<16>)0, NDTWIN_SAMPLE_RATE - 1);
            if (tm.sample_rand == 0) {
                tm.sample_ingress_port = standard_metadata.ingress_port;
                tm.sample_egress_port = standard_metadata.egress_spec;
                tm.sample_frame_length = (bit<16>)standard_metadata.packet_length;
                clone_preserving_field_list(CloneType.I2E, NDTWIN_SAMPLE_SESSION,
                                            NDTWIN_FL_SAMPLE);
            }
        }
    }
}

// ===========================================================================
// EGRESS: label the copy, and say so
// ===========================================================================

/*
 * Fills in the controller header on a cloned copy and truncates it.
 *
 * `is_sample` is an out parameter because a control cannot return one, and the caller needs the
 * answer: everything else its egress does -- counters, MAC rewrites, checksums -- is about real
 * traffic and must not run for a copy. See the header comment's line 5.
 *
 * Every field is assigned, including the pad and the two that are only meaningful for a sample.
 * An uninitialised header field is UNDEFINED in P4, so leaving one out sends the proxy an
 * arbitrary value that it cannot tell from a real one.
 */
control NdtwinTelemetryEmit(inout packet_in_header_t pkt_in,
                            inout packet_out_header_t pkt_out,
                            in ndtwin_telemetry_t tm,
                            in standard_metadata_t standard_metadata,
                            out bool is_sample) {
    apply {
        is_sample = (standard_metadata.instance_type
                     == NDTWIN_BMV2_INSTANCE_TYPE_INGRESS_CLONE);
        if (is_sample) {
            // pkt_in cannot already be valid here: a packet is only cloned when its
            // egress_spec is not the CPU port, and sending to the CPU is what makes it valid.
            pkt_in.setValid();
            pkt_in.reason = NDTWIN_PKTIN_REASON_SAMPLE;
            pkt_in.ingress_port = tm.sample_ingress_port;
            pkt_in.egress_port = tm.sample_egress_port;
            pkt_in.frame_length = tm.sample_frame_length;
            pkt_in.sampling_rate = NDTWIN_SAMPLE_RATE;
            pkt_in._pad = 0;
            pkt_out.setInvalid();
            // After the header is populated, not before: the count is of bytes ON THE WIRE, so
            // it covers the emitted controller header too.
            truncate(NDTWIN_SAMPLE_TRUNC_BYTES);
        }
    }
}

#endif  /* NDTWIN_TELEMETRY_P4_ */
