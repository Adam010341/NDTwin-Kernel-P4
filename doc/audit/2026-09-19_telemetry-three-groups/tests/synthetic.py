#!/usr/bin/env python3
"""
A synthetic raw/ tree for the three-group telemetry round, with the answers known in advance.

[Co-developed with claude code -- Adam]

The tests need raw data whose correct analysis is known, and the only raw this round will ever
produce comes from a live fabric nobody may run offline. So the shapes -- arm.meta's key=value
lines, ladder.tsv, rungs.tsv, cpu_arm_probe.py's JSONL, sample_error.sh's window.json,
get_sflow_stats' document -- are written here with THE SAME KEYS THE REAL RAW CARRIES FOR EVERY
FILE THE ANALYSIS READS, and the numbers are chosen so that each registered branch of PREREG is
exercised by at least one cell.

🔴 WHAT IS DELIBERATELY NOT WRITTEN, because the sentence used to say "EXACTLY as the scripts
write them" and that was an over-claim (ruling 35(3)):

  * twelve arm.meta keys nothing reads today -- rep_rule, switch_pids, gate, switch_count,
    telemetry_knob, telemetry_package, link_emitter_pid, link_emitter_alive, link_emitter_rate,
    clone_sessions, sflow_registered, top_rung_confirmation;
  * every file class the analysis never opens: the per-rung iperf3 JSON (k<N>_rep<N>.json),
    netdev_before/after.txt, switch_state*.json, cpu_probe.log, the per-arm sflow_before/after
    pair, link_telemetry_manifest.json, the generation and driver logs, and the run root's own
    files.

Both lists are ENFORCED, not just written down: tests/test_real_shape.py compares this tree
against a structural inventory of a real run (tests/fixtures/real_run_inventory.json) and fails
if the difference is anything other than exactly those. The table below is what each cell is for:

    ceiling      none/1024 = 20,20      resolved
                 coop/1024 = 20,12      one rung apart -> resolved, ratio 0.80  -> H-A1
                 link/1024 = 8,8        resolved,        ratio 0.40             -> H-A2
                 coop/64   = 20,20      ratio 1.00                              -> H-A1
                 link/64   = 1,20       six rungs apart                         -> H-A0
    sampling     none                   no ratio at all                         -> n/a
                 coop@20M  median 0.045 = the shot-noise prediction             -> H-B1
                 link@20M  median 0.150, all three the same sign                -> H-B2
    CPU          Delta(coop - none) = 5.0 + 0.0206 * samples_per_s              -> H-C1 (206 us)
    gate         link's external is 0.30 against the other groups' 0.05         -> within-group
                                                                                   it does NOT fire
    controls     controls/C3/{c3a_noburn,c3b_burn}: group none, 1024 B, the
                 six-rung throwaway ladder, clean=12, external 0.0538 / 0.2262  -> tagged
                                                                                   `control`,
                                                                                   in NO cell

Nothing here imports analyse.py: a fixture that borrowed the code under test would agree with it
by construction.
"""
import json
import os

CLK_TCK = 100
LADDER = [1, 8, 20]
#: C3's throwaway ladder, exactly the one drive_e.sh registers as CTRL_RATES (`drive_e.sh:90`)
#: and hands to run_group_arm.sh at `drive_e.sh:660-665`. It STOPS at 12 by construction, so the
#: `highest_clean_kpps=12` those two arms report is the top of the ladder, not a ceiling.
CTRL_LADDER = [1, 2, 3, 5, 8, 12]
CTRL_BURNERS = 4
#: The two externals of the real control, from raw/2026-09-19T105759Z_full/controls/C3/
#: {c3a_noburn,c3b_burn}/arm.meta. The step of +0.1724 is what makes the gate fire, which is the
#: whole purpose of the pair -- and the reason neither belongs in the gate's own reference.
C3_EXTERNAL_NOBURN = 0.0538
C3_EXTERNAL_BURN = 0.2262
#: 🔴 THE TWO EDGE SETS ARE NOT THE SAME SET, AND THE FIXTURE USED TO PRETEND THEY WERE.
#: `keys` is what sample_error.sh:189 computes -- `twin ∩ netdev`, i.e. EVERY inter-switch port
#: on all ten switches, 32 of them -- while only the four the flow crosses ever report a rate,
#: and those four are the ones that appear in `per_edge_peak_bps`. The old fixture wrote four
#: keys and four peaks, so `len(keys)` and "the edges that carried the flow" were the same
#: number and analyse.py's `links=len(keys)` looked right. In the real raw they differ 32 vs 4,
#: N came out eight times too large and five of six H-B verdicts were the wrong one.
#: Both lists are copied from raw/2026-09-19T105759Z_full/G2/se_cooperative_2M_p1/window.json.
ALL_EDGE_KEYS = [
    "s1-eth1", "s1-eth2", "s10-eth1", "s10-eth2", "s10-eth3", "s10-eth4", "s2-eth1", "s2-eth2",
    "s3-eth1", "s3-eth2", "s4-eth1", "s4-eth2", "s5-eth1", "s5-eth2", "s5-eth3", "s5-eth4",
    "s6-eth1", "s6-eth2", "s6-eth3", "s6-eth4", "s7-eth1", "s7-eth2", "s7-eth3", "s7-eth4",
    "s8-eth1", "s8-eth2", "s8-eth3", "s8-eth4", "s9-eth1", "s9-eth2", "s9-eth3", "s9-eth4",
]
#: The four inter-switch interfaces h1 -> h4 actually crosses (s1 -> agg -> core -> agg -> s4),
#: as the twin reported them. PREREG 5.2's N counts these and only these.
ONPATH_KEYS = ["s1-eth2", "s6-eth4", "s8-eth2", "s10-eth4"]
#: the host-facing ports sample_error.sh excludes, real shape (four, one per host switch)
EXCLUDED_HOST_FACING = ["s1-eth3", "s2-eth3", "s3-eth3", "s4-eth3"]

#: (group, frame) -> the two arms' highest clean rungs, in pass order.
DEFAULT_CELLS = {
    ("none", 64): [20, 20],
    ("cooperative", 64): [20, 20],
    ("link", 64): [1, 20],
    ("none", 1024): [20, 20],
    ("cooperative", 1024): [20, 12],
    ("link", 1024): [8, 8],
}
#: group -> the foreign residual every arm of that group reports.
DEFAULT_EXTERNAL = {"none": 0.05, "cooperative": 0.06, "link": 0.30}
DEFAULT_SOFTIRQ = {"none": 0.01, "cooperative": 0.011, "link": 0.09}
#: The kernel's CPU, as PREREG 5.3's model: a flat baseline plus a fixed cost plus a marginal
#: one. 0.0206 % of one core per sample/s IS 206 us/sample, which is 08-20's figure.
KERNEL_BASE = 10.0
KERNEL_FIXED = 5.0
KERNEL_MARGINAL = 0.0206
BMV2_BASE = 150.0
#: 🔴 THE TWO GROUPS DO NOT SAMPLE THE SAME NUMBER OF PACKETS, and the fixture must not pretend
#: they do. Under `cooperative` the five switches on the path each clone 1/256 of what they
#: forward; under `link` the host-facing ports carry an EGRESS filter as well as an ingress one,
#: so there is one more sampling point on the same flow. A fixture that used one figure for both
#: would make "read the counter" and "assume 5 * pps / 256" the same function, and the mutation
#: that replaces one with the other would be equivalent -- which is exactly what happened the
#: first time this gate was run (M-E10 SURVIVED).
SAMPLING_POINTS = {"cooperative": 5, "link": 6}
#: LLDP and ARP keep a trickle of samples flowing that no offered rate predicts. Worker A's
#: addressed_total counts every family, so the counter is never exactly the naive formula.
BACKGROUND_SAMPLES_PER_S = 2.0


def samples_per_second(kpps, group):
    if group == "none":
        return 0.0
    return SAMPLING_POINTS[group] * kpps * 1000.0 / 256.0 + BACKGROUND_SAMPLES_PER_S


def kernel_percent(kpps, group):
    if group == "none":
        return KERNEL_BASE
    return KERNEL_BASE + KERNEL_FIXED + KERNEL_MARGINAL * samples_per_second(kpps, group)


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)


def _sflow_document(addressed, families=True):
    """get_sflow_stats' body, in the shape the kernel really answers with.

    🔴 THE FAMILY COUNTS ARE AT THE TOP LEVEL, NOT INSIDE telemetry_health. This fixture had
    them nested, which no real document does -- found by the structural reconciliation of
    ruling 35(3), not by a test that reads them (nothing reads them from here today; the
    analysis takes the family deltas from arm.meta). It is corrected because the next reader
    of this file will believe it: raw/2026-09-19T105759Z_full/G2/cooperative_f1024_a/
    sflow_rung20_before.json has exactly these five top-level keys.
    """
    health = {"status": "ok", "samples_in_window": addressed, "offered_in_window": addressed,
              "dropped_in_window": 0, "socket_drops_in_window": 0, "app_drops_in_window": 0,
              "loss_fraction": 0.0, "window_seconds": 8.0,
              "rx_total": addressed // 4, "addressed_total": addressed,
              "sock_ovfl_total": 0, "app_drop_total": 0}
    document = {"status": "success", "telemetry_health": health}
    if families:
        document["samples_by_family"] = {"ipv4": int(addressed * 0.98), "ipv6": 0,
                                         "l2": addressed - int(addressed * 0.98),
                                         "undecodable": 0}
        document["malformed_ipv4_ihl"] = 0
        document["non_ipv4_flows"] = {"capacity": 4096, "tracked": 0, "observed": 0,
                                      "evicted_least_recently_seen": 0}
    return document


def write_arm(root, group, frame, pass_label, clean_kpps, external=None, softirq=None,
              kernel_spread=0.0, invalid=None, ladder=None, arm_name=None, burners=0):
    """One ladder arm directory, exactly as run_group_arm.sh writes one.

    `arm_name` and `burners` exist for C3's two throwaway ladders, which run_group_arm.sh writes
    with exactly this code path -- the driver only passes it a different `--arm`, a different
    `--out` and `BURNERS=` (drive_e.sh:660-665).
    """
    ladder = LADDER if ladder is None else ladder
    arm = arm_name or ("%s_f%d_%s" % (group, frame, pass_label))
    directory = os.path.join(root, arm)
    external = DEFAULT_EXTERNAL[group] if external is None else external
    softirq = DEFAULT_SOFTIRQ[group] if softirq is None else softirq

    t = 1000.0
    rung_rows, cpu_rows, spans = [], [], {}
    # cumulative jiffies. 100 jiffies = one core-second, so a process at P% of one core gains
    # P jiffies per second -- which is what makes the expected percentages exact.
    # 🔴 TEN SWITCHES, NOT ONE. The fabric runs ten simple_switch_grpc processes and the real
    # cpu.jsonl carries all ten (raw/.../cpu.jsonl's `static` has 12 entries, 13 on a link arm);
    # this fixture used to write a single `bmv2-1`, so `label_of`'s folding of ten pids into one
    # class -- the thing every bmv2 number in the round depends on -- was never exercised. Found
    # by the structural reconciliation of ruling 35(3). The total is unchanged: ten processes at
    # BMV2_BASE/10 each.
    totals = {"kernel:11": 500000, "proxy:12": 400000, "iperf3:31": 0}
    for switch in range(1, 11):
        totals["bmv2-%d:%d" % (switch, 20 + switch)] = 900000
    if group == "link":
        totals["emitter:13"] = 300000
    machine = {"user": 10 ** 7, "nice": 0, "system": 10 ** 6, "idle": 10 ** 8, "iowait": 0,
               "irq": 0, "softirq": 10 ** 5, "steal": 0}
    for index, kpps in enumerate(ladder):
        start, end = t, t + 8.0
        spans[kpps] = (start, end)
        rung_rows.append((kpps, 1, start, end, 0.0, kpps * 1000.0, kpps * 1000.0))
        # the arm's own per-rung samples/s pair (AMENDMENT-1 A1.5)
        # 🔴 The counter is an INTEGER, so the samples/s the analysis can recover is quantised.
        # The CPU model must be built on the recoverable rate, not on the ideal one, or the fit
        # misses by the rounding and the test would be asserting the fixture's arithmetic error.
        ideal = samples_per_second(kpps, group)
        counted = int(round(ideal * 8.0))
        recoverable = counted / 8.0
        _write(os.path.join(directory, "sflow_rung%d_before.json" % kpps),
               json.dumps(_sflow_document(1000 * (index + 1))))
        _write(os.path.join(directory, "sflow_rung%d_after.json" % kpps),
               json.dumps(_sflow_document(1000 * (index + 1) + counted)))
        kernel = KERNEL_BASE if group == "none" else (
            KERNEL_BASE + KERNEL_FIXED + KERNEL_MARGINAL * recoverable)
        # the spread the H-C0 branch looks at is BETWEEN THE ARMS of a cell, so it is keyed on
        # the pass label rather than on the rung
        kernel += kernel_spread if pass_label == "a" else -kernel_spread
        rates = {"kernel:11": kernel, "proxy:12": 4.0 if group == "none" else 12.0,
                 "iperf3:31": 110.0}
        for switch in range(1, 11):
            rates["bmv2-%d:%d" % (switch, 20 + switch)] = BMV2_BASE / 10.0
        if group == "link":
            rates["emitter:13"] = 8.0
        step = 0.5
        samples = int(8.0 / step) + 1
        for n in range(samples):
            now = start + n * step
            if n:
                for key, percent in rates.items():
                    totals[key] += percent * step
                for column, per_second in (("user", 400.0), ("system", 100.0), ("idle", 900.0),
                                           ("softirq", 60.0)):
                    machine[column] += per_second * step
            cpu_rows.append({"t": round(now, 3),
                             "machine": {k: int(v) for k, v in machine.items()},
                             "proc": {k: int(v) for k, v in totals.items()}})
        t = end + 4.0

    static = {"kernel": 11, "proxy": 12}
    if group == "link":
        static["emitter"] = 13
    static.update({"bmv2-%d" % switch: 20 + switch for switch in range(1, 11)})
    header = {"clk_tck": CLK_TCK, "nproc": 14, "hz": 2.0,
              "stat_columns": ["user", "nice", "system", "idle", "iowait", "irq", "softirq",
                               "steal"],
              "static": static, "comms": {"iperf3": "iperf3"},
              "unreadable_at_start": [], "started": 1000.0}
    _write(os.path.join(directory, "cpu.jsonl"),
           "\n".join([json.dumps(header)] + [json.dumps(row) for row in cpu_rows]) + "\n")

    _write(os.path.join(directory, "rungs.tsv"),
           "kpps\trep\tt_start\tt_end\tloss\tsent_pps\trecv_pps\n"
           + "".join("%d\t%d\t%.3f\t%.3f\t%.4f\t%.1f\t%.1f\n" % row for row in rung_rows))
    _write(os.path.join(directory, "ladder.tsv"),
           "kpps_offered\treps\tloss_scored\tloss_reps\tsent_pps\trecv_pps\tclean\n"
           + "".join("%d\t1\t0.0000\t0.0000\t%.1f\t%.1f\t%s\n"
                     % (k, k * 1000.0, k * 1000.0, "yes" if k <= clean_kpps else "no")
                     for k in ladder))

    meta = [
        "arm=%s" % arm, "group=%s" % group, "frame_bytes=%d" % frame,
        "payload_bytes=%d" % (frame - 42), "started=2026-09-19T00:00:00Z",
        "ladder_kpps=%s" % " ".join(str(k) for k in ladder), "step_s=8", "clean_pct=0.5",
        "host_pair=h1->h4 (10.0.0.4)", "loopback=0",
        "kernel_sha256_start=" + "a" * 64,
        "switch_binary=/usr/local/bmv2-fast/bin/simple_switch_grpc",
        "switch_binary_override_agrees=/usr/local/bmv2-fast/bin/simple_switch_grpc",
        "switch_binary_sha256=" + "b" * 64,
        "build_signature_EventLogger=0  # fast=0, stock=24",
        "pipeline_json_sha256=" + "c" * 64,
        "switch_count_manifest=10", "kernel_pid=11", "proxy_pid=12",
        "emitter_pid=%s" % ("13" if group == "link" else "none"),
        "burners=%d" % burners,
        "telemetry_sources=" + ",".join("%d:%s" % (d, group) for d in range(1, 11)),
        "group_mismatch=none", "ladder_truncated_at=not-truncated",
        "highest_clean_kpps=%d" % clean_kpps,
        "kernel_sha256_end=" + "a" * 64,
        "sflow_counter_level=telemetry_health/telemetry_health",
        "d_rx_total=%d" % (0 if group == "none" else 900),
        "d_addressed_total=%d" % (0 if group == "none" else 3600),
        "d_sock_ovfl_total=0", "d_app_drop_total=0", "d_malformed_ipv4_ihl=0",
        "d_family_ipv4=%d" % (0 if group == "none" else 3500),
        "d_family_ipv6=0",
        "d_family_l2=%d" % (0 if group == "none" else 100),
        "d_family_undecodable=0",
        "cpu_samples=%d" % len(cpu_rows), "cpu_window_s=8.0",
        "total_busy=0.3800", "softirq_share=%.4f" % softirq,
        "bmv2_share=0.1500", "iperf3_share=0.1100", "kernel_share=0.0500",
        "proxy_share=0.0100", "emitter_share=%.4f" % (0.008 if group == "link" else 0.0),
        "external=%.4f" % external,
        "finished=2026-09-19T00:10:00Z",
        "invalid=%s" % (invalid or "no"),
    ]
    _write(os.path.join(directory, "arm.meta"), "\n".join(meta) + "\n")
    return directory


def write_window(root, group, rate_mbit, label, abs_error=None, signed_error=None,
                 nonzero_readings=None, invalid=None, truth_mbit=None):
    """One sampling-error window directory, exactly as sample_error.sh writes one."""
    directory = os.path.join(root, "se_%s_%gM_%s" % (group, rate_mbit, label))
    truth_bps = (truth_mbit or rate_mbit) * 1e6
    document = {
        "group": group, "offered_mbit": rate_mbit, "window": label, "payload_bytes": 1400,
        "frame_bytes": 1442, "duration_s": 8.0, "hz": 4.0,
        # every inter-switch port of the fabric, as sample_error.sh:189 writes it ...
        "keys": list(ALL_EDGE_KEYS),
        "excluded_host_facing": list(EXCLUDED_HOST_FACING), "twin_samples": 32,
        "elapsed_s": 8.0, "truth_bps": truth_bps, "truth_bytes": int(truth_bps * 8 / 8),
        # ... and only the four that carried the flow, as sample_error.sh:210 writes it
        "per_edge_peak_bps": {k: truth_bps / 4 for k in ONPATH_KEYS},
        "telemetry_sources": {str(d): group for d in range(1, 11)},
        "sflow_deltas": {"rx_total": 0 if group == "none" else 900,
                         "addressed_total": 0 if group == "none" else 1800,
                         "sock_ovfl_total": 0, "app_drop_total": 0,
                         "malformed_ipv4_ihl": 0,
                         "samples_by_family": {"ipv4": 0 if group == "none" else 1750,
                                               "ipv6": 0,
                                               "l2": 0 if group == "none" else 50,
                                               "undecodable": 0}},
        "invalid": invalid,
    }
    if group == "none":
        # 🔴 AND NO PER-EDGE PEAKS AT ALL. Under `none` the twin never reports a rate, so
        # sample_error.sh's per_edge_peak dict stays EMPTY -- which is what the real
        # G1/se_none_*/window.json carries, and what makes analyse.py fall back to PREREG's
        # registered four edges instead of inferring zero of them.
        document.update({"ratio": None, "abs_error": None, "signed_error": None,
                         "nonzero_twin_readings": 0 if nonzero_readings is None
                                                  else nonzero_readings,
                         "twin_bps": 0.0, "per_edge_peak_bps": {},
                         "ratio_note": "n/a -- the none group has no twin readings; reporting 0 "
                                       "would turn an absence into a measurement"})
    else:
        signed = signed_error if signed_error is not None else -abs_error
        document.update({"ratio": 1.0 + signed, "abs_error": abs(signed), "signed_error": signed,
                         "nonzero_twin_readings": 120 if nonzero_readings is None
                                                  else nonzero_readings,
                         "twin_bps": truth_bps * (1.0 + signed)})
    _write(os.path.join(directory, "window.json"), json.dumps(document, indent=2, sort_keys=True))
    return directory


def write_emitter_log(directory, samples=10000, dropped=0, enobufs=0):
    """The emitter's own statistics line, the only mechanism evidence H-B3 may rest on."""
    lines = [
        "psample_sflow_emitter: samples=1 emitted=1 dropped_unknown_ifindex=0 "
        "dropped_no_direction=0 dropped_ambiguous_direction=0 dropped_no_origsize=0 "
        "dropped_other_group=0 dropped_decode_error=0 emit_failed=0 enobufs=0 "
        "per_switch=s1:1 elapsed=10.0s",
        "psample_sflow_emitter: samples=%d emitted=%d dropped_unknown_ifindex=%d "
        "dropped_no_direction=0 dropped_ambiguous_direction=0 dropped_no_origsize=0 "
        "dropped_other_group=0 dropped_decode_error=0 emit_failed=0 enobufs=%d "
        "per_switch=s1:%d elapsed=20.0s" % (samples, samples - dropped, dropped, enobufs,
                                            samples),
    ]
    _write(os.path.join(directory, "emitter.log"), "\n".join(lines) + "\n")


def write_control(root, control, **fields):
    lines = ["control=%s" % control] + ["%s=%s" % kv for kv in sorted(fields.items())]
    _write(os.path.join(root, "controls", control, "control.meta"), "\n".join(lines) + "\n")


def build(root, cells=None, coop_error=0.045, link_error=0.150, emitter_dropped=0,
          kernel_spread=0.0, c1_ceiling=770000.0, c2_ceiling=500000.0):
    """The whole tree. Returns root."""
    cells = DEFAULT_CELLS if cells is None else cells
    generations = {("none", "a"): "G1", ("cooperative", "a"): "G2", ("link", "a"): "G3",
                   ("link", "b"): "G4", ("cooperative", "b"): "G5", ("none", "b"): "G6"}
    for (group, frame), values in sorted(cells.items()):
        for pass_label, clean in zip(("a", "b"), values):
            directory = write_arm(os.path.join(root, generations[(group, pass_label)]),
                                  group, frame, pass_label, clean,
                                  kernel_spread=kernel_spread)
            if group == "link":
                write_emitter_log(directory, dropped=emitter_dropped)
    for group, base in (("none", None), ("cooperative", coop_error), ("link", link_error)):
        generation = os.path.join(root, generations[(group, "a")])
        for rate in (2, 20, 100):
            for index, label in enumerate(("p1", "p2", "p3")):
                if base is None:
                    write_window(generation, group, rate, label)
                else:
                    # a little spread around the cell's median, all with the same sign
                    write_window(generation, group, rate, label,
                                 signed_error=-(base + (index - 1) * base * 0.1))
    # `requirement` and `verdict` are written because the real C1/C2 control.meta carry them
    # (drive_e.sh:576-582) -- another gap the structural reconciliation of ruling 35(3) found.
    write_control(root, "C1", frame_bytes=64, payload_bytes=22, ceiling_pps=c1_ceiling,
                  reps_pps="%s %s %s" % (c1_ceiling, c1_ceiling - 900, c1_ceiling + 900),
                  requirement=">= 5x the highest 64B pps this round measures through bmv2 "
                              "(PREREG 4.3)",
                  verdict="computed by analyse.py once the 64B cells exist")
    write_control(root, "C2", frame_bytes=1024, payload_bytes=982, ceiling_pps=c2_ceiling,
                  reps_pps="%s %s %s" % (c2_ceiling, c2_ceiling - 900, c2_ceiling + 900),
                  requirement=">= 5x the highest 1024B pps this round measures through bmv2 "
                              "(PREREG 4.3)",
                  verdict="computed by analyse.py once the 1024B cells exist")
    # 🔴 C3'S TWO THROWAWAY LADDERS, WHERE AND AS THE DRIVER WRITES THEM. They were missing
    # until now, and that absence is why nothing could see analyse.py pooling them into
    # `none|1024`: the fixture disagreed with the raw about what a run directory contains, so
    # the suite was asserting about a tree the round never produces. Same family as M-E10 and
    # ruling 27's string `argv` -- a fixture shaped like the code's assumption proves nothing.
    # gate_control() (drive_e.sh:656-666) runs run_group_arm.sh twice with `--group none
    # --frame 1024`, `RATES_KPPS="1 2 3 5 8 12"` and BURNERS 0 then 4, into
    # <run>/controls/C3/<arm>. Every value below is from the real pair in
    # raw/2026-09-19T105759Z_full/controls/C3/*/arm.meta.
    c3_root = os.path.join(root, "controls", "C3")
    for arm_name, burners, external in (("c3a_noburn", 0, C3_EXTERNAL_NOBURN),
                                        ("c3b_burn", CTRL_BURNERS, C3_EXTERNAL_BURN)):
        write_arm(c3_root, "none", 1024, "a", CTRL_LADDER[-1], external=external,
                  ladder=CTRL_LADDER, arm_name=arm_name, burners=burners)
    write_control(root, "C3", burners=CTRL_BURNERS,
                  ladder=" ".join(str(k) for k in CTRL_LADDER),
                  external_without_burners=C3_EXTERNAL_NOBURN,
                  external_with_burners=C3_EXTERNAL_BURN,
                  threshold="+0.15 absolute", verdict="FIRES")
    return root
