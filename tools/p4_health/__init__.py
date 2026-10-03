"""P4 health check: which P4 features NDTwin carries, cell by cell.

[Co-developed with claude code -- Adam]

The design lives with the project's audit records (not part of the published tree). This
package is its Cut 1: the program, the offline stage S0, the verdict functions, the reading layer behind one injected
Runner and one Config, and the lab lifecycle as far as it can be tested without a lab.

Python 3.8 compatible on purpose: tests/python runs under the ryu-env interpreter (3.8).
"""
