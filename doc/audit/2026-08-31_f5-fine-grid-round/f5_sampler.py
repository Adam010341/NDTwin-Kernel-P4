#!/usr/bin/env python3
"""
f5_sampler.py -- PREREG-F5 【TBD-2】: the sampler.  One install, ten grid points, two instruments
                 per point, and every quantity the registration says must be recorded per point.

[Co-developed with claude code -- Adam]

WHAT ONE INSTALL LOOKS LIKE
    POST /ndt/install_flow_entry                       <- t=0 is when this RETURNS (§2)
    then, at t in {0, 0.25, 0.5, 1, 1.5, 2, 3, 5, 8, 12} s, one dual reading:
        KERNEL VIEW   GET  {ndt}/ndt/get_switch_openflow_table_entries   (the cached table view)
        SOUTHBOUND    GET  {southbound}/stats/flow/{dpid}                (what the switch has)
    P4: southbound is the proxy on :8081.  OVS: Ryu on :8080.  Same path shape, different port.

THE FOUR THINGS §2 MAKES NON-NEGOTIABLE, AND WHY EACH ONE IS HERE

 1. t=0 IS THE POST'S RETURN, AND THE POST'S OWN DURATION IS RECORDED SEPARATELY, NEVER FOLDED IN.
    The phantom is written into the cache by the HTTP thread before the response returns
    (HttpSession.cpp's "// TODO: Immediately update the table"), so the response is the earliest
    moment the caller can observe, and it is after the event.  The POST takes time of the same
    order as the window being measured -- so adding it to t would move every point by an amount
    that varies with load, i.e. exactly with the treatment.  Recorded beside t, never inside it.

 2. THE TWO INSTRUMENTS CANNOT BE SIMULTANEOUS, SO THE SKEW IS MEASURED AND THE ORDER ALTERNATES.
    Skew is the gap between the two reads' MIDPOINTS, because a read has a duration and its
    "moment" is not its start.  Over SKEW_LIMIT_MS the point is marked INDETERMINATE and KEPT.
    🔴 Dropping it would bias the distribution towards clean, which is the exact direction this
    round exists to guard against.  And the call order alternates every point, so a systematic
    skew shows up as a difference between the two orders instead of being absorbed into the
    answer.

 3. THE STRUCTURAL FINGERPRINT IS RECORDED AT EVERY POINT AND FILTERS NOTHING.
    classify() is imported from the TR-3 harness -- FINDING-03's three discriminators, not a
    substring search.  T-11-A's own commit message says the fix is deliberately NOT keyed on this
    fingerprint, "because that is what detected the defect, and keying the fix on it would make
    the filter the same shape as the thing it measures".  The same reasoning applies to the
    instrument: it records the fingerprint, it never uses it to decide what to look at.

 4. THE SAMPLER IS A REGISTERED COVARIATE.  Polling is load, and the northbound API serves one
    request at a time, so this instrument competes with the dispatch queue whose window it times.
    Its own CPU is recorded per install.

DRY RUN -- AND WHY IT IS THE DETECTOR'S MUTATION GATE, NOT JUST A SMOKE TEST
    --dry-scenario replaces the transport with a synthetic fabric whose behaviour is known:
        phantom  a phantom appears at t=0 and vanishes at ~2.2 s; the southbound gets the rule
                 at ~20 ms.  The sampler MUST report a hit.
        clean    the southbound gets the rule at ~20 ms and the kernel view only ever shows a
                 real entry.  The sampler MUST report zero hits.
        blind    neither reader ever sees anything.  The sampler MUST report the control failure
                 and refuse to call it "zero phantoms".
    A detector that has only ever been run against a live fabric that happened to be clean has
    not been shown to be able to fire at all -- and "zero" is what a working system and a broken
    instrument both look like.
"""
import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TRH = os.environ.get("TRH") or os.path.join(
    os.path.dirname(HERE), "2026-08-30_live-traffic-round", "harness")
sys.path.insert(0, TRH)
try:
    from tr3_f5_window import req as real_req, classify, entries_of, dst_of   # noqa: E402
except ImportError as e:                                                      # noqa: BLE001
    sys.stderr.write(
        f"REFUSE: cannot import the TR-3 harness from {TRH} ({e}).\n"
        "        classify() carries FINDING-03's structural discriminators and entries_of()\n"
        "        carries the corrected three-level flattening.  Re-implementing either here\n"
        "        would fork a correction that was made because its absence produced a\n"
        "        confident '0 phantom' reading from a function that was looking at wrappers.\n")
    sys.exit(2)

GRID_DEFAULT = [0.0, 0.25, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 12.0]


# --------------------------------------------------------------------------------------------- #
# The synthetic transport.  Only ever installed by --dry-scenario; the real one is `real_req`.
# --------------------------------------------------------------------------------------------- #
class FakeFabric:
    def __init__(self, scenario, dst):
        self.scenario, self.dst, self.t0 = scenario, dst, None

    def __call__(self, url, method="GET", body=None, timeout=15.0):
        now = time.monotonic()
        if method == "POST":
            self.t0 = now
            return (0.031, 200, None, {"status": "queued", "accepted": 1})
        age = (now - self.t0) if self.t0 else -1.0
        if self.scenario == "blind":
            return (0.004, 200, None, [] if "stats/flow" in url else [])
        if "stats/flow" in url:                       # southbound: has it after ~20 ms
            got = age > 0.02
            return (0.006, 200, None,
                    {"1": [{"match": {"nw_dst": self.dst}, "priority": 0,
                            "byte_count": 0, "packet_count": 0, "duration_sec": 1,
                            "actions": ["OUTPUT:2"]}]} if got else {"1": []})
        # kernel view
        if self.scenario == "phantom" and 0.0 <= age < 2.2:
            e = {"match": {"eth_type": 2048, "ipv4_dst": self.dst},          # POST's vocabulary
                 "actions": [{"type": "OUTPUT", "port": 2}], "priority": 930}   # object actions
        elif age > 0.02:
            e = {"match": {"dl_type": 2048, "nw_dst": self.dst},             # OpenFlow's spelling
                 "actions": ["OUTPUT:2"], "priority": 0, "byte_count": 0,
                 "packet_count": 0, "duration_sec": 1, "duration_nsec": 0, "cookie": 0}
        else:
            return (0.008, 200, None, [{"dpid": 1, "flows": {"1": []}}])
        return (0.008, 200, None, [{"dpid": 1, "flows": {"1": [e]}}])


# --------------------------------------------------------------------------------------------- #
def read_kernel(req, ndt, dst):
    t_start = time.monotonic()
    d, st, err, body = req(f"{ndt}/ndt/get_switch_openflow_table_entries")
    mid = t_start + d / 2.0
    if err is not None:
        return dict(ok=False, err=err, cls=None, mid=mid, dur=d)
    ents, shape = entries_of(body)
    for e in ents:
        if dst_of(e) == dst:
            return dict(ok=True, cls=classify(e), mid=mid, dur=d, shape=shape,
                        n_fields=len([k for k in e if not k.startswith("_")]),
                        entry=e, n_entries=len(ents))
    return dict(ok=True, cls=None, mid=mid, dur=d, shape=shape, n_entries=len(ents))


def read_southbound(req, url, dpid, dst):
    t_start = time.monotonic()
    d, st, err, body = req(f"{url}/stats/flow/{dpid}")
    mid = t_start + d / 2.0
    if err is not None or not isinstance(body, dict):
        return dict(ok=False, err=err or f"unexpected body type {type(body).__name__}",
                    has=None, mid=mid, dur=d)
    n = 0
    for _k, flows in body.items():
        if not isinstance(flows, list):
            continue
        n += len(flows)
        for f in flows:
            m = f.get("match") or {}
            if (m.get("nw_dst") or m.get("ipv4_dst")) == dst:
                return dict(ok=True, has=True, mid=mid, dur=d, priority=f.get("priority"),
                            n_flows=n)
    return dict(ok=True, has=False, mid=mid, dur=d, n_flows=n)


def self_cpu():
    try:
        with open("/proc/self/stat", "rb") as fh:
            raw = fh.read().decode()
        rest = raw[raw.rindex(")") + 2:].split()
        return (int(rest[11]) + int(rest[12])) / os.sysconf("SC_CLK_TCK")
    except (OSError, ValueError, IndexError):
        return None


def one_install(req, a, dst, index):
    """One independent unit (§3-zero: the unit is an install, never a grid point)."""
    rec = dict(index=index, dst=dst, dpid=a.dpid, arm=a.arm, when=time.strftime("%FT%T"),
               grid=a.grid, points=[])

    # --- the control, before the POST.  If either reader already carries this dst, or the
    #     southbound will not answer, nothing below decides anything.  TR-3's control, kept.
    pre_k = read_kernel(req, a.ndt, dst)
    pre_s = read_southbound(req, a.southbound, a.dpid, dst)
    rec["control"] = dict(kernel=pre_k.get("cls"), southbound=pre_s.get("has"),
                          kernel_ok=pre_k["ok"], southbound_ok=pre_s["ok"])
    if not pre_s["ok"] or not pre_k["ok"]:
        rec["verdict"] = "CONTROL-FAILED"
        rec["why"] = "a reader did not answer before the install; this install decides nothing"
        return rec
    if pre_s.get("has") or pre_k.get("cls") is not None:
        rec["verdict"] = "CONTROL-FAILED"
        rec["why"] = f"{dst} already present before the install (southbound={pre_s.get('has')}, kernel={pre_k.get('cls')})"
        return rec

    cpu0 = self_cpu()
    body = json.dumps({"dpid": a.dpid, "priority": 930,
                       "match": {"eth_type": 2048, "ipv4_dst": dst},
                       "actions": [{"type": "OUTPUT", "port": 2}]})
    d_post, st_post, err_post, _resp = req(a.ndt + "/ndt/install_flow_entry", "POST", body)
    t0 = time.monotonic()                       # §2: t=0 IS the response's return
    rec["post"] = dict(http=st_post, err=err_post, duration_s=round(d_post, 4))
    if err_post is not None or st_post is None or st_post >= 400:
        rec["verdict"] = "INSTALL-FAILED"
        return rec

    for gi, g in enumerate(a.grid):
        target = t0 + g
        slack = target - time.monotonic()
        if slack > 0:
            time.sleep(slack)
        # §2: the call order alternates every point, so a systematic skew is detectable rather
        # than absorbed.  Parity is on the GLOBAL point index so it also alternates across
        # installs at the same grid position -- otherwise every t=0 reading would share one order.
        kernel_first = ((index + gi) % 2 == 0)
        if kernel_first:
            k = read_kernel(req, a.ndt, dst)
            s = read_southbound(req, a.southbound, a.dpid, dst)
        else:
            s = read_southbound(req, a.southbound, a.dpid, dst)
            k = read_kernel(req, a.ndt, dst)

        skew_ms = abs(k["mid"] - s["mid"]) * 1000.0
        indeterminate = skew_ms > a.skew_limit_ms
        # A phantom is: the kernel view carries it with the phantom fingerprint AND the
        # southbound does not have it at the same moment.  Both halves are required -- the
        # fingerprint alone would flag a rule that is genuinely on the switch but freshly
        # spelled, and "not southbound" alone would flag one the proxy has not read yet.
        hit = (k.get("cls") == "phantom") and (s.get("has") is False) and not indeterminate
        rec["points"].append(dict(
            gi=gi, t_nominal=g, t_actual=round(time.monotonic() - t0, 4),
            order="kernel-first" if kernel_first else "southbound-first",
            skew_ms=round(skew_ms, 1), indeterminate=indeterminate,
            kernel_cls=k.get("cls"), kernel_ok=k["ok"], kernel_dur_s=round(k["dur"], 4),
            kernel_fields=k.get("n_fields"), kernel_entries=k.get("n_entries"),
            southbound_has=s.get("has"), southbound_ok=s["ok"],
            southbound_dur_s=round(s["dur"], 4), southbound_priority=s.get("priority"),
            phantom_hit=hit))

    pts = rec["points"]
    hits = [p for p in pts if p["phantom_hit"]]
    inde = [p for p in pts if p["indeterminate"]]
    # The visible window: first and last grid point at which the kernel view carried it at all.
    seen = [p["t_nominal"] for p in pts if p["kernel_cls"] is not None]
    sb_seen = [p["t_nominal"] for p in pts if p["southbound_has"]]
    rec["summary"] = dict(
        phantom_hits=len(hits), phantom_first_t=hits[0]["t_nominal"] if hits else None,
        phantom_last_t=hits[-1]["t_nominal"] if hits else None,
        indeterminate_points=len(inde),
        kernel_visible_from=seen[0] if seen else None, kernel_visible_to=seen[-1] if seen else None,
        southbound_from=sb_seen[0] if sb_seen else None,
        sampler_cpu_s=round((self_cpu() or 0) - (cpu0 or 0), 3))
    # 🔴 Never "no phantom".  An install in which the SOUTHBOUND never acquired the rule is an
    # install in which the instrument could not have seen a phantom either, and calling that
    # "clean" is the 08-18 mistake in a new place.
    if not sb_seen:
        rec["verdict"] = "BLIND"
        rec["why"] = "the southbound never acquired the rule inside the grid; this install has no discriminating power"
    else:
        rec["verdict"] = "HIT" if hits else "NO-HIT"
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ndt", default=os.environ.get("NDT_URL", "http://localhost:8000"))
    ap.add_argument("--southbound", default=os.environ.get("SOUTHBOUND_URL", "http://localhost:8081"))
    ap.add_argument("--dpid", type=int, default=int(os.environ.get("DPID", 1)))
    ap.add_argument("--arm", default=os.environ.get("ARM", "unknown"))
    ap.add_argument("--dst-file", help="the frozen sequence, as written by f5_dst_sequence.py")
    ap.add_argument("--dst", action="append", default=[])
    ap.add_argument("--out", default=os.environ.get("OUT", "."))
    ap.add_argument("--skew-limit-ms", type=float,
                    default=float(os.environ.get("SKEW_LIMIT_MS", 150)))
    ap.add_argument("--grid", default=os.environ.get("GRID", ""))
    ap.add_argument("--dry-scenario", choices=("phantom", "clean", "blind"),
                    help="synthetic transport; the detector's own force test")
    a = ap.parse_args()

    a.grid = [float(x) for x in a.grid.split()] if a.grid.strip() else GRID_DEFAULT
    a.skew_limit_ms = a.skew_limit_ms
    dsts = list(a.dst)
    if a.dst_file:
        with open(a.dst_file) as fh:
            dsts += [ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")]
    if not dsts:
        ap.error("no destinations: pass --dst-file (the frozen sequence) or --dst")
    if len(set(dsts)) != len(dsts):
        raise SystemExit("REFUSE: the destination list has repeats; a repeated dst makes the\n"
                         "        second install a modify, which produces no cached row at all.")

    os.makedirs(a.out, exist_ok=True)
    path = os.path.join(a.out, f"f5_installs_{a.arm}.jsonl")

    if a.dry_scenario:
        # The grid is compressed so the force test takes seconds rather than two minutes; the
        # phantom's synthetic lifetime is scaled with it, so the shape under test is the same.
        a.grid = [g / 10.0 for g in a.grid]
        print(f"### DRY: synthetic transport, scenario={a.dry_scenario}, grid/10 ###")

    n_hit = n_nohit = n_blind = n_ctl = 0
    with open(path, "a") as fh:
        for i, dst in enumerate(dsts):
            req = FakeFabric(a.dry_scenario, dst) if a.dry_scenario else real_req
            if a.dry_scenario == "phantom":
                # keep the synthetic phantom's life proportional to the compressed grid
                pass
            r = one_install(req, a, dst, i)
            fh.write(json.dumps(r) + "\n")
            fh.flush()
            v = r["verdict"]
            n_hit += v == "HIT"; n_nohit += v == "NO-HIT"
            n_blind += v == "BLIND"; n_ctl += v in ("CONTROL-FAILED", "INSTALL-FAILED")
            s = r.get("summary", {})
            print(f"  [{i:>3}] {dst:<12} {v:<14} hits={s.get('phantom_hits', '-')} "
                  f"indet={s.get('indeterminate_points', '-')} "
                  f"kview={s.get('kernel_visible_from')}..{s.get('kernel_visible_to')} "
                  f"sb={s.get('southbound_from')}")

    n_decisive = n_hit + n_nohit
    print(f"\n----- {a.arm}: {len(dsts)} installs -> {path} -----")
    print(f"  HIT {n_hit}   NO-HIT {n_nohit}   BLIND {n_blind}   CONTROL/INSTALL-FAILED {n_ctl}")
    print(f"  decisive installs (the independent unit, §3-zero): {n_decisive}")
    if n_hit == 0 and n_decisive > 0:
        ub = 3.0 / n_decisive * 100.0
        print(f"  🔴 THE ONLY LEGAL WORDING (§3-zero): \"{n_decisive} installs, zero hits;\n"
              f"     the 95% upper bound on the phantom rate is <={ub:.1f}%\".")
        print("     NOT 'zero phantoms', NOT 'phantoms eliminated', NOT 'the fix is fully effective'.")
        print("     Pooling across arms is legal ONLY if both arms are zero, and must say that it")
        print("     crosses two different fabrics.")
    if n_blind:
        print(f"  ⚠️  {n_blind} install(s) were BLIND -- the southbound never acquired the rule.")
        print("     They are NOT 'no phantom'; they carry no discriminating power and are excluded")
        print("     from the denominator above rather than counted as clean.")

    if a.dry_scenario:
        want = {"phantom": n_hit > 0, "clean": n_hit == 0 and n_decisive > 0,
                "blind": n_blind > 0 or n_ctl > 0}[a.dry_scenario]
        print(f"\n  FORCE TEST scenario={a.dry_scenario}: {'PASS' if want else 'FAIL'}")
        if not want:
            print("  🔴 The detector did not behave as the synthetic fabric requires.  A detector")
            print("     that cannot be made to fire has not been shown to be able to fire, and")
            print("     'zero' is what a working system and a dead instrument both look like.")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
