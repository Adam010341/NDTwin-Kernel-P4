"""
F-15: the bmv2 gRPC port block must not sit inside the kernel's ephemeral port range, and a
bring-up that lost a switch must not carry on as if it had not.

[Co-developed with claude code -- Adam]

The defect these tests stand against. `p4_proxy/mininet/p4_testbed_topo.py` assigned gRPC ports
`50050 + device_id`, i.e. 50051-50060, and `/proc/sys/net/ipv4/ip_local_port_range` on this
machine reads `32768 60999` with an empty `ip_local_reserved_ports`. Every one of the ten ports
was therefore inside the pool the kernel hands out to sockets that did not name their own port.
Any unrelated connection -- and bring-up makes many -- can hold 50052 at the instant bmv2 calls
bind(), and bmv2 then exits with EADDRINUSE. Observed 2026-08-18: 8 of 10 switches started, and
by the time anyone looked, both guilty ports were free again, which is why the diagnostic blamed
a leftover switch that had never existed.

Why the test reads /proc rather than hard-coding 32768. The range is a sysctl. Asserting
`GRPC_PORT_BASE < 32768` would pass on a machine whose range starts at 20000 while the fabric
failed on it all afternoon -- the test would be measuring the constant it was written from
instead of the machine it runs on. The block is checked against whatever the running kernel
says, so it goes red on the machine that is actually about to break.

The mirror test does the opposite: it feeds the checker a *fake* /proc whose range covers the
block, and requires a refusal. Without it, a checker that never refuses anything would pass the
first test forever.

Runs under any Python 3 with the standard library only -- no mininet, no grpc, no networkx.
Mininet is stubbed to reach partial_fabric_verdict, which touches none of it.

Run:  cd <repo> && python3 tests/python/test_grpc_port_block.py -v
"""

import importlib.util
import os
import re
import sys
import tempfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
MININET_DIR = os.path.join(REPO, "p4_proxy", "mininet")
sys.path.insert(0, MININET_DIR)

import grpc_ports as G  # noqa: E402

#: The fabric as it is actually built: p4_testbed_topo.py and ntg_bmv2_topo.py both iterate
#: range(1, 11). 128 is the host count, not a switch count -- it is included as the headroom
#: case, because a block that only just clears the range is one topology change from failing.
TEN_SWITCHES = range(1, 11)
ONE_TWENTY_EIGHT = range(1, 129)


def load_testbed_module():
    """
    p4_testbed_topo.py with mininet stubbed out. The stubs stand in for nothing under test:
    partial_fabric_verdict touches only os.environ and its arguments. Same technique, and the
    same reason, as p4_proxy/tests/test_readopt.load_testbed_module.
    """
    stubs = {
        "mininet": {},
        "mininet.net": {"Mininet": type("Mininet", (), {})},
        "mininet.topo": {"Topo": type("Topo", (), {})},
        "mininet.node": {"Switch": type("Switch", (), {}), "Host": type("Host", (), {})},
        "mininet.cli": {"CLI": type("CLI", (), {})},
        "mininet.log": {"setLogLevel": lambda *a, **k: None, "info": lambda *a, **k: None},
    }
    for name, attrs in stubs.items():
        if name not in sys.modules:
            mod = types.ModuleType(name)
            for attr, value in attrs.items():
                setattr(mod, attr, value)
            sys.modules[name] = mod
    path = os.path.join(MININET_DIR, "p4_testbed_topo.py")
    spec = importlib.util.spec_from_file_location("p4_testbed_topo_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_proc(tmpdir, name, text):
    path = os.path.join(tmpdir, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return path


# --- The block against this machine's real kernel ---------------------------------------

class TheBlockClearsThisMachinesEphemeralRange(unittest.TestCase):
    """Read the running kernel, not the number the constant was chosen against."""

    def test_the_range_file_is_readable(self):
        # If this fails, every other verdict here is uninformed rather than reassuring.
        self.assertIsNotNone(
            G.read_ephemeral_range(),
            f"cannot read {G.EPHEMERAL_RANGE_PATH}; the port block cannot be verified on "
            f"this machine, and 'not verified' is not 'safe'")

    def test_the_ten_switch_block_is_outside_the_range(self):
        rng = G.read_ephemeral_range()
        reserved = G.read_reserved_ports()
        ports = G.grpc_port_block(TEN_SWITCHES)
        at_risk = G.ports_at_risk(ports, rng, reserved)
        self.assertEqual(
            at_risk, [],
            f"gRPC ports {at_risk} are inside this kernel's ephemeral range {rng} and are "
            f"not reserved, so bmv2 will randomly fail to bind them (F-15)")

    def test_the_thrift_block_is_outside_the_range_too(self):
        # The control. The Thrift ports were never the problem -- same line of code, same
        # formula, a base below the range -- so a change that broke this would mean the
        # checker had started reporting risk where there is none.
        rng = G.read_ephemeral_range()
        ports = [G.thrift_port(d) for d in TEN_SWITCHES]
        self.assertEqual(G.ports_at_risk(ports, rng, G.read_reserved_ports()), [])

    def test_there_is_headroom_for_a_much_larger_fabric(self):
        rng = G.read_ephemeral_range()
        ports = G.grpc_port_block(ONE_TWENTY_EIGHT)
        self.assertEqual(
            G.ports_at_risk(ports, rng, G.read_reserved_ports()), [],
            "a 128-device fabric would reach into the ephemeral range; the base needs to "
            "move further down before the fabric grows")

    def test_the_whole_configured_block_passes_the_shipped_check(self):
        # The check the bring-up scripts actually call, on the real /proc paths.
        self.assertIsNone(G.check_port_block(G.grpc_port_block(TEN_SWITCHES)))


# --- The mirror: a kernel whose range DOES cover the block -------------------------------

class AnOverlappingRangeIsRefused(unittest.TestCase):
    """Feed the checker a fake /proc that overlaps, and require it to refuse."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ports = G.grpc_port_block(TEN_SWITCHES)
        lo, hi = min(self.ports) - 1000, max(self.ports) + 1000
        self.overlapping = write_proc(self.tmp.name, "range", f"{lo}\t{hi}\n")
        self.nothing_reserved = write_proc(self.tmp.name, "reserved", "\n")

    def test_ports_at_risk_names_every_port_in_the_range(self):
        at_risk = G.ports_at_risk(self.ports, G.read_ephemeral_range(self.overlapping))
        self.assertEqual(at_risk, sorted(self.ports))

    def test_check_port_block_reports_the_overlap(self):
        problem = G.check_port_block(self.ports, self.overlapping, self.nothing_reserved)
        self.assertIsNotNone(problem, "an overlapping range was reported as safe")
        self.assertIn("ephemeral port range", problem)
        self.assertIn(str(self.ports[0]), problem)

    def test_assert_raises_on_an_overlapping_range(self):
        with self.assertRaises(G.PortBlockError):
            G.assert_port_block_is_safe(self.ports, self.overlapping, self.nothing_reserved,
                                        env={})

    def test_a_block_half_inside_the_range_is_still_refused(self):
        # The partial case: a range whose floor cuts through the middle of the block. A
        # checker written with `min(ports) < low` would pass this.
        cut = write_proc(self.tmp.name, "cut", f"{self.ports[5]}\t{max(self.ports) + 500}\n")
        at_risk = G.ports_at_risk(self.ports, G.read_ephemeral_range(cut))
        self.assertEqual(at_risk, self.ports[5:])
        with self.assertRaises(G.PortBlockError):
            G.assert_port_block_is_safe(self.ports, cut, self.nothing_reserved, env={})


class ReservingTheBlockMakesAnOverlapSafe(unittest.TestCase):
    """Option (b): a block inside the range but listed in ip_local_reserved_ports."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ports = G.grpc_port_block(TEN_SWITCHES)
        self.overlapping = write_proc(
            self.tmp.name, "range",
            f"{min(self.ports) - 1000}\t{max(self.ports) + 1000}\n")

    def test_a_reserved_range_clears_the_check(self):
        reserved = write_proc(self.tmp.name, "reserved",
                              f"{min(self.ports)}-{max(self.ports)}\n")
        self.assertIsNone(G.check_port_block(self.ports, self.overlapping, reserved))

    def test_a_comma_separated_list_is_parsed_too(self):
        reserved = write_proc(self.tmp.name, "reserved",
                              ",".join(str(p) for p in self.ports) + "\n")
        self.assertIsNone(G.check_port_block(self.ports, self.overlapping, reserved))

    def test_reserving_only_part_of_the_block_still_refuses(self):
        # The sysctl applied to nine of ten ports is the shape a hand-typed range produces,
        # and the tenth switch is exactly as broken as before.
        reserved = write_proc(self.tmp.name, "reserved",
                              f"{min(self.ports)}-{max(self.ports) - 1}\n")
        problem = G.check_port_block(self.ports, self.overlapping, reserved)
        self.assertIsNotNone(problem)
        self.assertIn(str(max(self.ports)), problem)


class AnUnreadableRangeIsNotTreatedAsSafe(unittest.TestCase):
    """Unknown must not be conflated with safe -- the repo's most-repeated review finding."""

    def test_a_missing_file_reads_as_None(self):
        self.assertIsNone(G.read_ephemeral_range("/nonexistent/ndtwin/port_range"))

    def test_a_malformed_file_reads_as_None(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_proc(tmp, "range", "not a range\n")
            self.assertIsNone(G.read_ephemeral_range(path))

    def test_an_unreadable_range_is_refused(self):
        with self.assertRaises(G.PortBlockError):
            G.assert_port_block_is_safe(G.grpc_port_block(TEN_SWITCHES),
                                        "/nonexistent/ndtwin/port_range",
                                        "/nonexistent/ndtwin/reserved", env={})

    def test_a_missing_reserved_file_reserves_nothing(self):
        self.assertEqual(G.read_reserved_ports("/nonexistent/ndtwin/reserved"), set())


class TheOverrideIsADecisionNotADefault(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ports = G.grpc_port_block(TEN_SWITCHES)
        self.overlapping = write_proc(
            self.tmp.name, "range",
            f"{min(self.ports) - 1000}\t{max(self.ports) + 1000}\n")
        self.reserved = write_proc(self.tmp.name, "reserved", "\n")

    def test_the_override_downgrades_the_refusal_to_a_returned_warning(self):
        warning = G.assert_port_block_is_safe(self.ports, self.overlapping, self.reserved,
                                              env={G.OVERRIDE_ENV: "1"})
        self.assertIsNotNone(warning)
        self.assertIn("WARNING", warning)

    def test_any_other_value_does_not_open_the_hatch(self):
        for value in ("0", "true", "yes", ""):
            with self.subTest(value=value):
                with self.assertRaises(G.PortBlockError):
                    G.assert_port_block_is_safe(self.ports, self.overlapping, self.reserved,
                                                env={G.OVERRIDE_ENV: value})

    def test_a_safe_block_returns_no_warning_even_with_the_override_set(self):
        self.assertIsNone(
            G.assert_port_block_is_safe(G.grpc_port_block(TEN_SWITCHES),
                                        env={G.OVERRIDE_ENV: "1"}))


# --- Bring-up must fail loudly on a partial fabric ---------------------------------------

class BringUpRefusesAPartialFabric(unittest.TestCase):
    """
    The second half of F-15. Both bring-up scripts detected the missing switches and then
    continued anyway -- p4_testbed_topo into the Mininet CLI, ntg_bmv2_topo into a traffic
    generator -- printing a warning and exiting 0. A wrapper could not tell 8 switches from 10.
    """

    @classmethod
    def setUpClass(cls):
        cls.T = load_testbed_module()

    def test_a_complete_fabric_is_not_fatal_and_says_nothing(self):
        fatal, report = self.T.partial_fabric_verdict([], 10, env={})
        self.assertFalse(fatal)
        self.assertIsNone(report)

    def test_one_missing_switch_is_fatal(self):
        fatal, report = self.T.partial_fabric_verdict(
            [("s2", "process exited; gRPC port 30052 was already in use")], 10, env={})
        self.assertTrue(fatal, "a fabric missing a switch was not treated as a failure")
        self.assertIn("s2", report)
        self.assertIn("1 of 10", report)

    def test_the_report_carries_each_failure_reason(self):
        failures = [("s2", "bind failed"), ("s6", "process alive but gRPC not listening")]
        _, report = self.T.partial_fabric_verdict(failures, 10, env={})
        self.assertIn("bind failed", report)
        self.assertIn("process alive but gRPC not listening", report)
        self.assertIn("8/10", report)

    def test_the_escape_hatch_keeps_a_partial_fabric_but_still_reports(self):
        fatal, report = self.T.partial_fabric_verdict(
            [("s2", "bind failed")], 10,
            env={self.T.ALLOW_PARTIAL_ENV: "1"})
        self.assertFalse(fatal)
        self.assertIn("WARNING", report)
        self.assertIn("s2", report)

    def test_any_other_value_of_the_hatch_is_still_fatal(self):
        fatal, _ = self.T.partial_fabric_verdict(
            [("s2", "bind failed")], 10, env={self.T.ALLOW_PARTIAL_ENV: "0"})
        self.assertTrue(fatal)


class TheFabricAndTheProxyAgreeOnThePortBlock(unittest.TestCase):
    """
    One number, one place. The fabric assigns the ports and the proxy dials them; they used to
    be two independent literals (`50050 + i` and `DEFAULT_GRPC_PORT_BASE = 50050`), which is
    this repo's most-repeated bug shape -- change one, ship the other.

    proxy_agent/main.py cannot be imported here (fastapi, grpc, uvicorn), so the check is
    textual: it must take the base from grpc_ports rather than restate it.
    """

    def setUp(self):
        with open(os.path.join(REPO, "p4_proxy", "proxy_agent", "main.py"),
                  encoding="utf-8") as fh:
            self.source = fh.read()

    def test_the_proxy_imports_the_base_instead_of_restating_it(self):
        self.assertIn("from grpc_ports import GRPC_PORT_BASE", self.source)
        self.assertIn("DEFAULT_GRPC_PORT_BASE = GRPC_PORT_BASE", self.source)

    def test_the_proxy_carries_no_literal_port_base(self):
        # Statements only, anchored to the start of a line. Substring matching fails here for a
        # reason worth keeping: the comment above the import quotes the old assignment to say
        # what it replaced, so a naive `assertNotIn` reports the explanation as the defect.
        literal = re.search(r"^DEFAULT_GRPC_PORT_BASE\s*=\s*\d+", self.source, re.M)
        self.assertIsNone(
            literal,
            f"the proxy has its own copy of the port base again: "
            f"{literal.group(0) if literal else ''}")

    def test_the_topology_takes_its_ports_from_the_module(self):
        with open(os.path.join(MININET_DIR, "p4_testbed_topo.py"), encoding="utf-8") as fh:
            source = fh.read()
        self.assertIn("grpc_ports.grpc_port(i)", source)
        self.assertNotIn("grpc_port=50050+i", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
