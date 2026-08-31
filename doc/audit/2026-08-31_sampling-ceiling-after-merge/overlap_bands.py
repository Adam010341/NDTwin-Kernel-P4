#!/usr/bin/env python3
"""Classify every leg-1 cell against the declared/discovered foreign-load bands.

🔴 THERE IS NO `clean` CATEGORY IN THIS SCRIPT, AND THERE MUST NOT BE ONE.
No cell on this machine can be shown to be free of foreign load. The bands below are the
ones somebody happened to be able to evidence; the round's own instrument cannot enumerate
them (F-21: the covariate line scopes itself from a four-name allow-list). So the only two
categories that can be justified are:

    KNOWN-OVERLAP   this cell provably overlaps an evidenced band
    UNKNOWN         nobody has evidence either way for this cell

An earlier version of this file printed a `clean` column and a "clean-only" ratio. Both were
withdrawn on 2026-09-01 after a THIRD band was found that made four of the six cells in the
supposedly-clean 1/256 rung fully overlapping. The withdrawal is the finding; recomputing the
same column against a longer band list would repeat the error with a fresher number.

Band provenance -- none of it from recall:
  A  23:15-23:46      25+ mutation-gate batches, self-reported by 遠端機器測試; boundaries
                      from its scratchpad mtimes and commit stamps.
  B  01:13-01:23      two closing re-runs by the same session, same provenance.
  C  23:57:39-00:30:54  a qemu VM, pid 52578, found independently by 8/31 auditor in that
                      session's own committed witness logs:
                        .../2026-08-31_completeness-experiments/B-nslab-build/raw/
                          host_witness_a_rerun.log   150 samples 23:57:39 -> 00:10:10
                          host_witness_bcd.log       200 samples 00:14:12 -> 00:30:54
                      Verified here: 350/350 samples say qemu=1, all pid=52578.
                      🔴 C IS A LOWER BOUND. A witness log only records while the witness is
                      alive; the VM may have started earlier and stopped later. pid 52578 is
                      gone, so its utime/stime died with it -- "a VM was up" can no longer be
                      turned into "it drew N cores" by any measurement.
                      (The 4-minute seam 00:10:10-00:14:12 has no witness coverage; the same
                      pid appears on both sides, so the VM was continuously alive across it.)

A cell's span is taken from its `--- <cell> ---` header to its `cell CPU gate` line, i.e. the
FULL cell including bringup, not just the 300 s measurement window. That is the conservative
choice and it is what makes `e_bl_1024_3` (36 s) and `e_bl_0256_3` (9 s) count.

🔴 Gate colour is reported with the EFFECTIVE detection floor, not the nominal threshold. Every
one of these cells passed at a nominal 0.5 cores, but the floor that actually applies is
baseline + 0.5 ≈ 0.95 cores (F-13a). "GREEN" here means "below ~0.95", not "below 0.5", and for
loads under that floor it carries no information at all.

Writes a machine-readable sidecar next to cells.tsv so the marking has a reader (F-19's
"one writer, zero readers" is a defect this project has already paid for): the 2x2 figure and
FINDINGS both consume raw/cell_overlap.tsv, not this script's stdout.

[Co-developed with claude code -- Adam]
"""
import re
import datetime as dt

ROUND = ("/home/adam/Desktop/NDTwin-Kernel/doc/audit/"
         "2026-08-31_sampling-ceiling-after-merge")
LOG = f"{ROUND}/run_e.leg1.stdout.log"
SIDECAR = f"{ROUND}/raw/cell_overlap.tsv"

ROUND_OPEN_DAY = dt.date(2026, 8, 31)
EFFECTIVE_FLOOR = 0.95   # cores; F-13a.  NOT the nominal 0.5.
MIN_UNKNOWN_FOR_RATIO = 3


def stamp(hhmmss):
    h, m, s = (int(x) for x in hhmmss.split(":"))
    day = ROUND_OPEN_DAY + (dt.timedelta(days=1) if h < 12 else dt.timedelta())
    return dt.datetime.combine(day, dt.time(h, m, s))


BANDS = [
    ("A", "25+ mutation-gate batches (self-reported)",
     stamp("23:15:00"), stamp("23:46:00"), False),
    ("B", "two closing gate re-runs (self-reported)",
     stamp("01:13:00"), stamp("01:23:00"), False),
    ("C", "qemu VM pid 52578 (witness logs, LOWER BOUND)",
     stamp("23:57:39"), stamp("00:30:54"), True),
]


def cells_from(path):
    """Span = the cell's `--- name ---` header line through its `cell CPU gate` line."""
    out, cur = [], None
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"\[(\d\d:\d\d:\d\d)\]", line)
        if not m:
            continue
        ts = stamp(m.group(1))
        h = re.search(r"--- (e_\w+?)\s+arm=", line)
        if h:
            cur = {"name": h.group(1), "start": ts}
        elif cur and "cell CPU gate" in line:
            g = re.search(r"gate: (\w+) excess=(\S+)", line)
            cur.update(end=ts, gate=g.group(1), excess=float(g.group(2)))
        elif cur and "VERDICT cell=" in line:
            v = re.search(r"cell=(\S+).*?mark=(\S+).*?spread=(\S+)", line)
            cur.update(mark=v.group(2), spread=float(v.group(3)))
            out.append(cur)
            cur = None
    return out


def main():
    cells = cells_from(LOG)
    rows = []
    for c in cells:
        span = (c["end"] - c["start"]).total_seconds()
        hits, total = [], 0.0
        for tag, _, b0, b1, _lb in BANDS:
            ov = (min(c["end"], b1) - max(c["start"], b0)).total_seconds()
            if ov > 0:
                hits.append(f"{tag}:{ov:.0f}s")
                total += ov
        c["category"] = "KNOWN-OVERLAP" if hits else "UNKNOWN"
        c["bands"] = ",".join(hits) if hits else "-"
        c["overlap_s"], c["span_s"] = total, span
        rows.append(c)

    print(f"{'cell':<15} {'span':<19} {'gate':<6} {'excess':>7} {'spread':>7} "
          f"{'category':<14} bands / span")
    print("-" * 100)
    for c in rows:
        print(f"{c['name']:<15} {c['start']:%H:%M:%S}-{c['end']:%H:%M:%S}   "
              f"{c['gate']:<6} {c['excess']:>7.3f} {c['spread']:>7.3f} "
              f"{c['category']:<14} {c['bands']} / {c['span_s']:.0f}s")

    known = [c for c in rows if c["category"] == "KNOWN-OVERLAP"]
    print(f"\nKNOWN-OVERLAP {len(known)}/{len(rows)}   UNKNOWN {len(rows)-len(known)}/{len(rows)}")
    print("🔴 UNKNOWN is NOT clean.  It means no one has evidence either way for that cell.")
    print(f"🔴 All {len(rows)} cells passed the CPU gate, but the effective detection floor is "
          f"~{EFFECTIVE_FLOOR} cores (baseline+0.5), not the nominal 0.5.  Every band above sat "
          f"mostly below it, so GREEN carries no information here.")
    for tag, why, b0, b1, lb in BANDS:
        print(f"   band {tag}: {b0:%H:%M:%S}-{b1:%H:%M:%S}  {why}"
              + ("   ← lower bound" if lb else ""))

    # Per-rung availability.  A ratio is NOT printed where too few UNKNOWN cells remain:
    # the point to report is that the comparison cannot be made, not a fresher number.
    rungs = {}
    for c in rows:
        rungs.setdefault(c["name"].split("_")[2], []).append(c)
    print(f"\n{'rung':<8} {'n':>2} {'all-cell mean spread':>21} {'KNOWN':>6} {'UNKNOWN':>8}   "
          f"rung-to-rung ratio over UNKNOWN cells")
    prev = None
    for r in sorted(rungs, key=lambda x: -int(x)):
        cs = rungs[r]
        unk = [c for c in cs if c["category"] == "UNKNOWN"]
        mean_all = sum(c["spread"] for c in cs) / len(cs)
        if len(unk) < MIN_UNKNOWN_FOR_RATIO:
            verdict = f"n/a — only {len(unk)} UNKNOWN cell(s), need {MIN_UNKNOWN_FOR_RATIO}"
            cur = None
        else:
            cur = sum(c["spread"] for c in unk) / len(unk)
            verdict = (f"{prev/cur:.3f}" if prev else "-") + "  (UNKNOWN-only, NOT clean)"
        print(f"1/{r:<6} {len(cs):>2} {mean_all:>21.3f} {len(cs) - len(unk):>6} "
              f"{len(unk):>8}   {verdict}")
        prev = cur

    print("\n🔴 The lower rungs no longer hold enough non-overlapping cells to compute a "
          "comparison at all.\n    That is the result.  It cannot be repaired by recomputing "
          "against a longer band list —\n    a third band appeared after the first two were "
          "thought complete, and the population of\n    bands is not enumerable by this round's "
          "instruments (F-21).")

    with open(SIDECAR, "w", encoding="utf-8") as fh:
        fh.write("cell\tstart\tend\tspan_s\tgate\texcess\tmark\tspread\t"
                 "category\tbands\toverlap_s\n")
        for c in rows:
            fh.write(f"{c['name']}\t{c['start']:%H:%M:%S}\t{c['end']:%H:%M:%S}\t"
                     f"{c['span_s']:.0f}\t{c['gate']}\t{c['excess']:.3f}\t{c['mark']}\t"
                     f"{c['spread']:.3f}\t{c['category']}\t{c['bands']}\t{c['overlap_s']:.0f}\n")
    print(f"\nwrote {SIDECAR}  (readers: the 2x2 figure, FINDINGS — not this stdout)")


if __name__ == "__main__":
    main()
