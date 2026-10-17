"""
The proxy's HTTP API listens on loopback unless it is told otherwise.

[Co-developed with claude code -- Adam]

The API has no authentication, and a few of its routes change the fabric (`/p4/readopt/{dpid}`
re-pushes the pipeline, `/p4/table_entry` and `/stats/flowentry/*` write rules). It used to bind
0.0.0.0, so anything that could reach the machine could call them. The default is now 127.0.0.1,
and NDTWIN_PROXY_HOST is the one way to listen anywhere else.

These tests take the real `claim_listen_socket` and ask the socket it returns where it is bound,
on port 0 so they never touch :8081: that is the same call `python main.py` makes, so they fail
on a change that moves the default back (or ignores the variable) and not merely on a changed
constant.
"""

import contextlib
import io
import os
import re
import socket
import subprocess
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
# Before anything imports `main` (tests/journal_isolation.py).
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import journal_isolation  # noqa: E402,F401

import proxy_agent.main as main  # noqa: E402

ENV = "NDTWIN_PROXY_HOST"
PROXY_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
MAIN = os.path.join(PROXY_DIR, "proxy_agent", "main.py")


def have_ipv6_loopback():
    try:
        s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        s.bind(("::1", 0))
        s.close()
        return True
    except OSError:
        return False


def claim(env_value=None):
    """claim_listen_socket() with NDTWIN_PROXY_HOST set to env_value (or absent), port 0.
    Returns (bound host, bound family, stdout, stderr)."""
    with mock.patch.dict(os.environ):
        os.environ.pop(ENV, None)
        if env_value is not None:
            os.environ[ENV] = env_value
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            sock = main.claim_listen_socket(port=0)
        try:
            return sock.getsockname()[0], sock.family, out.getvalue(), err.getvalue()
        finally:
            sock.close()


def refused(env_value, host=None, port=0):
    """claim_listen_socket() expected to refuse. Returns (exit code, stderr)."""
    with mock.patch.dict(os.environ):
        os.environ.pop(ENV, None)
        if env_value is not None:
            os.environ[ENV] = env_value
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                sock = main.claim_listen_socket(host, port)
            except SystemExit as exc:
                return exc.code, err.getvalue()
        bound = sock.getsockname()
        sock.close()
        raise AssertionError("claim_listen_socket did not refuse %r; it bound %r"
                             % (env_value, bound))


class DefaultIsLoopback(unittest.TestCase):
    def test_the_default_socket_is_bound_to_127_0_0_1(self):
        host, _family, _out, _err = claim()
        self.assertEqual(
            "127.0.0.1", host,
            "with NDTWIN_PROXY_HOST unset the unauthenticated API must be reachable from this "
            "machine only")

    def test_an_empty_setting_is_the_default_not_all_interfaces(self):
        host, _f, _o, _e = claim("  ")
        self.assertEqual("127.0.0.1", host)

    def test_listen_host_reads_the_variable(self):
        self.assertEqual("127.0.0.1", main.listen_host({}))
        self.assertEqual("10.1.2.3", main.listen_host({ENV: " 10.1.2.3 "}))


class OptIn(unittest.TestCase):
    def test_a_named_address_is_honoured(self):
        # 127.0.0.2 is loopback on Linux, so this needs no real second interface; the old code
        # ignored the variable and bound 0.0.0.0, which this tells apart from 127.0.0.2.
        host, _f, _o, _e = claim("127.0.0.2")
        self.assertEqual("127.0.0.2", host)

    def test_all_interfaces_is_possible_and_warns(self):
        host, _f, out, err = claim("0.0.0.0")
        self.assertEqual("0.0.0.0", host)
        self.assertIn("WARNING", err)
        self.assertIn("no authentication", err)

    def test_ipv6_loopback_is_honoured(self):
        try:
            s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            s.bind(("::1", 0))
            s.close()
        except OSError:
            self.skipTest("no IPv6 loopback on this machine")
        host, family, _o, _e = claim("::1")
        self.assertEqual("::1", host)
        self.assertEqual(socket.AF_INET6, family)


class NoWarningOnLoopback(unittest.TestCase):
    def test_other_loopback_addresses_do_not_warn(self):
        for value in ("127.0.0.2", "::1", "::ffff:127.0.0.1"):
            with self.subTest(value=value):
                if ":" in value and not have_ipv6_loopback():
                    self.skipTest("no IPv6 loopback on this machine")
                try:
                    host, _f, _o, err = claim(value)
                except SystemExit:
                    self.skipTest("this machine cannot bind %s" % value)
                self.assertNotIn("WARNING", err)

    def test_is_loopback_reads_the_address_not_its_spelling(self):
        for value in ("127.0.0.1", "127.9.9.9", "::1", "::ffff:127.0.0.1"):
            self.assertTrue(main._is_loopback(value), value)
        for value in ("0.0.0.0", "::", "10.0.0.1", "192.168.1.5", "::ffff:10.0.0.1", "localhost"):
            self.assertFalse(main._is_loopback(value), value)


class BadValuesAreRefusedByName(unittest.TestCase):
    """A value that is not an address this machine can listen on must stop the proxy, name the
    variable and the value, and must not claim the port is taken."""

    def _assert_named_refusal(self, value):
        code, err = refused(value)
        self.assertNotEqual(0, code)
        self.assertIn(ENV, err)
        self.assertIn(repr(value), err)
        self.assertNotIn("already in use", err)

    def test_garbage(self):
        self._assert_named_refusal("not-an-address")

    def test_a_hostname_is_not_an_address(self):
        self._assert_named_refusal("localhost")

    def test_an_address_not_on_this_machine(self):
        # 192.0.2.0/24 is TEST-NET-1: never assigned to a real interface.
        self._assert_named_refusal("192.0.2.77")

    def test_only_a_taken_port_gets_the_already_running_text(self):
        blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            blocker.bind(("127.0.0.1", 0))
            blocker.listen(1)
            port = blocker.getsockname()[1]
            code, err = refused(None, port=port)
            self.assertNotEqual(0, code)
            self.assertIn("already in use", err)
            self.assertIn("Another proxy agent", err)
        finally:
            blocker.close()


class SecondProxyOnAnotherAddress(unittest.TestCase):
    """Binding one address does not conflict with a listener on another, so before a
    non-wildcard address is bound the proxy looks for a running agent on loopback."""

    def test_a_listener_on_127_0_0_1_stops_an_agent_asked_for_127_0_0_2(self):
        blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            blocker.bind(("127.0.0.1", 0))
            blocker.listen(1)
            port = blocker.getsockname()[1]
            code, err = refused("127.0.0.2", port=port)
            self.assertNotEqual(0, code)
            self.assertIn("already in use", err)
        finally:
            blocker.close()

    def test_a_listener_on_127_0_0_1_stops_an_agent_asked_for_ipv6_loopback(self):
        if not have_ipv6_loopback():
            self.skipTest("no IPv6 loopback on this machine")
        blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            blocker.bind(("127.0.0.1", 0))
            blocker.listen(1)
            port = blocker.getsockname()[1]
            code, err = refused("::1", port=port)
            self.assertNotEqual(0, code)
            self.assertIn("already in use", err)
        finally:
            blocker.close()

    def test_a_listener_on_ipv6_loopback_stops_an_agent_asked_for_127_0_0_2(self):
        if not have_ipv6_loopback():
            self.skipTest("no IPv6 loopback on this machine")
        blocker = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        try:
            blocker.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            blocker.bind(("::1", 0))
            blocker.listen(1)
            port = blocker.getsockname()[1]
            code, err = refused("127.0.0.2", port=port)
            self.assertNotEqual(0, code)
            self.assertIn("already in use", err)
        finally:
            blocker.close()

    def test_a_free_port_is_not_refused(self):
        host, _f, _o, _e = claim("127.0.0.2")
        self.assertEqual("127.0.0.2", host)

    def test_a_listener_on_the_requested_address_is_refused_by_the_bind(self):
        # The loopback probe cannot see 127.0.0.2, so this one is stopped by bind() itself:
        # the EADDRINUSE branch, which has to give the already-running text and not the
        # generic "cannot listen on" one.
        blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            blocker.bind(("127.0.0.2", 0))
            blocker.listen(1)
            port = blocker.getsockname()[1]
            code, err = refused("127.0.0.2", port=port)
            self.assertNotEqual(0, code)
            self.assertIn("already in use", err)
            self.assertIn("Another proxy agent", err)
            self.assertNotIn("cannot listen on", err)
        finally:
            blocker.close()


#: The child runs main.py as `__main__` (the production entry) with :8081 rewritten to a port
#: the parent found free -- in bind() AND in connect_ex(), the proxy's loopback probe, so nothing
#: here touches the real :8081 whatever is or is not listening on it -- and uvicorn.Server
#: replaced by a stub that reports the socket it was handed.
_CHILD = (
    "import runpy, sys, socket, uvicorn\n"
    "def _rewrite(addr):\n"
    "    if isinstance(addr, tuple) and len(addr) > 1 and addr[1] == 8081:\n"
    "        return (addr[0], %(port)d) + tuple(addr[2:])\n"
    "    return addr\n"
    "_bind, _connect_ex = socket.socket.bind, socket.socket.connect_ex\n"
    "socket.socket.bind = lambda self, addr: _bind(self, _rewrite(addr))\n"
    "socket.socket.connect_ex = lambda self, addr: _connect_ex(self, _rewrite(addr))\n"
    "class Stub:\n"
    "    def __init__(self, config): self.config = config\n"
    "    def run(self, sockets=None):\n"
    "        print('BOUND', sockets[0].getsockname()[0])\n"
    "        print('CONFIG', self.config.host, self.config.port == sockets[0].getsockname()[1])\n"
    "        sys.exit(0)\n"
    "uvicorn.Server = Stub\n"
    "sys.argv = [%(main)r]\n"
    "runpy.run_path(%(main)r, run_name='__main__')\n"
)


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
    finally:
        s.close()


class MainBlockBindsTheConfiguredAddress(unittest.TestCase):
    """The `if __name__ == '__main__'` block itself, not claim_listen_socket in isolation: a
    block that passed its own address (or 0.0.0.0) would survive every test above."""

    def _spawn(self, value, port):
        env = dict(os.environ, PYTHONPATH=PROXY_DIR, PYTHONUNBUFFERED="1")
        env.pop(ENV, None)
        if value is not None:
            env[ENV] = value
        return subprocess.run(
            [sys.executable, "-c", _CHILD % {"main": os.path.abspath(MAIN), "port": port}],
            cwd=PROXY_DIR, env=env, capture_output=True, text=True, timeout=120)

    def _run(self, value):
        proc = self._spawn(value, free_port())
        m = re.search(r"^BOUND (\S+)$", proc.stdout, re.M)
        self.assertTrue(m, "no BOUND line:\n" + proc.stdout[-1500:] + proc.stderr[-1500:])
        c = re.search(r"^CONFIG (\S+) (\S+)$", proc.stdout, re.M)
        return m.group(1), c.groups()

    def test_default(self):
        bound, (cfg_host, same_port) = self._run(None)
        self.assertEqual("127.0.0.1", bound)
        self.assertEqual(("127.0.0.1", "True"), (cfg_host, same_port))

    def test_configured(self):
        bound, (cfg_host, same_port) = self._run("127.0.0.2")
        self.assertEqual("127.0.0.2", bound)
        self.assertEqual(("127.0.0.2", "True"), (cfg_host, same_port))

    def test_a_taken_port_stops_the_entry_point(self):
        # Through the real entry point, with the port the child was redirected to taken.
        blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            blocker.bind(("127.0.0.1", 0))
            blocker.listen(1)
            proc = self._spawn(None, blocker.getsockname()[1])
        finally:
            blocker.close()
        self.assertNotEqual(0, proc.returncode)
        self.assertIn("already in use", proc.stderr)
        self.assertNotIn("BOUND", proc.stdout)


class StartupSaysWhere(unittest.TestCase):
    def test_an_ipv6_address_is_logged_in_brackets(self):
        if not have_ipv6_loopback():
            self.skipTest("no IPv6 loopback on this machine")
        _h, _f, out, _e = claim("::1")
        self.assertIn("HTTP API listening on [::1]:", out)

    def test_the_address_is_logged_and_loopback_does_not_warn(self):
        host, _f, out, err = claim()
        self.assertIn("HTTP API listening on 127.0.0.1:", out)
        self.assertNotIn("WARNING", err)


if __name__ == "__main__":
    unittest.main(verbosity=2)
