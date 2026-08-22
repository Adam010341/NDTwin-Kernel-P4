#!/usr/bin/env python3

import glob
import json
import os
import signal
import socket
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


HOST_COUNT_OVERRIDE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "host_count_override")


SETTING_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), "setting")


def _mac_str(mac, name):
    """The model stores a host MAC as an integer; Mininet wants the colon form.

    [Co-developed with claude code -- Adam]
    Falls back to deriving it from the host index when the model has no MAC, which is what
    the formula this replaced did. Note the old formula was `00:00:00:00:00:{i:02x}` and
    produced an invalid 7-digit address at i >= 256; formatting the integer as a 48-bit
    address is correct there instead. Nothing has ever run at that size.
    """
    try:
        value = int(mac)
    except (TypeError, ValueError):
        value = 0
    if value <= 0:
        value = int(name[1:]) if name[1:].isdigit() else 0
    return ":".join(f"{(value >> shift) & 0xFF:02x}" for shift in (40, 32, 24, 16, 8, 0))


def _topology_model_path(host_num):
    """The P4 model with this many hosts -- the same rule `ndt up` uses to pick one.

    [Co-developed with claude code -- Adam]
    Refuses rather than guessing: building a fabric the twin has no model for is the exact
    failure this reader exists to prevent, so an unmatched host count must stop the run
    instead of falling back to some other file.
    """
    override = os.environ.get("NDTWIN_P4_TOPO_FILE")
    if override:
        if not os.path.exists(override):
            raise topo_from_json.TopologyModelError(
                f"NDTWIN_P4_TOPO_FILE={override} does not exist")
        # [Co-developed with claude code -- Adam]
        # The override is checked against the host count too, not trusted on sight. It used to
        # return here immediately -- which made the docstring above a lie, and produced exactly
        # the mismatch this function exists to prevent: an override naming the 4-host model with
        # host_count_override at 128 built a 4-host fabric while the kernel was handed the
        # 128-host model, silently. Found by review, 2026-08-21.
        #
        # An explicit override still wins over the *scan*; what it cannot do is disagree with the
        # host count the rest of the run is using, because both sides read that count separately.
        try:
            declared = len(topo_from_json.hosts(topo_from_json.load(override)))
        except (OSError, ValueError, KeyError) as exc:
            raise topo_from_json.TopologyModelError(
                f"NDTWIN_P4_TOPO_FILE={override} is not a usable topology model: {exc}") from exc
        if declared != host_num:
            raise topo_from_json.TopologyModelError(
                f"NDTWIN_P4_TOPO_FILE={override} declares {declared} hosts but this run wants "
                f"{host_num} (from NDTWIN_P4_HOST_NUM or host_count_override). Point them at the "
                f"same size: the fabric would be built from the model while everything else "
                f"sizes itself from the count.")
        return override
    candidates = sorted(glob.glob(os.path.join(SETTING_DIR, "StaticNetworkTopologyP4_*.json")))
    unreadable = []
    for path in candidates:
        try:
            if len(topo_from_json.hosts(topo_from_json.load(path))) == host_num:
                return path
        except (ValueError, KeyError) as exc:
            # Skipped, but counted: "no model has N hosts" reads as "you need to derive one",
            # which is the wrong instruction when the right model is sitting there unparseable.
            unreadable.append(f"{os.path.basename(path)} ({exc.__class__.__name__})")
    detail = f"; {len(unreadable)} could not be read: {', '.join(unreadable)}" if unreadable else ""
    raise topo_from_json.TopologyModelError(
        f"no P4 topology model in {SETTING_DIR} has {host_num} hosts "
        f"(looked at {len(candidates)}){detail}. Derive one with "
        f"tools/test_workflow/derive_p4_topology_json.py before building this fabric")


def _host_count_override(path=None):
    """How many hosts this fabric builds. Default 4; one directive line to change it.

    Same shape as the bmv2 binary override next to it: first non-comment, non-blank line
    wins, blank lines and #-comments ignored, and a malformed file is refused loudly rather
    than silently falling back -- a run that quietly built the wrong number of hosts would
    look exactly like a successful one.

    [Co-developed with claude code -- Adam]
    """
    path = path or HOST_COUNT_OVERRIDE_PATH
    if not os.path.exists(path):
        return 4
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if not line.isdigit():
                raise ValueError(f"{path}: expected a host count, got {line!r}")
            return int(line)
    return 4


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
    def __init__(self, name, json_path=None, device_id=1, grpc_port=50051, thrift_port=9090, **kwargs):
        Switch.__init__(self, name, **kwargs)
        self.json_path = json_path
        self.device_id = device_id
        self.grpc_port = grpc_port
        self.thrift_port = thrift_port
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
        args.append('255')

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
    def __init__(self, **opts):
        Topo.__init__(self, **opts)
        
        json_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../p4_src/build/ndtwin_switch.json')
        
        # Add 10 switches
        switches = {}
        for i in range(1, 11):
            s_name = f's{i}'
            # grpc_port: 50051-50060, thrift_port: 9091-9100, device_id: 1-10
            s = self.addSwitch(s_name, cls=BMv2Switch, json_path=json_path, 
                               device_id=i, grpc_port=50050+i, thrift_port=9090+i)
            switches[i] = s

        # Which model to build from. The host count still selects it -- that is the one knob
        # the lab wrapper can deliver (see _host_count_override) -- but everything else about
        # the fabric now comes out of the model itself.
        HOST_NUM_FOR_MODEL = int(os.environ.get("NDTWIN_P4_HOST_NUM", "0")) or _host_count_override()

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
        model_path = _topology_model_path(HOST_NUM_FOR_MODEL)
        model = topo_from_json.load(model_path)
        info(f"*** topology model: {model_path}\n")

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
        for name, ip, mac in topo_from_json.hosts(model):
            self.addHost(name, ip=f"{ip}/24", mac=_mac_str(mac, name))

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
    one: startup already runs `pkill -f simple_switch_grpc` (see main), so a leftover switch
    never blocks the next run. This is hygiene -- ten idle bmv2 processes should not outlive
    the topology that owned them.

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


def main():
    setLogLevel('info')
    
    json_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../p4_src/build/ndtwin_switch.json')
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

    os.system('sudo mn -c > /dev/null 2>&1')
    # [Co-developed with claude code -- Adam]
    # `mn -c` does not touch bmv2, so a switch orphaned by a closed terminal keeps holding its
    # gRPC port and the matching switch in this run dies with "Address already in use". That
    # is a real failure we hit. Two Mininet topologies cannot coexist here anyway, and mn -c
    # above is already a full reset, so clearing these is consistent with what it does.
    os.system('sudo pkill -f simple_switch_grpc > /dev/null 2>&1')
    time.sleep(0.5)  # let the ports actually be released before anything tries to bind

    topo = MultiSwitchTopo()
    net = Mininet(topo=topo, controller=None, autoSetMacs=True)
    net.start()
    
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
    hosts = [net.get(f'h{i}') for i in range(1, _host_count_override() + 1)]
    for src in hosts:
        entries = " ; ".join(
            f"arp -s {dst.IP()} {dst.MAC()}" for dst in hosts if dst is not src
        )
        if entries:
            src.cmd(entries)

    disable_host_offloads(hosts)

    switches = [net.get(f's{i}') for i in range(1, 11)]
    failures = verify_switches(switches)
    write_manifest(switches)

    print("\n======================================================================")
    if failures:
        # Reported as a failure rather than the old unconditional success line. A dead switch
        # used to be completely silent here: its bind error went to /tmp/sN_bmv2.log, which
        # nothing read, and this banner claimed all ten were listening anyway. The proxy then
        # failed only on that one switch, tens of lines deep in its own log.
        print(f"WARNING: {len(failures)} of {len(switches)} BMv2 switches did NOT come up.")
        for name, reason in failures:
            print(f"  {name}: {reason}")
        alive = len(switches) - len(failures)
        print(f"\n{alive}/{len(switches)} switches are usable. The P4 proxy expects all "
              f"{len(switches)} and will report errors for the rest.")
        print("Fix the cause and restart this script rather than continuing.")
    else:
        print("Multi-Switch Network Started.")
        print(f"All {len(switches)} BMv2 switches verified listening on gRPC 50051 ~ 50060")
        print(f"Switch manifest: {MANIFEST_PATH}")
    print("======================================================================\n")

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
