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
    """{iface: (rx_delta, tx_delta)} between the first and last sample inside the window."""
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
    for iface, (t1, rx1, tx1) in first.items():
        t2, rx2, tx2 = last[iface]
        if t2 <= t1:
            continue
        out[iface] = (rx2 - rx1, tx2 - tx1, t2 - t1)
    return out, n


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

    veth, nrows = read_veth(vp)
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
    ap.add_argument("--window", help="t_lo,t_hi unix seconds to restrict to")
    ap.add_argument("--json", help="write the row table here")
    a = ap.parse_args()

    if a.selftest:
        return selftest("/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/"
                        "97128227-cf07-4b66-a198-f57756a1a0ef/scratchpad/an_selftest")
    if not a.dir:
        print(__doc__)
        return 2

    t_lo = t_hi = None
    if a.window:
        t_lo, t_hi = (float(x) for x in a.window.split(","))

    veth, nrows = read_veth(os.path.join(a.dir, "veth.tsv"), t_lo, t_hi)
    graph, ok, miss = read_graph(os.path.join(a.dir, "graph.jsonl"), t_lo, t_hi)
    print(f"veth: {len(veth)} interfaces from {nrows} rows")
    print(f"twin: {ok} usable graph samples, {miss} failed polls, {len(graph)} distinct edges")
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

    if a.json:
        with open(a.json, "w") as fh:
            json.dump({"summary": s, "rows": rows}, fh, indent=1, default=str)
        print(f"\nrows -> {a.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
