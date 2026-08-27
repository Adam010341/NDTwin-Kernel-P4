#!/usr/bin/env python3
"""Fraction of live flows whose `path` field is non-empty. Ticket M metric 6-2.

WHY THIS IS THE METRIC. Dropping calFlowPathByQueried from 1 kHz to 1 Hz will make CPU fall
handsomely, and CPU is not the judgment. The only thing 1 kHz buys is the freshness ceiling of
the API's `path` field -- flowPath has exactly one consumer, verified by grep across src, tests,
tools and p4_proxy -- so what the change actually costs is flows that are alive and have no path
yet. That is what this counts.

WHY EMPTY-FLEET IS NOT ZERO PERCENT. If the fabric has no flows at all, the fraction is undefined,
and reporting it as 0% would be indistinguishable from "every flow lost its path" -- which is
exactly the regression this instrument exists to detect. An instrument whose failure mode imitates
its own finding is worse than none, so n_flows is recorded on every sample and the ratio is None
rather than 0.0 when there is nothing to divide by. Same rule as /sflow/stats returning 503 rather
than zeros.

WHY RAW COUNTS. n_with_path and n_flows are stored, not the percentage. The analysis can then
weight by sample, by flow-second, or restrict to a window, without re-running the fabric.

Usage: sample_path_fill.py <out.jsonl> <interval_s> [api_base]
[Co-developed with claude code -- Adam]
"""
import json
import subprocess
import sys
import time

# 127.0.0.1, never localhost: this project lost 131 seconds to an IPv6 black hole on that name.
DEFAULT_API = "http://127.0.0.1:8000"


def poll(url):
    r = subprocess.run(["curl", "-sS", "--max-time", "3", url],
                       capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout:
        return None
    try:
        return json.loads(r.stdout)
    except Exception:
        return None


def main():
    out_path, interval = sys.argv[1], float(sys.argv[2])
    base = sys.argv[3] if len(sys.argv) > 3 else DEFAULT_API
    url = f"{base}/ndt/get_detected_flow_data"
    f = open(out_path, "a", buffering=1)      # append: a restart must not truncate history
    while True:
        t0 = time.time()
        rec = {"t": t0}
        flows = poll(url)
        if flows is None:
            # A failed poll is recorded as a failed poll. Treating it as "no flows" would feed
            # the empty-fleet case above, and treating it as "all paths present" would hide the
            # regression -- so it is neither, and the analysis can count how often it happened.
            rec["poll_ok"] = False
        elif not isinstance(flows, list):
            rec["poll_ok"] = False
            rec["unexpected_shape"] = str(type(flows).__name__)
        else:
            rec["poll_ok"] = True
            rec["n_flows"] = len(flows)
            rec["n_with_path"] = sum(1 for fl in flows if fl.get("path"))
            # Path lengths, because "non-empty" and "correct" are different questions and a
            # truncated path would pass the first. Cheap to store, impossible to recover later.
            rec["path_lens"] = sorted(len(fl.get("path") or []) for fl in flows)[:64]
            rec["ratio"] = (rec["n_with_path"] / rec["n_flows"]) if rec["n_flows"] else None
        f.write(json.dumps(rec) + "\n")
        # Sleep the remainder, not a flat interval: a flat sleep drifts under exactly the load
        # this measures, which is how the proxy sampler behaved before it was fixed.
        time.sleep(max(0.0, interval - (time.time() - t0)))


if __name__ == "__main__":
    main()
