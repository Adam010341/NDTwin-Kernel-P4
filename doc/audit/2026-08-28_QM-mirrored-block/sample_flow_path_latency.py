#!/usr/bin/env python3
"""Per-flow latency from "the twin can see this flow" to "the twin has a path for it".

Ticket M's metric, per amendment M-quater. Metric 6-2 (fraction of listed flows holding a path)
was retired because FLOW_IDLE_TIMEOUT inflates its denominator 13.3x, so a 20-point effect would
have shown up as 1.5 points. This measures the latency directly instead, per flow, so the idle
tail cannot dilute it: a finished flow sitting in the table contributes nothing here, because it
already has both of its timestamps.

TWO SEGMENTS, RECORDED SEPARATELY (M-quater (ii)):

    packets start -> (sFlow detects) -> IN TABLE -> (next path pass) -> HAS PATH
                     |___ detection ___|          |___ what M changes ___|

`t_first_seen` ends the first segment, `t_first_path` ends the second, and M's effect is the
DIFFERENCE. Reporting only the total would be one more ratio whose two sides come from different
populations. Detection latency is worth having on its own: it is how long the twin takes to
notice a new flow at all, and this project has never measured it.

WHY EVERY OBSERVATION CARRIES ITS OWN RESOLUTION. The effect is ~0.5 s and the northbound API
serves one request at a time, so a poller asking for 10 Hz may not get it -- and if it stalls for
800 ms just before a flow appears, that flow's latency is known only to +/-800 ms. A single
global "we polled at 10 Hz" would hide that. `gap_before_first_seen_s` and `gap_before_first_path_s`
record the actual interval since the previous SUCCESSFUL poll, per flow, so the analysis can
bound or drop individual observations instead of trusting an average cadence.

WHAT IS NOT A ZERO (M-quater (iii), and the third time this rule has been applied today):
  * no path ever            -> t_first_path = None, never_path = True. Not 0, not 999.
  * flow present on poll 1  -> left_censored = True. Its birth may predate the sampler.
  * sampler stopped soon    -> watch_s records how long it was actually watched, so "never got a
    after a flow appeared      path" can be told apart from "was not watched long enough". These
                               are different findings and must not share a bucket.
  * failed poll             -> poll_ok False, and it does NOT advance any flow's clock. Treating
                               a failed poll as "no flows" would manufacture appearances.

Usage: sample_flow_path_latency.py <out_dir> <hz> <duration_s> [api_base]
Writes poll.jsonl (one line per poll, streamed) and flows.json (the per-flow table, at exit).
[Co-developed with claude code -- Adam]
"""
import json
import os
import signal
import subprocess
import sys
import time

# 127.0.0.1, never localhost: this project lost 131 seconds to an IPv6 black hole on that name.
DEFAULT_API = "http://127.0.0.1:8000"

_stop = False


def _on_term(signum, frame):
    global _stop
    _stop = True


def poll(url):
    """Returns (parsed_or_None, elapsed_s). Elapsed is measured around the request either way,
    because a poll that FAILS slowly is the interesting case -- it is the one that opens a hole
    in the timeline -- and a failure that discarded its duration would look like a fast one."""
    t0 = time.time()
    try:
        r = subprocess.run(["curl", "-sS", "--max-time", "3", url],
                           capture_output=True, text=True)
    except Exception:
        return None, time.time() - t0
    el = time.time() - t0
    if r.returncode != 0 or not r.stdout:
        return None, el
    try:
        d = json.loads(r.stdout)
    except Exception:
        return None, el
    return (d if isinstance(d, list) else None), el


def key_of(fl):
    return (f"{fl.get('src_ip')}:{fl.get('src_port')}>"
            f"{fl.get('dst_ip')}:{fl.get('dst_port')}/{fl.get('protocol_id')}")


def main():
    out_dir, hz, dur = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
    base = sys.argv[4] if len(sys.argv) > 4 else DEFAULT_API
    url = f"{base}/ndt/get_detected_flow_data"
    os.makedirs(out_dir, exist_ok=True)
    signal.signal(signal.SIGTERM, _on_term)
    signal.signal(signal.SIGINT, _on_term)

    period = 1.0 / hz
    t_start = time.time()
    t_stop = t_start + dur
    pf = open(os.path.join(out_dir, "poll.jsonl"), "w", buffering=1)

    flows = {}          # key -> record
    prev_ok_t = None    # timestamp of the previous SUCCESSFUL poll
    n_poll = n_fail = 0
    first_ok_poll_t = None

    while not _stop and time.time() < t_stop:
        t0 = time.time()
        data, el = poll(url)
        n_poll += 1
        rec = {"t": round(t0, 4), "ms": round(el * 1000, 1)}
        if data is None:
            n_fail += 1
            rec["poll_ok"] = False
            pf.write(json.dumps(rec) + "\n")
            # prev_ok_t deliberately NOT advanced: the gap a later flow reports must span the
            # failure, because that is genuinely how long the timeline was blind.
            time.sleep(max(0.0, period - (time.time() - t0)))
            continue

        rec["poll_ok"] = True
        rec["n_flows"] = len(data)
        rec["n_with_path"] = sum(1 for fl in data if fl.get("path"))
        pf.write(json.dumps(rec) + "\n")

        gap = None if prev_ok_t is None else t0 - prev_ok_t
        if first_ok_poll_t is None:
            first_ok_poll_t = t0

        for fl in data:
            k = key_of(fl)
            r = flows.get(k)
            if r is None:
                r = flows[k] = {
                    "key": k,
                    "t_first_seen": round(t0, 4),
                    "gap_before_first_seen_s": (None if gap is None else round(gap, 4)),
                    # A flow already present on the first successful poll may have been born
                    # before the sampler started. Its detection latency is a lower bound only.
                    "left_censored": (t0 == first_ok_poll_t),
                    "t_first_path": None,
                    "gap_before_first_path_s": None,
                    "never_path": True,
                    "path_len_at_first_path": None,
                    "n_polls_seen": 0,
                    # The kernel's own opinion of when it first sampled this flow, at 1 s
                    # resolution. Too coarse for the effect, but an INDEPENDENT check that
                    # poll-based first-sighting is not systematically late.
                    "kernel_first_sampled_time": fl.get("first_sampled_time"),
                }
            r["n_polls_seen"] += 1
            if r["never_path"] and fl.get("path"):
                r["t_first_path"] = round(t0, 4)
                r["gap_before_first_path_s"] = (None if gap is None else round(gap, 4))
                r["never_path"] = False
                r["path_len_at_first_path"] = len(fl["path"])

        prev_ok_t = t0
        time.sleep(max(0.0, period - (time.time() - t0)))

    t_end = time.time()
    pf.close()

    # Achieved cadence, from the record rather than from the request. "We asked for 10 Hz" is not
    # a measurement of anything; the spread of what we got is the instrument's real resolution.
    ts = []
    with open(os.path.join(out_dir, "poll.jsonl")) as fh:
        for line in fh:
            d = json.loads(line)
            if d.get("poll_ok"):
                ts.append(d["t"])
    gaps = sorted(b - a for a, b in zip(ts, ts[1:]))

    def q(p):
        return round(gaps[min(len(gaps) - 1, int(p * len(gaps)))], 4) if gaps else None

    for r in flows.values():
        r["latency_detect_to_path_s"] = (
            None if r["never_path"] else round(r["t_first_path"] - r["t_first_seen"], 4))
        # How long this flow was actually watched after it appeared. A `never_path` flow that was
        # only watched for 0.2 s is not evidence about paths; it is evidence the run ended.
        r["watch_s"] = round(t_end - r["t_first_seen"], 4)

    summary = {
        "t_start": round(t_start, 4), "t_end": round(t_end, 4),
        "requested_hz": hz, "n_polls": n_poll, "n_polls_failed": n_fail,
        "achieved_gap_median_s": q(0.5), "achieved_gap_p95_s": q(0.95),
        "achieved_gap_max_s": (round(gaps[-1], 4) if gaps else None),
        "n_flows_seen": len(flows),
        "n_left_censored": sum(1 for r in flows.values() if r["left_censored"]),
        "n_never_path": sum(1 for r in flows.values() if r["never_path"]),
    }
    json.dump({"summary": summary, "flows": sorted(flows.values(), key=lambda r: r["t_first_seen"])},
              open(os.path.join(out_dir, "flows.json"), "w"), indent=1)
    print(f"  path-latency: {summary['n_flows_seen']} flows, "
          f"{summary['n_never_path']} never got a path, "
          f"{summary['n_left_censored']} left-censored; "
          f"polls {n_poll} ({n_fail} failed), "
          f"gap median {summary['achieved_gap_median_s']}s p95 {summary['achieved_gap_p95_s']}s "
          f"max {summary['achieved_gap_max_s']}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
