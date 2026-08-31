#!/usr/bin/env python3
"""Classify every leg-1 cell against the evidenced foreign-load bands on THIS machine.

🔴 THE WORD `clean` DOES NOT APPEAR AS A CATEGORY, AND MUST NOT.
Enumerating foreign load gives a LOWER BOUND, never a list. The bands below are the ones
somebody could evidence; this round's own instrument cannot enumerate them at all (F-21: the
covariate line scopes itself from a four-name allow-list). So the categories are:

    KNOWN-OVERLAP   an evidenced band overlaps this cell's MEASUREMENT window
    BRINGUP-ONLY    an evidenced band overlaps only the cell's bringup, not its measurement
    UNKNOWN         no evidenced band overlaps this cell at all — which is NOT "clean"

🔴 WHICH SPAN. `spread` is computed from the measurement window, so that window decides
KNOWN-OVERLAP. Bringup (fabric teardown, rebuild, P4 recompile) is reported separately rather
than folded in either direction: silently including it inflates the suspect set, silently
dropping it hides a real overlap. The ratio population is "no evidenced overlap of the
MEASUREMENT window" = UNKNOWN + BRINGUP-ONLY.

Band provenance -- none from recall:
  A  23:15-23:46   25+ mutation-gate batches, self-reported by 遠端機器測試; boundaries from
                   its scratchpad mtimes and commit stamps.
                   ⚠️ mtime-derived boundaries are structurally blind to a period where
                   something was running but not writing files. The session says so itself:
                   "I had no such period this time, but that is luck, not design."
  B  01:13-01:23   two closing re-runs by the same session, same provenance.

🔴 A THIRD BAND WAS PROPOSED AND WITHDRAWN, and the reason is worth keeping. A qemu VM,
pid 52578, appears in 350/350 samples of that session's committed witness logs. Those numbers
are real. They are **not about this machine**: the same file says the log was taken 宿主上 (on
the host) and that its peak is "the projection of this round's guest's own 16 vCPU onto the
host". This laptop has 14 cores, and its only qemu is pid 405062. The samples were verified and
their REFERENT was not -- the answer to "are these numbers real" is not the answer to "which
machine are they about". Bands A and B stand; there is no band C here.

STANDING CONSTANT, NOT A TREATMENT: pid 405062 `qemu-system-x86_64 -name claude-cowork-vm` has
been up since 2026-08-30 19:41:30 -- ~30 h, spanning §0-ter's baseline measurement and every
cell of this round -- for a total of 6m55s of CPU, i.e. ~0.004 cores averaged. Because it was
already running when the baseline was measured, it is absorbed INTO the baseline and must not be
counted again as contamination. Recorded so the next reader does not re-derive it as a finding.

⚠️ COUNTING qemu BY PATTERN IS UNSOUND HERE. 遠端機器測試's test fixtures spawn stand-ins whose
`argv[0]` is literally `qemu-system-x86_64` (`bash -c 'sleep 30; :' qemu-system-x86_64 …`, six
sites), so any witness that counts by name counts them as VMs. The same trap bit the enumeration
written to check this: a shell whose own command line contained the string matched itself. Same
family as `pkill -f iperf3` (F-20) -- the victim is chosen by what it happens to mention.

🔴 Gate colour is reported with the EFFECTIVE detection floor. Every cell here passed at a
nominal 0.5 cores, but the floor that applies is baseline + 0.5 ≈ 0.95 cores (F-13a). "GREEN"
means "below ~0.95", and for loads under that floor it carries no information at all.

Writes a machine-readable sidecar beside cells.tsv so the marking has a reader (a marker living
only in prose is a writer with no reader, which this project has already paid for): the 2x2
figure and FINDINGS consume raw/cell_overlap.tsv, not this stdout. `raw/` is gitignored by
design (.gitignore:74) — like cells.tsv itself, this file belongs to the audit-raw ref.

[Co-developed with claude code -- Adam]
"""
import re
import datetime as dt

ROUND = ("/home/adam/Desktop/NDTwin-Kernel/doc/audit/"
         "2026-08-31_sampling-ceiling-after-merge")
LOG = f"{ROUND}/run_e.leg1.stdout.log"
SIDECAR = f"{ROUND}/raw/cell_overlap.tsv"

ROUND_OPEN_DAY = dt.date(2026, 8, 31)
EFFECTIVE_FLOOR = 0.95     # cores; F-13a.  NOT the nominal 0.5.
MIN_FOR_RATIO = 3          # cells with an unoverlapped measurement window


def stamp(hhmmss):
    h, m, s = (int(x) for x in hhmmss.split(":"))
    day = ROUND_OPEN_DAY + (dt.timedelta(days=1) if h < 12 else dt.timedelta())
    return dt.datetime.combine(day, dt.time(h, m, s))


BANDS = [
    ("A", "25+ mutation-gate batches (self-reported, mtime-derived)",
     stamp("23:15:00"), stamp("23:46:00")),
    ("B", "two closing gate re-runs (self-reported, mtime-derived)",
     stamp("01:13:00"), stamp("01:23:00")),
]


def cells_from(path):
    """header line -> `(open)` sha line -> `cell CPU gate` line."""
    out, cur = [], None
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"\[(\d\d:\d\d:\d\d)\]", line)
        if not m:
            continue
        ts = stamp(m.group(1))
        h = re.search(r"--- (e_\w+?)\s+arm=", line)
        if h:
            cur = {"name": h.group(1), "head": ts}
        elif cur and "(open)" in line:
            cur["open"] = ts
        elif cur and "cell CPU gate" in line:
            g = re.search(r"gate: (\w+) excess=(\S+)", line)
            cur.update(close=ts, gate=g.group(1), excess=float(g.group(2)))
        elif cur and "VERDICT cell=" in line:
            v = re.search(r"cell=(\S+).*?mark=(\S+).*?spread=(\S+)", line)
            cur.update(mark=v.group(2), spread=float(v.group(3)))
            out.append(cur)
            cur = None
    return out


def overlap(a0, a1, b0, b1):
    return max(0.0, (min(a1, b1) - max(a0, b0)).total_seconds())


def main():
    rows = cells_from(LOG)
    for c in rows:
        meas, boot = [], []
        for tag, _, b0, b1 in BANDS:
            om = overlap(c["open"], c["close"], b0, b1)
            ob = overlap(c["head"], c["open"], b0, b1)
            if om:
                meas.append(f"{tag}:{om:.0f}s")
            if ob:
                boot.append(f"{tag}:{ob:.0f}s")
        c["meas"], c["boot"] = ",".join(meas) or "-", ",".join(boot) or "-"
        c["category"] = ("KNOWN-OVERLAP" if meas else
                         "BRINGUP-ONLY" if boot else "UNKNOWN")

    print(f"{'cell':<15} {'measurement window':<19} {'gate':<6} {'excess':>7} {'spread':>7} "
          f"{'category':<14} {'meas':<9} bringup")
    print("-" * 104)
    for c in rows:
        print(f"{c['name']:<15} {c['open']:%H:%M:%S}-{c['close']:%H:%M:%S}   {c['gate']:<6} "
              f"{c['excess']:>7.3f} {c['spread']:>7.3f} {c['category']:<14} "
              f"{c['meas']:<9} {c['boot']}")

    n_k = sum(c["category"] == "KNOWN-OVERLAP" for c in rows)
    n_b = sum(c["category"] == "BRINGUP-ONLY" for c in rows)
    print(f"\nKNOWN-OVERLAP {n_k}/{len(rows)}   BRINGUP-ONLY {n_b}   "
          f"UNKNOWN {len(rows)-n_k-n_b}")
    print("🔴 UNKNOWN is NOT clean — it means no one has evidence either way. Enumerating "
          "foreign\n   load yields a lower bound, never a list.")
    print(f"🔴 All {len(rows)} cells passed the CPU gate, but the effective detection floor is "
          f"~{EFFECTIVE_FLOOR} cores\n   (baseline+0.5), not the nominal 0.5. Both bands sat "
          f"mostly below it, so GREEN carries no\n   information about them.")
    for tag, why, b0, b1 in BANDS:
        print(f"   band {tag}: {b0:%H:%M:%S}-{b1:%H:%M:%S}  {why}")

    rungs = {}
    for c in rows:
        rungs.setdefault(c["name"].split("_")[2], []).append(c)
    # 🔴 THE LADDER'S STEPS ARE NOT UNIFORM.  LADDER="1024 256 64 32 16 8 4 1" steps by
    # 4x, 4x, 2x, 2x, 2x, 2x, 4x.  A sqrt(n) expectation therefore predicts 2.000 for the 4x
    # steps and 1.414 for the 2x ones.  Comparing every observed ratio against 2 reads the 2x
    # steps as a deepening departure when they may be no departure at all -- which is exactly
    # the error this column exists to stop.  Report predicted, observed, and the shortfall.
    print(f"\n{'rung':<8} {'n':>2} {'all-cell':>9} {'KNOWN':>6} {'elig':>5} {'mean elig':>10} "
          f"{'step':>5} {'pred':>6} {'obs':>6} {'obs/pred':>9}")
    prev = prev_rate = None
    for r in sorted(rungs, key=lambda x: -int(x)):
        cs = rungs[r]
        rate = int(r)
        elig = [c for c in cs if c["category"] != "KNOWN-OVERLAP"]
        mean_all = sum(c["spread"] for c in cs) / len(cs)
        step = pred = obs = frac = None
        if len(elig) < MIN_FOR_RATIO:
            cur, shown = None, float("nan")
        else:
            cur = shown = sum(c["spread"] for c in elig) / len(elig)
            if prev:
                step = prev_rate / rate          # sampling-rate multiplier for THIS step
                pred = step ** 0.5               # sqrt(n): spread falls as 1/sqrt(samples)
                obs = prev / cur
                frac = obs / pred
        f = lambda v, w, p=3: (f"{v:>{w}.{p}f}" if v is not None else " " * (w - 1) + "-")
        print(f"1/{r:<6} {len(cs):>2} {mean_all:>9.3f} "
              f"{sum(c['category'] == 'KNOWN-OVERLAP' for c in cs):>6} {len(elig):>5} "
              f"{shown:>10.3f} {f(step,5,1)} {f(pred,6)} {f(obs,6)} {f(frac,9)}")
        if cur:
            prev, prev_rate = cur, rate
    print("   'elig' = measurement window not overlapped by any evidenced band "
          "(UNKNOWN + BRINGUP-ONLY).\n   It is NOT a clean subset; it is the subset nobody has "
          "evidence against.\n"
          "   'step' = this rung's sampling-rate multiplier over the previous one — 4x and 2x "
          "steps both\n           occur, so 'pred' is sqrt(step), NOT a constant 2.  "
          "'obs/pred' = 1.000 means sqrt(n) held.")

    with open(SIDECAR, "w", encoding="utf-8") as fh:
        fh.write("cell\thead\topen\tclose\tgate\texcess\tmark\tspread\t"
                 "category\tmeas_overlap\tbringup_overlap\n")
        for c in rows:
            fh.write(f"{c['name']}\t{c['head']:%H:%M:%S}\t{c['open']:%H:%M:%S}\t"
                     f"{c['close']:%H:%M:%S}\t{c['gate']}\t{c['excess']:.3f}\t{c['mark']}\t"
                     f"{c['spread']:.3f}\t{c['category']}\t{c['meas']}\t{c['boot']}\n")
    print(f"\nwrote {SIDECAR}  (readers: the 2x2 figure, FINDINGS — not this stdout)")


if __name__ == "__main__":
    main()
