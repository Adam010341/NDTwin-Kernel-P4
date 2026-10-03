#!/usr/bin/env python3
"""The P4 health check's verdict functions, on fixtures (DESIGN 5.2-①).

[Co-developed with claude code -- Adam]

Pure functions, no I/O. The package under test is tools/p4_health, or the copy that
$P4_HEALTH_UNDER_TEST names (tests/shell/mutate_p4_health.sh points it at a mutated copy).

Every active cell gets: green, red, sent=0 -> NOT RUN, oracle unreadable -> NOT RUN, attribution
failing -> UNATTRIBUTED (where the cell's attribution can fail at all), self-check failing ->
PROBE-BROKEN. Every static cell: oracle unreadable -> NOT RUN, and a thrift reply that is an
error or empty never reads GREEN (its negative read fails). Then the named fixtures: rule D,
expected refusals, the decision order, Q1, CH7, K1's N vs N+1, and the rest of M1-M18.
"""
import copy
import os
import re
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.environ.get("P4_HEALTH_UNDER_TEST") or os.path.join(REPO, "tools"))

from p4_health import expected as E  # noqa: E402
from p4_health import frames as F  # noqa: E402
from p4_health.cells import table as T  # noqa: E402
from p4_health.cells import verdict as V  # noqa: E402

PKG = os.path.dirname(os.path.abspath(T.__file__))
EXPECTED_TSV = os.path.join(REPO, "doc", "audit", "2026-10-03_p4-health-check", "expected_today.tsv")
P4_SRC = os.path.join(os.path.dirname(PKG), "exercise", "src", "hc_main.p4")

ALL_ATTR = {"bmv2": True, "wire": True, "static": True}
#: The best a cell can read today by its own definition (P4: section 12 item 8).
BEST = {"P4": V.PARTIAL}


def ctx_green(**over):
    """A context in which every gate is GREEN and every self-check passed."""
    ctx = V.Context()
    for c in T.TABLE.cells:
        ctx.cells[c.id] = V.Verdict(V.GREEN, "fixture")
    for s in T.TABLE.self_checks:
        ctx.self_checks[s.id] = V.Verdict(V.GREEN, "fixture")
    for k, v in over.items():
        k = k.replace("_", "-")
        if k in ctx.self_checks:
            ctx.self_checks[k] = v
        else:
            ctx.cells[k] = v
    return ctx


def decide(cid, obs, ctx=None):
    return V.decide(T.TABLE.cell(cid), obs, ctx or ctx_green())


NEG_OK = {"absent": True}
PAIR = {"src_mac": "08:00:00:00:01:11", "dst_mac": "08:00:00:00:04:44"}
G1_OK = {"on_path": ["s1-s2"], "main_integral": 12.0, "off_path_max": 0}


def side(ethertype, before, after, pair=PAIR):
    return {"pair": dict(pair),
            "side_before": [dict(pair, ethertype=ethertype, samples=before)] if before is not None else [],
            "side_after": [dict(pair, ethertype=ethertype, samples=after)]}


def hb(state="usable", missing=()):
    return {"state": state, "missing_directions": list(missing)}


# (green obs, red obs) per cell. Each observation carries everything its cell reads.
FIX = {
    "PL1": ({"answer": {"pipelines": {"1": "alt", "2": "main"}}, "expect": {"pipelines": {"1": "alt", "2": "main"}},
             "oracle": {"alt_table": {"1": True}}, "negative": NEG_OK},
            {"answer": {"pipelines": {"1": "main", "2": "main"}}, "expect": {"pipelines": {"1": "alt", "2": "main"}},
             "oracle": {"alt_table": {"1": True}}, "negative": NEG_OK}),
    "PL2": ({"answer": {"skipped": ["pipeline_push"]}, "sent": 1, "oracle": {"primary": True, "set_pipeline_ok": True}},
            {"answer": {"skipped": []}, "sent": 1, "oracle": {"primary": True, "set_pipeline_ok": True}}),
    "T1": ({"answer": {"counts": {"1": {"recorded": 3, "applied": 3, "failed": 0}}}, "sent": 3,
            "expect": {"entries": {"1": ["a", "b"]}}, "oracle": {"dumps": {"1": ["a", "b"]}}, "negative": NEG_OK},
           {"answer": {"counts": {"1": {"recorded": 3, "applied": 2, "failed": 1}}}, "sent": 3,
            "expect": {"entries": {"1": ["a", "b"]}}, "oracle": {"dumps": {"1": ["a"]}}, "negative": NEG_OK}),
    "T2": ({"answer": {"applied": True}, "oracle": {"s2_default": ["HcIngress.stamp", [42]]}, "negative": NEG_OK},
           {"answer": {"applied": True}, "oracle": {"s2_default": ["HcIngress.stamp", [0]]}, "negative": NEG_OK}),
    "T3": ({"answer": {"http": 200}, "sent": 1, "oracle": {"present_after": True}, "negative": NEG_OK},
           {"answer": {"http": 200}, "sent": 1, "oracle": {"present_after": False}, "negative": NEG_OK}),
    "T4": ({"answer": {"http": 200}, "sent": 1, "oracle": {"present_after": True, "mask_ok": True, "priority_ok": True},
            "negative": NEG_OK},
           {"answer": {"http": 501}, "sent": 1, "oracle": {"present_after": False}, "attribution": {"bmv2": True}}),
    "T5": ({"answer": {"http": 200}, "sent": 1, "oracle": {"present_after": True}, "negative": NEG_OK},
           {"answer": {"http": 501}, "sent": 1, "oracle": {}, "attribution": {"bmv2": True}}),
    "T6": ({"answer": {"http": 200}, "sent": 1, "oracle": {"present_after": True}, "negative": NEG_OK},
           {"answer": {"http": 501}, "sent": 1, "oracle": {}, "attribution": {"bmv2": True}}),
    "T7": ({"answer": {"http": 200}, "sent": 2, "oracle": {"order_ok": True}, "negative": NEG_OK},
           {"answer": {"http": 200}, "sent": 2, "oracle": {"order_ok": False}, "attribution": {"bmv2": True}}),
    "T8": ({"answer": {"journaled": True}}, {"answer": {"journaled": False}}),
    "PF-T": ({"answer": {"rc": 0}}, {"answer": {"rc": 1, "g5_rows": 1, "other_fail_rows": 0}, "attribution": {"static": True}}),
    "M1": ({"answer": {"applied": 1, "recorded": 1}, "oracle": {"s1_group1": frozenset({1, 2})}, "negative": NEG_OK},
           {"answer": {"applied": 1, "recorded": 1}, "oracle": {"s1_group1": frozenset({1})}, "negative": NEG_OK}),
    "M2": ({"answer": {"http": 200}, "sent": 1, "oracle": {"group2_after": frozenset({1, 3}), "declared": [1, 3]},
            "negative": NEG_OK},
           {"answer": {"http": 502}, "sent": 1, "oracle": {"group2_after": None, "declared": [1, 3]}}),
    "C1": ({"answer": {"applied": 1}, "oracle": {"ports": frozenset({1})}, "negative": NEG_OK},
           {"answer": {"applied": 1}, "oracle": {"ports": frozenset()}, "negative": NEG_OK}),
    "C2": ({"answer": {"route": True}, "oracle": {"present_after": True, "ports_ok": True}, "negative": NEG_OK},
           {"answer": {"route": False}, "oracle": {"present_after": True}, "attribution": {"bmv2": True}}),
    "K1": ({"answer": {"http": 200, "delta": 5}, "sent": 5, "oracle": {"delta": 5}},
           {"answer": {"http": 404}, "sent": 5, "oracle": {"delta": 5}}),
    "K2": ({"answer": {"http": 200, "delta": 5}, "sent": 5, "oracle": {"delta": 5}, "pre": {"ok": True}},
           {"answer": {"http": 404}, "sent": 5, "oracle": {"delta": 5}, "pre": {"ok": True}, "attribution": {"bmv2": True}}),
    "K3": ({"answer": {"http": 200, "delta": 5}, "sent": 5, "oracle": {"delta": 5}},
           {"answer": {"http": 200, "delta": 4}, "sent": 5, "oracle": {"delta": 5}}),
    "MT1": ({"answer": {"http": 200}, "sent": 1, "oracle": {"rates_after": [[1, 2]], "target": [[1, 2]]}, "negative": NEG_OK},
            {"answer": {"http": 501}, "sent": 1, "oracle": {"rates_after": [], "target": [[1, 2]]}, "attribution": {"bmv2": True}}),
    "MT2": ({"answer": {"route": True}, "oracle": {"rates_after": [[1, 2]], "target": [[1, 2]]}, "negative": NEG_OK},
            {"answer": {"route": False}, "oracle": {}, "attribution": {"bmv2": True}}),
    "MT3": ({"answer": {"route": True}, "oracle": {"rates_after": [[1, 2]], "target": [[1, 2]]}, "negative": NEG_OK},
            {"answer": {"route": False}, "oracle": {}, "attribution": {"bmv2": True}}),
    "R2": ({"answer": {"route": True, "value": 4660}, "sent": 1, "oracle": {"value": 4660}},
           {"answer": {"route": False}, "sent": 1, "oracle": {"value": 4660}}),
    "R3": ({"answer": {"route": True}, "oracle": {"value_after": 7, "target": 7}, "negative": NEG_OK},
           {"answer": {"route": False}, "oracle": {}, "attribution": {"bmv2": True}}),
    "D1": ({"answer": {"exit": True, "fields": [1, 2]}, "sent": 1, "oracle": {"fields": [1, 2]}},
           {"answer": {"exit": False}, "sent": 1, "oracle": {"fields": [1, 2]}, "attribution": {"bmv2": True}}),
    "P1": ({"oracle": {"argv_has": True}}, {"oracle": {"argv_has": False}}),
    "P2": ({"answer": {"exit": True}, "sent": 1, "oracle": {"received": 1}},
           {"answer": {"exit": False}, "sent": 1, "oracle": {"received": 0}, "attribution": {"bmv2": True}}),
    "P3": ({"answer": {"route": True}, "sent": 1, "oracle": {"received": 1}},
           {"answer": {"route": False}, "sent": 1, "oracle": {}, "attribution": {"bmv2": True}}),
    "P4": ({"answer": {}, "sent": 1, "oracle": {"received": True}},
           {"answer": {}, "sent": 1, "oracle": {"received": False}, "attribution": {"bmv2": True}}),
    "CH1": (dict({"answer": dict(side(0x1212, 3, 9), g1=G1_OK, flow_identity=True)}, sent=5000, oracle={}),
            dict({"answer": dict(side(0x9999, 3, 9), g1=G1_OK)}, sent=5000, oracle={})),
    "CH2": (dict({"answer": dict(side(0x1234, 3, 9), g1=G1_OK, flow_identity=True)}, sent=5000, oracle={}),
            dict({"answer": dict(side(0x1234, 3, 9), g1={"on_path": []})}, sent=5000, oracle={})),
    "CH3": ({"answer": {"flow_identity": True}, "sent": 5000, "oracle": {}},
            {"answer": {"flow_identity": False}, "sent": 5000, "oracle": {}}),
    "CH4": ({"answer": {"identity": "disclosed"}, "sent": 5000, "oracle": {}},
            {"answer": {"identity": "wrong"}, "sent": 5000, "oracle": {}, "attribution": {"wire": True}}),
    "CH5": ({"answer": {"flow_identity": True}, "sent": 5000, "oracle": {}},
            {"answer": {"flow_identity": False}, "sent": 5000, "oracle": {}}),
    "CH6": ({"answer": {"flow_identity": True}, "sent": 5000, "oracle": {}},
            {"answer": {"flow_identity": False}, "sent": 5000, "oracle": {}}),
    "CH7": (dict({"answer": dict(side(0x1236, 3, 9), g1=G1_OK)}, sent=5000, oracle={}),
            dict({"answer": dict(side(0x1234, 3, 9), g1=G1_OK)}, sent=5000, oracle={})),
    "CH8": ({"answer": {"flow_identity": True}, "sent": 5000, "oracle": {}},
            {"answer": {"flow_identity": False}, "sent": 5000, "oracle": {}}),
    "Q1": ({"answer": {"sent_idents": [0]}, "sent": 100,
            "oracle": {"shaped": True, "received": [{"ident": 0x8003}, {"ident": 0x8000}]}},
           {"answer": {"sent_idents": [0]}, "sent": 100, "oracle": {"shaped": False, "received": []}}),
    "Q2": ({"oracle": {"argv_has": True}}, {"oracle": {"argv_has": False}, "attribution": {"static": True}}),
    "CS1": ({"oracle": {"tx_checksum_off": {"h1": True, "h2": True}}},
            {"oracle": {"tx_checksum_off": {"h1": True, "h2": False}}}),
    "TTL1": ({"sent": 1, "oracle": {"received": 1}}, None),
    "TP1": ({"answer": {"switches": [1], "hosts": [["h1", "10.0.1.1"]], "edges": [1], "ports": [1]},
             "oracle": {"switches": [1], "hosts": [["h1", "10.0.1.1"]], "edges": [1], "ports": [1]}},
            {"answer": {"switches": [1], "hosts": [["h1", "10.0.1.9"]], "edges": [1], "ports": [1]},
             "oracle": {"switches": [1], "hosts": [["h1", "10.0.1.1"]], "edges": [1], "ports": [1]}}),
    "TP2": ({"answer": {"heartbeat": hb(), "down_after_s": 6.0, "recovered": True}, "sent": 1, "oracle": {}},
            {"answer": {"heartbeat": hb(), "down_after_s": 25.0, "recovered": True}, "sent": 1, "oracle": {}}),
    "TP4": ({"answer": {"heartbeat": hb(), "drop_check_rc": 0, "withheld": False, "down_after_s": 6.0,
                        "recovered": True}, "sent": 1, "oracle": {}},
            {"answer": {"heartbeat": hb(), "drop_check_rc": 0, "withheld": False, "down_after_s": None,
                        "recovered": False}, "sent": 1, "oracle": {}}),
    "CP2": ({"answer": {"http": 409}, "sent": 1, "oracle": {"entry_present": False, "controller_entry_present": True}},
            {"answer": {"http": 200}, "sent": 1, "oracle": {"entry_present": True, "controller_entry_present": True}}),
    "CP4": ({"answer": {"heartbeat": hb(), "capabilities": {"ipv4_route": "ndtwin", "binding_source": "package",
                                                           "reroute": True}, "rerouted_after_s": 8.0},
             "sent": 1, "oracle": {"kernel_route_present": True, "port_after_cut": 5}, "negative": NEG_OK},
            {"answer": {"heartbeat": hb(), "capabilities": {"ipv4_route": "unbound"}, "rerouted_after_s": None},
             "sent": 1, "oracle": {"kernel_route_present": True, "port_after_cut": 4}}),
    "V1": ({"answer": {"g1": G1_OK}, "sent": 1, "oracle": {}}, {"answer": {"g1": {"on_path": []}}, "sent": 1, "oracle": {}}),
    "V2": ({"answer": {"bytes_match": True, "flow_identity": True}, "sent": 1, "oracle": {}},
           {"answer": {"bytes_match": False}, "sent": 1, "oracle": {}}),
    "AP1": ({"answer": {"route": True, "http": 200}, "sent": 1, "oracle": {"present_after": True, "points_to_member": True},
             "negative": NEG_OK},
            {"answer": {"route": False}, "sent": 1, "oracle": {}, "attribution": {"bmv2": True}}),
    "AS1": ({"answer": {"route": True, "http": 200}, "sent": 1, "oracle": {"present_after": True}, "negative": NEG_OK},
            {"answer": {"route": False}, "sent": 1, "oracle": {}, "attribution": {"bmv2": True}}),
    "IT1": ({"answer": {"idle_field": True, "notification_exit": True, "timeout_reported": True}, "sent": 1, "oracle": {}},
            {"answer": {"idle_field": False, "notification_exit": False}, "sent": 1, "oracle": {}, "attribution": {"bmv2": True}}),
    "VS1": ({"answer": {"route": True, "http": 200}, "sent": 1, "oracle": {"present_after": True}, "negative": NEG_OK},
            {"answer": {"route": False}, "sent": 1, "oracle": {}, "attribution": {"bmv2": True}}),
    "RC1": ({"answer": {"g1": G1_OK, "bytes_match": True, "flow_identity": True}, "sent": 5000, "oracle": {}},
            {"answer": {"g1": G1_OK, "bytes_match": False, "flow_identity": True}, "sent": 5000, "oracle": {}}),
    "HR1": ({"answer": {"seen": {"s1-eth4": True, "s1-eth5": False}}, "sent": 16,
             "oracle": {"carried": {"s1-eth4": True, "s1-eth5": False}}},
            {"answer": {"seen": {"s1-eth4": True, "s1-eth5": False}}, "sent": 16,
             "oracle": {"carried": {"s1-eth4": False, "s1-eth5": True}}}),
    "HR2": ({"answer": {"seen": {"s1-eth4": True, "s1-eth5": True}}, "sent": 16,
             "oracle": {"carried": {"s1-eth4": True, "s1-eth5": True}}},
            {"answer": {"seen": {"s1-eth4": True, "s1-eth5": False}}, "sent": 16,
             "oracle": {"carried": {"s1-eth4": True, "s1-eth5": True}}}),
    "HU1": (dict({"answer": dict(side(0x86DD, 1, 4), g1=G1_OK, flow_identity=True)}, sent=5000, oracle={}),
            dict({"answer": dict(side(0x0800, 1, 4), g1=G1_OK)}, sent=5000, oracle={})),
}

#: Cells whose RED needs nothing beyond NDTwin's own declaration (and, where noted, the oracle
#: reading the cell already requires): their attribution cannot fail through the observation, so
#: they have no UNATTRIBUTED fixture. Listed so a new cell cannot silently join them.
STRUCTURAL_ONLY = {"PL1", "PL2", "T1", "T2", "T3", "T8", "M1", "M2", "C1", "K3", "P1", "CH1", "CH2",
                   "CH3", "CH5", "CH6", "CH7", "CH8", "Q1", "CS1", "TP1", "TP2", "TP4", "CP2", "CP4",
                   "V1", "V2", "RC1", "HR1", "HR2", "HU1", "TTL1"}


class TestEveryCellHasItsFixtures(unittest.TestCase):

    def test_every_judged_cell_has_a_green_and_a_red_fixture(self):
        judged = {c.id for c in T.TABLE.cells if c.alias_of is None and c.by_design is None}
        self.assertEqual(judged, set(FIX))

    def test_green_fixtures_are_green(self):
        for cid, (g, _r) in sorted(FIX.items()):
            with self.subTest(cell=cid):
                self.assertEqual(decide(cid, copy.deepcopy(g)).verdict, BEST.get(cid, V.GREEN), cid)

    def test_red_fixtures_are_red_or_partial(self):
        for cid, (_g, r) in sorted(FIX.items()):
            if r is None:
                continue
            with self.subTest(cell=cid):
                obs = copy.deepcopy(r)
                obs.setdefault("attribution", dict(ALL_ATTR))
                self.assertEqual(decide(cid, obs).verdict, V.RED, (cid, decide(cid, obs)))

    def test_an_active_cell_with_nothing_sent_is_not_run(self):
        for c in T.TABLE.cells:
            if c.kind != "active" or c.id not in FIX:
                continue
            with self.subTest(cell=c.id):
                obs = copy.deepcopy(FIX[c.id][0])
                obs["sent"] = 0
                v = decide(c.id, obs)
                self.assertEqual(v.verdict, V.NOT_RUN, (c.id, v))
                self.assertEqual(v.phase, "stimulus")

    def test_an_unreadable_oracle_is_not_run_never_green(self):
        for c in T.TABLE.cells:
            if not c.needs_oracle or c.id not in FIX:
                continue
            with self.subTest(cell=c.id):
                obs = copy.deepcopy(FIX[c.id][0])
                obs["oracle"] = None
                v = decide(c.id, obs)
                self.assertEqual(v.verdict, V.NOT_RUN, (c.id, v))

    def test_attribution_that_fails_is_unattributed_never_red(self):
        can_fail = [c for c in T.TABLE.cells if c.id in FIX and FIX[c.id][1] is not None
                    and c.id not in STRUCTURAL_ONLY]
        self.assertEqual({c.id for c in T.TABLE.cells if c.id in FIX} - STRUCTURAL_ONLY,
                         {c.id for c in can_fail})
        for c in can_fail:
            with self.subTest(cell=c.id):
                obs = copy.deepcopy(FIX[c.id][1])
                obs["attribution"] = {"bmv2": False, "wire": False, "static": False}
                if "thrift" in c.red_attribution:
                    obs["oracle"] = None
                v = decide(c.id, obs)
                self.assertEqual(v.verdict, V.UNATTRIBUTED, (c.id, v))

    def test_structural_only_cells_really_need_only_structural(self):
        for cid in STRUCTURAL_ONLY:
            with self.subTest(cell=cid):
                self.assertTrue(set(T.TABLE.cell(cid).red_attribution) <= {"structural", "thrift"})

    def test_a_failed_self_check_makes_its_cells_probe_broken_not_red(self):
        for c in T.TABLE.cells:
            if not c.self_checks or c.id not in FIX:
                continue
            for sc in c.self_checks:
                with self.subTest(cell=c.id, sc=sc):
                    ctx = ctx_green(**{sc: V.Verdict(V.PROBE_BROKEN, "fixture: failed")})
                    v = decide(c.id, copy.deepcopy(FIX[c.id][0]), ctx)
                    self.assertEqual(v.verdict, V.PROBE_BROKEN, (c.id, v))


class TestStaticCells(unittest.TestCase):
    """DESIGN 5.2-① for T2, M1, C1, PL1, T1's dump half, P1, Q2, CS1, TP1."""
    STATIC = ("T2", "M1", "C1", "PL1", "T1", "P1", "Q2", "CS1", "TP1")
    THRIFT_MATCH = ("T2", "M1", "C1", "PL1", "T1")

    def test_oracle_unreadable_is_not_run(self):
        for cid in self.STATIC:
            with self.subTest(cell=cid):
                obs = copy.deepcopy(FIX[cid][0])
                obs["oracle"] = None
                self.assertEqual(decide(cid, obs).verdict, V.NOT_RUN)

    def test_an_error_read_as_a_match_fails_the_negative_read(self):
        """A thrift layer that turned an error or an empty reply into "present" makes the
        same-window negative read find the absent object present -> PROBE-BROKEN, never GREEN."""
        for cid in self.THRIFT_MATCH:
            with self.subTest(cell=cid):
                obs = copy.deepcopy(FIX[cid][0])
                obs["negative"] = {"absent": False, "why": "fixture: the error reply read as present"}
                self.assertEqual(decide(cid, obs).verdict, V.PROBE_BROKEN)

    def test_no_negative_read_no_green(self):
        for c in T.TABLE.cells:
            if not c.negative_read or c.id not in FIX:
                continue
            with self.subTest(cell=c.id):
                obs = copy.deepcopy(FIX[c.id][0])
                obs.pop("negative", None)
                self.assertEqual(decide(c.id, obs).verdict, V.NOT_RUN)

    def test_every_write_then_read_cell_has_a_negative_read(self):
        """DESIGN 2.1 (r5): every 'matches after the write' cell reads 'absent before' too."""
        for cid in ("T3", "T4", "T5", "T6", "T7", "M2", "C2", "MT1", "MT2", "MT3", "R3", "AP1", "AS1", "VS1"):
            self.assertTrue(T.TABLE.cell(cid).negative_read, cid)


class TestRuleD(unittest.TestCase):

    def judge(self, cells, scs):
        return V.judge_all(T.TABLE, cells, scs)

    def base_obs(self):
        cells = {cid: copy.deepcopy(g) for cid, (g, _r) in FIX.items()}
        scs = {"SC-fwd": {"pingall": (30, 30), "dump_ok": True},
               "SC-count": {"thrift_delta": 5, "sent": 5, "received": 5},
               "SC-reg": {"chosen": 4660, "register": 4660},
               "SC-qstamp": {"sent_idents": {0}, "stamped": 2},
               "SC-ttl": {"hops_lpm": 2, "ttls": [62, 62]},
               "SC-recirc": {"flags": [0x0C]},
               "SC-union": {"hops": 2, "hop_limits": [62]}}
        return cells, scs

    def test_a_red_gate_makes_its_dependants_not_run_and_the_round_publishable(self):
        cells, scs = self.base_obs()
        cells["PL1"] = copy.deepcopy(FIX["PL1"][1])
        ctx = self.judge(cells, scs)
        self.assertEqual(ctx.cells["PL1"].verdict, V.RED)
        self.assertEqual(ctx.self_checks["SC-fwd"].verdict, V.NOT_RUN)
        self.assertIn("gate PL1 RED", ctx.self_checks["SC-fwd"].reason)
        for cid in ("K1", "R2", "Q1", "TTL1", "K3"):
            self.assertEqual(ctx.cells[cid].verdict, V.NOT_RUN, cid)
            self.assertIn("gate PL1 RED", ctx.cells[cid].reason, cid)
        self.assertEqual(V.run_verdict(ctx)[0], "COMPLETE")

    def test_every_gate_green_and_sc_fwd_failing_is_probe_broken(self):
        cells, scs = self.base_obs()
        scs["SC-fwd"] = {"pingall": (29, 30), "dump_ok": True}
        ctx = self.judge(cells, scs)
        self.assertEqual(ctx.self_checks["SC-fwd"].verdict, V.PROBE_BROKEN)
        self.assertEqual(ctx.cells["K1"].verdict, V.PROBE_BROKEN)
        self.assertEqual(V.run_verdict(ctx), ("PROBE-BROKEN", 1))

    def test_t7_is_not_run_while_t4_is_red(self):
        cells, scs = self.base_obs()
        cells["T4"] = dict(copy.deepcopy(FIX["T4"][1]), attribution={"bmv2": True})
        ctx = self.judge(cells, scs)
        self.assertEqual(ctx.cells["T4"].verdict, V.RED)
        self.assertEqual(ctx.cells["T7"].verdict, V.NOT_RUN)
        self.assertIn("gate T4 RED", ctx.cells["T7"].reason)

    def test_the_whole_table_judges_green_from_green_fixtures(self):
        cells, scs = self.base_obs()
        cells["K1-neg"] = {"answer": {"http": 404}}
        cells["T3-neg"] = {"answer": {"http": 404}}
        ctx = self.judge(cells, scs)
        bad = {k: v.label for k, v in ctx.cells.items()
               if v.verdict != BEST.get(k, V.GREEN) and k != "VB1"}
        self.assertEqual(bad, {})
        self.assertEqual(ctx.cells["CP1"].verdict, ctx.cells["T1"].verdict)


class TestNamedFixtures(unittest.TestCase):

    # expected refusals (DESIGN 2.1 step 1, r4 L03)
    def test_cp2s_409_is_the_pass_and_not_a_red_candidate(self):
        v = decide("CP2", copy.deepcopy(FIX["CP2"][0]))
        self.assertEqual(v.verdict, V.GREEN)
        self.assertEqual(v.phase, "compare")

    def test_k1_neg_and_t3_neg_404_pass(self):
        for ctl in T.TABLE.controls:
            self.assertEqual(ctl.judge({"answer": {"http": 404}}).verdict, V.GREEN, ctl.id)
            self.assertEqual(ctl.judge({"answer": {"http": 200}}).verdict, V.PROBE_BROKEN, ctl.id)
            self.assertNotEqual(ctl.judge({"answer": {"http": 404}}).verdict, V.RED)

    # the decision order (M11)
    def test_a_cannot_answer_with_the_oracle_unreadable_is_a_red_candidate_not_not_run(self):
        v = decide("T4", {"answer": {"http": 501}, "sent": 1, "oracle": None, "attribution": {"bmv2": True}})
        self.assertEqual((v.verdict, v.phase), (V.RED, "cannot"))
        v = decide("K1", {"answer": {"http": 404}, "sent": 5, "oracle": None})
        self.assertNotEqual(v.verdict, V.NOT_RUN)
        self.assertEqual(v.phase, "cannot")

    def test_a_cannot_answer_wins_over_a_failed_gate(self):
        ctx = ctx_green(**{"SC-reg": V.Verdict(V.NOT_RUN, "gate PL1 RED")})
        v = decide("R2", copy.deepcopy(FIX["R2"][1]), ctx)
        self.assertEqual((v.verdict, v.phase), (V.RED, "cannot"))

    # M1, M5: K1
    def test_k1_thrift_n_ndtwin_n_plus_1_is_red(self):
        v = decide("K1", {"answer": {"http": 200, "delta": 6}, "sent": 5, "oracle": {"delta": 5}})
        self.assertEqual(v.verdict, V.RED)

    def test_k1_503_is_not_a_zero(self):
        v = decide("K1", {"answer": {"http": 503, "delta": None}, "sent": 5, "oracle": {"delta": 0}})
        self.assertEqual(v.verdict, V.RED)

    # M2: R2's openapi fixture
    def test_r2_with_no_route_is_a_structural_red_not_an_absent_value(self):
        v = decide("R2", {"answer": {"route": False}, "sent": 1, "oracle": {"value": 4660}})
        self.assertEqual((v.verdict, v.phase), (V.RED, "cannot"))
        self.assertIn("no route", v.reason)

    # M8, section 12 item 6: CH7
    def test_ch7_is_not_satisfied_by_another_ethertypes_row(self):
        for et in (0x1234, 0x0806, 0x86DD, 0x88B5):
            with self.subTest(ethertype=hex(et)):
                obs = {"answer": dict(side(et, 3, 9), g1=G1_OK), "sent": 5000, "oracle": {}}
                self.assertNotEqual(decide("CH7", obs).verdict, V.GREEN)

    def test_ch7_row_with_the_wrong_mac_pair_or_no_new_samples_is_not_green(self):
        wrong_pair = {"answer": dict(side(0x1236, 3, 9, pair={"src_mac": "08:00:00:00:01:11",
                                                             "dst_mac": "08:00:00:00:05:55"}),
                                     g1=G1_OK, pair=PAIR), "sent": 5000, "oracle": {}}
        self.assertNotEqual(decide("CH7", wrong_pair).verdict, V.GREEN)
        stale = {"answer": dict(side(0x1236, 9, 9), g1=G1_OK), "sent": 5000, "oracle": {}}
        self.assertNotEqual(decide("CH7", stale).verdict, V.GREEN)

    # M9: T8
    def test_t8_journaled_false_is_red(self):
        self.assertEqual(decide("T8", {"answer": {"journaled": False}}).verdict, V.RED)

    # M10: TP2's deadline
    def test_tp2_past_the_deadline_is_red(self):
        v = decide("TP2", copy.deepcopy(FIX["TP2"][1]))
        self.assertEqual(v.verdict, V.RED)
        self.assertEqual(T.LINK_DOWN_DEADLINE_S, 20.0)

    def test_tp2_without_a_usable_heartbeat_is_not_run(self):
        obs = copy.deepcopy(FIX["TP2"][0])
        obs["answer"]["heartbeat"] = hb(missing=["1:4->2:2"])
        self.assertEqual(decide("TP2", obs).verdict, V.NOT_RUN)

    # M15: TP4's heartbeat is "usable", not "not null"
    def test_tp4_with_a_heartbeat_that_is_there_but_not_usable_is_not_run(self):
        for state in ("not_read", "stale", "no_report"):
            with self.subTest(state=state):
                obs = copy.deepcopy(FIX["TP4"][0])
                obs["answer"]["heartbeat"] = hb(state=state)
                v = decide("TP4", obs)
                self.assertEqual((v.verdict, v.phase), (V.NOT_RUN, "precondition"))

    def test_cp4_without_a_usable_heartbeat_is_not_run(self):
        obs = copy.deepcopy(FIX["CP4"][0])
        obs["answer"]["heartbeat"] = {"state": "not_read"}
        self.assertEqual(decide("CP4", obs).verdict, V.NOT_RUN)

    # M16: Q1
    def test_q1_with_id_1_and_no_stamp_is_not_green(self):
        obs = {"answer": {"sent_idents": [1]}, "sent": 100,
               "oracle": {"shaped": True, "received": [{"ident": 0x0005}]}}
        self.assertNotEqual(decide("Q1", obs).verdict, V.GREEN)
        obs = {"answer": {"sent_idents": [0]}, "sent": 100,
               "oracle": {"shaped": True, "received": [{"ident": 0x0005}]}}
        self.assertNotEqual(decide("Q1", obs).verdict, V.GREEN)

    def test_q1_shaped_and_stamped_but_qdepth_zero_is_unattributed(self):
        obs = {"answer": {"sent_idents": [0]}, "sent": 100,
               "oracle": {"shaped": True, "received": [{"ident": 0x8000}]}}
        self.assertEqual(decide("Q1", obs).verdict, V.UNATTRIBUTED)

    # M13
    def test_a_red_whose_bmv2_attribution_failed_is_unattributed(self):
        v = decide("T4", {"answer": {"http": 501}, "sent": 1, "oracle": {}, "attribution": {"bmv2": False}})
        self.assertEqual(v.verdict, V.UNATTRIBUTED)
        self.assertFalse(v.attribution["ok"])

    def test_pft_static_attribution_counts_for_bmv2(self):
        v = decide("PF-T", copy.deepcopy(FIX["PF-T"][1]))
        self.assertEqual(v.verdict, V.RED)
        v = decide("PF-T", {"answer": {"rc": 1, "g5_rows": 1, "other_fail_rows": 0}})
        self.assertEqual(v.verdict, V.UNATTRIBUTED)
        v = decide("PF-T", {"answer": {"rc": 1, "g5_rows": 1, "other_fail_rows": 1}})
        self.assertEqual(v.verdict, V.PROBE_BROKEN)

    def test_p4_received_is_partial_b(self):
        v = decide("P4", copy.deepcopy(FIX["P4"][0]))
        self.assertEqual(v.label, "PARTIAL(b)")

    def test_vb1_is_not_run_by_design(self):
        v = decide("VB1", {"answer": {"flow_identity": True}, "sent": 5000, "oracle": {}})
        self.assertEqual((v.verdict, v.phase), (V.NOT_RUN, "design"))
        self.assertIn("CH6", v.reason)

    def test_it1_today_is_a_structural_cannot(self):
        v = decide("IT1", copy.deepcopy(FIX["IT1"][1]))
        self.assertEqual((v.verdict, v.phase), (V.RED, "cannot"))
        self.assertIn("IdleTimeoutNotification", v.reason)

    def test_hr2_needs_both_uplinks_carrying(self):
        obs = copy.deepcopy(FIX["HR2"][0])
        obs["oracle"]["carried"]["s1-eth5"] = False
        self.assertEqual(decide("HR2", obs).verdict, V.NOT_RUN)


class TestSelfChecks(unittest.TestCase):

    def sc(self, sid):
        return [s for s in T.TABLE.self_checks if s.id == sid][0]

    # M18
    def test_a_self_check_is_never_red(self):
        for s in T.TABLE.self_checks:
            ctx = ctx_green()
            v = V.decide_self_check(s, {}, ctx)
            self.assertIn(v.verdict, (V.PROBE_BROKEN, V.NOT_RUN), s.id)

    def test_sc_count_uses_the_switchs_ingress_count_when_known(self):
        ok, _ = self.sc("SC-count").check({"thrift_delta": 5, "netdev_in": 5, "sent": 9, "received": 3})
        self.assertTrue(ok)
        ok, _ = self.sc("SC-count").check({"thrift_delta": 5, "netdev_in": 6, "sent": 5, "received": 5})
        self.assertFalse(ok)

    def test_sc_count_without_netdev_needs_zero_loss(self):
        ok, _ = self.sc("SC-count").check({"thrift_delta": 4, "sent": 5, "received": 4})
        self.assertFalse(ok)
        ok, _ = self.sc("SC-count").check({"thrift_delta": 5, "sent": 5, "received": 5})
        self.assertTrue(ok)

    def test_sc_reg_needs_the_markers_own_nonzero_value(self):
        self.assertFalse(self.sc("SC-reg").check({"chosen": 4660, "register": 1})[0])
        self.assertFalse(self.sc("SC-reg").check({"chosen": 0, "register": 0})[0])
        self.assertTrue(self.sc("SC-reg").check({"chosen": 4660, "register": 4660})[0])

    def test_sc_qstamp_needs_the_sender_to_have_sent_id_0(self):
        self.assertFalse(self.sc("SC-qstamp").check({"sent_idents": {0, 0x8001}, "stamped": 3})[0])
        self.assertFalse(self.sc("SC-qstamp").check({"sent_idents": {0}, "stamped": 0})[0])
        self.assertTrue(self.sc("SC-qstamp").check({"sent_idents": {0}, "stamped": 1})[0])

    def test_sc_ttl_counts_hops_from_the_lpm_path_not_the_topology(self):
        links = {(1, 4): 2, (2, 2): 1, (1, 5): 3, (3, 2): 1, (2, 3): 4, (4, 2): 2, (3, 3): 4, (4, 3): 3}
        short = {2: {"10.0.6.6": 3}, 4: {"10.0.6.6": 1}}
        long_ = {2: {"10.0.6.6": 2}, 1: {"10.0.6.6": 5}, 3: {"10.0.6.6": 3}, 4: {"10.0.6.6": 1}}
        self.assertEqual(T.hops_from_lpm(short, links, 2, "10.0.6.6"), 2)
        self.assertEqual(T.hops_from_lpm(long_, links, 2, "10.0.6.6"), 4)
        loop = {2: {"10.0.6.6": 2}, 1: {"10.0.6.6": 4}}
        self.assertIsNone(T.hops_from_lpm(loop, links, 2, "10.0.6.6"))
        self.assertFalse(self.sc("SC-ttl").check({"hops_lpm": 4, "ttls": [62]})[0])
        self.assertTrue(self.sc("SC-ttl").check({"hops_lpm": 4, "ttls": [60]})[0])

    def test_sc_recirc_and_sc_union(self):
        self.assertFalse(self.sc("SC-recirc").check({"flags": [0x08]})[0])
        self.assertTrue(self.sc("SC-recirc").check({"flags": [0x0C]})[0])
        self.assertFalse(self.sc("SC-union").check({"hops": 1, "hop_limits": [64]})[0])
        self.assertTrue(self.sc("SC-union").check({"hops": 1, "hop_limits": [63]})[0])


class TestRollup(unittest.TestCase):

    def ctx_of(self, verdicts):
        ctx = V.Context()
        for c in T.TABLE.cells:
            ctx.cells[c.id] = V.Verdict(V.NOT_RUN, "")
        for cid, v in verdicts.items():
            ctx.cells[cid] = V.Verdict(v, "")
        return ctx

    # M6
    def test_a_dimension_with_only_not_run_cells_is_undecided(self):
        r = V.rollup(T.TABLE, self.ctx_of({}), "core")
        self.assertEqual(r["dimensions"]["meters"], V.UNDECIDED)
        self.assertEqual(r["totals"][V.CAN], 0)

    # M7
    def test_green_and_red_in_one_dimension_is_partial_not_the_best(self):
        r = V.rollup(T.TABLE, self.ctx_of({"MT1": V.GREEN, "MT2": V.RED}), "core")
        self.assertEqual(r["dimensions"]["meters"], V.PART)

    def test_unattributed_is_not_counted(self):
        r = V.rollup(T.TABLE, self.ctx_of({"MT1": V.GREEN, "MT2": V.UNATTRIBUTED}), "core")
        self.assertEqual(r["dimensions"]["meters"], V.CAN)

    def test_core_counts_core_cells_and_sixteen_keys_full_counts_twenty_two(self):
        r = V.rollup(T.TABLE, self.ctx_of({"MT1": V.RED, "MT2": V.RED, "MT3": V.GREEN}), "core")
        self.assertEqual(r["dimensions"]["meters"], V.CANNOT)
        self.assertEqual(len(r["dimensions"]), 16)
        r = V.rollup(T.TABLE, self.ctx_of({"MT1": V.RED, "MT2": V.RED, "MT3": V.GREEN}), "full")
        self.assertEqual(r["dimensions"]["meters"], V.PART)
        self.assertEqual(len(r["dimensions"]), 22)

    def test_the_predictions_give_the_designs_rollups(self):
        """DESIGN 5.1: core most likely 10 / 3 / 3 / 0, full (16 keys) 6 / 7 / 3 / 0."""
        exp = E.load(EXPECTED_TSV)
        verdicts = {cid: re.sub(r"\(.\)$", "", row["expected"]) for cid, row in exp.items()
                    if cid in {c.id for c in T.TABLE.cells}}
        ctx = self.ctx_of(verdicts)
        core = V.rollup(T.TABLE, ctx, "core")["totals"]
        self.assertEqual((core[V.CAN], core[V.PART], core[V.CANNOT], core[V.UNDECIDED]), (10, 3, 3, 0))
        full = V.rollup(T.TABLE, ctx, "full")["dimensions"]
        sixteen = [full[d] for d in T.CORE_DIMENSIONS]
        self.assertEqual((sixteen.count(V.CAN), sixteen.count(V.PART), sixteen.count(V.CANNOT),
                          sixteen.count(V.UNDECIDED)), (6, 7, 3, 0))

    def test_telemetry_none_needs_v1_ch1_ch7_red_and_no_link_usage(self):
        ok, _ = V.telemetry_none_check({"V1": V.RED, "CH1": V.RED, "CH7": V.RED}, True)
        self.assertTrue(ok)
        self.assertFalse(V.telemetry_none_check({"V1": V.RED, "CH1": V.GREEN, "CH7": V.RED}, True)[0])
        self.assertFalse(V.telemetry_none_check({"V1": V.RED, "CH1": V.RED, "CH7": V.RED}, False)[0])


class TestExpectedFile(unittest.TestCase):

    def test_the_file_covers_every_cell_and_control_once_with_the_tables_metadata(self):
        exp = E.load(EXPECTED_TSV)
        ids = {c.id for c in T.TABLE.cells} | {c.id for c in T.TABLE.controls}
        self.assertEqual(set(exp), ids)
        for c in T.TABLE.cells:
            row = exp[c.id]
            self.assertEqual((row["dimension"], row["scope"], row["bringup"], row["cut"]),
                             (c.dimension, c.scope, c.bringup, str(c.cut)), c.id)
            self.assertEqual(row["added"], "cut1-q3b" if c.q3b else "r6", c.id)
            self.assertTrue(row["basis"].strip(), c.id)

    # M12
    def test_the_prediction_comes_from_the_file_not_from_the_run(self):
        exp = E.load(EXPECTED_TSV)
        self.assertEqual(exp["T4"]["expected"], "RED")
        ctx = V.Context()
        ctx.cells["T4"] = V.Verdict(V.GREEN, "fixed")
        ctx.cells["T1"] = V.Verdict(V.GREEN, "")
        ann = E.annotate(ctx, exp)
        self.assertEqual(ann["T4"], ("RED", "flipped"))
        self.assertEqual(ann["T1"], ("GREEN", "same"))

    def test_a_malformed_file_is_refused(self):
        import tempfile
        d = tempfile.mkdtemp(prefix="p4h-expected-%d-" % os.getpid())
        path = os.path.join(d, "bad.tsv")
        with open(path, "w") as fh:
            fh.write("cell\texpected\nT4\tRED\n")
        with self.assertRaises(E.ExpectedError):
            E.load(path)
        import shutil
        shutil.rmtree(d)


class TestTheTableAgainstTheDesign(unittest.TestCase):

    def test_counts(self):
        t = T.TABLE
        self.assertEqual(len(t.counted("core")), 34)
        self.assertEqual(len(t.counted("ext", q3b=False)), 13)
        self.assertEqual(len(t.counted(q3b=True)), 9)
        by = {}
        for c in t.counted(q3b=False):
            by[c.bringup] = by.get(c.bringup, 0) + 1
        self.assertEqual(by, {"A": 40, "B": 5, "C": 1, "S0": 1})
        self.assertEqual(len(t.controls), 2)
        self.assertEqual(len([s for s in t.self_checks if not s.q3b]), 5)

    def test_rule_d_edges_are_the_designs(self):
        sc = {s.id: (set(s.gates), set(s.self_checks)) for s in T.TABLE.self_checks}
        self.assertEqual(sc["SC-fwd"], ({"PL1", "T1", "TP1"}, set()))
        for sid in ("SC-count", "SC-reg", "SC-qstamp"):
            self.assertEqual(sc[sid], (set(), {"SC-fwd"}))
        self.assertEqual(sc["SC-ttl"], ({"TP1"}, {"SC-fwd"}))
        self.assertEqual(T.TABLE.cell("K3").self_checks, ("SC-count",))   # section 12 item 7

    def test_the_dports_are_the_programs(self):
        with open(P4_SRC) as fh:
            src = fh.read()
        defined = {m.group(1): int(m.group(2)) for m in re.finditer(r"#define HC_DPORT_(\w+)\s+(\d+)", src)}
        self.assertEqual(defined, T.DPORTS)
        self.assertTrue(all(40001 <= v <= 40099 for v in T.DPORTS.values()))

    def test_the_heartbeat_drop_is_the_first_statement_of_ingress(self):
        with open(P4_SRC) as fh:
            src = fh.read()
        apply = src[src.index("control HcIngress"):]
        apply = apply[apply.index("    apply {"):]
        first = [l.strip() for l in apply.splitlines()[1:] if l.strip() and not l.strip().startswith(("/*", "*"))]
        self.assertEqual(first[0], "if (hdr.ethernet.etherType == TYPE_HB) {")
        self.assertEqual(first[1:4], ["#ifdef HC_MUTANT_FWD_88B5", "standard_metadata.egress_spec = 1;", "#else"])
        self.assertEqual(first[4:7], ["mark_to_drop(standard_metadata);", "#endif", "exit;"])

    def test_the_committed_exercise_files_are_the_generators(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "hc_gen", os.path.join(os.path.dirname(PKG), "exercise", "gen_runtime.py"))
        gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gen)
        self.assertEqual(gen.main(["--check"]), 0)

    def test_the_marker_layout(self):
        p = F.payload("run1", "K1", 7)
        self.assertEqual(p[:5], b"NDTHC")
        self.assertEqual(len(p), 25)
        self.assertEqual(F.parse_payload(p), ("run1", "K1", 7))
        frame = F.udp_marker("08:00:00:00:01:11", "08:00:00:00:04:44", "10.0.1.1", "10.0.4.4", 40011,
                             "run1", "K1", 7)
        got = F.parse(frame)
        self.assertEqual((got["dport"], got["ttl"], got["marker"], got["ip_csum_ok"]),
                         (40011, 64, ("run1", "K1", 7), True))


class TestS0Pieces(unittest.TestCase):
    """The parts of S0 that decide something from text (the rest is seen live, in the S0 log)."""

    def test_pft_is_the_g5_answer_only_when_nothing_else_failed(self):
        from p4_health import s0
        with open(os.path.join(REPO, "tests", "python", "fixtures", "p4_health", "preflight_pft.txt")) as fh:
            text = fh.read()
        self.assertEqual(s0.classify_pft(text), (1, 0))
        more = text.replace("  PASS  p4c-bm2-ss", "  FAIL  p4c-bm2-ss")
        self.assertEqual(s0.classify_pft(more), (1, 1))
        cont = text + "  FAIL                                    a second problem under the same row\n"
        self.assertEqual(s0.classify_pft(cont), (1, 0))

    def test_runtime_entries_as_cli_commands(self):
        from p4_health import runtime_cli as RC
        p4info = ('tables {\n  preamble {\n    id: 1\n    name: "I.t"\n  }\n  match_fields {\n    id: 1\n'
                  '    name: "hdr.a"\n  }\n  match_fields {\n    id: 2\n    name: "meta.b"\n  }\n}\n'
                  'actions {\n  preamble {\n    id: 2\n    name: "I.fwd"\n  }\n  params {\n    id: 1\n'
                  '    name: "mac"\n  }\n  params {\n    id: 2\n    name: "port"\n  }\n}\n')
        keys, params = RC.p4info_orders(p4info)
        self.assertEqual((keys, params), ({"I.t": ["hdr.a", "meta.b"]}, {"I.fwd": ["mac", "port"]}))
        rt = {"table_entries": [
            {"table": "I.t", "match": {"meta.b": 1, "hdr.a": ["10.0.0.1", 32]}, "action_name": "I.fwd",
             "action_params": {"port": 3, "mac": "08:00:00:00:00:01"}},
            {"table": "I.t", "default_action": True, "action_name": "I.fwd",
             "action_params": {"port": 0, "mac": "00:00:00:00:00:00"}}],
              "multicast_group_entries": [{"multicast_group_id": 1, "replicas": [{"egress_port": 1}, {"egress_port": 2}]}],
              "clone_session_entries": [{"clone_session_id": 7, "replicas": [{"egress_port": 1}]}]}
        self.assertEqual(RC.commands(rt, keys, params), [
            "table_add I.t I.fwd 10.0.0.1/32 1 => 08:00:00:00:00:01 3",
            "table_set_default I.t I.fwd 00:00:00:00:00:00 0",
            "mc_mgrp_create 1", "mc_node_create 1 1 2", "mc_node_associate 1 0", "mirroring_add 7 1"])
        with self.assertRaises(RC.Untranslatable):
            RC.commands({"table_entries": [dict(rt["table_entries"][0], priority=1)]}, keys, params)


if __name__ == "__main__":
    unittest.main()
