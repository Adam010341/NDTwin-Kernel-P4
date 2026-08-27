#!/usr/bin/env python3
"""Ticket P: slice every instrument by each arm's window and run the pre-registered read-out.

WHAT THIS ANSWERS. Ticket 1 measured that under CPU contention the twin under-reports 34% while
the data plane loses 5%, excluded collector drops and proxy starvation, and refused to name a
third candidate for want of per-process data. P-1 puts the cut at the proxy's send side: if
samples_sent falls with the twin the loss is upstream (a resource limit); if it holds while the
twin falls the loss is downstream, inside the kernel, and that is a bug rather than a limit.

WINDOWS. Every instrument is sliced by the SAME window the twin/veth ratio is computed over --
active_window() read off the arm's own veth stream, not the nominal window in meta.json. The two
sides of a ratio have to come from one population and one execution; this project has produced
three ratios in a single round that did not, and they inverted the conclusion.

FAILURE IS NOT ZERO. A sampler with fewer than two rows inside a window returns None and prints
NO-DATA. Zero is a legal value for every counter here and it is also what a broken reader emits,
and "the send side stopped sending" is precisely the finding this round exists to detect. Same
reason GET /sflow/stats answers 503 instead of {"samples_sent": 0}.

Usage: analyze_P.py [--raw DIR] [--json OUT]
[Co-developed with claude code -- Adam]
"""
import argparse
import json
import math
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
L = HERE.parent / "2026-08-25_large-scale-concurrent"
sys.path.insert(0, str(L))

from analyze import (                      # noqa: E402  -- the loaders ticket 1's numbers came from
    active_window, read_veth, read_graph, reconcile, summarise,
)

ARMS = ["P_Q", "P_B14", "P_B28", "P_Qp"]
BURNERS = {"P_Q": 0, "P_B14": 14, "P_B28": 28, "P_Qp": 0}
N_SWITCHES = 10
CEILING_BPS = 0.9e9                        # Pb-2: an edge this close to the declared 1 Gbit/s
                                           # may be reading the representation ceiling, not loss


def rows_in(path, lo, hi):
    out = []
    if not os.path.exists(path):
        return out
    for line in open(path):
        try:
            r = json.loads(line)
        except Exception:
            continue
        t = r.get("t")
        if t is not None and lo <= t <= hi:
            out.append(r)
    return out


def delta(rows, key):
    """Last minus first inside the window, plus a monotonicity verdict.

    Returns (value, monotonic, n). value is None when there are not two rows to differentiate --
    an arm whose sampler was dead must not serialise the same as an arm where nothing was sent.
    """
    vals = [r[key] for r in rows if key in r and isinstance(r[key], (int, float))]
    if len(vals) < 2:
        return None, None, len(vals)
    mono = all(b >= a for a, b in zip(vals, vals[1:]))
    return vals[-1] - vals[0], mono, len(vals)


def bmv2_cpu(rows, span_s):
    """Summed and per-switch CPU seconds over the window, and the switch-count check.

    A switch that dies mid-arm makes the total quietly smaller, which is the exact shape of the
    signal we are looking for -- so n_switches is asserted on every row, not sampled.
    """
    if len(rows) < 2:
        return None
    counts = {len(r.get("procs", {})) for r in rows}
    first, last = rows[0]["procs"], rows[-1]["procs"]
    tck = rows[0].get("clk_tck", 100)
    per_sw, total = {}, 0
    for pid, a in first.items():
        b = last.get(pid)
        if b is None:                       # pid vanished: a restart, not a measurement
            continue
        j = (b["utime"] + b["stime"]) - (a["utime"] + a["stime"])
        per_sw[a.get("sw") or pid] = j / tck
        total += j / tck
    return {
        "cpu_s": total,
        "pct_of_wall": 100.0 * total / span_s if span_s else None,
        "per_switch_cpu_s": dict(sorted(per_sw.items())),
        "n_switches_seen": sorted(counts),
        "switch_count_ok": counts == {N_SWITCHES},
        "pids_survived": len(per_sw),
    }


def arm_report(raw, arm):
    d = L / "raw" / arm
    if not d.is_dir():
        return {"arm": arm, "status": "NOT RUN"}
    w = active_window(str(d / "veth.tsv"))
    if not w:
        return {"arm": arm, "status": "NO ACTIVE WINDOW -- the veth stream never moved"}
    lo, hi = w
    span = hi - lo

    veth, nrows, vspan = read_veth(str(d / "veth.tsv"), lo, hi)
    graph, ok, miss = read_graph(str(d / "graph.jsonl"), vspan[0], vspan[1])
    rows = reconcile(veth, graph) if (veth and ok >= 3) else []
    s = summarise(rows) if rows else {}

    sf = rows_in(raw / "sflow_stats.jsonl", lo, hi)
    # 503 and 000 are different failures and must not be counted together: 503 means the emitter
    # was never injected (a wiring failure, and the one thing this endpoint exists to distinguish
    # from "the send side stopped"), while 000 is curl giving up on a loaded box -- a lost poll,
    # not a lost signal.
    wiring = [r for r in sf if r.get("http") == "503"]
    lost_polls = [r for r in sf if r.get("http") not in ("200", "503")]
    d_samples, mono_s, n_s = delta(sf, "samples_sent")
    d_grams, mono_g, _ = delta(sf, "datagrams_sent")
    d_err, _, _ = delta(sf, "send_errors")

    udp = rows_in(raw / "udp6343.jsonl", lo, hi)
    d_drops, _, _ = delta(udp, "drops")
    rxq = [r["rx_queue"] for r in udp if "rx_queue" in r]

    prx = rows_in(raw / "proxy_cpu.jsonl", lo, hi)
    proxy = bmv2_cpu(prx, span)             # same shape: {pid: {utime, stime}}

    # Pb-2: did any single edge get close enough to the declared capacity that the twin could be
    # reading a clamp rather than a loss? Ticket N saw a 99.5% under-report ABOVE capacity, which
    # is a different phenomenon and must not be merged with this one.
    near_ceiling = sorted(
        ((r["edge"], r["veth_bytes"] * 8.0 / span) for r in rows
         if r["veth_bytes"] * 8.0 / span >= CEILING_BPS),
        key=lambda kv: -kv[1])

    return {
        "arm": arm, "status": "ok", "burners": BURNERS[arm],
        "window": [lo, hi], "span_s": span,
        "twin": {cls: {"veth_GB": v["veth_bytes"] / 1e9, "twin_GB": v["twin_bytes"] / 1e9,
                       "ratio": v["ratio"], "edges": v["edges"], "loaded": v["loaded"]}
                 for cls, v in sorted(s.items())},
        "twin_samples_ok": ok, "twin_samples_failed": miss,
        # samples_per_s, not samples_sent, is what arms get compared on. The arms do NOT share a
        # window length -- B28 came in 8% short and an arm still in flight is shorter still -- so
        # comparing raw counts silently folds the window difference into the effect. Both sides of
        # a ratio have to be the same population; this project has inverted a conclusion that way.
        # Samples are taken per packet per switch, so fewer samples is EXPECTED if the fabric is
        # carrying less. samples_per_GB divides by what the veths actually moved, which is the
        # only form of this number that can distinguish "sampling degraded" from "less traffic".
        # (Edge-bytes, summed over all three classes: a packet crossing two hops counts twice.
        # That is fine as a denominator because every arm counts it the same way.)
        "edge_GB": sum(v["veth_bytes"] for v in s.values()) / 1e9 if s else None,
        "sflow": {"samples_sent": d_samples, "datagrams_sent": d_grams, "send_errors": d_err,
                  "samples_per_s": (d_samples / span) if d_samples is not None and span else None,
                  "samples_per_GB": (
                      d_samples / (sum(v["veth_bytes"] for v in s.values()) / 1e9)
                      if d_samples is not None and s and sum(v["veth_bytes"] for v in s.values())
                      else None),
                  "monotonic": mono_s, "grams_monotonic": mono_g, "polls": n_s,
                  "wiring_503": len(wiring), "lost_polls": len(lost_polls),
                  "lost_poll_codes": sorted({r.get("http") for r in lost_polls}) or None},
        "bmv2": bmv2_cpu(rows_in(raw / "bmv2_cpu.jsonl", lo, hi), span),
        "proxy": {"cpu_s": proxy["cpu_s"], "pct_of_wall": proxy["pct_of_wall"]} if proxy else None,
        "udp": {"drops_delta": d_drops, "rx_queue_max": max(rxq) if rxq else None,
                "polls": len(udp)},
        "near_ceiling_edges": near_ceiling[:5],
    }


def fmt(v, spec=".4f", none="NO-DATA"):
    return none if v is None else format(v, spec)


def sentinel(name, q, b14, qp):
    """|Q'-Q| > |B14-Q|/2  =>  CONFOUNDED. Ticket 1's own rule, applied to every metric here
    rather than only to the one wearing the verdict label -- that omission is what let ticket 1
    ship a claim its own sentinel had already killed."""
    if None in (q, b14, qp):
        return f"  {name:<22} NO-DATA in one of Q / B14 / Q' -- sentinel not evaluable"
    drift, effect = abs(qp - q), abs(b14 - q)
    bad = drift > effect / 2
    return (f"  {name:<22} |Q'-Q| = {drift:.4g}  vs  |B14-Q|/2 = {effect/2:.4g}   "
            + ("🔴 CONFOUNDED" if bad else "✅ interpretable"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", default=str(HERE / "raw"))
    ap.add_argument("--json")
    a = ap.parse_args()
    raw = Path(a.raw)

    reps = [arm_report(raw, arm) for arm in ARMS]
    by = {r["arm"]: r for r in reps}

    # An arm still in flight has a short window and otherwise looks exactly like a completed arm
    # whose fabric went quiet early -- both produce real numbers over a real window. Flag it, or
    # the analysis silently reports half an arm as a whole one.
    spans = sorted(r["span_s"] for r in reps if r["status"] == "ok")
    ref = spans[len(spans) // 2] if spans else None
    for r in reps:
        if r["status"] == "ok" and ref and r["span_s"] < 0.80 * ref:
            r["incomplete"] = True
            print(f"⚠️  {r['arm']}: window {r['span_s']:.0f}s vs {ref:.0f}s median -- INCOMPLETE "
                  f"(arm still running, or it ended early). Excluded from verdicts below.")

    print(f"\n{'arm':7}{'burn':>5}{'span':>7}{'samp/s':>9}{'edge GB':>9}{'samp/GB':>9}"
          f"{'bmv2 CPU%':>11}{'proxy%':>8}{'h->s':>8}{'s->h':>8}{'s->s':>8}{'drops':>7}")
    for r in reps:
        if r["status"] != "ok":
            print(f"{r['arm']:7}  {r['status']}")
            continue
        t, b, f = r["twin"], r["bmv2"], r["sflow"]
        flag = " ⚠️ INCOMPLETE" if r.get("incomplete") else ""
        print(f"{r['arm']:7}{r['burners']:>5}{r['span_s']:>7.0f}"
              f"{fmt(f['samples_per_s'], '.1f'):>9}"
              f"{fmt(r['edge_GB'], '.2f'):>9}"
              f"{fmt(f['samples_per_GB'], ',.0f'):>9}"
              f"{fmt(b and b['pct_of_wall'], '.1f'):>11}"
              f"{fmt(r['proxy'] and r['proxy']['pct_of_wall'], '.1f'):>8}"
              f"{fmt(t.get('host->switch', {}).get('ratio')):>8}"
              f"{fmt(t.get('switch->host', {}).get('ratio')):>8}"
              f"{fmt(t.get('switch->switch', {}).get('ratio')):>8}"
              f"{fmt(r['udp']['drops_delta'], 'd'):>7}{flag}")

    print("\n--- abort conditions (P-7) ---")
    for r in reps:
        if r["status"] != "ok":
            continue
        f = r["sflow"]
        b = r["bmv2"]
        for label, ok_, detail in (
            ("samples_sent monotonic", f["monotonic"], f"{f['polls']} polls"),
            ("emitter wired (no 503)", f["wiring_503"] == 0, f"{f['wiring_503']} x 503"),
            ("polls all landed", f["lost_polls"] == 0,
             f"{f['lost_polls']} lost {f['lost_poll_codes'] or ''} of {f['polls']} -- "
             f"transport, not signal"),
            ("10 switches throughout", b and b["switch_count_ok"],
             f"saw {b['n_switches_seen'] if b else 'NO-DATA'}"),
            ("udp drops zero", r["udp"]["drops_delta"] == 0,
             f"delta {fmt(r['udp']['drops_delta'], 'd')}, rx_max {r['udp']['rx_queue_max']}"),
            ("no edge near ceiling", not r["near_ceiling_edges"],
             f"{len(r['near_ceiling_edges'])} edges >= 0.9 Gbit/s"),
        ):
            mark = "✅" if ok_ else ("🔴" if ok_ is False else "⚠️ ")
            print(f"  {r['arm']:7} {mark} {label:<24} {detail}")

    print("\n--- sentinel, every metric (P-8) ---")
    q, b14, qp = by.get("P_Q"), by.get("P_B14"), by.get("P_Qp")
    def g(r, path):
        # An incomplete arm returns None rather than its partial value: a half-window number is
        # not a small effect, and the sentinel cannot tell the two apart.
        if not r or r.get("status") != "ok" or r.get("incomplete"):
            return None
        for k in path:
            r = (r or {}).get(k) if isinstance(r, dict) else None
        return r
    print(sentinel("samples/s", g(q, ["sflow", "samples_per_s"]),
                   g(b14, ["sflow", "samples_per_s"]), g(qp, ["sflow", "samples_per_s"])))
    print(sentinel("bmv2 CPU%", g(q, ["bmv2", "pct_of_wall"]),
                   g(b14, ["bmv2", "pct_of_wall"]), g(qp, ["bmv2", "pct_of_wall"])))
    for cls in ("host->switch", "switch->host", "switch->switch"):
        print(sentinel(f"twin ratio {cls}", g(q, ["twin", cls, "ratio"]),
                       g(b14, ["twin", cls, "ratio"]), g(qp, ["twin", cls, "ratio"])))

    print("\n--- read-out table (P-5) ---")
    sq = g(q, ["sflow", "samples_per_s"])
    s28 = g(by.get("P_B28"), ["sflow", "samples_per_s"])
    cq, c28 = g(q, ["bmv2", "pct_of_wall"]), g(by.get("P_B28"), ["bmv2", "pct_of_wall"])
    if sq and s28:
        ratio = s28 / sq
        cpu = "NO-DATA" if None in (cq, c28) else ("lower than Q" if c28 < cq else "flat/higher")
        if 0.60 <= ratio <= 0.75:
            verdict = ("✅ UPSTREAM, mechanism self-consistent" if cpu == "lower than Q"
                       else "⚠️  UPSTREAM but mechanism unnamed -- open a new question")
        elif 0.95 <= ratio <= 1.05:
            verdict = "🔴 DOWNSTREAM: the kernel received them and did not count them -- a BUG"
        elif 0.75 < ratio < 0.95:
            verdict = "uncertain band -- NO VERDICT, record as measured"
        else:
            verdict = "NONE OF THE ABOVE -- record standalone, do not round into a neighbour"
        print(f"  samples/s B28/Q = {ratio:.4f}  ({s28:.1f} vs {sq:.1f} per s)"
              f"   per-bmv2 CPU: {cpu}\n  => {verdict}")
        # Supplementary, NOT the pre-registered metric. P-5 判 samples_sent; samples/s is that
        # same quantity with the window difference taken out. samples/GB is a DIFFERENT question
        # -- it asks whether each forwarded byte still yields its share of samples -- and it is
        # reported beside the verdict rather than folded into it.
        gq = g(q, ["sflow", "samples_per_GB"])
        g28 = g(by.get("P_B28"), ["sflow", "samples_per_GB"])
        if gq and g28:
            print(f"  [supplementary, not pre-registered] samples/GB B28/Q = {g28/gq:.4f}  "
                  f"({g28:,.0f} vs {gq:,.0f} per GB)\n"
                  f"    ~1.0 => the fabric simply carried less; sampling per byte is intact.\n"
                  f"    <1.0 => each forwarded byte yielded fewer samples: sampling itself degraded.")
    else:
        print("  NO-DATA in Q or B28 -- no verdict. This is not 'no effect'.")

    if a.json:
        Path(a.json).write_text(json.dumps(reps, indent=1))
        print(f"\nwrote {a.json}")


if __name__ == "__main__":
    main()
