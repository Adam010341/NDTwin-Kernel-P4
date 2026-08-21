"""
Tests for the never-answered-port LLDP backoff (`NDTWIN_RYU_LLDP_BACKOFF`).

[Co-developed with claude code -- Adam]

The patch replaces Ryu's `Switches.lldp_loop` with a copy whose one change is: a due port that
has never answered an LLDP gets its sweep clock advanced without a packet-out or guard-sleep,
except on every Nth tick. The claim that justifies the whole feature is that detection evidence
is untouched -- ports that HAVE answered are probed exactly as Ryu probes them. So the tests
here are about who gets transmitted to and when, not about link death (which stays
`link_loop`'s job, unpatched).

## Why the methods are extracted rather than imported

Same reason as test_route_install_gate.py: importing `intelligent_router` pulls in Ryu, which
lives in a separate conda env. The two patch functions are read out of the real file by AST and
executed against stubs, so an edit to them is an edit these tests see. Note both functions live
*inside* the `else:` arm of the flag check -- `ast.walk` finds nested FunctionDefs, so the
extraction does not care.
"""

from __future__ import annotations

import ast
import os
import unittest

ROUTER = os.path.join(os.path.dirname(__file__), "..", "..", "intelligent_router.py")
LOOP = "_lldp_loop_with_backoff"
MARKER = "_lldp_received_marking"


def extract(name):
    with open(ROUTER) as fh:
        tree = ast.parse(fh.read())
    func = next((n for n in ast.walk(tree)
                 if isinstance(n, ast.FunctionDef) and n.name == name), None)
    assert func is not None, f"{name} not found in {ROUTER} -- was it renamed?"
    return func


class PortData:
    def __init__(self, timestamp=None, answered=False):
        self.timestamp = timestamp
        if answered:
            # Set only when true: the production attribute is created lazily by the marker
            # patch, and the loop must tolerate its absence (it uses getattr). A port that
            # carries the attribute from birth would hide a loop that forgot the default.
            self.ever_received = True


class Ports(dict):
    """The slice of Ryu's PortDataState the loop touches: ordered items(), lldp_sent."""

    def __init__(self):
        super().__init__()
        self.order = []
        self.sent_clock_advances = []

    def add(self, key, data):
        self[key] = data
        self.order.append(key)

    def items(self):
        return [(k, self[k]) for k in self.order]

    def lldp_sent(self, port):
        self.sent_clock_advances.append(port)
        self[port].timestamp = 1000.0
        self.order.remove(port)
        self.order.append(port)
        return self[port]


class Controller:
    """Runs the loop for a fixed number of ticks, recording every transmission."""

    def __init__(self, ports, ticks):
        self.ports = ports
        self.is_active = True
        self.transmitted = []
        self.LLDP_SEND_PERIOD_PER_PORT = 0.9
        self.LLDP_SEND_GUARD = 0.05
        self._budget = ticks
        outer = self

        class Ev:
            def clear(self):
                pass

            def wait(self, timeout=None):
                outer._budget -= 1
                if outer._budget <= 0:
                    outer.is_active = False
                # Make every port due again for the next tick.
                for d in outer.ports.values():
                    if d.timestamp is not None:
                        d.timestamp = 0.0

        self.lldp_event = Ev()

    def send_lldp_packet(self, port):
        self.transmitted.append(port)
        self.ports[port].timestamp = 1000.0


def run_loop(ports, *, ticks, backoff_n):
    ns = {
        "time": lambda: 100.0,
        "hub": type("hub", (), {"sleep": staticmethod(lambda _s: None)})(),
        "_backoff_n": backoff_n,
    }
    exec(compile(ast.Module(body=[extract(LOOP)], type_ignores=[]), ROUTER, "exec"), ns)
    ctl = Controller(ports, ticks)
    ns[LOOP](ctl)
    return ctl


class LldpBackoffLoopTest(unittest.TestCase):
    def test_answered_ports_are_probed_every_tick(self):
        # The feature's justification: sw-sw ports keep Ryu's exact probe cadence.
        ports = Ports()
        ports.add("sw", PortData(timestamp=0.0, answered=True))
        ctl = run_loop(ports, ticks=6, backoff_n=10)
        self.assertEqual(ctl.transmitted, ["sw"] * 6,
                         "a port that has answered LLDP was not probed on every sweep")

    def test_never_answered_port_is_skipped_but_its_clock_advances(self):
        ports = Ports()
        ports.add("host", PortData(timestamp=0.0))
        ctl = run_loop(ports, ticks=6, backoff_n=10)
        self.assertEqual(ctl.transmitted, [],
                         "a never-answered port was transmitted to inside the backoff window")
        self.assertEqual(len(ports.sent_clock_advances), 6,
                         "skipping the transmit must still advance the port's sweep clock, or "
                         "the ordered expiry scan degrades")

    def test_nth_tick_transmits_to_never_answered_ports(self):
        # Discovery is delayed, not disabled: every Nth tick probes everything.
        ports = Ports()
        ports.add("host", PortData(timestamp=0.0))
        ctl = run_loop(ports, ticks=6, backoff_n=3)
        self.assertEqual(ctl.transmitted, ["host", "host"],
                         "expected transmissions on ticks 3 and 6 only (backoff_n=3, 6 ticks)")

    def test_new_ports_are_probed_immediately(self):
        # timestamp None is Ryu's "never sent yet" fast path; at boot every port is in it, so
        # backing it off would slow initial discovery of the whole fabric.
        ports = Ports()
        ports.add("new", PortData(timestamp=None))
        ctl = run_loop(ports, ticks=1, backoff_n=10)
        self.assertEqual(ctl.transmitted, ["new"],
                         "a brand-new port was not probed on its first sweep")


class LldpReceivedMarkerTest(unittest.TestCase):
    def test_marker_sets_the_bit_and_still_calls_ryu(self):
        calls = []
        ns = {"_ryu_lldp_received": lambda self, port: calls.append(port)}
        exec(compile(ast.Module(body=[extract(MARKER)], type_ignores=[]), ROUTER, "exec"), ns)

        state = {"p1": PortData(timestamp=0.0)}
        ns[MARKER](state, "p1")

        self.assertTrue(getattr(state["p1"], "ever_received", False),
                        "an answered port was not marked")
        self.assertEqual(calls, ["p1"],
                         "the marker must chain to Ryu's lldp_received, which resets the "
                         "drop counter link_loop reads")


if __name__ == "__main__":
    unittest.main()
