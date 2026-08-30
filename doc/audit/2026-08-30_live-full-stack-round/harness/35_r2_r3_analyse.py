#!/usr/bin/env python3
"""
35_r2_r3_analyse.py -- turn 30_r2_r3_sample.py's JSONL into the R-2 answer.

WRITTEN, NOT RUN.  Syntax-checked with `python3 -m py_compile` only.

Reads only the saved samples.  It never fetches, so it can be re-run against a finished round,
and a mistake in the analysis costs nothing but a re-run.

WHAT IT REPORTS, AND WHAT EACH LINE IS ALLOWED TO SUPPORT

  1. Sampler health, FIRST, before any result.
        - overruns: samples where the loop could not keep its interval.  A sampler that slipped
          reports a slower-changing world than the real one, so an overrun rate above a few
          percent invalidates the change-interval numbers rather than merely widening them.
        - transport errors vs HTTP statuses, counted separately (H-19).
        - the paths channel's status.  F-8 (08-18) is the case where this channel returned
          `unknown` for a whole round because of a default port, and the tool reported a clean
          3-channel pass on 2 channels, silently.  If the paths channel never answered, this
          script SAYS SO AT THE TOP and marks every paths-derived line untestable.

  2. Change intervals of the flowPath a consumer reads.
        For each flow key, the times at which its path digest changed.  Reported as a
        distribution, not a mean: a ~60 s mode is the refresh thread
        (memory: destination-paths-not-monotonic, ceiling ~60 s) and must not be read as the
        recompute rate.

  3. The decimation table -- what a consumer polling at cadence C would have observed.
        Computed for the REGISTERED cadence (15 s) and for every MEASURED one
        (1 s viz/te, 5 s nsr, 60 s energy).  Both are printed.  This script does not decide
        which is the right one; PREREG §3 registered 15 s and the measurement says otherwise,
        and reconciling those is the auditor's call, not the harness's.

  🔑 WHAT THIS SCRIPT MAY NOT CONCLUDE
        R-2 changed an internal recompute rate.  Nothing here observes that rate.  The strongest
        honest statement available is about what a consumer could see.  "No consumer-visible
        difference" is a claim about consumers; it is not a claim that the recompute happens at
        1 Hz.  memory: claim-verb-decides-the-evidence.

H-CORRESPONDENCE
    H-17/H-22  no processes involved.
    H-18/H-23  no regexes; every field is looked up by key, and a missing key is reported as
               "absent" rather than folded into zero.
    H-19       transport errors and HTTP statuses are counted in separate buckets throughout.
    H-20       reads only the file named on the command line; prints its mtime and sample count
               in the header so the reader can see which run is being analysed.
    H-21       n/a.
    H-24       reads a closed file.

[Co-developed with claude code -- Adam]
"""

import argparse
import collections
import gzip
import hashlib
import json
import os
import sys
import time

# Cadences to decimate at.  15 is what PREREG §3 registered; the rest are what the apps
# actually use, read from their sources on 2026-08-30.
CADENCES = [
    (1.0,  "viz / te      (NetworkTopologyApp.java:424 ; Traffic-engineering-App.py:41)"),
    (5.0,  "nsr           (recorder_setting.yaml:5)"),
    (15.0, "PREREG §3 R-2 registered cadence -- NOT used by any app"),
    (60.0, "energy        (Energy-Saving-App/include/app/settings.hpp:8)"),
]


def digest(obj):
    return hashlib.sha256(
        json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:16]


def find_paths(container):
    """Extract {flow_key: path_digest} tolerantly.

    The exact schema of /ndt/get_detected_flow_data is not pinned here on purpose: this
    harness was written without a live kernel to read a real body from, and inventing a schema
    from source would be the same mistake as grepping for the manual's word instead of the
    software's (H-18/M-3).  So: walk the structure, take anything whose key looks like a path,
    and RECORD WHICH KEY WAS USED so the reader can check the choice.

    After the first live run, replace this with the real key.  Until then every result carries
    the key name it was derived from.
    """
    found = {}
    used = set()

    def walk(node, trail):
        if isinstance(node, dict):
            for k, v in node.items():
                if isinstance(k, str) and k.lower() in (
                        "flowpath", "flow_path", "path", "paths"):
                    found[".".join(trail) or "<root>"] = digest(v)
                    used.add(k)
                else:
                    walk(v, trail + [str(k)])
        elif isinstance(node, list):
            for i, v in enumerate(node):
                walk(v, trail + [str(i)])

    walk(container, [])
    return found, sorted(used)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", required=True)
    ap.add_argument("--overrun-tolerance", type=float, default=0.05,
                    help="fraction of samples allowed to overrun before the timing results are "
                         "declared unusable rather than merely noisy")
    args = ap.parse_args()

    op = gzip.open if args.samples.endswith(".gz") else open
    recs = []
    with op(args.samples, "rt") as f:
        for line in f:
            line = line.strip()
            if line:
                recs.append(json.loads(line))

    print("=" * 92)
    print("R-2 analysis of %s" % args.samples)
    print("  file mtime : %s" % time.strftime(
        "%Y-%m-%dT%H:%M:%SZ", time.gmtime(os.path.getmtime(args.samples))))
    print("  records    : %d" % len(recs))
    print("=" * 92)

    # ---------------------------------------------------------------- 1. sampler health, first
    overruns = [r for r in recs if "__overrun__" in r]
    samples = [r for r in recs if "__overrun__" not in r]
    if not samples:
        print("\nNO USABLE SAMPLES.  Nothing below can be computed.")
        return 3
    frac = len(overruns) / float(len(recs))
    print("\n--- 1. SAMPLER HEALTH (read this before any result) ---")
    print("  samples          : %d" % len(samples))
    print("  overruns         : %d  (%.1f%%)" % (len(overruns), frac * 100))
    span = samples[-1]["t"] - samples[0]["t"]
    print("  wall span        : %.1f s" % span)
    print("  effective rate   : %.3f Hz" % (len(samples) / span if span else 0))
    timing_usable = frac <= args.overrun_tolerance
    if not timing_usable:
        print("  🔴 OVERRUN RATE ABOVE TOLERANCE (%.0f%%).  The sampler could not keep its own"
              % (args.overrun_tolerance * 100))
        print("     schedule, so every interval below is biased LONG.  Treat section 2 as")
        print("     unusable, not merely noisy, and re-run on a quieter machine.")

    for chan in ("flows", "graph", "paths"):
        http = collections.Counter()
        errs = collections.Counter()
        for r in samples:
            p = r.get(chan) or {}
            if p.get("err"):
                errs[p["err"].split(":")[0]] += 1
            else:
                http[p.get("http")] += 1
        print("  %-7s http=%s  transport-errors=%s"
              % (chan, dict(http) or "{}", dict(errs) or "{}"))

    paths_ok = any((r.get("paths") or {}).get("http") == 200 for r in samples)
    if not paths_ok:
        print("\n  🔴 THE PATHS CHANNEL NEVER ANSWERED 200.")
        print("     This is F-8's exact shape: a channel silently absent while the summary")
        print("     still prints.  Every paths-derived line below is UNTESTABLE, not passing.")
        print("     Check the URL for this fabric -- P4 serves it on the proxy :8081, OVS on")
        print("     Ryu :8080, and defaulting to the wrong one is how F-8 happened.")

    # ---------------------------------------------------------------- 2. change intervals
    print("\n--- 2. HOW OFTEN THE PATH A CONSUMER READS ACTUALLY CHANGES ---")
    keys_used = set()
    last = {}
    changes = collections.defaultdict(list)     # flow key -> [timestamps of change]
    first_seen = {}
    for r in samples:
        body = (r.get("flows") or {}).get("body")
        if not body:
            continue
        got, used = find_paths(body)
        keys_used.update(used)
        for k, d in got.items():
            if k not in last:
                last[k] = d
                first_seen[k] = r["t"]
                continue
            if d != last[k]:
                changes[k].append(r["t"])
                last[k] = d

    print("  JSON key(s) treated as the path field: %s" % (sorted(keys_used) or "NONE FOUND"))
    if not keys_used:
        print("  🔴 No path-like key was found in any sample.  Either the endpoint returned no")
        print("     flows (a quiet network -- check the graph channel and the traffic source),")
        print("     or the schema differs from every name tried.  Open one raw body from the")
        print("     sample file, find the real key, and put it in find_paths().  Do NOT report")
        print("     'paths never changed' from this: an absent key is not a stable value.")
    else:
        print("  flow keys observed : %d" % len(last))
        print("  flow keys that ever changed : %d" % len(changes))
        allint = []
        for k, ts in changes.items():
            prev = first_seen[k]
            for t in ts:
                allint.append(t - prev)
                prev = t
        if allint:
            allint.sort()
            def pct(p):
                return allint[min(len(allint) - 1, int(len(allint) * p))]
            print("  inter-change intervals (s): n=%d  min=%.2f  p50=%.2f  p95=%.2f  max=%.2f"
                  % (len(allint), allint[0], pct(0.5), pct(0.95), allint[-1]))
            # The ~60 s mode is the refresh thread, not the recompute.
            near60 = sum(1 for x in allint if 50 <= x <= 70)
            print("  intervals in [50,70] s: %d (%.0f%%)  <- if this dominates, you are seeing"
                  % (near60, 100.0 * near60 / len(allint)))
            print("     the refresh thread's ~60 s ceiling (memory: destination-paths-not-")
            print("     monotonic), NOT the recompute rate.  Its downgrade condition is")
            print("     'non-empty', not 'converged', so 99.8%% of the time it looks converged.")
            sub1 = sum(1 for x in allint if x < 1.0)
            print("  intervals < 1 s: %d  <- anything here is faster than R-2's 1 Hz and needs"
                  % sub1)
            print("     explaining before R-2 is called 'no observable difference'.")
        else:
            print("  no path ever changed during the window.  That is consistent with R-2's")
            print("  registered expectation AND with a network too quiet to recompute anything.")
            print("  Those are different worlds; the graph/traffic evidence decides which.")

    # ---------------------------------------------------------------- 3. decimation table
    print("\n--- 3. WHAT A CONSUMER AT CADENCE C WOULD HAVE SEEN ---")
    print("  %-7s %-9s %-9s  %s" % ("cadence", "polls", "changes", "which app"))
    for c, who in CADENCES:
        polls = int(span // c) if span else 0
        seen = 0
        for k, ts in changes.items():
            buckets = set(int((t - samples[0]["t"]) // c) for t in ts)
            seen += len(buckets)
        print("  %-7.0fs %-9d %-9d  %s" % (c, polls, seen, who))
    print("  NOTE: 15 s is the cadence PREREG §3 R-2 assumed.  No app uses it.  Both rows are")
    print("  printed so the write-up can state the registered expectation and the measured")
    print("  premise separately, rather than quietly substituting one for the other.")

    print("\n--- VERDICT SCAFFOLD (fill in by hand; this script does not decide) ---")
    print("  R-2 is: [ no consumer-visible difference / a difference, described / untestable ]")
    print("  Supported by: change intervals in §2 at the cadences in §3, with §1 confirming the")
    print("  sampler resolved them.  NOT supported: any statement about the recompute rate.")
    return 0 if timing_usable else 1


if __name__ == "__main__":
    sys.exit(main())
