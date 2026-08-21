#!/usr/bin/env python3
"""
Ryu topology-endpoint response time vs host count -- experiment ② , first probe.

[Co-developed with claude code -- Adam]

Hypothesis under test: OVS 128-host failover is slower than P4 (3.12x, zero overlap)
because the *controller's* topology query amplifies with host count, not because the
data plane does.

Measures the three endpoints the kernel actually polls -- TopologyAndFlowMonitor builds
them as RYU_BASE_URL + {/switches,/hosts,/links} (tests/test_TopologyUrlAndPathJson.cpp
:112-114) -- so this measures the real read path, not a synthetic one.

DOES NOT bring the lab up and DOES NOT claim it. Run it against a fabric that is already
up; it refuses rather than guesses if the fabric is not the one you named.

Usage:
    python3 ryu_topo_latency.py 4    > ryu_topo_4host.json
    python3 ryu_topo_latency.py 128  > ryu_topo_128host.json

Then, with both files:
    python3 ryu_topo_latency.py --compare ryu_topo_4host.json ryu_topo_128host.json
"""
import json
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request

BASE = "http://localhost:8080/v1.0/topology"
# The Ryu app's own path table. Not part of /v1.0/topology, but it is the state that
# actually scales with host count (128 hosts -> 16256 ordered pairs), so leaving it out
# would test the cheap surface and miss the expensive one.
PATHS_URL = "http://localhost:8080/ryu_server/all_destination_paths"
ENDPOINTS = ("switches", "hosts", "links", "paths")
WARMUP = 3
REPS = 20


def endpoint_urls():
    urls = {ep: f"{BASE}/{ep}" for ep in ("switches", "hosts", "links")}
    urls["paths"] = PATHS_URL
    return urls


def fetch(url, timeout=30):
    """One timed GET. Returns (elapsed_s, payload_bytes, parsed)."""
    t0 = time.perf_counter()
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        body = resp.read()
    return time.perf_counter() - t0, len(body), json.loads(body)


def identify_fabric():
    """
    Prove what is running from the machine, not from what the caller believes.

    Same discipline as the bmv2 binary record: the run's own data must name the thing
    it measured. Reads /proc directly -- `ps | grep` matches this process's own command
    line (bitten twice on 2026-08-21).
    """
    import os
    procs = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/cmdline", "rb") as fh:
                argv = fh.read().decode("utf-8", "replace").replace("\0", " ").strip()
        except OSError:
            continue
        if argv:
            procs.append(argv)

    def count(needle):
        return sum(1 for p in procs if needle in p)

    switch_bins = sorted({tok for p in procs if "simple_switch_grpc" in p
                          for tok in p.split() if tok.endswith("simple_switch_grpc")})
    ovs = subprocess.run(["sudo", "-n", "ovs-vsctl", "list-br"],
                         capture_output=True, text=True)
    return {
        "bmv2_switches": count("simple_switch_grpc"),
        "bmv2_binary": switch_bins,
        "ryu_running": any("ryu-manager" in p or "ryu.cmd" in p for p in procs),
        "ovs_bridges": sorted(ovs.stdout.split()) if ovs.returncode == 0 else [],
        "kernel_running": count("ndtwin_kernel") > 0,
    }


def settle(expect_hosts, timeout=180.0, stable_reads=3, interval=2.0):
    """
    Wait for topology discovery to converge, then confirm it stays converged.

    Ryu learns hosts from traffic and links from LLDP, so an early read sees a partial
    graph. And per destination-paths-not-monotonic the count can fall back after rising,
    so one matching sample is not convergence -- the target has to hold across consecutive
    reads before the graph is treated as settled.

    Returns the settle trace so the record shows how it converged, not just that it did.
    """
    trace, hit, deadline = [], 0, time.time() + timeout
    while time.time() < deadline:
        try:
            _, _, hosts = fetch(f"{BASE}/hosts")
            n = len(hosts)
        except (urllib.error.URLError, OSError) as e:
            trace.append({"t": round(time.time(), 3), "error": str(e)})
            n = -1
        else:
            trace.append({"t": round(time.time(), 3), "hosts": n})
        hit = hit + 1 if n == expect_hosts else 0
        if hit >= stable_reads:
            return trace, True
        time.sleep(interval)
    return trace, False


def measure(expect_hosts):
    fabric = identify_fabric()
    if not fabric["ryu_running"]:
        sys.exit("refusing: ryu-manager is not running -- this probe needs the OVS stack")

    # Assert the fabric is the one named, from the endpoint itself. A mislabelled cell is
    # the failure mode that makes both numbers look reasonable and the comparison wrong.
    settle_trace, converged = settle(expect_hosts)
    if not converged:
        seen = [s.get("hosts") for s in settle_trace[-5:]]
        sys.exit(f"refusing: asked for the {expect_hosts}-host cell but Ryu never held that "
                 f"count for 3 consecutive reads (last 5 host counts: {seen}). "
                 f"Bring up the right fabric, or the label lies.")

    try:
        _, _, hosts = fetch(f"{BASE}/hosts")
        _, _, switches = fetch(f"{BASE}/switches")
        _, _, links = fetch(f"{BASE}/links")
    except (urllib.error.URLError, OSError) as e:
        sys.exit(f"refusing: cannot reach {BASE} ({e})")

    result = {
        "recorded_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "expect_hosts": expect_hosts,
        "observed": {"hosts": len(hosts), "switches": len(switches), "links": len(links)},
        "fabric": fabric,
        "settle_reads": len(settle_trace),
        "settle_trace": settle_trace,
        "warmup": WARMUP,
        "reps": REPS,
        "endpoints": {},
    }

    for ep, url in endpoint_urls().items():
        for _ in range(WARMUP):
            fetch(url)
        times, sizes = [], []
        for _ in range(REPS):
            dt, nbytes, _ = fetch(url)
            times.append(dt * 1000.0)
            sizes.append(nbytes)
        times.sort()
        result["endpoints"][ep] = {
            "ms_median": round(statistics.median(times), 3),
            "ms_min": round(times[0], 3),
            "ms_max": round(times[-1], 3),
            "ms_p90": round(times[int(0.9 * (len(times) - 1))], 3),
            "ms_stdev": round(statistics.stdev(times), 3) if len(times) > 1 else 0.0,
            "ms_all": [round(t, 3) for t in times],
            "payload_bytes": sizes[0],
            "payload_bytes_stable": len(set(sizes)) == 1,
        }
    return result


def compare(path_a, path_b):
    a = json.load(open(path_a))
    b = json.load(open(path_b))
    lo, hi = sorted((a, b), key=lambda r: r["expect_hosts"])
    print(f"{'endpoint':<10} {'hosts':>6} {'median ms':>10} {'bytes':>9}   "
          f"{'hosts':>6} {'median ms':>10} {'bytes':>9}   {'t ratio':>8} {'B ratio':>8}")
    for ep in ENDPOINTS:
        la, lb = lo["endpoints"][ep], hi["endpoints"][ep]
        tr = lb["ms_median"] / la["ms_median"] if la["ms_median"] else float("nan")
        br = lb["payload_bytes"] / la["payload_bytes"] if la["payload_bytes"] else float("nan")
        print(f"{ep:<10} {lo['expect_hosts']:>6} {la['ms_median']:>10.3f} "
              f"{la['payload_bytes']:>9}   {hi['expect_hosts']:>6} {lb['ms_median']:>10.3f} "
              f"{lb['payload_bytes']:>9}   {tr:>8.2f} {br:>8.2f}")
    print()
    print("Read the last two columns together. If t ratio tracks B ratio the cost is "
          "serialisation\nand scales with payload; if t ratio runs well ahead of B ratio "
          "the controller is doing\nwork that is superlinear in the topology, which is the "
          "hypothesis ② actually needs.")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--compare":
        compare(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 2 and sys.argv[1].isdigit():
        json.dump(measure(int(sys.argv[1])), sys.stdout, indent=2)
        print()
    else:
        sys.exit(__doc__)
