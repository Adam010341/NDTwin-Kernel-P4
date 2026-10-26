"""
The kernel's copy of the 5-tuple field list is the proxy's.

[Co-developed with claude code -- Adam]

KNOWN-ISSUES C-7. The kernel now refuses, before queueing, a strict delete the proxy is known to
refuse: a named priority on a match that compiles to ipv4_lpm. Whether a match compiles there is
the proxy's `needs_five_tuple`, which reads FIVE_TUPLE_ONLY_FIELDS -- and the kernel cannot import
Python, so it carries `kP4FiveTupleOnlyMatchFields` in FlowJob.hpp. If the proxy learns a new
spelling and the kernel does not, the kernel refuses a delete the proxy would honour (a delete
lost); the other way round, the 200 "queued" for a doomed delete comes back. This reads the C++
array out of the header and compares the sets, so either drift fails here.

unittest rather than pytest: tools/test_workflow/l1_unit_tests.sh executes each file directly.
"""

from __future__ import annotations

import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

from proxy_agent.topology_manager import FIVE_TUPLE_ONLY_FIELDS  # noqa: E402

FLOW_JOB_HPP = os.path.join(HERE, "..", "..", "include", "ndt_core", "routing_management",
                            "FlowJob.hpp")


def kernel_fields(text):
    """The string literals of kP4FiveTupleOnlyMatchFields' initialiser, or None if not found."""
    found = re.search(r"kP4FiveTupleOnlyMatchFields\[\]\s*=\s*\{(.*?)\};", text, re.S)
    if found is None:
        return None
    return re.findall(r'"([^"]+)"', found.group(1))


class TheKernelMirrorsTheProxysFiveTupleFieldsTest(unittest.TestCase):

    def test_the_two_sets_are_equal(self):
        with open(FLOW_JOB_HPP, encoding="utf-8") as fh:
            fields = kernel_fields(fh.read())
        self.assertIsNotNone(fields, "kP4FiveTupleOnlyMatchFields not found in FlowJob.hpp")
        self.assertEqual(len(fields), len(set(fields)), f"duplicate spelling in {fields}")
        self.assertEqual(set(fields), set(FIVE_TUPLE_ONLY_FIELDS))

    def test_the_reader_is_not_vacuous(self):
        # A regex that matched nothing would make the comparison above compare two empty sets
        # the day the proxy's list became empty too. Pin that it finds a known array.
        self.assertEqual(kernel_fields('x kP4FiveTupleOnlyMatchFields[] = {"a", "b"};'),
                         ["a", "b"])
        self.assertIsNone(kernel_fields("no array here"))
        self.assertTrue(FIVE_TUPLE_ONLY_FIELDS, "the proxy's set is empty")


if __name__ == "__main__":
    unittest.main()
