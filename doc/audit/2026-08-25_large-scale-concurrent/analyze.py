#!/usr/bin/env python3
"""Reconcile the twin's per-edge telemetry against kernel veth counters, at 128 hosts.

Three independent streams, none derived from another:
  veth.tsv     rx/tx byte counters from /sys, underneath everything under test
  graph.jsonl  /ndt/get_graph_data, link_bandwidth_usage_bps per edge
  flows.jsonl  /ndt/get_detected_flow_data

MAPPING. A twin edge leaving switch N by interface M is the veth `sN-ethM`; the bytes it should
account for are that interface's TX delta. The reverse edge is the same interface's RX delta.

INTEGRATION. usage_bps is an instantaneous rate, so twin bytes = sum over samples of
rate * dt, using the actual timestamp gaps rather than the nominal interval -- a poller that
stalled for six seconds would otherwise be counted as if it had not.

WHY THE FLOOR MATTERS MORE THAN THE RATIO. 1/256 sampling puts a Poisson floor of 196*sqrt(1/c)
on any per-edge estimate, where c is that edge's sample count. An edge inside its floor is
consistent with correct accounting; an edge WELL inside it is being smoothed, which is not the
same as being accurate. Both are reported, because a bare ratio invites reading 1.00 as "good".

SELFTEST. `--selftest` runs the whole pipeline over synthetic input with a known answer,
including one edge that must be flagged. A reconciler that has only ever seen real input has no
way to distinguish "the twin is accurate" from "my parser returns zeros" -- this repo read a
parser regression as a system state four times in one day.

[Co-developed with claude code -- Adam]
"""
import argparse
import collections
import json
import math
import os
import sys

HOST_DPID = 0            # hosts carry dpid 0 in the topology model; confirmed against live data


# --------------------------------------------------------------------------- veth ground truth
def read_veth(path, t_lo=None, t_hi=None):
    """{iface: (rx_delta, tx_delta)} between the first and last sample inside the window.

    Also returns the span actually realised. That matters more than it looks: the pollers do not
    hit their nominal 2 s -- the veth one spawns 160 reads per sweep -- so the veth stream and
    the twin stream cover slightly different spans of the same window. Integrating each over its
    OWN span and dividing gives a ratio that carries the difference, which would read as a
    telemetry error. The caller aligns them using this.
    """
    first, last = {}, {}
    n = 0
    with open(path) as fh:
        head = fh.readline()
        assert head.startswith("ts\t"), f"{path}: not the expected TSV header"
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 4:
                continue
            ts, iface, rx, tx = float(parts[0]), parts[1], int(parts[2]), int(parts[3])
            if t_lo is not None and ts < t_lo:
                continue
            if t_hi is not None and ts > t_hi:
                continue
            n += 1
            first.setdefault(iface, (ts, rx, tx))
            last[iface] = (ts, rx, tx)
    out = {}
    span_lo = span_hi = None
    for iface, (t1, rx1, tx1) in first.items():
        t2, rx2, tx2 = last[iface]
        if t2 <= t1:
            continue
        out[iface] = (rx2 - rx1, tx2 - tx1, t2 - t1)
        span_lo = t1 if span_lo is None else min(span_lo, t1)
        span_hi = t2 if span_hi is None else max(span_hi, t2)
    return out, n, (span_lo, span_hi)


# --------------------------------------------------------------------------- twin per-edge
def read_graph(path, t_lo=None, t_hi=None):
    """{(src_dpid, src_if, dst_dpid, dst_if): {bytes, samples, nonzero, first_bps, util}}."""
    acc = collections.defaultdict(lambda: {"bytes": 0.0, "samples": 0, "nonzero": 0,
                                           "first_bps": None, "util": [], "declared": None})
    prev_ts = None
    ok = miss = 0
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            ts, body = rec["ts"], rec["body"]
            if body is None:
                miss += 1
                continue
            if t_lo is not None and ts < t_lo:
                prev_ts = ts
                continue
            if t_hi is not None and ts > t_hi:
                continue
            ok += 1
            dt = (ts - prev_ts) if prev_ts is not None else 0.0
            prev_ts = ts
            for e in body.get("edges", []):
                k = (e["src_dpid"], e["src_interface"], e["dst_dpid"], e["dst_interface"])
                a = acc[k]
                bps = e.get("link_bandwidth_usage_bps") or 0
                a["bytes"] += bps * dt / 8.0
                a["samples"] += 1
                if bps:
                    a["nonzero"] += 1
                if a["first_bps"] is None:
                    a["first_bps"] = bps
                if e.get("link_bandwidth_utilization_percent") is not None:
                    a["util"].append(e["link_bandwidth_utilization_percent"])
                if a["declared"] is None:
                    a["declared"] = e.get("link_bandwidth_bps")
    return dict(acc), ok, miss


def edge_class(src_dpid, dst_dpid):
    if src_dpid == HOST_DPID:
        return "host->switch"
    if dst_dpid == HOST_DPID:
        return "switch->host"
    return "switch->switch"


def floor_pct(sample_count):
    """The Poisson error floor at 1/256, as a percentage. c = number of sFlow samples."""
    return 196.0 * math.sqrt(1.0 / sample_count) if sample_count > 0 else float("inf")


def samples_from_bytes(byts, sampling_n=256, avg_pkt=1400):
    return byts / avg_pkt / sampling_n if avg_pkt else 0.0


# --------------------------------------------------------------------------- reconciliation
def reconcile(veth, graph):
    """One row per twin edge, each mapped onto the veth and direction that carries its bytes.

    A switch-sourced edge leaves by its own interface, so its bytes are that veth's TX. A
    host-sourced edge ARRIVES at a switch, so it is the *destination* interface's RX -- the
    host side of the wire has no sN-ethM at all. Keying both off src_interface would silently
    compare 128 host edges against the wrong counter, and the wrong counter is a real number,
    so nothing downstream would look broken.
    """
    rows = []
    for (sd, si, dd, di), a in graph.items():
        if sd != HOST_DPID:
            iface, direction = f"s{sd}-eth{si}", "tx"
        elif dd != HOST_DPID:
            iface, direction = f"s{dd}-eth{di}", "rx"
        else:
            continue                                   # host to host: not a thing in this model
        if iface not in veth:
            continue
        rx, tx, _dt = veth[iface]
        src = "h" if sd == HOST_DPID else f"s{sd}"
        dst = "h" if dd == HOST_DPID else f"s{dd}"
        rows.append({
            "edge": f"{src}->{dst}@{iface}.{direction}",
            "iface": iface,
            "direction": direction,
            "cls": edge_class(sd, dd),
            "veth_bytes": tx if direction == "tx" else rx,
            "twin_bytes": a["bytes"],
            "samples": a["samples"],
            "nonzero": a["nonzero"],
            "first_bps": a["first_bps"],
            "declared": a["declared"],
            "util_max": max(a["util"]) if a["util"] else None,
        })
    return rows


def summarise(rows, sampling_n=256):
    out = {}
    by = collections.defaultdict(list)
    for r in rows:
        if r["twin_bytes"] is None:
            continue
        by[r["cls"]].append(r)
    for cls, rs in sorted(by.items()):
        v = sum(r["veth_bytes"] for r in rs)
        t = sum(r["twin_bytes"] for r in rs)
        ratios = [r["twin_bytes"] / r["veth_bytes"] for r in rs
                  if r["veth_bytes"] > 1_000_000]           # idle edges carry no information
        out[cls] = {
            "edges": len(rs), "loaded": len(ratios),
            "veth_bytes": v, "twin_bytes": t,
            "ratio": (t / v) if v else None,
            "per_edge_min": min(ratios) if ratios else None,
            "per_edge_max": max(ratios) if ratios else None,
        }
    return out


def active_window(path, frac=0.35):
    """The span where the fabric is actually carrying traffic, read off the veth stream itself.

    The nominal window in meta.json starts when run_plane.sh recorded T_FLOW_START, but
    run_flows.sh then spends a minute resolving 128 host namespaces and clearing stale servers
    before a single packet moves. Anchoring on the nominal window therefore folds a dead period
    into the measurement: the RATIO survives it (both streams see the same dead time) but the
    per-edge sample counts, the error floors derived from them, and any statement about offered
    load do not.

    So: total bytes per sweep, and keep the contiguous span above `frac` of the peak sweep rate.
    """
    sweeps = collections.defaultdict(int)
    with open(path) as fh:
        fh.readline()
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 4:
                continue
            sweeps[round(float(parts[0]), 1)] += int(parts[2]) + int(parts[3])
    ts = sorted(sweeps)
    if len(ts) < 4:
        return None
    rates = [((sweeps[ts[i + 1]] - sweeps[ts[i]]) / max(1e-9, ts[i + 1] - ts[i]), ts[i], ts[i + 1])
             for i in range(len(ts) - 1)]
    peak = max(r for r, _, _ in rates)
    live = [(a, b) for r, a, b in rates if r >= frac * peak]
    if not live:
        return None
    return live[0][0], live[-1][1]


# --------------------------------------------------------------------------- loss attribution
def ip_from_packed(n):
    """The graph packs IPv4 little-endian: 192653504 -> 192.168.123.11."""
    return ".".join(str((n >> s) & 0xFF) for s in (0, 8, 16, 24))


def host_ports(graph_body):
    """{host_ip: (switch_dpid, iface_no)} from the switch->host edges."""
    out = {}
    for e in graph_body.get("edges", []):
        if e["dst_dpid"] == HOST_DPID and e.get("dst_ip"):
            out[ip_from_packed(e["dst_ip"][0])] = (e["src_dpid"], e["src_interface"])
    return out


def attribute_loss(rundir, veth):
    """PREREG A-6: did the fabric drop it, or did the receiving host?

    iperf3 reports loss measured at the RECEIVER, so it covers both "bmv2 or a veth queue
    dropped the packet" and "the iperf3 process was not scheduled and its socket buffer
    overflowed". Those need different fixes and look identical in the loss column.

    The discriminator is the switch port facing the server. Its TX is what the fabric handed to
    the host. If that matches what the client offered but iperf3 saw less, the packet crossed
    the whole fabric and died on the host side.
    """
    import glob
    first = None
    with open(os.path.join(rundir, "graph.jsonl")) as fh:
        for line in fh:
            rec = json.loads(line)
            if rec["body"]:
                first = rec["body"]
                break
    if first is None:
        return None
    ports = host_ports(first)

    per_port_offered = collections.defaultdict(float)
    per_port_received = collections.defaultdict(float)
    flows = 0
    for p in sorted(glob.glob(os.path.join(rundir, "iperf", "cli_*.json"))):
        try:
            j = json.load(open(p))
            s = j["end"]["sum"]
        except Exception:
            continue
        srv = os.path.basename(p).split("_to_")[1].rsplit("_", 1)[0]      # e.g. h68
        ip = f"10.0.0.{srv[1:]}"
        if ip not in ports:
            continue
        flows += 1
        dpid, ifno = ports[ip]
        iface = f"s{dpid}-eth{ifno}"
        secs = s.get("seconds") or 1.0
        offered = s["bits_per_second"] * secs / 8.0
        lost = s.get("lost_percent", 0.0) / 100.0
        per_port_offered[iface] += offered
        per_port_received[iface] += offered * (1.0 - lost)

    tot_off = sum(per_port_offered.values())
    tot_rcv = sum(per_port_received.values())
    tot_veth = sum(veth[i][1] for i in per_port_offered if i in veth)   # tx toward the host
    return {"flows": flows, "offered": tot_off, "iperf_received": tot_rcv,
            "veth_tx_to_host": tot_veth,
            "delivered_by_fabric_pct": 100.0 * tot_veth / tot_off if tot_off else None,
            "seen_by_iperf_pct": 100.0 * tot_rcv / tot_off if tot_off else None}


# ------------------------------------------------------------------ integrator known-good
def integrator_check():
    """Does the rate-to-bytes integration recover an analytically known answer?

    WHY THIS EXISTS, and why it is separate from --selftest. Both this analyser and the auditer's
    independent recomputation turn `link_bandwidth_usage_bps` samples into bytes by summing
    rate x dt. Two people agreeing means nothing if they share an assumption, and neither of us
    had ever checked that this one recovers a known integral -- it is our common single point of
    failure. Pointed out by 8/25 auditor on 2026-08-25; it needs no lab, so it is done first.

    Each case has a closed-form answer. Irregular spacing is included deliberately: the real
    pollers never hit their nominal interval, so uniform-dt cases would not exercise the path the
    measurements actually took.
    """
    import random
    cases = []

    # 1. Constant rate. bytes = R*T/8, exactly.
    cases.append(("constant 80 Mbit/s for 300 s, dt=2",
                  [(t, 80e6) for t in range(0, 302, 2)], 80e6 * 300 / 8))

    # 2. Same integral, wildly irregular spacing. A correct integrator does not care.
    ts, t = [], 0.0
    rnd = random.Random(1)
    while t < 300:
        ts.append((t, 80e6))
        t += rnd.choice([0.4, 1.1, 2.0, 3.7, 6.2])
    ts.append((300.0, 80e6))
    cases.append(("constant 80 Mbit/s, irregular dt 0.4-6.2 s", ts, 80e6 * 300 / 8))

    # 3. Linear ramp 0 -> 100 Mbit/s. Integral of a ramp is the triangle: R_max*T/2/8.
    #    Left-endpoint summation under-reads a ramp by exactly one step's triangle, so the
    #    tolerance below is not slack -- it is the known discretisation error, and stating it is
    #    the point: an integrator that is exact on a constant can still be biased on a trend.
    cases.append(("linear ramp 0 -> 100 Mbit/s over 300 s, dt=1",
                  [(t, 100e6 * t / 300.0) for t in range(0, 301)], 100e6 * 300 / 2 / 8))

    # 4. A gap. The real pollers stall; bytes during a stall are attributed to the stalled
    #    interval, which is the behaviour the reports rely on.
    seq = [(t, 40e6) for t in range(0, 100, 2)] + [(160.0, 40e6)] + \
          [(t, 40e6) for t in range(162, 302, 2)]
    cases.append(("constant 40 Mbit/s with a 60 s poller stall", seq, 40e6 * 300 / 8))

    print("integrator known-good (rate x dt -> bytes)")
    worst = 0.0
    fails = []
    for name, series, expected in cases:
        got, prev = 0.0, None
        for t, bps in series:
            if prev is not None:
                got += bps * (t - prev) / 8.0
            prev = t
        err = abs(got - expected) / expected * 100 if expected else 0.0
        worst = max(worst, err)
        flag = "ok      " if err < 0.6 else "🔴 FAIL "
        if err >= 0.6:
            fails.append(f"{name}: {err:.2f}%")
        print(f"  {flag} {name:<52} recovered {got/1e9:7.4f} GB vs {expected/1e9:7.4f} "
              f"({err:+.3f}%)")

    # The check must be able to fail. A deliberately wrong integrator (nominal dt instead of the
    # real gaps) is run through case 2, where it should be badly wrong.
    nominal_dt = 2.0
    got = sum(bps * nominal_dt / 8.0 for _, bps in cases[1][1])
    bad_err = abs(got - cases[1][2]) / cases[1][2] * 100
    print(f"\n  control: assuming the nominal 2 s dt on irregular data reads {bad_err:.0f}% off")
    if bad_err < 10:
        fails.append("the control did not misread -- this check cannot detect a broken integrator")

    print()
    if fails:
        print("🔴 FAIL:")
        for f in fails:
            print(f"   - {f}")
        return 1
    print(f"PASS: worst error {worst:.3f}%, and the deliberately-wrong control is caught")
    return 0


# --------------------------------------------------------------------------- selftest
def selftest(tmpdir):
    """Known input, known answer, and one edge that MUST be flagged."""
    os.makedirs(tmpdir, exist_ok=True)
    vp = os.path.join(tmpdir, "veth.tsv")
    gp = os.path.join(tmpdir, "graph.jsonl")

    # s1-eth1  100 MB out over 10 s, twin agrees                      -> ratio 1.0
    # s1-eth2  100 MB out, twin reports half                          -> ratio 0.5, must be seen
    # s1-eth3  RX and TX deliberately DIFFERENT (60 MB in, 999 MB out). The host->switch edge
    #          must be scored against RX; scoring it against TX gives 0.060 instead of 1.0,
    #          so this case is what proves the direction logic rather than assuming it.
    with open(vp, "w") as fh:
        fh.write("ts\tiface\trx_bytes\ttx_bytes\n")
        for i, ts in enumerate((1000.0, 1010.0)):
            fh.write(f"{ts}\ts1-eth1\t{i*50_000_000}\t{i*100_000_000}\n")
            fh.write(f"{ts}\ts1-eth2\t0\t{i*100_000_000}\n")
            fh.write(f"{ts}\ts1-eth3\t{i*60_000_000}\t{i*999_000_000}\n")

    # 100 MB in 10 s = 80 Mbit/s. Two samples 10 s apart; the first contributes dt=0.
    with open(gp, "w") as fh:
        for ts, bps2 in ((1000.0, 40_000_000), (1010.0, 40_000_000)):
            body = {"edges": [
                {"src_dpid": 1, "src_interface": 1, "dst_dpid": 5, "dst_interface": 1,
                 "link_bandwidth_usage_bps": 80_000_000, "link_bandwidth_bps": 1_000_000_000,
                 "link_bandwidth_utilization_percent": 8.0},
                {"src_dpid": 1, "src_interface": 2, "dst_dpid": 0, "dst_interface": 0,
                 "link_bandwidth_usage_bps": bps2, "link_bandwidth_bps": 1_000_000_000,
                 "link_bandwidth_utilization_percent": 4.0},
                # host -> switch: arrives at s1 interface 3, so it is that veth's RX.
                # 60 MB in 10 s = 48 Mbit/s.
                {"src_dpid": 0, "src_interface": 0, "dst_dpid": 1, "dst_interface": 3,
                 "link_bandwidth_usage_bps": 48_000_000, "link_bandwidth_bps": 1_000_000_000,
                 "link_bandwidth_utilization_percent": 4.8},
            ]}
            fh.write(json.dumps({"ts": ts, "body": body}) + "\n")

    veth, nrows, _span = read_veth(vp)
    graph, ok, miss = read_graph(gp)
    rows = reconcile(veth, graph)
    s = summarise(rows)

    fails = []
    if nrows != 6:
        fails.append(f"veth reader saw {nrows} rows, expected 6")
    if ok != 2:
        fails.append(f"graph reader saw {ok} usable samples, expected 2")
    if not veth:
        fails.append("veth reader returned nothing -- an empty parse must never read as a pass")
    got = {c: round(v["ratio"], 4) for c, v in s.items() if v["ratio"] is not None}
    if got.get("switch->switch") != 1.0:
        fails.append(f"accurate edge should reconcile at 1.0, got {got.get('switch->switch')}")
    if got.get("switch->host") != 0.5:
        fails.append(f"the deliberately-halved edge should read 0.5, got {got.get('switch->host')}"
                     " -- a checker that cannot see a 2x error cannot see a real one")
    if got.get("host->switch") != 1.0:
        fails.append(f"host->switch should score against RX and read 1.0, got "
                     f"{got.get('host->switch')}; ~0.06 means it was scored against TX, which is "
                     f"a real number and would look like a real defect")
    # the floor must be a number, and must shrink as samples grow
    if not (floor_pct(100) > floor_pct(10_000) > 0):
        fails.append("error floor is not monotonically decreasing in sample count")

    print("selftest:")
    for c, v in sorted(s.items()):
        print(f"  {c:<15} ratio={v['ratio']:.4f}  veth={v['veth_bytes']:,}  "
              f"twin={v['twin_bytes']:,.0f}")
    print(f"  floor at c=100: {floor_pct(100):.1f}%   at c=10000: {floor_pct(10_000):.1f}%")
    if fails:
        print("\n🔴 FAIL -- do not trust this analyser:")
        for f in fails:
            print(f"   - {f}")
        return 1
    print("\nPASS: reconciles a known-good edge at 1.0 and flags a known-bad one at 0.5")
    return 0


# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", help="run directory holding veth.tsv, graph.jsonl, flows.jsonl")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--integrator-check", action="store_true",
                    help="recover analytically known integrals; needs no data")
    ap.add_argument("--window", help="t_lo,t_hi unix seconds to restrict to")
    ap.add_argument("--auto-window", action="store_true",
                    help="derive the window from when the veth counters are actually moving")
    ap.add_argument("--json", help="write the row table here")
    a = ap.parse_args()

    if a.integrator_check:
        return integrator_check()

    if a.selftest:
        return selftest("/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/"
                        "97128227-cf07-4b66-a198-f57756a1a0ef/scratchpad/an_selftest")
    if not a.dir:
        print(__doc__)
        return 2

    t_lo = t_hi = None
    if a.window:
        t_lo, t_hi = (float(x) for x in a.window.split(","))
    elif a.auto_window:
        w = active_window(os.path.join(a.dir, "veth.tsv"))
        if not w:
            print("🔴 INCONCLUSIVE: no active period found in the veth stream")
            return 2
        t_lo, t_hi = w
        print(f"auto window: {t_hi - t_lo:.0f}s of moving counters")

    veth, nrows, span = read_veth(os.path.join(a.dir, "veth.tsv"), t_lo, t_hi)
    # Integrate the twin over the span the veth ACTUALLY covers, not the nominal window: the two
    # pollers run at different real rates, and a ratio built from mismatched spans is wrong by
    # exactly the mismatch.
    graph, ok, miss = read_graph(os.path.join(a.dir, "graph.jsonl"), span[0], span[1])
    print(f"veth: {len(veth)} interfaces from {nrows} rows, "
          f"span {span[1]-span[0]:.1f}s" if span[0] else "veth: no usable span")
    print(f"twin: {ok} usable graph samples, {miss} failed polls, {len(graph)} distinct edges")
    if ok < 3:
        print("🔴 INCONCLUSIVE: fewer than three twin samples inside the veth span -- the "
              "integration has nothing to integrate over.")
        return 2
    if not veth or not ok:
        print("🔴 INCONCLUSIVE: one of the two streams is empty. Absence of a discrepancy in an "
              "empty comparison is not evidence.")
        return 2

    rows = reconcile(veth, graph)
    s = summarise(rows)
    print(f"\n{'class':<16}{'edges':>6}{'loaded':>7}{'veth GB':>10}{'twin GB':>10}"
          f"{'ratio':>8}{'per-edge min':>14}{'max':>8}")
    for cls, v in sorted(s.items()):
        if v["ratio"] is None:
            continue
        print(f"{cls:<16}{v['edges']:>6}{v['loaded']:>7}{v['veth_bytes']/1e9:>10.3f}"
              f"{v['twin_bytes']/1e9:>10.3f}{v['ratio']:>8.4f}"
              f"{(v['per_edge_min'] or 0):>14.3f}{(v['per_edge_max'] or 0):>8.3f}")

    # P4/P5/P8 evidence, printed rather than judged -- the report does the judging.
    print("\nfirst-sample bps (P4: edges reporting the declared 1 Gbit/s before any sample):")
    firsts = collections.Counter(r["first_bps"] for r in rows if r["first_bps"] is not None)
    for bps, n in firsts.most_common(6):
        print(f"  {bps:>14,} bps  x{n}")

    print("\nloaded veth edges the twin reports as zero (P5: the ~3 Mbit/s quantisation):")
    zeros = [r for r in rows if r["twin_bytes"] == 0 and r["veth_bytes"] > 1_000_000]
    for r in sorted(zeros, key=lambda r: -r["veth_bytes"])[:12]:
        mbps = r["veth_bytes"] * 8 / 1e6
        print(f"  {r['edge']:<20} veth={r['veth_bytes']:>13,} B  ({mbps:.1f} Mbit over window)")
    print(f"  ({len(zeros)} such edges)")

    print("\ndeclared capacity seen by the twin (P8: 10 Gbit/s links Mininet never shaped):")
    dec = collections.Counter(r["declared"] for r in rows if r["declared"])
    for d, n in dec.most_common():
        print(f"  {d:>14,} bps  x{n}")

    att = attribute_loss(a.dir, veth)
    if att and att["offered"]:
        print(f"\nloss attribution (PREREG A-6), {att['flows']} flows:")
        print(f"  offered by clients        {att['offered']/1e9:8.3f} GB")
        print(f"  handed to hosts by fabric {att['veth_tx_to_host']/1e9:8.3f} GB  "
              f"({att['delivered_by_fabric_pct']:.1f}% of offered)")
        print(f"  seen by iperf3 receivers  {att['iperf_received']/1e9:8.3f} GB  "
              f"({att['seen_by_iperf_pct']:.1f}% of offered)")
        gap = att["delivered_by_fabric_pct"] - att["seen_by_iperf_pct"]
        print(f"  => fabric lost {100 - att['delivered_by_fabric_pct']:.1f} pts, "
              f"host lost {gap:.1f} pts")

    if a.json:
        with open(a.json, "w") as fh:
            json.dump({"summary": s, "rows": rows}, fh, indent=1, default=str)
        print(f"\nrows -> {a.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
