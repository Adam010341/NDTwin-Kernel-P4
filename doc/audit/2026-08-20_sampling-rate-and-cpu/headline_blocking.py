#!/usr/bin/env python3
"""
Does the northbound API serialise under concurrent consumers?

[Co-developed with claude code -- Adam]

Usage:  headline_blocking.py <out.json> [seconds-per-level]

The twin's central claim is that seven applications consume it simultaneously through /ndt/.
That claim has never been tested under concurrency: run_layers.sh and run_contract_test.py
issue requests serially, so L2/L3 being green says nothing about four apps polling at once --
which is what Web-GUI, Visualizer, NSR and the Energy app actually do, every second.

The kernel's HTTP server is `net::io_context ioc{1}` (src/main.cpp:316) -- one thread -- and
several handlers shell out synchronously through utils::execCommand's popen (southbound flow
posts at HttpRoutingStrategyBase.cpp:70, topology polls at TopologyAndFlowMonitor.cpp:476-502).
A single-threaded server with blocking handlers has a signature that does not need a fault
injected to reveal it:

    if requests are served one at a time, then as concurrency N rises,
      - throughput stays FLAT at 1/T (T = one request's service time), and
      - latency rises LINEARLY, p50 ~ N*T/2, p95 -> N*T

    if they are served concurrently, throughput rises with N until something else saturates,
    and latency stays flat.

So the experiment is just: sweep N, plot both. No fault injection, no state mutation, nothing
that can leave the fabric in a different condition than it started -- every request below is a
GET. That matters because this has to be safe to run before a demo.

WHAT THIS DELIBERATELY DOES NOT DO
----------------------------------
It does not try to make a handler slow on purpose. The obvious candidates cannot: in MININET
`get_cpu_utilization`, `get_memory_utilization` and `get_temperature` never touch SNMP or SSH
at all -- they return `hash(ip) % n` arithmetic (DeviceConfigurationAndPowerManager.cpp), so
they are among the *fastest* endpoints here, not the slowest. The genuinely blocking paths are
the southbound popen calls, and reaching those means mutating routing state. If phase 1 shows
serialisation, that is already the finding; injection would only make it larger.

READING THE RESULT HONESTLY
---------------------------
Flat latency would mean this concern does not bite at the scale the twin actually runs at, and
that is a perfectly good outcome to publish -- "we measured it, it holds to N apps" is a
stronger sentence than silence. Do not go looking for a way to make it fail.
"""
import json
import statistics as st
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

URL = "http://localhost:8000/ndt/get_graph_data"
LEVELS = [1, 2, 4, 8, 16]


def one_request():
    """Wall-clock latency of a single GET, or None if it failed."""
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(URL, timeout=30) as r:
            r.read()
    except Exception:
        return None
    return time.perf_counter() - t0


def level(n, seconds):
    """
    n clients hammering back-to-back for `seconds`.

    Back-to-back rather than at a fixed 1 Hz on purpose: a fixed rate measures whether the
    server keeps up with that rate, which is a different and easier question. Closed-loop
    saturation measures the service time itself, and service time is what a single-threaded
    server multiplies by concurrency.
    """
    deadline = time.time() + seconds
    lat, fails = [], 0

    def worker():
        out, f = [], 0
        while time.time() < deadline:
            d = one_request()
            if d is None:
                f += 1
            else:
                out.append(d)
        return out, f

    with ThreadPoolExecutor(max_workers=n) as ex:
        for out, f in ex.map(lambda _: worker(), range(n)):
            lat.extend(out)
            fails += f

    if not lat:
        return None
    lat.sort()
    return {
        "n": n,
        "requests": len(lat),
        "failures": fails,
        "throughput_rps": len(lat) / seconds,
        "p50_ms": lat[len(lat) // 2] * 1000,
        "p95_ms": lat[int(len(lat) * 0.95)] * 1000,
        "p99_ms": lat[int(len(lat) * 0.99)] * 1000,
        "max_ms": lat[-1] * 1000,
        "mean_ms": st.mean(lat) * 1000,
    }


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "headline_blocking.json"
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0

    # A warm-up level that is discarded: the first requests after an idle period pay for
    # whatever the kernel lazily builds, and folding that into the N=1 baseline would make
    # every later level look better by comparison.
    level(1, 5)

    results = []
    for n in LEVELS:
        r = level(n, secs)
        if r is None:
            print(f"N={n}: every request failed", file=sys.stderr)
            continue
        results.append(r)
        print(f"N={r['n']:>3}  {r['throughput_rps']:>7.1f} req/s   "
              f"p50 {r['p50_ms']:>7.1f} ms   p95 {r['p95_ms']:>7.1f} ms   "
              f"p99 {r['p99_ms']:>7.1f} ms   fails {r['failures']}")

    if results:
        base = results[0]
        print("\n  N   throughput vs N=1   p50 vs N=1   serialised would predict")
        for r in results:
            print(f"{r['n']:>3}   {r['throughput_rps']/base['throughput_rps']:>13.2f}x   "
                  f"{r['p50_ms']/base['p50_ms']:>9.2f}x   "
                  f"{'throughput 1.00x, p50 %.2fx' % r['n']:>26}")

    with open(out_path, "w") as fh:
        json.dump({"url": URL, "seconds_per_level": secs, "levels": results}, fh, indent=2)
    print(f"\nwrote {out_path}")


if __name__ == "__main__":
    main()
