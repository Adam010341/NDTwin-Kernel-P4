#!/usr/bin/env python3
"""T-11 live probe: POST an install, then watch the table view for the row.

Records not just PRESENCE but SHAPE, because the two are different claims:

  request-shape : match uses the caller's vocabulary (ipv4_dst) and carries no
                  packet_count/byte_count. This is the optimistic cache row --
                  FINDING-03's phantom signature.
  polled-shape  : match uses the switch's vocabulary (nw_dst) and carries
                  counters. This row came back from the southbound poll.

A row visible in request-shape means the cache row was served. Under T-11 that
may only happen once the token is confirmed.

[Co-developed with claude code -- Adam]
"""
import json
import sys
import time
import urllib.request

KERNEL = "http://localhost:8000"


def post_install(dpid, ipv4_dst, port, priority):
    body = json.dumps({
        "dpid": dpid,
        "priority": priority,
        "match": {"eth_type": 2048, "ipv4_dst": ipv4_dst},
        "actions": [{"type": "OUTPUT", "port": port}],
    }).encode()
    req = urllib.request.Request(
        KERNEL + "/ndt/install_flow_entry", data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    t = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return t, r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return t, e.code, e.read().decode()


def get_table():
    with urllib.request.urlopen(KERNEL + "/ndt/get_switch_openflow_table_entries",
                                timeout=15) as r:
        return json.loads(r.read().decode())


def classify(tables, dpid, ipv4_dst):
    """Return list of (shape, entry) for rows on `dpid` matching ipv4_dst."""
    hits = []
    for sw in tables:
        if sw.get("dpid") != dpid:
            continue
        for _tid, entries in (sw.get("flows") or {}).items():
            if not isinstance(entries, list):
                continue
            for e in entries:
                m = e.get("match", {})
                val = m.get("ipv4_dst") or m.get("nw_dst")
                if val != ipv4_dst:
                    continue
                has_counters = ("packet_count" in e) or ("byte_count" in e)
                caller_vocab = "ipv4_dst" in m
                if caller_vocab and not has_counters:
                    shape = "REQUEST-SHAPE(phantom-signature)"
                elif not caller_vocab and has_counters:
                    shape = "POLLED-SHAPE(real)"
                else:
                    shape = ("MIXED(caller_vocab=%s,counters=%s)"
                             % (caller_vocab, has_counters))
                hits.append((shape, e))
    return hits


def total_entries(tables):
    return sum(len(v) for sw in tables
               for v in (sw.get("flows") or {}).values() if isinstance(v, list))


def main():
    label = sys.argv[1]
    dpid = int(sys.argv[2])
    ipv4_dst = sys.argv[3]
    port = int(sys.argv[4])
    priority = int(sys.argv[5])
    duration = float(sys.argv[6]) if len(sys.argv) > 6 else 25.0

    print("=== %s : dpid=%d ipv4_dst=%s port=%d priority=%d ==="
          % (label, dpid, ipv4_dst, port, priority))
    pre = get_table()
    print("pre-POST: target rows=%d, table total=%d"
          % (len(classify(pre, dpid, ipv4_dst)), total_entries(pre)))

    t0, status, body = post_install(dpid, ipv4_dst, port, priority)
    print("POST at t=0.000 -> HTTP %d  %s" % (status, body.strip()[:300]))

    first_seen = None
    last = None
    while True:
        el = time.monotonic() - t0
        if el > duration:
            break
        try:
            tb = get_table()
        except Exception as ex:
            print("  t=%6.3f  GET failed: %s" % (el, ex))
            time.sleep(0.5)
            continue
        el = time.monotonic() - t0
        hits = classify(tb, dpid, ipv4_dst)
        desc = "ABSENT" if not hits else "; ".join(h[0] for h in hits)
        if desc != last:
            print("  t=%6.3f  %s   (table total=%d)" % (el, desc, total_entries(tb)))
            if hits and first_seen is None:
                first_seen = el
                print("       first sighting entry: %s"
                      % json.dumps(hits[0][1], sort_keys=True)[:400])
            last = desc
        time.sleep(0.25)

    print("RESULT: first_sighting=%s"
          % ("never (absent for the whole %.1fs)" % duration
             if first_seen is None else "t=%.3f s" % first_seen))


main()
