"""P4 health check: which P4 features NDTwin carries, cell by cell.

[Co-developed with claude code -- Adam]

The design document is not part of the published tree. The
package holds the program, the offline stage S0, the verdict functions, the reading layer behind one injected
Runner and one Config, the lab lifecycle, bring-up A's observers (observe_a, round_a), bring-up B's
controller and attributions (controller_ext, attribution, round_b), and the lab run that orders them
(lab, `probe.py lab`). A cell whose `cut` in cells/table.py is 3 or more is observed by no round
yet, so a lab run judges it NOT RUN.

Python 3.8 compatible on purpose: tests/python runs under the ryu-env interpreter (3.8).
"""
