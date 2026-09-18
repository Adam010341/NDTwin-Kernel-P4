#!/usr/bin/env python3
# [Co-developed with claude code -- Adam]
"""
psample_listen.py -- pure-stdlib listener for the kernel's psample generic-netlink
multicast group.

WHAT IT IS
    Opens AF_NETLINK/NETLINK_GENERIC, resolves the `psample` family id and the id of its
    `packets` multicast group through CTRL_CMD_GETFAMILY on the nlctrl family, joins that
    group with SOL_NETLINK/NETLINK_ADD_MEMBERSHIP, and decodes every PSAMPLE_CMD_SAMPLE
    notification the kernel multicasts until a deadline.

    It depends on nothing outside the Python standard library: `pyroute2` is NOT installed
    on this machine and this spike must not install anything.

WHICH NETWORK NAMESPACE
    psample notifications are multicast with genlmsg_multicast_netns() to the netns that
    owns the psample group, and a psample group is looked up per-net (psample_group_get()
    takes a `struct net *`).  Therefore THE LISTENER MUST RUN IN THE SAME NETWORK NAMESPACE
    AS THE SAMPLED INTERFACE.  Running it on the host while the `tc ... action sample`
    filter lives inside a netns yields exactly zero samples, and that silence is not a
    failure of the sampler.  spike.sh therefore starts this program under
    `ip netns exec ndtspike-a`.

PRIVILEGES
    Joining the psample `packets` multicast group REQUIRES CAP_NET_ADMIN in the user
    namespace that owns the network namespace.  Measured on this machine (2026-09-17,
    kernel 7.0.0-31-generic): running as plain `adam`, the
    SOL_NETLINK/NETLINK_ADD_MEMBERSHIP setsockopt on group id 29 returns EPERM.  Under
    `sudo`, or inside `unshare -rn` (where you hold CAP_NET_ADMIN over the fresh netns),
    it succeeds.  The error path below states this explicitly instead of failing as an
    empty sample stream.  Nothing else in this program needs privilege.

ATTRIBUTE NUMBERING
    Taken from /usr/include/linux/psample.h on THIS machine (kernel 7.0.0-31-generic;
    the header IS present, from linux-libc-dev).  The enum there is unnumbered, so the
    values below are its declaration order, which is the uapi contract.  Newer attributes
    present in that header and decoded here: GROUP_REFCOUNT, TUNNEL, PAD, OUT_TC,
    OUT_TC_OCC, LATENCY, TIMESTAMP, PROTO.

    MEASURED QUIRK -- ifindex attributes are 16-bit, not 32-bit.  The header gives no
    width for IIFINDEX/OIFINDEX, and net/psample/psample.c writes them with nla_put_u16().
    Observed on this machine 2026-09-17: every sample carried its ifindex attribute with a
    2-byte payload.  This decoder therefore accepts 2-, 4- and 8-byte payloads for those
    two attributes and records the observed width in `iifindex_width`/`oifindex_width`.
    It matters downstream: an ifindex above 65535 cannot be represented, so a
    veth -> (dpid, port) map must not assume psample's ifindex is the full one.

    MEASURED, also 2026-09-17: an EGRESS `action sample` emits OIFINDEX and no IIFINDEX;
    an INGRESS one emits IIFINDEX and no OIFINDEX.  Code that expects both in one sample
    will see None half the time.

USAGE
    psample_listen.py [--seconds N] [--group G] [--json] [--data-prefix N]

    --seconds N     run for N seconds, then exit (default 20)
    --group G       only report samples whose PSAMPLE_ATTR_SAMPLE_GROUP == G (repeatable)
    --json          emit one JSON object per sample on stdout (otherwise stdout is silent)
    --data-prefix N hex-dump the first N bytes of PSAMPLE_ATTR_DATA into each JSON object
                    (default 32; 0 disables)

    A summary always goes to stderr on exit: sample count, distinct iifindex values,
    min/max/mean ORIGSIZE, the set of SAMPLE_RATE values seen, and elapsed wall time.
    Exit status 0 if at least one sample was seen, 3 if none, 1 on setup failure.
"""

from __future__ import annotations

import argparse
import errno
import json
import os
import select
import socket
import struct
import sys
import time

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
PSAMPLE_ATTR_GROUP_REFCOUNT = 7
PSAMPLE_ATTR_TUNNEL = 8
PSAMPLE_ATTR_PAD = 9
PSAMPLE_ATTR_OUT_TC = 10        # u16
PSAMPLE_ATTR_OUT_TC_OCC = 11    # u64, bytes
PSAMPLE_ATTR_LATENCY = 12       # u64, nanoseconds
PSAMPLE_ATTR_TIMESTAMP = 13     # u64, nanoseconds
PSAMPLE_ATTR_PROTO = 14         # u16

PSAMPLE_CMD_SAMPLE = 0
PSAMPLE_CMD_GET_GROUP = 1
PSAMPLE_CMD_NEW_GROUP = 2
PSAMPLE_CMD_DEL_GROUP = 3

# The kernel writes these two with nla_put_u16(); accept any sane width (see header).
_IFINDEX_ATTRS = {
    PSAMPLE_ATTR_IIFINDEX: "iifindex",
    PSAMPLE_ATTR_OIFINDEX: "oifindex",
}

# u32 attributes, and the JSON key each becomes
_U32_ATTRS = {
    PSAMPLE_ATTR_ORIGSIZE: "origsize",
    PSAMPLE_ATTR_SAMPLE_GROUP: "group",
    PSAMPLE_ATTR_GROUP_SEQ: "group_seq",
    PSAMPLE_ATTR_SAMPLE_RATE: "rate",
    PSAMPLE_ATTR_GROUP_REFCOUNT: "group_refcount",
}
_U16_ATTRS = {
    PSAMPLE_ATTR_OUT_TC: "out_tc",
    PSAMPLE_ATTR_PROTO: "proto",
}
_U64_ATTRS = {
    PSAMPLE_ATTR_OUT_TC_OCC: "out_tc_occ",
    PSAMPLE_ATTR_LATENCY: "latency_ns",
    PSAMPLE_ATTR_TIMESTAMP: "timestamp_ns",
}


# ---------------------------------------------------------------------------
# netlink attribute plumbing
# ---------------------------------------------------------------------------
def _align4(n: int) -> int:
    return (n + 3) & ~3


def nla(attr_type: int, payload: bytes) -> bytes:
    """One nlattr: length (incl. header), type, payload, padding to a 4-byte boundary."""
    length = 4 + len(payload)
    return struct.pack("=HH", length, attr_type) + payload + b"\x00" * (_align4(length) - length)


def parse_attrs(buf: bytes) -> list[tuple[int, bytes]]:
    """Flat list of (type, payload). A list, not a dict: nested arrays reuse the type
    field as an index, so duplicates are meaningful."""
    out: list[tuple[int, bytes]] = []
    off = 0
    end = len(buf)
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
    # nlmsghdr: len, type, flags, seq, pid(0 = let the kernel fill in ours)
    return struct.pack("=IHHII", total, family_id, flags, seq, 0) + body


def iter_nlmsg(buf: bytes):
    """Yield (nlmsg_type, nlmsg_flags, nlmsg_seq, body) for each message in a datagram."""
    off = 0
    end = len(buf)
    while off + 16 <= end:
        mlen, mtype, mflags, mseq, _mpid = struct.unpack_from("=IHHII", buf, off)
        if mlen < 16 or off + mlen > end:
            break
        yield mtype, mflags, mseq, buf[off + 16:off + mlen]
        off += _align4(mlen)


# ---------------------------------------------------------------------------
# family / group resolution
# ---------------------------------------------------------------------------
class SetupError(Exception):
    pass


def resolve_family(sock: socket.socket, family_name: str,
                   group_name: str) -> tuple[int, int, dict[str, int]]:
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
        data = sock.recv(65536)
        for mtype, _flags, _seq, body in iter_nlmsg(data):
            if mtype == NLMSG_ERROR:
                (err,) = struct.unpack_from("=i", body, 0)
                if err == 0:
                    continue  # plain ACK
                raise SetupError(
                    "the kernel refused CTRL_CMD_GETFAMILY for family %r: %s. "
                    "If it is ENOENT the psample module is not loaded "
                    "(`modprobe psample`, or attach a `tc ... action sample` filter "
                    "which pulls act_sample and psample in)."
                    % (family_name, os.strerror(-err)))
            if mtype == NLMSG_DONE:
                raise SetupError("family %r not reported by nlctrl" % family_name)
            if mtype != GENL_ID_CTRL:
                continue

            family_id = 0
            groups: dict[str, int] = {}
            for atype, payload in parse_attrs(body[4:]):
                if atype == CTRL_ATTR_FAMILY_ID:
                    (family_id,) = struct.unpack_from("=H", payload, 0)
                elif atype == CTRL_ATTR_MCAST_GROUPS:
                    for _idx, grp_blob in parse_attrs(payload):
                        gname, gid = None, None
                        for gtype, gpayload in parse_attrs(grp_blob):
                            if gtype == CTRL_ATTR_MCAST_GRP_NAME:
                                gname = gpayload.split(b"\x00", 1)[0].decode()
                            elif gtype == CTRL_ATTR_MCAST_GRP_ID:
                                (gid,) = struct.unpack_from("=I", gpayload, 0)
                        if gname is not None and gid is not None:
                            groups[gname] = gid
            if not family_id:
                raise SetupError("nlctrl reply for %r carried no family id" % family_name)
            if group_name not in groups:
                raise SetupError(
                    "family %r has no multicast group %r (it has: %s)"
                    % (family_name, group_name, ", ".join(sorted(groups)) or "<none>"))
            return family_id, groups[group_name], groups


def open_psample_socket(family_name: str = PSAMPLE_GENL_NAME,
                        group_name: str = PSAMPLE_NL_MCGRP_SAMPLE_NAME):
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
            raise SetupError(
                "EPERM joining the %r/%r multicast group (id %d). Joining a "
                "generic-netlink multicast group can require CAP_NET_ADMIN in the user "
                "namespace owning this network namespace: run this under `sudo`, or "
                "inside `unshare -rn` where you hold CAP_NET_ADMIN over the fresh netns. "
                "Nothing else about this program needs privilege."
                % (family_name, group_name, group_id))
        raise SetupError("could not join %r/%r (id %d): %s"
                         % (family_name, group_name, group_id, exc))
    return sock, family_id, group_id, all_groups


# ---------------------------------------------------------------------------
# ifindex -> name, so the report can say `spk-a` and not just `3`
# ---------------------------------------------------------------------------
NETLINK_ROUTE = 0
RTM_NEWLINK = 16
RTM_GETLINK = 18
NLM_F_DUMP = 0x300
IFLA_IFNAME = 3


def _links_via_netlink() -> dict[int, str]:
    """RTM_GETLINK dump over NETLINK_ROUTE: always reflects the CURRENT netns.

    /sys/class/net does not: `unshare -n` without a mount namespace leaves the host's
    sysfs mounted, so a /sys-based lookup silently names the wrong namespace's
    interfaces. `ip netns exec` does remount sysfs, but this listener must be honest in
    both cases, so netlink is the primary source and /sys only the fallback.
    """
    result: dict[int, str] = {}
    try:
        sock = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, NETLINK_ROUTE)
    except OSError:
        return result
    try:
        sock.bind((0, 0))
        # struct ifinfomsg: family, pad, type, index, flags, change
        ifinfo = struct.pack("=BBHiII", socket.AF_UNSPEC, 0, 0, 0, 0, 0)
        total = 16 + len(ifinfo)
        req = struct.pack("=IHHII", total, RTM_GETLINK,
                          NLM_F_REQUEST | NLM_F_DUMP, 1, 0) + ifinfo
        sock.send(req)
        sock.settimeout(2.0)
        done = False
        while not done:
            try:
                data = sock.recv(65536)
            except (OSError, socket.timeout):
                break
            for mtype, _flags, _seq, body in iter_nlmsg(data):
                if mtype == NLMSG_DONE or mtype == NLMSG_ERROR:
                    done = True
                    break
                if mtype != RTM_NEWLINK or len(body) < 16:
                    continue
                index = struct.unpack_from("=i", body, 4)[0]
                for atype, payload in parse_attrs(body[16:]):
                    if atype == IFLA_IFNAME:
                        result[index] = payload.split(b"\x00", 1)[0].decode(errors="replace")
    except OSError:
        pass
    finally:
        sock.close()
    return result


class IfIndexMap:
    def __init__(self) -> None:
        self._map: dict[int, str] = {}
        self.refresh()

    def refresh(self) -> None:
        self._map.update(_links_via_netlink())
        if self._map:
            return
        try:
            names = os.listdir("/sys/class/net")
        except OSError:
            return
        for name in names:
            try:
                with open(os.path.join("/sys/class/net", name, "ifindex")) as handle:
                    self._map[int(handle.read().strip())] = name
            except (OSError, ValueError):
                continue

    def get(self, index):
        if index is None:
            return None
        if index not in self._map:
            self.refresh()
        return self._map.get(index)

    def snapshot(self) -> dict[int, str]:
        return dict(self._map)


# ---------------------------------------------------------------------------
# sample decoding
# ---------------------------------------------------------------------------
def _unpack_uint(payload: bytes):
    """Host-order unsigned int of whatever width the kernel chose (1/2/4/8 bytes)."""
    fmt = {1: "=B", 2: "=H", 4: "=I", 8: "=Q"}.get(len(payload))
    if fmt is None:
        return None
    return struct.unpack(fmt, payload)[0]


def decode_sample(body: bytes, data_prefix: int) -> dict:
    """body is the genlmsghdr + attributes of a PSAMPLE_CMD_SAMPLE message."""
    sample: dict = {"unknown_attrs": []}
    for atype, payload in parse_attrs(body[4:]):
        if atype in _IFINDEX_ATTRS:
            key = _IFINDEX_ATTRS[atype]
            value = _unpack_uint(payload)
            if value is None:
                sample["unknown_attrs"].append({"type": atype, "len": len(payload)})
                continue
            sample[key] = value
            sample[key + "_width"] = len(payload)
        elif atype in _U32_ATTRS and len(payload) >= 4:
            sample[_U32_ATTRS[atype]] = struct.unpack_from("=I", payload, 0)[0]
        elif atype in _U16_ATTRS and len(payload) >= 2:
            sample[_U16_ATTRS[atype]] = struct.unpack_from("=H", payload, 0)[0]
        elif atype in _U64_ATTRS and len(payload) >= 8:
            sample[_U64_ATTRS[atype]] = struct.unpack_from("=Q", payload, 0)[0]
        elif atype == PSAMPLE_ATTR_DATA:
            sample["data_len"] = len(payload)
            if data_prefix > 0:
                sample["data_prefix_hex"] = payload[:data_prefix].hex()
        elif atype == PSAMPLE_ATTR_TUNNEL:
            sample["tunnel_len"] = len(payload)
        elif atype == PSAMPLE_ATTR_PAD:
            pass
        else:
            sample["unknown_attrs"].append({"type": atype, "len": len(payload)})
    if not sample["unknown_attrs"]:
        del sample["unknown_attrs"]
    return sample


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Listen on the psample `packets` multicast group and decode "
                    "PSAMPLE_CMD_SAMPLE notifications. Must run in the same network "
                    "namespace as the sampled interface.")
    parser.add_argument("--seconds", type=float, default=20.0,
                        help="run for this many seconds, then exit (default: 20)")
    parser.add_argument("--group", type=int, action="append", default=None,
                        metavar="G",
                        help="only report samples with this SAMPLE_GROUP (repeatable)")
    parser.add_argument("--json", action="store_true",
                        help="print one JSON object per sample on stdout")
    parser.add_argument("--data-prefix", type=int, default=32, metavar="N",
                        help="hex-dump the first N bytes of PSAMPLE_ATTR_DATA "
                             "(default 32, 0 to omit)")
    args = parser.parse_args(argv)

    wanted_groups = set(args.group) if args.group else None

    try:
        sock, family_id, group_id, all_groups = open_psample_socket()
    except SetupError as exc:
        print("psample_listen: %s" % exc, file=sys.stderr)
        return 1

    ifmap = IfIndexMap()
    print("psample_listen: family id %d, mcast groups %s, joined `packets` (id %d), "
          "netns inode %s, listening %.1fs"
          % (family_id,
             ",".join("%s=%d" % kv for kv in sorted(all_groups.items())),
             group_id,
             _netns_inode(),
             args.seconds),
          file=sys.stderr)

    count = 0
    filtered_out = 0
    other_cmds = 0
    enobufs = 0
    origsizes: list[int] = []
    rates: set[int] = set()
    iifs: dict[int, int] = {}
    oifs: dict[int, int] = {}
    per_group: dict[int, int] = {}
    ifindex_widths: set[int] = set()

    started = time.monotonic()
    started_wall = time.time()
    deadline = started + args.seconds
    out = sys.stdout

    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            try:
                ready, _, _ = select.select([sock], [], [], min(remaining, 0.5))
            except InterruptedError:
                continue
            if not ready:
                continue
            try:
                data = sock.recv(262144)
            except OSError as exc:
                if exc.errno == errno.ENOBUFS:
                    enobufs += 1
                    continue
                if exc.errno == errno.EINTR:
                    continue
                raise

            recv_wall = time.time()
            for mtype, _flags, _seq, body in iter_nlmsg(data):
                if mtype != family_id or len(body) < 4:
                    continue
                cmd = body[0]
                if cmd != PSAMPLE_CMD_SAMPLE:
                    other_cmds += 1
                    continue
                sample = decode_sample(body, args.data_prefix)
                group = sample.get("group")
                if wanted_groups is not None and group not in wanted_groups:
                    filtered_out += 1
                    continue

                count += 1
                sample["ts"] = round(recv_wall, 6)
                iif = sample.get("iifindex")
                oif = sample.get("oifindex")
                if iif is not None:
                    iifs[iif] = iifs.get(iif, 0) + 1
                    sample["iifname"] = ifmap.get(iif)
                    ifindex_widths.add(sample["iifindex_width"])
                if oif is not None:
                    oifs[oif] = oifs.get(oif, 0) + 1
                    sample["oifname"] = ifmap.get(oif)
                    ifindex_widths.add(sample["oifindex_width"])
                if "origsize" in sample:
                    origsizes.append(sample["origsize"])
                if "rate" in sample:
                    rates.add(sample["rate"])
                if group is not None:
                    per_group[group] = per_group.get(group, 0) + 1

                if args.json:
                    out.write(json.dumps(sample, sort_keys=True) + "\n")
    except KeyboardInterrupt:
        pass
    finally:
        try:
            out.flush()
        except Exception:
            pass
        sock.close()

    elapsed = time.monotonic() - started
    mean = (sum(origsizes) / len(origsizes)) if origsizes else 0.0
    summary = {
        "samples": count,
        "elapsed_s": round(elapsed, 3),
        "started_wall": round(started_wall, 3),
        "distinct_iifindex": sorted(iifs),
        "iifindex_counts": {str(k): v for k, v in sorted(iifs.items())},
        "oifindex_counts": {str(k): v for k, v in sorted(oifs.items())},
        "ifindex_names": {str(k): ifmap.get(k) for k in sorted(set(iifs) | set(oifs))},
        "per_group": {str(k): v for k, v in sorted(per_group.items())},
        "origsize_min": min(origsizes) if origsizes else None,
        "origsize_max": max(origsizes) if origsizes else None,
        "origsize_mean": round(mean, 2) if origsizes else None,
        "sample_rates_seen": sorted(rates),
        "ifindex_attr_widths_bytes": sorted(ifindex_widths),
        "netns_links": {str(k): v for k, v in sorted(ifmap.snapshot().items())},
        "filtered_out_by_group_option": filtered_out,
        "non_sample_commands": other_cmds,
        "enobufs_events": enobufs,
    }
    print("psample_listen: SUMMARY " + json.dumps(summary, sort_keys=True), file=sys.stderr)
    print("psample_listen: samples=%d distinct_iifindex=%s origsize min/max/mean=%s/%s/%s "
          "rates=%s elapsed=%.3fs"
          % (count,
             sorted(iifs) or "[]",
             summary["origsize_min"], summary["origsize_max"], summary["origsize_mean"],
             sorted(rates) or "[]",
             elapsed),
          file=sys.stderr)
    return 0 if count else 3


def _netns_inode() -> str:
    try:
        return os.readlink("/proc/self/ns/net")
    except OSError:
        return "?"


if __name__ == "__main__":
    sys.exit(main())
