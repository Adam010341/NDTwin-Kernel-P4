#!/usr/bin/env python3
"""Old-vs-new tables for every number and verdict FINDINGS section 4 (and 5(b), 8) quotes.

[Co-developed with claude code -- Adam]

Reads two summary.json files -- the base analysis (30aa500c, the union window) and the fix
(both readings, from its cpu_window block) -- and prints markdown tables:
  (1) the per-rung table of FINDINGS 4: coop S, delta coop, delta link, spread coop/link, resolved
  (2) the decomposition: F, m, share, verdict, H-C2 block, per group
  (3) the registered bmv2 ratio per rung, and which rungs fall outside [0.90, 1.15]
  (4) reconciliation (b) rows
  (5) the per-group CPU cells (kernel and bmv2) that moved, for fig3
Every value is read from the files; nothing is recomputed here.
Usage: compare_tables.py <base summary.json> <fix summary.json>
"""
import json
import sys

base = json.load(open(sys.argv[1]))
fix = json.load(open(sys.argv[2]))
READ = [("old (union)", base),
        ("new: climb", fix["cpu_window"]["readings"]["climb"]),
        ("new: climb+conf", fix["cpu_window"]["readings"]["climb+confirmation"])]
assert fix["cpu_window"]["primary"] == "climb" and fix["cpu_window"]["decided_by_prereg"] is False
assert fix["cpu_kernel"] == fix["cpu_window"]["readings"]["climb"]["cpu_kernel"]


def rows(block, group):
    return {r["kpps"]: r for r in block["cpu_kernel"]["rows"] if r["group"] == group}


def f(x, fmt="%.3f"):
    return "n/a" if x is None else fmt % x


print("## (1) FINDINGS 4 per-rung table -- old -> climb / climb+conf\n")
print("| kpps | coop S (samples/s) | delta coop | delta link | spread coop | spread link | resolved coop/link |")
print("|---|---|---|---|---|---|---|")
kpps_all = sorted(rows(base, "cooperative"))
for k in kpps_all:
    cells = []
    for key, fmt in (("samples_per_s", "%.1f"), ("delta_percent", "%.3f")):
        vals = [rows(b, "cooperative")[k][key] for _n, b in READ]
        cells.append(" / ".join(f(v, fmt) for v in vals))
    vals = [rows(b, "link")[k]["delta_percent"] for _n, b in READ]
    cells.append(" / ".join(f(v) for v in vals))
    for g in ("cooperative", "link"):
        vals = [rows(b, g)[k]["spread"] for _n, b in READ]
        cells.append(" / ".join(f(v) for v in vals))
    res = []
    for _n, b in READ:
        res.append("%s%s" % ("y" if rows(b, "cooperative")[k]["resolved"] else "N",
                             "y" if rows(b, "link")[k]["resolved"] else "N"))
    changed = any(len(set(c.split(" / "))) > 1 for c in cells)
    print("| %s | %s | %s |" % (("**%g**" if changed else "%g") % k, " | ".join(cells),
                                "/".join(res)))
print("\n(each cell: old / climb / climb+conf; bold kpps = a value moved)")

print("\n## (2) decomposition (PREREG 5.3), per treated group\n")
print("| group | reading | F (% of one core) | m (us/sample) | share F/(F+m*S_top) | verdict | H-C2 cond 1 | delta ratio | S ratio | S_top |")
print("|---|---|---|---|---|---|---|---|---|---|")
for g in ("cooperative", "link"):
    for name, b in READ:
        e = b["cpu_kernel"]["fits"][g]
        fit, h = e["fit"], e.get("H-C2") or {}
        print("| %s | %s | %.4f | %.2f | %.4f | %s | %s (share %.4f) | %.3f | %.3f | %.1f |"
              % (g, name, fit["fixed_percent"], fit["marginal_us_per_sample"], h.get("share"),
                 e["verdict"], h.get("condition_1"), h.get("share"), h.get("delta_ratio"),
                 h.get("s_ratio"), fit["max_samples_per_s"]))

print("\n## (3) registered bmv2 coop/none per rung, [0.90, 1.15]\n")
print("| kpps | " + " | ".join(n for n, _b in READ) + " |")
print("|---|---|---|---|")
by = [{r["kpps"]: r for r in b["cpu_bmv2_ratio"]["rows"]} for _n, b in READ]
for k in sorted(by[0]):
    vals = [by[i][k] for i in range(3)]
    changed = len({round(v["ratio"], 3) for v in vals}) > 1
    print("| %s | %s |" % (("**%g**" if changed else "%g") % k,
                           " | ".join("%.3f %s" % (v["ratio"], "in" if v["inside"] else "OUT")
                                      for v in vals)))
for i, (n, _b) in enumerate(READ):
    out = [("%g" % k) for k in sorted(by[i]) if by[i][k]["inside"] is False]
    print("\n%s: %d inside, %d outside (%s)" % (n, sum(1 for k in by[i] if by[i][k]["inside"]),
                                            len(out), ", ".join(out)))

print("\n## (4) reconciliation (b)\n")
print("| group | reading | m | fixed share | consistent | verdict |")
print("|---|---|---|---|---|---|")
recon = [base["reconciliation"], fix["cpu_window"]["readings"]["climb"]["reconciliation_b"],
         fix["cpu_window"]["readings"]["climb+confirmation"]["reconciliation_b"]]
for i, (n, _b) in enumerate(READ):
    for r in recon[i]:
        if r["id"] != "b":
            continue
        print("| %s | %s | %.2f | %.4f | %s | %s |" % (r["group"], n, r["marginal_us_per_sample"],
                                                     r["fixed_share"], r["consistent"], r["verdict"]))
fix_b = [r for r in fix["reconciliation"] if r["id"] == "b"]
assert fix_b == fix["cpu_window"]["readings"]["climb"]["reconciliation_b"]

print("\n## (5) per-group CPU cells that moved (fig3 panels; % of one core)\n")
print("| label | group | kpps | old | climb | climb+conf |")
print("|---|---|---|---|---|---|")
for label, key in (("kernel", "cpu_kernel"), ("bmv2", "cpu_bmv2"), ("proxy+emitter", "cpu_kernel")):
    for g in ("none", "cooperative", "link"):
        pg = [b[key]["per_group"][g] for _n, b in READ]
        for k in sorted(pg[0], key=float):
            field = "_proxy_plus_emitter" if label == "proxy+emitter" else "cpu"
            vals = [p[k][field] for p in pg]
            if max(vals) - min(vals) > 1e-9:
                print("| %s | %s | %s | %.3f | %.3f | %.3f |" % (label, g, k, *vals))
