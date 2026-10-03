"""P4 health check: which P4 features NDTwin carries, cell by cell.

[Co-developed with claude code -- Adam]

Design: doc/audit/2026-10-03_p4-health-check/DESIGN.md. This package is Cut 1 of it: the
program, the offline stage S0, the verdict functions, the reading layer behind one injected
Runner and one Config, and the lab lifecycle as far as it can be tested without a lab.

Python 3.8 compatible on purpose: tests/python runs under the ryu-env interpreter (3.8).
"""
