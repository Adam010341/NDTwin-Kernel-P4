#!/usr/bin/env python3
"""Poll the proxy's send-side counters. Ticket P instrument 1's reader.

The endpoint (GET /sflow/stats, commit 59e7298) exposes datagrams_sent, samples_sent and
send_errors, which had been incremented since the emitter was written and read by nobody. This
is the sampler that turns them into a per-arm number.

WHY IT RECORDS THE HTTP STATUS. The endpoint answers 503 when the emitter was never injected,
precisely so that a wiring failure cannot be mistaken for "the send side stopped sending". That
distinction is only preserved if the sampler carries it through instead of writing a row with
missing counters, so status is stored on every sample and 503 is not silently retried away.

WHY RAW COUNTERS. samples_sent is cumulative. The analysis differentiates two reads across an
arm's window; averaging a cumulative counter has already produced one published number on this
project that looked entirely reasonable.

Usage: sample_sflow_stats.py <out.jsonl> <interval_s> [proxy_base]
[Co-developed with claude code -- Adam]
"""
import json
import subprocess
import sys
import time

DEFAULT_BASE = "http://127.0.0.1:8081"      # 127.0.0.1, never localhost


def main():
    out_path, interval = sys.argv[1], float(sys.argv[2])
    base = sys.argv[3] if len(sys.argv) > 3 else DEFAULT_BASE
    url = f"{base}/sflow/stats"
    f = open(out_path, "a", buffering=1)
    while True:
        t0 = time.time()
        rec = {"t": t0}
        # -w '%{http_code}' so a 503 is data rather than an empty body. --max-time because a
        # blocked proxy must not stall the sampler into a gap that reads as "nothing happened".
        r = subprocess.run(["curl", "-sS", "--max-time", "3", "-w", "\n%{http_code}", url],
                           capture_output=True, text=True)
        body, _, code = r.stdout.rpartition("\n")
        rec["http"] = code.strip() or "000"
        if rec["http"] == "200":
            try:
                rec.update(json.loads(body))
            except Exception:
                rec["parse_error"] = body[:120]
        else:
            # Kept verbatim: 503 means not wired, and that must never be smoothed into zeros.
            rec["body"] = body[:200]
        f.write(json.dumps(rec) + "\n")
        time.sleep(max(0.0, interval - (time.time() - t0)))


if __name__ == "__main__":
    main()
