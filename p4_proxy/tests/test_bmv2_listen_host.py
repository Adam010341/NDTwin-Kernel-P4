#!/usr/bin/env python3
"""
The bmv2 switches' gRPC servers listen on loopback unless NDTWIN_BMV2_HOST says otherwise.

[Co-developed with claude code -- Adam]

The switches run in the root namespace and their P4Runtime server has no authentication, so
whatever could reach the machine at ports 30051-30060 could write a switch's tables. They used
to be launched with `--grpc-server-addr 0.0.0.0:<port>`. The default is now 127.0.0.1, and
NDTWIN_BMV2_HOST (127.0.0.1, 0.0.0.0 or ::) is the one way to listen anywhere else -- the same shape as NDTWIN_PROXY_HOST
for the proxy (test_listen_host.py).

These tests drive the real `BMv2Switch.start()` and read the command line it composed (the
argv bmv2 is given, and the one the manifest records), so they fail on a change that moves the
default back to 0.0.0.0 or stops reading the variable, and not merely on a changed constant.
"""

import importlib.util
import json
import os
import shlex
import shutil
import socket
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

ENV = "NDTWIN_BMV2_HOST"


class _StubSwitch:
    """Just enough of mininet.node.Switch for BMv2Switch.start() to run."""

    def __init__(self, name, **kwargs):
        self.name = name
        self.intfs = {}

    def cmd(self, line):
        self.last_cmd = line
        return "12345\n"


def load_testbed_module():
    """Import p4_testbed_topo.py with mininet stubbed out, under a name of our own."""
    stubs = {
        "mininet": {},
        "mininet.net": {"Mininet": type("Mininet", (), {})},
        "mininet.topo": {"Topo": type("Topo", (), {"__init__": lambda self, **kw: None,
                                                   "addSwitch": lambda self, *a, **kw: None,
                                                   "addHost": lambda self, *a, **kw: None,
                                                   "addLink": lambda self, *a, **kw: None})},
        "mininet.node": {"Switch": _StubSwitch, "Host": type("Host", (), {})},
        "mininet.cli": {"CLI": type("CLI", (), {})},
        "mininet.log": {"setLogLevel": lambda *a, **k: None,
                        "info": lambda *a, **k: None},
    }
    for name, attrs in stubs.items():
        mod = sys.modules.get(name) or types.ModuleType(name)
        for attr, value in attrs.items():
            setattr(mod, attr, value)
        sys.modules[name] = mod
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "mininet", "p4_testbed_topo.py")
    spec = importlib.util.spec_from_file_location("p4_testbed_topo_listen_host_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


topo = load_testbed_module()


def have_ipv6_wildcard():
    try:
        s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        s.bind(("::", 0))
        s.close()
        return True
    except OSError:
        return False


class SwitchCase(unittest.TestCase):
    """A scratch binary override, and the means to start one switch under a given environment."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="bmv2_listen_host.")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        binary = os.path.join(self.tmp, "bin", "simple_switch_grpc")
        os.makedirs(os.path.dirname(binary))
        with open(binary, "w") as fh:
            fh.write("#!/bin/sh\n")
        os.chmod(binary, 0o755)
        override = os.path.join(self.tmp, "bmv2_binary_override")
        with open(override, "w") as fh:
            fh.write(binary + "\n")
        original = topo.BINARY_OVERRIDE_PATH
        topo.BINARY_OVERRIDE_PATH = override
        self.addCleanup(setattr, topo, "BINARY_OVERRIDE_PATH", original)

    def started(self, env_value=None, grpc_port=30053):
        """A BMv2Switch built and start()ed with NDTWIN_BMV2_HOST set to env_value (or absent)."""
        with mock.patch.dict(os.environ):
            os.environ.pop(ENV, None)
            if env_value is not None:
                os.environ[ENV] = env_value
            sw = topo.BMv2Switch("s3", json_path="/tmp/prog.json", device_id=3,
                                 grpc_port=grpc_port, thrift_port=9093)
            sw.start(controllers=[])
        return sw

    @staticmethod
    def grpc_addr(argv):
        words = argv.split()
        return words[words.index("--grpc-server-addr") + 1]


class DefaultIsLoopback(SwitchCase):
    def test_the_default_argv_carries_127_0_0_1(self):
        sw = self.started()
        self.assertEqual(
            "127.0.0.1:30053", self.grpc_addr(sw.launch_argv),
            "with NDTWIN_BMV2_HOST unset the unauthenticated gRPC server must be reachable "
            "from this machine only")
        self.assertNotIn("0.0.0.0", sw.launch_argv)

    def test_the_command_that_ran_is_the_one_recorded(self):
        sw = self.started()
        self.assertIn("--grpc-server-addr 127.0.0.1:30053 ", sw.last_cmd)

    def test_an_empty_setting_is_the_default_not_all_interfaces(self):
        sw = self.started("   ")
        self.assertEqual("127.0.0.1:30053", self.grpc_addr(sw.launch_argv))

    def test_the_reader_defaults_to_loopback(self):
        self.assertEqual("127.0.0.1", topo.bmv2_listen_host({}))
        self.assertEqual("127.0.0.1", topo.bmv2_listen_host({ENV: ""}))


class OptIn(SwitchCase):
    def test_all_interfaces_is_possible(self):
        sw = self.started(" 0.0.0.0 ")
        self.assertEqual("0.0.0.0:30053", self.grpc_addr(sw.launch_argv))
        self.assertEqual("0.0.0.0", sw.grpc_host)

    def test_the_ipv6_wildcard_is_bracketed_and_quoted_for_the_shell(self):
        if not have_ipv6_wildcard():
            self.skipTest("no IPv6 on this machine")
        sw = self.started("::")
        # In the manifest's argv (which the power helper shlex-splits) and in the shell line:
        # "[::]:N" unquoted is a bracket glob.
        self.assertEqual("[::]:30053", self.grpc_addr(sw.launch_argv.replace("'", "")))
        self.assertIn("--grpc-server-addr '[::]:30053' ", sw.last_cmd)
        self.assertEqual(["--grpc-server-addr", "[::]:30053"],
                         shlex.split(sw.launch_argv)[-4:-2])

    def test_the_canonical_address_is_what_is_used(self):
        # AI_NUMERICHOST accepts "127.1" and "0"; the argv and the manifest carry the canonical
        # spelling, so "127.1" is not mistaken for something non-loopback and "0" is not printed as 0.
        self.assertEqual("127.0.0.1", topo.bmv2_listen_host({ENV: "127.1"}))
        self.assertEqual("0.0.0.0", topo.bmv2_listen_host({ENV: "0"}))
        self.assertEqual("0.0.0.0:30053", self.grpc_addr(self.started("0").launch_argv))

    def test_an_explicit_host_beats_the_environment(self):
        # MultiSwitchTopo hands every switch the one answer the pre-flight gave.
        with mock.patch.dict(os.environ, {ENV: "0.0.0.0"}):
            sw = topo.BMv2Switch("s1", json_path="/tmp/p.json", device_id=1,
                                 grpc_port=30051, thrift_port=9091, grpc_host="127.0.0.1")
        self.assertEqual("127.0.0.1", sw.grpc_host)


class BadValueIsRefused(SwitchCase):
    # 127.0.0.2, ::1 and the LAN address are real, bindable addresses of this machine; they are
    # refused because nothing that checks a switch would find it there.
    BAD = ("not-an-address", "localhost", "10.0.0.0/8", "127.0.0.1:30051", "203.0.113.77",
           "127.0.0.2", "::1", "::ffff:127.0.0.1", "192.168.1.5", "10..0.1")

    def test_the_reader_refuses_and_names_the_variable(self):
        for value in self.BAD:
            with self.subTest(value=value):
                with self.assertRaises(topo.Bmv2HostError) as ctx:
                    topo.bmv2_listen_host({ENV: value})
                self.assertIn(ENV, str(ctx.exception))
                self.assertIn(repr(value), str(ctx.exception))

    def test_a_specific_address_is_refused_with_the_reason(self):
        with self.assertRaises(topo.Bmv2HostError) as ctx:
            topo.bmv2_listen_host({ENV: "127.0.0.2"})
        message = str(ctx.exception)
        for word in ("127.0.0.1", "0.0.0.0", "::", "probes", "ndtwin-p4-power", "proxy"):
            self.assertIn(word, message)

    def test_it_is_a_value_error_so_both_mains_catch_it(self):
        self.assertTrue(issubclass(topo.Bmv2HostError, ValueError))

    def test_a_switch_is_not_built_on_a_bad_value(self):
        # Nothing reaches the launch command: the refusal is at construction.
        with mock.patch.dict(os.environ, {ENV: "not-an-address"}):
            with self.assertRaises(topo.Bmv2HostError):
                topo.BMv2Switch("s1", json_path="/tmp/p.json", device_id=1,
                                grpc_port=30051, thrift_port=9091)


class WhyAnotherLoopbackAddressIsRefused(unittest.TestCase):
    """Unstubbed: a real listener on 127.0.0.2 and the switch's real liveness probe.

    The probe every bring-up trusts (BMv2Switch.grpc_is_listening, and with it verify_switches)
    dials 127.0.0.1. A server bound to 127.0.0.2 is up and accepting, and the probe says it is
    not -- so that fabric would be torn down, rebuilt and then declared dead. The refusal is what
    stops the sequence before the teardown.
    """

    def listener(self, address):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.addCleanup(sock.close)
        try:
            sock.bind((address, 0))
        except OSError:
            self.skipTest("this machine cannot bind %s" % address)
        sock.listen(4)
        return sock.getsockname()[1]

    def switch(self, port):
        with mock.patch.dict(os.environ):
            os.environ.pop(ENV, None)
            return topo.BMv2Switch("s1", json_path="/tmp/p.json", device_id=1,
                                   grpc_port=port, thrift_port=9091)

    def test_the_probe_finds_a_server_on_127_0_0_1(self):
        self.assertTrue(self.switch(self.listener("127.0.0.1")).grpc_is_listening())

    def test_the_probe_does_not_find_a_server_on_127_0_0_2_so_127_0_0_2_is_refused(self):
        port = self.listener("127.0.0.2")
        with socket.create_connection(("127.0.0.2", port), timeout=1):
            pass  # the server is there and accepts
        self.assertFalse(self.switch(port).grpc_is_listening())
        with self.assertRaises(topo.Bmv2HostError):
            topo.bmv2_listen_host({ENV: "127.0.0.2"})


class WhatTheBringUpSays(unittest.TestCase):
    def test_loopback_is_printed_without_a_warning(self):
        for value in ("127.0.0.1",):
            with self.subTest(value=value):
                lines = topo.bmv2_host_lines(value)
                self.assertEqual([f"bmv2 gRPC listen address: {value}"], lines)

    def test_anything_else_warns_and_names_the_variable(self):
        for value in ("0.0.0.0", "::"):
            with self.subTest(value=value):
                lines = topo.bmv2_host_lines(value)
                self.assertEqual(2, len(lines))
                self.assertIn("WARNING", lines[1])
                self.assertIn("no authentication", lines[1])
                self.assertIn(ENV, lines[1])


class ManifestRecordsTheAddress(SwitchCase):
    def manifest_for(self, env_value):
        class Live(topo.BMv2Switch):
            def failure_reason(self):
                return None
        with mock.patch.dict(os.environ):
            os.environ.pop(ENV, None)
            if env_value is not None:
                os.environ[ENV] = env_value
            sw = Live("s3", json_path="/tmp/prog.json", device_id=3,
                      grpc_port=30053, thrift_port=9093)
            sw.start(controllers=[])
        path = os.path.join(self.tmp, "switches.json")
        self.assertIsNone(topo.write_manifest([sw], path=path))
        with open(path) as fh:
            return json.load(fh)["s3"]

    def test_the_default_address_is_in_the_entry(self):
        entry = self.manifest_for(None)
        self.assertEqual("127.0.0.1", entry["grpc_host"])
        self.assertEqual(30053, entry["grpc_port"])
        self.assertIn("--grpc-server-addr 127.0.0.1:30053", entry["argv"])

    def test_an_opted_in_address_is_in_the_entry(self):
        entry = self.manifest_for("0.0.0.0")
        self.assertEqual("0.0.0.0", entry["grpc_host"])
        self.assertIn("--grpc-server-addr 0.0.0.0:30053", entry["argv"])

    def test_the_reap_still_recognises_the_switch(self):
        # process_is_a_switch ties a pid to its entry by the port the gRPC address ends in,
        # so a loopback address must not stop teardown from reaping the switch.
        pid = os.getpid()
        proc = os.path.join(self.tmp, "proc", str(pid))
        os.makedirs(proc)
        argv = ["/x/simple_switch_grpc", "--thrift-port", "9093", "--device-id", "3",
                "/tmp/prog.json", "--", "--grpc-server-addr", "127.0.0.1:30053"]
        with open(os.path.join(proc, "cmdline"), "wb") as fh:
            fh.write(b"\0".join(a.encode() for a in argv) + b"\0")
        entry = {"grpc_port": 30053, "device_id": 3}
        self.assertTrue(topo.process_is_a_switch(
            pid, proc_root=os.path.join(self.tmp, "proc"), entry=entry))


if __name__ == "__main__":
    unittest.main()
