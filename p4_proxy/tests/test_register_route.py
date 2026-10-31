"""
`GET /p4/register/{name}` -- a register's cells, read through bmv2's thrift service.

[Co-developed with claude code -- Adam]

bmv2's P4Runtime answers every RegisterEntry read UNIMPLEMENTED, so this route asks bmv2's thrift
`standard` service (proxy_agent/bm_thrift.py). Here the thrift call is replaced by a recording
double -- what goes on the wire is tests/test_bm_thrift.py's subject, and a real switch is the
offline trial's -- and every status code of the route's docstring is asserted one row at a time:

    200  the cells, as bit<W> values (W at most 63); `source: "bmv2-thrift"`
    400  index out of range (checked against p4info before the switch is asked), a bad range
    404  an unknown dpid, a name that is not a register
    413  too many cells
    501  bit<64> or wider (bmv2's thrift saturates at 2^63 - 1, measured), or not bit<W>
    502  the thrift port is another switch's; bmv2 refused; an answer that is not the answer
    503  no answer (NOT a zero); thrift not installed; replay pending; no thrift port; no topology

The double stands in for bm_thrift.device_info too: the route asks the thrift service who it is
once per client before it reads.

The handler is called directly, as in test_counter_route.py and for its reason.

Run with:  p4_proxy/venv/bin/python -m unittest tests.test_register_route
"""

from __future__ import annotations

import asyncio
import os
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    import thrift  # noqa: F401
    from fastapi import HTTPException
    from p4.config.v1 import p4info_pb2

    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover -- depends on the interpreter L1 picks
    HAVE_P4RUNTIME = False

if HAVE_P4RUNTIME:
    # Not guarded: with the dependencies present, a missing route or client is a failure.
    from proxy_agent import api_routes
    from proxy_agent import bm_thrift
    from proxy_agent.p4_client import P4RuntimeClient, RPC_TIMEOUT_S


def a_p4info():
    """hc_main's r_mark (bit<32>, 16 cells); bit<63>, bit<64> and bit<128> ones; one larger than the cell
    cap but small enough to fetch whole; the fetch-whole boundary on both sides; one too big to fetch
    whole; and an int<32> one (p4info's bitstring.int)."""
    p4info = p4info_pb2.P4Info()
    for rid, name, alias, width, size in ((382518421, "HcIngress.r_mark", "r_mark", 32, 16),
                                          (382518422, "HcIngress.r_wide", "r_wide", 64, 4),
                                          (382518423, "HcIngress.r_huge", "r_huge", 128, 4),
                                          (382518424, "HcIngress.r_big", "r_big", 32, 100000),
                                          (382518425, "HcIngress.r_mid", "r_mid", 32, 8192),
                                          (382518426, "HcIngress.r_63", "r_63", 63, 2),
                                          (382518427, "HcIngress.r_65536", "r_65536", 32, 65536),
                                          (382518428, "HcIngress.r_65537", "r_65537", 32, 65537)):
        r = p4info.registers.add()
        r.preamble.id, r.preamble.name, r.preamble.alias = rid, name, alias
        r.type_spec.bitstring.bit.bitwidth = width
        r.size = size
    i = p4info.registers.add()
    i.preamble.id, i.preamble.name, i.preamble.alias = 382518429, "HcIngress.r_int", "r_int"
    i.type_spec.bitstring.int.bitwidth = 32
    i.size = 2
    c = p4info.counters.add()
    c.preamble.id, c.preamble.name = 317599709, "HcIngress.c_in"
    return p4info


class ThriftDouble:
    """Stands in for bm_thrift.read_register_as. On each call it first plays bm_mgmt_get_info:
    raises `info_error` if set, records the identity asked (`info_calls`), and raises
    ThriftDeviceMismatch when `identity` is not the expected (device id, thrift port) -- before
    any register is read. Then it answers from `cells`, or raises `error`, recording the read
    (`calls`) and the thread it ran on."""

    def __init__(self, cells=None, error=None, identity=None):
        self.cells = dict(cells or {})
        self.error = error
        self.calls = []
        self.threads = []
        self.identity = dict(identity or {"device_id": 2, "thrift_port": 9092})
        self.info_error = None
        self.info_calls = []

    def __call__(self, host, port, register, index, expected, timeout_s=None):
        self.info_calls.append((host, port, tuple(expected), timeout_s))
        if self.info_error is not None:
            raise self.info_error
        if (self.identity["device_id"], self.identity["thrift_port"]) != tuple(expected):
            raise bm_thrift.ThriftDeviceMismatch(dict(self.identity), tuple(expected))
        self.calls.append((host, port, register, index, timeout_s))
        self.threads.append(threading.get_ident())
        if self.error is not None:
            raise self.error
        values = self.cells[register]
        return values[index] if index is not None else list(values)


class ProbeDouble:
    """Stands in for the client's P4Runtime liveness round trip (P4RuntimeClient.probe)."""

    def __init__(self, ok=True, delay=0.0):
        self.ok, self.delay = ok, delay
        self.calls = []
        self.threads = []

    def __call__(self, timeout_s=2.0):
        self.calls.append(timeout_s)
        self.threads.append(threading.get_ident())
        if self.delay:
            time.sleep(self.delay)
        if self.ok:
            return {"ok": True, "detail": "answered GetForwardingPipelineConfig"}
        return {"ok": False, "detail": "UNAVAILABLE: failed to connect to all addresses"}


def a_client(thrift_port=9092):
    client = P4RuntimeClient.__new__(P4RuntimeClient)
    client.device_id = 2
    client.p4info = a_p4info()
    client.stub = None
    client.arbitration = True
    client.thrift_port = thrift_port
    client.probe = ProbeDouble()
    return client


class FakeTopology:
    def __init__(self, switches):
        self.switches = switches


class FakeJournals:
    def __init__(self, pending=()):
        self.pending_dpids = set(pending)

    def pending(self, dpid):
        return dpid in self.pending_dpids


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class RegisterRouteTestBase(unittest.TestCase):
    def setUp(self):
        # getattr: so that on code without the identity check these tests still run, and the ones
        # about the check go red for their own reason instead of every setUp failing.
        saved = (api_routes.topology, api_routes.table_journals,
                 getattr(bm_thrift, "read_register_as", None))
        self.addCleanup(self.restore, saved)
        self.thrift = ThriftDouble({"HcIngress.r_mark": [4737] + [0] * 14 + [7],
                                    "HcIngress.r_wide": [2 ** 63 - 1, 1, 0, 2 ** 62],
                                    "HcIngress.r_63": [2 ** 63 - 1, 0],
                                    "HcIngress.r_65536": list(range(65536)),
                                    "HcIngress.r_65537": list(range(65537)),
                                    "HcIngress.r_big": list(range(100000)),
                                    "HcIngress.r_mid": list(range(8192))})
        bm_thrift.read_register_as = self.thrift
        self.client = a_client()
        api_routes.topology = FakeTopology({2: self.client})
        api_routes.table_journals = None

    @staticmethod
    def restore(saved):
        api_routes.topology, api_routes.table_journals, read_register_as = saved
        if read_register_as is not None:
            bm_thrift.read_register_as = read_register_as

    def get(self, name="HcIngress.r_mark", dpid=2, **kw):
        return asyncio.run(api_routes.register(name, dpid=dpid, index=kw.get("index"),
                                               start=kw.get("start"), count=kw.get("count")))

    def refused(self, **kwargs):
        with self.assertRaises(HTTPException) as caught:
            self.get(**kwargs)
        return caught.exception


class TheReadingItselfTest(RegisterRouteTestBase):
    def test_one_cell_is_200_with_its_value_and_says_where_it_came_from(self):
        self.assertEqual(self.get(index=0), {
            "dpid": 2, "register": "HcIngress.r_mark", "bitwidth": 32, "size": 16, "start": 0,
            "values": [4737], "source": "bmv2-thrift"})

    def test_one_cell_is_one_bm_register_read_of_that_index_on_the_switchs_port(self):
        self.get(index=15)
        (call,) = self.thrift.calls
        self.assertEqual(call[:4], ("127.0.0.1", 9092, "HcIngress.r_mark", 15))
        self.assertTrue(0 < call[4] <= RPC_TIMEOUT_S, call)
        self.assertEqual(self.thrift.info_calls[0][2], (2, 9092), "the identity asked is the client's")

    def test_a_zero_is_a_200(self):
        self.assertEqual(self.get(index=3)["values"], [0])

    def test_no_index_is_the_whole_array_from_one_read_all(self):
        body = self.get()
        self.assertEqual(body["values"], [4737] + [0] * 14 + [7])
        self.assertEqual([c[:4] for c in self.thrift.calls], [("127.0.0.1", 9092, "HcIngress.r_mark", None)])

    def test_a_range_is_sliced_from_the_array(self):
        body = self.get(start=14, count=2)
        self.assertEqual((body["start"], body["values"]), (14, [0, 7]))

    def test_the_alias_names_the_same_register_and_the_full_name_is_asked(self):
        body = self.get(name="r_mark", index=0)
        self.assertEqual(body["register"], "HcIngress.r_mark")
        self.assertEqual(self.thrift.calls[0][2], "HcIngress.r_mark")

    def test_a_bit63_register_is_read_up_to_its_top(self):
        self.assertEqual(self.get(name="HcIngress.r_63")["values"], [2 ** 63 - 1, 0])

    def test_a_value_outside_the_registers_width_is_502_not_truncated(self):
        # bmv2 cannot send a negative value for a bit<32> cell, or one past 2^32: if one comes, the
        # program and the p4info disagree, and reducing it to 32 bits would invent a reading.
        self.thrift.cells["HcIngress.r_mark"][0] = -1
        error = self.refused(index=0)
        self.assertEqual((error.status_code, error.detail["error"]), (502, "register answer invalid"))
        self.assertEqual(error.detail["source"], "bmv2-thrift")
        self.thrift.cells["HcIngress.r_mark"][0] = 2 ** 32
        self.assertEqual(self.refused(index=0).status_code, 502)

    def test_a_whole_array_longer_than_p4info_says_is_502_before_slicing(self):
        self.thrift.cells["HcIngress.r_mark"] = list(range(17))
        error = self.refused(start=0, count=2)
        self.assertEqual((error.status_code, error.detail["error"]), (502, "register answer invalid"))
        self.assertIn("17 cells", error.detail["message"])

    def test_a_short_answer_is_502_not_a_short_list(self):
        self.thrift.cells["HcIngress.r_mark"] = [1, 2]
        error = self.refused(start=0, count=4)
        self.assertEqual((error.status_code, error.detail["error"]), (502, "register answer invalid"))
        self.assertEqual(error.detail["source"], "bmv2-thrift")


class TheThriftPortMustBeThisSwitchsTest(RegisterRouteTestBase):
    """Two checks before a thrift read, on EVERY read:
      * the dpid's own switch answers P4Runtime now (client.probe), inside the request's deadline --
        else 503 and thrift is not asked; and
      * on the thrift connection itself, bm_mgmt_get_info answers this client's (device id, port)
        -- else 502 and no register is read (bm_thrift.read_register_as).
    Measured 2026-10-17: a remembered identity let a replaced process and
    an impostor holding the port answer 200 with their own cells."""

    def test_another_device_on_the_port_is_502_and_nothing_is_read(self):
        self.thrift.identity["device_id"] = 3
        error = self.refused(index=0)
        self.assertEqual((error.status_code, error.detail["error"]), (502, "thrift device mismatch"))
        self.assertEqual(error.detail["source"], "bmv2-thrift")
        self.assertEqual(self.thrift.calls, [], "a register of another switch must not be read")

    def test_the_same_device_on_another_port_is_502(self):
        self.thrift.identity["thrift_port"] = 9093
        self.assertEqual(self.refused(index=0).detail["error"], "thrift device mismatch")
        self.assertEqual(self.thrift.calls, [])

    def test_the_identity_is_asked_on_every_read(self):
        self.get(index=0)
        self.get(index=1)
        self.assertEqual([c[2] for c in self.thrift.info_calls], [(2, 9092), (2, 9092)])
        self.assertEqual(len(self.thrift.calls), 2)

    def test_a_process_that_replaced_the_switch_after_a_read_is_caught(self):
        self.assertEqual(self.get(index=0)["values"], [4737])
        self.thrift.identity["device_id"] = 3           # another process took the port since
        self.assertEqual(self.refused(index=0).detail["error"], "thrift device mismatch")
        self.thrift.identity["device_id"] = 2           # and nothing about the client is pinned
        self.assertEqual(self.get(index=0)["values"], [4737])

    def test_an_identity_that_cannot_be_asked_is_503(self):
        self.thrift.info_error = bm_thrift.ThriftUnreachable("refused")
        error = self.refused(index=0)
        self.assertEqual((error.status_code, error.detail["error"]), (503, "register not read"))
        self.assertEqual(self.thrift.calls, [])

    def test_a_switch_that_does_not_answer_p4runtime_is_503_and_thrift_is_not_asked(self):
        self.client.probe.ok = False
        error = self.refused(index=0)
        self.assertEqual((error.status_code, error.detail["error"]), (503, "switch not reachable"))
        self.assertIn("UNAVAILABLE", error.detail["message"])
        self.assertEqual(self.thrift.info_calls, [], "thrift must not be asked for a switch that is gone")

    def test_the_liveness_check_runs_before_every_read_on_a_worker_thread(self):
        async def drive():
            return threading.get_ident(), await api_routes.register(
                "HcIngress.r_mark", dpid=2, index=0, start=None, count=None)
        loop_thread, _b = asyncio.run(drive())
        asyncio.run(drive())
        self.assertEqual(len(self.client.probe.calls), 2)
        self.assertNotEqual(self.client.probe.threads[0], loop_thread)
        # drawn from the request's deadline, which started before it: strictly under a full budget
        self.assertTrue(all(0 < t < RPC_TIMEOUT_S for t in self.client.probe.calls), self.client.probe.calls)

    def test_the_liveness_check_and_the_read_share_one_deadline(self):
        # One budget per request, not one per call: what the liveness check used is
        # gone from what the thrift read may take.
        self.client.probe.delay = 0.4
        self.get(index=0)
        read_budget = self.thrift.info_calls[0][3]
        self.assertLessEqual(read_budget, RPC_TIMEOUT_S - 0.35, read_budget)


class TheRefusalsTest(RegisterRouteTestBase):
    def assert_refused_before_the_switch(self, status, error_word, **kw):
        error = self.refused(**kw)
        self.assertEqual((error.status_code, error.detail["error"]), (status, error_word))
        self.assertEqual(self.thrift.calls, [], "the switch must not be asked")
        return error

    def test_no_topology_is_503(self):
        api_routes.topology = None
        self.assert_refused_before_the_switch(503, "no topology")

    def test_an_unknown_dpid_is_404(self):
        self.assert_refused_before_the_switch(404, "unknown switch", dpid=9)

    def test_a_switch_being_readopted_is_503_replay_pending(self):
        api_routes.table_journals = FakeJournals(pending={2})
        self.assert_refused_before_the_switch(503, "replay pending")

    def test_another_switch_being_readopted_does_not_stop_this_read(self):
        api_routes.table_journals = FakeJournals(pending={3})
        self.assertEqual(self.get(index=0)["values"], [4737])

    def test_a_name_that_is_no_register_is_404(self):
        self.assert_refused_before_the_switch(404, "not in this pipeline", name="HcIngress.c_in")

    def test_a_start_past_the_end_is_400_index_out_of_range(self):
        error = self.assert_refused_before_the_switch(400, "index out of range", start=16)
        self.assertEqual(error.detail["size"], 16)

    def test_an_index_past_the_end_is_400_and_says_the_size(self):
        error = self.assert_refused_before_the_switch(400, "index out of range", index=16)
        self.assertEqual(error.detail["size"], 16)

    def test_the_last_index_is_read(self):
        self.assertEqual(self.get(index=15)["values"], [7])

    def test_a_range_past_the_end_is_400(self):
        self.assert_refused_before_the_switch(400, "index out of range", start=10, count=7)

    def test_a_negative_index_is_400(self):
        self.assert_refused_before_the_switch(400, "invalid range", index=-1)

    def test_an_empty_range_is_400(self):
        self.assert_refused_before_the_switch(400, "invalid range", start=0, count=0)

    def test_index_with_a_range_is_400(self):
        self.assert_refused_before_the_switch(400, "invalid range", index=1, count=2)

    def test_the_fetch_whole_limit_itself_is_read_and_one_past_it_is_413(self):
        self.assertEqual(self.get(name="HcIngress.r_65536", start=65534, count=2)["values"], [65534, 65535])
        del self.thrift.calls[:]
        error = self.assert_refused_before_the_switch(413, "too many cells", name="HcIngress.r_65537",
                                                      start=0, count=2)
        self.assertEqual(error.detail["size"], 65537)

    def test_more_cells_than_the_cap_is_413(self):
        # r_mid (8192 cells) is small enough to fetch whole, so only the cell cap refuses it: on r_big the
        # fetch-whole limit would refuse the same request and hide a cap that is gone.
        error = self.assert_refused_before_the_switch(413, "too many cells", name="HcIngress.r_mid")
        self.assertIn("at most %d" % api_routes.REGISTER_CELLS_MAX, error.detail["message"])
        self.assertEqual(error.detail["size"], 8192)
        self.assert_refused_before_the_switch(413, "too many cells", name="HcIngress.r_mid",
                                              start=0, count=api_routes.REGISTER_CELLS_MAX + 1)

    def test_the_cap_itself_is_read(self):
        self.client.p4info.registers[3].size = api_routes.REGISTER_CELLS_MAX
        self.thrift.cells["HcIngress.r_big"] = list(range(api_routes.REGISTER_CELLS_MAX))
        body = self.get(name="HcIngress.r_big")
        self.assertEqual(len(body["values"]), api_routes.REGISTER_CELLS_MAX)

    def test_a_range_of_an_array_too_big_to_fetch_whole_is_413(self):
        self.assert_refused_before_the_switch(413, "too many cells", name="HcIngress.r_big",
                                              start=0, count=2)

    def test_one_cell_of_an_array_too_big_to_fetch_whole_is_read(self):
        self.assertEqual(self.get(name="HcIngress.r_big", index=99999)["values"], [99999])

    def test_a_register_wider_than_64_bits_is_501(self):
        self.assert_refused_before_the_switch(501, "register too wide", name="HcIngress.r_huge")

    def test_a_bit64_register_is_501_and_says_why(self):
        # Measured on both builds: every bit<64> cell at or above 2^63 reads as
        # 2^63 - 1 through thrift, the CLI and bmv2's generated client alike -- so 2^63 - 1 itself
        # cannot be told from 2^64 - 1, and no reading of a bit<64> cell can be vouched for.
        error = self.assert_refused_before_the_switch(501, "register too wide", name="HcIngress.r_wide")
        self.assertIn("2^63 - 1", error.detail["message"])

    def test_an_int_w_register_is_501(self):
        self.assert_refused_before_the_switch(501, "register type not readable", name="HcIngress.r_int",
                                              index=0)

    def test_a_register_that_is_not_bit_w_is_501(self):
        self.client.p4info.registers[0].type_spec.Clear()
        self.client.p4info.registers[0].type_spec.struct.name = "pair_t"
        self.assert_refused_before_the_switch(501, "register type not readable", index=0)

    def test_a_client_with_no_thrift_port_is_503(self):
        self.client.thrift_port = None
        self.assert_refused_before_the_switch(503, "no thrift port", index=0)

    def test_no_answer_is_503_and_not_a_zero(self):
        self.thrift.error = bm_thrift.ThriftUnreachable("timed out")
        error = self.refused(index=0)
        self.assertEqual((error.status_code, error.detail["error"]), (503, "register not read"))
        self.assertIn("NOT a reading of zero", error.detail["message"])
        self.assertEqual(error.detail["source"], "bmv2-thrift")

    def test_no_thrift_package_is_503_for_this_route_alone(self):
        self.thrift.info_error = bm_thrift.ThriftNotInstalled("no module named thrift")
        error = self.refused(index=0)
        self.assertEqual((error.status_code, error.detail["error"]), (503, "thrift not installed"))
        self.assertEqual(error.detail["source"], "bmv2-thrift")

    def test_bytes_that_are_not_thrift_are_502_not_understood(self):
        self.thrift.error = bm_thrift.ThriftAnswerNotUnderstood("bad version")
        error = self.refused(index=0)
        self.assertEqual((error.status_code, error.detail["error"]), (502, "register answer not understood"))
        self.assertEqual(error.detail["source"], "bmv2-thrift")

    def test_bmv2_refusing_the_name_is_502_with_its_code(self):
        self.thrift.error = bm_thrift.RegisterReadRefused(bm_thrift.INVALID_REGISTER_NAME)
        error = self.refused(index=0)
        self.assertEqual((error.status_code, error.detail["error"]), (502, "register refused"))
        self.assertEqual(error.detail["code"], "INVALID_REGISTER_NAME")

    def test_an_answer_that_is_not_the_answer_is_502(self):
        self.thrift.error = bm_thrift.ThriftAnswerInvalid("no result")
        error = self.refused(index=0)
        self.assertEqual((error.status_code, error.detail["error"]), (502, "register answer invalid"))
        self.assertEqual(error.detail["source"], "bmv2-thrift")


class ExternalAndThreadTest(RegisterRouteTestBase):
    def test_an_external_control_plane_can_still_read(self):
        self.client.arbitration = False
        self.assertEqual(self.get(index=0)["values"], [4737])

    def test_the_thrift_read_runs_on_a_worker_thread(self):
        async def drive():
            return threading.get_ident(), await api_routes.register(
                "HcIngress.r_mark", dpid=2, index=0, start=None, count=None)
        loop_thread, body = asyncio.run(drive())
        self.assertEqual(body["values"], [4737])
        self.assertEqual(len(self.thrift.threads), 1)
        self.assertNotEqual(self.thrift.threads[0], loop_thread,
                            "GET /p4/register read the switch on the event loop thread")

    def test_the_range_read_runs_on_a_worker_thread_too(self):
        async def drive():
            return threading.get_ident(), await api_routes.register(
                "HcIngress.r_mark", dpid=2, index=None, start=0, count=4)
        loop_thread, _body = asyncio.run(drive())
        self.assertNotEqual(self.thrift.threads[0], loop_thread)


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class TheRouteIsRegisteredTest(unittest.TestCase):
    def test_the_path_and_method_are_on_the_router(self):
        matches = [r for r in api_routes.router.routes
                   if getattr(r, "path", None) == "/p4/register/{name}"]
        self.assertEqual(len(matches), 1, "the register route is not registered")
        self.assertEqual(matches[0].methods, {"GET"}, "a read route; R3 looks for a WRITE")


if __name__ == "__main__":
    unittest.main(verbosity=2)
