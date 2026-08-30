#!/usr/bin/env python3
"""
tr3_simultaneity.py -- the decisive test for TR-3's mechanism.

WHAT THE 08-30 DATA ACTUALLY SHOWS, ONCE THE INSTRUMENT WAS FIXED
    A rule POSTed to /ndt/install_flow_entry returns 200, appears in the kernel's table view for
    1-11 s as a PHANTOM (the request echoed back: requested priority, POST match vocabulary, no
    counters -- T-4 FINDING-03), and then becomes a REAL programmed entry **with its priority
    rewritten to 0**. Keying on priority hides the second half completely.

THE TWO STORIES FOR THE 1-11 s LATENCY
      (A) PER-RULE   each queued request is dispatched on its own schedule, so a rule posted 5 s
                     after another is programmed 5 s after it.
      (B) PERIODIC   a cycle picks up everything pending, so rules posted at different times are
                     programmed AT THE SAME INSTANT, and the observed latency is just the
                     distance from the POST to the next cycle.

    Post n rules `spacing` apart and watch. Spread of the PROGRAMMING instants ~= spacing*(n-1)
    means (A); ~= 0 means (B). No reading of the data satisfies both.

WHY THE POSTS HAPPEN INSIDE THE POLLING LOOP
    The first version posted all n rules and only then started watching, so the earliest rule was
    already ~10 s old -- past its whole phantom lifetime -- when the first sample was taken. It
    reported "NEVER SEEN" for two of three rules, which reads exactly like a system finding about
    a single-slot queue. It was the schedule of the instrument.
    🔑 A window can only be measured by something that was already looking.

[Co-developed with claude code -- Adam]
"""
import argparse, json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tr3_f5_window import req, entries_of, classify, dst_of


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ndt", default=os.environ.get("NDT_URL", "http://localhost:8000"))
    ap.add_argument("--out", default=os.environ.get("OUT", "."))
    ap.add_argument("--spacing", type=float, default=5.0)
    ap.add_argument("--n", type=int, default=3)
    ap.add_argument("--watch", type=float, default=45.0, help="seconds after the LAST post")
    ap.add_argument("--first-octet", type=int, default=220)
    ap.add_argument("--label", default="simultaneity")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    rules = [{"prio": 920 + i, "dst": f"10.0.0.{a.first_octet + i}",
              "post_at": None, "ph_first": None, "ph_last": None, "prog_at": None,
              "prog_prio": None}
             for i in range(a.n)]

    print(f"===== TR-3 simultaneity  {time.strftime('%FT%TZ', time.gmtime())} =====")
    print(f"      {a.n} rules {a.spacing}s apart; each is identified by its DESTINATION, "
          f"because the priority does not survive the trip")

    d, st, err, body = req(a.ndt + "/ndt/get_switch_openflow_table_entries")
    if err is not None:
        print(f"  FAIL  CONTROL: kernel did not answer ({err})."); return 3
    ents, where = entries_of(body)
    n_real = sum(1 for e in ents if classify(e) == "real")
    print(f"      baseline {len(ents)} entries from {where}; {n_real} real")
    if n_real == 0:
        print("  FAIL  CONTROL: no real entries visible; absence below would prove nothing."); return 3
    already = [r["dst"] for r in rules if any(dst_of(e) == r["dst"] for e in ents)]
    if already:
        print(f"  FAIL  CONTROL: {already} already present before this test posted anything. "
              f"Pick a --first-octet that is unused, or this measures a previous run."); return 3
    print(f"  PASS  CONTROL: {n_real} real entries visible; none of the target destinations exists yet.")

    tsv = os.path.join(a.out, f"tr3_{a.label}.tsv")
    t_start = time.time()
    schedule = [t_start + i * a.spacing for i in range(a.n)]
    end = schedule[-1] + a.watch
    nsamp = 0
    with open(tsv, "w") as f:
        f.write("epoch\t" + "\t".join(f"{r['dst']}:ph/prog" for r in rules) + "\n")
        while time.time() < end:
            # post anything now due, from inside the loop
            for i, r in enumerate(rules):
                if r["post_at"] is None and time.time() >= schedule[i]:
                    b = json.dumps({"dpid": 1, "priority": r["prio"],
                                    "match": {"eth_type": 2048, "ipv4_dst": r["dst"]},
                                    "actions": [{"type": "OUTPUT", "port": 2}]})
                    r["post_at"] = time.time()
                    _, s2, e2, _ = req(a.ndt + "/ndt/install_flow_entry", "POST", b)
                    print(f"      POST prio {r['prio']} -> {r['dst']} at {r['post_at']:.3f} http={s2}")

            _, s3, e3, bod = req(a.ndt + "/ndt/get_switch_openflow_table_entries")
            now = time.time()
            if e3 is not None:
                continue
            ents, _ = entries_of(bod)
            mine = {}
            for e in ents:
                dd = dst_of(e)
                if dd:
                    mine.setdefault(dd, []).append(e)
            row = []
            for r in rules:
                es = mine.get(r["dst"], [])
                ph = [e for e in es if classify(e) == "phantom"]
                pr = [e for e in es if classify(e) == "real"]
                if ph:
                    if r["ph_first"] is None:
                        r["ph_first"] = now
                    r["ph_last"] = now
                if pr and r["prog_at"] is None:
                    r["prog_at"] = now
                    r["prog_prio"] = pr[0].get("priority")
                row.append(f"{len(ph)}/{len(pr)}")
            f.write(f"{now:.3f}\t" + "\t".join(row) + "\n")
            nsamp += 1

    print(f"\n----- results ({nsamp} samples) -----")
    print(f"{'prio':>5}{'dst':>13}{'posted':>15}{'phantom_s':>11}{'programmed_s':>14}{'prog_prio':>10}")
    for r in rules:
        ph = f"{r['ph_last'] - r['post_at']:.2f}" if r["ph_last"] else "-"
        pg = f"{r['prog_at'] - r['post_at']:.2f}" if r["prog_at"] else "NEVER"
        pp = r["prog_prio"] if r["prog_prio"] is not None else "-"
        print(f"{r['prio']:>5}{r['dst']:>13}{r['post_at']:>15.3f}{ph:>11}{pg:>14}{pp:>10}")

    progs = [r["prog_at"] for r in rules if r["prog_at"]]
    posts = [r["post_at"] for r in rules if r["post_at"]]
    if len(progs) < 2:
        print("\n  N/A   fewer than two rules were programmed; cannot discriminate."); return 0
    spread_prog = max(progs) - min(progs)
    spread_post = max(posts) - min(posts)
    print(f"\nspread of PROGRAMMING instants: {spread_prog:.3f} s")
    print(f"spread of POST instants:        {spread_post:.3f} s")
    prios = {r["prog_prio"] for r in rules if r["prog_at"]}
    print(f"priorities as PROGRAMMED: {prios}   (requested: {sorted(r['prio'] for r in rules)})")
    print()
    # 🔴 The spread comparison that used to live here printed "PER-RULE (A)" over the 8-rule
    # run, whose four-rules-at-one-instant structure is the clearest possible periodic signature.
    # A grid and a per-rule schedule have the SAME max-min spread once the posts span more than
    # one period, so the statistic cannot separate them and must not pretend to.
    # The verdict now comes from clustering, in tr3_grid_analyse.py, which reads this run's TSV.
    print("  VERDICT DEFERRED to tr3_grid_analyse.py -- a max-min spread cannot distinguish a")
    print("  periodic grid from a per-rule schedule. Run:")
    print(f"      python3 tr3_grid_analyse.py {tsv}")
    print(f"\nartefact: {tsv}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
