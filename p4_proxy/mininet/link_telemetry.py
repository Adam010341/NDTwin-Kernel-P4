#!/usr/bin/env python3
"""Link-level telemetry: which veth gets a sampling filter, and what that filter is.

[Co-developed with claude code -- Adam]

TICKET-P3 sections 2.1, 2.2 and 2.5. The cooperative path NDTwin has always used needs the
`.p4` program's cooperation -- a clone session, a CPU port, a `packet_in` header -- so an
arbitrary user program produces no telemetry at all. This is the other path: the kernel samples
on the switch-side veth with `tc ... action sample`, which needs nothing from the program, and
a root emitter turns those psample notifications into the same sFlow the kernel already parses.

WHAT THIS MODULE IS. It decides and it records; it runs `tc` only through the `run` callable it
is handed, and it opens no socket at all. That is what lets the whole of it be tested offline:
`plan()` is a pure function of the package, the model and the switch objects, `attach()`'s
output is a list of argv the test reads word for word, and `write_manifest()` produces the file
the emitter and `ndt status` both read.

🔴 THE FOUR MEASURED FACTS THE SHAPE COMES FROM (doc/audit/2026-09-04_p4-tutorial-exercise-prep/
spike-tc-sample/, run live 2026-09-17):

  1. psample notifications are multicast to the netns that owns the group, so THE EMITTER MUST
     RUN IN THE SAME NETWORK NAMESPACE AS THE SAMPLED INTERFACE. Mininet switches are created
     with `inNamespace=False`, so every switch-side veth is in the root netns and one emitter
     covers the whole fabric -- but that is a property of how the fabric is built, not a law,
     so `plan()` verifies it per switch and refuses rather than producing a listener that
     would sit in silence and look like "no traffic".
  2. `PSAMPLE_ATTR_IIFINDEX`/`OIFINDEX` are written with `nla_put_u16()`. They are SIXTEEN BITS.
     An ifindex above 65535 cannot be represented, so the veth -> (dpid, port) map is keyed on
     `ifindex & 0xFFFF` and two interfaces that collide in those sixteen bits are a REFUSAL:
     silently picking one of them would attribute a whole switch's traffic to another's port.
  3. An ingress filter emits IIFINDEX and no OIFINDEX; an egress filter emits OIFINDEX and no
     IIFINDEX. That is what tells the emitter which direction a sample is, and it is why one
     psample group serves the whole fabric.
  4. Joining the psample multicast group needs CAP_NET_ADMIN. The emitter is started by the
     topology script, which already runs as root under `sudo ndtwin-lab topo-start`.
"""
from __future__ import annotations

import errno
import json
import math
import os
import signal
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from typing import Tuple

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import app_package  # noqa: E402
import topo_from_json  # noqa: E402

#: Where the emitter's pid, the port map and the `tc` command lines are written. Read by the
#: emitter (`--manifest`), by `ndt status`/`verify_p4`, by the proxy's `switch_state`
#: disclosure, and by this module's own teardown -- which is why teardown needs no argument
#: threaded through two mains and their abort paths.
LINK_TELEMETRY_MANIFEST = "/tmp/ndtwin_link_telemetry.json"

#: 1-in-256, the rate compiled into `ndtwin_switch.json` for the cooperative path. The same
#: number on both paths is what makes the three telemetry arms of the section 2.8 measurement
#: comparable: a link arm sampling at a different rate would differ from the cooperative arm in
#: two ways at once.
LINK_SAMPLE_RATE = 256

#: `trunc 128` -- the bytes of each sampled frame the kernel copies up. Matches
#: sflow_emitter.DEFAULT_MAX_HEADER_BYTES and OVS's `header=128`: the twin reads the 5-tuple
#: out of the first ~40 bytes, and a truncation the collector does not expect would change the
#: datagram sizes the L4 differential compares.
LINK_SAMPLE_TRUNC = 128

#: The psample group every filter reports into. One group for the fabric, because direction
#: already arrives in the attribute the kernel chose (fact 3 above) and a per-port group would
#: be a second encoding of something that cannot then disagree with itself. A sample from
#: somebody else's filter that happened to use this group carries an ifindex this fabric's map
#: does not hold, and is dropped and COUNTED rather than attributed.
LINK_SAMPLE_GROUP = 27

#: The sixteen bits of fact 2, as a mask and as a width the manifest states out loud.
IFINDEX_MASK = 0xFFFF
IFINDEX_WIDTH_BITS = 16

#: Where the synthesised sFlow goes, and who it says it is. The proxy's cooperative emitter is
#: sub-agent 0; this one is 1, so a datagram's origin is readable when both are in play on one
#: fabric (they never are on one SWITCH -- section 2.1's exclusivity -- but a mixed fabric runs
#: both at once).
LINK_COLLECTOR = ("127.0.0.1", 6343)
LINK_SUB_AGENT_ID = 1

#: The emitter this module starts, next to this file.
EMITTER_PATH = os.path.join(_HERE, "psample_sflow_emitter.py")

#: Where the emitter's own output goes. Beside the switches' `/tmp/sN_bmv2.log`, and for a
#: reason that is not filing.
#:
#: 🔴 THE EMITTER MUST NOT INHERIT THE TOPOLOGY'S DESCRIPTORS. `ntg_bmv2_topo.py` runs under
#: `topo_log.Tee`, which is an FD-LEVEL tee: `os.dup2` puts a pipe on fds 1 and 2 and a pump
#: thread drains it. `Tee.stop()` -- called before NTG's prompt, because prompt_toolkit renders
#: as plain text into a pipe -- ends that pump by putting the real descriptors back and letting
#: the LAST write end go, and its own comment states the invariant that makes this work: "this
#: process owns them all -- Mininet gives its node shells their own pipes and bmv2 is launched
#: with `> /tmp/sN_bmv2.log 2>&1`". A child of ours holding fd 2 would be a fourth owner: the
#: pump would never see EOF, `stop()` would burn its whole five-second join on every bring-up,
#: and the emitter's statistics line would keep arriving on the operator's NTG prompt every ten
#: seconds for the life of the fabric. So the emitter is launched the way bmv2 is, onto its own
#: file -- which is also the file the orchestrator tails to read those statistics.
LINK_TELEMETRY_LOG = "/tmp/ndtwin_link_telemetry.log"

#: How long the emitter gets to fall over before the bring-up calls it fatal, and how long a
#: SIGTERMed one gets before SIGKILL. Section 2.5.
EMITTER_STARTUP_GRACE_S = 3.0
EMITTER_STOP_GRACE_S = 5.0

#: How often a SIGTERMed emitter is asked whether it has gone. Same step as the start-up
#: grace loop in `p4_testbed_topo`, and a named constant so both loops' trip counts are
#: arithmetic rather than float subtraction.
EMITTER_POLL_INTERVAL_S = 0.1


class LinkTelemetryError(ValueError):
    """A refusal.

    ValueError because that is the class both mains already funnel malformed-input failures
    through -- `AppPackageError`, `TopologyModelError` and `PortBlockError` are all ValueErrors
    and both mains catch exactly that around `plan_fabric`.

    🔴 WHAT THAT DOES **NOT** BUY, and the first version of this docstring claimed it did:
    `bring_up` is NOT inside either main's `except ValueError`, and by the time this class is
    raised from there the net has been built and started. A bare raise out of `bring_up` would
    go past a `tear_down` that is only ever reached through the `fatal` return, leaving a
    running fabric, no manifest, and whatever filters got attached. So
    `p4_testbed_topo.start_link_telemetry` catches ValueError itself and returns it as a fatal
    verdict; being a ValueError is what makes that catch narrow enough to be honest, not a
    teardown somebody else performs.
    """


@dataclass(frozen=True)
class PortPlan:
    """One switch port, and which way it is sampled."""

    port: int
    ifname: str
    ifindex: int
    #: `ifindex & 0xFFFF` -- what psample will actually report. The map is keyed on this.
    key: int
    ingress: bool
    egress: bool


@dataclass(frozen=True)
class SwitchPlan:
    dpid: int
    name: str
    agent_ip: str
    ports: Tuple[PortPlan, ...]


@dataclass(frozen=True)
class LinkTelemetryPlan:
    """Everything the bring-up, the emitter and the teardown need, decided once."""

    switches: Tuple[SwitchPlan, ...] = ()
    rate: int = LINK_SAMPLE_RATE
    trunc: int = LINK_SAMPLE_TRUNC
    group: int = LINK_SAMPLE_GROUP
    ifindex_width: int = IFINDEX_WIDTH_BITS
    collector: Tuple[str, int] = LINK_COLLECTOR
    sub_agent_id: int = LINK_SUB_AGENT_ID
    #: The `tc` argv `attach()` will run, in order. Recorded on the plan rather than composed
    #: inside `attach()` so a test can read the commands without running anything, and so the
    #: manifest can state what was actually installed.
    commands: Tuple[Tuple[str, ...], ...] = ()
    #: Why there is no link telemetry, when there is none. A sentence, for the bring-up line.
    reason: str = ""
    #: {dpid: resolved source}, every switch in the fabric -- including the ones this plan does
    #: nothing for. The bring-up prints it and `ndt`/the proxy cross-check against it.
    sources: Tuple[Tuple[int, str], ...] = ()

    @property
    def is_empty(self) -> bool:
        return not self.switches

    def ingress_filters(self) -> int:
        return sum(1 for s in self.switches for p in s.ports if p.ingress)

    def egress_filters(self) -> int:
        return sum(1 for s in self.switches for p in s.ports if p.egress)

    def interfaces(self):
        """Every sampled interface, in plan order. One `clsact` qdisc each."""
        return [p.ifname for s in self.switches for p in s.ports]


def switch_agent_ips(model) -> dict:
    """{dpid: agent IP} out of an already-loaded topology model.

    The same rule `sflow_emitter.load_switch_agent_ips` applies to the kernel's topology FILE:
    a switch node's first address is the agent address, because that is the one the kernel
    looks samples up by (AgentKey{agentIP, port}). Over the model the fabric already holds
    rather than over the file, because the fabric was built from this object and re-reading the
    file is how two readers come to hold two answers.
    """
    agents = {}
    for node in model.get("nodes", []) or []:
        if not node or node.get("vertex_type") != topo_from_json.SWITCH:
            continue
        dpid, addresses = node.get("dpid"), node.get("ip") or []
        if not dpid or not addresses:
            continue
        agents[int(dpid)] = addresses[0]
    return agents


def read_ifindex(ifname, sys_root="/sys/class/net"):
    """This interface's ifindex, from sysfs. Injectable because a unit test has no veth."""
    path = os.path.join(sys_root, ifname, "ifindex")
    try:
        with open(path) as fh:
            return int(fh.read().strip())
    except (OSError, ValueError) as exc:
        raise LinkTelemetryError(
            f"cannot read {path}: {exc}. The sampling filter is addressed by interface and the "
            f"emitter maps samples back by ifindex, so an interface neither of them can name "
            f"would sample into nothing") from exc


def plan(package, model, switches, knob_path=None, ifindex_of=None, base_dir=None):
    """Which switches sample on the link path, on which ports, and with what `tc`.

    `switches` are the live Mininet switch nodes -- this reads `device_id`, `name`, `intfs` and
    `inNamespace` off them and touches nothing. Returns a LinkTelemetryPlan whose `switches` is
    empty when no switch resolves to `link`; `reason` then says why, in one sentence, for the
    bring-up line.

    Raises LinkTelemetryError for the four things that would otherwise produce a listener that
    sits in silence: a switch in its own netns, an interface whose ifindex cannot be read, two
    interfaces that alias in psample's sixteen bits, and a `link` switch the model gives no
    agent address.
    """
    # Resolved here, not bound at def time: the module attribute is the seam the offline
    # suites replace (a unit test has no veth to read an ifindex off), exactly as
    # `resolve_bmv2_launcher` resolves its override path at call time.
    ifindex_of = ifindex_of or read_ifindex
    agents = switch_agent_ips(model)
    host_facing = {(dpid, port) for _name, dpid, port in topo_from_json.host_links(model)}
    ports_of = {}
    for a_dpid, a_port, b_dpid, b_port in topo_from_json.switch_links(model):
        ports_of.setdefault(a_dpid, set()).add(a_port)
        ports_of.setdefault(b_dpid, set()).add(b_port)
    for _name, dpid, port in topo_from_json.host_links(model):
        ports_of.setdefault(dpid, set()).add(port)

    sources = []
    planned = []
    by_key = {}
    for switch in switches:
        dpid = int(getattr(switch, "device_id", 0) or 0)
        source = app_package.telemetry_source(package, dpid, knob_path=knob_path,
                                              base_dir=base_dir)
        sources.append((dpid, source))
        if source != app_package.TELEMETRY_LINK:
            continue

        # 🔴 FACT 1. `inNamespace` is False for every switch Mininet's `addSwitch` makes, and
        # this fabric has never made one any other way -- so this check has never fired and is
        # here for the day it would: a switch in its own netns puts its veth's psample group in
        # that netns, the root emitter joins the root one, and the result is a fabric that
        # brings up clean and reports zero link usage forever.
        if getattr(switch, "inNamespace", False):
            raise LinkTelemetryError(
                f"switch {switch.name} (dpid {dpid}) is in its own network namespace, and "
                f"psample notifications are multicast only to the namespace that owns the "
                f"group -- one root emitter cannot hear it. Link telemetry needs switches in "
                f"the root namespace, which is what mininet's addSwitch builds by default")

        agent_ip = agents.get(dpid)
        if not agent_ip:
            raise LinkTelemetryError(
                f"switch {switch.name} (dpid {dpid}) runs link telemetry but the topology "
                f"model gives it no address. The kernel attributes a sample by "
                f"AgentKey{{agentIP, port}}, so samples from it would arrive and be attributed "
                f"to nothing")

        intfs = getattr(switch, "intfs", {}) or {}
        ports = []
        for port in sorted(ports_of.get(dpid, ())):
            intf = intfs.get(port)
            if intf is None:
                raise LinkTelemetryError(
                    f"the model gives {switch.name} (dpid {dpid}) a port {port} that the built "
                    f"switch has no interface for; a filter cannot be attached to a device "
                    f"that is not there")
            ifname = intf.name
            ifindex = ifindex_of(ifname)
            key = ifindex & IFINDEX_MASK
            # 🔴 FACT 2. Refused, not resolved: whichever of the two aliases won, every sample
            # from the other would be booked against it -- one switch's traffic on another
            # switch's port, with nothing anywhere saying so.
            if key in by_key and by_key[key] != ifname:
                raise LinkTelemetryError(
                    f"{ifname} (ifindex {ifindex}) and {by_key[key]} collide in the low "
                    f"{IFINDEX_WIDTH_BITS} bits psample reports (both {key}); every sample "
                    f"from one would be attributed to the other's port")
            by_key[key] = ifname
            ports.append(PortPlan(port=port, ifname=ifname, ifindex=ifindex, key=key,
                                  ingress=True, egress=(dpid, port) in host_facing))
        planned.append(SwitchPlan(dpid=dpid, name=switch.name, agent_ip=agent_ip,
                                  ports=tuple(ports)))

    if not planned:
        counts = {}
        for _dpid, source in sources:
            counts[source] = counts.get(source, 0) + 1
        reason = ("no switch is on the link path (" +
                  ", ".join(f"{n} {s}" for s, n in sorted(counts.items())) + ")"
                  if counts else "this fabric declares no switches")
        return LinkTelemetryPlan(reason=reason, sources=tuple(sources))

    return LinkTelemetryPlan(switches=tuple(planned), commands=_commands(planned),
                             sources=tuple(sources))


def _commands(planned):
    """The `tc` argv, in the order they must run: the qdisc, then that interface's filters.

    🔴 EVERY PORT GETS AN INGRESS FILTER; ONLY A HOST-FACING PORT GETS AN EGRESS ONE, and that
    asymmetry is the whole of section 2.2. The kernel credits a link from the RECEIVING
    switch's ingress samples (FlowLinkUsageCollector's drain resolves `(agent, inputPort)` to
    the edge "other side -> here"), so switch->switch and host->switch links are already
    covered by ingress alone. The one direction with no receiving switch is switch->host, and
    it is paid for out of the egress bank -- which only ever gets an entry from a sample whose
    inputPort is 0. An egress filter on every port would double-count every inter-switch link.
    """
    out = []
    for switch in planned:
        for port in switch.ports:
            out.append(("tc", "qdisc", "add", "dev", port.ifname, "clsact"))
            for direction, wanted in (("ingress", port.ingress), ("egress", port.egress)):
                if not wanted:
                    continue
                out.append(("tc", "filter", "add", "dev", port.ifname, direction,
                            "matchall", "action", "sample",
                            "rate", str(LINK_SAMPLE_RATE),
                            "group", str(LINK_SAMPLE_GROUP),
                            "trunc", str(LINK_SAMPLE_TRUNC)))
    return tuple(out)


def detach_commands(interfaces):
    """`tc qdisc del ... clsact` per interface: removing the qdisc removes its filters."""
    return tuple(("tc", "qdisc", "del", "dev", name, "clsact") for name in interfaces)


def attach(plan, run=None):
    """Run the plan's `tc` commands. Returns the ones that were run.

    `run` is `subprocess.run`'s shape and is always injected by the tests -- this module never
    imports a default that could execute during one.
    """
    run = run or subprocess.run
    for argv in plan.commands:
        result = run(list(argv), check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        rc = getattr(result, "returncode", 0)
        if rc:
            stderr = getattr(result, "stderr", b"") or b""
            if isinstance(stderr, bytes):
                stderr = stderr.decode(errors="replace")
            raise LinkTelemetryError(
                f"`{' '.join(argv)}` failed (rc {rc}): {stderr.strip()}. A fabric with some of "
                f"its filters attached measures part of itself and reports the rest as zero")
    return plan.commands


def detach(plan_or_interfaces, run=None, report=None):
    """Remove every clsact qdisc this plan installed. Failures are reported, never raised.

    Teardown is the one path that must not be stoppable by a device that has already gone:
    `net.stop()` deletes the veths, and a teardown that raised on the first missing one would
    leave the rest of the fabric's qdiscs -- and the manifest -- behind.
    """
    run = run or subprocess.run
    interfaces = (plan_or_interfaces.interfaces()
                  if hasattr(plan_or_interfaces, "interfaces") else list(plan_or_interfaces))
    removed = []
    for argv in detach_commands(interfaces):
        try:
            result = run(list(argv), check=False, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE)
        except OSError as exc:
            if report:
                report(f"link telemetry: could not run `{' '.join(argv)}`: {exc}")
            continue
        if getattr(result, "returncode", 0) == 0:
            removed.append(argv[4])
    return removed


def manifest_document(plan, emitter_pid, log_path=None, identity=None):
    """What `write_manifest` writes. Separated so a test can read it without a filesystem.

    [Co-developed with claude code -- Adam]
    `argv` and `start_time` are `emitter_identity`'s, and are what makes `pid` mean ONE process
    rather than whichever holds that number (`process_is_the_emitter`). Always present, null
    when not known, so the document has one shape for every reader.
    """
    identity = identity or {}
    return {
        "pid": emitter_pid,
        "argv": identity.get("argv"),
        "start_time": identity.get("start_time"),
        "log": log_path or LINK_TELEMETRY_LOG,
        "rate": plan.rate,
        "trunc": plan.trunc,
        "group": plan.group,
        "ifindex_width": plan.ifindex_width,
        "collector": list(plan.collector),
        "sub_agent_id": plan.sub_agent_id,
        "switches": [
            {
                "dpid": s.dpid,
                "name": s.name,
                "agent_ip": s.agent_ip,
                "ports": {
                    str(p.port): {"ifname": p.ifname, "ifindex": p.ifindex, "key": p.key,
                                  "ingress": p.ingress, "egress": p.egress}
                    for p in s.ports
                },
            }
            for s in plan.switches
        ],
        "tc_commands": [list(argv) for argv in plan.commands],
    }


def write_manifest(plan, emitter_pid, path=None, log_path=None, identity=None):
    """Record the emitter's pid, its identity and the port map where every reader can find them.

    Replace the inode, never truncate in place -- the same reasoning as the switch manifest
    next door: /tmp is sticky, anyone can create this NAME before we run, and `open(path, "w")`
    as root would truncate their file and leave them owning a document that names a pid this
    fabric's teardown then signals.

    [Co-developed with claude code -- Adam]
    🔴 A MANIFEST THAT COULD NOT BE WRITTEN IS A REFUSAL, NOT A WARNING. Without it the emitter
    (which waits for it) has no port map, the teardown has no pid to stop, and whatever is at
    the name instead -- a directory, or a file someone else put there -- is what every reader
    finds. Raised as LinkTelemetryError, which `start_link_telemetry` turns into the same fatal
    verdict as an emitter that died.
    """
    path = path or LINK_TELEMETRY_MANIFEST
    document = manifest_document(plan, emitter_pid, log_path=log_path, identity=identity)
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".",
                                   prefix=".ndtwin_link_telemetry.")
        try:
            with os.fdopen(fd, "w") as fh:
                json.dump(document, fh, indent=2)
            os.chmod(tmp, 0o644)
            os.replace(tmp, path)
        except OSError:
            os.unlink(tmp)
            raise
    except OSError as e:
        raise LinkTelemetryError(
            f"could not write the link telemetry manifest to {path}: {e}. The emitter reads its "
            f"port map from it and the teardown finds the emitter through it, so a link fabric "
            f"without it measures nothing and cannot be stopped cleanly") from e
    return document


#: How the manifest's owner and mode are read: `os.fstat` of the descriptor `load_manifest`
#: opened, never a second lookup of the path. A module attribute so a suite with no root can put
#: a different owner in front of the check -- `chown` to another uid is not something a test
#: can do -- resolved at call time for that reason. [Co-developed with claude code -- Adam]
_fstat = os.fstat


def manifest_distrust(st, euid):
    """Why a manifest with this stat must not be acted on, or None when it may be.

    [Co-developed with claude code -- Adam]
    🔴 THE MANIFEST DECIDES WHAT ROOT SIGNALS (judge KJL B2, 2026-09-27). It lives in /tmp,
    which is world-writable and sticky, and the name is free whenever no fabric is up -- so any
    local user can create it before the next bring-up, and `reset_for_bring_up` reads it as
    root and SIGTERMs, then SIGKILLs, the pid it names (and runs `tc qdisc del` on every
    interface it lists). Only a document this process's own user or root wrote is one to act
    on: a regular file, owned by root or by the euid reading it, writable by nobody else.
    `write_manifest` produces exactly that (root, 0644); `ndt` and the proxy, running as the
    lab user, read a root-owned file and accept it too.
    """
    if not stat.S_ISREG(st.st_mode):
        return "it is not a regular file"
    if st.st_uid not in (0, euid):
        return (f"it is owned by uid {st.st_uid}, and only a manifest written by root or by "
                f"this process's own user (uid {euid}) is acted on")
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        return (f"it is writable by its group or by others (mode "
                f"{stat.S_IMODE(st.st_mode):04o}), so its contents are not its owner's")
    # The file `write_manifest` creates has exactly one name. A second one is a hard link
    # somebody made to an inode they do not own -- which only `fs.protected_hardlinks` would
    # otherwise stop -- and a root-owned JSON object reached that way is not this manifest.
    if st.st_nlink != 1:
        return (f"it has {st.st_nlink} hard links, and the file written for it has exactly one")
    return None


def load_manifest(path=None):
    """(document, problem): the manifest as a dict, or None and the reason it cannot be used.

    [Co-developed with claude code -- Adam]
    Absent is (None, None): no manifest is the ordinary state of a cooperative fabric. Every
    other None comes with a sentence -- a symlink, a file of the wrong owner or mode
    (`manifest_distrust`), one that does not parse -- and the caller that would have acted on
    it says that sentence rather than acting (judge KJL B2).

    Opened with O_NOFOLLOW, so a symlink planted at the name is refused rather than followed to
    whatever it points at; with O_NONBLOCK, so a FIFO planted there cannot hang a teardown on
    open; and the owner and mode are those of the DESCRIPTOR (`_fstat`), so the file checked is
    the file read -- no second lookup of the path for anything to swap in between.
    """
    path = path or LINK_TELEMETRY_MANIFEST
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except FileNotFoundError:
        return None, None
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            return None, f"{path} is a symbolic link, and a link at this name is never followed"
        return None, f"{path} cannot be opened: {exc}"
    try:
        why = manifest_distrust(_fstat(fd), os.geteuid())
        if why:
            return None, f"{path} is not acted on: {why}"
        with os.fdopen(fd, "r", closefd=False) as fh:
            document = json.load(fh)
    except (OSError, ValueError) as exc:
        return None, f"{path} cannot be read: {exc}"
    finally:
        os.close(fd)
    if not isinstance(document, dict):
        return None, f"{path} is not a JSON object"
    return document, None


def read_manifest(path=None):
    """The manifest as a dict, or None when there is none or it must not be used.

    `load_manifest`'s document alone -- for `ndt` and the proxy, which render a None as
    "unreadable". The teardown (`shut_down`) and the root emitter
    (`psample_sflow_emitter.load_manifest`) call `load_manifest` itself, so every reader of the
    file refuses the same files. [Co-developed with claude code -- Adam]
    """
    return load_manifest(path)[0]


def _read_cmdline(pid, proc_root):
    """`/proc/<pid>/cmdline` as the list of words it is, or None when it cannot be read.

    The kernel writes each argv word followed by one NUL, so the last split element is the
    empty remainder after the final NUL and is dropped -- a word that is itself empty stays.
    """
    try:
        with open(os.path.join(proc_root, str(int(pid)), "cmdline"), "rb") as fh:
            raw = fh.read()
    except (OSError, ValueError, TypeError):
        return None
    if not raw:
        return []
    return [os.fsdecode(word) for word in raw.split(b"\0")[:-1]]


def process_start_time(pid, proc_root="/proc"):
    """When `pid` started: field 22 of `/proc/<pid>/stat`, in clock ticks since boot.

    [Co-developed with claude code -- Adam]
    The one property a process cannot change and a recycled pid cannot inherit. `comm` (field
    2) is in parentheses and may itself contain spaces and ')', so the fields are counted from
    after the LAST ')': there, field 3 is index 0 and field 22 is index 19. None when the pid
    is gone or the file does not parse.
    """
    try:
        with open(os.path.join(proc_root, str(int(pid)), "stat"), "rb") as fh:
            raw = fh.read()
    except (OSError, ValueError, TypeError):
        return None
    _comm, closing, rest = raw.rpartition(b")")
    if not closing:
        return None
    try:
        return int(rest.split()[19])
    except (IndexError, ValueError):
        return None


def _is_an_argv(value):
    return isinstance(value, (list, tuple)) and all(isinstance(w, str) for w in value)


def _is_an_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _is_a_signallable_pid(pid):
    """An int, not a bool, above 1. [Co-developed with claude code -- Adam]

    `True` is an int in Python and `int(True)` is 1 -- /proc/1, init -- so a manifest saying
    `"pid": true` must not get as far as a lookup, let alone a signal (judge KJL B2). 1 is init,
    0 is "my process group" to kill(2) and a negative number is somebody's process group: none
    of them is ever an emitter this module launched.
    """
    return _is_an_int(pid) and pid > 1


def _is_the_launchers_shape(cmdline):
    """Whether `cmdline` is exactly what `emitter_argv` builds, whoever built it.

    `<python> <.../psample_sflow_emitter.py> --manifest <path>`: four words, a python first,
    this module's emitter by file name second, the flag the launcher itself writes third. The
    fallback for a manifest that recorded no argv -- every one written before 2026-09-27.
    """
    return (len(cmdline) == 4
            and os.path.basename(cmdline[0]).startswith("python")
            and os.path.basename(cmdline[1]) == os.path.basename(EMITTER_PATH)
            and cmdline[2] == "--manifest")


def process_is_the_emitter(pid, proc_root="/proc", argv=None, start_time=None):
    """Whether `pid` is still the emitter that was recorded, rather than whatever holds it now.

    🔴 THE SAME RULE `process_is_a_switch` STATES, and for the same reason: a pid recorded at
    bring-up is not evidence that the same process holds it at teardown -- Linux recycles pids,
    and this teardown runs as root. It is a read of ONE pid we wrote down, never a scan for a
    pattern: `pkill -f`/`pgrep -f` are forbidden in this repo and this is the shape that makes
    them unnecessary.

    [Co-developed with claude code -- Adam]
    🔴 AND IT IS AN IDENTITY, NOT A RESEMBLANCE (Adam 2026-09-27, ruling K). Until then this
    answered `b"psample_sflow_emitter.py" in <the whole cmdline>` -- so `vim` with that file
    open, a `grep` or `tail` naming it, or a test runner with it among its arguments, holding a
    recycled pid, was "the emitter", and `stop_emitter` would SIGTERM and then SIGKILL it as
    root. Every answer of True now needs ALL of:

      * `pid` an int above 1 that is not a bool (`_is_a_signallable_pid`);
      * the cmdline in the launcher's own four-word shape, `<python> <.../psample_sflow_emitter.py>
        --manifest <path>` (`_is_the_launchers_shape`) -- ALWAYS, whatever the manifest recorded.
        The real emitter is never anything else, and this is what keeps a manifest someone else
        wrote from naming an arbitrary process by copying its argv and start time out of /proc
        (judge KJL B2: at 4a96f894 a recorded argv REPLACED the shape check, so a forged manifest
        could have root signal sshd);
      * and, when the manifest recorded an identity (`emitter_identity`), BOTH halves of it: the
        cmdline equal to the recorded `argv` word for word -- a file of the same NAME run from
        another path is not it -- and `/proc/<pid>/stat` field 22 equal to the recorded
        `start_time`, which is what defeats pid reuse outright: a process that took the number
        later started later, whatever its argv says.

    No identity at all (a manifest written before this ruling) is the shape alone. HALF an
    identity -- an argv with no start time, or the reverse -- is never a match (judge K-N7):
    the launcher records both or neither (`emitter_identity`), so half of one is a document
    nobody here wrote, as is a recorded field of the wrong type.
    """
    if not _is_a_signallable_pid(pid):
        return False
    cmdline = _read_cmdline(pid, proc_root)
    if not cmdline or not _is_the_launchers_shape(cmdline):
        # Gone, not ours to read, a zombie (which is what a SIGTERMed emitter is until its
        # parent reaps it), or something that is not an emitter at all.
        return False
    if argv is None and start_time is None:
        return True
    return (_is_an_argv(argv) and cmdline == list(argv)
            and _is_an_int(start_time) and process_start_time(pid, proc_root) == start_time)


def emitter_identity(proc, proc_root="/proc"):
    """What the manifest records about the emitter besides its pid: {"argv", "start_time"}.

    [Co-developed with claude code -- Adam]
    `argv` is the list the launcher handed to Popen (`Popen.args`), not a reading of /proc: it
    is what the process was TOLD to be, and a later reading of /proc is compared against it.
    `start_time` is read from /proc HERE, and this is the one moment it can be read without a
    race: until `proc` is waited on, it is this process's unreaped child, so its pid cannot
    have been handed to anything else -- even if it has already exited, a zombie keeps its
    number and its stat. When either cannot be known BOTH are None, and the check is then the
    launcher's shape alone, as for a manifest written before the ruling.
    """
    args = getattr(proc, "args", None)
    pid = getattr(proc, "pid", None)
    argv = list(args) if _is_an_argv(args) else None
    started = process_start_time(pid, proc_root) if _is_a_signallable_pid(pid) else None
    # 🔴 BOTH OR NEITHER (judge K-N7). Half an identity is a document `process_is_the_emitter`
    # refuses outright, so recording one would orphan the emitter this launch just started;
    # neither falls back to the launcher's shape, exactly as a pre-ruling manifest does.
    if argv is None or started is None:
        return {"argv": None, "start_time": None}
    return {"argv": argv, "start_time": started}


def emitter_is_running(document, proc_root="/proc"):
    """Whether the emitter a manifest document names is running NOW, by everything it recorded.

    [Co-developed with claude code -- Adam]
    What `ndt status`/`ndt down` and the proxy's `switch_state` disclosure read the manifest's
    pid through. The teardown does not call this -- `shut_down` goes through `stop_emitter`,
    which asks `process_is_the_emitter` again on every step of its grace loop -- but both ask
    the same predicate with the same recorded identity, and `process_is_the_emitter` itself
    refuses a pid that is not an int above 1 (judge K-N6). So no reader can call "alive" -- and
    tell an operator to `kill` -- a process the teardown would refuse to signal.
    """
    if not isinstance(document, dict):
        return False
    return process_is_the_emitter(document.get("pid"), proc_root=proc_root,
                                  argv=document.get("argv"),
                                  start_time=document.get("start_time"))


def stop_emitter(pid, kill=None, is_emitter=None, sleep=None, grace_s=EMITTER_STOP_GRACE_S,
                 argv=None, start_time=None):
    """SIGTERM, wait up to `grace_s`, then SIGKILL. Returns what it ended up doing.

    One of "absent" (that pid is not the emitter any more -- nothing is signalled), "term"
    (it went on the SIGTERM) or "kill". `argv` and `start_time` are what the manifest recorded
    (`emitter_identity`), and every question put to `is_emitter` carries them.
    """
    kill = kill or os.kill
    is_emitter = is_emitter or process_is_the_emitter
    sleep = sleep or time.sleep
    identity = {"argv": argv, "start_time": start_time}
    # 🔴 THE PID IS CHECKED HERE TOO, not only inside the predicate (judge KJL B2): `is_emitter`
    # is injectable, and `kill(int(True), ...)` is a signal to init. [Co-developed with claude code -- Adam]
    if not _is_a_signallable_pid(pid) or not is_emitter(pid, **identity):
        return "absent"
    try:
        kill(int(pid), signal.SIGTERM)
    except OSError:
        return "absent"
    # A whole number of steps rather than `while deadline > 0: deadline -= 0.1`. That
    # subtraction is binary floating point -- 0.5 becomes six steps, not five -- and
    # `p4_testbed_topo.start_link_telemetry` already carries that warning beside its own
    # grace loop. A loop whose trip count nobody can state is one whose test has to be
    # written from its own behaviour.
    for _step in range(int(math.ceil(grace_s / EMITTER_POLL_INTERVAL_S))):
        if not is_emitter(pid, **identity):
            return "term"
        sleep(EMITTER_POLL_INTERVAL_S)
    try:
        kill(int(pid), signal.SIGKILL)
    except OSError:
        pass
    return "kill"


def shut_down(path=None, run=None, kill=None, is_emitter=None, sleep=None, report=None,
              remove=None):
    """Stop the emitter, remove the filters, drop the manifest. Safe when there is none.

    🔴 IT READS THE MANIFEST RATHER THAN TAKING A PLAN, and that is the whole point. Both entry
    points tear down with a bare `tear_down(net)`, including from their abort paths, and a plan
    object threaded through those would be a fourth thing an abort path has to remember. The
    manifest is on disk before the first packet is sampled, so a teardown -- or the NEXT
    bring-up's -- can clean up after a process that died without one.

    Returns (fate, interfaces removed, document) or (None, [], None) when nothing was up, and
    ("refused", [], None) when the manifest must not be acted on (`load_manifest`).
    """
    path = path or LINK_TELEMETRY_MANIFEST
    remove = remove or os.remove
    # 🔴 A MANIFEST THIS PROCESS MAY NOT TRUST IS NOT ACTED ON AT ALL (judge KJL B2): no signal,
    # no `tc qdisc del` on the interfaces it lists, and the file left where it is. The next LINK
    # bring-up's `write_manifest` replaces the inode; a cooperative bring-up never writes one, so
    # on a cooperative fabric the refusal is repeated at every reset and teardown until someone
    # removes the file. Said, never silent: "something stopped the teardown doing its job" is a
    # fact the operator needs. [Co-developed with claude code -- Adam]
    document, problem = load_manifest(path)
    if document is None:
        if problem is None:
            return None, [], None
        if report:
            report(f"link telemetry: {problem} -- nothing was signalled, no filter was removed, "
                   f"and the file was left in place")
        return "refused", [], None
    # The identity it recorded goes with the pid: `stop_emitter` asks `is_emitter` with it on
    # every step, so the process signalled is the one the bring-up launched and no other.
    fate = stop_emitter(document.get("pid"), kill=kill, is_emitter=is_emitter, sleep=sleep,
                        argv=document.get("argv"), start_time=document.get("start_time"))
    interfaces = [port["ifname"]
                  for switch in document.get("switches", [])
                  for port in (switch.get("ports") or {}).values()
                  if port.get("ifname")]
    removed = detach(interfaces, run=run, report=report)
    if report:
        report(f"link telemetry: emitter pid {document.get('pid')} {fate}, "
               f"{len(removed)} of {len(interfaces)} clsact qdisc(s) removed")
    try:
        remove(path)
    except OSError:
        pass
    return fate, removed, document


def emitter_argv(manifest_path=None, python=None, emitter=None):
    """The exact argv `start_emitter` runs, so a test and the bring-up state one thing."""
    return [python or sys.executable, emitter or EMITTER_PATH,
            "--manifest", manifest_path or LINK_TELEMETRY_MANIFEST]


def start_emitter(manifest_path=None, popen=None, python=None, emitter=None, stderr=None,
                  log_path=None, opener=None):
    """Launch the emitter against a manifest that is ALREADY on disk, onto its own log.

    Returns the Popen. The caller decides what a dead one means -- `bring_up` calls it fatal,
    which section 2.5 requires: an emitter that exited is a fabric measuring nothing while
    every other line of the bring-up reads success.

    `stderr` is for a test that wants the stream itself; production takes the other branch and
    gets `LINK_TELEMETRY_LOG`, for the reason written at that constant. The handle is closed
    here -- the child has its own duplicate -- so this process holds no extra descriptor either.
    """
    popen = popen or subprocess.Popen
    argv = emitter_argv(manifest_path, python, emitter)
    if stderr is not None:
        return popen(argv, stderr=stderr)
    handle = (opener or open)(log_path or LINK_TELEMETRY_LOG, "wb")
    try:
        return popen(argv, stdout=handle, stderr=handle)
    finally:
        handle.close()


def stop_launched_emitter(proc, grace_s=EMITTER_STOP_GRACE_S):
    """Stop an emitter THIS process just launched, through its own Popen. Never raises.

    [Co-developed with claude code -- Adam]
    For a bring-up that fails after `start_emitter`: the child is unreaped, so its pid is still
    its own, and `terminate`/`kill` address exactly it. Without this, a failed manifest write
    leaves a root process holding the psample group that no manifest names.
    """
    try:
        proc.terminate()
        proc.wait(timeout=grace_s)
    except Exception:                                    # noqa: BLE001 -- best effort
        try:
            proc.kill()
            proc.wait(timeout=grace_s)
        except Exception:                                # noqa: BLE001
            pass


def describe(plan, emitter_pid=None) -> str:
    """The one line the bring-up prints. Section 4.2."""
    if plan.is_empty:
        return f"link telemetry: off ({plan.reason})"
    return (f"link telemetry: {len(plan.switches)} switch(es), "
            f"{plan.ingress_filters()} ingress + {plan.egress_filters()} egress filters, "
            f"emitter pid {emitter_pid}")
