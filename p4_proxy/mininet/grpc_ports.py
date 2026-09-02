"""
Where the bmv2 gRPC port block lives, and the pre-flight that keeps it out of the kernel's
ephemeral port range.

[Co-developed with claude code -- Adam]

Why this module exists (F-15). The block used to be 50051-50060, written as `50050 + i` in
p4_testbed_topo.py and, independently, as `DEFAULT_GRPC_PORT_BASE = 50050` in
proxy_agent/main.py. Two problems, and the second is the one that cost a live round:

  1. Two copies. The fabric assigns the ports and the proxy dials them; nothing tied the two
     numbers together, so "changed one, forgot the other" was one edit away. This module is
     now the single place the number is written.

  2. 50051-50060 lies *inside* /proc/sys/net/ipv4/ip_local_port_range, which on this machine
     is 32768-60999, and none of those ports were reserved. That range is the pool the kernel
     draws from for any socket that did not name its own port -- every outbound connection,
     and every `bind(port=0); listen()`. So an unrelated socket can be holding 50052 at the
     instant simple_switch_grpc calls bind(), and bmv2 then dies with EADDRINUSE. Observed
     2026-08-18: 8 of 10 switches came up, and by the time anyone looked the two guilty ports
     were free again -- which is exactly why the diagnostic blamed a leftover switch that had
     never existed. (doc/audit/2026-08-18_live-full-stack-round/subagent-round2-FINDINGS.md)

The Thrift ports were never affected: 9091-9100 sit below 32768. That is the control: the
same line of code assigns both, and only the one inside the range fails.

The fix is a block below the range plus a pre-flight that *checks* rather than assumes. The
check matters more than the constant: ip_local_port_range is a sysctl, so a machine we do not
own can move the floor under us, and a number that was safe when it was chosen is not
evidence that it is safe on the machine about to run the demo.

The check also accepts the other legitimate arrangement -- a block inside the range that is
listed in ip_local_reserved_ports -- so a site that prefers to reserve rather than move is
not fighting the pre-flight.
"""

import os

#: The gRPC port for device N is GRPC_PORT_BASE + N. Devices are 1-based, so the ten-switch
#: fabric occupies 30051-30060.
#:
#: 30050 rather than 50050: the whole block must stay below ip_local_port_range's floor
#: (32768 on stock Linux, and the lowest floor seen in the wild is well above 30178). At
#: 30050 the fabric has room for 2717 switches before it reaches 32768, against the ten it
#: has today. Nothing else in this project listens anywhere near it -- the occupied numbers
#: are 6343 (sFlow), 6633/6653 (OpenFlow), 8000 (kernel), 8080 (Ryu), 8081 (proxy) and
#: 9091-9100 (bmv2 Thrift).
GRPC_PORT_BASE = 30050

#: The Thrift port for device N. Unchanged, and only here so both numbers live in one file.
THRIFT_PORT_BASE = 9090

EPHEMERAL_RANGE_PATH = "/proc/sys/net/ipv4/ip_local_port_range"
RESERVED_PORTS_PATH = "/proc/sys/net/ipv4/ip_local_reserved_ports"

#: Set to "1" to run anyway after the pre-flight refuses. An escape hatch, deliberately not a
#: default: the failure it suppresses is random and partial, so "it worked last time" is not
#: evidence. Taking it must be a decision someone made, not something that happened.
OVERRIDE_ENV = "NDTWIN_ALLOW_EPHEMERAL_GRPC_PORTS"


class PortBlockError(Exception):
    """The configured gRPC port block cannot be trusted on this machine."""


def grpc_port(device_id, base=GRPC_PORT_BASE):
    """The gRPC port for one device id."""
    return base + device_id


def thrift_port(device_id, base=THRIFT_PORT_BASE):
    """The Thrift port for one device id."""
    return base + device_id


def grpc_port_block(device_ids, base=GRPC_PORT_BASE):
    """Every gRPC port the fabric will try to bind, in device order."""
    return [grpc_port(d, base) for d in device_ids]


def read_ephemeral_range(path=EPHEMERAL_RANGE_PATH):
    """
    The kernel's ephemeral port range as (low, high), or None when it cannot be read.

    None means "unknown", never "safe" -- see check_port_block, which refuses on None. A
    check that treats an unreadable file as a pass is the empty-conflated-with-success shape
    this repo keeps rediscovering.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            fields = fh.read().split()
    except OSError:
        return None
    try:
        low, high = int(fields[0]), int(fields[1])
    except (IndexError, ValueError):
        return None
    return (low, high)


def read_reserved_ports(path=RESERVED_PORTS_PATH):
    """
    The set of ports listed in ip_local_reserved_ports.

    The file's format is a comma-separated list of numbers and inclusive `a-b` ranges, and it
    is empty by default. Ports listed here are never handed out as ephemeral ports, so a block
    inside the range but fully reserved is as safe as a block outside it. Returns an empty set
    when the file is missing -- which is the truth: nothing is reserved.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read().strip()
    except OSError:
        return set()
    reserved = set()
    for token in text.replace(",", " ").split():
        try:
            if "-" in token:
                lo, hi = token.split("-", 1)
                reserved.update(range(int(lo), int(hi) + 1))
            else:
                reserved.add(int(token))
        except ValueError:
            # A token we cannot parse is not a licence to assume the port is reserved.
            continue
    return reserved


def ports_at_risk(ports, ephemeral_range, reserved=frozenset()):
    """
    The ports that sit inside the ephemeral range without being reserved, sorted.

    Empty means the block is safe on a machine with this range and this reservation list.
    """
    if ephemeral_range is None:
        return sorted(ports)
    low, high = ephemeral_range
    return sorted(p for p in ports if low <= p <= high and p not in reserved)


def check_port_block(ports, range_path=EPHEMERAL_RANGE_PATH,
                     reserved_path=RESERVED_PORTS_PATH):
    """
    Why this port block is unsafe on this machine, or None when it is safe.

    Returns a message rather than raising so a caller can decide what to do with it; the
    raising wrapper is assert_port_block_is_safe below.
    """
    ephemeral_range = read_ephemeral_range(range_path)
    if ephemeral_range is None:
        return (f"cannot read the kernel's ephemeral port range from {range_path}, so there "
                f"is no way to tell whether gRPC ports {min(ports)}-{max(ports)} are safe to "
                f"bind. Unknown is not safe: a port inside that range can be taken by any "
                f"unrelated socket at the moment bmv2 binds it, and the switch then dies of "
                f"EADDRINUSE. Set {OVERRIDE_ENV}=1 to proceed anyway.")

    reserved = read_reserved_ports(reserved_path)
    at_risk = ports_at_risk(ports, ephemeral_range, reserved)
    if not at_risk:
        return None

    low, high = ephemeral_range
    shown = ", ".join(str(p) for p in at_risk[:8])
    if len(at_risk) > 8:
        shown += f", ... ({len(at_risk)} ports in total)"
    return (f"gRPC ports {shown} lie inside the kernel's ephemeral port range {low}-{high} "
            f"({range_path}) and are not listed in {reserved_path}. The kernel hands those "
            f"numbers out to any socket that did not name its own port, so a switch will "
            f"randomly fail to bind and exit -- and the port is usually free again by the "
            f"time anyone looks, which makes the failure look like a leftover process. "
            f"Fix it one of two ways: move the block below {low} (edit GRPC_PORT_BASE in "
            f"p4_proxy/mininet/grpc_ports.py), or reserve it with "
            f"`net.ipv4.ip_local_reserved_ports` (a sysctl -- a human applies it, and it must "
            f"go in /etc/sysctl.d/ to survive a reboot). Set {OVERRIDE_ENV}=1 to proceed "
            f"anyway.")


def assert_port_block_is_safe(ports, range_path=EPHEMERAL_RANGE_PATH,
                              reserved_path=RESERVED_PORTS_PATH, env=None):
    """
    Raise PortBlockError unless this port block can be bound reliably on this machine.

    Honours OVERRIDE_ENV, which downgrades the refusal to a returned warning string.
    """
    env = os.environ if env is None else env
    problem = check_port_block(ports, range_path, reserved_path)
    if problem is None:
        return None
    if env.get(OVERRIDE_ENV) == "1":
        return f"WARNING ({OVERRIDE_ENV}=1, proceeding anyway): {problem}"
    raise PortBlockError(problem)
