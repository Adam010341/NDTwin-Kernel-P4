"""
A destination-only modify naming the priority its ipv4_lpm slot holds is honoured; no other is.

[Co-developed with claude code -- Adam]

Adam's 2026-10-16 ruling, amending doc/audit/2026-09-03_night-rounds/DECISION-P4-PRIORITY.md
for one case. Before it, every named priority on a destination-only modify answered 501, and
that included the priority-10 modify Traffic-Engineering's default mode and Energy-Saving send
for every route change (the kernel builds `modifyAnEntry(dpid, 10, ...)` -> `/stats/flowentry/
modify` with `"priority": 10`), so neither app moved a flow on P4. Priority 10 is the priority
NDTwin's OVS control plane writes its destination routes at; on P4 the proxy's own routes (the
refill and the A-4d restore) are the counterpart, and a modify at 10 against one of them names
the same entry it names on OVS.

What these tests pin, each against a mutant in tests/shell/mutate_p4_priority_refusal.sh:

  * honoured: a modify at 10 on a slot the proxy's refill or restore wrote; a modify at the
    priority an install asked for;
  * still 501, and nothing written: no record; a priority that is not the slot's (777; 10 after
    an install at 100); every named priority on a strict delete;
  * the record is forgotten after a write that cannot be confirmed (False, an exception, a
    DEADLINE_EXCEEDED on the real client), after a removal, after a pipeline push, and when the
    switch's client is replaced (readopt);
  * the check and the write are atomic per slot, and per slot only;
  * the check runs after the read-only (409) and foreign-pipeline (501 `reason`) refusals,
    which are properties of the switch; a strict delete keeps its refusal ahead of them;
  * the 501 remedy no longer tells a caller to omit the priority (on OVS that is a priority-0
    strict modify that edits nothing), and `requested_priority` stays inside the 200 bytes the
    kernel keeps of a failure body.

unittest rather than pytest because tools/test_workflow/l1_unit_tests.sh executes each file
directly and parses "Ran N tests".
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import sys
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))

from fastapi import HTTPException  # noqa: E402

from proxy_agent import api_routes  # noqa: E402
from proxy_agent.topology_manager import TopologyManager  # noqa: E402

try:
    import grpc  # noqa: E402
    from tests.test_p4_client_writes import (FakeRpcError, RecordingStub,  # noqa: E402
                                             a_client as a_writes_client)
    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover - depends on the interpreter L1 picks
    HAVE_P4RUNTIME = False

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))

DST = "10.0.0.2"
DST_MAC = "00:00:00:00:00:02"
#: The fabric is 1 -- 2 -- DST: switch 1 reaches DST out of port 2, switch 2 out of port 1.
ROUTE_PORT = {1: 2, 2: 1}
#: Where an application moves the traffic.
DETOUR_PORT = 3
#: A destination in the graph that no switch has a path to (an application's own address).
UNROUTED = "10.9.9.9"


class SlotClient:
    """Stands in for P4RuntimeClient on the ipv4_lpm writes, recording verb and port."""

    def __init__(self, verdict=True):
        self.verdict = verdict
        self.calls = []
        self.raise_on = None
        self.hold = None       # an Event a modify/insert waits on, to test the slot lock
        self.entered = threading.Event()

    def _write(self, verb, dst, port):
        self.calls.append((verb, dst, port))
        self.entered.set()
        if self.hold is not None:
            self.hold.wait(5)
        if self.raise_on == verb:
            raise RuntimeError("the channel went away mid-write")
        return self.verdict

    def insert_ipv4_route(self, dst_ip, prefix_len, mac, port):
        return self._write("insert", dst_ip, port)

    def modify_ipv4_route(self, dst_ip, prefix_len, mac, port):
        return self._write("modify", dst_ip, port)

    def delete_ipv4_route(self, dst_ip, prefix_len):
        return self._write("delete", dst_ip, None)


def a_fabric(client1=None, client2=None):
    """A real TopologyManager over 1 -- 2 -- DST, with the given (or recording) clients."""
    topo = TopologyManager()
    c1 = client1 if client1 is not None else SlotClient()
    c2 = client2 if client2 is not None else SlotClient()
    topo.add_switch(1, c1)
    topo.add_switch(2, c2)
    topo.add_link(1, 2, 2, 2)
    topo.add_host(DST, DST_MAC, 2, 1)
    topo.net.add_node(UNROUTED, type="host", mac="00:00:00:00:09:09")
    return topo, c1, c2


def body(dpid=1, priority=None, port=DETOUR_PORT, dst=DST):
    """What the kernel builds for TE's and ESA's modify (HttpRoutingStrategyBase.cpp:307-386)."""
    out = {"actions": [{"port": port, "type": "OUTPUT"}], "dpid": dpid,
           "match": {"eth_type": 2048, "ipv4_dst": dst}}
    if priority is not None:
        out["priority"] = priority
    return out


class FakeRequest:
    def __init__(self, data):
        self._data = data

    async def json(self):
        return self._data


def post(handler, data):
    return asyncio.run(handler(FakeRequest(data)))


def modify(data):
    return post(api_routes.modify_flow_entry, data)


def refused(handler, data):
    try:
        out = post(handler, data)
    except HTTPException as err:
        return err
    raise AssertionError(f"expected a refusal, got {out!r}")


def writes(client, verb):
    return [c for c in client.calls if c[0] == verb]


class SlotTestCase(unittest.TestCase):
    def setUp(self):
        self.saved = api_routes.topology
        self.addCleanup(setattr, api_routes, "topology", self.saved)

    def fabric(self, refill=True, **kw):
        topo, c1, c2 = a_fabric(**kw)
        api_routes.topology = topo
        if refill:
            topo.install_initial_routes()
        return topo, c1, c2


# --- honoured --------------------------------------------------------------------------------


class AModifyAtTheSlotsPriorityIsHonouredTest(SlotTestCase):

    def test_a_modify_at_ten_on_the_proxys_own_route_is_honoured(self):
        # The TE / ESA body verbatim, against the route the refill wrote.
        topo, c1, _ = self.fabric()
        out = modify(body(priority=10))
        self.assertEqual(out["status"], "success")
        self.assertEqual(writes(c1, "modify"), [("modify", DST, DETOUR_PORT)])
        self.assertEqual(topo.installed_routes()[(1, DST)], DETOUR_PORT)

    def test_the_answer_still_describes_the_table_not_the_request(self):
        # `priority_honoured` describes ipv4_lpm's capability (it has no priority column), as on
        # every other destination-only answer; it does not turn true because 10 matched.
        self.fabric()
        out = modify(body(priority=10))
        self.assertEqual((out["table"], out["priority_honoured"]), ("ipv4_lpm", False))

    def test_a_modify_at_the_priority_an_install_asked_for_is_honoured(self):
        topo, c1, _ = self.fabric()
        post(api_routes.add_flow_entry, body(priority=100, port=4))
        out = modify(body(priority=100))
        self.assertEqual(out["status"], "success")
        self.assertEqual(writes(c1, "modify")[-1], ("modify", DST, DETOUR_PORT))

    def test_a_modify_at_ten_after_the_restore_is_honoured_again(self):
        # Install at 100 replaces the proxy's route; the non-strict delete (A-4d) hands the slot
        # back to the control plane, so it holds a priority-10 entry again.
        self.fabric()
        post(api_routes.add_flow_entry, body(priority=100, port=4))
        post(api_routes.delete_flow_entry, {"dpid": 1, "match": body()["match"]})
        out = modify(body(priority=10))
        self.assertEqual(out["status"], "success")

    def test_the_honoured_modify_keeps_the_slot_at_its_priority(self):
        # A modify changes the port, not the priority: a second TE round at 10 is honoured too.
        _, c1, _ = self.fabric()
        modify(body(priority=10))
        out = modify(body(priority=10, port=5))
        self.assertEqual(out["status"], "success")
        self.assertEqual(writes(c1, "modify")[-1], ("modify", DST, 5))

    def test_a_modify_naming_no_priority_is_untouched_by_the_record(self):
        # makeModifyJob's 0 ("no priority named"): the proxy edits whatever entry the slot holds,
        # as before, with no record needed. (On OVS the kernel sends this as a priority-0 STRICT
        # modify, HttpRoutingStrategyBase.cpp:371-386, which is why the 501 remedy does not
        # advise it.)
        _, c1, _ = self.fabric(refill=False)
        out = modify(body(priority=0))
        self.assertEqual(out["status"], "success")
        self.assertEqual(len(writes(c1, "modify")), 1)

    def test_the_control_plane_priority_is_the_ovs_routers(self):
        # The value is only right if it is Ryu's: every destination route intelligent_router.py
        # writes goes in at one literal priority, and it is the one recorded here.
        from proxy_agent import slot_priority
        with open(os.path.join(REPO, "intelligent_router.py")) as fh:
            src = fh.read()
        found = re.findall(
            r"OFPMatch\(eth_type=0x0800, ipv4_dst=dst_ip\)\s*\n[^\n]*\n\s*"
            r"self\.add_flow\(datapath, priority=(\d+), match=match", src)
        self.assertTrue(found, "the router's destination-route write was not found")
        self.assertEqual({int(p) for p in found}, {slot_priority.CONTROL_PLANE_ROUTE_PRIORITY})


# --- still refused, and nothing written -----------------------------------------------------


class EveryOtherNamedPriorityIsStill501Test(SlotTestCase):

    def assert_refused_unwritten(self, client, data, held):
        err = refused(api_routes.modify_flow_entry, data)
        self.assertEqual(err.status_code, 501)
        self.assertEqual(err.detail["outcome"], "unsupported_on_p4")
        self.assertEqual(err.detail["requested_priority"], data["priority"])
        self.assertEqual(err.detail.get("slot_priority"), held)
        self.assertEqual(writes(client, "modify"), [], "a refused modify reached the switch")
        return err

    def test_a_slot_with_no_record_is_501(self):
        _, c1, _ = self.fabric(refill=False)
        self.assert_refused_unwritten(c1, body(priority=10), None)

    def test_a_modify_at_777_on_the_proxys_own_route_is_still_501(self):
        topo, c1, _ = self.fabric()
        self.assert_refused_unwritten(c1, body(priority=777), 10)
        self.assertEqual(topo.installed_routes()[(1, DST)], ROUTE_PORT[1])

    def test_a_modify_at_ten_after_an_install_at_100_is_501(self):
        # The 2026-09-03 identity problem: the slot now holds the application's entry, and a
        # modify at 10 would edit it rather than the route the caller named.
        topo, c1, _ = self.fabric()
        post(api_routes.add_flow_entry, body(priority=100, port=4))
        self.assert_refused_unwritten(c1, body(priority=10), 100)
        self.assertEqual(topo.installed_routes()[(1, DST)], 4)

    def test_an_install_with_no_priority_is_not_a_priority_ten_entry(self):
        _, c1, _ = self.fabric()
        post(api_routes.add_flow_entry, body(port=4))
        self.assert_refused_unwritten(c1, body(priority=10), 0)

    def test_a_strict_delete_at_ten_is_still_501(self):
        # Unchanged by the ruling: a strict delete at the slot's own priority stays refused,
        # before the topology, so the proxy's route is untouched.
        _, c1, _ = self.fabric()
        err = refused(api_routes.delete_flow_entry,
                      {"dpid": 1, "match": body()["match"], "priority": 10})
        self.assertEqual(err.status_code, 501)
        self.assertEqual(c1.calls[-1][0], "insert", "the strict delete touched the switch")
        self.assertEqual(len(c1.calls), 1)

    def test_a_removed_slot_has_no_record(self):
        # No control-plane route to restore, so the non-strict delete removes the entry: the
        # slot is empty and a modify at the old priority names nothing.
        _, c1, _ = self.fabric()
        post(api_routes.add_flow_entry, body(priority=100, dst=UNROUTED))
        post(api_routes.delete_flow_entry, {"dpid": 1, "match": body(dst=UNROUTED)["match"]})
        self.assertEqual(c1.calls[-1], ("delete", UNROUTED, None))
        self.assert_refused_unwritten(c1, body(priority=100, dst=UNROUTED), None)


# --- forgotten after anything that cannot be confirmed --------------------------------------


class AWriteThatCannotBeConfirmedForgetsTheSlotTest(SlotTestCase):

    def fabric(self, **kw):
        # The control: before the write under test, the slot is recorded and a modify at 10 IS
        # honoured, so a 501 afterwards is the write's doing and not a record that never was.
        topo, c1, c2 = super().fabric(**kw)
        self.assertEqual(modify(body(priority=10, port=7))["status"], "success")
        return topo, c1, c2

    def assert_now_501(self, client):
        client.verdict, client.raise_on = True, None
        before = len(writes(client, "modify"))
        err = refused(api_routes.modify_flow_entry, body(priority=10))
        self.assertEqual(err.status_code, 501)
        self.assertIsNone(err.detail["slot_priority"])
        self.assertEqual(len(writes(client, "modify")), before)

    def test_a_failed_modify_forgets_the_slot(self):
        _, c1, _ = self.fabric()
        c1.verdict = False
        with self.assertRaises(HTTPException):
            modify(body(priority=0))
        self.assert_now_501(c1)

    def test_a_failed_install_forgets_the_slot(self):
        # The slot held 10; an install at 10 that the switch refused may or may not have landed.
        _, c1, _ = self.fabric()
        c1.verdict = False
        post(api_routes.add_flow_entry, body(priority=10))
        self.assert_now_501(c1)

    def test_a_failed_refill_write_forgets_the_slot(self):
        topo, c1, _ = self.fabric()
        c1.verdict = False
        topo.install_initial_routes()
        self.assert_now_501(c1)

    def test_a_failed_restore_forgets_the_slot(self):
        _, c1, _ = self.fabric()
        c1.verdict = False
        post(api_routes.delete_flow_entry, {"dpid": 1, "match": body()["match"]})
        self.assert_now_501(c1)

    def test_a_write_that_raises_forgets_the_slot(self):
        _, c1, _ = self.fabric()
        c1.raise_on = "modify"
        with self.assertRaises(RuntimeError):
            modify(body(priority=0))
        self.assert_now_501(c1)

    @unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
    def test_a_timed_out_write_on_the_real_client_forgets_the_slot(self):
        # DEADLINE_EXCEEDED can hide a write that landed (p4_client.py, RPC_TIMEOUT_S). The real
        # client reports it as False; the record must not survive it.
        stub = RecordingStub()
        c1 = a_writes_client(stub=stub, device_id=1)
        topo, _, _ = self.fabric(client1=c1)
        self.assertEqual(modify(body(priority=10))["status"], "success")
        stub.write_error = FakeRpcError(grpc.StatusCode.DEADLINE_EXCEEDED, "deadline")
        stub.always = True
        with self.assertRaises(HTTPException):
            modify(body(priority=10, port=5))
        stub.write_error = None
        sent = len(stub.requests)
        err = refused(api_routes.modify_flow_entry, body(priority=10, port=6))
        self.assertEqual((err.status_code, err.detail["slot_priority"]), (501, None))
        self.assertEqual(len(stub.requests), sent, "the refused modify reached the stub")


class APipelinePushForgetsThatSwitchTest(SlotTestCase):

    def test_a_push_on_one_switch_forgets_its_slots_and_no_other(self):
        _, c1, c2 = self.fabric()
        c1.pipeline_push_epoch = getattr(c1, "pipeline_push_epoch", 0) + 2
        self.assertEqual(refused(api_routes.modify_flow_entry, body(priority=10)).status_code,
                         501)
        self.assertEqual(modify(body(dpid=2, priority=10))["status"], "success")
        self.assertEqual(writes(c2, "modify"), [("modify", DST, DETOUR_PORT)])

    def test_a_refill_after_the_push_records_ten_again(self):
        topo, c1, _ = self.fabric()
        c1.pipeline_push_epoch = getattr(c1, "pipeline_push_epoch", 0) + 2
        topo.install_initial_routes()
        self.assertEqual(modify(body(priority=10))["status"], "success")

    def test_a_replaced_client_does_not_inherit_the_old_ones_records(self):
        # readopt swaps self.switches[dpid] for a new client after pushing its pipeline.
        topo, _, _ = self.fabric()
        fresh = SlotClient()
        topo.switches[1] = fresh
        self.assertEqual(refused(api_routes.modify_flow_entry, body(priority=10)).status_code,
                         501)
        self.assertEqual(fresh.calls, [])

    def test_a_write_that_overlaps_a_push_is_not_recorded(self):
        topo, c1, _ = self.fabric(refill=False)
        c1.hold = threading.Event()
        t = threading.Thread(target=topo.install_initial_routes, kwargs={"only_dpid": 1})
        t.start()
        self.assertTrue(c1.entered.wait(5))
        c1.pipeline_push_epoch = getattr(c1, "pipeline_push_epoch", 0) + 1   # a push began
        c1.hold.set()
        t.join(5)
        c1.hold = None
        self.assertEqual(refused(api_routes.modify_flow_entry, body(priority=10)).status_code,
                         501)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheClientBumpsItsPushEpochTest(unittest.TestCase):
    """The stamp the records are checked against, on the real client."""

    def client(self, push_error=None):
        import tempfile
        stub = RecordingStub()
        if push_error is not None:
            def refuse(request, timeout=None):
                stub.pipeline_pushes.append(request)
                raise push_error
            stub.SetForwardingPipelineConfig = refuse
        c = a_writes_client(stub=stub)
        handle, path = tempfile.mkstemp(suffix=".json")
        os.write(handle, b"{}")
        os.close(handle)
        self.addCleanup(os.unlink, path)
        c.json_path, c.pipeline_cookie = path, None
        c.table_generation, c.pipeline_commits = None, 0
        return c, stub

    def test_a_push_moves_the_epoch_on_both_sides_of_the_rpc(self):
        c, stub = self.client()
        seen = []
        real = stub.SetForwardingPipelineConfig

        def watch(request, timeout=None):
            seen.append(getattr(c, "pipeline_push_epoch", 0))
            return real(request, timeout)
        stub.SetForwardingPipelineConfig = watch
        start = getattr(c, "pipeline_push_epoch", 0)
        c.set_forwarding_pipeline_config()
        self.assertEqual(seen, [start + 1], "not bumped before the RPC")
        self.assertEqual(getattr(c, "pipeline_push_epoch", 0), start + 2,
                         "not bumped after the RPC")

    def test_a_push_that_times_out_still_moves_it(self):
        # A timed-out push may have emptied the tables.
        c, _ = self.client(push_error=FakeRpcError(grpc.StatusCode.DEADLINE_EXCEEDED))
        start = getattr(c, "pipeline_push_epoch", 0)
        with self.assertRaises(grpc.RpcError):
            c.set_forwarding_pipeline_config()
        self.assertEqual(getattr(c, "pipeline_push_epoch", 0), start + 2)


# --- atomic per slot -------------------------------------------------------------------------


class TheCheckAndTheWriteAreOneStepPerSlotTest(SlotTestCase):

    def test_an_install_cannot_land_between_a_modifys_check_and_its_write(self):
        # Thread A's modify at 10 passed the check and is mid-write; thread B's install at 100
        # on the same slot must wait for it, or A's write lands on B's entry.
        topo, c1, _ = self.fabric()
        c1.hold = threading.Event()
        c1.entered.clear()
        a = threading.Thread(target=modify, args=(body(priority=10),))
        a.start()
        self.assertTrue(c1.entered.wait(5))
        b = threading.Thread(target=post, args=(api_routes.add_flow_entry,
                                                body(priority=100, port=4)))
        b.start()
        time.sleep(0.5)
        inserts_during = [c for c in c1.calls if c[0] == "insert" and c[2] == 4]
        c1.hold.set()
        a.join(5)
        b.join(5)
        self.assertEqual(inserts_during, [], "the install ran while the modify held the slot")
        self.assertEqual(c1.calls[-2:], [("modify", DST, DETOUR_PORT), ("insert", DST, 4)])

    def test_another_slot_is_not_held_up(self):
        # Per slot: a write stuck on its 5 s deadline must not stall every other destination.
        topo, c1, _ = self.fabric()
        c1.hold = threading.Event()
        c1.entered.clear()
        a = threading.Thread(target=modify, args=(body(priority=10),))
        a.start()
        self.assertTrue(c1.entered.wait(5))
        done = threading.Event()

        def other():
            post(api_routes.add_flow_entry, body(priority=100, port=4, dst=UNROUTED))
            done.set()
        b = threading.Thread(target=other)
        b.start()
        # SlotClient.hold makes B's own write wait too, so watch for it ENTERING the client.
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and not any(c[1] == UNROUTED for c in c1.calls):
            time.sleep(0.01)
        reached = any(c[1] == UNROUTED for c in c1.calls)
        c1.hold.set()
        a.join(5)
        b.join(5)
        self.assertTrue(reached, "a write to another destination waited on this slot's lock")


# --- check order -----------------------------------------------------------------------------


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheSlotCheckComesAfterTheSwitchsOwnRefusalsTest(SlotTestCase):
    """
    Modify: 400 (the request) -> 409 read-only -> 501 foreign/unbound -> 501 slot priority.
    The first two are properties of the switch and true whatever priority is named; answering
    "priority not held" there would point at the wrong fault. Strict delete keeps its refusal
    ahead of the topology, unchanged since 2026-09-03.
    """

    def a_real_switch(self, arbitration=True, binding="baseline"):
        stub = RecordingStub()
        c1 = a_writes_client(stub=stub)
        c1.arbitration = arbitration
        if binding is None:
            c1.bind_routes(None)
        self.fabric(refill=False, client1=c1)
        return c1, stub

    def test_a_modify_at_ten_on_a_read_only_switch_is_409(self):
        _, stub = self.a_real_switch(arbitration=False)
        err = refused(api_routes.modify_flow_entry, body(priority=10))
        self.assertEqual(err.status_code, 409)
        self.assertEqual(stub.requests, [])

    def test_a_modify_at_ten_on_an_unbound_switch_is_the_binding_501(self):
        _, stub = self.a_real_switch(binding=None)
        err = refused(api_routes.modify_flow_entry, body(priority=10))
        self.assertEqual((err.status_code, err.detail.get("reason")), (501, "unbound"))
        self.assertEqual(stub.requests, [])

    def test_a_strict_delete_at_ten_on_a_read_only_switch_is_still_the_priority_501(self):
        _, stub = self.a_real_switch(arbitration=False)
        err = refused(api_routes.delete_flow_entry,
                      {"dpid": 1, "match": body()["match"], "priority": 10})
        self.assertEqual((err.status_code, err.detail.get("table")), (501, "ipv4_lpm"))
        self.assertEqual(stub.requests, [])

    def test_a_malformed_match_is_still_the_400_before_any_of_them(self):
        self.a_real_switch(arbitration=False)
        data = body(priority=10)
        data["match"]["ipv4_dst"] = "10.0.0.0/24"
        self.assertEqual(refused(api_routes.modify_flow_entry, data).status_code, 400)


# --- the 501 says what to do, on either plane ------------------------------------------------


class TheRemedyIsTrueOnBothPlanesTest(SlotTestCase):
    KERNEL_MESSAGE_WINDOW = 200   # HttpRoutingStrategyBase.cpp:62 briefly(body, 200)

    def wire(self, err):
        from fastapi.responses import JSONResponse
        return JSONResponse(status_code=err.status_code,
                            content={"detail": err.detail}).body.decode()

    def test_neither_verb_advises_omitting_the_priority(self):
        # On OVS an omitted priority is a priority-0 strict modify that edits nothing, and -1 is
        # non-strict and edits every rule for the destination: P4-only advice.
        self.fabric()
        for handler, data in ((api_routes.modify_flow_entry, body(priority=777)),
                              (api_routes.delete_flow_entry,
                               {"dpid": 1, "match": body()["match"], "priority": 777})):
            with self.subTest(handler=handler.__name__):
                remedy = refused(handler, data).detail["remedy"]
                self.assertNotIn("omit", remedy)
                self.assertIn("five-tuple", remedy)

    def test_the_modify_remedy_names_the_slots_priority(self):
        self.fabric()
        err = refused(api_routes.modify_flow_entry, body(priority=777))
        self.assertIn("slot_priority", err.detail["remedy"])

    def test_the_modify_501_keeps_its_machine_fields_inside_the_kernel_window(self):
        self.fabric()
        window = self.wire(refused(api_routes.modify_flow_entry,
                                   body(priority=777)))[:self.KERNEL_MESSAGE_WINDOW]
        for needle in ("unsupported_on_p4", "remedy", "five-tuple", "requested_priority",
                       "slot_priority"):
            self.assertIn(needle, window)


# --- round 2 (review r1) ---------------------------------------------------------------------
# [Co-developed with claude code -- Adam]

#: Another spelling of DST that check_match_values accepts and inet_aton encodes to the same
#: four bytes, so the switch holds ONE entry for both (p4_client._lpm_match).
DST_ALT = "10.0.0.02"


def race(testcase, second, first=None):
    """
    Thread A runs `first` (default: a modify at 10 on DST) and is held mid-write; thread B runs
    `second(topo)`. Returns the client calls B made while A still held the slot, and the client.
    """
    topo, c1, _ = testcase.fabric()
    c1.hold = threading.Event()
    c1.entered.clear()
    a = threading.Thread(target=first or (lambda: modify(body(priority=10))))
    a.start()
    testcase.assertTrue(c1.entered.wait(5))
    n = len(c1.calls)
    b = threading.Thread(target=second, args=(topo,))
    b.start()
    time.sleep(0.5)
    made = list(c1.calls[n:])
    c1.hold.set()
    a.join(5)
    b.join(5)
    c1.hold = None
    return made, c1


class OneSlotWhateverTheSpellingTest(SlotTestCase):
    """MAJOR-1: the record and the lock are the switch's entry, not the string the caller sent."""

    def test_an_install_under_another_spelling_is_the_same_slot(self):
        # Refill records 10; an app installs at 100 spelling the address differently (same
        # switch entry). A modify at 10 in the canonical spelling would edit the app's entry.
        _, c1, _ = self.fabric()
        self.assertEqual(post(api_routes.add_flow_entry,
                              body(priority=100, port=4, dst=DST_ALT))["status"], "success")
        err = refused(api_routes.modify_flow_entry, body(priority=10))
        self.assertEqual((err.status_code, err.detail.get("slot_priority")), (501, 100))
        self.assertEqual(writes(c1, "modify"), [], "the modify reached the app's entry")

    def test_a_restore_under_another_spelling_is_the_same_slot(self):
        # App installs at 100 as DST_ALT, the non-strict delete (canonical) restores the
        # control plane's route at 10: a modify at 100 as DST_ALT names nothing that is there.
        _, c1, _ = self.fabric()
        post(api_routes.add_flow_entry, body(priority=100, port=4, dst=DST_ALT))
        out = post(api_routes.delete_flow_entry, {"dpid": 1, "match": body()["match"]})
        self.assertEqual(out["status"], "success")
        self.assertEqual(c1.calls[-1], ("insert", DST, ROUTE_PORT[1]), "not the A-4d restore")
        err = refused(api_routes.modify_flow_entry, body(priority=100, dst=DST_ALT))
        self.assertEqual((err.status_code, err.detail.get("slot_priority")), (501, 10))
        self.assertEqual(writes(c1, "modify"), [])

    def test_two_spellings_wait_on_the_same_lock(self):
        made, _ = race(self, lambda topo: post(api_routes.add_flow_entry,
                                               body(priority=100, port=4, dst=DST_ALT)))
        self.assertEqual(made, [], "an install spelled differently ran while the modify held "
                                   "the slot")


class EveryWriterTakesTheSlotLockTest(SlotTestCase):
    """m1: built like the install-vs-modify race above, one per remaining writer."""

    def test_a_restore_cannot_land_between_a_modifys_check_and_its_write(self):
        made, c1 = race(self, lambda topo: post(api_routes.delete_flow_entry,
                                                {"dpid": 1, "match": body()["match"]}))
        self.assertEqual(made, [], "the A-4d restore ran while the modify held the slot")
        self.assertEqual(c1.calls[-2:], [("modify", DST, DETOUR_PORT),
                                         ("insert", DST, ROUTE_PORT[1])])

    def test_a_refill_cannot_land_between_a_modifys_check_and_its_write(self):
        made, c1 = race(self, lambda topo: topo.install_initial_routes(only_dpid=1))
        self.assertEqual(made, [], "the refill ran while the modify held the slot")
        self.assertEqual(c1.calls[-2:], [("modify", DST, DETOUR_PORT),
                                         ("insert", DST, ROUTE_PORT[1])])


class ReadoptClient(SlotClient):
    """The part of P4RuntimeClient readopt_switch drives; the push bumps the epoch like the
    real one (both sides), and can be told to raise after it 'landed'."""

    def __init__(self, push_raises=False, **kw):
        super().__init__(**kw)
        self.arbitration = True
        self.mastership_confirmed = True
        self.packet_in_callback = None
        self.push_raises = push_raises
        self.pipeline_push_epoch = 0
        self.stopped = False

    def start(self, push_config=True):
        pass

    def set_forwarding_pipeline_config(self):
        self.pipeline_push_epoch += 1
        try:
            if self.push_raises:
                raise RuntimeError("deadline exceeded after the push landed")
        finally:
            self.pipeline_push_epoch += 1

    def write_clone_session(self):
        return True

    def stop(self):
        self.stopped = True


class ReadoptEndToEndTest(SlotTestCase):
    """m4: TopologyManager.readopt_switch driven with stub clients: push, swap, refill."""

    def test_after_a_readopt_the_refilled_route_is_modified_at_ten(self):
        topo, old, _ = self.fabric(client1=ReadoptClient())
        new = ReadoptClient()
        result = topo.readopt_switch(1, lambda dpid: new, settle_s=0)
        self.assertEqual(result["status"], "success", result)
        self.assertEqual(new.calls, [("insert", DST, ROUTE_PORT[1])])
        self.assertEqual(modify(body(priority=10))["status"], "success")
        self.assertEqual(writes(new, "modify"), [("modify", DST, DETOUR_PORT)])
        self.assertEqual(writes(old, "modify"), [])

    def test_after_a_readopt_with_no_refill_the_old_records_do_not_count(self):
        topo, old, _ = self.fabric(client1=ReadoptClient())
        new = ReadoptClient()
        result = topo.readopt_switch(1, lambda dpid: new, settle_s=0, install_routes=False)
        self.assertEqual(result["status"], "success", result)
        err = refused(api_routes.modify_flow_entry, body(priority=10))
        self.assertEqual((err.status_code, err.detail["slot_priority"]), (501, None))
        self.assertEqual(new.calls, [])

    def test_a_push_that_raised_after_landing_costs_one_failed_modify_and_no_insert(self):
        # The new client's push emptied the tables and raised; readopt keeps the OLD client,
        # whose records still count. Pinned residual (review r1 m4): the honoured modify reaches
        # a slot that is empty, modify_ipv4_route has no insert fallback (pinned below on the
        # real client), so it fails, the record is forgotten, and the next one is a 501.
        topo, old, _ = self.fabric(client1=ReadoptClient())
        new = ReadoptClient(push_raises=True)
        result = topo.readopt_switch(1, lambda dpid: new, settle_s=0)
        self.assertEqual((result["status"], result.get("step")), ("failed", "pipeline"))
        self.assertIs(topo.switches[1], old)
        old.verdict = False                  # the entry is gone: the modify is refused
        with self.assertRaises(HTTPException):
            modify(body(priority=10))
        self.assertEqual([c[0] for c in old.calls[1:]], ["modify"], "anything but one modify")
        old.verdict = True
        err = refused(api_routes.modify_flow_entry, body(priority=10))
        self.assertEqual((err.status_code, err.detail["slot_priority"]), (501, None))


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class AModifyNeverInsertsTest(unittest.TestCase):
    """m4: the property the residual above rests on, on the real client."""

    def test_a_refused_modify_is_not_retried_as_an_insert(self):
        from p4.v1 import p4runtime_pb2
        stub = RecordingStub(FakeRpcError(grpc.StatusCode.NOT_FOUND), always=True)
        c = a_writes_client(stub=stub)
        self.assertFalse(c.modify_ipv4_route(DST, 32, DST_MAC, DETOUR_PORT))
        kinds = [u.type for r in stub.requests for u in r.updates]
        self.assertEqual(kinds, [p4runtime_pb2.Update.MODIFY],
                         "a modify on an absent entry must not create one")


if __name__ == "__main__":
    unittest.main(verbosity=2)
