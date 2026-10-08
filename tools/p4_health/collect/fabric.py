"""The fabric oracle: veth peers, and the address and MAC inside each host's namespace.

[Co-developed with claude code -- Adam]

TP1 compares get_graph_data with this, item by item. Host namespaces are entered with
`sudo -n mnexec -a <pid>`, the pid found by the tail-field rule drive_exercise.py uses
(`ps -eo pid=,args=` lines ending in `mininet:<host>`, drive_exercise.py:1024-1038).
"""
from __future__ import annotations

import re


def host_pid(ps_lines, host):
    """The pid of the namespace shell for `host`, or None (the TAIL field, exactly)."""
    if ps_lines is None:
        return None
    tag = "mininet:%s" % host
    pids = [line.split()[0] for line in ps_lines
            if len(line.split()) >= 2 and line.split()[-1] == tag and line.split()[0].isdigit()]
    return pids[0] if len(pids) == 1 else None


def veth_peers(ip_link_text):
    """{iface: its veth peer} from `ip -o link show`. iproute2 prints the peer two ways
    (Cut 2 review MAJOR-1; seen with iproute2-6.1.0, the gate log r2/veth_format.log):

        3: s1-eth4@s2-eth2: ...    the peer is in the SAME namespace -> its NAME (a str)
        5: s1-eth1@if2: ...        the peer is in ANOTHER namespace -> its ifindex THERE (an int)

    A Mininet fabric's switches live in the root namespace, so every switch-to-switch link is the
    first kind and every host-facing port the second. An interface printed with no `@` is not in
    the map. None when there is no text."""
    out = {}
    if ip_link_text is None:
        return None
    for line in ip_link_text.splitlines():
        m = re.match(r"^(\d+):\s+([^@:\s]+)@([^:\s]+):", line)
        if not m:
            continue
        peer = m.group(3)
        idx = re.match(r"^if(\d+)$", peer)
        out[m.group(2)] = int(idx.group(1)) if idx else peer
    return out


def ifindex(ip_link_text):
    out = {}
    for line in (ip_link_text or "").splitlines():
        m = re.match(r"^(\d+):\s+([^@:\s]+)[@:]", line)
        if m:
            out[m.group(2)] = int(m.group(1))
    return out


def host_addr(ip_addr_text):
    """(ipv4, mac) of eth0 inside a host namespace, from `ip -o addr show dev eth0` and
    `ip -o link show dev eth0` concatenated; None when either is missing."""
    if not ip_addr_text:
        return None
    ip = re.search(r"\binet (\d+\.\d+\.\d+\.\d+)/", ip_addr_text)
    mac = re.search(r"link/ether ([0-9a-f:]{17})", ip_addr_text)
    if not ip or not mac:
        return None
    return ip.group(1), mac.group(1)


def checksum_offload_off(ethtool_text):
    """True/False for `tx-checksumming: off|on` in `ethtool -k` output; None if absent."""
    if not ethtool_text:
        return None
    m = re.search(r"^tx-checksumming:\s+(on|off)", ethtool_text, re.M)
    return None if m is None else m.group(1) == "off"
