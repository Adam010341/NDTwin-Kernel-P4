"""health.json, 00_table.tsv and the terminal table (design 4.3), with the three rollups.

[Co-developed with claude code -- Adam]
"""
from __future__ import annotations

import json

from .cells import verdict as V


def table_rows(table, ctx, annotated):
    rows = []
    for c in table.cells:
        v = ctx.cells.get(c.id)
        if v is None:
            continue
        exp, d = annotated.get(c.id, (None, "unpredicted"))
        attr = v.attribution or {}
        attribution = "+".join(attr.get("kind") or []) + ("" if attr.get("ok", True) else " (not established)")
        if c.alias_of:
            # (r3) an alias row says whose verdict it is: VB1's varbit verdict is CH3's
            attribution = "ALIAS of %s%s" % (c.alias_of, ("; " + attribution) if attribution else "")
        rows.append([c.dimension, c.id, c.scope, v.label, attribution, exp or "-", d, v.reason])
    for ctl in table.controls:
        v = ctx.cells.get(ctl.id)
        if v is not None:
            exp, d = annotated.get(ctl.id, (None, "unpredicted"))
            rows.append(["control", ctl.id, "-", v.label, "-", exp or "-", d, v.reason])
    return rows


HEADER = ["dimension", "cell", "scope", "verdict", "attribution", "expected", "delta", "reason"]


def tsv(rows):
    return "\t".join(HEADER) + "\n" + "".join("\t".join(str(x).replace("\t", " ") for x in r) + "\n"
                                              for r in rows)


def render(rows, rollups):
    widths = [max(len(str(r[i])) for r in rows + [HEADER]) for i in range(len(HEADER) - 1)]
    lines = ["  ".join(str(h).ljust(w) for h, w in zip(HEADER, widths)) + "  reason"]
    for r in rows:
        lines.append("  ".join(str(x).ljust(w) for x, w in zip(r, widths)) + "  " + str(r[-1]))
    for scope in V.SCOPES:
        t = rollups[scope]["totals"]
        lines.append("rollup %-4s  can %d  partial %d  cannot %d  undecided %d  (of %d dimensions)"
                     % (scope, t[V.CAN], t[V.PART], t[V.CANNOT], t[V.UNDECIDED],
                        len(rollups[scope]["dimensions"])))
        for dim, via in sorted((rollups[scope].get("alias_only") or {}).items()):
            lines.append("  %s rests only on an alias: %s" % (dim, ", ".join(via)))
    return "\n".join(lines)


def health(run_id, probe_version, lab_surface, s0, bringups, table, ctx, annotated, rollups,
           verdict):
    return {
        "run": run_id, "probe_version": probe_version, "lab_surface": lab_surface,
        "s0": s0, "bringups": bringups,
        "self_checks": {k: v.as_dict() for k, v in ctx.self_checks.items()},
        "cells": [dict(ctx.cells[c.id].as_dict(), id=c.id, dimension=c.dimension, scope=c.scope,
                       expected_today=annotated.get(c.id, (None,))[0],
                       delta=annotated.get(c.id, (None, "unpredicted"))[1])
                  for c in table.cells if c.id in ctx.cells],
        "controls": [dict(ctx.cells[c.id].as_dict(), id=c.id, of=c.of,
                          expected_today=annotated.get(c.id, (None,))[0],
                          delta=annotated.get(c.id, (None, "unpredicted"))[1])
                     for c in table.controls if c.id in ctx.cells],
        "rollup": rollups, "verdict": verdict,
        "aliases": {c.id: c.alias_of for c in table.cells if c.alias_of},
    }


def dump(path, doc):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2, sort_keys=True, default=sorted)
        fh.write("\n")
