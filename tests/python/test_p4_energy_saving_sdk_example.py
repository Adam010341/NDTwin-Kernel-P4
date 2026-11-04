#!/usr/bin/env python3
"""examples/p4_energy_saving/energy_saving_sdk.py against an in-process fake kernel.

[Co-developed with claude code -- Adam]

The scenarios of test_p4_energy_saving_example.py, which tests the app that does its own HTTP, and
a few more (the exit codes, the lock renewal, the read-back of a default entry); the fake kernel is
tests/python/p4_fake_kernel.py. The SDK is read from sdk/python, or from
$NDTWIN_SDK_UNDER_TEST; the app is $ENERGY_SAVING_SDK_UNDER_TEST, or the file in examples/, and
route_walk.py is taken from the app's own directory first, as when the app runs as a script.
"""
import contextlib
import copy
import http.client
import importlib.util
import io
import os
import sys
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(os.path.dirname(HERE))
SDK_DIR = os.environ.get("NDTWIN_SDK_UNDER_TEST") or os.path.join(REPO_DIR, "sdk", "python")
APP_PATH = os.environ.get("ENERGY_SAVING_SDK_UNDER_TEST") or os.path.join(
    REPO_DIR, "examples", "p4_energy_saving", "energy_saving_sdk.py")
sys.path.insert(0, os.path.dirname(os.path.abspath(APP_PATH)))
sys.path.insert(0, HERE)
from p4_fake_kernel import (FIELD, MGMT_IP, TABLE, FakeKernel, calls,  # noqa: E402
                            chain_fabric, grpc_502, ring_fabric, serve)

sys.path.insert(0, SDK_DIR)
import ndtwin  # noqa: E402

_spec = importlib.util.spec_from_file_location("energy_saving_sdk_under_test", APP_PATH)
app = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(app)


class EnergySavingSdkTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeKernel()
        self.server = serve(self.fake)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.kernel = ndtwin.Kernel(self.url, timeout=5, retry_wait=0)
        self.args = app.parse_args(["--kernel", self.url, "--settle", "0"])
        self.out = io.StringIO()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def run_once(self, **overrides):
        args = copy.copy(self.args)
        for key, value in overrides.items():
            setattr(args, key, value)
        return app.run_once(self.kernel, args, log=lambda s: self.out.write(s + "\n"))

    def posts(self, path):
        return [(q, b) for m, p, q, b in self.fake.requests if m == "POST" and p == path]

    def assert_lock_released(self):
        self.assertEqual(calls(self.fake)[0], "POST acquire_lock")
        self.assertEqual(calls(self.fake)[-1], "POST release_lock")
        self.assertEqual(self.posts("/ndt/release_lock")[-1][1],
                         {"type": "routing_lock", "lease": 41})

    def assert_all_hosts_reach_each_other(self, avoiding=None):
        attach = {"10.0.1.1": 1, "10.0.2.2": 1, "10.0.3.3": 2, "10.0.4.4": 2}
        for src, s_sw in attach.items():
            for dst in attach:
                if dst == src:
                    continue
                path, ok = self.fake.walk(s_sw, dst)
                self.assertTrue(ok, f"{src} -> {dst} stops at {path}")
                if avoiding is not None:
                    self.assertNotIn(avoiding, path, f"{src} -> {dst} still crosses s{avoiding}")

    def assert_no_writes(self):
        self.assertEqual(self.posts("/ndt/p4/table_entry"), [])
        self.assertEqual(self.posts("/ndt/set_switches_power_state"), [])

    # --- the pass that does what it is for -------------------------------------------------

    def test_turns_off_the_spine_that_draws_more_and_keeps_every_route(self):
        result = self.run_once()
        self.assertEqual(result["switch"], 4, result)  # s4 draws 73.978 W, s3 49.053 W
        self.assertTrue(result["powered_off"], result)
        self.assertEqual(calls(self.fake), [
            "POST acquire_lock", "GET get_graph_data", "GET get_average_link_usage",
            "GET get_power_report", "GET table s1", "GET table s2", "GET table s3",
            "POST renew_lock", "POST table s1", "POST table s2", "GET table s1", "GET table s2",
            "POST renew_lock", "POST power 192.168.123.14 off", "GET get_switches_power_state",
            "POST release_lock"])
        self.assertEqual([b for _, b in self.posts("/ndt/renew_lock")],
                         [{"type": "routing_lock", "ttl": 60, "lease": 41}] * 2)
        self.assertEqual([b for _, b in self.posts("/ndt/p4/table_entry")], [
            {"dpid": 1, "table": TABLE, "match": {FIELD: ["10.0.4.4", 32]},
             "action_name": "MyIngress.ipv4_forward",
             "action_params": {"dstAddr": "08:00:00:00:03:00", "port": 3},
             "priority": None, "default_action": False, "op": "modify"},
            {"dpid": 2, "table": TABLE, "match": {FIELD: ["10.0.2.2", 32]},
             "action_name": "MyIngress.ipv4_forward",
             "action_params": {"dstAddr": "08:00:00:00:03:00", "port": 4},
             "priority": None, "default_action": False, "op": "modify"}])
        self.assertEqual(self.fake.power_state["192.168.123.14"]["admin_state"], "off")
        self.assert_all_hosts_reach_each_other(avoiding=4)
        self.assert_lock_released()

    def test_a_second_pass_finds_nothing_more_to_turn_off(self):
        self.run_once()
        # The fake shows s4 commanded off; what the kernel shows a little later: s4 unreachable,
        # its links down.
        for node in self.fake.graph["nodes"]:
            if node["dpid"] == 4 and node["vertex_type"] == 0:
                self.assertEqual(node["admin_state"], "off")
                node.update(reachable=False, is_up=False)
        for edge in self.fake.graph["edges"]:
            if 4 in (edge["src_dpid"], edge["dst_dpid"]):
                edge["is_up"] = False
        self.fake.requests.clear()
        result = self.run_once()
        self.assertIsNone(result["switch"], result)
        self.assert_no_writes()
        self.assert_all_hosts_reach_each_other(avoiding=4)

    def test_dry_run_reads_and_plans_but_writes_nothing(self):
        result = self.run_once(dry_run=True)
        self.assertEqual(result["switch"], 4)
        self.assertEqual(len(result["rewrites"]), 2)
        self.assert_no_writes()
        self.assert_lock_released()

    def test_management_address_is_read_in_the_kernels_byte_order(self):
        topo = self.kernel.topology()
        self.assertEqual({d: sw.mgmt_ip for d, sw in topo.switches.items()}, MGMT_IP)
        self.assertEqual(ndtwin.topology.ip_str(16842762), "10.0.1.1")

    # --- the policy's gates ----------------------------------------------------------------

    def test_a_busy_network_is_left_alone(self):
        self.fake.avg = 0.55  # a 0..1 fraction (§24); the default limit is 0.4
        result = self.run_once()
        self.assertIsNone(result["switch"])
        self.assert_no_writes()
        self.assert_lock_released()

    def test_a_switch_with_a_hot_link_is_not_chosen(self):
        for edge in self.fake.graph["edges"]:
            if edge["src_dpid"] == 4 and edge["dst_dpid"] == 2:
                edge["link_bandwidth_utilization_percent"] = 85.0
        result = self.run_once()
        self.assertEqual(result["switch"], 3, result)
        self.assert_all_hosts_reach_each_other(avoiding=3)

    def test_a_switch_with_a_host_behind_a_down_link_is_not_chosen(self):
        # h9 hangs off s4 through a link that is down for now; s4 is still its only switch.
        h9 = 0x0909000A  # 10.0.9.9 in the kernel's byte order
        self.fake.graph["nodes"].append({"vertex_type": 1, "dpid": 0, "device_name": "h9",
                                         "ip": [h9], "mac": 0})
        for src, sport, dst, dport, key in ((4, 9, 0, 1, "dst_ip"), (0, 1, 4, 9, "src_ip")):
            edge = copy.deepcopy(self.fake.graph["edges"][0])
            edge.update({"src_dpid": src, "src_interface": sport, "dst_dpid": dst,
                         "dst_interface": dport, "is_up": False, key: [h9]})
            self.fake.graph["edges"].append(edge)
        for dpid, port in ((1, 4), (2, 3), (3, 1), (4, 9)):  # h9's routes, all over s4
            entry = copy.deepcopy(self.fake.tables[dpid][0])
            entry["match"] = {FIELD: ["10.0.9.9", 32]}
            entry["action_params"]["port"] = port
            self.fake.tables[dpid].insert(0, entry)
        result = self.run_once(dry_run=True)
        self.assertEqual(result["switch"], 3, result)  # although s4 draws more
        self.assertNotIn("s4 stays on", self.out.getvalue())  # left out as h9's switch, unplanned

    def test_a_switch_whose_links_are_not_measured_is_not_chosen(self):
        # A link with no samples reads 0 %: that is not a quiet link.
        for edge in self.fake.graph["edges"]:
            if 4 in (edge["src_dpid"], edge["dst_dpid"]) and edge["src_dpid"] and edge["dst_dpid"]:
                edge["telemetry_status"] = "unknown"
        result = self.run_once(dry_run=True)
        self.assertEqual(result["switch"], 3, result)
        for status in ("silent", None):
            with self.subTest(status):
                self.fake.graph["edges"][0]["telemetry_status"] = status  # s1 -> s3
                self.assertIsNone(self.run_once(dry_run=True)["switch"])

    def take_down_s2_s3(self):
        for edge in self.fake.graph["edges"]:
            if {edge["src_dpid"], edge["dst_dpid"]} == {3, 2}:
                edge["is_up"] = False  # s3 now reaches only s1, so s4 is the only way to s2

    def test_a_switch_the_hosts_depend_on_is_not_chosen(self):
        self.take_down_s2_s3()
        self.fake.tables[2][0]["action_params"]["port"] = 3  # s2 sends h1's packets over s4 now
        result = self.run_once(dry_run=True)
        self.assertEqual(result["switch"], 3, result)  # although s4 draws more
        self.assert_no_writes()
        self.assertIn("s4 stays on: without it some hosts could not reach each other",
                      self.out.getvalue())

    def test_a_route_that_is_already_broken_keeps_every_switch_on(self):
        self.take_down_s2_s3()  # s2 still sends h1's packets to s3, over the link that is down
        result = self.run_once(dry_run=True)
        self.assertIsNone(result["switch"], result)
        self.assertIn("s3 stays on: after the rewrites 10.0.3.3 -> 10.0.1.1 stops: s2",
                      self.out.getvalue())

    def set_default(self, dpid, port):
        """Make s<dpid>'s default entry forward out of `port`."""
        default = self.fake.tables[dpid][-1]
        assert default["default_action"]
        default.update(action_name="MyIngress.ipv4_forward",
                       action_params={"dstAddr": "08:00:00:00:09:09", "port": port})

    def test_a_switch_that_a_default_entry_forwards_to_is_not_chosen(self):
        self.set_default(1, 4)  # s1's miss action sends packets to s4, which draws more than s3
        result = self.run_once()
        self.assertEqual(result["switch"], 3, result)
        self.assertTrue(result["powered_off"], result)
        self.assert_all_hosts_reach_each_other(avoiding=3)

    def test_with_every_candidate_behind_a_default_entry_nothing_is_turned_off(self):
        self.set_default(1, 4)  # towards s4
        self.set_default(2, 4)  # towards s3
        result = self.run_once()
        self.assertIsNone(result["switch"], result)
        self.assert_no_writes()
        self.assert_lock_released()

    def test_a_table_the_api_cannot_fully_show_is_not_rewritten(self):
        self.fake.unrendered[2] = [{"default_action": False, "priority": None,
                                    "reason": "the action comes from an action profile"}]
        self.assertRaises(ndtwin.NDTwinError, self.run_once)
        self.assert_no_writes()
        self.assert_lock_released()

    # --- a fabric where moving only the entries next to the switch would loop ---------------

    def use_ring(self, hot=()):
        self.tearDown()
        graph, routes, power = ring_fabric(hot)
        self.fake = FakeKernel(graph, routes, power)
        self.server = serve(self.fake)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.kernel = ndtwin.Kernel(self.url, timeout=5, retry_wait=0)

    def test_the_ring_fixture_does_loop_when_only_the_next_entry_is_moved(self):
        # The control for the two tests below: the plan of an app that does not follow the
        # packets (s3 off; s2's entry for h4 sent back towards s1, the way around) loops.
        self.use_ring()
        tables = copy.deepcopy(self.fake.tables)
        tables[2][1]["action_params"]["port"] = 1
        del tables[3]
        path, delivered = self.fake.walk(1, "10.0.4.4", tables)
        self.assertEqual((path, delivered), ([1, 2, 1], False))

    def test_a_switch_whose_rewrites_would_make_a_loop_is_not_turned_off(self):
        self.use_ring(hot={(5, 6), (6, 7)})  # s5, s6, s7 are busy: only s3 and s2 are candidates
        result = self.run_once()
        self.assertIsNone(result["switch"], result)
        self.assertEqual(result["reason"], "no switch can be turned off")
        self.assert_no_writes()
        self.assertIn("s3 stays on: after the rewrites 10.0.1.1 -> 10.0.4.4 stops: s1 s2 s1",
                      self.out.getvalue())
        self.assertIn("s2 stays on: after the rewrites 10.0.4.4 -> 10.0.1.1 stops: s4 s3 s4",
                      self.out.getvalue())
        self.assert_lock_released()

    def test_on_the_ring_a_switch_whose_rewrites_keep_every_route_is_turned_off(self):
        self.use_ring()
        result = self.run_once()
        self.assertEqual(result["switch"], 5, result)  # s3 and s2 draw more but would loop
        self.assertTrue(result["powered_off"], result)
        for src, dst in ((1, "10.0.4.4"), (4, "10.0.1.1")):
            path, delivered = self.fake.walk(src, dst)
            self.assertTrue(delivered, path)
            self.assertNotIn(5, path)

    # --- a host behind a link that is down, and why a switch stays on -----------------------

    def use_chain(self):
        self.tearDown()
        graph, routes, power = chain_fabric()
        self.fake = FakeKernel(graph, routes, power)
        self.server = serve(self.fake)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.kernel = ndtwin.Kernel(self.url, timeout=5, retry_wait=0)

    def test_the_chain_fixture_loops_for_the_host_behind_the_down_link(self):
        # The control for the test below: with s3 off and s2's entry for h4 sent towards s1,
        # h4 and h5 still reach each other, and h9's packets loop once its link is back.
        self.use_chain()
        tables = copy.deepcopy(self.fake.tables)
        tables[2][0]["action_params"]["port"] = 1
        del tables[3]
        self.assertEqual(self.fake.walk(5, "10.0.4.4", tables), ([5, 4], True))
        self.assertEqual(self.fake.walk(4, "10.0.5.5", tables), ([4, 5], True))
        self.assertEqual(self.fake.walk(2, "10.0.4.4", tables), ([2, 1, 2], False))

    def test_the_routes_of_a_host_behind_a_down_link_are_followed_too(self):
        self.use_chain()
        result = self.run_once()
        self.assertIsNone(result["switch"], result)
        self.assert_no_writes()
        self.assertIn("s3 stays on: after the rewrites 10.0.9.9 -> 10.0.4.4 stops: s2 s1 s2",
                      self.out.getvalue())
        self.assert_lock_released()

    def test_links_without_telemetry_are_named_and_the_reason_says_what_to_do(self):
        # A fabric nobody has sent traffic through yet: every link between switches reads
        # "silent" (the switch's sFlow agent sent nothing within the window).
        for edge in self.fake.graph["edges"]:
            if edge["src_dpid"] and edge["dst_dpid"]:
                edge["telemetry_status"] = "silent"
        rc = app.main(["--kernel", self.url, "--settle", "0"], kernel=self.kernel,
                      log=lambda s: self.out.write(s + "\n"))
        self.assertEqual(rc, 0)
        out = self.out.getvalue()
        self.assertIn("s3 stays on: no telemetry on s1->s3 silent, s2->s3 silent, s3->s1 silent, "
                      "s3->s2 silent", out)
        self.assertIn("s4 stays on: no telemetry on s1->s4 silent", out)
        self.assertIn("no switch can be turned off; s3, s4 stayed on only because their links "
                      "have no telemetry samples: send traffic through every switch, then run "
                      "again", out)
        self.assert_no_writes()

    def test_the_reason_names_no_telemetry_only_when_that_kept_a_switch_on(self):
        self.use_ring(hot={(5, 6), (6, 7)})
        self.assertEqual(self.run_once()["reason"], "no switch can be turned off")
        self.assertIn("s5 stays on: a link at 85 % (--max-link-util 40)", self.out.getvalue())

    def test_a_destination_with_no_known_host_keeps_that_switch_on_and_the_next_is_tried(self):
        extra = copy.deepcopy(self.fake.tables[1][3])  # s1's entry for 10.0.4.4, port 4 (s4)
        extra["match"] = {FIELD: ["10.0.9.9", 32]}
        self.fake.tables[1].insert(0, extra)
        result = self.run_once()
        self.assertEqual(result["switch"], 3, result)
        self.assertTrue(result["powered_off"], result)
        self.assertIn("s4 stays on: s1: no single way around it for ['10.0.9.9', 32]",
                      self.out.getvalue())

    def test_a_match_value_that_is_not_an_address_is_an_error_not_a_traceback(self):
        for value in (["10.0.4.4", "255.0.255.0"], ["0x0a000404", 32]):  # a ternary mask, hex
            with self.subTest(value):
                self.tearDown()
                self.setUp()
                self.fake.tables[1][3]["match"] = {FIELD: value}
                rc = app.main(["--kernel", self.url, "--settle", "0"], kernel=self.kernel,
                              log=lambda s: self.out.write(s + "\n"))
                self.assertEqual(rc, 1)
                self.assertIn("error: ", self.out.getvalue())
                self.assertIn(value[0] if value[1] == 32 else value[1], self.out.getvalue())
                self.assert_no_writes()
                self.assert_lock_released()

    def test_a_rewrite_that_keeps_its_mac_address_says_so(self):
        # s1 sends h3's packets over s4 too: no entry of s1 uses port 3 (s3) any more, so the
        # MAC address of s3 as a next hop is not known.
        self.fake.tables[1][2]["action_params"].update(port=4, dstAddr="08:00:00:00:04:00")
        result = self.run_once(dry_run=True)
        self.assertEqual(result["switch"], 4, result)
        self.assertIn("{'dstAddr': '08:00:00:00:04:00', 'port': 3} (dstAddr unchanged: no entry "
                      "of s1 that uses port 3 gives another)", self.out.getvalue())
        self.assertNotIn("unchanged", self.out.getvalue().split("s2 {")[1])  # s2's has one

    def add_unreachable_leaf(self):
        """s5, unreachable, on s1's port 5, with h5 (10.0.5.5) behind it; s1 routes h5 to it."""
        graph, h5 = self.fake.graph, int.from_bytes(bytes([10, 0, 5, 5]), "little")
        node = copy.deepcopy(next(n for n in graph["nodes"] if n["vertex_type"] == 0 and n["dpid"] == 4))
        node.update(dpid=5, device_name="s5", nickname="s5", reachable=False,
                    ip=[int.from_bytes(bytes([192, 168, 123, 15]), "little")])
        graph["nodes"] += [node, {"vertex_type": 1, "dpid": 0, "device_name": "h5", "ip": [h5],
                                  "mac": 0}]
        cable = next(e for e in graph["edges"] if e["src_dpid"] and e["dst_dpid"])
        for src, sport, dst, dport, key in ((1, 5, 5, 1, None), (5, 1, 1, 5, None),
                                            (5, 2, 0, 1, "dst_ip"), (0, 1, 5, 2, "src_ip")):
            edge = copy.deepcopy(cable)
            edge.update(src_dpid=src, src_interface=sport, dst_dpid=dst, dst_interface=dport)
            if key:
                edge[key] = [h5]
            graph["edges"].append(edge)
        entry = copy.deepcopy(self.fake.tables[1][0])
        entry["match"] = {FIELD: ["10.0.5.5", 32]}
        entry["action_params"]["port"] = 5
        self.fake.tables[1].insert(0, entry)

    def test_hosts_of_a_switch_that_is_off_or_unreachable_are_not_walked(self):
        # The walk would stop at s5, which has no table to follow, and keep every switch on.
        self.add_unreachable_leaf()
        result = self.run_once()
        self.assertEqual(result["switch"], 4, result)
        self.assertTrue(result["powered_off"], result)
        self.assertIn("s5 has hosts and is off or unreachable: their routes are not checked",
                      self.out.getvalue())
        self.assertNotIn("after the rewrites", self.out.getvalue())

    def test_a_read_back_that_fails_after_every_write_was_answered_is_worded_as_such(self):
        posted = lambda q, b: any(m == "POST" and p == "/ndt/p4/table_entry"  # noqa: E731
                                  for m, p, _, _ in self.fake.requests)
        self.fake.fault("GET", "/ndt/p4/table_entry", 503,
                        {"detail": {"error": "switch busy", "dpid": 1, "message": "m"}},
                        origin="proxy", times=3, match=posted)
        result = self.run_once()
        self.assertFalse(result["powered_off"])
        self.assertIn("every write was answered, the read-back does not confirm them (they may "
                      "have landed), s4 left on", result["reason"])
        self.assertNotIn("written before it", result["reason"])
        self.assertNotIn("not on the switch", result["reason"])
        self.assertEqual(self.posts("/ndt/set_switches_power_state"), [])
        self.assert_lock_released()

    # --- errors on the write, read as §43 says --------------------------------------------

    def test_a_busy_switch_is_retried_because_nothing_was_written(self):
        self.fake.fault("POST", "/ndt/p4/table_entry", 503,
                        {"detail": {"error": "switch busy", "dpid": 1,
                                    "message": "nothing was written, try again"}}, origin="proxy")
        result = self.run_once()
        self.assertTrue(result["powered_off"], result)
        self.assertEqual(calls(self.fake).count("POST table s1"), 2)
        self.assert_all_hosts_reach_each_other(avoiding=4)

    def test_a_timeout_before_sending_is_retried(self):
        self.fake.fault("POST", "/ndt/p4/table_entry", 504,
                        {"error": "P4 proxy timed out", "origin": "kernel", "request_sent": False,
                         "message": "timed out connecting; the request was not sent"},
                        origin="kernel")
        result = self.run_once()
        self.assertTrue(result["powered_off"], result)
        self.assertEqual(calls(self.fake).count("POST table s1"), 2)

    def test_a_timeout_after_sending_is_not_repeated_and_the_switch_stays_on(self):
        self.fake.fault("POST", "/ndt/p4/table_entry", 504,
                        {"error": "P4 proxy timed out", "origin": "kernel", "request_sent": True,
                         "message": "no reply within 15000 ms; the request was sent"},
                        origin="kernel", apply=True)
        result = self.run_once()
        self.assertFalse(result["powered_off"])
        self.assertIn("may have landed", result["reason"])
        self.assertEqual(calls(self.fake).count("POST table s1"), 1)
        self.assertEqual(self.posts("/ndt/set_switches_power_state"), [])
        self.assert_all_hosts_reach_each_other()
        self.assert_lock_released()

    def test_a_kernel_500_on_the_write_is_not_repeated(self):
        self.fake.fault("POST", "/ndt/p4/table_entry", 500,
                        {"error": "Internal server error", "origin": "kernel",
                         "message": "the kernel failed while relaying"}, origin="kernel")
        result = self.run_once()
        self.assertFalse(result["powered_off"])
        self.assertEqual(calls(self.fake).count("POST table s1"), 1)
        self.assertEqual(self.posts("/ndt/set_switches_power_state"), [])

    def test_a_write_the_read_back_does_not_show_keeps_the_switch_on(self):
        # Both writes are answered 200; only the first lands, so the second table did not change.
        self.fake.fault("POST", "/ndt/p4/table_entry", 200, {"status": "success", "dpid": 1},
                        origin="proxy", apply=True, match=lambda q, b: b["dpid"] == 1)
        self.fake.fault("POST", "/ndt/p4/table_entry", 200, {"status": "success", "dpid": 2},
                        origin="proxy", match=lambda q, b: b["dpid"] == 2)
        result = self.run_once()
        self.assertFalse(result["powered_off"])
        self.assertIn("read back", result["reason"])
        self.assertEqual(self.posts("/ndt/set_switches_power_state"), [])
        self.assert_all_hosts_reach_each_other()

    def test_a_proxy_502_without_the_switchs_reason_may_have_landed_and_is_sent_once(self):
        for grpc_status in ("DEADLINE_EXCEEDED", "UNAVAILABLE"):
            with self.subTest(grpc_status):
                self.tearDown()
                self.setUp()
                self.fake.fault("POST", "/ndt/p4/table_entry", 502, grpc_502(grpc_status),
                                origin="proxy", apply=True, times=3)
                result = self.run_once()
                self.assertFalse(result["powered_off"])
                self.assertIn("may have landed", result["reason"])
                self.assertEqual(calls(self.fake).count("POST table s1"), 1)
                self.assertEqual(self.posts("/ndt/set_switches_power_state"), [])
                self.assert_lock_released()

    def test_a_refused_second_write_names_the_first_as_written(self):
        self.fake.fault("POST", "/ndt/p4/table_entry", 502,
                        {"detail": {"error": "the switch refused the write", "dpid": 2,
                                    "grpc_status": "UNKNOWN",
                                    "p4rt_error": {"code": "NOT_FOUND", "message": ""}}},
                        origin="proxy", match=lambda q, b: b["dpid"] == 2)
        result = self.run_once()
        self.assertFalse(result["powered_off"])
        self.assertIn("(not on the switch); s1 {'hdr.ipv4.dstAddr': ['10.0.4.4', 32]} was "
                      "written before it", result["reason"])
        self.assertEqual(self.posts("/ndt/set_switches_power_state"), [])

    WRITTEN_FIRST = "s1 {'hdr.ipv4.dstAddr': ['10.0.4.4', 32]} was written before it, s4 left on: "

    def error_lines(self):
        return [ln for ln in self.out.getvalue().splitlines() if ln.startswith("error: ")]

    def not_json_second_write(self):
        self.fake.fault("POST", "/ndt/p4/table_entry", 200, b"<html>ok</html>", origin="proxy",
                        apply=True, match=lambda q, b: b["dpid"] == 2)

    @contextlib.contextmanager
    def refused_second_write(self):
        """The connection to the kernel is refused for the write to s2 only (every other request
        is answered); yields the list that gets one item per try."""
        real_once = self.kernel._http._once
        tries = []

        def once(method, path, query, body):
            if path != "/ndt/p4/table_entry" or (body or {}).get("dpid") != 2:
                return real_once(method, path, query, body)
            tries.append(1)
            with mock.patch.object(http.client.HTTPConnection, "connect",
                                   side_effect=ConnectionRefusedError("refused")):
                return real_once(method, path, query, body)

        with mock.patch.object(self.kernel._http, "_once", once):
            yield tries

    # [Co-developed with claude code -- Adam]
    def test_a_write_reply_that_is_not_json_may_have_landed_and_names_the_first_as_written(self):
        self.not_json_second_write()
        result = self.run_once()
        self.assertFalse(result["powered_off"])
        self.assertIn("write failed (may have landed); " + self.WRITTEN_FIRST, result["reason"])
        self.assertEqual(self.posts("/ndt/set_switches_power_state"), [])
        self.assert_lock_released()

    # [Co-developed with claude code -- Adam]
    def test_a_refused_connection_on_the_second_write_names_the_first_as_written(self):
        with self.refused_second_write() as tries:
            result = self.run_once()
        self.assertEqual(len(tries), 3, "nothing was sent, so the write is tried 3 times")
        self.assertFalse(result["powered_off"])
        self.assertIn("write failed (not on the switch); " + self.WRITTEN_FIRST, result["reason"])
        self.assertIn("cannot connect to the kernel", result["reason"])
        self.assertEqual(self.posts("/ndt/set_switches_power_state"), [])
        self.assert_lock_released()

    # [Co-developed with claude code -- Adam]
    def test_main_reports_a_write_reply_that_is_not_json_as_a_failed_write_and_exits_1(self):
        self.not_json_second_write()
        rc = app.main(["--kernel", self.url, "--settle", "0"], kernel=self.kernel,
                      log=lambda s: self.out.write(s + "\n"))
        self.assertEqual(rc, 1)
        self.assertIn("write failed (may have landed); " + self.WRITTEN_FIRST, self.out.getvalue())
        self.assertEqual(self.error_lines(), [])
        self.assertEqual(self.posts("/ndt/set_switches_power_state"), [])

    # [Co-developed with claude code -- Adam]
    def test_main_reports_a_refused_connection_on_a_write_as_a_failed_write_and_exits_1(self):
        with self.refused_second_write():
            rc = app.main(["--kernel", self.url, "--settle", "0"], kernel=self.kernel,
                          log=lambda s: self.out.write(s + "\n"))
        self.assertEqual(rc, 1)
        self.assertIn("write failed (not on the switch); " + self.WRITTEN_FIRST,
                      self.out.getvalue())
        self.assertEqual(self.error_lines(), [])
        self.assertEqual(self.posts("/ndt/set_switches_power_state"), [])

    def test_a_switch_that_refused_the_entry_keeps_the_switch_on_and_is_sent_once(self):
        self.fake.fault("POST", "/ndt/p4/table_entry", 502,
                        {"detail": {"error": "the switch refused the write", "dpid": 1,
                                    "grpc_status": "UNKNOWN",
                                    "p4rt_error": {"code": "NOT_FOUND", "message": ""}}},
                        origin="proxy", times=3)
        result = self.run_once()
        self.assertFalse(result["powered_off"])
        self.assertIn("not on the switch", result["reason"])
        self.assertEqual(calls(self.fake).count("POST table s1"), 1)

    def test_a_table_the_read_back_cannot_show_in_full_keeps_the_switch_on(self):
        self.fake.unrendered_after_write[1] = [
            {"default_action": False, "priority": None, "reason": "the action comes from a profile"}]
        result = self.run_once()
        self.assertFalse(result["powered_off"])
        self.assertIn("the action comes from a profile", result["reason"])
        self.assertEqual(self.posts("/ndt/set_switches_power_state"), [])

    # --- the lock, which the app renews before the power-off --------------------------------

    def test_a_lock_that_cannot_be_renewed_before_the_writes_means_no_write(self):
        self.fake.fault("POST", "/ndt/renew_lock", 412,
                        {"error": "Renew failed", "reason": "expired", "detail": "ran out"})
        result = self.run_once()
        self.assertFalse(result["powered_off"])
        self.assertIn("could not be renewed, s4 left on, nothing written", result["reason"])
        self.assert_no_writes()
        self.assert_lock_released()

    def test_a_lock_that_cannot_be_renewed_before_the_power_off_means_no_power_off(self):
        self.fake.fault("POST", "/ndt/renew_lock", 200, {"status": "renewed"}, apply=True)
        self.fake.fault("POST", "/ndt/renew_lock", 412,
                        {"error": "Renew failed", "reason": "expired", "detail": "ran out"})
        result = self.run_once()
        self.assertFalse(result["powered_off"])
        self.assertIn("could not be renewed, s4 left on, routes already moved", result["reason"])
        self.assertEqual(self.posts("/ndt/set_switches_power_state"), [])
        self.assert_all_hosts_reach_each_other(avoiding=4)  # the routes had moved already
        self.assert_lock_released()

    def test_the_lock_is_renewed_right_before_the_writes_and_right_before_the_power_off(self):
        self.run_once()
        names = calls(self.fake)
        renewals = [i for i, name in enumerate(names) if name == "POST renew_lock"]
        self.assertEqual(len(renewals), 2)
        self.assertEqual(names[renewals[0] + 1], "POST table s1")
        self.assertEqual(names[renewals[1] + 1], "POST power 192.168.123.14 off")

    def test_a_lease_that_runs_out_during_the_reads_means_no_write_and_no_power_off(self):
        # Ten seconds per request: the renewal before the writes comes 70 s after the acquire.
        self.fake.seconds_per_request = 10
        rc = app.main(["--kernel", self.url, "--settle", "0", "--lock-ttl", "60"],
                      kernel=self.kernel, log=lambda s: self.out.write(s + "\n"))
        self.assertEqual(rc, 1, self.out.getvalue())
        self.assertEqual(self.posts("/ndt/renew_lock")[0][1]["ttl"], 60)
        self.assert_no_writes()
        self.assertEqual(calls(self.fake)[-1], "POST release_lock")
        self.assertEqual(self.fake.locks, {})
        # The pass's own reason is printed, then the release's error.
        out = self.out.getvalue()
        self.assertIn("routing_lock could not be renewed, s4 left on, nothing written", out)
        self.assertLess(out.index("nothing written"), out.index("error: POST /ndt/release_lock"))

    # --- the power API -----------------------------------------------------------------------

    def test_a_failed_power_off_is_reported_as_one_that_may_have_taken_effect(self):
        # The kernel's 500 does not tell a helper that never touched the switch from one that
        # signalled it and gave up waiting.
        self.fake.fault("POST", "/ndt/set_switches_power_state", 500,
                        {"error": "Failed to change switch power state"})
        result = self.run_once()
        self.assertFalse(result["powered_off"])
        self.assertIn("power-off of s4", result["reason"])
        self.assertIn("may have taken effect", result["reason"])
        self.assertEqual(calls(self.fake).count("POST power 192.168.123.14 off"), 1)
        self.assert_all_hosts_reach_each_other()
        self.assert_lock_released()

    def test_a_power_off_whose_outcome_is_unknown_is_worded_as_such(self):
        self.fake.fault("POST", "/ndt/set_switches_power_state", 500,
                        {"error": "Internal server error"})
        result = self.run_once()
        self.assertFalse(result["powered_off"])
        self.assertIn("may have taken effect", result["reason"])
        self.assertNotIn("did not take effect", result["reason"])

    def not_off_afterwards(self):
        self.fake.fault("GET", "/ndt/get_switches_power_state", 200,
                        {"192.168.123.14": {"admin_state": "on", "reachable": True}})

    def test_a_power_off_the_state_does_not_show_is_not_reported_as_done(self):
        self.not_off_afterwards()
        result = self.run_once()
        self.assertFalse(result["powered_off"], result)

    # --- the command line --------------------------------------------------------------------

    def test_lock_held_by_another_app_exits_3_and_does_nothing(self):
        self.fake.lock_busy = True
        rc = app.main(["--kernel", self.url, "--settle", "0"], kernel=self.kernel,
                      log=lambda s: self.out.write(s + "\n"))
        self.assertEqual(rc, 3)
        self.assertEqual(calls(self.fake), ["POST acquire_lock"])

    def test_main_runs_one_pass_and_exits_0(self):
        rc = app.main(["--kernel", self.url, "--settle", "0"], kernel=self.kernel,
                      log=lambda s: self.out.write(s + "\n"))
        self.assertEqual(rc, 0, self.out.getvalue())
        self.assertIn("turning off s4", self.out.getvalue())

    def test_an_error_exits_1(self):
        self.fake.fault("GET", "/ndt/get_graph_data", 500, {"error": "Internal server error"})
        rc = app.main(["--kernel", self.url, "--settle", "0"], kernel=self.kernel,
                      log=lambda s: self.out.write(s + "\n"))
        self.assertEqual(rc, 1)
        self.assertEqual(calls(self.fake)[-1], "POST release_lock")

    def test_a_power_off_that_did_not_take_exits_1(self):
        self.not_off_afterwards()
        rc = app.main(["--kernel", self.url, "--settle", "0"], kernel=self.kernel,
                      log=lambda s: self.out.write(s + "\n"))
        self.assertEqual(rc, 1)

    def test_a_graph_the_sdk_cannot_read_exits_1(self):
        self.fake.fault("GET", "/ndt/get_graph_data", 200, {"nodes": [{"vertex_type": 0}],
                                                            "edges": []})
        rc = app.main(["--kernel", self.url, "--settle", "0"], kernel=self.kernel,
                      log=lambda s: self.out.write(s + "\n"))
        self.assertEqual(rc, 1)
        self.assertIn("error: GET /ndt/get_graph_data", self.out.getvalue())

    def test_every_is_0_or_at_least_15_seconds(self):
        for every in ("5", "14.9", "-1"):
            with self.subTest(every), self.assertRaises(SystemExit), \
                    contextlib.redirect_stderr(io.StringIO()):
                app.parse_args(["--every", every])
        self.assertEqual(app.parse_args(["--every", "15"]).every, 15)
        self.assertEqual(app.parse_args([]).every, 0)

    def test_a_dry_run_exits_0(self):
        rc = app.main(["--kernel", self.url, "--settle", "0", "--dry-run"], kernel=self.kernel,
                      log=lambda s: self.out.write(s + "\n"))
        self.assertEqual(rc, 0)
        self.assert_no_writes()


if __name__ == "__main__":
    unittest.main()
