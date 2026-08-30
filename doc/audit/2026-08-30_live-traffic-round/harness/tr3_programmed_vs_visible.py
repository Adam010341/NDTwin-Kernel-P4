#!/usr/bin/env python3
"""
tr3_programmed_vs_visible.py -- the check that decides FINDING-06's severity.

THE QUESTION
    A rule POSTed to /ndt/install_flow_entry becomes visible in
    `/ndt/get_switch_openflow_table_entries` only after ~10.7 s. Two readings, with very
    different consequences:

      (A) PROGRAMMED LATE   the rule really is not on the switch for up to 10.7 s
      (B) VISIBLE LATE      the rule is on the switch almost immediately; only the kernel's
                            cached table VIEW lags

    Source says (B): FlowDispatcher::workerLoop_ is `cv_.wait` -> `sender_(burst)` with no clock,
    while DeviceConfigurationAndPowerManager::openflowTablesUpdateWorker fetches, overwrites
    m_cachedOpenFlowTables, and sleeps 10 s -- and HttpSession.cpp:622 serves that cache. But
    source is what the code says; this measures what the switch has.

HOW IT DECIDES
    Poll TWO readers concurrently after one POST:
      * SOUTHBOUND  the P4 proxy's /stats/flow/<dpid> -- the proxy's own read of the switch
      * KERNEL VIEW /ndt/get_switch_openflow_table_entries -- the cached view
    Whichever shows the rule first, and by how much, is the answer.

    🔑 The southbound reader is on the critical path of its own claim: if IT is cached too, a
    late appearance there proves nothing. So the run first establishes that the proxy reader can
    see a change the kernel view has not yet published -- that is exactly what a non-zero gap
    demonstrates, and a zero gap is reported as "cannot separate", never as (A).

[Co-developed with claude code -- Adam]
"""
import argparse, json, os, sys, time, urllib.error, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tr3_f5_window import req, entries_of, classify, dst_of


def southbound_has(proxy, dpid, dst):
    """Does the PROXY's read of the switch carry a rule for dst? -> (bool, priority|None)"""
    d, st, err, body = req(f"{proxy}/stats/flow/{dpid}")
    if err is not None or not isinstance(body, dict):
        return None, None
    for _k, flows in body.items():
        if not isinstance(flows, list):
            continue
        for f in flows:
            m = f.get("match") or {}
            if (m.get("nw_dst") or m.get("ipv4_dst")) == dst:
                return True, f.get("priority")
    return False, None


def kernel_has(ndt, dst):
    """-> ('phantom'|'real'|None, priority|None) from the kernel's cached table view."""
    d, st, err, body = req(f"{ndt}/ndt/get_switch_openflow_table_entries")
    if err is not None:
        return None, None
    for e in entries_of(body)[0]:
        if dst_of(e) == dst:
            return classify(e), e.get("priority")
    return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ndt", default="http://localhost:8000")
    ap.add_argument("--proxy", default="http://localhost:8081")
    ap.add_argument("--out", default=os.environ.get("OUT", "."))
    ap.add_argument("--dpid", type=int, default=1)
    ap.add_argument("--octet", type=int, default=250)
    ap.add_argument("--watch", type=float, default=30.0)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    dst = f"10.0.0.{a.octet}"

    print(f"===== programmed vs visible  {time.strftime('%FT%TZ', time.gmtime())} =====")
    print(f"      rule -> {dst} on dpid {a.dpid}; southbound={a.proxy}/stats/flow/{a.dpid}")

    # --- control: neither reader already carries it --------------------------------------
    sb, _ = southbound_has(a.proxy, a.dpid, dst)
    kv, _ = kernel_has(a.ndt, dst)
    if sb is None:
        print(f"  FAIL  CONTROL: the southbound reader did not answer. Nothing below decides."); return 3
    if sb or kv is not None:
        print(f"  FAIL  CONTROL: {dst} already present (southbound={sb}, kernel={kv}). "
              f"Choose an unused --octet."); return 3
    print(f"  PASS  CONTROL: both readers answer, neither carries {dst} yet.")

    body = json.dumps({"dpid": a.dpid, "priority": 930,
                       "match": {"eth_type": 2048, "ipv4_dst": dst},
                       "actions": [{"type": "OUTPUT", "port": 2}]})
    t0 = time.time()
    d, st, err, resp = req(a.ndt + "/ndt/install_flow_entry", "POST", body)
    print(f"      POST at {t0:.3f} -> http={st} in {d*1000:.0f} ms\n")

    t_sb = t_kv_phantom = t_kv_real = None
    sb_prio = kv_prio = None
    tsv = os.path.join(a.out, "tr3_programmed_vs_visible.tsv")
    with open(tsv, "w") as f:
        f.write("t_since_post_s\tsouthbound\tkernel_view\n")
        while time.time() - t0 < a.watch:
            s_has, s_p = southbound_has(a.proxy, a.dpid, dst)
            k_cls, k_p = kernel_has(a.ndt, dst)
            t = time.time() - t0
            if s_has and t_sb is None:
                t_sb, sb_prio = t, s_p
                print(f"  >>> SOUTHBOUND has the rule at t+{t:.2f}s (priority as programmed: {s_p})")
            if k_cls == "phantom" and t_kv_phantom is None:
                t_kv_phantom = t
                print(f"  >>> kernel view shows it as a PHANTOM at t+{t:.2f}s")
            if k_cls == "real" and t_kv_real is None:
                t_kv_real, kv_prio = t, k_p
                print(f"  >>> kernel view shows it as a REAL entry at t+{t:.2f}s (priority {k_p})")
            f.write(f"{t:.3f}\t{s_has}\t{k_cls}\n")
            if t_sb is not None and t_kv_real is not None:
                break

    print(f"\n----- result -----")
    print(f"  southbound (switch, via proxy) : {'t+%.2f s' % t_sb if t_sb is not None else 'NEVER within watch'}")
    print(f"  kernel view, as phantom        : {'t+%.2f s' % t_kv_phantom if t_kv_phantom is not None else '-'}")
    print(f"  kernel view, as real entry     : {'t+%.2f s' % t_kv_real if t_kv_real is not None else 'NEVER within watch'}")
    print()
    if t_sb is None:
        print("  => CANNOT SEPARATE: the southbound reader never showed the rule either.")
        return 0
    if t_kv_real is None:
        print(f"  => (B) VISIBLE LATE, strongly: the switch had the rule at t+{t_sb:.2f}s and the")
        print(f"     kernel view still had not published it when the watch ended.")
        return 0
    gap = t_kv_real - t_sb
    print(f"  gap (kernel view minus southbound): {gap:.2f} s")
    if gap > 1.0:
        print(f"  => (B) VISIBLE LATE. The rule was on the switch {gap:.2f} s before the kernel's")
        print(f"     table view published it. FINDING-06's window is a VIEW-STALENESS window, not")
        print(f"     an unprogrammed window, and its severity is 'blind', not 'not installed'.")
    elif gap < -1.0:
        print(f"  => the kernel view LED the switch by {-gap:.2f} s -- that is the phantom being")
        print(f"     served as real; treat as a reporting defect, not as programming.")
    else:
        print(f"  => CANNOT SEPARATE at this resolution: the two agree within {abs(gap):.2f} s.")
    print(f"\nartefact: {tsv}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
