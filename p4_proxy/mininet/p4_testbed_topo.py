#!/usr/bin/env python3

import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
from mininet.net import Mininet
from mininet.topo import Topo
from mininet.node import Switch, Host
from mininet.cli import CLI
from mininet.log import setLogLevel, info

# The sibling module resolves when this file runs as a script (its own directory is then
# sys.path[0]) but not when a test loads this file via importlib from elsewhere -- which is
# how test_readopt and test_bmv2_binary_override went red the day the JSON wiring landed.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import topo_from_json  # noqa: E402
import grpc_ports  # noqa: E402
import app_package  # noqa: E402

# [Co-developed with claude code -- Adam]
# Where the switch manifest is written: name -> pid, grpc_port, thrift_port, device_id.
# P4PowerStrategy needs this to power one switch off without killing the other nine
# (Mininet switches share the root PID namespace, so `pkill -f simple_switch_grpc` kills
# all of them). See Phase 7 of doc/2026-07-27_p4_bmv2_support_plan.md.
MANIFEST_PATH = "/tmp/ndtwin_p4_switches.json"

# [Co-developed with claude code -- Adam]
# The launcher default and its override. The override file exists because the lab wrapper
# launches this topology with a fixed root environment, so no env var can reach it -- a file
# next to the topology is the only channel an unprivileged operator has. One directive line,
# the absolute path of the simple_switch_grpc to run; blank lines and #-comments are ignored.
#
# 2026-08-22: the fast build is the default, and a missing directive is now a REFUSAL rather
# than a fallback. [Co-developed with claude code -- Adam]
#
# It used to be `"simple_switch_grpc"` -- a bare name, PATH lookup, which resolves to the stock
# -O0 build. Delete or comment out the override and the next run silently benchmarked a binary
# roughly 10x slower while every filename, note and slide still said "fast". Nothing errored;
# the number that came back was merely plausible, which reads as "the fabric was busy" rather
# than as a wrong binary. That is the one silent path bmv2-binary-provenance.md flagged in red.
#
# Promoting fast to default does not remove that trap, it INVERTS it: silence would now mean
# someone who wanted the stock build got the fast one. So neither direction is left silent --
# resolve_bmv2_launcher raises when the file is absent or carries no directive, and the binary
# in use is always something a human wrote down.
#
# The promotion is licensed by doc/audit/2026-08-22_stock-control-ladder/: the same ladder, same
# invocation, back to back on both binaries, with each arm verifying from /proc which binary the
# live switches actually run. Both arms: L0/L1/L2/L3/capture/L4 pass, log allowlist fails
# identically. "The fast build introduces zero new failures" is now a measurement.
DEFAULT_BMV2_BINARY = "/usr/local/bmv2-fast/bin/simple_switch_grpc"
BINARY_OVERRIDE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "bmv2_binary_override")


HOST_COUNT_OVERRIDE_PATH = topo_from_json.HOST_COUNT_OVERRIDE_PATH


SETTING_DIR = topo_from_json.SETTING_DIR


# [Co-developed with claude code -- Adam]
# These three moved to topo_from_json.py, which imports no Mininet and can therefore be read by
# the proxy and by a unit test. The proxy needs the same three answers now that it builds its
# host table from the model, and a second implementation of "which file, how many hosts, what
# MAC" is the exact shape that once let the proxy know four hosts while the fabric built 128.
# These remain as delegates so every existing caller and test keeps its name.
_mac_str = topo_from_json.mac_str
_host_count_override = topo_from_json.host_count_override


def _topology_model_path(host_num, package=None):
    """The model this fabric builds from: the app package's, or the one the host count picks.

    [Co-developed with claude code -- Adam]
    Behaviour with no package is unchanged, `NDTWIN_P4_TOPO_FILE` included -- see
    topo_from_json.model_path, which is where the body went.
    """
    return app_package.topology_path(package, host_num, setting_dir=SETTING_DIR)


def fabric_model(package=None):
    """(package, model_path, model) for this run -- the one place the fabric decides what it is.

    [Co-developed with claude code -- Adam]
    Both `main()` and `MultiSwitchTopo` need the model: main() pre-flights the gRPC port block
    for the switches the model declares, and that has to happen BEFORE `mn -c` tears anything
    down, while the topology object is only built afterwards. Rather than thread an object
    through Mininet's `Topo(**opts)` bag, both call this. It is a pure read of two files.
    """
    package = app_package.current() if package is None else package
    host_num = int(os.environ.get("NDTWIN_P4_HOST_NUM", "0")) or _host_count_override()
    path = _topology_model_path(host_num, package)
    return package, path, topo_from_json.load(path)


def resolve_bmv2_launcher(override_path=None):
    """
    Which simple_switch_grpc this fabric runs: (binary, lib_dir).

    [Co-developed with claude code -- Adam]
    Default is the bare name -- PATH lookup, byte-identical to the pre-override behavior.
    With an override file, the binary comes from its first directive line, and lib_dir is
    the install prefix's ../lib when that directory exists: the fast build's libraries
    must accompany its binary or the run silently mixes stock libs into a "fast"
    measurement (the performance report's trap #3), which is why the derivation is
    automatic rather than a second line someone can forget.

    A present-but-broken override raises instead of falling back: a fallback would
    benchmark the stock build under a filename that claims otherwise, and a corrupted
    comparison is worse than a refused run.
    """
    if override_path is None:
        # Resolved at call time, not bound at def time, so the module attribute stays
        # patchable and every caller (start(), both mains' pre-flights) sees one source.
        override_path = BINARY_OVERRIDE_PATH
    try:
        with open(override_path, encoding="utf-8") as fh:
            lines = fh.readlines()
    except FileNotFoundError:
        raise ValueError(
            f"no bmv2 binary override at {override_path}. This file is tracked and must name "
            f"the simple_switch_grpc to run -- there is no default to fall back to on purpose. "
            f"Both installs answer --version identically, so a silent fallback picks a binary "
            f"that differs by ~10x in throughput and says nothing. "
            f"Write one absolute path, e.g. {DEFAULT_BMV2_BINARY}") from None
    directive = next((ln.strip() for ln in lines
                      if ln.strip() and not ln.strip().startswith("#")), None)
    if directive is None:
        raise ValueError(
            f"{override_path} has no directive line (every line is blank or a #-comment). "
            f"Commenting the line out used to re-select the stock build silently; it now "
            f"refuses, because which binary produced a number must be something a human "
            f"wrote down. Write one absolute path, e.g. {DEFAULT_BMV2_BINARY}")
    if not os.path.isabs(directive):
        raise ValueError(f"bmv2 binary override must be an absolute path, "
                         f"got {directive!r} (file: {override_path})")
    if not (os.path.isfile(directive) and os.access(directive, os.X_OK)):
        raise ValueError(f"bmv2 binary override names no executable: {directive!r} "
                         f"(file: {override_path})")
    lib_dir = os.path.normpath(os.path.join(os.path.dirname(directive), "..", "lib"))
    return directive, (lib_dir if os.path.isdir(lib_dir) else None)


def bmv2_launch_head(binary, lib_dir):
    """
    The start of the shell command that launches one switch.

    [Co-developed with claude code -- Adam]
    LD_LIBRARY_PATH rides in front as a shell env-prefix: the launch goes through the
    switch's shell (BMv2Switch.start -> self.cmd), where the prefix binds to that process
    only. The manifest argv therefore starts with the prefix.

    That used to mean power-ON did not work under an override at all: ndtwin-p4-power's
    shell-free exec checks basename(argv[0]) and refused the entry. The reasoning was that
    a refusal an operator can read beats relaunching the fast binary against the stock
    libraries via the ldconfig cache -- a switch that is neither build.

    Both halves of that were true and the third option was missed. The helper now strips
    the assignments and derives LD_LIBRARY_PATH from the binary itself, by the same
    dirname(binary)/../lib rule resolve_bmv2_launcher uses above, so it relaunches with the
    *right* libraries rather than choosing between wrong and refused. Keep the two
    derivations identical if either moves.

    Why it mattered enough to revisit: the Energy-Saving App exists to power switches off
    *and back on*, so under an override it could only ever shut the fabric down. Found live
    2026-08-18 by powering s5 off and being unable to bring it back.

    Power-OFF was never affected (pid + comm).
    """
    return f"LD_LIBRARY_PATH={lib_dir} {binary}" if lib_dir else binary


class BMv2Switch(Switch):
    """BMv2 switch for Mininet"""
    def __init__(self, name, json_path=None, device_id=1,
                 grpc_port=grpc_ports.grpc_port(1), thrift_port=grpc_ports.THRIFT_PORT_BASE,
                 cpu_port=app_package.BASELINE_CPU_PORT,
                 **kwargs):
        Switch.__init__(self, name, **kwargs)
        self.json_path = json_path
        self.device_id = device_id
        self.grpc_port = grpc_port
        self.thrift_port = thrift_port
        # [Co-developed with claude code -- Adam]
        # Was the literal 255 written into the argv below, one of three copies of that number
        # (the other two are p4_client.CPU_PORT and ndtwin_switch.p4). The default here is that
        # same 255, so a fabric built without a package launches a byte-identical command line;
        # what the parameter buys is a package whose pipeline puts the CPU port somewhere else
        # being able to say so, instead of its packet-ins going to a port nothing reads.
        self.cpu_port = cpu_port
        self.log_file = f"/tmp/{self.name}_bmv2.log"
        # PID of the launched simple_switch_grpc, captured so stop() can target this one
        # switch and so the manifest can be written. None until start() runs.
        self.bmv2_pid = None
        self.launch_argv = None

    def start(self, controllers):
        binary, lib_dir = resolve_bmv2_launcher()
        args = [bmv2_launch_head(binary, lib_dir)]
        for port, intf in self.intfs.items():
            if not intf.IP():
                args.extend(['-i', f'{port}@{intf.name}'])

        # args.extend(['--log-console'])
        args.extend(['--thrift-port', str(self.thrift_port)])
        args.extend(['--device-id', str(self.device_id)])

        if self.json_path:
            args.append(self.json_path)
        else:
            args.append('--no-p4')

        args.append('--')
        args.append('--grpc-server-addr')
        args.append(f'0.0.0.0:{self.grpc_port}')
        args.append('--cpu-port')
        args.append(str(self.cpu_port))

        cmd = ' '.join(args)
        self.launch_argv = cmd
        info(f"Starting {self.name} (gRPC: {self.grpc_port}, Thrift: {self.thrift_port}, "
             f"bin: {binary})\n")
        # `echo $!` yields the background PID; cmd() returns the shell's output. Without this
        # there is no handle on the process at all, which is why stop() used a job spec.
        out = self.cmd(f"{cmd} > {self.log_file} 2>&1 & echo $!")
        try:
            self.bmv2_pid = int(out.strip().split()[-1])
        except (ValueError, IndexError):
            self.bmv2_pid = None

    def is_alive(self):
        """Whether the launched process still exists."""
        if self.bmv2_pid is None:
            return False
        try:
            os.kill(self.bmv2_pid, 0)
            return True
        except (OSError, ProcessLookupError):
            return False

    def grpc_is_listening(self, timeout=0.3):
        """
        Whether anything accepts TCP on this switch's gRPC port.

        Checked in addition to the process being alive: bmv2 stays up briefly before its gRPC
        server binds, and a bind failure is reported by exiting, so both signals are needed to
        distinguish "still starting" from "died".
        """
        try:
            with socket.create_connection(("127.0.0.1", self.grpc_port), timeout=timeout):
                return True
        except OSError:
            return False

    def failure_reason(self):
        """
        Why this switch is not usable, or None when it is.

        [Co-developed with claude code -- Adam]
        Reads the switch's own log, which is where the real cause goes: bmv2's stderr is
        redirected to a file, so a bind failure ("Address already in use", the usual cause,
        from a leftover process holding the port) is completely invisible on the console.
        Nothing used to look at it, and the script reported success regardless.
        """
        if self.is_alive() and self.grpc_is_listening():
            return None

        detail = ""
        try:
            # errors="replace": bmv2 writes its own diagnostics here and can emit non-UTF-8
            # bytes. A UnicodeDecodeError is not an OSError, so it would escape this handler
            # and abort startup verification -- turning "one switch failed" into "the whole
            # topology script crashed".
            with open(self.log_file, encoding="utf-8", errors="replace") as fh:
                lines = [ln.strip() for ln in fh if ln.strip()]
            if any("Address already in use" in ln for ln in lines):
                detail = (f"gRPC port {self.grpc_port} was already in use -- most likely a "
                          f"leftover simple_switch_grpc from an earlier run")
            elif lines:
                detail = lines[-1][:300]
        except OSError:
            detail = "no log file"

        state = "process exited" if not self.is_alive() else "process alive but gRPC not listening"
        return f"{state}; {detail} (full log: {self.log_file})"

    def stop(self, deleteIntfs=True):
        # Kill this switch's PID rather than `kill %simple_switch_grpc`. The job spec only
        # works inside the shell that launched it, so closing the terminal left the process
        # running -- and those orphans are what hold the gRPC port and make the next run's
        # switch fail to bind.
        if self.bmv2_pid is not None:
            try:
                os.kill(self.bmv2_pid, signal.SIGTERM)
            except (OSError, ProcessLookupError):
                pass
        Switch.stop(self, deleteIntfs)

class MultiSwitchTopo(Topo):
    def __init__(self, package=None, model=None, **opts):
        Topo.__init__(self, **opts)

        # Which model to build from, and under which app package. The host count still selects
        # the model when no package names one -- that is the one knob the lab wrapper can
        # deliver (see topo_from_json.host_count_override) -- but everything else about the
        # fabric comes out of the model and the package.
        #
        # [Co-developed with claude code -- Adam]
        # `package`/`model` are arguments so main() can pre-flight the gRPC port block against
        # the switches this model declares BEFORE `mn -c` tears anything down, and then hand the
        # same two objects here rather than reading the files twice and risking two answers.
        if model is None:
            package, model_path, model = fabric_model(package)
            info(f"*** topology model: {model_path}\n")
        elif package is None:
            package = app_package.baseline()

        base = os.path.dirname(os.path.abspath(__file__))
        # The fabric-wide pipeline. `pipeline_for` answers NDTwin's own
        # `p4_src/build/ndtwin_switch.json` for every switch of every package in phase 1 (G4 is
        # not built), so this is byte-identical to the literal path it replaces.
        json_path = package.pipeline_for(1, os.path.join(base, ".."))[1]

        # The switches, from the model rather than from `range(1, 11)`.
        #
        # [Co-developed with claude code -- Adam]
        # That literal was the fourth copy of "this fabric has ten switches" -- the others were
        # main()'s port-block pre-flight, main()'s `net.get` loop, and the proxy's
        # DEFAULT_SWITCH_DPIDS. The 10-switch models still produce dpids 1..10, which
        # tools/test_workflow/test_topo_from_json.py asserts; what changes is that a package
        # with a different switch count is now buildable instead of silently truncated to ten.
        switches = {}
        for dpid, s_name in topo_from_json.switches(model):
            # grpc_port: 30051-30060, thrift_port: 9091-9100, device_id: 1-10.
            # Both bases live in grpc_ports.py, which is also where the reason the gRPC block
            # is 30050-based rather than 50050-based is written down (F-15: 50051-50060 was
            # inside the kernel's ephemeral range, so switches randomly failed to bind).
            s = self.addSwitch(s_name, cls=BMv2Switch, json_path=json_path,
                               device_id=dpid, grpc_port=grpc_ports.grpc_port(dpid),
                               thrift_port=grpc_ports.thrift_port(dpid),
                               cpu_port=package.cpu_port)
            switches[dpid] = s

        # Links, hosts and host attachment all come from the kernel's own topology model.
        #
        # [Co-developed with claude code -- Adam]
        # These used to be sixteen literal addLink calls, repeated verbatim in three files, with
        # nothing checking them against the model the twin loads. That is how a fabric and a
        # model could disagree in silence. Verified identical before the switch-over:
        # tools/test_workflow/test_topo_from_json.py compares the derived wiring against the
        # literals it replaces, for all three models, and it is part of the acceptance gate.
        #
        # The model is chosen by host count, the same rule `ndt` uses, because the topology is
        # launched through `tmux` under a fixed root environment where no operator-set variable
        # arrives -- the same reason host_count_override is a file. NDTWIN_P4_TOPO_FILE still
        # wins when the topology is run directly, which is how it gets tested.
        for a_dpid, a_port, b_dpid, b_port in topo_from_json.switch_links(model):
            self.addLink(switches[a_dpid], switches[b_dpid], port1=a_port, port2=b_port)

        # Hosts and their attachment, also from the model.
        #
        # [Co-developed with claude code -- Adam]
        # This replaces the "equal quarters over s1-s4, ports from 3" formula, which was a
        # second copy of a layout the model already stated exactly -- and a third copy lived in
        # the proxy. The formula also forced HOST_NUM to be a multiple of four; reading the
        # attachment removes that constraint, because the model says where each host actually
        # plugs in. Verified to reproduce the formula exactly at 4 and at 128 hosts before this
        # replaced it (tools/test_workflow/test_topo_from_json.py).
        #
        # The prefix length comes from the package and is 24 without one, which is the literal
        # this replaces. pod-topo puts its four hosts in four different /24s, so a fabric that
        # kept the literal would give every host a route to every other over its own subnet and
        # the exercise's `route add default gw` would never be consulted.
        for name, ip, mac in topo_from_json.hosts(model):
            self.addHost(name, ip=f"{ip}/{package.host_prefix_len(name)}",
                         mac=_mac_str(mac, name))

        for name, dpid, port in topo_from_json.host_links(model):
            self.addLink(name, switches[dpid], port1=1, port2=port)

def verify_switches(switches, timeout=10.0):
    """
    Wait for every switch to be up, and report the ones that are not.

    [Co-developed with claude code -- Adam]
    Returns a list of (name, reason). Empty means all are usable.

    Polls rather than sleeping a fixed amount: bmv2 needs a moment to bind its gRPC port, so
    an immediate check reports false failures, and a fixed sleep is either too short on a slow
    machine or wasted time on a fast one.
    """
    deadline = time.time() + timeout
    pending = list(switches)
    while pending and time.time() < deadline:
        pending = [sw for sw in pending if sw.failure_reason() is not None]
        if pending:
            time.sleep(0.5)
    return [(sw.name, sw.failure_reason() or "unknown") for sw in pending]


#: Set to "1" to keep a partial fabric instead of aborting. Same shape as grpc_ports'
#: override: an escape hatch for someone who has decided they want nine switches, never a
#: default.
ALLOW_PARTIAL_ENV = "NDTWIN_P4_ALLOW_PARTIAL_FABRIC"


def partial_fabric_verdict(failures, total, env=None):
    """
    What to do about the switches that did not come up: (fatal, message).

    [Co-developed with claude code -- Adam]
    Split out of main() so the decision can be tested without a fabric, and because it was not
    a decision at all before: main() printed a WARNING and then dropped into the CLI anyway,
    exiting 0. A run with eight of ten switches therefore looked, to anything scripting it,
    exactly like a run with ten -- and every measurement taken on top of it was silently
    against a different topology. Detecting the failure and then continuing is worse than not
    detecting it, because the banner makes it look handled.

    `fatal` is False only when there are no failures, or when someone set ALLOW_PARTIAL_ENV.
    """
    env = os.environ if env is None else env
    if not failures:
        return (False, None)

    alive = total - len(failures)
    lines = [f"{len(failures)} of {total} BMv2 switches did NOT come up."]
    lines.extend(f"  {name}: {reason}" for name, reason in failures)
    lines.append(f"{alive}/{total} switches are usable. The P4 proxy expects all {total} and "
                 f"will report errors for the rest, so anything measured now is measured "
                 f"against a fabric that is not the one being described.")

    if env.get(ALLOW_PARTIAL_ENV) == "1":
        lines.insert(0, f"WARNING ({ALLOW_PARTIAL_ENV}=1, continuing anyway):")
        return (False, "\n".join(lines))

    lines.insert(0, "ERROR: bring-up failed.")
    lines.append(f"Fix the cause and re-run. If a gRPC port was already in use, check "
                 f"whether the block still sits outside the ephemeral range: "
                 f"cat {grpc_ports.EPHEMERAL_RANGE_PATH}. Set {ALLOW_PARTIAL_ENV}=1 to keep "
                 f"a partial fabric deliberately.")
    return (True, "\n".join(lines))


def disable_host_offloads(hosts):
    """
    Turn off checksum/segmentation offloads on every host interface.

    [Co-developed with claude code -- Adam]
    bmv2's pcap path re-emits frames byte-for-byte, so a TCP segment that left its host
    with checksum offload pending arrives at the far host carrying a bad checksum and is
    silently dropped -- handshakes succeed (tiny segments), bulk TCP stalls at zero. This
    was masked since the topology's creation because every P4-side test used UDP or ICMP;
    NTG's iperf3 runs surfaced it on 2026-08-15 (seventeen "unable to connect to server"
    files while ping crossed the same fabric at 8 ms). Verified the same day: with
    offloads off, the identical TCP pair moved 16.8 MB at 23.9 Mbps. GSO/TSO/GRO go too:
    a 64 KB super-frame is one pcap packet as far as bmv2 is concerned.
    """
    for h in hosts:
        for intf in h.intfList():
            if intf.name != 'lo':
                h.cmd(f'ethtool -K {intf.name} tx off rx off gso off tso off gro off')


def write_manifest(switches, path=MANIFEST_PATH):
    """
    Record each switch's PID and ports so one switch can be managed on its own.

    [Co-developed with claude code -- Adam]
    Written for P4PowerStrategy (Phase 7): Mininet switches share the root PID namespace, so
    powering one switch off by pattern-matching the process name would kill all ten. Only
    verified-live switches are listed -- a manifest entry for a dead switch would be worse
    than no entry, since a caller would trust it.
    """
    manifest = {
        sw.name: {
            "pid": sw.bmv2_pid,
            "device_id": sw.device_id,
            "grpc_port": sw.grpc_port,
            "thrift_port": sw.thrift_port,
            "log_file": sw.log_file,
            "argv": sw.launch_argv,
        }
        for sw in switches
        if sw.failure_reason() is None
    }
    # Replace the inode, never truncate in place. /tmp is sticky, so anyone can create this
    # *name* before we run; open(path, "w") as root would truncate their file and leave them
    # the owner -- able to rewrite the argv that ndtwin-p4-power later executes as root. A
    # tempfile + os.replace makes the manifest a fresh inode owned by us every time, which is
    # exactly what the helper's owner check verifies before trusting the contents.
    # [Co-developed with claude code -- Adam]
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".",
                                   prefix=".ndtwin_p4_switches.")
        try:
            with os.fdopen(fd, "w") as fh:
                json.dump(manifest, fh, indent=2)
            os.chmod(tmp, 0o644)
            os.replace(tmp, path)
        except OSError:
            os.unlink(tmp)
            raise
    except OSError as e:
        print(f"WARNING: could not write the switch manifest to {path}: {e}")


def process_is_a_switch(pid, proc_root="/proc"):
    """
    Whether `pid` is currently a bmv2 process rather than whatever inherited that number.

    [Co-developed with claude code -- Adam]
    A pid recorded minutes ago is not evidence that the same process still holds it: Linux
    recycles pids, so killing a manifest pid unchecked would eventually kill something
    unrelated -- as root, since teardown runs under sudo. Reading the cmdline costs one open
    and turns "this number was a switch once" into "this number is a switch now".
    """
    try:
        with open(os.path.join(proc_root, str(pid), "cmdline"), "rb") as fh:
            return b"simple_switch_grpc" in fh.read()
    except OSError:
        # Gone, or not ours to look at. Either way there is nothing here to reap.
        return False


def reap_manifest_switches(path=MANIFEST_PATH, is_switch=process_is_a_switch,
                           kill=os.kill, settle_s=0.5):
    """
    Stop every switch still listed in the manifest. Returns the names actually reaped.

    [Co-developed with claude code -- Adam]
    Teardown used to delete the manifest without stopping what it described. `net.stop()`
    only reaps Mininet's own children, and a switch that ndtwin-p4-power restarted is not one
    of them -- the helper spawns with `start_new_session=True` (tools/p4_power_helper.py) so
    that the switch outlives the sudo invocation that created it, which is precisely what
    makes power-on work. So such a switch survived teardown, and deleting the manifest then
    removed the only thing that could still address it: the helper resolves names to pids
    through this file and nothing else. The result was a process nothing owned and the
    helper's own "off" could no longer stop.

    Detaching is the feature and is not changed here. What is fixed is the bookkeeping: the
    registry is now acted on before it is destroyed.

    Not a demo-blocker, and this is worth stating plainly because it was briefly claimed as
    one: startup clears leftover switches too (clear_switches_from_a_previous_run, called from
    main), so a leftover switch listed in the manifest never blocks the next run. This is
    hygiene -- ten idle bmv2 processes should not outlive the topology that owned them.

    2026-09-11: that sentence used to read "startup already runs `pkill -f simple_switch_grpc`",
    and it was true. It is not any more, and the difference matters to a reader of this
    docstring: startup now reaps the SAME registry this function does, so a switch missing from
    the manifest is no longer swept up by a name match at the next bring-up. It is reported
    instead -- which is why leaving the manifest in place on the paths below is load-bearing.

    Never raises. Teardown must go on to remove the manifest whatever happens here.
    """
    try:
        with open(path) as fh:
            manifest = json.load(fh)
    except (OSError, ValueError):
        # No manifest, or one we cannot parse. Nothing addressable either way.
        return []

    doomed = []
    for name, entry in sorted(manifest.items()):
        try:
            pid = entry.get("pid")
        except AttributeError:
            continue
        if pid and is_switch(pid):
            doomed.append((name, pid))

    for name, pid in doomed:
        try:
            kill(pid, signal.SIGTERM)
        except OSError:
            pass

    # One settle window for all of them rather than per switch: they shut down in parallel,
    # and ten sequential waits would make an interactive teardown feel hung.
    if doomed:
        time.sleep(settle_s)

    for name, pid in doomed:
        if is_switch(pid):
            try:
                kill(pid, signal.SIGKILL)
            except OSError:
                pass

    return [name for name, _ in doomed]


def grpc_port_is_open(port, host="127.0.0.1", timeout=0.3):
    """Whether anything is accepting TCP on this port right now. Same probe as
    BMv2Switch.grpc_is_listening, asked about a port rather than about a switch object."""
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def clear_switches_from_a_previous_run(manifest_path=MANIFEST_PATH, ports=(), reap=None,
                                      port_is_open=None, settle_s=0.5, report=print):
    """
    Stop the switches an earlier run left behind -- BY PID -- and report what could not be.

    [Co-developed with claude code -- Adam]
    This was `os.system('sudo pkill -f simple_switch_grpc > /dev/null 2>&1')`, here and in
    ntg_bmv2_topo.py, as root, on every bring-up. CLAUDE.md's engineering discipline names that
    exact form as forbidden and KNOWN-ISSUES G-9 and G-inst-2 are the two times the reason was
    learned the expensive way: `-f` matches the whole command line, so it takes any process
    whose argv merely mentions the string -- a sibling session's fabric, a tail of a log path,
    an editor with the file open -- and Mininet switches share the root PID namespace, so there
    is no blast wall between the ten. tools/p4_power_helper.py's header had already written the
    rule down for this same binary: "Processes are only ever addressed by PID taken from the
    manifest ... No pkill, no killall, no name matching -- in any code path." This was the code
    path that did it anyway.

    The pid was never missing information. write_manifest has recorded name -> pid for every
    verified switch since Phase 7; reap_manifest_switches signals exactly those pids and
    re-reads /proc/<pid>/cmdline first, so a recycled number is never signalled; and teardown
    has called it since the A-4 bookkeeping fix. Startup was simply not using any of it.

    What a name match did that a pid cannot: reach a switch with no manifest entry -- a manifest
    deleted by hand, or a run that predates it. That case is neither dropped nor guessed at. The
    gRPC ports this run needs are probed, and a port still held is REPORTED, together with the
    way to find its owner BY THAT PORT. The alternative is to choose a process by a substring of
    its argv and send it SIGTERM as root, which is the defect rather than the fallback.

    🔴 The manifest is deliberately NOT deleted here. reap_manifest_switches' own docstring is
    about that exact mistake: the file is the only thing that can still address a switch we
    failed to stop, so removing it after a refused kill would destroy the last handle on a
    process nothing owns. write_manifest replaces the whole file later in this run anyway, and
    stale entries are inert because process_is_a_switch re-checks every pid.

    Reports; it does not decide. This function's job ends at "these ports are still held, and
    here is how to find out by whom". What to DO about that is abort_if_grpc_ports_are_held,
    which both mains call on the second half of this function's return value.

    2026-09-12: that decision used to be "warn and go on", and it was written here, in this
    docstring, as a reason rather than as a choice. It is a choice, Adam ruled it, and it is now
    "refuse" -- see abort_if_grpc_ports_are_held for what the warn-and-continue path cost. The
    split is kept because the two halves fail differently: reporting must never raise (teardown
    and tests call it), and refusing must never happen anywhere except a main.

    Returns (reaped_names, ports_still_held). Never raises.
    """
    reap = reap or reap_manifest_switches
    port_is_open = port_is_open or grpc_port_is_open

    reaped = reap(manifest_path)
    if reaped:
        report("Reaped %d switch(es) from an earlier run by pid, out of %s: %s"
               % (len(reaped), manifest_path, ", ".join(reaped)))
        # One settle for the whole set: a port is released when the process exits, and the
        # probe below would otherwise read a switch that is still on its way out as a
        # stranger holding the port.
        if settle_s:
            time.sleep(settle_s)

    held = [port for port in ports if port_is_open(port)]
    if held:
        report("")
        report("WARNING: %d gRPC port(s) this run needs are still in use, and nothing in %s "
               "names their owner: %s"
               % (len(held), manifest_path, ", ".join(str(p) for p in held)))
        report("  This script will not choose a process to signal by matching its name, so it "
               "is leaving them alone. Find the owner by the port it is holding:")
        report("    sudo ss -ltnp \"sport = :%d\"" % held[0])
        report("  The switch on each of those ports would fail to bind. The caller decides "
               "what that is worth -- see abort_if_grpc_ports_are_held.")
        report("")
    return reaped, held


def port_owner_line(port, run=None):
    """
    The `ss -ltnp` line for whatever is listening on `port` right now, or None.

    [Co-developed with claude code -- Adam]
    Asked BY THE PORT, which is the whole distinction this file spent 2026-09-11 learning: a
    port is a fact about a socket the kernel owns, a name is a string the target process
    chose. `sport = :N` is a filter ss evaluates, not a pattern matched against argv, so this
    lookup cannot select the wrong process the way `pgrep -f` can -- and nothing is signalled
    on the strength of it either way; the line is printed at a human.

    None when the owner cannot be read, which is a real case rather than a failure: the
    process column needs privilege to name a process belonging to another user, and a machine
    without iproute2 has no `ss` at all. The caller must say "could not read" rather than
    treat an unnamed owner as an absent one -- the port is held in both cases.
    """
    run = run or _run_read_only
    try:
        rc, out = run(["ss", "-ltnp", "sport = :%d" % port])
    except (OSError, subprocess.SubprocessError):
        return None
    if rc != 0:
        return None
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith("State") or line.startswith("Netid"):
            continue
        return " ".join(line.split())
    return None


def _run_read_only(argv, timeout=3.0):
    """argv with a hard timeout and no shell. Returns (rc, stdout)."""
    p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout


def abort_if_grpc_ports_are_held(held, owner_of=None, report=print, exit_=sys.exit):
    """
    Refuse to build the fabric when a gRPC port this run needs is still held. Adam, 2026-09-12.

    [Co-developed with claude code -- Adam]
    The previous policy was to warn and go on, and the warning was accurate: BMv2Switch
    .failure_reason reads the switch's own log and names the port, and partial_fabric_verdict
    turns that into a non-zero verdict. Both still happen. What neither of them does is STOP,
    and continuing is what costs:

      * the fabric that gets built has fewer switches than the topology declares, and every
        number measured on it afterwards belongs to a population nobody wrote down. The 128-host
        rounds are the case that settles it -- one missing switch there is 16 hosts that never
        answer, and the run is over by the time the verdict is read;
      * "it was reported" is not "someone read it". The report arrives in the middle of
        Mininet's own output, after the operator has already started waiting.

    Held by WHOM is printed, not just which port: a refusal an operator cannot act on is a
    slower warning. The owner is read by port (port_owner_line) and never matched by name, and
    an owner that could not be read is said so -- an unreadable owner must not print like an
    absent one, and neither is a reason to start on a port that is demonstrably taken.

    Nothing is signalled here. This function has no kill seam, by construction: the fix that
    replaced `pkill -f simple_switch_grpc` cannot be allowed to grow one back in the function
    whose whole subject is a process it could not identify.

    Called only from a main -- `exit_` is injected so the tests observe the refusal instead of
    taking the interpreter down with them.
    """
    if not held:
        return
    owner_of = owner_of or port_owner_line
    report("")
    report("FATAL: %d gRPC port(s) this run needs are still held after the reset: %s"
           % (len(held), ", ".join(str(p) for p in held)))
    for port in held:
        line = owner_of(port)
        if line:
            report("  :%d is held by  %s" % (port, line))
        else:
            report("  :%d is held, and the owner could not be read here (naming another "
                   "user's process needs root, and a box without iproute2 has no ss at all)"
                   % port)
    report("  Check it yourself, and stop the owner by the pid that line names -- never by "
           "its name:")
    for port in held:
        report("      sudo ss -ltnp 'sport = :%d'" % port)
    report("  Refusing to start. A fabric built now would be missing the switch on each of "
           "those ports, and every measurement taken on it would belong to a topology that "
           "was never declared.")
    report("")
    exit_(1)


def main():
    setLogLevel('info')

    # Which app package, which model, which switches -- decided once, here, before anything is
    # torn down, and handed to MultiSwitchTopo below so the two cannot read different files.
    # A malformed knob or an unusable package stops the run here, which is the point: the
    # alternative is a fabric that comes up on the wrong topology and reports success.
    # [Co-developed with claude code -- Adam]
    try:
        package, model_path, model = fabric_model()
    except (app_package.AppPackageError, topo_from_json.TopologyModelError, ValueError) as e:
        print(f"Error: {e}")
        sys.exit(1)
    print(f"app package: {package.dir or 'baseline (no knob file)'}")
    print(f"topology model: {model_path}")
    dpids = [dpid for dpid, _ in topo_from_json.switches(model)]

    json_path = package.pipeline_for(
        1, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))[1]
    if not os.path.exists(json_path):
        print(f"Error: Compiled P4 JSON not found at {json_path}. Run 'p4c-bm2-ss' first in p4_src.")
        sys.exit(1)

    # Pre-flight the binary choice before anything is torn down: a broken override should
    # fail here, not after mn -c has already destroyed the running fabric.
    try:
        binary, lib_dir = resolve_bmv2_launcher()
    except ValueError as e:
        print(f"Error: {e}")
        sys.exit(1)
    print(f"bmv2 binary: {binary}" + (f"  (LD_LIBRARY_PATH={lib_dir})" if lib_dir else ""))

    # Pre-flight the gRPC port block, for the same reason and in the same place as the binary
    # check above: this must fail before `mn -c` tears down whatever is running, not after.
    # The block is checked against the *running kernel's* ephemeral range rather than against
    # the number that was safe when it was chosen -- ip_local_port_range is a sysctl, and the
    # demo machine is not necessarily this one. See grpc_ports.py and F-15.
    wanted_ports = grpc_ports.grpc_port_block(dpids)
    try:
        warning = grpc_ports.assert_port_block_is_safe(wanted_ports)
    except grpc_ports.PortBlockError as e:
        print(f"Error: {e}")
        sys.exit(1)
    if warning:
        print(warning)

    os.system('sudo mn -c > /dev/null 2>&1')
    # [Co-developed with claude code -- Adam]
    # `mn -c` does not touch bmv2, so a switch orphaned by a closed terminal keeps holding its
    # gRPC port and the matching switch in this run dies with "Address already in use". That
    # is a real failure we hit. Two Mininet topologies cannot coexist here anyway, and mn -c
    # above is already a full reset, so clearing these is consistent with what it does.
    #
    # By pid out of the manifest, and a report for anything that leaves. This line used to be
    # `os.system('sudo pkill -f simple_switch_grpc > /dev/null 2>&1')` -- see
    # clear_switches_from_a_previous_run for why that was the wrong instrument and why the pid
    # was available the whole time.
    _, still_held = clear_switches_from_a_previous_run(ports=wanted_ports)
    # And a port the reap could not free stops the run here, before Mininet is built. Adam
    # ruled that on 2026-09-12; the reasons are in abort_if_grpc_ports_are_held.
    abort_if_grpc_ports_are_held(still_held)
    time.sleep(0.5)  # let the ports actually be released before anything tries to bind

    topo = MultiSwitchTopo(package=package, model=model)
    net = Mininet(topo=topo, controller=None, autoSetMacs=True)
    net.start()

    # The hosts, named by the model rather than counted. `_host_count_override()` and the model
    # agree by construction (topo_from_json.model_path refuses a model whose host count differs),
    # but a package names its own model and nothing then ties the count file to it.
    # [Co-developed with claude code -- Adam]
    hosts = [net.get(name) for name, _ip, _mac in topo_from_json.hosts(model)]

    host_commands = package.host_commands()
    if host_commands is None:
        # Add static ARPs.
        #
        # This was `range(1, 5)`: hard-coded to four hosts, like the two other four-host lists
        # this fabric carried (the proxy's add_host table, and disable_host_offloads below).
        # At 128 hosts the switches forward correctly and every rule installs, but nothing pings,
        # because the sender never resolves the destination MAC -- and an unreachable host looks
        # exactly like a broken data plane. Measured: with the entry added by hand for one pair,
        # h1 -> h33 goes from 100% loss to 0% at 1.6 ms.
        #
        # One batched invocation per host rather than one per pair: at 128 hosts the pairwise
        # form is 16256 separate `cmd()` round-trips through Mininet and takes minutes; batching
        # makes it 128. Behaviour at 4 hosts is unchanged.
        for src in hosts:
            entries = " ; ".join(
                f"arp -s {dst.IP()} {dst.MAC()}" for dst in hosts if dst is not src
            )
            if entries:
                src.cmd(entries)
    else:
        # [Co-developed with claude code -- Adam]
        # A package brings its own host setup -- pod-topo's hosts each get a default gateway and
        # ONE static ARP, for that gateway -- and the all-pairs fan-out above would defeat it:
        # every host would already hold every other host's MAC, so the exercise's forwarding
        # tables would never be consulted and a broken data plane would ping perfectly.
        #
        # Printed per host rather than run silently. These are the only commands this fabric runs
        # on somebody else's behalf, and a typo in one of them presents as an unreachable host.
        for host in hosts:
            for command in host_commands.get(host.name, ()):
                info(f"*** {host.name}: {command}\n")
                host.cmd(command)

    disable_host_offloads(hosts)

    switches = [net.get(name) for _dpid, name in topo_from_json.switches(model)]
    failures = verify_switches(switches)
    write_manifest(switches)

    fatal, report = partial_fabric_verdict(failures, len(switches))
    ports = grpc_ports.grpc_port_block(dpids)

    print("\n======================================================================")
    if report:
        # Reported as a failure rather than the old unconditional success line. A dead switch
        # used to be completely silent here: its bind error went to /tmp/sN_bmv2.log, which
        # nothing read, and this banner claimed all ten were listening anyway. The proxy then
        # failed only on that one switch, tens of lines deep in its own log.
        print(report)
    else:
        print("Multi-Switch Network Started.")
        print(f"All {len(switches)} BMv2 switches verified listening on gRPC "
              f"{ports[0]} ~ {ports[-1]}")
        print(f"Switch manifest: {MANIFEST_PATH}")
    print("======================================================================\n")

    if fatal:
        # Refuse the CLI rather than printing a warning above it. The warning was there before
        # and it did not stop a single run: the operator got a prompt, the wrapper got exit 0,
        # and the partial fabric was used. The switch logs stay on disk (/tmp/sN_bmv2.log) for
        # the post-mortem -- what is withheld is the ability to carry on as if nothing broke.
        net.stop()
        reap_manifest_switches()
        try:
            os.remove(MANIFEST_PATH)
        except OSError:
            pass
        sys.exit(1)

    CLI(net)
    net.stop()
    # Before the manifest goes: net.stop() does not reap a switch the power helper restarted,
    # and once this file is gone nothing can address one. See reap_manifest_switches.
    reaped = reap_manifest_switches()
    if reaped:
        print(f"Reaped {len(reaped)} switch(es) that outlived the topology: "
              f"{', '.join(reaped)}")
    try:
        os.remove(MANIFEST_PATH)
    except OSError:
        pass

if __name__ == '__main__':
    main()

# Developed in collaboration with Gemini 3.1 Pro.
