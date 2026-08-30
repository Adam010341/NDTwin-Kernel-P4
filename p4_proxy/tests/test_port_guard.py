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

import os
import socket
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PROXY_DIR = os.path.join(HERE, "..")
MAIN = os.path.join(PROXY_DIR, "proxy_agent", "main.py")
VENV_PY = os.path.join(PROXY_DIR, "venv", "bin", "python")
PORT = 8081

STARTUP_MARKER = "[Proxy Agent] Starting up..."


def _python() -> str:
    # The venv interpreter, not whichever python is on PATH: base and venv share a binary but
    # not site-packages, and grpc/p4runtime only exist in the venv.
    return VENV_PY if os.path.exists(VENV_PY) else sys.executable


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
        env = dict(os.environ, PYTHONPATH=PROXY_DIR, PYTHONUNBUFFERED="1")
        return subprocess.run(
            [_python(), MAIN],
            cwd=PROXY_DIR, env=env, capture_output=True, text=True, timeout=90,
        )

    def test_startup_event_never_runs_when_the_port_is_taken(self):
        """The assertion that matters: nothing that can reach a switch was executed."""
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
    """The accept path. A guard that refuses everything would pass the test above perfectly."""

    def test_startup_event_does_run_when_the_port_is_free(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind(("0.0.0.0", PORT))
        except OSError:
            self.skipTest(f":{PORT} is occupied by something else; cannot test the free case")
        finally:
            s.close()

        env = dict(os.environ, PYTHONPATH=PROXY_DIR, PYTHONUNBUFFERED="1")
        proc = subprocess.Popen(
            [_python(), MAIN],
            cwd=PROXY_DIR, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        try:
            saw_startup = False
            # Read until the marker or the process dies; no fabric is running, so startup will
            # complain about unreachable switches -- that is fine and is not what is asserted.
            for _ in range(400):
                line = proc.stdout.readline()
                if not line:
                    break
                if STARTUP_MARKER in line:
                    saw_startup = True
                    break
            self.assertTrue(
                saw_startup,
                "with the port free the proxy must still start normally; a guard that blocks "
                "the good case too is worse than no guard",
            )
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    unittest.main(verbosity=2)
