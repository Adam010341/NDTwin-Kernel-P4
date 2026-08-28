#!/usr/bin/env python3
"""Do already-finished flows OUTRANK live ones in get_detected_top_k_flow_data?

WHY RANK AND NOT PROPORTION. The first version of this question was "do both arms return ~50
records of which ~45 read zero". That measures the PROPORTION of corpses in the list. The
severity claim is about ORDER: the endpoint is sorted by
estimated_packet_rate_in_the_proceeding_1sec_timeslot (FLUC:2339-2341), and Energy-Saving-App
consumes the top of that list. "45 of 50 are dead" and "9 of the top 10 are dead" are different
defects, and only the second one reaches the consumer. So every record is stored WITH ITS RANK.

WHAT COUNTS AS DEAD, AND WHY NOT THE SORT KEY. Liveness is decided by latest_sampled_time --
the kernel's own record of when it last sampled this flow, frozen at FlowLinkUsageCollector.cpp
:2314 from info.endTime. It is deliberately NOT decided from the rate fields, because the rate
fields are the thing under test: using them to define "dead" would guarantee that dead flows have
low rates and the measurement would return its own premise. Same rule as an instrument not
mimicking its own finding.

THE COMPARISON IS BETWEEN TWO BINARIES, NOT TWO BRANCHES. 開機手冊 established (verified
independently, FINDINGS F-8) that origin/main has always cleared periodic rates to zero, that
31b357a introduced the retention on this branch, and that aabe605 fixed it -- so both branches
zero dead flows today and the "phantom rate" difference this was originally written to catch does
not exist. What is left is the POPULATION problem, which both branches have: the walk in
getFlowInfoJson applies no liveness filter at all, and getTopKFlowInfoJson takes min(k, size) of
it. That is what this measures.

Usage: sample_topk_rank.py <out_dir> <interval_s> <duration_s> [k] [api_base]
[Co-developed with claude code -- Adam]
"""
import datetime
import json
import os
import subprocess
import sys
import time

DEFAULT_API = "http://127.0.0.1:8000"       # never localhost: 131 s IPv6 black hole
DEAD_AFTER_S = 2.0                           # no sample for this long => not currently sending


def get(url):
    try:
        r = subprocess.run(["curl", "-sS", "--max-time", "5", url],
                           capture_output=True, text=True)
    except Exception:
        return None
    if r.returncode != 0 or not r.stdout:
        return None
    try:
        return json.loads(r.stdout)
    except Exception:
        return None


def parse_ts(s):
    """latest_sampled_time is 'YYYY-MM-DD HH:MM:SS' local. Returns unix seconds or None.

    None is returned, not 0 and not now(): a timestamp we cannot parse is a flow whose liveness
    is UNKNOWN, and folding it into either bucket would put a guess where a measurement belongs.
    """
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%d %H:%M:%S").timestamp()
    except Exception:
        return None


def key_of(f):
    return (f"{f.get('src_ip')}:{f.get('src_port')}>"
            f"{f.get('dst_ip')}:{f.get('dst_port')}/{f.get('protocol_id')}")


def main():
    out_dir, iv, dur = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
    k = int(sys.argv[4]) if len(sys.argv) > 4 else 50
    base = sys.argv[5] if len(sys.argv) > 5 else DEFAULT_API
    os.makedirs(out_dir, exist_ok=True)
    url = f"{base}/ndt/get_detected_top_k_flow_data?k={k}"
    f = open(os.path.join(out_dir, "topk.jsonl"), "w", buffering=1)

    t_end = time.time() + dur
    n_poll = n_fail = 0
    while time.time() < t_end:
        t0 = time.time()
        data = get(url)
        n_poll += 1
        if not isinstance(data, list):
            n_fail += 1
            f.write(json.dumps({"t": round(t0, 3), "poll_ok": False}) + "\n")
            time.sleep(max(0.0, iv - (time.time() - t0)))
            continue
        rows = []
        for rank, fl in enumerate(data):
            ts = parse_ts(fl.get("latest_sampled_time", ""))
            age = None if ts is None else t0 - ts
            rows.append({
                "rank": rank,                       # 0 = top of the list the consumer reads first
                "key": key_of(fl),
                "age_s": None if age is None else round(age, 1),
                "dead": None if age is None else (age > DEAD_AFTER_S),
                # the sort key itself, and its sibling, so the ordering can be reconstructed
                "sortkey_pps_proceeding":
                    fl.get("estimated_packet_rate_in_the_proceeding_1sec_timeslot"),
                "bps_proceeding":
                    fl.get("estimated_flow_sending_rate_bps_in_the_proceeding_1sec_timeslot"),
                "bps_last_sec":
                    fl.get("estimated_flow_sending_rate_bps_in_the_last_sec"),
                "has_path": bool(fl.get("path")),
            })
        f.write(json.dumps({"t": round(t0, 3), "poll_ok": True, "n": len(rows),
                            "rows": rows}) + "\n")
        time.sleep(max(0.0, iv - (time.time() - t0)))
    f.close()
    print(f"  topk: {n_poll} polls ({n_fail} failed) -> {out_dir}/topk.jsonl")
    return 0


if __name__ == "__main__":
    main()
