#!/usr/bin/env python3
"""Ryu's /v1.0/topology/* handlers must answer, and must answer with an EMPTY body when they fail.

[Co-developed with claude code -- Adam]

doc/KNOWN-ISSUES.md A-2, second uncovered item -- restated, because the entry names the wrong
file. `intelligent_router.py`'s get_link is already bounded (`_bounded_topo_read`, landed in
cce9c5db) AND it never served /v1.0/topology/* in the first place: those three endpoints come from
the stock `ryu.app.rest_topology`, loaded by name in tools/test_workflow/stack.sh. That is where
the unbounded read the kernel actually polls still lives.

WHAT THIS FILE TESTS, and what it does not
------------------------------------------
It drives the real `TopologyController` handlers out of `rest_topology.py` with every `ryu.*`
import replaced by a stub, so it runs on a plain interpreter with neither ryu nor eventlet
installed. What that faithfully reproduces is the control flow the patch changes:

  * eventlet's Timeout is thrown INTO the greenlet, so it surfaces as an exception propagating out
    of `fn()` inside the `with` block -- which is exactly what the stub read does.
  * eventlet's `Timeout.__exit__` suppresses nothing unless it was constructed with
    `exception=False` (eventlet/timeout.py:129-132), and the patch does not do that, so the
    `except hub.Timeout` really is what runs. The stub matches that rule rather than assuming it.
  * `Timeout` subclasses BaseException, so a bare `except Exception` would miss it. The stub
    subclasses BaseException too, so a patch that got this wrong would fail here.

What it does NOT test: that eventlet actually fires the timer after N seconds under a wedged
`ryu.topology.switches`. That needs a live control plane and is a live step, not a unit test.

RUNNING IT
----------
    # green (patched):
    /home/adam/miniconda3/bin/python3 A-2_test_ryu_rest_topology_bounded.py

    # red (stock, the tree as it is today):
    A2_REST_TOPOLOGY=/home/adam/miniconda3/envs/ryu-env/lib/python3.8/site-packages/ryu/app/rest_topology.py \
        /home/adam/miniconda3/bin/python3 A-2_test_ryu_rest_topology_bounded.py

By default it loads A-2_ryu_rest_topology_patched.py from this directory, which is the stock file
with A-2_ryu_rest_topology_bounded.patch applied.
"""

import importlib.util
import logging
import os
import pathlib
import sys
import types
import unittest

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_TARGET = HERE / "A-2_ryu_rest_topology_patched.py"


# --------------------------------------------------------------------------------------------
# The ryu stubs. Only what rest_topology.py imports, and no more: a stub rich enough to hide a
# behaviour difference would defeat the point of running this against both versions of the file.
# --------------------------------------------------------------------------------------------

class StubTimeout(BaseException):
    """Models eventlet.timeout.Timeout closely enough for the control flow under test.

    BaseException, not Exception -- the real one is, and a patch that caught `Exception` instead
    of `hub.Timeout` has to fail here rather than pass by accident. __exit__ mirrors
    eventlet/timeout.py:129-132: it suppresses only the instance it raised itself, and only when
    constructed with exception=False.
    """

    def __init__(self, seconds=None, exception=None):
        super().__init__(seconds)
        self.seconds = seconds
        self.exception = exception
        self.cancelled = False

    def cancel(self):
        self.cancelled = True

    def __enter__(self):
        return self

    def __exit__(self, typ, value, tb):
        self.cancel()
        if value is self and self.exception is False:
            return True
        return False


class StubResponse:
    """Records what the handler decided to send. `body` is the only field the kernel can see."""

    def __init__(self, status=200, body=b"", content_type=None, **kwargs):
        self.status = status
        self.body = body
        self.content_type = content_type


class StubControllerBase:
    def __init__(self, req, link, data, **config):
        self.req = req
        self.link = link
        self.data = data


def stub_route(*args, **kwargs):
    """`@route(...)` is a decorator factory; the wrapped function is what the tests call."""
    def decorate(fn):
        return fn
    return decorate


class StubRyuApp:
    def __init__(self, *args, **kwargs):
        pass


def install_ryu_stubs():
    """Puts the stub ryu packages into sys.modules so rest_topology.py can be imported."""
    def module(name, **attrs):
        mod = types.ModuleType(name)
        for key, value in attrs.items():
            setattr(mod, key, value)
        sys.modules[name] = mod
        return mod

    module("ryu")
    module("ryu.app")
    module("ryu.base")
    module("ryu.lib")
    module("ryu.topology")

    module("ryu.app.wsgi",
           ControllerBase=StubControllerBase,
           Response=StubResponse,
           route=stub_route,
           WSGIApplication=object)
    module("ryu.base.app_manager", RyuApp=StubRyuApp)
    module("ryu.lib.dpid", DPID_PATTERN=r"[0-9a-f]{16}", str_to_dpid=lambda s: int(s, 16))
    module("ryu.lib.hub", Timeout=StubTimeout)
    module("ryu.topology.api",
           get_switch=lambda app, dpid=None: [],
           get_link=lambda app, dpid=None: [],
           get_host=lambda app, dpid=None: [])


def load_target():
    """Imports the rest_topology.py under test by path, with the ryu stubs already installed."""
    path = pathlib.Path(os.environ.get("A2_REST_TOPOLOGY", str(DEFAULT_TARGET))).resolve()
    if not path.is_file():
        raise SystemExit(f"no such rest_topology.py: {path}")
    install_ryu_stubs()
    spec = importlib.util.spec_from_file_location("a2_rest_topology_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.__a2_path__ = str(path)
    return mod


REST = load_target()


class Wedged:
    """A topology read that never answers: the eventlet timer fires and throws into this greenlet.

    Records how many times it was called, so a handler that silently skipped the read entirely
    could not be mistaken for one that bounded it.
    """

    def __init__(self):
        self.calls = 0

    def __call__(self, app, dpid=None):
        self.calls += 1
        raise StubTimeout(getattr(REST, "TOPO_REST_TIMEOUT_S", 3.0))


class Answering:
    """A topology read that answers normally, with one object that knows how to serialise."""

    class Item:
        def __init__(self, payload):
            self.payload = payload

        def to_dict(self):
            return self.payload

    def __init__(self, payload):
        self.payload = payload

    def __call__(self, app, dpid=None):
        return [Answering.Item(self.payload)]


def controller():
    return REST.TopologyController(req=None, link=None, data={"topology_api_app": object()})


class BoundedTopologyRest(unittest.TestCase):
    def setUp(self):
        self.saved = {name: getattr(REST, name)
                      for name in ("get_switch", "get_link", "get_host")}

    def tearDown(self):
        for name, value in self.saved.items():
            setattr(REST, name, value)

    # --- the failure path: the whole point ---------------------------------------------------

    def test_a_blocked_link_read_answers_instead_of_propagating(self):
        wedged = Wedged()
        REST.get_link = wedged
        response = controller()._links(None)
        self.assertEqual(wedged.calls, 1, "the read must still be attempted, just not forever")
        self.assertIsInstance(response, StubResponse,
                              "a wedged topology app must produce an answer, not an exception")

    def test_the_answer_to_a_blocked_read_has_an_empty_body(self):
        # 🔴 The load-bearing assertion. utils::execCommand captures curl's stdout and throws the
        # exit status away, so the BODY is the entire channel to the kernel -- an error page here
        # would be classified as a successful round and fed to json::parse.
        REST.get_link = Wedged()
        response = controller()._links(None)
        self.assertEqual(response.body, b"",
                         "any body at all reads to the kernel as a round that answered")

    def test_the_answer_to_a_blocked_read_is_503(self):
        REST.get_link = Wedged()
        response = controller()._links(None)
        self.assertEqual(response.status, 503)

    def test_all_three_endpoints_are_bounded(self):
        # The wedge observed in the field took out all three at once; bounding only the one the
        # ticket happened to name would leave the same outage with two thirds of its surface.
        for name, handler in (("get_switch", "_switches"),
                              ("get_host", "_hosts"),
                              ("get_link", "_links")):
            with self.subTest(endpoint=name):
                setattr(REST, name, Wedged())
                response = getattr(controller(), handler)(None)
                self.assertEqual(response.status, 503, name)
                self.assertEqual(response.body, b"", name)

    def test_a_blocked_read_names_the_endpoint_in_the_log(self):
        # A wedge with no line in ryu.log cannot be told apart from a patch that never landed.
        REST.get_link = Wedged()
        with self.assertLogs(level=logging.WARNING) as captured:
            controller()._links(None)
        joined = "\n".join(captured.output)
        self.assertIn("links", joined, joined)

    def test_the_server_gives_up_before_the_kernel_does(self):
        # Cross-component constraint, and the reason for the specific number. The kernel's curl
        # carries --max-time 5 (TopologyAndFlowMonitor.hpp kTopologyRequestTimeoutSeconds). If the
        # server's ceiling were the larger of the two, the client would always abort first: the
        # warning above would never be written and the greenlet would never be released.
        self.assertLess(REST.TOPO_REST_TIMEOUT_S, 5.0,
                        "the side that gives up first is the side that gets to explain why")

    # --- the healthy path: a regression guard, NOT a discriminator ----------------------------
    # This one is green against the stock file too, and is here so that bounding the read cannot
    # be "achieved" by breaking the answer. It kills no mutation and is named as such in the A-2
    # findings.

    def test_a_healthy_read_still_returns_the_same_json(self):
        REST.get_link = Answering({"src": {"dpid": "0000000000000001"}})
        response = controller()._links(None)
        self.assertEqual(response.status, 200)
        self.assertEqual(response.content_type, "application/json")
        self.assertIn("0000000000000001", response.body)


if __name__ == "__main__":
    print(f"rest_topology.py under test: {REST.__a2_path__}", file=sys.stderr)
    unittest.main(verbosity=2)
