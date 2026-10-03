#!/usr/bin/env python3
"""Stand-in for bring-up B's controller (tools/p4_health/controller_ext.py, Cut 2).

[Co-developed with claude code -- Adam]

convert.py --mode external requires an exercise to carry a mycontroller.py (convert.py:516-521),
so the exercise carries this. It refuses to run: B's controller and its eleven attributions are
Cut 2's work, and a stand-in that connected to a fabric would be a controller nobody reviewed.
"""
import sys

if __name__ == "__main__":
    sys.stderr.write("p4_health: bring-up B's controller is not built yet (Cut 2)\n")
    sys.exit(2)
