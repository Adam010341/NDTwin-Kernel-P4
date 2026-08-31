#!/usr/bin/env python3
"""Overlap every leg-1 cell's measurement window against declared foreign-load bands.

Written 2026-09-01 01:35 after `遠端機器測試` self-reported running 25+ mutation-gate
batches on THIS laptop inside the round's exclusive-CPU window, in two bands.

🔑 Why this script exists rather than a hand count: the round's own contamination gate
samples CPU continuously but reports only a FIXED ALLOW-LIST of named processes
(claude-desktop / claude / gnome-shell / chrome).  A load made of qemu-img, python
socket servers and short-lived bash/awk/sed appears in NEITHER column, so reading the
covariate itemisation cannot answer "was this cell contaminated".  Only the declared
band boundaries can, and only by arithmetic on timestamps.

The bands are derived by their author from file mtimes and commit stamps, not recall,
and are widened conservatively here.  A cell counts as suspect on ANY overlap: the
gate's 0.5-core threshold is not the criterion, because the reported load sat mostly
below it — "not flagged red" is not "no effect".

[Co-developed with claude code -- Adam]
"""
import re
import datetime as dt

LOG = ("/home/adam/Desktop/NDTwin-Kernel/doc/audit/"
       "2026-08-31_sampling-ceiling-after-merge/run_e.leg1.stdout.log")

# The round opened on 2026-08-31 and runs past midnight; log stamps are HH:MM:SS only.
ROUND_OPEN_DAY = dt.date(2026, 8, 31)


def stamp(hhmmss):
    """HH:MM:SS -> datetime, rolling to the next day for post-midnight times."""
    h, m, s = (int(x) for x in hhmmss.split(":"))
    day = ROUND_OPEN_DAY + (dt.timedelta(days=1) if h < 12 else dt.timedelta())
    return dt.datetime.combine(day, dt.time(h, m, s))


BANDS = [
    ("A", "23:15-23:46 dense, 25+ gate batches", stamp("23:15:00"), stamp("23:46:00")),
    ("B", "01:13-01:23 two closing re-runs",     stamp("01:13:00"), stamp("01:23:00")),
]


def cells_from(path):
    """A cell's measurement window is the '(open)' sha line to the 'cell CPU gate' line."""
    out, open_at = [], None
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"\[(\d\d:\d\d:\d\d)\]", line)
        if not m:
            continue
        ts = stamp(m.group(1))
        if "(open)" in line:
            open_at = ts
        elif "cell CPU gate" in line:
            g = re.search(r"gate: (\w+) excess=(\S+)", line)
            out.append({"open": open_at, "close": ts,
                        "gate": g.group(1), "excess": float(g.group(2))})
        elif "VERDICT cell=" in line and out and "name" not in out[-1]:
            v = re.search(r"cell=(\S+).*?mark=(\S+).*?spread=(\S+)", line)
            out[-1].update(name=v.group(1), mark=v.group(2), spread=float(v.group(3)))
    return [c for c in out if "name" in c]


def main():
    cells = cells_from(LOG)
    print(f"{'cell':<16} {'window':<19} {'gate':<6} {'excess':>7} {'spread':>7}  overlap")
    print("-" * 86)
    suspect = set()
    for c in cells:
        span = (c["close"] - c["open"]).total_seconds()
        hits = []
        for tag, _, b0, b1 in BANDS:
            ov = (min(c["close"], b1) - max(c["open"], b0)).total_seconds()
            if ov > 0:
                hits.append(f"{tag}:{ov:.0f}s/{span:.0f}s")
                suspect.add(c["name"])
        print(f"{c['name']:<16} {c['open']:%H:%M:%S}-{c['close']:%H:%M:%S}   "
              f"{c['gate']:<6} {c['excess']:>7.3f} {c['spread']:>7.3f}  "
              f"{'  '.join(hits) if hits else '-'}")

    print(f"\nSUSPECT ({len(suspect)}/{len(cells)}): {' '.join(sorted(suspect))}")
    for tag, why, b0, b1 in BANDS:
        print(f"  band {tag}: {b0:%H:%M:%S}-{b1:%H:%M:%S}  {why}")

    # Sensitivity: does dropping the suspect cells change the rung-to-rung spread ratio?
    rungs, clean = {}, {}
    for c in cells:
        r = c["name"].split("_")[2]
        rungs.setdefault(r, []).append(c["spread"])
        if c["name"] not in suspect:
            clean.setdefault(r, []).append(c["spread"])

    print(f"\n{'rung':<8} {'n':>2} {'mean':>9}   {'n':>2} {'clean':>9}   "
          f"{'ratio(all)':>10} {'ratio(clean)':>12}")
    prev_a = prev_c = None
    for r in sorted(rungs, key=lambda x: -int(x)):
        a = sum(rungs[r]) / len(rungs[r])
        cl = clean.get(r, [])
        c = sum(cl) / len(cl) if cl else float("nan")
        ra = f"{prev_a / a:.3f}" if prev_a else "-"
        rc = f"{prev_c / c:.3f}" if prev_c and cl else "-"
        print(f"1/{r:<6} {len(rungs[r]):>2} {a:>9.3f}   {len(cl):>2} {c:>9.3f}   "
              f"{ra:>10} {rc:>12}")
        prev_a, prev_c = a, (c if cl else prev_c)

    print("\n⚠️  n=3 vs n=3 at 1/1024 has no power to detect a small shift.  This table\n"
          "    shows the conclusion does not TURN ON the suspect cells; it does not show\n"
          "    the contamination had no effect.")


if __name__ == "__main__":
    main()
