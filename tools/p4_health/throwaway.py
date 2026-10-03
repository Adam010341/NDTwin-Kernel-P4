"""A throwaway bmv2 in pcap mode, for S0's offline self-checks and trials. No root, no interface.

[Co-developed with claude code -- Adam]

The shape of tools/test_workflow/heartbeat_drop_check.py's `Launch`, with its rules kept:

  * argv[0] is `ndt-hc-selfcheck-bmv2` (or another `ndt-hc-*` name) and the file executed is a
    symlink of that name, so its comm is not `simple_switch*` either: nothing that finds fabric
    switches by name or by argv (ndt's bmv2_count, the helper's sweep, p4_testbed_topo, the
    kernel's capacity scan) counts it or reaps it;
  * it runs as the caller (refused as root), in its own directory, on a Thrift port from
    29500-29599 (gRPC, when asked for, from 29650-29699) -- outside every lab port, which are
    read from p4_proxy/mininet/grpc_ports.py the way the drop check reads them -- checked free
    right before the launch, with a device id far above any fabric's and unique to this
    process; after the port opens, `switch_info` must report that device id, so a listener
    that won a bind race is never mistaken for ours;
  * it is stopped by its exact pid, and dies with this process (PR_SET_PDEATHSIG; a child that
    cannot set it exits before it execs).

Unlike the drop check it DOES get entries, through simple_switch_CLI on ITS OWN port: the only
thrift writes anywhere in tools/p4_health go to a switch this module started (`cli` refuses any
other port). `--use-files <wait>` makes bmv2 wait before it reads the input pcaps; the entries
go in inside that window and the run is refused unless they did.
"""
from __future__ import annotations

import ctypes
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

from . import frames as F
from .collect.runner import Runner

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
ARGV0 = "ndt-hc-selfcheck-bmv2"
DEFAULT_BMV2 = "/usr/local/bin/simple_switch"
THRIFT_CANDIDATES = range(29500, 29600)
GRPC_CANDIDATES = range(29650, 29700)
DEVICE_ID = 910000 + os.getpid() % 50000


def _lab_port_ranges():
    """The lab's ports, from grpc_ports.py (heartbeat_drop_check.py:116-119's list). When that
    module cannot be read every port counts as the lab's, so nothing is ever chosen."""
    sys.path.insert(0, os.path.join(REPO, "p4_proxy", "mininet"))
    try:
        import grpc_ports
    except Exception:  # noqa: BLE001
        return ((0, 65536),)
    finally:
        sys.path.pop(0)
    return ((grpc_ports.THRIFT_PORT_BASE, grpc_ports.THRIFT_PORT_BASE + 512),
            (grpc_ports.GRPC_PORT_BASE, grpc_ports.GRPC_PORT_BASE + 512),
            (6343, 6344), (6633, 6634), (6653, 6654), (8000, 8001), (8080, 8082), (9000, 9001))


LAB_PORT_RANGES = _lab_port_ranges()


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


def choose_port(candidates=THRIFT_CANDIDATES):
    for port in candidates:
        if outside_lab_ports(port) and port_is_free(port):
            return port
    return None


def choose_thrift_port():
    return choose_port(THRIFT_CANDIDATES)


def _die_with_parent():
    """In the child, before exec. A child that cannot arrange to die with us must not run."""
    try:
        rc = ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, signal.SIGKILL)
    except OSError:
        rc = -1
    if rc != 0:
        os._exit(127)


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
                 bmv2=DEFAULT_BMV2, workdir=None, runner=None, argv0=ARGV0, grpc=False):
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
        self.argv0 = argv0
        self.grpc = grpc
        self.grpc_port = None
        if not argv0.startswith("ndt-hc-"):
            raise ThrowawayError("a throwaway switch's argv[0] must start with ndt-hc-")

    def start(self):
        if os.geteuid() == 0:
            raise ThrowawayError("refusing to launch the throwaway switch as root")
        if not os.access(self.bmv2, os.X_OK):
            raise ThrowawayError("no bmv2 at %s" % self.bmv2)
        self.thrift_port = choose_port(THRIFT_CANDIDATES)
        if self.thrift_port is None:
            raise ThrowawayError("no free Thrift port in 29500-29599")
        if self.grpc:
            self.grpc_port = choose_port(GRPC_CANDIDATES)
            if self.grpc_port is None:
                raise ThrowawayError("no free gRPC port in 29650-29699")
        for port in self.ports:
            F.write_pcap(os.path.join(self.workdir, "p%d_in.pcap" % port), self.inputs.get(port, []))
        bindir = os.path.join(self.workdir, ".bin")
        os.makedirs(bindir, exist_ok=True)
        link = os.path.join(bindir, self.argv0)
        if not os.path.lexists(link):
            os.symlink(os.path.abspath(self.bmv2), link)
        argv = [self.argv0, "--use-files", str(self.wait_s)]
        for port in self.ports:
            if self.grpc and port == self.cpu_port:
                continue        # simple_switch_grpc owns its --cpu-port; it is not a data port
            argv += ["-i", "%d@p%d" % (port, port)]
        argv += ["--thrift-port", str(self.thrift_port), "--device-id", str(DEVICE_ID),
                 "--notifications-addr", "ipc://notif.ipc", "--log-file", "bmv2",
                 "--log-level", "debug", "--log-flush", self.program_json]
        env = dict(os.environ)
        if self.grpc:
            argv += ["--", "--grpc-server-addr", "127.0.0.1:%d" % self.grpc_port,
                     "--cpu-port", str(self.cpu_port)]
            lib = os.path.normpath(os.path.join(os.path.dirname(os.path.realpath(self.bmv2)), "..", "lib"))
            if os.path.isdir(lib):
                env["LD_LIBRARY_PATH"] = lib            # p4_testbed_topo's ../lib rule
        self.argv = argv
        out = open(os.path.join(self.workdir, "stdout.txt"), "wb")
        self.started_at = time.monotonic()
        self.proc = subprocess.Popen(argv, executable=link, cwd=self.workdir, env=env,
                                     stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                                     preexec_fn=_die_with_parent, start_new_session=True)
        out.close()
        deadline = self.started_at + max(self.wait_s, 5)
        if not _wait_port(self.thrift_port, deadline) or \
                (self.grpc and not _wait_port(self.grpc_port, deadline)):
            self.stop()
            raise ThrowawayError("the throwaway switch never opened its port(s)")
        info = self.cli(["switch_info"])
        m = re.search(r"device_id\s*:\s*(\d+)", info or "")
        if m is None or int(m.group(1)) != DEVICE_ID or self.proc.poll() is not None:
            self.stop()
            raise ThrowawayError("the switch on port %d is not the one just started (switch_info: "
                                 "%r)" % (self.thrift_port, (info or "")[-200:]))
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
        """{port: [frames]}; a port whose output pcap is missing maps to None (unreadable)."""
        return {port: F.read_pcap(os.path.join(self.workdir, "p%d_out.pcap" % port))
                for port in self.ports}

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

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
