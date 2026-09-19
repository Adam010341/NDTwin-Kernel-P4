#!/usr/bin/env python3
"""psample notifications in, sFlow v5 out: the link-telemetry path's other half.

[Co-developed with claude code -- Adam]

TICKET-P3 section 2.5. `link_telemetry.py` attaches `tc ... action sample` filters to the
switch-side veths; the kernel then multicasts a PSAMPLE_CMD_SAMPLE for one packet in every 256.
This program joins that multicast group, maps each sample back to the (dpid, port) the filter
was attached to, and hands it to `proxy_agent/sflow_emitter.py` -- the SAME builder the
cooperative path uses, so the bytes that reach the NDTwin kernel's collector are the bytes it
already parses and the two telemetry paths cannot drift into two wire formats.

WHAT IT NEEDS AND WHY
  * `--manifest`: the file `link_telemetry.write_manifest` wrote -- the ifindex -> (dpid, port)
    map, the agent address per switch, the rate and the group. It is written immediately AFTER
    this process is started (the manifest carries this process's pid), so a short wait for it
    to appear is normal and is not an error; `--manifest-wait` bounds it.
  * CAP_NET_ADMIN, to join the psample `packets` multicast group. The topology script that
    starts this already runs as root under `sudo ndtwin-lab topo-start`.
  * The SAME NETWORK NAMESPACE as the sampled interfaces. psample multicasts per-netns, so a
    listener in the wrong one receives exactly nothing and that silence looks like idle links.
    Mininet switches live in the root namespace, which is why one process covers the fabric --
    `link_telemetry.plan()` verifies that rather than assuming it.

WHAT IT PRINTS. One statistics line to stderr every `--stats-interval` seconds (default 10),
and one final line on the way out. Every drop has a named counter: a sample this program threw
away is a number an operator can read, not a gap in a graph.

THE DECODER IS THE SPIKE'S. The netlink/genetlink plumbing below is carried over from
doc/audit/2026-09-04_p4-tutorial-exercise-prep/spike-tc-sample/psample_listen.py, which was run
live on 2026-09-17 and whose header records what was MEASURED there rather than read out of a
header file:

  * PSAMPLE_ATTR_IIFINDEX/OIFINDEX are written with `nla_put_u16()` -- SIXTEEN BITS. The map is
    keyed on `ifindex & 0xFFFF` and `link_telemetry.plan()` refuses a fabric whose interfaces
    alias in those bits.
  * An INGRESS filter emits IIFINDEX and no OIFINDEX; an EGRESS one emits OIFINDEX and no
    IIFINDEX. That is how a sample's direction is known, and it is why one group serves the
    whole fabric.
  * Joining the group as an unprivileged user returns EPERM. Said in those words below, because
    the alternative failure mode is an empty sample stream that reads as "no traffic".
"""
from __future__ import annotations

import argparse
import errno
import json
import os
import select
import signal
import socket
import struct
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
_PROXY_AGENT = os.path.join(os.path.dirname(_HERE), "proxy_agent")
if _PROXY_AGENT not in sys.path:
    # By path, not as a package: `proxy_agent/sflow_emitter.py` imports nothing outside the
    # standard library (json/os/socket/struct/time/dataclasses/typing), which is what lets this
    # process -- started by the topology script under whatever interpreter the lab wrapper
    # chose -- share the builder with the proxy instead of transcribing the wire format.
    sys.path.insert(0, _PROXY_AGENT)

import sflow_emitter  # noqa: E402

# ---------------------------------------------------------------------------
# netlink / generic netlink constants (linux/netlink.h, linux/genetlink.h)
# ---------------------------------------------------------------------------
NETLINK_GENERIC = 16
SOL_NETLINK = 270
NETLINK_ADD_MEMBERSHIP = 1

NLMSG_ERROR = 0x2
NLMSG_DONE = 0x3
NLM_F_REQUEST = 0x01
NLM_F_ACK = 0x04

NLA_F_NESTED = 0x8000
NLA_F_NET_BYTEORDER = 0x4000
NLA_TYPE_MASK = ~(NLA_F_NESTED | NLA_F_NET_BYTEORDER) & 0xFFFF

GENL_ID_CTRL = 0x10
CTRL_CMD_GETFAMILY = 3
CTRL_ATTR_FAMILY_ID = 1
CTRL_ATTR_FAMILY_NAME = 2
CTRL_ATTR_MCAST_GROUPS = 7
CTRL_ATTR_MCAST_GRP_NAME = 1
CTRL_ATTR_MCAST_GRP_ID = 2

# ---------------------------------------------------------------------------
# psample uapi -- /usr/include/linux/psample.h, declaration order of `enum { ... }`
# ---------------------------------------------------------------------------
PSAMPLE_GENL_NAME = "psample"
PSAMPLE_NL_MCGRP_SAMPLE_NAME = "packets"

PSAMPLE_ATTR_IIFINDEX = 0
PSAMPLE_ATTR_OIFINDEX = 1
PSAMPLE_ATTR_ORIGSIZE = 2
PSAMPLE_ATTR_SAMPLE_GROUP = 3
PSAMPLE_ATTR_GROUP_SEQ = 4
PSAMPLE_ATTR_SAMPLE_RATE = 5
PSAMPLE_ATTR_DATA = 6

PSAMPLE_CMD_SAMPLE = 0

#: Fact 2 of the spike: these two are u16 on the wire.
IFINDEX_MASK = 0xFFFF


def _align4(n: int) -> int:
    return (n + 3) & ~3


def nla(attr_type: int, payload: bytes) -> bytes:
    """One nlattr: length (incl. header), type, payload, padding to a 4-byte boundary."""
    length = 4 + len(payload)
    return struct.pack("=HH", length, attr_type) + payload + b"\x00" * (_align4(length) - length)


def parse_attrs(buf: bytes):
    """Flat list of (type, payload). A list, not a dict: a nested array reuses the type field
    as an index, so duplicates are meaningful."""
    out = []
    off, end = 0, len(buf)
    while off + 4 <= end:
        alen, atype = struct.unpack_from("=HH", buf, off)
        if alen < 4 or off + alen > end:
            break
        out.append((atype & NLA_TYPE_MASK, buf[off + 4:off + alen]))
        off += _align4(alen)
    return out


def build_genl(family_id: int, cmd: int, version: int, flags: int, seq: int,
               payload: bytes) -> bytes:
    body = struct.pack("=BBH", cmd, version, 0) + payload
    total = 16 + len(body)
    return struct.pack("=IHHII", total, family_id, flags, seq, 0) + body


def iter_nlmsg(buf: bytes):
    """Yield (nlmsg_type, nlmsg_flags, nlmsg_seq, body) for each message in a datagram."""
    off, end = 0, len(buf)
    while off + 16 <= end:
        mlen, mtype, mflags, mseq, _pid = struct.unpack_from("=IHHII", buf, off)
        if mlen < 16 or off + mlen > end:
            break
        yield mtype, mflags, mseq, buf[off + 16:off + mlen]
        off += _align4(mlen)


def _unpack_uint(payload: bytes):
    """Host-order unsigned int of whatever width the kernel chose (1/2/4/8 bytes)."""
    fmt = {1: "=B", 2: "=H", 4: "=I", 8: "=Q"}.get(len(payload))
    return None if fmt is None else struct.unpack(fmt, payload)[0]


class SetupError(Exception):
    pass


def resolve_family(sock, family_name: str, group_name: str):
    """CTRL_CMD_GETFAMILY -> (family_id, wanted_group_id, all_groups)."""
    req = build_genl(GENL_ID_CTRL, CTRL_CMD_GETFAMILY, 1,
                     NLM_F_REQUEST | NLM_F_ACK, 1,
                     nla(CTRL_ATTR_FAMILY_NAME, family_name.encode() + b"\x00"))
    sock.send(req)
    deadline = time.monotonic() + 5.0
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SetupError("timed out waiting for a CTRL_CMD_GETFAMILY reply")
        ready, _, _ = select.select([sock], [], [], remaining)
        if not ready:
            continue
        for mtype, _flags, _seq, body in iter_nlmsg(sock.recv(65536)):
            if mtype == NLMSG_ERROR:
                (err,) = struct.unpack_from("=i", body, 0)
                if err == 0:
                    continue
                raise SetupError(
                    "the kernel refused CTRL_CMD_GETFAMILY for family %r: %s. If it is ENOENT "
                    "the psample module is not loaded -- attaching a `tc ... action sample` "
                    "filter pulls act_sample and psample in, so this usually means no filter "
                    "was attached at all" % (family_name, os.strerror(-err)))
            if mtype == NLMSG_DONE:
                raise SetupError("family %r not reported by nlctrl" % family_name)
            if mtype != GENL_ID_CTRL:
                continue
            family_id, groups = 0, {}
            for atype, payload in parse_attrs(body[4:]):
                if atype == CTRL_ATTR_FAMILY_ID:
                    (family_id,) = struct.unpack_from("=H", payload, 0)
                elif atype == CTRL_ATTR_MCAST_GROUPS:
                    for _idx, blob in parse_attrs(payload):
                        gname = gid = None
                        for gtype, gpayload in parse_attrs(blob):
                            if gtype == CTRL_ATTR_MCAST_GRP_NAME:
                                gname = gpayload.split(b"\x00", 1)[0].decode()
                            elif gtype == CTRL_ATTR_MCAST_GRP_ID:
                                (gid,) = struct.unpack_from("=I", gpayload, 0)
                        if gname is not None and gid is not None:
                            groups[gname] = gid
            if not family_id:
                raise SetupError("nlctrl reply for %r carried no family id" % family_name)
            if group_name not in groups:
                raise SetupError("family %r has no multicast group %r (it has: %s)"
                                 % (family_name, group_name,
                                    ", ".join(sorted(groups)) or "<none>"))
            return family_id, groups[group_name], groups


def open_psample_socket(family_name=PSAMPLE_GENL_NAME, group_name=PSAMPLE_NL_MCGRP_SAMPLE_NAME):
    sock = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, NETLINK_GENERIC)
    try:
        sock.bind((0, 0))
    except OSError as exc:
        sock.close()
        raise SetupError("could not bind an AF_NETLINK/NETLINK_GENERIC socket: %s" % exc)
    # A sampled burst can outrun us; a small default buffer turns that into ENOBUFS.
    for opt in ("SO_RCVBUFFORCE", "SO_RCVBUF"):
        code = getattr(socket, opt, None)
        if code is None:
            continue
        try:
            sock.setsockopt(socket.SOL_SOCKET, code, 8 * 1024 * 1024)
            break
        except OSError:
            continue
    family_id, group_id, all_groups = resolve_family(sock, family_name, group_name)
    try:
        sock.setsockopt(SOL_NETLINK, NETLINK_ADD_MEMBERSHIP, group_id)
    except OSError as exc:
        sock.close()
        if exc.errno == errno.EPERM:
            # 🔴 THE THREE FACTS, in the error rather than in a comment: what the failure is,
            # what it needs, and the OTHER way this program goes quiet -- because an operator
            # who reads only "permission denied" fixes the privilege and then cannot explain
            # why the stream is still empty.
            raise SetupError(
                "EPERM joining the %r/%r multicast group (id %d). Three facts, all measured on "
                "2026-09-17: (1) joining a generic-netlink multicast group needs CAP_NET_ADMIN "
                "in the user namespace owning this network namespace -- run under sudo, which "
                "is how `ndtwin-lab topo-start` starts the topology; (2) psample multicasts "
                "PER NETWORK NAMESPACE, so this process must run in the same one as the "
                "sampled interfaces or it receives nothing and the silence looks like idle "
                "links; (3) nothing else in this program needs privilege."
                % (family_name, group_name, group_id))
        raise SetupError("could not join %r/%r (id %d): %s"
                         % (family_name, group_name, group_id, exc))
    return sock, family_id, group_id, all_groups


def decode_sample(body: bytes) -> dict:
    """The attributes of one PSAMPLE_CMD_SAMPLE message. `body` is genlmsghdr + attributes."""
    sample = {}
    for atype, payload in parse_attrs(body[4:]):
        if atype == PSAMPLE_ATTR_IIFINDEX:
            value = _unpack_uint(payload)
            if value is not None:
                sample["iifindex"] = value
        elif atype == PSAMPLE_ATTR_OIFINDEX:
            value = _unpack_uint(payload)
            if value is not None:
                sample["oifindex"] = value
        elif atype == PSAMPLE_ATTR_ORIGSIZE and len(payload) >= 4:
            sample["origsize"] = struct.unpack_from("=I", payload, 0)[0]
        elif atype == PSAMPLE_ATTR_SAMPLE_GROUP and len(payload) >= 4:
            sample["group"] = struct.unpack_from("=I", payload, 0)[0]
        elif atype == PSAMPLE_ATTR_SAMPLE_RATE and len(payload) >= 4:
            sample["rate"] = struct.unpack_from("=I", payload, 0)[0]
        elif atype == PSAMPLE_ATTR_DATA:
            # The frame itself, whole. The spike kept a hex prefix because it was writing a
            # report; this is the payload of the sFlow raw-header record.
            sample["data"] = payload
    return sample


# ---------------------------------------------------------------------------
# the manifest: ifindex -> (dpid, port), per direction
# ---------------------------------------------------------------------------
class PortMap:
    """What `link_telemetry.write_manifest` recorded, in the shape the hot loop asks for."""

    def __init__(self, document):
        self.rate = int(document.get("rate") or 0)
        self.group = document.get("group")
        self.sub_agent_id = int(document.get("sub_agent_id") or 0)
        collector = document.get("collector") or list(sflow_emitter.DEFAULT_COLLECTOR)
        self.collector = (collector[0], int(collector[1]))
        self.agents = {}
        self.names = {}
        self.ingress = {}
        self.egress = {}
        for switch in document.get("switches") or []:
            dpid = int(switch["dpid"])
            self.agents[dpid] = switch["agent_ip"]
            self.names[dpid] = switch.get("name", f"s{dpid}")
            for port_text, port in (switch.get("ports") or {}).items():
                # 🔴 THE KEY IS THE SIXTEEN BITS, not the ifindex. The manifest states both and
                # this reads the one psample will actually report; taking `ifindex` here would
                # work on a machine whose indices are small and fail on the machine that has
                # been up long enough for them not to be.
                key = int(port.get("key", int(port["ifindex"]) & IFINDEX_MASK))
                where = (dpid, int(port_text))
                if port.get("ingress"):
                    self.ingress[key] = where
                if port.get("egress"):
                    self.egress[key] = where

    def switches(self):
        return sorted(self.agents)


def load_manifest(path, wait_s=0.0, sleep=time.sleep, exists=os.path.exists):
    """Read the manifest, waiting up to `wait_s` for it to appear.

    The wait is not defensive padding: `bring_up` starts this process and THEN writes the
    manifest, because the manifest carries this process's pid. Missing after the wait is a
    refusal -- a running emitter with no map would join the group and drop every sample.
    """
    deadline = time.monotonic() + wait_s
    while True:
        if exists(path):
            with open(path) as fh:
                return PortMap(json.load(fh))
        if time.monotonic() >= deadline:
            raise SetupError(
                "no link-telemetry manifest at %s after %.1fs. It is written by "
                "link_telemetry.write_manifest immediately after this process is started; "
                "without it every sample would be dropped as an unknown ifindex" % (path, wait_s))
        sleep(0.05)


# ---------------------------------------------------------------------------
# the counters, and the one line they are printed as
# ---------------------------------------------------------------------------
class Stats:
    """Every sample this program saw, and the named reason for every one it did not emit."""

    FIELDS = ("samples", "emitted", "dropped_unknown_ifindex", "dropped_no_direction",
              "dropped_ambiguous_direction", "dropped_no_origsize", "dropped_other_group",
              "dropped_decode_error", "emit_failed", "enobufs")

    def __init__(self, started=None):
        for name in self.FIELDS:
            setattr(self, name, 0)
        self.per_switch = {}
        self.started = started if started is not None else time.monotonic()

    def credit(self, name):
        self.per_switch[name] = self.per_switch.get(name, 0) + 1

    def line(self, now=None) -> str:
        """The statistics line. ONE line, stable field order, `k=v` throughout -- so `ndt` and
        an operator's `grep` read the same thing and a new counter cannot shift a column."""
        elapsed = (now if now is not None else time.monotonic()) - self.started
        per_switch = ",".join(f"{k}:{v}" for k, v in sorted(self.per_switch.items())) or "-"
        fields = " ".join(f"{name}={getattr(self, name)}" for name in self.FIELDS)
        return f"psample_sflow_emitter: {fields} per_switch={per_switch} elapsed={elapsed:.1f}s"


def sample_for(decoded, ports: PortMap, stats: Stats):
    """One decoded psample -> (dpid, SampledPacket), or None with a counter credited.

    🔴 `frame_length` IS ORIGSIZE, NOT `len(DATA)`. `trunc 128` means DATA is at most 128 bytes
    whatever the packet was, and the kernel multiplies frameLength by the sampling rate to get
    link bytes -- so using the captured length would report a 1500-byte packet as 128 and the
    whole fabric's link usage would come out ~12x low, plausibly and wrongly.

    🔴 DIRECTION COMES FROM WHICH ATTRIBUTE IS PRESENT, which the spike measured: ingress
    filters emit IIFINDEX only, egress filters OIFINDEX only. An ingress sample becomes
    `ingress_port=p, egress_port=0`; an egress sample becomes `ingress_port=0, egress_port=p`,
    which is the shape section 2.2 requires -- the kernel banks an `inputPort == 0` sample as
    egress-only and credits it to the switch->host edge, and a port number in the ingress field
    would instead book it against the host->switch edge.
    """
    iif, oif = decoded.get("iifindex"), decoded.get("oifindex")
    if iif is not None and oif is not None:
        stats.dropped_ambiguous_direction += 1
        return None
    if iif is not None:
        where, ingress = ports.ingress.get(iif & IFINDEX_MASK), True
    elif oif is not None:
        where, ingress = ports.egress.get(oif & IFINDEX_MASK), False
    else:
        stats.dropped_no_direction += 1
        return None
    if where is None:
        stats.dropped_unknown_ifindex += 1
        return None
    origsize = decoded.get("origsize")
    if not origsize:
        stats.dropped_no_origsize += 1
        return None
    dpid, port = where
    return dpid, sflow_emitter.SampledPacket(
        ingress_port=port if ingress else 0,
        egress_port=0 if ingress else port,
        frame_length=int(origsize),
        # The kernel states the rate it applied; the manifest's is the fallback for a kernel
        # that did not. Taking the manifest's unconditionally would silently misreport a filter
        # that was attached with a different rate than the one this fabric planned.
        sampling_rate=int(decoded.get("rate") or ports.rate),
        frame=decoded.get("data") or b"",
    )


def build_emitter(ports: PortMap, emitter=None):
    """An SFlowEmitter with one agent per switch, at this path's sub-agent id."""
    emitter = emitter or sflow_emitter.SFlowEmitter(collector=ports.collector)
    for dpid in ports.switches():
        emitter.register_switch(dpid, ports.agents[dpid])
        agent = emitter.agent_for(dpid)
        if agent is not None:
            # The proxy's cooperative emitter is sub-agent 0. Set after registering rather than
            # by changing `register_switch`, which belongs to the proxy (file ownership,
            # TICKET-P3 section 0 item 7) and whose default every other caller relies on.
            agent.sub_agent_id = ports.sub_agent_id
    return emitter


def run(sock, family_id, ports, emitter, stats, stop, stats_interval=10.0,
        report=None, now=time.monotonic):
    """The loop. `stop` is a zero-argument predicate, so SIGTERM is one flag and not a raise."""
    report = report or (lambda line: print(line, file=sys.stderr, flush=True))
    next_stats = now() + stats_interval
    while not stop():
        try:
            ready, _, _ = select.select([sock], [], [], 0.5)
        except InterruptedError:
            continue
        if ready:
            try:
                data = sock.recv(262144)
            except OSError as exc:
                if exc.errno == errno.ENOBUFS:
                    stats.enobufs += 1
                    data = b""
                elif exc.errno == errno.EINTR:
                    data = b""
                else:
                    raise
            for mtype, _flags, _seq, body in iter_nlmsg(data):
                if mtype != family_id or len(body) < 4 or body[0] != PSAMPLE_CMD_SAMPLE:
                    continue
                try:
                    decoded = decode_sample(body)
                except (struct.error, ValueError, IndexError):
                    stats.dropped_decode_error += 1
                    continue
                if ports.group is not None and decoded.get("group") != ports.group:
                    stats.dropped_other_group += 1
                    continue
                stats.samples += 1
                made = sample_for(decoded, ports, stats)
                if made is None:
                    continue
                dpid, sample = made
                if emitter.emit(dpid, sample, emitter.uptime_ms()):
                    stats.emitted += 1
                    stats.credit(ports.names.get(dpid, f"s{dpid}"))
                else:
                    stats.emit_failed += 1
        if now() >= next_stats:
            report(stats.line())
            next_stats = now() + stats_interval
    report(stats.line())
    return stats


#: What "stop sampling" arrives as. TICKET-P3 section 9 ruling 19(1).
#:
#: [Co-developed with claude code -- Adam]
#: SIGTERM is what `link_telemetry.stop_emitter` sends. SIGHUP is what `ndtwin-lab topo-stop`'s
#: `kill-session` sends to the tmux pane's process group -- which this process is IN, because
#: the topology script started it -- and with the default disposition that killed it on the
#: spot, mid-datagram, with no last statistics line. SIGINT is the operator's Ctrl-C on the
#: same pane.
STOP_SIGNALS = ("SIGTERM", "SIGINT", "SIGHUP")


def install_stop_handlers(stopping, signals=None, install=None):
    """Set a flag rather than raise: the loop finishes its iteration and flushes.

    A handler that raised would unwind out of `sock.recv` and lose whatever the emitter had
    buffered. Teardown SIGTERMs this process on purpose, so that path is the NORMAL one, not
    the exceptional one. Returns the names actually installed, which is what a test reads.
    """
    install = install or signal.signal
    installed = []
    for name in (signals or STOP_SIGNALS):
        number = getattr(signal, name, None)
        if number is None:
            continue
        try:
            install(number, lambda _sig, _frame: stopping.append(True))
        except (ValueError, OSError, RuntimeError):
            continue
        installed.append(name)
    return installed


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Turn psample notifications from `tc ... action sample` filters into the "
                    "sFlow the NDTwin kernel already parses. Must run as root, in the same "
                    "network namespace as the sampled interfaces.")
    parser.add_argument("--manifest", default=None,
                        help="the link-telemetry manifest link_telemetry.write_manifest wrote "
                             "(default: its LINK_TELEMETRY_MANIFEST)")
    parser.add_argument("--manifest-wait", type=float, default=10.0, metavar="S",
                        help="wait up to S seconds for the manifest to appear (default: 10)")
    parser.add_argument("--stats-interval", type=float, default=10.0, metavar="S",
                        help="print one statistics line to stderr every S seconds "
                             "(default: 10)")
    args = parser.parse_args(argv)

    manifest_path = args.manifest
    if manifest_path is None:
        sys.path.insert(0, _HERE)
        import link_telemetry  # noqa: PLC0415 -- only to learn the default path
        manifest_path = link_telemetry.LINK_TELEMETRY_MANIFEST

    try:
        ports = load_manifest(manifest_path, wait_s=args.manifest_wait)
    except (SetupError, OSError, ValueError, KeyError) as exc:
        print("psample_sflow_emitter: %s" % exc, file=sys.stderr, flush=True)
        return 1

    try:
        sock, family_id, group_id, _all = open_psample_socket()
    except SetupError as exc:
        print("psample_sflow_emitter: %s" % exc, file=sys.stderr, flush=True)
        return 1

    stopping = []
    # SIGTERM sets a flag; the loop finishes its iteration and flushes. A handler that raised
    # would unwind out of `sock.recv` and lose whatever the emitter had buffered -- teardown
    # SIGTERMs this process on purpose, so that path is the normal one, not the exceptional one.
    install_stop_handlers(stopping)

    emitter = build_emitter(ports)
    stats = Stats()
    print("psample_sflow_emitter: manifest %s, %d switch(es), group %s, rate %d, joined "
          "psample/packets (id %d), netns %s"
          % (manifest_path, len(ports.switches()), ports.group, ports.rate, group_id,
             _netns_inode()),
          file=sys.stderr, flush=True)
    try:
        run(sock, family_id, ports, emitter, stats, lambda: bool(stopping),
            stats_interval=args.stats_interval)
    finally:
        try:
            emitter.flush()
        except Exception:                            # noqa: BLE001 -- shutdown must not raise
            pass
        sock.close()
    return 0


def _netns_inode() -> str:
    try:
        return os.readlink("/proc/self/ns/net")
    except OSError:
        return "?"


if __name__ == "__main__":
    sys.exit(main())
