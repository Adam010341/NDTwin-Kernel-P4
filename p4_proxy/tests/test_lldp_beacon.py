"""
Tests for the LLDP beacon the proxy uses to discover inter-switch links.

[Co-developed with claude code -- Adam]

Three defects, all of them quiet:

  - **The source MAC was a host's.** `00:00:00:00:00:{dpid:02x}` is exactly the range main.py
    registers hosts in (h1-h4 are :01 through :04), so every beacon from s1-s4 claimed to come from
    a host, on every inter-switch port. Anything learning from those addresses is told those hosts
    are everywhere.
  - **It crashed for dpid >= 256.** `bytes.fromhex(f"...{dpid:02x}")` gets three hex digits, and
    `fromhex` rejects an odd-length string. Not reachable on a 10-switch topology, which is why it
    survived.
  - **The port list was `range(1, 7)` for every switch.** s1-s4 have three interfaces and s5-s10
    have four, so two to three beacons per switch per round went to a port that does not exist --
    and on s1-s4 one of the three real ports faces a host, so only two could ever find a link.

Ports now come from the topology file the kernel reads, which is also where the sFlow agent IPs come
from. The two must not disagree about the topology.

unittest rather than pytest: l1_unit_tests.sh executes each of these files directly and parses
"Ran N tests".
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from proxy_agent.topology_manager import (  # noqa: E402
    LLDP_BEACON_INTERVAL_S,
    LLDP_FALLBACK_PORTS,
    TopologyManager,
    lldp_source_mac,
    load_switch_link_ports,
)

#: The MACs main.py gives the four hosts. A beacon must never carry one of these.
HOST_MACS = {bytes.fromhex(f"0000000000{n:02x}") for n in (1, 2, 3, 4)}

TOPO = os.path.join(
    os.path.dirname(__file__), "..", "..", "setting",
    "StaticNetworkTopologyP4_10Switches_4Hosts.json",
)


class SourceMacTest(unittest.TestCase):
    def test_it_is_never_a_host_mac(self):
        # The defect, stated directly. dpid 1-4 are the collisions that actually existed.
        for dpid in range(1, 11):
            self.assertNotIn(
                lldp_source_mac(dpid),
                HOST_MACS,
                f"the beacon from s{dpid} is sourced from a host's address",
            )

    def test_it_is_locally_administered_unicast(self):
        # Locally administered so it cannot collide with a real vendor's assignment, and unicast so
        # it is a legal source address.
        first = lldp_source_mac(1)[0]
        self.assertTrue(first & 0x02, f"not locally administered: 0x{first:02x}")
        self.assertFalse(first & 0x01, f"multicast bit set on a source address: 0x{first:02x}")

    def test_it_is_six_bytes_for_every_dpid_including_ones_that_used_to_crash(self):
        # bytes.fromhex(f"...{dpid:02x}") raised ValueError for anything >= 256: three hex digits is
        # an odd-length string. Unreachable on this topology, which is why it was never seen.
        for dpid in (0, 1, 255, 256, 4095, 65535, 65536, 70000, 2**32):
            mac = lldp_source_mac(dpid)
            self.assertEqual(len(mac), 6, f"dpid {dpid} produced {len(mac)} bytes")

    def test_distinct_switches_get_distinct_addresses(self):
        macs = {lldp_source_mac(d) for d in range(1, 11)}
        self.assertEqual(len(macs), 10, "two switches share a beacon source MAC")

    def test_the_dpid_a_receiver_acts_on_comes_from_the_payload_not_the_mac(self):
        # Which is why masking the dpid into two bytes is acceptable: a collision 65536 apart costs
        # nothing. Pinned so nobody "fixes" the mask by widening the MAC and assumes it is parsed.
        topo = TopologyManager()
        packet = topo.create_lldp_packet(70000, 3)
        self.assertEqual(topo.parse_lldp_packet(packet), (70000, 3))


class BeaconPacketTest(unittest.TestCase):
    def setUp(self):
        self.topo = TopologyManager()

    def test_the_packet_round_trips_through_the_parser(self):
        for dpid, port in ((1, 1), (10, 4), (255, 2)):
            packet = self.topo.create_lldp_packet(dpid, port)
            self.assertEqual(self.topo.parse_lldp_packet(packet), (dpid, port))

    def test_it_is_addressed_to_the_lldp_multicast_group_with_the_lldp_ethertype(self):
        packet = self.topo.create_lldp_packet(1, 1)
        self.assertEqual(packet[0:6], bytes.fromhex("0180c200000e"))
        self.assertEqual(packet[12:14], bytes.fromhex("88cc"), "not 0x88cc, so nothing parses it")


class LinkPortsTest(unittest.TestCase):
    def test_the_ports_match_the_topology_file(self):
        # s1-s4 have two inter-switch ports (the third faces a host); s5-s10 have four. Confirmed
        # against the live fabric with `ip link` before this was written.
        ports = load_switch_link_ports(TOPO)
        for dpid in range(1, 5):
            self.assertEqual(ports.get(dpid), (1, 2), f"s{dpid}")
        for dpid in range(5, 11):
            self.assertEqual(ports.get(dpid), (1, 2, 3, 4), f"s{dpid}")

    def test_host_facing_ports_are_excluded(self):
        # Port 3 on s1-s4 faces a host. A beacon there is answered by nothing, and before the source
        # MAC was fixed it announced that host's own address back at it.
        ports = load_switch_link_ports(TOPO)
        for dpid in range(1, 5):
            self.assertNotIn(3, ports[dpid], f"s{dpid} would beacon at its host")

    def test_no_switch_is_told_to_beacon_on_a_port_that_does_not_exist(self):
        # The old range(1, 7) sent to ports 3-6 on s1-s4 and 5-6 on s5-s10.
        real_interfaces = {**{d: 3 for d in range(1, 5)}, **{d: 4 for d in range(5, 11)}}
        ports = load_switch_link_ports(TOPO)
        for dpid, highest in real_interfaces.items():
            for port in ports[dpid]:
                self.assertLessEqual(port, highest, f"s{dpid} has no port {port}")

    def test_an_unreadable_topology_gives_nothing_rather_than_raising(self):
        # It is read at construction, so raising here would stop the proxy from starting.
        self.assertEqual(load_switch_link_ports("/nonexistent/topology.json"), {})

    def test_a_malformed_topology_gives_nothing_rather_than_raising(self):
        import tempfile

        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            fh.write("{not json")
            path = fh.name
        try:
            self.assertEqual(load_switch_link_ports(path), {})
        finally:
            os.unlink(path)


class BeaconPortSelectionTest(unittest.TestCase):
    def test_it_uses_the_topology_ports_when_they_are_known(self):
        topo = TopologyManager()
        topo._link_ports = {1: (1, 2), 5: (1, 2, 3, 4)}
        self.assertEqual(topo.lldp_ports_for(1), (1, 2))
        self.assertEqual(topo.lldp_ports_for(5), (1, 2, 3, 4))

    def test_an_unknown_switch_falls_back_rather_than_beaconing_nowhere(self):
        # Returning an empty list would mean no discovery at all for that switch, which is a worse
        # failure than sending to a port that may not exist.
        topo = TopologyManager()
        topo._link_ports = {1: (1, 2)}
        self.assertEqual(topo.lldp_ports_for(99), LLDP_FALLBACK_PORTS)

    def test_the_fallback_is_reported_once_not_every_round(self):
        # The loop runs every 5 seconds forever; a warning per switch per round is how the last log
        # flood happened.
        topo = TopologyManager()
        topo._link_ports = {}
        topo._link_ports_warned = False
        topo.lldp_ports_for(1)
        self.assertTrue(topo._link_ports_warned)
        # Second call must not re-arm it.
        topo.lldp_ports_for(2)
        self.assertTrue(topo._link_ports_warned)


class BeaconIntervalTest(unittest.TestCase):
    def test_it_leaves_room_for_one_missed_round_in_the_kernels_freshness_window(self):
        # The kernel treats a beacon older than kLldpFreshSeconds (12 s) as no evidence. Two
        # intervals must fit inside that, or one dropped beacon makes a healthy switch look stale
        # and a failed gRPC probe then reads as Down.
        kernel_lldp_fresh_seconds = 12.0
        self.assertLess(
            2 * LLDP_BEACON_INTERVAL_S,
            kernel_lldp_fresh_seconds,
            "changing the beacon interval requires changing kLldpFreshSeconds in "
            "DeviceConfigurationAndPowerManager.hpp",
        )


if __name__ == "__main__":
    unittest.main()
