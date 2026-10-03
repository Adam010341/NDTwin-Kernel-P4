"""A throwaway stock bmv2 in pcap mode, for S0's offline self-checks. No root, no interface.

[Co-developed with claude code -- Adam]

The shape of tools/test_workflow/heartbeat_drop_check.py's `Launch`, with its rules kept:

  * argv[0] is `ndt-hc-selfcheck-bmv2` and the file executed is a symlink of that name, so its
    comm is not `simple_switch*` either: nothing that finds fabric switches by name or by argv
    (ndt's bmv2_count, the helper's sweep, p4_testbed_topo, the kernel's capacity scan) counts
    it or reaps it;
  * it runs as the caller (refused as root), in its own temporary directory, on a Thrift port
    from 29500-29599 -- outside every lab port and outside the drop check's 29400-29499 --
    checked free right before the launch, with a device id far above any fabric's;
  * it is stopped by its exact pid, and dies with this process (PR_SET_PDEATHSIG).

Unlike the drop check it DOES get entries: `--use-files <wait>` makes bmv2 wait that long before
it reads the input pcaps, the entries go in through simple_switch_CLI in that window, and the run
is refused unless the CLI finished inside it (`installed_before_s` < wait).
"""
from __future__ import annotations

import ctypes
import os
import shutil
import signal
import socket
import subprocess
import tempfile
import time

from . import frames as F
from .collect.runner import Runner

ARGV0 = "ndt-hc-selfcheck-bmv2"
DEFAULT_BMV2 = "/usr/local/bin/simple_switch"
THRIFT_CANDIDATES = range(29500, 29600)
DEVICE_ID = 910000
#: The lab's ports (ports.sh, heartbeat_drop_check.LAB_PORT_RANGES): never chosen.
LAB_PORT_RANGES = ((9090, 9090 + 512), (30050, 30050 + 512), (6343, 6344), (6633, 6634),
                   (6653, 6654), (8000, 8001), (8080, 8082), (9000, 9001))


class ThrowawayError(RuntimeError):
    pass


def outside_lab_ports(port):
    return not any(lo <= port < hi for lo, hi in LAB_PORT_RANGES)


def port_is_free(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def choose_thrift_port():
    for port in THRIFT_CANDIDATES:
        if outside_lab_ports(port) and port_is_free(port):
            return port
    return None


def _die_with_parent():
    try:
        ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, signal.SIGKILL)
    except OSError:
        pass


def _wait_port(port, deadline):
    while time.monotonic() < deadline:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.2)
        try:
            s.connect(("127.0.0.1", port))
            return True
        except OSError:
            time.sleep(0.1)
        finally:
            s.close()
    return False


class Throwaway(object):
    """One switch, one program, one set of input frames per port."""

    def __init__(self, program_json, inputs, cpu_port, cli_argv, wait_s=8,
                 bmv2=DEFAULT_BMV2, workdir=None, runner=None):
        self.program_json = os.path.abspath(program_json)
        self.inputs = dict(inputs)                    # {port: [frame bytes]}
        self.cpu_port = cpu_port
        self.ports = sorted(set(self.inputs) | {cpu_port})
        self.cli_argv = list(cli_argv)
        self.wait_s = wait_s
        self.bmv2 = bmv2
        self.workdir = workdir or tempfile.mkdtemp(prefix="ndt-hc-selfcheck-")
        self.proc = None
        self.thrift_port = None
        self.started_at = None
        self.installed_before_s = None
        self.cli_log = []
        self.runner = runner or Runner()

    def start(self):
        if os.geteuid() == 0:
            raise ThrowawayError("refusing to launch the throwaway switch as root")
        if not os.access(self.bmv2, os.X_OK):
            raise ThrowawayError("no stock simple_switch at %s" % self.bmv2)
        self.thrift_port = choose_thrift_port()
        if self.thrift_port is None:
            raise ThrowawayError("no free Thrift port in 29500-29599")
        for port in self.ports:
            F.write_pcap(os.path.join(self.workdir, "p%d_in.pcap" % port), self.inputs.get(port, []))
        bindir = os.path.join(self.workdir, ".bin")
        os.makedirs(bindir, exist_ok=True)
        link = os.path.join(bindir, ARGV0)
        if not os.path.lexists(link):
            os.symlink(os.path.abspath(self.bmv2), link)
        argv = [ARGV0, "--use-files", str(self.wait_s)]
        for port in self.ports:
            argv += ["-i", "%d@p%d" % (port, port)]
        argv += ["--thrift-port", str(self.thrift_port), "--device-id", str(DEVICE_ID),
                 "--notifications-addr", "ipc://notif.ipc", "--log-file", "bmv2",
                 "--log-level", "debug", "--log-flush", self.program_json]
        self.argv = argv
        out = open(os.path.join(self.workdir, "stdout.txt"), "wb")
        self.started_at = time.monotonic()
        self.proc = subprocess.Popen(argv, executable=link, cwd=self.workdir,
                                     stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                                     preexec_fn=_die_with_parent, start_new_session=True)
        out.close()
        if not _wait_port(self.thrift_port, self.started_at + self.wait_s):
            self.stop()
            raise ThrowawayError("the throwaway switch never opened Thrift port %d" % self.thrift_port)
        return self

    def cli(self, lines, timeout=60):
        """Run CLI lines against THIS switch's port only. Returns stdout."""
        if self.thrift_port is None or not outside_lab_ports(self.thrift_port):
            raise ThrowawayError("refusing a CLI call to a port that is not the throwaway's")
        text = "\n".join(lines) + "\n"
        res = self.runner.run(self.cli_argv + ["--thrift-port", str(self.thrift_port)],
                              timeout=timeout, cwd=self.workdir, input_text=text)
        self.cli_log.append({"lines": list(lines), "rc": res.rc, "out": res.stdout + res.stderr})
        return res.stdout

    def install(self, lines):
        out = self.cli(lines)
        self.installed_before_s = time.monotonic() - self.started_at
        bad = [l for l in out.splitlines() if "Error" in l or "Invalid" in l or "Could not" in l]
        if bad or self.cli_log[-1]["rc"] != 0:
            raise ThrowawayError("installing the entries failed: %s" % (bad[:3] or self.cli_log[-1]["rc"]))
        if self.installed_before_s >= self.wait_s:
            raise ThrowawayError("the entries took %.1f s to install, past the %d s the switch "
                                 "waits before reading its input: the frames may have met an "
                                 "empty table" % (self.installed_before_s, self.wait_s))
        return out

    def wait_processed(self, settle_s=3.0):
        remaining = self.started_at + self.wait_s - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)
        time.sleep(settle_s)

    def outputs(self):
        return {port: F.read_pcap(os.path.join(self.workdir, "p%d_out.pcap" % port))
                for port in self.ports}

    def log_text(self):
        try:
            with open(os.path.join(self.workdir, "bmv2.txt"), errors="replace") as fh:
                return fh.read()
        except OSError:
            return ""

    def stop(self):
        if self.proc is None:
            return None
        if self.proc.poll() is None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=3)
        return self.proc.returncode

    def cleanup(self):
        shutil.rmtree(self.workdir, ignore_errors=True)
