"""
A destination-only delete must hand ipv4_lpm back to the control plane, not empty it.

[Co-developed with claude code -- Adam]

## What was wrong (doc/KNOWN-ISSUES.md A-4d)

`ipv4_lpm` keys on the destination alone and holds **one entry per destination**
(`ndtwin_switch.p4:350-363`). Both writers use the same key: `install_initial_routes` writes
`dst/32` at `topology_manager.py:1061`, and an application's `POST /stats/flowentry/add` writes
`dst/32` at `topology_manager.py:897`. The second write cannot add a second entry, so
`insert_ipv4_route`'s INSERT is refused and its MODIFY fallback (`p4_client.py:855`) *replaces*
the control plane's routing entry in place.

`unroute_flow` then deleted that entry -- the only one the destination had. `ipv4_lpm`'s
`default_action` is `send_to_cpu()`, and `handle_packet_in` parses LLDP and drops everything
else, so the destination became a black hole: measured at 0 MB and 100% ping loss.

The same two calls are safe under OVS, where a migration at priority 100 layers over the
router's rule at priority 10 and deleting the top one uncovers the one underneath. There is no
"underneath" on a single-key LPM table. The equivalent is to give the slot back to the control
plane, which is what these tests pin.

## The three assertions that carry this file

1. **After install-then-delete the switch still forwards the destination.** This is A-4d
   itself, asserted on the sequence that produced it rather than on either call alone.
2. **The restore is one `insert_ipv4_route`, not a delete followed by an insert.** The entry
   exists, so that call lands as a MODIFY and swaps the port in place. A DELETE+INSERT pair
   would leave a window with no entry at all, which is the same black hole for as long as it
   lasts.
3. **A destination the control plane cannot route is still really deleted.** Without this the
   suite would pass on a proxy that had simply stopped deleting, which is a different defect,
   not a fix.

`RecordingClient` deliberately records the *table and verb*, not just the arguments: the whole
defect is which verb reached which table, and a double that only remembered arguments could not
tell a restore from a delete.
"""

from __future__ import annotations

import os
import sys
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

import networkx as nx  # noqa: E402

from proxy_agent import topology_manager as tm  # noqa: E402

#: The destination under test, and the two ports it can leave switch 1 by.
DST = "10.0.0.1"
DST_MAC = "00:00:00:00:00:01"
CONTROL_PLANE_PORT = 2   # what install_initial_routes computes for (switch 1 -> DST)
MIGRATED_PORT = 3        # where a TE application moves the traffic to


class RecordingClient:
    """Stands in for P4RuntimeClient, recording which table each write went to."""

    def __init__(self, verdict=True):
        self.verdict = verdict
        self.calls = []

    def insert_ipv4_route(self, dst_ip, prefix_len, mac, port):
        self.calls.append(("lpm_insert", dst_ip, prefix_len, port))
        return self.verdict

    def delete_ipv4_route(self, dst_ip, prefix_len):
        self.calls.append(("lpm_delete", dst_ip, prefix_len))
        return self.verdict

    def modify_ipv4_route(self, dst_ip, prefix_len, mac, port):
        self.calls.append(("lpm_modify", dst_ip, prefix_len, port))
        return self.verdict

    def insert_5tuple_rule(self, keys, priority, mac, port):
        self.calls.append(("5t_insert", dict(keys), priority, port))
        return self.verdict

    def modify_5tuple_rule(self, keys, priority, mac, port):
        self.calls.append(("5t_modify", dict(keys), priority, port))
        return self.verdict

    def delete_5tuple_rule(self, keys, priority):
        self.calls.append(("5t_delete", dict(keys), priority))
        return self.verdict


def manager_with(client, routed=True):
    """
    A TopologyManager holding the smallest fabric that can show the defect.

    `1 -- 2 -- DST`, so the control plane's route for DST out of switch 1 is
    CONTROL_PLANE_PORT. A real networkx graph rather than a stand-in, because the restore
    reads `net.edges[u, v]["port"]` exactly the way `install_initial_routes` does and a
    looser double would not catch a wrong lookup.

    `routed=False` drops the path, standing for a destination the control plane has no route
    to -- after a failure that disconnected it, or one it never routed at all.
    """
    mgr = tm.TopologyManager.__new__(tm.TopologyManager)
    mgr.switches = {1: client}
    mgr._net_lock = threading.RLock()
    mgr._installed_routes = {}
    # The flow methods also journal what the switch accepted (KNOWN-ISSUES A-4c), and
    # unroute_flow reaches _note_in_journal on every path this file drives. None is the
    # no-journal mode every existing construction site uses, so nothing here changes -- but
    # __init__ always sets it, and a double that omits it is narrower than the object it
    # stands in for. Same reasoning, and same value, as the double in test_five_tuple_match.py.
    # [Co-developed with claude code -- Adam]
    mgr._journal = None

    net = nx.DiGraph()
    net.add_node(1, type="switch")
    net.add_node(2, type="switch")
    net.add_node(DST, type="host", mac=DST_MAC)
    net.add_edge(1, 2, port=CONTROL_PLANE_PORT)
    net.add_edge(2, DST, port=1)
    mgr.net = net

    mgr.dest_paths = {}
    if routed:
        mgr.dest_paths = {DST: {1: {"path": [1, 2, DST], "length": 2}}}
    return mgr


def lpm_writes(client):
    """Just the ipv4_lpm traffic, in order."""
    return [c for c in client.calls if c[0].startswith("lpm_")]


class DeleteRestoresTheControlPlaneRoute(unittest.TestCase):

    def test_install_then_delete_leaves_the_destination_forwarding(self):
        # A-4d as measured: an application migrates the destination, then withdraws its own
        # rule. What the switch is left holding is the whole question.
        c = RecordingClient()
        mgr = manager_with(c)

        mgr.route_flow(1, {"nw_dst": DST}, [{"type": "OUTPUT", "port": MIGRATED_PORT}])
        mgr.unroute_flow(1, {"nw_dst": DST})

        last = lpm_writes(c)[-1]
        self.assertEqual(last[0], "lpm_insert",
                         f"the destination's last ipv4_lpm write was {last[0]}: nothing is "
                         f"left to forward it and the table misses to send_to_cpu()")
        self.assertEqual(last[3], CONTROL_PLANE_PORT,
                         "the entry came back pointing somewhere the control plane did not "
                         "choose")

    def test_the_restore_never_empties_the_entry_first(self):
        # A DELETE followed by an INSERT would end in the right state and still black-hole the
        # destination for the width of the gap. The entry exists, so one insert_ipv4_route is
        # enough: it is refused as a duplicate and lands as an in-place MODIFY.
        c = RecordingClient()
        mgr = manager_with(c)
        mgr._installed_routes[(1, DST)] = MIGRATED_PORT

        mgr.unroute_flow(1, {"nw_dst": DST})

        self.assertEqual(lpm_writes(c),
                         [("lpm_insert", DST, 32, CONTROL_PLANE_PORT)],
                         "the delete path did not resolve to a single in-place restore")

    def test_the_bookkeeping_names_the_restored_port(self):
        # _installed_routes is what render_destination_paths answers from. Popping it here
        # would have the twin withdraw a route the switch is holding.
        c = RecordingClient()
        mgr = manager_with(c)
        mgr._installed_routes[(1, DST)] = MIGRATED_PORT

        mgr.unroute_flow(1, {"nw_dst": DST})

        self.assertEqual(mgr._installed_routes.get((1, DST)), CONTROL_PLANE_PORT,
                         "the twin's record disagrees with the entry now in the switch")

    def test_a_destination_the_control_plane_cannot_route_is_really_deleted(self):
        # The negative control. There is nothing to give the slot back to, so the honest
        # outcome is the entry's removal -- and the record's removal with it.
        c = RecordingClient()
        mgr = manager_with(c, routed=False)
        mgr._installed_routes[(1, DST)] = MIGRATED_PORT

        ok = mgr.unroute_flow(1, {"nw_dst": DST})

        self.assertTrue(ok)
        self.assertEqual(lpm_writes(c), [("lpm_delete", DST, 32)],
                         "a destination with no control-plane route was not deleted")
        self.assertNotIn((1, DST), mgr._installed_routes,
                         "the twin still advertises a route the switch no longer has")

    def test_a_five_tuple_delete_is_left_alone(self):
        # The second control. flow_5tuple sits in front of ipv4_lpm, so deleting a 5-tuple
        # rule already falls back to the entry underneath -- the layering OVS has and the LPM
        # table does not. Restoring here would write an ipv4_lpm entry nobody asked for.
        c = RecordingClient()
        mgr = manager_with(c)
        mgr._installed_routes[(1, DST)] = CONTROL_PLANE_PORT

        mgr.unroute_flow(1, {"nw_dst": DST, "nw_src": "10.0.0.9"}, priority=100)

        self.assertEqual(lpm_writes(c), [],
                         "a 5-tuple delete reached ipv4_lpm")
        self.assertEqual([c0[0] for c0 in c.calls], ["5t_delete"])

    def test_a_refused_restore_is_reported_as_a_failed_delete(self):
        # The caller's rule is still in the switch, so the delete did not happen. Answering
        # success would leave the application believing it had cleaned up.
        c = RecordingClient(verdict=False)
        mgr = manager_with(c)
        mgr._installed_routes[(1, DST)] = MIGRATED_PORT

        ok = mgr.unroute_flow(1, {"nw_dst": DST})

        self.assertFalse(ok)
        self.assertEqual(mgr._installed_routes.get((1, DST)), MIGRATED_PORT,
                         "a rejected write was recorded as though it had landed")


if __name__ == "__main__":
    unittest.main(verbosity=2)
