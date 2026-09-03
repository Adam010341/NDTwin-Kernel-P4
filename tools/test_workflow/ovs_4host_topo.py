#!/usr/bin/env python3
"""
OVS on the P4 test bed's topology: 10 switches, 4 hosts -- the matched cell.

[Co-developed with claude code -- Adam]

Why this exists (2026-08-17): every P4-vs-OVS result we had was measured across two
*different* topologies -- the P4 side on p4_testbed_topo.py (10 switches / 4 hosts /
40 edges) and the OVS side on testbed_topo.py (10 switches / 128 hosts / 288 edges).
So "P4 self-heals in 12.5 s, OVS blackholes for 291 s" varied the data plane, the
controller, and the path diversity all at once, and cannot be attributed to any one of
them. This file holds the topology constant so the data plane is the only variable.

Two deliberate departures from testbed_topo.py, both for parity with the P4 side:

  * No `bw=` on any link. testbed_topo.py shapes with TCLink (1000/10000 Mbps) while
    p4_testbed_topo.py shapes nothing at all -- on the P4 side the only limit is bmv2's
    forwarding speed. Shaping one side and not the other is exactly the confound this
    file is meant to remove, so neither side is shaped.
  * 4 hosts on s1..s4 port 3, with the same IPs and MACs the P4 topology assigns, and
    the same static ARP mesh and offload disabling.

The inter-switch links below are copied from testbed_topo.py and verified pair-by-pair
against p4_testbed_topo.py: same endpoints, same port numbers, all sixteen.

Pairs with setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json, which is the P4
model with brand_name flipped BMv2 -> OVS. That field is what the kernel reads to decide
whether to talk to the P4 proxy or to Ryu (FlowLinkUsageCollector::controlPlaneHostAndPort
-> usesIdentityPortMapping, true only when every switch is BMV2).

Ryu must already be listening on 6653 before this runs. The port is passed explicitly
rather than left to Mininet's probe: with no port, RemoteController tries 6653 then 6633
and falls back to 6653 when neither answers, which silently masks a controller that is
not up yet.

The other half of that -- a controller from the PREVIOUS round still listening, which the
same probe adopts just as silently -- is no longer only written down. It is rows 6653 and
6633 of tools/test_workflow/ports.sh, which `ndt clean`, `ndt down --deep` and the bring-up
preflight all read, and which name the holder and the consequence when either is held.
Keep this paragraph and that row in step: this one says why the port is hard-coded here,
the row says what a leftover on it costs.

sFlow (added 2026-09-03, finding #4). Until this change the file had ZERO sFlow references, so
all ten bridges came up with `sflow=[]` while the kernel listened on :6343 as usual. Nothing
failed: `/ndt/get_average_link_usage` answered `{"avg_link_usage":0.0,"status":"success"}` under
3000 packets of real traffic, and every per-flow rate read zero. "We never asked" and "the
network is idle" were the same output, on every channel. The reference topology testbed_topo.py
-- the one `ndt up ovs` (128 hosts) runs -- has done this since it was written; only this
fixture was missing it. See configure_sflow() below for the parameters and why each is what
testbed_topo.py already uses.

    sudo /home/adam/miniconda3/envs/ntg-env/bin/python tools/test_workflow/ovs_4host_topo.py
"""

import re
import subprocess
import sys
import threading  # the pre-rule discovery burst below runs its pings in parallel

sys.path.append('/usr/lib/python3/dist-packages')


from mininet.cli import CLI
from mininet.log import setLogLevel
from mininet.net import Mininet
from mininet.node import OVSKernelSwitch, RemoteController
from mininet.topo import Topo

HOST_NUM = 4
CONTROLLER_IP = '127.0.0.1'
CONTROLLER_PORT = 6653

# --- sFlow -----------------------------------------------------------------------------------
# [Co-developed with claude code -- Adam]
#
# Every value here is testbed_topo.py's. Do not invent a second set: the kernel's model file
# encodes one of them, so the two files are not merely "similar", they have to agree.
#
# 🔴 SFLOW_AGENT_IP_BASE/FIRST is the one that is load-bearing, and it is not a style choice.
# The kernel identifies a sample's switch by the AGENT ADDRESS carried inside the sFlow
# datagram (FlowLinkUsageCollector.cpp: `uint32_t agentIp = data[2]`), then looks up the edge
# whose src_ip matches (TopologyAndFlowMonitor::findEdgeByAgentIpAndPort compares
# `props.srcIp.front()`). setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json declares
# s1..s10 as 192.168.123.11..20 -- so an agent that reports anything else is parsed, accepted,
# matched against no edge, and contributes nothing, which looks exactly like the defect this
# change is fixing. That is why the mgmt IP is assigned to the agent interface first: OVS reads
# the agent address off that interface, and an agent interface with no IPv4 makes OVS fall back
# to the source address of the route to the collector -- one address for all ten switches.
SFLOW_COLLECTOR_IP = '127.0.0.1'
SFLOW_COLLECTOR_PORT = 6343    # the kernel's collector; ports.sh row 6343 says what a squatter costs
SFLOW_HEADER = 128
SFLOW_SAMPLING = 256
SFLOW_POLLING = 0
SFLOW_AGENT_IP_BASE = '192.168.123.'
SFLOW_AGENT_IP_FIRST = 11      # s1 -> .11, so sN -> .(10 + N); matches the model file, above
SFLOW_AGENT_PREFIX_LEN = 24


def sflow_agent_ip(bridge):
    """The agent address for a bridge, as the kernel's topology model declares it.

    `s7` -> `192.168.123.17`. The trailing integer is the dpid; the model file keys its
    switches the same way, and tests/python/test_ovs4_sflow.py asserts the two agree rather
    than trusting this comment.
    """
    m = re.fullmatch(r's(\d+)', bridge)
    if not m:
        raise ValueError(f'not a switch name this topology builds: {bridge!r}')
    return f'{SFLOW_AGENT_IP_BASE}{SFLOW_AGENT_IP_FIRST + int(m.group(1)) - 1}'


def sflow_agent_iface(intf_names):
    """testbed_topo.py's find_ovs_agent_iface, over the interface names of one switch.

    The first non-loopback interface of the bridge. Kept identical in behaviour to the
    reference topology so the two fabrics present the same agent to the collector.
    """
    for name in intf_names:
        if not name.startswith('lo') and 's' in name:
            return name
    return None


def agent_ip_argv(iface, ip):
    return ['ifconfig', iface, f'{ip}/{SFLOW_AGENT_PREFIX_LEN}', 'up']


def sflow_create_argv(bridge, iface):
    """testbed_topo.py's enable_sflow command, as argv rather than a shell string.

    The elements are byte-for-byte what ovs-vsctl receives there -- including the literal
    quotes around `target=`, which in that file are written `\\"` for os.system's shell and
    arrive at ovs-vsctl as part of the value. Passing argv instead of a shell string is the
    only departure, and it is what lets the exit status be read: os.system's return value was
    discarded there, so `set bridge s11 sflow=@sflow` against a bridge that does not exist was
    indistinguishable from success.
    """
    target = f'{SFLOW_COLLECTOR_IP}:{SFLOW_COLLECTOR_PORT}'
    return [
        'ovs-vsctl',
        '--', '--id=@sflow', 'create', 'sflow',
        f'agent={iface}',
        f'target="{target}"',
        f'header={SFLOW_HEADER}',
        f'sampling={SFLOW_SAMPLING}',
        f'polling={SFLOW_POLLING}',
        '--', 'set', 'bridge', bridge, 'sflow=@sflow',
    ]


def run_checked(argv):
    """Run argv and raise on a non-zero exit status. The seam the tests replace."""
    subprocess.run(argv, check=True)


def configure_sflow(bridges, run=run_checked):
    """Point every bridge's sFlow at the kernel's collector. Returns the bridges configured.

    `bridges` is a sequence of (bridge_name, interface_names). Each bridge is configured
    exactly once: OVS would happily accept a second `create sflow` and leave an unreferenced
    record behind in the database, which is why `ndt`'s verify counts records as well as
    references.

    polling=0 disables counter samples, and that is correct here -- do not "fix" it. The
    reasoning is written out in testbed_topo.py: in MININET mode the kernel discards every
    counter sample (FlowLinkUsageCollector.cpp, the `m_mode == utils::MININET` early continue
    in the sampleType 2 branch) and derives link utilisation from FLOW samples instead. The
    0.0 that once looked like a polling problem was a measurement across a single switch,
    which getAvgLinkUsage does not count. Enabling polling buys nothing and only adds
    datagrams.
    """
    configured = []
    for bridge, intf_names in bridges:
        iface = sflow_agent_iface(intf_names)
        if iface is None:
            raise RuntimeError(
                f'{bridge} has no non-loopback interface to use as the sFlow agent; '
                f'without one OVS reports the same agent address for every switch and the '
                f'kernel matches the samples to no edge')
        run(agent_ip_argv(iface, sflow_agent_ip(bridge)))
        run(sflow_create_argv(bridge, iface))
        configured.append(bridge)
    return configured


class MatchedTopo(Topo):
    def __init__(self, **opts):
        Topo.__init__(self, **opts)

        s = {i: self.addSwitch(f's{i}') for i in range(1, 11)}

        # Edge -> aggregation.
        self.addLink(s[1], s[5], port1=1, port2=1)
        self.addLink(s[1], s[6], port1=2, port2=1)
        self.addLink(s[2], s[5], port1=1, port2=2)
        self.addLink(s[2], s[6], port1=2, port2=2)
        self.addLink(s[3], s[7], port1=1, port2=1)
        self.addLink(s[3], s[8], port1=2, port2=1)
        self.addLink(s[4], s[7], port1=1, port2=2)
        self.addLink(s[4], s[8], port1=2, port2=2)

        # Aggregation -> core.
        self.addLink(s[5], s[9], port1=3, port2=1)
        self.addLink(s[5], s[10], port1=4, port2=1)
        self.addLink(s[6], s[9], port1=3, port2=2)
        self.addLink(s[6], s[10], port1=4, port2=2)
        self.addLink(s[7], s[9], port1=3, port2=3)
        self.addLink(s[7], s[10], port1=4, port2=3)
        self.addLink(s[8], s[9], port1=3, port2=4)
        self.addLink(s[8], s[10], port1=4, port2=4)

        # One host per edge switch, on port 3 -- same as p4_testbed_topo.py.
        for i in range(1, HOST_NUM + 1):
            h = self.addHost(f'h{i}', ip=f'10.0.0.{i}/24',
                             mac=f'00:00:00:00:00:{i:02x}')
            self.addLink(h, s[i], port1=1, port2=3)


def disable_host_offloads(hosts):
    """
    Kept for parity with the P4 side, where it is load-bearing.

    On bmv2 this is the difference between working and stalled bulk TCP (its pcap path
    re-emits frames byte-for-byte, so a segment with checksum offload still pending
    arrives corrupt). OVS does not need it. It is here anyway because leaving it on for
    one data plane and off for the other would put a TCP-behaviour difference into a
    comparison that is supposed to isolate the data plane.
    """
    for h in hosts:
        for intf in h.intfList():
            if intf.name != 'lo':
                h.cmd(f'ethtool -K {intf.name} tx off rx off gso off tso off gro off')


def main():
    setLogLevel('info')

    # Deliberately NO `mn -c` here, unlike p4_testbed_topo.py.
    #
    # Mininet's cleanup killalls a list of "zombies" that includes ryu-manager
    # (mininet/clean.py: 'ovs-testcontroller udpbwtest mnexec ivs ryu-manager'). On the P4
    # side that is harmless -- there is no Ryu -- so the habit is safe there and copying it
    # here looked safe too. In OVS mode the controller has to be listening *before* the
    # switches start, so this line kills the very thing the topology is about to connect to,
    # and the only symptom is switches that never appear in Ryu's topology view. Measured
    # 2026-08-17: bridges up, `ovs-vsctl get-controller s1` correct, Ryu simply gone.
    #
    # The environment is cleaned by `ndtwin-lab topo-stop` / `cleanup` before this runs, and
    # stack.sh separately refuses to start Ryu while a Mininet is live.

    net = Mininet(
        topo=MatchedTopo(),
        controller=lambda name: RemoteController(name, ip=CONTROLLER_IP,
                                                 port=CONTROLLER_PORT),
        switch=OVSKernelSwitch,
        autoSetMacs=True,
    )
    net.start()

    # [Co-developed with claude code -- Adam]
    # Before the hosts, because the discovery burst below is the first traffic on the fabric and
    # a bridge that is not sampling yet contributes nothing to it. See the sFlow block at the
    # top of this file for the parameters and for why the agent IP is the load-bearing one.
    switches = [(sw.name, [i.name for i in sw.intfList()]) for sw in net.switches]
    print(f'Configuring sFlow on {len(switches)} bridges -> '
          f'{SFLOW_COLLECTOR_IP}:{SFLOW_COLLECTOR_PORT}')
    configure_sflow(switches)
    # Same line testbed_topo.py prints, for the same reason: the tmux pane is where an operator
    # looks first, and `ndt up ovs4`'s verify reads the same table independently.
    subprocess.run(['ovs-vsctl', 'list', 'sflow'], check=False)

    hosts = [net.get(f'h{i}') for i in range(1, HOST_NUM + 1)]
    for src in hosts:
        for dst in hosts:
            if src != dst:
                src.cmd(f'arp -s {dst.IP()} {dst.MAC()}')

    disable_host_offloads(hosts)

    # [Co-developed with claude code -- Adam]
    # Every host pings every other, in parallel, right here -- and the position in this file is
    # the whole point, not the pings.
    #
    # Ryu learns a host's IP only from a packet it is punted. intelligent_router installs
    # proactive rules once it has discovered the topology, and after that traffic is forwarded in
    # the data plane and never reaches the controller. So a burst that lands *before* the rules
    # populates `ipv4`, and the identical burst a minute later does not.
    #
    # Measured side by side on 2026-08-17: testbed_topo.py does this and had 128/128 hosts
    # carrying IPs; this fixture did not and had 0/4 after thousands of pings. `updateHosts`
    # skips a host with an empty ipv4, so those four hosts and their edges read *down* in the twin
    # while all ten switches read up -- which made the whole cell unusable for host-level
    # assertions. It did not affect the failover numbers measured in that cell, because those were
    # real ICMP through the data plane rather than anything the twin reported.
    #
    # This refines the earlier reading that static ARP was to blame: the `arp -s` lines above stay,
    # and the hosts are discovered anyway. What matters is the ordering against rule installation.
    print(f'Priming controller host discovery: {HOST_NUM}x{HOST_NUM - 1} pings, before rules land')
    threads = []
    for src in hosts:
        for dst in hosts:
            if src is not dst:
                t = threading.Thread(target=lambda s=src, d=dst: s.cmd(f'ping -c 1 -W 1 {d.IP()}'))
                threads.append(t)
                t.start()
    for t in threads:
        t.join()

    print('\n' + '=' * 70)
    print(f'OVS matched topology up: 10 switches, {HOST_NUM} hosts, 40 directed edges.')
    print(f'Controller: {CONTROLLER_IP}:{CONTROLLER_PORT} (Ryu must already be listening)')
    print(f'sFlow: {len(switches)} bridges -> {SFLOW_COLLECTOR_IP}:{SFLOW_COLLECTOR_PORT}, '
          f'agents {sflow_agent_ip("s1")}-{sflow_agent_ip(f"s{len(switches)}")}')
    print('Kernel model: setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json')
    print('=' * 70 + '\n')

    CLI(net)
    net.stop()


if __name__ == '__main__':
    main()
