"""
Tests for the kernel northbound notifier.

[Co-developed with claude code -- Adam]

Runs a real HTTP server on a loopback port rather than mocking `requests`, because the things
most likely to be wrong are the URL, the method and the JSON field names -- exactly what a mock
would happily accept. The kernel rejects a link report that uses `src_port` instead of
`src_interface` (HttpSession.cpp checks for the latter), and a mock cannot tell us that.

The other property under test is that nothing raises. These run on the gRPC receive thread and
the LLDP discovery thread; an escaping exception kills that thread and silently takes the
feature with it.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from proxy_agent.kernel_notifier import KernelNotifier  # noqa: E402


class RecordingKernel(BaseHTTPRequestHandler):
    """Stands in for the kernel: records what arrived and replies with a configured status."""

    requests = []
    status = 200

    def _record(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            body = raw
        RecordingKernel.requests.append({"method": method, "path": self.path, "body": body})
        self.send_response(RecordingKernel.status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def do_GET(self):
        self._record("GET")

    def do_POST(self):
        self._record("POST")

    def log_message(self, *args):
        pass  # keep the test output readable


class NotifierTestBase(unittest.TestCase):
    def setUp(self):
        RecordingKernel.requests = []
        RecordingKernel.status = 200
        # Port 0 lets the OS pick a free one, so concurrent runs cannot collide.
        self.server = HTTPServer(("127.0.0.1", 0), RecordingKernel)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.shutdown)
        host, port = self.server.server_address
        self.notifier = KernelNotifier(base_url=f"http://{host}:{port}", timeout=2.0)

    @property
    def sent(self):
        return RecordingKernel.requests


class SwitchEnteredTest(NotifierTestBase):
    def test_uses_the_endpoint_that_sets_is_enabled(self):
        # This exact URL is the only thing that sets isEnabled on a vertex; a typo here leaves
        # the whole graph disabled with no other symptom.
        self.assertTrue(self.notifier.switch_entered(7))

        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.sent[0]["method"], "GET")
        self.assertEqual(self.sent[0]["path"], "/ndt/inform_switch_entered?dpid=7")

    def test_a_non_200_is_reported_as_failure(self):
        RecordingKernel.status = 404
        self.assertFalse(self.notifier.switch_entered(1))
        self.assertEqual(self.notifier.failures, 1)

    def test_each_switch_is_reported_separately(self):
        for dpid in range(1, 4):
            self.notifier.switch_entered(dpid)
        paths = [r["path"] for r in self.sent]
        self.assertEqual(paths, [f"/ndt/inform_switch_entered?dpid={d}" for d in (1, 2, 3)])


class LinkStateTest(NotifierTestBase):
    def test_link_failure_uses_the_field_names_the_kernel_requires(self):
        # HttpSession.cpp rejects the body unless all four of these are present, and it reads
        # src_interface/dst_interface -- not src_port/dst_port.
        self.assertTrue(self.notifier.link_failure(1, 2, 3, 4))

        self.assertEqual(self.sent[0]["method"], "POST")
        self.assertEqual(self.sent[0]["path"], "/ndt/link_failure_detected")
        self.assertEqual(self.sent[0]["body"], {
            "src_dpid": 1, "src_interface": 2, "dst_dpid": 3, "dst_interface": 4,
        })

    def test_link_recovery_hits_the_recovery_endpoint(self):
        self.assertTrue(self.notifier.link_recovery(5, 6, 7, 8))
        self.assertEqual(self.sent[0]["path"], "/ndt/link_recovery_detected")
        self.assertEqual(self.sent[0]["body"]["src_interface"], 6)

    def test_failure_and_recovery_are_different_endpoints(self):
        # Guards against a copy-paste that reports recovery on both paths, which would make a
        # broken link look permanently healthy.
        self.notifier.link_failure(1, 1, 2, 1)
        self.notifier.link_recovery(1, 1, 2, 1)
        self.assertNotEqual(self.sent[0]["path"], self.sent[1]["path"])


class NeverRaisesTest(unittest.TestCase):
    """
    A dead or missing kernel must produce False, not an exception.

    These run on background threads: the gRPC stream receiver and LLDP discovery. An exception
    escaping either kills that thread, so telemetry or discovery would stop with no error
    pointing at the cause.
    """

    def setUp(self):
        # Nothing listens here. Port 1 is privileged and closed, so connection is refused
        # immediately rather than hanging until the timeout.
        self.notifier = KernelNotifier(base_url="http://127.0.0.1:1", timeout=1.0)

    def test_switch_entered_returns_false_when_the_kernel_is_absent(self):
        self.assertFalse(self.notifier.switch_entered(1))

    def test_link_reports_return_false_when_the_kernel_is_absent(self):
        self.assertFalse(self.notifier.link_failure(1, 1, 2, 1))
        self.assertFalse(self.notifier.link_recovery(1, 1, 2, 1))

    def test_failures_are_counted(self):
        self.notifier.switch_entered(1)
        self.notifier.link_failure(1, 1, 2, 1)
        self.assertEqual(self.notifier.failures, 2)

    def test_an_unresolvable_host_also_does_not_raise(self):
        # A different exception family from a refused connection, and just as fatal to a thread.
        notifier = KernelNotifier(base_url="http://no-such-host.invalid", timeout=1.0)
        self.assertFalse(notifier.switch_entered(1))


class ConfigurationTest(unittest.TestCase):
    def test_honours_ndt_url_from_the_environment(self):
        # Same variable the test harness uses (components.env), so the two cannot disagree.
        old = os.environ.get("NDT_URL")
        os.environ["NDT_URL"] = "http://example.invalid:9999/"
        try:
            self.assertEqual(KernelNotifier().base_url, "http://example.invalid:9999")
        finally:
            if old is None:
                del os.environ["NDT_URL"]
            else:
                os.environ["NDT_URL"] = old

    def test_an_explicit_base_url_wins_over_the_environment(self):
        os.environ["NDT_URL"] = "http://from-env.invalid"
        try:
            self.assertEqual(KernelNotifier(base_url="http://explicit.invalid").base_url,
                             "http://explicit.invalid")
        finally:
            del os.environ["NDT_URL"]

    def test_a_trailing_slash_does_not_produce_a_double_slash(self):
        self.assertEqual(KernelNotifier(base_url="http://k:8000/").base_url, "http://k:8000")


class DestinationPathPushTest(NotifierTestBase):
    """
    [Co-developed with claude code -- Adam]
    The kernel reads `body.at("all_destination_paths")` and refuses the body outright if the key is
    absent -- and it does *not* require the `status` envelope the pull path insists on, so the two
    shapes genuinely differ. A key name only a mock would accept is the whole risk here.
    """

    PATHS = [[["10.0.0.1", 3], [1, 1], [5, 2], ["10.0.0.2", 0]]]

    def test_the_push_uses_the_key_the_kernel_reads(self):
        self.assertTrue(self.notifier.all_destination_paths(self.PATHS))

        self.assertEqual(self.sent[0]["method"], "POST")
        self.assertEqual(self.sent[0]["path"], "/ndt/inform_all_destination_paths")
        self.assertEqual(self.sent[0]["body"], {"all_destination_paths": self.PATHS})

    def test_host_endpoints_survive_as_strings_and_switches_as_numbers(self):
        # The kernel discriminates on the JSON type: a string goes through ipStringToUint32, a
        # number through get<uint64_t>(). json.dumps would happily turn 1 into "1".
        self.notifier.all_destination_paths(self.PATHS)
        path = self.sent[0]["body"]["all_destination_paths"][0]
        self.assertIsInstance(path[0][0], str)
        self.assertIsInstance(path[1][0], int)

    def test_an_empty_snapshot_is_not_sent_at_all(self):
        # setAllPaths returns early on an empty vector, deliberately -- before convergence "no paths"
        # is a transient. Sending one would produce an "ok" the kernel did not act on.
        self.assertFalse(self.notifier.all_destination_paths([]))
        self.assertEqual(self.sent, [])

    def test_a_non_200_is_reported_as_failure(self):
        RecordingKernel.status = 400
        self.assertFalse(self.notifier.all_destination_paths(self.PATHS))
        self.assertEqual(self.notifier.failures, 1)


class RenotifyUntilAcknowledgedTest(unittest.TestCase):
    """
    The bounded retry behind the startup push.

    [Co-developed with claude code -- Adam]
    Under stack.sh's ordering the kernel starts last, so the startup switch-entered push always
    fails and every dpid lands in this loop. Pure-function tests: `notify` and `sleep` are
    injected, so nothing here needs a kernel, a network, or wall-clock time.
    """

    def _import(self):
        from proxy_agent.kernel_notifier import renotify_until_acknowledged
        return renotify_until_acknowledged

    def test_acknowledged_dpids_leave_the_retry_set(self):
        renotify = self._import()
        acks = {1: [False, True], 2: [True]}  # per-dpid script of answers
        calls = []

        def notify(d):
            calls.append(d)
            return acks[d].pop(0)

        left = renotify(notify, [1, 2], attempts=5, interval_s=0, sleep=lambda s: None,
                        log=lambda m: None)
        self.assertEqual(left, [])
        # dpid 2 acknowledged in round one and must not be retried in round two.
        self.assertEqual(calls, [1, 2, 1])

    def test_gives_up_after_the_attempt_budget(self):
        renotify = self._import()
        logged = []
        left = renotify(lambda d: False, [7], attempts=3, interval_s=0,
                        sleep=lambda s: None, log=logged.append)
        self.assertEqual(left, [7])
        self.assertEqual(len(logged), 1)
        self.assertIn("never acknowledged", logged[0])

    def test_sleeps_before_every_round_not_after(self):
        renotify = self._import()
        # Event order, not sleep count: sleep-after-the-round also produces exactly one sleep
        # when round one acknowledges, so a counter cannot tell the two apart. The caller has
        # just finished a full startup attempt -- an immediate re-push would be pointless, so
        # the sleep must come first.
        events = []
        renotify(lambda d: events.append("notify") or True, [1], attempts=5, interval_s=10,
                 sleep=lambda s: events.append("sleep"), log=lambda m: None)
        self.assertEqual(events, ["sleep", "notify"])

    def test_nothing_to_do_means_no_sleeping_at_all(self):
        renotify = self._import()
        sleeps = []
        left = renotify(lambda d: True, [], attempts=5, interval_s=10,
                        sleep=sleeps.append, log=lambda m: None)
        self.assertEqual(left, [])
        self.assertEqual(sleeps, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
