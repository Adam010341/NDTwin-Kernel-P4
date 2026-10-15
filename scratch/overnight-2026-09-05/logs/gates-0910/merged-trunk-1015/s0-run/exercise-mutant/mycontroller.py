#!/usr/bin/env python3
"""Stand-in for bring-up B's controller (tools/p4_health/controller_ext.py, Cut 2).

[Co-developed with claude code -- Adam]

convert.py --mode external requires an exercise to carry a mycontroller.py (convert.py:516-521),
so the exercise carries this. It refuses to run: bring-up B runs tools/p4_health/controller_ext.py
by name through run_external_controller.py (round_b.py), and a stand-in that connected to a fabric
would be a second controller nobody asked for.
"""
import sys

if __name__ == "__main__":
    sys.stderr.write("p4_health: bring-up B runs controller_ext.py, not this stand-in\n")
    sys.exit(2)
