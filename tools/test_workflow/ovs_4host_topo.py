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

    sudo /home/adam/miniconda3/envs/ntg-env/bin/python tools/test_workflow/ovs_4host_topo.py
"""

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
    print('Kernel model: setting/StaticNetworkTopologyOVS_10Switches_4Hosts.json')
    print('=' * 70 + '\n')

    CLI(net)
    net.stop()


if __name__ == '__main__':
    main()
