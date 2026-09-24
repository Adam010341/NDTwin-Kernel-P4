#!/usr/bin/env python3
"""Is `if headroom <= 0` in plot.place_end_labels an equivalent mutation away from zero?

[Co-developed with claude code -- Adam]

The claim (ruling 39: the judge's argument, repeated in plot.py's comment): below zero the
unguarded bound (y-low)*H/headroom is negative and loses every max, so `<= 0`, `< 0` and no
guard at all return the same thing; only AT zero do they differ, where the unguarded forms divide
by zero. A mechanism nobody ran is the shape of error ruling 39(0b) records, so this runs it:
three copies of place_end_labels, compiled from plot.py's own source with the guard as written,
as `< 0`, and removed, over the real panels, a stack with negative headroom, and the exact-zero
case.

Usage:  tests/postcheck_guard_equivalence.py
Exit:   0 the claim holds as stated, 1 it does not.
"""
import os
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import plot                                         # noqa: E402
from test_plot import Figure3LabelsStayInsideTest   # noqa: E402

GUARD = "            if headroom <= 0:"


def variant(replacement):
    with open(plot.__file__) as fh:
        source = fh.read()
    assert source.count(GUARD) == 1, "the guard's text is not where this check expects it"
    module = types.ModuleType("plot_variant")
    exec(compile(source.replace(GUARD, replacement), plot.__file__, "exec"), module.__dict__)
    return module


def outcome(module, ends, ylim, height):
    try:
        return module.place_end_labels(ends, ylim, height)
    except ZeroDivisionError as error:
        return "ZeroDivisionError: %s" % error


def main():
    variants = {"as written (<= 0)": variant(GUARD),
                "< 0": variant("            if headroom < 0:"),
                "no guard": variant("            if False:")}
    case = Figure3LabelsStayInsideTest()
    cases = [("real panel %s (headroom > 0)" % name, ends, case.autoscaled(low, ends), 206.5)
             for name, (low, ends, _measured) in case.PANELS.items()]
    # how many of the twenty have negative headroom is COUNTED, with the function's own formula
    negative = sum(1 for i in range(20)
                   if 50.0 - (19 - i) * plot.LABEL_HEIGHT_PT - plot.LABEL_HEIGHT_PT / 2.0 < 0)
    cases.append(("20 labels in 50 pt (headroom < 0 for %d of them)" % negative,
                  [(float(i), 110.0, "s%d" % i) for i in range(20)], (0.0, 19.0), 50.0))
    cases.append(("3 labels in 27.5 pt, the lowest at the bottom (headroom == 0)",
                  [(0.0, 110.0, "a"), (1.0, 110.0, "b"), (3.0, 110.0, "c")], (0.0, 3.0), 27.5))
    holds = True
    for name, ends, ylim, height in cases:
        results = {label: outcome(module, ends, ylim, height) for label, module in variants.items()}
        reference = results["as written (<= 0)"]
        same = {label: result == reference for label, result in results.items()}
        exact_zero = "headroom == 0" in name
        print("%s" % name)
        for label, result in results.items():
            shown = result if isinstance(result, str) else "ylim=(%.6g, %.6g), top label at %.4f pt" % (
                result[0][0], result[0][1], result[1][-1]["display_points"])
            print("    %-18s %-8s %s" % (label, "same" if same[label] else "DIFFERS", shown))
        expected = (not all(same.values())) if exact_zero else all(same.values())
        holds &= expected
    print("\nTHE GUARD IS EQUIVALENT AWAY FROM ZERO AND NOT AT ZERO: %s" % holds)
    return 0 if holds else 1


if __name__ == "__main__":
    sys.exit(main())
