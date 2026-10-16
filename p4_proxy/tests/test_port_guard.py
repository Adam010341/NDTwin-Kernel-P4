"""
The proxy must not touch a switch when it cannot have the port.

[Co-developed with claude code -- Adam]

WHY THIS EXISTS. uvicorn runs the ASGI lifespan *before* it binds -- `server.py:103-104` awaits
`lifespan.startup()`, and the bind happens afterwards. This proxy's startup event is where it
opens gRPC channels, pushes pipeline config and installs forwarding rules. So a second instance
launched against a port that is already taken does all of that first, and only then discovers it
cannot serve. It then exits (the workers are daemon threads), leaving a fabric whose forwarding
state two processes have written to, and an operator whose `curl :8081` is answered by the other
one.

WHAT IS ASSERTED, AND WHY IT IS NOT THE EXIT CODE. A non-zero exit says the process gave up; it
says nothing about whether it wrote to a switch on the way. The load-bearing assertion is that
the startup event never ran at all -- `[Proxy Agent] Starting up...` is its first statement and
everything that reaches a switch is behind it. If that line is absent, nothing downstream of it
happened.

This is deliberately a subprocess test rather than a unit test of a guard function: the property
is about ordering between the guard and uvicorn's lifespan, and a unit test of the guard alone
would pass just as happily with the guard placed after `uvicorn.run()`, which is where it does
no good.
"""

from __future__ import annotations

import atexit
import errno
import os
import queue
import random
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

# The proxy this file starts inherits this process's environment, and so its table-entry journal
# directory: without this its startup writes a header for every switch into the checkout's
# .run/table_entry_journal (tests/journal_isolation.py). [Co-developed with claude code -- Adam]
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import journal_isolation  # noqa: E402,F401

# The default switch ports, read from the one file that states them (the proxy imports the same
# number the same way), so the test knows which ports it must keep clear of.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mininet"))
import grpc_ports  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY_DIR = os.path.join(HERE, "..")
MAIN = os.path.join(PROXY_DIR, "proxy_agent", "main.py")
VENV_PY = os.path.join(PROXY_DIR, "venv", "bin", "python")
PORT = 8081

STARTUP_MARKER = "[Proxy Agent] Starting up..."
STARTUP_DONE = "Application startup complete."
#: What proxy_agent/profile.py prints once it has chosen the package (profile.py:41).
BASELINE_LINE = "[Proxy Agent] app package: baseline"

#: Ports above the base the offline block holds: the switches (1-based dpids; ten on both
#: baseline models) take base+1.., and the kernel URL takes base+BLOCK_SIZE.
BLOCK_SIZE = 16

#: What the child's dial guard says when something asks grpc for a target outside the block.
REFUSAL = "OFFLINE-GUARD refused to dial"

#: The child's whole program, with @NAME@ placeholders filled by `offline_proxy`. It runs
#: main.py as `__main__`, so the port guard and the uvicorn start are the real ones, after:
#:  * importing grpc_ports AND app_package BEFORE the base moves. app_package reads
#:    grpc_ports.GRPC_PORT_BASE at import as BASELINE_GRPC_BASE and refuses a package whose
#:    grpc_base differs; moved first, it would refuse every converted package;
#:  * pointing the three knob files (app_package_override, telemetry_override, host_count_override)
#:    at paths that do not exist, so the baseline four-host fabric with default telemetry is what
#:    runs whatever `ndt up p4 ...` left in p4_proxy/mininet;
#:  * moving the switch base (main.py reads it at import: `from grpc_ports import ...`);
#:  * wrapping grpc.insecure_channel / secure_channel so a target outside the block is refused
#:    with REFUSAL instead of dialled -- a regression then cannot reach a live fabric.
_CHILD = """
import runpy, sys
sys.path.insert(0, @MININET@)
import grpc, grpc_ports, app_package, topo_from_json
app_package.KNOB_PATH = @KNOB@
app_package.TELEMETRY_KNOB_PATH = @TELEMETRY_KNOB@
topo_from_json.HOST_COUNT_OVERRIDE_PATH = @HOST_KNOB@
grpc_ports.GRPC_PORT_BASE = @BASE@

def _guard(real):
    def dial(target, *args, **kwargs):
        try:
            port = int(str(target).rsplit(":", 1)[-1])
        except ValueError:
            port = -1
        if not (@LO@ <= port <= @HI@):
            raise RuntimeError("@REFUSAL@ %s (the offline block is @LO@-@HI@)" % (target,))
        return real(target, *args, **kwargs)
    return dial

grpc.insecure_channel = _guard(grpc.insecure_channel)
grpc.secure_channel = _guard(grpc.secure_channel)
sys.argv = [@MAIN@]
runpy.run_path(@MAIN@, run_name="__main__")
"""

_TMP_DIRS = []


def _temp_dir(prefix):
    path = tempfile.mkdtemp(prefix=prefix)
    _TMP_DIRS.append(path)
    return path


atexit.register(lambda: [shutil.rmtree(d, True) for d in _TMP_DIRS])

#: Errors from a connect to ::1 that mean "nothing can be listening there" (no IPv6 in the
#: kernel, no ::1 address, no route), as opposed to "something is".
_NO_V6 = (errno.EAFNOSUPPORT, errno.EADDRNOTAVAIL, errno.ENETUNREACH)


def _nothing_listens(port: int) -> bool:
    """True when 127.0.0.1 and ::1 both refuse a connect on `port` (or ::1 does not exist)."""
    for family, addr in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        s = None
        try:
            s = socket.socket(family, socket.SOCK_STREAM)
            s.settimeout(0.3)
            err = s.connect_ex((addr, port))
        except OSError as exc:
            err = exc.errno
        finally:
            if s is not None:
                s.close()
        if err == errno.ECONNREFUSED:
            continue
        if family == socket.AF_INET6 and err in _NO_V6:
            continue
        return False
    return True


def free_block(size: int = BLOCK_SIZE) -> int:
    """
    The first port of `size + 1` consecutive ports on this machine that nothing listens on and
    that lie above the kernel's ephemeral range, so a short-lived outbound socket cannot be
    holding one either. Skips the test when there is no such block.

    [Co-developed with claude code -- Adam]
    """
    rng = grpc_ports.read_ephemeral_range()
    first = (rng[1] + 1) if rng else 61000
    last = 65535 - size
    if last <= first:
        raise unittest.SkipTest("no port above the ephemeral range to use as an offline block")
    starts = list(range(first, last))
    random.shuffle(starts)
    for base in starts[:200]:
        if all(_nothing_listens(p) for p in range(base, base + size + 1)):
            return base
    raise unittest.SkipTest("found no free port block above the ephemeral range")


def offline_proxy(*, python=None):
    """
    How to start the real proxy so that its switch dials, its kernel URL and its routing
    journal stay inside this test. Returns (argv, env, base).

    The child (`_CHILD`): runs the baseline fabric whatever knob files are on disk, dials
    the switches at base+1.. in a block checked to be free instead of localhost:30051-30060, and
    refuses any gRPC target outside the block. env: NDT_URL names base+BLOCK_SIZE (the kernel is
    otherwise localhost:8000), NDTWIN_RULE_JOURNAL_PATH is a file in a temp dir of its own, and
    NDTWIN_P4_BEACON_S=0.5 shortens the link watchdog's start-up grace from 30 s to 3 s so the
    first link-failure call to the kernel URL happens within the test's reach.

    Left alone, the child dials the switches where a running bmv2 fabric listens and pushes a
    pipeline and its own cookie onto them; the next real proxy start then sees every switch as
    unconfirmed and sets its table-entry journal aside.

    [Co-developed with claude code -- Adam]
    """
    base = free_block()
    knob_dir = _temp_dir("ndt-test-no-knob-")
    fill = {
        "MININET": repr(os.path.abspath(os.path.join(PROXY_DIR, "mininet"))),
        "KNOB": repr(os.path.join(knob_dir, "app_package_override")),
        "TELEMETRY_KNOB": repr(os.path.join(knob_dir, "telemetry_override")),
        "HOST_KNOB": repr(os.path.join(knob_dir, "host_count_override")),
        "BASE": str(base),
        "LO": str(base), "HI": str(base + BLOCK_SIZE),
        "MAIN": repr(os.path.abspath(MAIN)),
        "REFUSAL": REFUSAL,
    }
    code = _CHILD
    for key, value in fill.items():
        code = code.replace("@%s@" % key, value)
    argv = [python or _python(), "-c", code]
    env = dict(os.environ, PYTHONPATH=PROXY_DIR, PYTHONUNBUFFERED="1",
               NDT_URL="http://127.0.0.1:%d" % (base + BLOCK_SIZE),
               NDTWIN_P4_BEACON_S="0.5",
               NDTWIN_RULE_JOURNAL_PATH=os.path.join(_temp_dir("ndt-test-rule-journal-"),
                                                     "rule_journal.jsonl"))
    return argv, env, base


#: A dial target as the proxy's own output spells it: a switch as `localhost:30051`,
#: `ipv4:127.0.0.1:30051` or `ipv6:%5B::1%5D:30051` (grpc), the kernel as
#: `host='127.0.0.1', port=8000` (requests).
_TARGET = re.compile(r"(?:localhost|127\.0\.0\.1|\[::1\]|%5B::1%5D):(\d{2,5})\b"
                     r"|\bport=(\d{2,5})\b")

#: The p4info the baseline clients are built from. Without it `build_p4_client` fails before any
#: channel exists, so an unbuilt tree dials nothing and there is nothing for this test to observe.
P4INFO = os.path.join(PROXY_DIR, "p4_src", "build", "ndtwin_switch.p4info.txt")


def dialed_ports(output: str) -> set:
    """Every port the proxy's output names as a place it tried to reach."""
    return {int(a or b) for a, b in _TARGET.findall(output)}


def _python() -> str:
    # The venv interpreter, not whichever python is on PATH: base and venv share a binary but
    # not site-packages, and grpc/p4runtime only exist in the venv.
    return VENV_PY if os.path.exists(VENV_PY) else sys.executable


def run_proxy_until(argv, env, done, deadline_s=60):
    """
    Start the proxy, collect its output lines until `done(lines)` or the process ends or the
    deadline passes, then SIGTERM it. Returns the lines.
    """
    proc = subprocess.Popen(
        argv, cwd=PROXY_DIR, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    q = queue.Queue()

    def pump():
        for line in proc.stdout:
            q.put(line)
        q.put(None)

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    lines = []
    try:
        deadline = time.monotonic() + deadline_s
        while time.monotonic() < deadline and not done(lines):
            try:
                line = q.get(timeout=1)
            except queue.Empty:
                continue
            if line is None:
                break
            lines.append(line)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        reader.join(timeout=5)
        proc.stdout.close()
    return lines


class PortAlreadyTakenTest(unittest.TestCase):
    def setUp(self):
        self.blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.blocker.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            self.blocker.bind(("0.0.0.0", PORT))
        except OSError as exc:
            self.blocker.close()
            self.skipTest(f"cannot occupy :{PORT} for the test ({exc})")
        self.blocker.listen(8)

    def tearDown(self):
        self.blocker.close()

    def _run_proxy(self):
        # Offline even here: this test expects the process to stop before startup, but if the
        # guard regresses, "before startup" is exactly where it would start dialling switches.
        argv, env, _base = offline_proxy()
        return subprocess.run(
            argv, cwd=PROXY_DIR, env=env, capture_output=True, text=True, timeout=90,
        )

    def test_startup_event_never_runs_when_the_port_is_taken(self):
        # The assertion that matters: nothing that can reach a switch was executed. (A comment,
        # not a docstring: unittest prints a skipped test's reason on the docstring line, and the
        # L1 runner counts skips only on lines that start with the test's name.)
        proc = self._run_proxy()
        out = proc.stdout + proc.stderr
        self.assertNotIn(
            STARTUP_MARKER, out,
            "the startup event ran even though the port was unavailable -- everything that "
            "opens gRPC channels and installs forwarding rules is behind this line, so a "
            "second instance has already written to the fabric by the time it gives up",
        )

    def test_it_exits_non_zero_and_says_why(self):
        proc = self._run_proxy()
        out = proc.stdout + proc.stderr
        self.assertNotEqual(0, proc.returncode, "a proxy that cannot serve must not exit 0")
        self.assertRegex(
            out.lower(), r"8081.*(in use|unavailable|already)|already.*8081",
            "the refusal must name the port, so the operator is not left guessing",
        )


class PortFreeTest(unittest.TestCase):
    """
    The accept path. A guard that refuses everything would pass the test above perfectly.

    [Co-developed with claude code -- Adam]
    The second test says where the started proxy dialled. A real startup pushes a pipeline, and
    its own cookie, onto whatever answers at the switch ports, so the child is pointed at a
    free block (`offline_proxy`).
    """

    def setUp(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind(("0.0.0.0", PORT))
        except OSError:
            self.skipTest(f":{PORT} is occupied by something else; cannot test the free case")
        finally:
            s.close()

    def test_startup_event_does_run_when_the_port_is_free(self):
        argv, env, _base = offline_proxy()
        lines = run_proxy_until(argv, env, lambda ls: any(STARTUP_MARKER in l for l in ls))
        out = "".join(lines)
        self.assertTrue(
            any(STARTUP_MARKER in l for l in lines),
            "with the port free the proxy must still start normally; a guard that blocks "
            "the good case too is worse than no guard. The child's output ended:\n"
            + out[-2000:],
        )
        self.assertIn(BASELINE_LINE, out, "the child did not run the baseline package:\n"
                      + out[-2000:])

    @unittest.skipUnless(
        os.path.exists(P4INFO),
        "p4_src/build/ndtwin_switch.p4info.txt is not built: without it the proxy builds no "
        "switch client and dials nothing, so where it dials cannot be observed")
    def test_proxy_dials_only_the_offline_block(self):
        # What this checks, and no more: with the pipeline built, every switch port and kernel
        # port named in the proxy's output lies in the free block; the kernel's own port
        # (base+BLOCK_SIZE) is named by the first link-failure call, which proves NDT_URL
        # reached the notifier; and nothing was refused by the child's dial guard. The switch
        # ports the output names are the ones it tried; the guard is what stops a stray one.
        # (A comment, not a docstring: see test_startup_event_never_runs_when_the_port_is_taken.)
        argv, env, base = offline_proxy()
        block = set(range(base, base + BLOCK_SIZE + 1))

        def done(ls):
            return (any(STARTUP_DONE in l for l in ls)
                    and any("[Kernel] link failure" in l for l in ls))

        lines = run_proxy_until(argv, env, done, deadline_s=60)
        out = "".join(lines)
        self.assertTrue(any(STARTUP_DONE in l for l in lines),
                        "startup did not complete, so the dials were not seen:\n" + out[-2000:])
        self.assertIn(BASELINE_LINE, out, "the child did not run the baseline package:\n"
                      + out[-2000:])
        self.assertNotIn(REFUSAL, out, "the proxy asked grpc for a target outside the block")
        ports = dialed_ports(out)
        switch_ports = {p for p in ports if p != base + BLOCK_SIZE}
        self.assertTrue(switch_ports,
                        "the output names no switch address, so this test lost sight of the "
                        "dials:\n" + out[-2000:])
        default_block = set(range(grpc_ports.GRPC_PORT_BASE + 1,
                                  grpc_ports.GRPC_PORT_BASE + BLOCK_SIZE + 1))
        self.assertFalse(
            ports & default_block,
            "the proxy dialled the default switch ports %s, where a running bmv2 fabric "
            "listens" % sorted(ports & default_block))
        self.assertTrue(ports <= block,
                        "the proxy named ports outside the free block %d-%d: %s"
                        % (base, base + BLOCK_SIZE, sorted(ports - block)))
        kernel = [l for l in lines if "[Kernel] link failure" in l]
        self.assertTrue(kernel, "no link-failure call to the kernel URL was seen within the "
                                "deadline, so the kernel half is not proved. The child's "
                                "output ended:\n" + out[-2000:])
        m = re.search(r"port=(\d+)", kernel[0])
        self.assertIsNotNone(m, "the first link-failure line names no port: " + kernel[0])
        self.assertEqual(
            base + BLOCK_SIZE, int(m.group(1)),
            "the kernel call went to port %s, not the offline kernel URL's %d. The child's "
            "output ended:\n%s" % (m.group(1), base + BLOCK_SIZE, out[-2000:]))


class NothingListensTest(unittest.TestCase):
    """The probe that picks the block must not turn a missing IPv6 into a skip."""

    class Sock:
        def __init__(self, result):
            self.result = result

        def settimeout(self, _t):
            pass

        def connect_ex(self, _addr):
            return self.result

        def close(self):
            pass

    def _with(self, v4, v6):
        """v4/v6: an errno from connect_ex, or an OSError raised by socket() itself."""
        def factory(family, _type):
            outcome = v4 if family == socket.AF_INET else v6
            if isinstance(outcome, OSError):
                raise outcome
            return self.Sock(outcome)
        with mock.patch.object(socket, "socket", factory):
            return _nothing_listens(40000)

    def test_both_refused_is_free(self):
        self.assertTrue(self._with(errno.ECONNREFUSED, errno.ECONNREFUSED))

    def test_no_ipv6_support_is_free(self):
        self.assertTrue(self._with(errno.ECONNREFUSED, OSError(errno.EAFNOSUPPORT, "no ipv6")))

    def test_no_loopback_v6_address_or_route_is_free(self):
        for code in (errno.EADDRNOTAVAIL, errno.ENETUNREACH):
            with self.subTest(errno=code):
                self.assertTrue(self._with(errno.ECONNREFUSED, code))

    def test_a_listener_is_busy_on_either_family(self):
        self.assertFalse(self._with(0, errno.ECONNREFUSED))
        self.assertFalse(self._with(errno.ECONNREFUSED, 0))

    def test_an_unclear_answer_is_busy(self):
        self.assertFalse(self._with(errno.ETIMEDOUT, errno.ECONNREFUSED))
        self.assertFalse(self._with(errno.ECONNREFUSED, errno.ETIMEDOUT))


class DialedPortsTest(unittest.TestCase):
    def test_every_spelling_the_proxy_and_grpc_use(self):
        out = ("last error: UNKNOWN: ipv4:127.0.0.1:61152: Failed\n"
               "last error: UNKNOWN: ipv6:%5B::1%5D:61155: Failed\n"
               "channel to localhost:61153 closed\n"
               "last error: ipv6:[::1]:61156\n"
               "HTTPConnectionPool(host='127.0.0.1', port=61167): Max retries\n")
        self.assertEqual({61152, 61153, 61155, 61156, 61167}, dialed_ports(out))


if __name__ == "__main__":
    unittest.main(verbosity=2)
