"""
The kernel's table_entry deadline is longer than the waits the proxy bounds on its table routes.

[Co-developed with claude code -- Adam]

The kernel relays POST and GET /ndt/p4/table_entry to the proxy and gives the relay
`kTwoRpcDeadlineSeconds` (include/ndt_core/http/P4Passthrough.hpp). If that deadline is not above
the waits the proxy bounds, a request the proxy would still answer (`503 switch busy`, or a write
that landed) comes back from the kernel as a 504 that says nothing about the switch. Those waits
are a GET's slot wait plus two reads (TABLE_READ_WORST_S) and a write's lock wait plus its write
(TABLE_ENTRY_LOCK_TIMEOUT_S + RPC_TIMEOUT_S). It is not a guarantee: a write's wait for a thread
in the proxy's shared pool is unbounded (up to about 5 s was measured, with forty table reads stuck
on one switch, when table reads still used that pool), and a GET's conversion and JSON encoding
after its reads are neither bounded nor measured. The kernel cannot import Python, so
this reads the C++ constant out of the header and compares.

unittest rather than pytest: tools/test_workflow/l1_unit_tests.sh executes each file directly.
"""

from __future__ import annotations

import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

from proxy_agent.api_routes import TABLE_ENTRY_LOCK_TIMEOUT_S, TABLE_READ_WORST_S  # noqa: E402
from proxy_agent.p4_client import RPC_TIMEOUT_S  # noqa: E402

P4_PASSTHROUGH_HPP = os.path.join(HERE, "..", "..", "include", "ndt_core", "http",
                                  "P4Passthrough.hpp")


def kernel_deadlines(text):
    """Every value the declaration `inline constexpr int kTwoRpcDeadlineSeconds = N;` gives, as
    ints. The pattern is anchored to the start of a line, so a declaration in a `//` comment, or
    one named in a comment, does not count."""
    return [int(v) for v in
            re.findall(r"^\s*inline\s+constexpr\s+int\s+kTwoRpcDeadlineSeconds\s*=\s*(\d+)\s*;",
                       text, re.M)]


class TheKernelDeadlineCoversTheProxysTableRoutesTest(unittest.TestCase):

    def setUp(self):
        with open(P4_PASSTHROUGH_HPP, encoding="utf-8") as fh:
            found = kernel_deadlines(fh.read())
        self.assertEqual(len(found), 1,
                         f"expected exactly one kTwoRpcDeadlineSeconds definition, found {found}")
        self.deadline = found[0]

    def test_a_table_read_fits(self):
        self.assertLess(TABLE_READ_WORST_S, self.deadline,
                        f"a GET can spend {TABLE_READ_WORST_S} s in the proxy; the kernel gives "
                        f"up at {self.deadline} s")

    def test_a_table_write_fits(self):
        write_worst = TABLE_ENTRY_LOCK_TIMEOUT_S + RPC_TIMEOUT_S
        self.assertLess(write_worst, self.deadline,
                        f"a POST can spend {write_worst} s in the proxy; the kernel gives up at "
                        f"{self.deadline} s")

    def test_the_reader_is_not_vacuous(self):
        # A regex that matched nothing would leave setUp failing for the right reason only by
        # luck of its message; pin what it finds and what it refuses.
        self.assertEqual(kernel_deadlines("inline constexpr int kTwoRpcDeadlineSeconds = 15;"),
                         [15])
        self.assertEqual(kernel_deadlines("// kTwoRpcDeadlineSeconds = 15 in the comment only"),
                         [])
        # A complete declaration that is commented out is not the definition.
        self.assertEqual(kernel_deadlines("// inline constexpr int kTwoRpcDeadlineSeconds = 99;"),
                         [])
        self.assertEqual(kernel_deadlines("  // inline constexpr int kTwoRpcDeadlineSeconds = 99;\n"
                                          "inline constexpr int kTwoRpcDeadlineSeconds = 15;\n"),
                         [15])
        # Not the declaration form: the brace initialiser is not read, so setUp fails loudly.
        self.assertEqual(kernel_deadlines("inline constexpr int kTwoRpcDeadlineSeconds{15};"), [])
        self.assertEqual(kernel_deadlines("no constant here"), [])


if __name__ == "__main__":
    unittest.main()
