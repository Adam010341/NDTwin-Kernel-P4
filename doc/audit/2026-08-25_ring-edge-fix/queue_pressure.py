#!/usr/bin/env python3
"""Peak event-queue pressure across a boot's sampled dumps.

[Co-developed with claude code -- Adam]
The ring is gone after B, so "did guard 0.01 raise the failure rate" can no longer be answered by
counting wedges -- there are none to count in either arm. This measures the thing the guard was
ever suspected of moving: how full IntelligentRyu's 128-slot queue gets. LLDP packet-ins land in
that queue, the guard sets how fast they arrive, and filling the queue was half the ring.

Reports the MAXIMUM depth seen across every sample of a boot, per app, plus the worst semaphore
balance (negative = emitters blocked). A boot that never exceeds a few slots had no pressure,
whatever its wedge outcome.
"""
import re, sys, os, collections

def peaks(path):
    hi = collections.defaultdict(lambda: [0, 128, 0])   # app -> [max qsize, maxsize, worst -bal]
    for ln in open(path, errors="replace"):
        m = re.match(r'\s+(\S+)\s+(\d+)/(\d+)\s+balance=(-?\d+)', ln)
        if not m:
            continue
        app, q, mx, bal = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))
        hi[app][0] = max(hi[app][0], q)
        hi[app][1] = mx
        hi[app][2] = max(hi[app][2], -bal if bal < 0 else 0)
    return hi

for p in sys.argv[1:]:
    h = peaks(p)
    if not h:
        print(f"{os.path.basename(p)}: 🔴 no queue census rows -- INCONCLUSIVE, not 'no pressure'")
        continue
    worst = max(h.items(), key=lambda kv: (kv[1][0], kv[1][2]))
    parts = [f"{a}={v[0]}/{v[1]}" + (f"(blocked {v[2]})" if v[2] else "") for a, v in sorted(h.items()) if v[0] or v[2]]
    print(f"{os.path.basename(p)}: peak {worst[0]}={worst[1][0]}/{worst[1][1]}"
          f"  |  nonzero: {', '.join(parts) if parts else 'none -- every queue empty in every sample'}")
