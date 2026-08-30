#!/usr/bin/env python3
"""
tr3_grid_analyse.py -- decide PERIODIC vs PER-RULE by CLUSTERING the programming instants,
and re-derive everything from the saved per-sample TSVs so no fabric is needed.

WHY THIS EXISTS AS A SEPARATE STEP
    tr3_simultaneity.py's built-in verdict compared max-min spreads:

        spread(programmed) vs spread(posted)

    On the 8-rule run that test printed "PER-RULE (A)" over data that is as periodic as data
    gets: four rules posted 3 s apart were programmed within 10 ms of one another, then three
    more together 10.71 s later, then one 10.65 s after that. A grid and a per-rule schedule have
    the SAME total spread whenever the posts span more than one period, so the statistic is blind
    to the very structure it was written to detect.
    🔴 memory: failures-that-report-success -- this is the mirror shape. The gate could go red and
    could go green; it just could not tell the two apart, and it announced a verdict anyway. Ask
    of any discriminator: what would the data look like under the OTHER hypothesis, and does this
    statistic actually differ between them?

WHAT IT DOES INSTEAD
    Cluster the programming instants with a tolerance. Under PER-RULE, n rules posted `spacing`
    apart give n clusters and inter-cluster gaps equal to `spacing`. Under PERIODIC, they give
    far fewer clusters, gaps equal to the PERIOD, and -- the signature that cannot be faked --
    rules posted at different times sharing one instant.

    Analysis reads the same artefacts the run wrote, so the conclusion can be re-derived, argued
    with, and re-run against a changed tolerance without re-touching the lab.
    (memory: evidence-must-outlive-the-handoff)

[Co-developed with claude code -- Adam]
"""
import argparse, glob, os, statistics, sys


def load(path):
    """-> {dst: (first_prog_epoch, first_phantom_epoch, last_phantom_epoch)}"""
    with open(path) as f:
        hdr = f.readline().rstrip("\n").split("\t")
        dsts = [h.split(":")[0] for h in hdr[1:]]
        first_prog = {d: None for d in dsts}
        first_ph = {d: None for d in dsts}
        last_ph = {d: None for d in dsts}
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) != len(hdr):
                continue
            try:
                ep = float(parts[0])
            except ValueError:
                continue
            for d, cell in zip(dsts, parts[1:]):
                try:
                    ph, pr = (int(x) for x in cell.split("/"))
                except ValueError:
                    continue
                if ph > 0:
                    if first_ph[d] is None:
                        first_ph[d] = ep
                    last_ph[d] = ep
                if pr > 0 and first_prog[d] is None:
                    first_prog[d] = ep
    return {d: (first_prog[d], first_ph[d], last_ph[d]) for d in dsts}


def cluster(vals, tol):
    out = []
    for v in sorted(vals):
        if out and v - out[-1][-1] <= tol:
            out[-1].append(v)
        else:
            out.append([v])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tsv", nargs="*", help="tr3_*.tsv files (default: all in OUT)")
    ap.add_argument("--tol", type=float, default=0.5,
                    help="two instants within this many seconds are the same cycle")
    a = ap.parse_args()
    files = a.tsv or sorted(glob.glob(os.path.join(os.environ.get("OUT", "."), "tr3_simult*.tsv")))
    if not files:
        print("no TSVs given or found"); return 2

    all_gaps = []
    for path in files:
        rec = load(path)
        progs = [v[0] for v in rec.values() if v[0]]
        print(f"\n===== {os.path.basename(path)} =====")
        print(f"{'dst':>13}{'programmed_epoch':>20}{'phantom_ends':>16}{'handover_ms':>13}")
        for d, (pg, pf, pl) in sorted(rec.items()):
            ho = f"{(pg - pl) * 1000:.0f}" if (pg and pl) else "-"
            print(f"{d:>13}{pg if pg else 0:>20.3f}{pl if pl else 0:>16.3f}{ho:>13}")
        if len(progs) < 2:
            print("  fewer than two programmed; skipping"); continue
        cl = cluster(progs, a.tol)
        gaps = [cl[i + 1][0] - cl[i][-1] for i in range(len(cl) - 1)]
        all_gaps += gaps
        print(f"\n  {len(progs)} rules -> {len(cl)} distinct programming instant(s) "
              f"(tolerance {a.tol}s)")
        for i, c in enumerate(cl):
            print(f"    cycle {i}: {len(c)} rule(s) at {c[0]:.3f}"
                  + (f"  (spread within cycle: {(c[-1]-c[0])*1000:.0f} ms)" if len(c) > 1 else ""))
        if gaps:
            print(f"  gaps between cycles: {', '.join(f'{g:.2f}' for g in gaps)} s")
        if len(cl) < len(progs):
            print(f"  => PERIODIC: rules posted at DIFFERENT times share one programming instant. "
                  f"A per-rule schedule cannot do that.")
        else:
            print(f"  => every rule got its own instant here; this file alone cannot separate the "
                  f"two stories (posts may simply be further apart than the period).")

    if all_gaps:
        print(f"\n===== pooled across {len(files)} file(s) =====")
        print(f"  inter-cycle gaps: {', '.join(f'{g:.2f}' for g in sorted(all_gaps))} s")
        print(f"  mean {statistics.mean(all_gaps):.2f} s"
              + (f", sd {statistics.stdev(all_gaps):.2f} s" if len(all_gaps) > 1 else ""))
        print(f"  => dispatch cycle period ~= {statistics.mean(all_gaps):.1f} s")
        print(f"  => an install's exposure window is the distance from the POST to the next cycle:")
        print(f"     bounded above by the period, uniform-ish below it, mean ~= "
              f"{statistics.mean(all_gaps)/2:.1f} s. It is set by a CLOCK, not by queue depth.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
