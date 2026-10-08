#!/usr/bin/env python3
"""The P4 health check's verdict functions, on fixtures (design 5.2-①).

[Co-developed with claude code -- Adam]

Pure functions, no I/O. The package under test is tools/p4_health, or the copy that
$P4_HEALTH_UNDER_TEST names (tests/shell/mutate_p4_health.sh points it at a mutated copy).

Every judged cell gets: green; red; NDTwin's answer unreadable -> NOT RUN; an answer or oracle
that is readable but EMPTY -> NOT RUN, never GREEN; sent=0 -> NOT RUN (active); oracle
unreadable -> NOT RUN; attribution failing -> UNATTRIBUTED (where it can fail); self-check
failing -> PROBE-BROKEN. Static thrift-match cells: a thrift reply read as a match fails the
negative read. Then the named fixtures: rule D, the controls, expected refusals, the decision
order, every compare branch the Cut 1 review listed, the three rollups, and the predictions.
"""
import copy
import os
import re
import subprocess
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.environ.get("P4_HEALTH_UNDER_TEST") or os.path.join(REPO, "tools"))

from p4_health import expected as E  # noqa: E402
from p4_health import frames as F  # noqa: E402
from p4_health import report as R  # noqa: E402
from p4_health.cells import table as T  # noqa: E402
from p4_health.cells import verdict as V  # noqa: E402
from p4_health import attribution as AT  # noqa: E402
from p4_health import controller_ext as CX  # noqa: E402
from p4_health import round_a as RA  # noqa: E402



class MustNotRun(BaseException):
    """What a test double raises where the code under test must not get to. Not an Exception:
    `probe.py lab` turns any Exception into rc 2 (round 5, #2), which would let a test that expects
    rc 2 pass even though the double was reached."""


PKG = os.path.dirname(os.path.abspath(T.__file__))
EXPECTED_TSV = os.path.join(REPO, "doc", "audit", "2026-10-03_p4-health-check", "expected_today.tsv")
P4_SRC = os.path.join(os.path.dirname(PKG), "exercise", "src", "hc_main.p4")

#: The two records expected_today.tsv's header cites; they live on the trunk branch, not on main.
CITED_RECORDS = ("doc/audit/2026-09-04_p4-tutorial-exercise-prep/GAP-2b-ndtwin-p4-capabilities-2026-09-27.md",
                 "doc/audit/2026-10-03_p4-health-check/DESIGN.md")


class _NoGit(Exception):
    """git cannot answer for this tree; the message says why, in git's own words where it has any."""


def _git(repo, *args):
    """git -C repo args: the CompletedProcess, or _NoGit when git is missing or times out."""
    try:
        return subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        raise _NoGit("git %s timed out after 60 s" % " ".join(args))
    except OSError as e:
        raise _NoGit("git is not available (%s)" % e)


def _git_checkout_head(repo):
    """Check that repo is itself a git checkout with a HEAD commit, else raise _NoGit with git's stderr.
    The toplevel must be repo itself: a tree extracted inside some other repository is not a checkout."""
    top = _git(repo, "rev-parse", "--show-toplevel")
    if top.returncode != 0:
        raise _NoGit("git could not open this tree as a checkout (git said: %s)" % (top.stderr.strip() or "nothing"))
    if os.path.realpath(top.stdout.strip()) != os.path.realpath(repo):
        raise _NoGit("this tree is inside another git repository (%s), not a checkout of its own" % top.stdout.strip())
    head = _git(repo, "rev-parse", "--verify", "-q", "HEAD^{commit}")
    if head.returncode != 0:
        raise _NoGit("this checkout has no HEAD commit (git said: %s)" % (head.stderr.strip() or "nothing"))


def _ref_list(names, cap=10):
    """The refs for a message, at most cap of them, then "... and N more"."""
    names = list(names)
    return ", ".join(names[:cap]) + (" ... and %d more" % (len(names) - cap) if len(names) > cap else "")


def _trunk_ref_names(repo):
    """Every trunk ref of the checkout: refs/heads/trunk, then refs/remotes/<remote>/trunk."""
    out = _git(repo, "for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes")
    if out.returncode != 0:
        raise _NoGit("git could not list the refs of this tree (git said: %s)" % (out.stderr.strip() or "nothing"))
    names = out.stdout.split()
    return ([n for n in names if n == "refs/heads/trunk"]
            + [n for n in names if re.fullmatch(r"refs/remotes/[^/]+/trunk", n)]), names


def _in_tree(repo, ref, rel):
    """Whether ref's tree holds the path rel."""
    return _git(repo, "cat-file", "-e", "%s:%s" % (ref, rel)).returncode == 0


def _decisive_trunk_ref(repo):
    """(ref, why_not): the ONE ref that decides what trunk holds. refs/heads/trunk when it exists, else the
    only refs/remotes/<remote>/trunk; with none, or several of those and no local trunk, (None, reason
    saying the test declined to choose, naming the refs found). Refs are never pooled: a stale remote must
    not vouch for a path trunk dropped."""
    trunks, names = _trunk_ref_names(repo)
    if "refs/heads/trunk" in trunks:
        return "refs/heads/trunk", ""
    if len(trunks) == 1:
        return trunks[0], ""
    if not trunks:
        return None, ("the test declined to choose a ref: this checkout has no trunk ref (refs found: %s)"
                      % (_ref_list(names) or "none"))
    return None, ("the test declined to choose a ref: this checkout has no local trunk and several remote trunk"
                  " refs, so none is decisive (%s)" % _ref_list(trunks))


ALL_ATTR = {"bmv2": True, "wire": True, "static": True}
#: The best a cell can read today by its own definition (P4: section 12 item 8).
BEST = {"P4": V.PARTIAL}
CONTROL_OK = {"answer": {"http": 404, "error": "not in this pipeline"}}


def ctx_green(**over):
    """A context in which every gate and control is GREEN and every self-check passed."""
    ctx = V.Context()
    for c in T.TABLE.cells + T.TABLE.controls:
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
S4 = ("1", "2", "3", "4")
PIPES = {"1": "alt", "2": "main", "3": "main", "4": "main"}


def side(ethertype, before, after, pair=PAIR):
    return {"pair": dict(pair),
            "side_before": [dict(pair, ethertype=ethertype, samples=before)] if before is not None else [],
            "side_after": [dict(pair, ethertype=ethertype, samples=after)]}


def hb(state="usable", missing=()):
    return {"state": state, "missing_directions": list(missing)}


def win(eth4, eth5, base=100):
    return {"s1-eth4": {"base": base, "during": base + eth4}, "s1-eth5": {"base": base, "during": base + eth5}}


def ident(ethertype, g1=G1_OK, flow=True, before=3, after=9):
    a = dict(side(ethertype, before, after), g1=dict(g1), flow_identity=flow)
    return {"answer": a, "sent": 5000}


COUNTS = {d: {"recorded": 3, "applied": 3, "failed": 0} for d in S4}
DUMPS = {d: ["a%s" % d, "b%s" % d] for d in S4}

# (green obs, red obs) per cell. Each observation carries everything its cell reads.
FIX = {
    "PL1": ({"answer": {"pipelines": dict(PIPES)}, "expect": {"pipelines": dict(PIPES)},
             "oracle": {"alt_table": {"1": True}}, "negative": NEG_OK},
            {"answer": {"pipelines": dict(PIPES, **{"1": "main"})}, "expect": {"pipelines": dict(PIPES)},
             "oracle": {"alt_table": {"1": True}}, "negative": NEG_OK}),
    "PL2": ({"answer": {"skipped": ["pipeline_push"]}, "sent": 1, "oracle": {"primary": True, "set_pipeline_ok": True}},
            {"answer": {"skipped": []}, "sent": 1, "oracle": {"primary": True, "set_pipeline_ok": True}}),
    "T1": ({"answer": {"counts": copy.deepcopy(COUNTS)}, "sent": 3, "expect": {"entries": copy.deepcopy(DUMPS)},
            "oracle": {"dumps": copy.deepcopy(DUMPS)}, "negative": NEG_OK},
           {"answer": {"counts": dict(COUNTS, **{"2": {"recorded": 3, "applied": 2, "failed": 1}})}, "sent": 3,
            "expect": {"entries": copy.deepcopy(DUMPS)}, "oracle": {"dumps": copy.deepcopy(DUMPS)}, "negative": NEG_OK}),
    "T2": ({"answer": {"applied": True}, "oracle": {"s2_default": ["HcIngress.stamp", [42]]}, "negative": NEG_OK},
           {"answer": {"applied": True}, "oracle": {"s2_default": ["HcIngress.stamp", [0]]}, "negative": NEG_OK}),
    "T3": ({"answer": {"http": 200}, "sent": 1, "oracle": {"present_after": True}, "negative": NEG_OK},
           {"answer": {"http": 200}, "sent": 1, "oracle": {"present_after": False}, "negative": NEG_OK}),
    "T4": ({"answer": {"http": 200}, "sent": 1, "oracle": {"present_after": True, "mask_ok": True, "priority_ok": True},
            "negative": NEG_OK},
           {"answer": {"http": 501}, "sent": 1, "oracle": {"present_after": False}, "attribution": {"bmv2": True}}),
    "T5": ({"answer": {"http": 200}, "sent": 1, "oracle": {"present_after": True, "priority_ok": True}, "negative": NEG_OK},
           {"answer": {"http": 501}, "sent": 1, "oracle": {}, "attribution": {"bmv2": True}}),
    "T6": ({"answer": {"http": 200}, "sent": 1, "oracle": {"present_after": True, "priority_ok": True}, "negative": NEG_OK},
           {"answer": {"http": 501}, "sent": 1, "oracle": {}, "attribution": {"bmv2": True}}),
    "T7": ({"answer": {"http": 200}, "sent": 2, "oracle": {"order_ok": True}, "negative": NEG_OK},
           {"answer": {"http": 200}, "sent": 2, "oracle": {"order_ok": False}, "attribution": {"bmv2": True}}),
    "T8": ({"answer": {"journaled": True}}, {"answer": {"journaled": False}}),
    "PF-T": ({"answer": {"rc": 0}}, {"answer": {"rc": 1, "g5_rows": 1, "other_fail_rows": 0}, "attribution": {"static": True}}),
    "M1": ({"answer": {"applied": 1, "recorded": 1}, "oracle": {"s1_group1": frozenset({1, 2})}, "negative": NEG_OK},
           {"answer": {"applied": 1, "recorded": 1}, "oracle": {"s1_group1": frozenset({1})}, "negative": NEG_OK}),
    "M2": ({"answer": {"http": 200}, "sent": 1, "oracle": {"group2_after": frozenset({1, 3}), "declared": [1, 3]},
            "negative": NEG_OK},
           {"answer": {"http": 502}, "sent": 1, "oracle": {"group2_after": frozenset(), "declared": [1, 3]}}),
    "C1": ({"answer": {"applied": 1}, "oracle": {"ports": frozenset({1})}, "negative": NEG_OK},
           {"answer": {"applied": 1}, "oracle": {"ports": frozenset()}, "negative": NEG_OK}),
    "C2": ({"answer": {"route": True, "http": 200}, "oracle": {"present_after": True, "ports_ok": True}, "negative": NEG_OK},
           {"answer": {"route": False}, "oracle": {"present_after": True}, "attribution": {"bmv2": True}}),
    "K1": ({"answer": {"http": 200, "delta": 5}, "sent": 5, "oracle": {"delta": 5}},
           {"answer": {"http": 404}, "sent": 5, "oracle": {"delta": 5}}),
    "K2": ({"answer": {"http": 200, "delta": 5}, "sent": 5, "oracle": {"delta": 5}},
           {"answer": {"http": 404}, "sent": 5, "oracle": {"delta": 5}, "attribution": {"bmv2": True}}),
    "K3": ({"answer": {"http": 200, "delta": 5}, "sent": 5, "oracle": {"delta": 5}},
           {"answer": {"http": 200, "delta": 4}, "sent": 5, "oracle": {"delta": 5}}),
    "MT1": ({"answer": {"http": 200}, "sent": 1, "oracle": {"rates_after": [[1, 2]], "target": [[1, 2]]}, "negative": NEG_OK},
            {"answer": {"http": 501}, "sent": 1, "oracle": {"rates_after": [], "target": [[1, 2]]}, "attribution": {"bmv2": True}}),
    "MT2": ({"answer": {"route": True, "http": 200}, "oracle": {"rates_after": [[1, 2]], "target": [[1, 2]]}, "negative": NEG_OK},
            {"answer": {"route": False}, "oracle": {}, "attribution": {"bmv2": True}}),
    "MT3": ({"answer": {"route": True, "http": 200}, "oracle": {"rates_after": [[1, 2]], "target": [[1, 2]]}, "negative": NEG_OK},
            {"answer": {"route": False}, "oracle": {}, "attribution": {"bmv2": True}}),
    "R2": ({"answer": {"route": True, "value": 4660}, "sent": 1, "oracle": {"value": 4660}},
           {"answer": {"route": False}, "sent": 1, "oracle": {"value": 4660}}),
    "R3": ({"answer": {"route": True, "http": 200}, "oracle": {"value_after": 7, "target": 7}, "negative": NEG_OK},
           {"answer": {"route": False}, "oracle": {}, "attribution": {"bmv2": True}}),
    "D1": ({"answer": {"exit": True, "fields": [1, 2]}, "sent": 1, "oracle": {"fields": [1, 2]}},
           {"answer": {"exit": False}, "sent": 1, "oracle": {"fields": [1, 2]}, "attribution": {"bmv2": True}}),
    "P1": ({"oracle": {"argv_has": True}}, {"oracle": {"argv_has": False}}),
    "P2": ({"answer": {"exit": True}, "sent": 1, "oracle": {"received": 1}},
           {"answer": {"exit": False}, "sent": 1, "oracle": {"received": 0}, "attribution": {"bmv2": True}}),
    "P3": ({"answer": {"route": True, "http": 200}, "sent": 1, "oracle": {"received": 1}},
           {"answer": {"route": False}, "sent": 1, "oracle": {}, "attribution": {"bmv2": True}}),
    "P4": ({"sent": 1, "oracle": {"received": True}},
           {"sent": 1, "oracle": {"received": False}, "attribution": {"bmv2": True}}),
    "CH1": (ident(0x1212), ident(0x9999, flow=False)),
    "CH2": (ident(0x1234), ident(0x1234, g1={"on_path": [], "main_integral": 0, "off_path_max": 0})),
    "CH3": ({"answer": {"flow_identity": True}, "sent": 5000},
            {"answer": {"flow_identity": False}, "sent": 5000}),
    "CH4": ({"answer": {"identity": "disclosed"}, "sent": 5000},
            {"answer": {"identity": "wrong"}, "sent": 5000, "attribution": {"wire": True}}),
    "CH5": ({"answer": {"flow_identity": True}, "sent": 5000},
            {"answer": {"flow_identity": False}, "sent": 5000}),
    "CH6": ({"answer": {"flow_identity": True}, "sent": 5000},
            {"answer": {"flow_identity": False}, "sent": 5000}),
    "CH7": (ident(0x1236, flow=None), ident(0x1234, flow=None)),
    "CH8": ({"answer": {"flow_identity": True, "pair": PAIR, "side_after": []}, "sent": 5000},
            {"answer": {"flow_identity": False, "pair": PAIR, "side_after": []}, "sent": 5000}),
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
    "TP2": ({"answer": {"heartbeat": hb(), "down_after_s": 6.0, "recovered": True, "watched_s": 30}, "sent": 1},
            {"answer": {"heartbeat": hb(), "down_after_s": 25.0, "recovered": True, "watched_s": 30}, "sent": 1}),
    "TP4": ({"answer": {"heartbeat": hb(), "drop_check_rc": 0, "withheld": False, "down_after_s": 6.0,
                        "recovered": True, "watched_s": 30}, "sent": 1},
            {"answer": {"heartbeat": hb(), "drop_check_rc": 0, "withheld": False, "down_after_s": T.NEVER,
                        "recovered": True, "watched_s": 30}, "sent": 1}),
    "CP2": ({"answer": {"http": 409}, "sent": 1, "oracle": {"entry_present": False, "controller_entry_present": True}},
            {"answer": {"http": 200}, "sent": 1, "oracle": {"entry_present": True, "controller_entry_present": True}}),
    "CP4": ({"answer": {"heartbeat": hb(), "capabilities": {"ipv4_route": "ndtwin", "binding_source": "package",
                                                           "reroute": True}, "rerouted_after_s": 8.0,
                        "watched_s": 30},
             "sent": 1, "oracle": {"kernel_route_present": True, "port_after_cut": 5}, "negative": NEG_OK},
            {"answer": {"heartbeat": hb(), "capabilities": {"ipv4_route": "unbound"}, "rerouted_after_s": 8.0,
                        "watched_s": 30},
             "sent": 1, "oracle": {"kernel_route_present": True, "port_after_cut": 4}}),
    "V1": ({"answer": {"g1": G1_OK}, "sent": 5000},
           {"answer": {"g1": {"on_path": [], "main_integral": 0, "off_path_max": 0}}, "sent": 5000}),
    "RC1": ({"answer": {"g1": G1_OK}, "sent": 5000},
            {"answer": {"g1": {"on_path": ["s1-s2"], "main_integral": 0, "off_path_max": 0}}, "sent": 5000}),
    "V2": ({"answer": {"bytes_match": True, "flow_identity": True}, "sent": 1},
           {"answer": {"bytes_match": False, "flow_identity": True}, "sent": 1}),
    "AP1": ({"answer": {"route": True, "http": 200}, "sent": 1, "oracle": {"present_after": True, "points_to_member": True},
             "negative": NEG_OK},
            {"answer": {"route": False}, "sent": 1, "oracle": {}, "attribution": {"bmv2": True}}),
    "AS1": ({"answer": {"route": True, "http": 200}, "sent": 1, "oracle": {"present_after": True, "points_to_group": True},
             "negative": NEG_OK},
            {"answer": {"route": False}, "sent": 1, "oracle": {}, "attribution": {"bmv2": True}}),
    "IT1": ({"answer": {"idle_field": True, "notification_exit": True, "requested_timeout_ms": 5000,
                        "reported_after_s": 3.0, "watched_s": 15}, "sent": 1,
             "oracle": {"timeout_ms": 5000, "since_hit_ms": 9000},
             "negative": NEG_OK},
            {"answer": {"idle_field": False, "notification_exit": False}, "sent": 1, "oracle": {}, "attribution": {"bmv2": True}}),
    "VS1": ({"answer": {"route": True, "http": 200}, "sent": 1, "oracle": {"present_after": True}, "negative": NEG_OK},
            {"answer": {"route": False}, "sent": 1, "oracle": {}, "attribution": {"bmv2": True}}),
    "HR1": ({"answer": {"uplinks": win(100000, 50)}, "sent": T.HR_FRAMES, "oracle": {"uplinks": win(100000, 50), "flow_bytes": 100000}},
            {"answer": {"uplinks": win(50, 100000)}, "sent": T.HR_FRAMES, "oracle": {"uplinks": win(100000, 50), "flow_bytes": 100000}}),
    "HR2": ({"answer": {"uplinks": win(50000, 50000)}, "sent": T.HR_FRAMES, "oracle": {"uplinks": win(50000, 50000), "flow_bytes": 100000}},
            {"answer": {"uplinks": win(100000, 0)}, "sent": T.HR_FRAMES, "oracle": {"uplinks": win(50000, 50000), "flow_bytes": 100000}}),
    "HU1": ({"answer": {"v6": dict(side(0x86DD, 1, 4), g1=G1_OK, flow_identity=True), "x": side(0x1238, 1, 4),
                        "side_size": 10}, "sent": 5000, "sent_x": 5000},
            {"answer": {"v6": dict(side(0x86DD, 1, 4), g1=G1_OK, flow_identity=True), "x": side(0x9999, 1, 4),
                        "side_size": 10}, "sent": 5000, "sent_x": 5000}),
}

#: Cells whose RED needs nothing beyond NDTwin's own declaration (and, where noted, the oracle
#: reading the cell already requires): their attribution cannot fail through the observation, so
#: they have no UNATTRIBUTED fixture. Listed so a new cell cannot silently join them.
STRUCTURAL_ONLY = {"PL1", "PL2", "T1", "T2", "T3", "T8", "M1", "M2", "C1", "K3", "P1", "CH1", "CH2",
                   "CH3", "CH5", "CH6", "CH7", "CH8", "Q1", "CS1", "TP1", "TP2", "TP4", "CP2", "CP4",
                   "V1", "V2", "HR1", "HR2", "HU1", "TTL1", "RC1"}
#: Design 2.1 / 5.2: every cell whose GREEN rests on a thrift match reads "absent" in the same
#: window. Pinned here, so dropping the flag from a row is a red test, not a silent change.
NEGATIVE_READ_CELLS = {"PL1", "T1", "T2", "T3", "T4", "T5", "T6", "T7", "M1", "M2", "C1", "C2", "MT1",
                       "MT2", "MT3", "R3", "CP4", "AP1", "AS1", "IT1", "VS1"}


def judged():
    return [c for c in T.TABLE.cells if c.alias_of is None]


class TestEveryCellHasItsFixtures(unittest.TestCase):

    def test_every_judged_cell_has_a_green_and_a_red_fixture(self):
        self.assertEqual({c.id for c in judged()}, set(FIX))

    def test_green_fixtures_are_green(self):
        for cid, (g, _r) in sorted(FIX.items()):
            with self.subTest(cell=cid):
                self.assertEqual(decide(cid, copy.deepcopy(g)).verdict, BEST.get(cid, V.GREEN),
                                 (cid, decide(cid, copy.deepcopy(g))))

    def test_red_fixtures_are_red(self):
        for cid, (_g, r) in sorted(FIX.items()):
            if r is None:
                continue
            with self.subTest(cell=cid):
                obs = copy.deepcopy(r)
                obs.setdefault("attribution", dict(ALL_ATTR))
                self.assertEqual(decide(cid, obs).verdict, V.RED, (cid, decide(cid, obs)))

    def test_an_unreadable_answer_is_not_run(self):
        """Step 0 (review MAJ-2): no answer is no verdict, never RED and never GREEN."""
        for c in judged():
            if not c.needs_answer:
                continue
            for which in (0, 1):
                obs = copy.deepcopy(FIX[c.id][which])
                if obs is None:
                    continue
                with self.subTest(cell=c.id, fixture=which):
                    obs["answer"] = None
                    v = decide(c.id, obs)
                    self.assertEqual((v.verdict, v.phase), (V.NOT_RUN, "answer"))

    def test_an_empty_answer_or_oracle_is_never_green(self):
        """Review MAJ-1: a readable but empty reply is a reading not taken."""
        for c in judged():
            for side_ in ("answer", "oracle"):
                if not any(n.startswith(side_[0] + ":") for n in c.need):
                    continue
                with self.subTest(cell=c.id, side=side_):
                    obs = copy.deepcopy(FIX[c.id][0])
                    obs[side_] = {}
                    v = decide(c.id, obs)
                    self.assertEqual(v.verdict, V.NOT_RUN, (c.id, side_, v))

    def test_every_need_key_is_needed(self):
        """Each declared reading, removed alone from the green fixture, makes the cell NOT RUN."""
        for c in judged():
            for need in c.need:
                part, key = need.split(":")
                with self.subTest(cell=c.id, need=need):
                    obs = copy.deepcopy(FIX[c.id][0])
                    doc = obs["answer" if part == "a" else "oracle"]
                    doc.pop(key, None)
                    v = decide(c.id, obs)
                    self.assertEqual((v.verdict, v.phase), (V.NOT_RUN, "reading"), (c.id, need, v))

    def test_an_active_cell_with_nothing_sent_is_not_run(self):
        for c in judged():
            if c.kind != "active":
                continue
            with self.subTest(cell=c.id):
                obs = copy.deepcopy(FIX[c.id][0])
                obs["sent"] = 0
                v = decide(c.id, obs)
                self.assertEqual((v.verdict, v.phase), (V.NOT_RUN, "stimulus"), (c.id, v))

    def test_an_unreadable_oracle_is_not_run_never_green(self):
        for c in judged():
            if not c.needs_oracle:
                continue
            with self.subTest(cell=c.id):
                obs = copy.deepcopy(FIX[c.id][0])
                obs["oracle"] = None
                self.assertEqual(decide(c.id, obs).verdict, V.NOT_RUN, c.id)

    def test_attribution_that_fails_is_unattributed_never_red(self):
        can_fail = [c for c in judged() if FIX[c.id][1] is not None and c.id not in STRUCTURAL_ONLY]
        self.assertEqual({c.id for c in judged()} - STRUCTURAL_ONLY, {c.id for c in can_fail})
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
        for c in judged():
            for sc in c.self_checks:
                with self.subTest(cell=c.id, sc=sc):
                    ctx = ctx_green(**{sc: V.Verdict(V.PROBE_BROKEN, "fixture: failed")})
                    v = decide(c.id, copy.deepcopy(FIX[c.id][0]), ctx)
                    self.assertEqual(v.verdict, V.PROBE_BROKEN, (c.id, v))


class TestStaticCells(unittest.TestCase):
    """Design 5.2-① for T2, M1, C1, PL1, T1's dump half, P1, Q2, CS1, TP1."""
    STATIC = ("T2", "M1", "C1", "PL1", "T1", "P1", "Q2", "CS1", "TP1")

    def test_oracle_unreadable_is_not_run(self):
        for cid in self.STATIC:
            with self.subTest(cell=cid):
                obs = copy.deepcopy(FIX[cid][0])
                obs["oracle"] = None
                self.assertEqual(decide(cid, obs).verdict, V.NOT_RUN)

    def test_an_error_read_as_a_match_fails_the_negative_read(self):
        """A thrift layer that turned an error or an empty reply into "present" makes the
        same-window negative read find the absent object present -> PROBE-BROKEN, never GREEN."""
        for cid in sorted(NEGATIVE_READ_CELLS):
            with self.subTest(cell=cid):
                obs = copy.deepcopy(FIX[cid][0])
                obs["negative"] = {"absent": False, "why": "fixture: the error reply read as present"}
                self.assertEqual(decide(cid, obs).verdict, V.PROBE_BROKEN)

    def test_no_negative_read_no_green(self):
        for cid in sorted(NEGATIVE_READ_CELLS):
            with self.subTest(cell=cid):
                obs = copy.deepcopy(FIX[cid][0])
                obs.pop("negative", None)
                self.assertEqual(decide(cid, obs).verdict, V.NOT_RUN)

    def test_the_negative_read_cells_are_exactly_the_pinned_ones(self):
        self.assertEqual({c.id for c in T.TABLE.cells if c.negative_read}, NEGATIVE_READ_CELLS)

    def test_empty_fabric_or_ethtool_oracles_are_not_green(self):
        obs = copy.deepcopy(FIX["TP1"][0])
        obs["answer"] = dict.fromkeys(T.TP1_ITEMS, [])
        obs["oracle"] = dict.fromkeys(T.TP1_ITEMS, [])
        self.assertEqual(decide("TP1", obs).verdict, V.NOT_RUN)
        self.assertEqual(decide("CS1", {"oracle": {"tx_checksum_off": {}}}).verdict, V.NOT_RUN)


class TestRuleD(unittest.TestCase):

    def base_obs(self):
        cells = {cid: copy.deepcopy(g) for cid, (g, _r) in FIX.items()}
        cells["K1-neg"] = copy.deepcopy(CONTROL_OK)
        cells["T3-neg"] = copy.deepcopy(CONTROL_OK)
        scs = {"SC-fwd": {"pingall": (30, 30), "dump_ok": True},
               "SC-count": {"thrift_delta": 5, "sent": 5, "received": 5},
               "SC-reg": {"chosen": 4660, "register": 4660},
               "SC-qstamp": {"sent_idents": {0}, "stamped": 2},
               "SC-ttl": {"hops_lpm": 2, "ttls": [62, 62]},
               "SC-recirc": {"flags": [0x0C]},
               "SC-union": {"hops_v6": 2, "hop_limits": [62]}}
        return cells, scs

    def test_a_red_gate_makes_its_dependants_not_run_and_the_round_publishable(self):
        cells, scs = self.base_obs()
        cells["PL1"] = copy.deepcopy(FIX["PL1"][1])
        ctx = V.judge_all(T.TABLE, cells, scs)
        self.assertEqual(ctx.cells["PL1"].verdict, V.RED)
        self.assertEqual(ctx.self_checks["SC-fwd"].verdict, V.NOT_RUN)
        self.assertIn("gate PL1 RED", ctx.self_checks["SC-fwd"].reason)
        for cid in ("K1", "R2", "Q1", "TTL1", "K3", "HU1"):
            self.assertEqual(ctx.cells[cid].verdict, V.NOT_RUN, cid)
            self.assertIn("gate PL1 RED", ctx.cells[cid].reason, cid)
        self.assertEqual(V.run_verdict(ctx, True)[0], "COMPLETE")

    def test_every_gate_green_and_sc_fwd_failing_is_probe_broken(self):
        cells, scs = self.base_obs()
        scs["SC-fwd"] = {"pingall": (29, 30), "dump_ok": True}
        ctx = V.judge_all(T.TABLE, cells, scs)
        self.assertEqual(ctx.self_checks["SC-fwd"].verdict, V.PROBE_BROKEN)
        self.assertEqual(ctx.cells["K1"].verdict, V.PROBE_BROKEN)
        self.assertEqual(V.run_verdict(ctx, True), ("PROBE-BROKEN", 1))

    def test_an_incomplete_round_is_incomplete(self):
        cells, scs = self.base_obs()
        ctx = V.judge_all(T.TABLE, cells, scs)
        self.assertEqual(V.run_verdict(ctx, False), ("INCOMPLETE", 2))
        self.assertEqual(V.run_verdict(ctx, True), ("COMPLETE", 0))

    def test_a_stop_overrides_probe_broken_and_a_see_red_pass_needs_a_complete_run(self):
        """(Cut 2 review, round 4 F3) PROBE-BROKEN is checked first, so it used to hide both a
        recorded stop and a round that did not end clean."""
        cells, scs = self.base_obs()
        scs["SC-fwd"] = {"pingall": (29, 30), "dump_ok": True}
        ctx = V.judge_all(T.TABLE, cells, scs)
        self.assertEqual(V.run_verdict(ctx, True), ("PROBE-BROKEN", 1))
        self.assertEqual(V.run_verdict(ctx, True, stopped=True), ("INCOMPLETE", 2))
        self.assertEqual(V.run_verdict(ctx, False, stopped=True), ("INCOMPLETE", 2))
        # a see-red run: PROBE-BROKEN is the pass only when the run was complete and clean
        self.assertEqual(V.run_verdict(ctx, True, see_red=True), ("PROBE-BROKEN", 1))
        self.assertEqual(V.run_verdict(ctx, False, see_red=True), ("INCOMPLETE", 2))
        # and any other run keeps reporting what it found, complete or not
        self.assertEqual(V.run_verdict(ctx, False), ("PROBE-BROKEN", 1))
        clean_ctx = V.judge_all(T.TABLE, *self.base_obs())
        self.assertEqual(V.run_verdict(clean_ctx, True, stopped=True), ("INCOMPLETE", 2))

    def test_t7_is_not_run_while_t4_is_red(self):
        cells, scs = self.base_obs()
        cells["T4"] = dict(copy.deepcopy(FIX["T4"][1]), attribution={"bmv2": True})
        ctx = V.judge_all(T.TABLE, cells, scs)
        self.assertEqual(ctx.cells["T4"].verdict, V.RED)
        self.assertEqual(ctx.cells["T7"].verdict, V.NOT_RUN)
        self.assertIn("gate T4 RED", ctx.cells["T7"].reason)

    def test_the_whole_table_reads_green_from_green_fixtures(self):
        cells, scs = self.base_obs()
        ctx = V.judge_all(T.TABLE, cells, scs)
        bad = {k: v.label for k, v in ctx.cells.items() if v.verdict != BEST.get(k, V.GREEN)}
        self.assertEqual(bad, {})
        self.assertEqual(ctx.cells["CP1"].verdict, ctx.cells["T1"].verdict)

    def test_aliases_carry_their_sources_verdict(self):
        """VB1 = CH3 (Cut 1 review, MAJ-9) and CP1 = T1 (design 2.3). RC1 is a real cell (r3)."""
        cells, scs = self.base_obs()
        cells["CH3"] = copy.deepcopy(FIX["CH3"][1])
        ctx = V.judge_all(T.TABLE, cells, scs)
        for alias, src in (("VB1", "CH3"), ("CP1", "T1")):
            self.assertEqual(T.TABLE.cell(alias).alias_of, src)
            self.assertEqual(ctx.cells[alias].label, ctx.cells[src].label, alias)
            self.assertTrue(ctx.cells[alias].reason.startswith("= %s" % src), alias)
        self.assertEqual(ctx.cells["VB1"].verdict, V.RED)
        self.assertIn("varbit", T.TABLE.cell("VB1").alias_why)
        self.assertIsNone(T.TABLE.cell("RC1").alias_of)

    # MAJ-3: the controls gate their cells
    def test_k1_and_t3_follow_their_controls(self):
        for cell, ctl in (("K1", "K1-neg"), ("T3", "T3-neg")):
            for answer, want in (({"http": 200, "error": None}, V.PROBE_BROKEN),
                                 ({"http": 404, "error": "Not Found"}, V.PROBE_BROKEN),
                                 ({"http": 404, "error": "unknown switch"}, V.PROBE_BROKEN),
                                 (None, V.NOT_RUN)):
                with self.subTest(cell=cell, answer=answer):
                    cells, scs = self.base_obs()
                    if answer is None:
                        cells.pop(ctl)
                    else:
                        cells[ctl] = {"answer": answer}
                    ctx = V.judge_all(T.TABLE, cells, scs)
                    self.assertEqual(ctx.cells[cell].verdict, want)
                    self.assertEqual(ctx.cells[cell].phase, "control")

    def test_a_missing_route_makes_the_cell_red_and_the_round_publishable(self):
        """Review MINOR 3, decided: no counter / table-entry route -> the control is NOT RUN
        (nothing to ask), K1 / T3 are RED for "no route", and the round stays publishable."""
        cells, scs = self.base_obs()
        for cell, ctl in (("K1", "K1-neg"), ("T3", "T3-neg")):
            cells[ctl] = {"answer": {"route": False}}
            cells[cell] = {"answer": {"route": False}, "sent": 5, "oracle": {"delta": 5, "present_after": False}}
        ctx = V.judge_all(T.TABLE, cells, scs)
        for cell, ctl in (("K1", "K1-neg"), ("T3", "T3-neg")):
            self.assertEqual(ctx.cells[ctl].verdict, V.NOT_RUN)
            self.assertEqual((ctx.cells[cell].verdict, ctx.cells[cell].phase), (V.RED, "cannot"), cell)
            self.assertIn("no route", ctx.cells[cell].reason)
        self.assertEqual(V.run_verdict(ctx, True)[0], "COMPLETE")
        cells["K1"] = copy.deepcopy(FIX["K1"][0])             # the cell claims a route the control lacked
        ctx = V.judge_all(T.TABLE, cells, scs)
        self.assertEqual(ctx.cells["K1"].verdict, V.PROBE_BROKEN)

    def test_alias_only_dimensions_are_marked(self):
        """r3: a dimension whose only counted evidence is an alias says whose it is."""
        cells, scs = self.base_obs()
        for cid in ("CP2", "CP4"):
            cells.pop(cid)
        ctx = V.judge_all(T.TABLE, cells, scs)
        r = V.rollup(T.TABLE, ctx, "core")
        self.assertEqual(r["alias_only"], {"control_plane_mode": ["CP1=T1"]})
        rows = R.table_rows(T.TABLE, ctx, {})
        vb1 = [row for row in rows if row[1] == "VB1"][0]
        self.assertTrue(vb1[4].startswith("ALIAS of CH3"), vb1)
        self.assertIn("rests only on an alias: CP1=T1", R.render(rows, {s: V.rollup(T.TABLE, ctx, s) for s in V.SCOPES}))
        ctx = V.judge_all(T.TABLE, self.base_obs()[0], scs)
        self.assertEqual(V.rollup(T.TABLE, ctx, "core")["alias_only"], {})

    def test_controls_are_in_health_json(self):
        cells, scs = self.base_obs()
        ctx = V.judge_all(T.TABLE, cells, scs)
        doc = R.health("r", "t", {}, {}, [], T.TABLE, ctx, E.annotate(ctx, E.load(EXPECTED_TSV)),
                       {s: V.rollup(T.TABLE, ctx, s) for s in V.SCOPES}, "COMPLETE")
        self.assertEqual([c["id"] for c in doc["controls"]], ["K1-neg", "T3-neg"])
        self.assertEqual({c["expected_today"] for c in doc["controls"]}, {"GREEN"})
        self.assertEqual(set(doc["rollup"]), set(V.SCOPES))
        self.assertEqual(doc["aliases"], {"CP1": "T1", "VB1": "CH3"})


class TestNamedFixtures(unittest.TestCase):

    def test_cp2s_409_is_the_pass_and_not_a_red_candidate(self):
        v = decide("CP2", copy.deepcopy(FIX["CP2"][0]))
        self.assertEqual((v.verdict, v.phase), (V.GREEN, "compare"))

    def test_k1_neg_and_t3_neg_404_pass(self):
        for ctl in T.TABLE.controls:
            self.assertEqual(ctl.judge(copy.deepcopy(CONTROL_OK)).verdict, V.GREEN, ctl.id)
            self.assertEqual(ctl.judge({"answer": {"http": 200}}).verdict, V.PROBE_BROKEN, ctl.id)
            self.assertEqual(ctl.judge({"answer": {"http": 404, "error": "Not Found"}}).verdict,
                             V.PROBE_BROKEN, ctl.id)
            self.assertEqual(ctl.judge({}).verdict, V.NOT_RUN, ctl.id)

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

    def test_k1_thrift_n_ndtwin_n_plus_1_is_red(self):
        v = decide("K1", {"answer": {"http": 200, "delta": 6}, "sent": 5, "oracle": {"delta": 5}})
        self.assertEqual((v.verdict, v.phase), (V.RED, "compare"))

    def test_k1_503_is_not_a_zero(self):
        v = decide("K1", {"answer": {"http": 503, "delta": None}, "sent": 5, "oracle": {"delta": 0}})
        self.assertEqual(v.verdict, V.RED)

    def test_k2_needs_thrift_to_move_by_what_was_sent(self):
        for delta in (0, 4):
            obs = copy.deepcopy(FIX["K2"][0])
            obs["oracle"]["delta"] = delta
            self.assertEqual(decide("K2", obs).phase, "precondition", delta)

    def test_r2_with_no_route_is_a_structural_red_not_an_absent_value(self):
        v = decide("R2", {"answer": {"route": False}, "sent": 1, "oracle": {"value": 4660}})
        self.assertEqual((v.verdict, v.phase), (V.RED, "cannot"))
        self.assertIn("no route", v.reason)

    def test_ch7_is_not_satisfied_by_another_ethertypes_row(self):
        for et in (0x1234, 0x0806, 0x86DD, 0x88B5):
            with self.subTest(ethertype=hex(et)):
                self.assertNotEqual(decide("CH7", ident(et, flow=None)).verdict, V.GREEN)

    def test_ch7_row_with_the_wrong_mac_pair_or_no_new_samples_is_not_green(self):
        wrong = ident(0x1236, flow=None)
        wrong["answer"].update(side(0x1236, 3, 9, pair={"src_mac": "08:00:00:00:01:11",
                                                         "dst_mac": "08:00:00:00:05:55"}))
        wrong["answer"]["pair"] = dict(PAIR)
        self.assertNotEqual(decide("CH7", wrong).verdict, V.GREEN)
        self.assertNotEqual(decide("CH7", ident(0x1236, flow=None, before=9, after=9)).verdict, V.GREEN)

    def test_g1_needs_a_positive_integral_and_a_quiet_off_path(self):
        for g1 in ({"on_path": ["x"], "main_integral": 0, "off_path_max": 0},
                   {"on_path": ["x"], "main_integral": 5, "off_path_max": 1},
                   {"on_path": [], "main_integral": 5, "off_path_max": 0}):
            for cid in ("CH1", "CH7", "V1"):
                with self.subTest(cell=cid, g1=g1):
                    obs = copy.deepcopy(FIX[cid][0])
                    obs["answer"]["g1"] = dict(g1)
                    self.assertEqual(decide(cid, obs).verdict, V.RED)

    def test_g1_not_read_is_not_run(self):
        obs = copy.deepcopy(FIX["V1"][0])
        obs["answer"]["g1"] = {"on_path": ["x"], "main_integral": 5}
        self.assertEqual(decide("V1", obs).verdict, V.NOT_RUN)

    def test_the_sample_floor_comes_from_the_sender_not_the_emitter(self):
        """Review NEW-A: under the floor (19 expected samples at 1/256 = 4864 frames) NOT RUN;
        at or above it, a twin that saw nothing is RED whatever NDTwin's emitter says."""
        self.assertEqual(T.IDENTITY_MIN_SENT, 4864)
        for cid in ("CH1", "CH3", "CH4", "CH7", "V1", "RC1"):
            with self.subTest(cell=cid):
                obs = copy.deepcopy(FIX[cid][1])
                obs["sent"] = 4863
                v = decide(cid, obs)
                self.assertEqual((v.verdict, v.phase), (V.NOT_RUN, "stimulus"))
                obs = copy.deepcopy(FIX[cid][1])
                obs["oracle"] = {"sampled": 0}            # a broken emitter: no sample at all
                obs["attribution"] = dict(ALL_ATTR)
                self.assertEqual(decide(cid, obs).verdict, V.RED)
        obs = copy.deepcopy(FIX["HU1"][0])
        obs["sent_x"] = 100
        self.assertEqual(decide("HU1", obs).verdict, V.NOT_RUN)

    def test_telemetry_none_through_the_real_cells(self):
        """Review NEW-A: the telemetry-none bring-up's own observations, decided by the real cells,
        must give the RED that telemetry_none_check asks for: the twin has the path but no usage."""
        quiet = {"on_path": ["s1-s2", "s2-s4"], "main_integral": 0, "off_path_max": 0}
        obs = {"V1": {"answer": {"g1": dict(quiet)}, "sent": 5000},
               "CH1": {"answer": dict(side(0x1212, None, 0), g1=dict(quiet), flow_identity=False), "sent": 5000},
               "CH7": {"answer": dict(pair=dict(PAIR), side_after=[], g1=dict(quiet)), "sent": 5000}}
        got = {cid: decide(cid, o).verdict for cid, o in obs.items()}
        self.assertEqual(got, {"V1": V.RED, "CH1": V.RED, "CH7": V.RED})
        ok, why = V.telemetry_none_check(got, True)
        self.assertTrue(ok, why)

    def test_t8_journaled_false_is_red(self):
        self.assertEqual(decide("T8", {"answer": {"journaled": False}}).verdict, V.RED)

    def test_tp2_past_the_deadline_is_red(self):
        v = decide("TP2", copy.deepcopy(FIX["TP2"][1]))
        self.assertEqual(v.verdict, V.RED)
        obs = copy.deepcopy(FIX["TP2"][0])
        obs["answer"]["down_after_s"] = 25.0
        self.assertEqual(decide("TP2", obs).verdict, V.RED)
        self.assertEqual(T.LINK_DOWN_DEADLINE_S, 20.0)

    def test_a_link_that_never_went_down_is_red_not_not_read(self):
        """Review NEW-B: "watched the whole window, it never went down" is a value, not a missing key."""
        for cid in ("TP2", "TP4"):
            with self.subTest(cell=cid):
                obs = copy.deepcopy(FIX[cid][0])
                obs["answer"]["down_after_s"] = T.NEVER
                v = decide(cid, obs)
                self.assertEqual((v.verdict, v.phase), (V.RED, "compare"))
                obs["answer"]["watched_s"] = 12            # did not watch the whole deadline
                self.assertEqual(decide(cid, obs).verdict, V.NOT_RUN)
                del obs["answer"]["down_after_s"]          # not read at all
                self.assertEqual(decide(cid, obs).phase, "reading")

    def test_a_route_gone_after_the_cut_is_red(self):
        obs = copy.deepcopy(FIX["CP4"][0])
        obs["oracle"]["port_after_cut"] = T.GONE
        v = decide("CP4", obs)
        self.assertEqual((v.verdict, v.phase), (V.RED, "compare"))
        self.assertIn("gone", v.reason)
        obs = copy.deepcopy(FIX["CP4"][0])
        obs["answer"]["rerouted_after_s"] = T.NEVER
        self.assertEqual(decide("CP4", obs).verdict, V.RED)
        obs["answer"]["watched_s"] = 5
        self.assertEqual(decide("CP4", obs).verdict, V.NOT_RUN)
        obs = copy.deepcopy(FIX["CP4"][0])
        del obs["answer"]["rerouted_after_s"]
        self.assertEqual(decide("CP4", obs).phase, "reading")

    def test_malformed_timed_readings_are_probe_broken(self):
        """Cut 1 follow-up 6: the never / watched_s encoding is validated. A negative time, a
        "Never" that is not the canonical value, and a time larger than the observer's own watch
        are the observer's bug -- PROBE-BROKEN, not GREEN, not RED."""
        cells = (("TP2", "down_after_s"), ("TP4", "down_after_s"), ("CP4", "rerouted_after_s"),
                 ("IT1", "reported_after_s"))
        cases = (("a negative time", -1, 30), ("a non-canonical Never", "Never", 30),
                 ("an upper-case NEVER", "NEVER", 30), ("a boolean", True, 30),
                 ("a time past its own watched_s", 25.0, 12), ("a negative watched_s", 3.0, -5),
                 ("a watched_s that is a string", T.NEVER, "30"), ("a watched_s that is a boolean", T.NEVER, True))
        for cid, key in cells:
            for what, value, watched in cases:
                with self.subTest(cell=cid, case=what):
                    obs = copy.deepcopy(FIX[cid][0])
                    obs["attribution"] = dict(ALL_ATTR)
                    obs["answer"][key] = value
                    obs["answer"]["watched_s"] = watched
                    v = decide(cid, obs)
                    self.assertEqual((v.verdict, v.phase), (V.PROBE_BROKEN, "compare"), (cid, what, v))
            with self.subTest(cell=cid, case="deadline_met takes no negative time"):
                self.assertFalse(T.deadline_met(-1))
                self.assertTrue(T.deadline_met(0))
            with self.subTest(cell=cid, case="the valid encodings still decide"):
                obs = copy.deepcopy(FIX[cid][0])
                obs["attribution"] = dict(ALL_ATTR)
                obs["answer"][key] = 0.0                       # zero seconds is a time
                self.assertEqual(decide(cid, obs).verdict, V.GREEN)
                obs["answer"][key], obs["answer"]["watched_s"] = T.NEVER, 30
                self.assertEqual(decide(cid, obs).verdict, V.RED)

    def test_a_route_read_as_gone_during_a_short_watch_is_not_run(self):
        """Cut 1 follow-up 6: CP4 checks how long the observer watched BEFORE it reads `gone`."""
        obs = copy.deepcopy(FIX["CP4"][0])
        obs["oracle"]["port_after_cut"] = T.GONE
        obs["answer"]["rerouted_after_s"] = T.NEVER
        obs["answer"]["watched_s"] = 5
        v = decide("CP4", obs)
        self.assertEqual((v.verdict, v.phase), (V.NOT_RUN, "compare"), v)
        obs["answer"]["watched_s"] = 30                        # the whole deadline watched: RED, as before
        obs["attribution"] = dict(ALL_ATTR)
        self.assertEqual(decide("CP4", obs).verdict, V.RED)

    def test_tp2_without_a_usable_heartbeat_is_not_run(self):
        obs = copy.deepcopy(FIX["TP2"][0])
        obs["answer"]["heartbeat"] = hb(missing=["1:4->2:2"])
        self.assertEqual(decide("TP2", obs).verdict, V.NOT_RUN)

    def test_tp4_with_a_heartbeat_that_is_there_but_not_usable_is_not_run(self):
        for state in ("not_read", "stale", "no_report"):
            with self.subTest(state=state):
                obs = copy.deepcopy(FIX["TP4"][0])
                obs["answer"]["heartbeat"] = hb(state=state)
                v = decide("TP4", obs)
                self.assertEqual((v.verdict, v.phase), (V.NOT_RUN, "precondition"))

    def test_tp4_needs_the_drop_check_and_no_withheld_file(self):
        for key, value in (("drop_check_rc", 1), ("drop_check_rc", None), ("withheld", True), ("withheld", None)):
            with self.subTest(key=key, value=value):
                obs = copy.deepcopy(FIX["TP4"][0])
                obs["answer"][key] = value
                self.assertEqual(decide("TP4", obs).phase, "precondition")

    def test_cp4_without_a_usable_heartbeat_is_not_run(self):
        obs = copy.deepcopy(FIX["CP4"][0])
        obs["answer"]["heartbeat"] = {"state": "not_read"}
        self.assertEqual(decide("CP4", obs).verdict, V.NOT_RUN)

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

    def test_a_red_whose_bmv2_attribution_failed_is_unattributed(self):
        v = decide("T4", {"answer": {"http": 501}, "sent": 1, "oracle": {}, "attribution": {"bmv2": False}})
        self.assertEqual(v.verdict, V.UNATTRIBUTED)
        self.assertFalse(v.attribution["ok"])

    def test_pft_static_attribution_counts_for_bmv2(self):
        self.assertEqual(decide("PF-T", copy.deepcopy(FIX["PF-T"][1])).verdict, V.RED)
        self.assertEqual(decide("PF-T", {"answer": {"rc": 1, "g5_rows": 1, "other_fail_rows": 0}}).verdict,
                         V.UNATTRIBUTED)
        self.assertEqual(decide("PF-T", {"answer": {"rc": 1, "g5_rows": 1, "other_fail_rows": 1}}).verdict,
                         V.PROBE_BROKEN)

    def test_pft_with_no_observation_is_not_run(self):
        """Review MINOR 2."""
        self.assertEqual(decide("PF-T", {}).verdict, V.NOT_RUN)
        self.assertEqual(decide("PF-T", None).verdict, V.NOT_RUN)

    def test_p4_received_is_partial_b(self):
        self.assertEqual(decide("P4", copy.deepcopy(FIX["P4"][0])).label, "PARTIAL(b)")

    # MAJ-4: the compare branches, each with a fixture where it is the one that decides
    def test_t1s_dump_half_decides_on_its_own(self):
        obs = copy.deepcopy(FIX["T1"][0])
        obs["oracle"]["dumps"]["3"] = ["a3"]
        v = decide("T1", obs)
        self.assertEqual(v.verdict, V.RED)
        self.assertIn("s3: the thrift dump", v.reason)

    def test_t1_and_pl1_need_all_four_switches(self):
        obs = copy.deepcopy(FIX["T1"][0])
        del obs["answer"]["counts"]["4"]
        self.assertEqual(decide("T1", obs).verdict, V.RED)
        obs = copy.deepcopy(FIX["T1"][0])
        del obs["expect"]["entries"]["4"]
        self.assertEqual(decide("T1", obs).verdict, V.PROBE_BROKEN)
        obs = copy.deepcopy(FIX["T1"][0])
        del obs["oracle"]["dumps"]["4"]
        self.assertEqual(decide("T1", obs).verdict, V.NOT_RUN)
        obs = copy.deepcopy(FIX["PL1"][0])
        del obs["expect"]["pipelines"]["4"]
        self.assertEqual(decide("PL1", obs).verdict, V.PROBE_BROKEN)
        obs = copy.deepcopy(FIX["PL1"][0])
        del obs["answer"]["pipelines"]["3"]
        self.assertEqual(decide("PL1", obs).verdict, V.RED)

    def test_pl1s_thrift_half_decides_on_its_own(self):
        obs = copy.deepcopy(FIX["PL1"][0])
        obs["oracle"]["alt_table"] = {"1": False}
        v = decide("PL1", obs)
        self.assertEqual(v.verdict, V.RED)
        self.assertIn("thrift: s1", v.reason)

    def test_compare_branches_after_a_route_exists(self):
        cases = [("MT2", "oracle", "rates_after", [[9, 9]]), ("MT2", "answer", "http", 500),
                 ("MT1", "oracle", "rates_after", [[9, 9]]), ("R2", "answer", "value", 1),
                 ("R3", "oracle", "value_after", 8), ("R3", "answer", "http", 500),
                 ("D1", "answer", "fields", [9]), ("P2", "oracle", "received", 0),
                 ("P3", "oracle", "received", 0), ("P3", "answer", "http", 500),
                 ("C2", "oracle", "ports_ok", False), ("C2", "answer", "http", 500),
                 ("AP1", "oracle", "points_to_member", False), ("AS1", "oracle", "points_to_group", False),
                 ("VS1", "oracle", "present_after", False), ("T4", "oracle", "mask_ok", False),
                 ("T5", "oracle", "priority_ok", False), ("M2", "oracle", "group2_after", frozenset({1})),
                 ("V2", "answer", "bytes_match", False), ("CP4", "oracle", "port_after_cut", 4),
                 ("CP2", "answer", "http", 500), ("PL2", "oracle", "primary", False)]
        for cid, part, key, value in cases:
            with self.subTest(cell=cid, key=key):
                obs = copy.deepcopy(FIX[cid][0])
                obs[part][key] = value
                obs["attribution"] = dict(ALL_ATTR)
                v = decide(cid, obs)
                self.assertEqual((v.verdict, v.phase), (V.RED, "compare"), (cid, key, v))

    def test_empty_probe_side_inputs_are_probe_broken(self):
        """Review MINOR 1: an empty target, declared port set or marker field list is the probe's
        own fault -- PROBE-BROKEN, as pl1 and t1 already treat an incomplete expectation."""
        for cid, key, value in (("MT1", "target", []), ("MT2", "target", []), ("M2", "declared", []),
                                ("D1", "fields", [])):
            with self.subTest(cell=cid):
                obs = copy.deepcopy(FIX[cid][0])
                obs["oracle"][key] = value
                self.assertEqual(decide(cid, obs).verdict, V.PROBE_BROKEN)

    def test_hu1s_nested_readings_are_needed(self):
        """Review MINOR 2."""
        for member, key in (("v6", "g1"), ("v6", "pair"), ("v6", "flow_identity"), ("x", "pair"),
                            ("x", "side_after")):
            with self.subTest(member=member, key=key):
                obs = copy.deepcopy(FIX["HU1"][0])
                del obs["answer"][member][key]
                self.assertEqual(decide("HU1", obs).verdict, V.NOT_RUN)
        # Cut 1 follow-up 5: "looked, no flow identity" is False and still decides (PARTIAL(a),
        # the prediction); only a MISSING key is a reading not taken
        obs = copy.deepcopy(FIX["HU1"][0])
        obs["answer"]["v6"]["flow_identity"] = False
        self.assertEqual(decide("HU1", obs).verdict, V.PARTIAL)

    def test_it1_today_is_a_structural_cannot(self):
        v = decide("IT1", copy.deepcopy(FIX["IT1"][1]))
        self.assertEqual((v.verdict, v.phase), (V.RED, "cannot"))
        self.assertIn("IdleTimeoutNotification", v.reason)

    def test_it1_reads_the_switchs_own_aging(self):
        obs = copy.deepcopy(FIX["IT1"][0])
        obs["oracle"]["since_hit_ms"] = 3000
        self.assertEqual(decide("IT1", obs).phase, "precondition")
        obs = copy.deepcopy(FIX["IT1"][0])
        obs["answer"]["reported_after_s"] = T.NEVER
        obs["attribution"] = dict(ALL_ATTR)
        self.assertEqual(decide("IT1", obs).verdict, V.RED)
        obs["answer"]["reported_after_s"] = 25.0          # review MINOR 5: a report past the deadline
        obs["answer"]["watched_s"] = 30                   # (r4) ... seen, so the watch reached it
        self.assertEqual(decide("IT1", obs).verdict, V.RED)
        obs["answer"]["reported_after_s"] = T.NEVER
        obs["answer"]["watched_s"] = 4
        self.assertEqual(decide("IT1", obs).verdict, V.NOT_RUN)
        obs = copy.deepcopy(FIX["IT1"][0])
        obs["oracle"]["timeout_ms"] = 1000
        obs["oracle"]["since_hit_ms"] = 9000
        obs["attribution"] = dict(ALL_ATTR)
        v = decide("IT1", obs)
        self.assertEqual(v.verdict, V.RED)
        self.assertIn("thrift shows timeout 1000", v.reason)

    def test_hr1_needs_exactly_one_uplink_and_hr2_both(self):
        for cid, eth4, eth5 in (("HR1", 50, 50), ("HR1", 60000, 60000), ("HR2", 100000, 50), ("HR2", 0, 0)):
            with self.subTest(cell=cid, eth4=eth4, eth5=eth5):
                obs = copy.deepcopy(FIX[cid][0])
                obs["oracle"]["uplinks"] = win(eth4, eth5)
                obs["answer"]["uplinks"] = win(eth4, eth5)
                self.assertEqual(decide(cid, obs).phase, "precondition")

    @staticmethod
    def _poisson_cdf(k, lam):
        """P(X <= k) for X ~ Poisson(lam)."""
        import math
        term = total = math.exp(-lam)
        for i in range(1, k + 1):
            term *= lam / i
            total += term
        return total

    def test_hr_stimulus_size_and_order(self):
        """Review MINOR 4, redone in Cut 1 follow-up 3: HR's stimulus makes a false RED from
        sampling rare AGAINST THE CELL'S OWN ABSOLUTE THRESHOLD, fits the shaped uplink, and runs
        after TP2 and before Q1."""
        import math
        # the threshold is CARRY_SHARE x the sender's flow_bytes; one sample books SAMPLE_ONE_IN
        # frames' bytes, so a half needs this many samples to count as carrying the flow
        need = math.ceil(T.CARRY_SHARE * T.HR_FRAMES / T.SAMPLE_ONE_IN - 1e-9)
        lam_half = T.HR_FRAMES / 2.0 / T.SAMPLE_ONE_IN           # HR2: the coin's half, thinned 1/256
        p_half = self._poisson_cdf(need - 1, lam_half)             # a half under the threshold
        self.assertLess(2 * p_half, 1e-5, "false-RED probability of HR2 (either half)")
        p_hr1 = self._poisson_cdf(need - 1, T.HR_FRAMES / float(T.SAMPLE_ONE_IN))
        self.assertLess(p_hr1, 1e-5)                               # HR1's one loaded uplink
        # the model is the one the review computed: 20000 frames is 2.0e-5, and so is not enough
        self.assertAlmostEqual(2 * self._poisson_cdf(16 - 1, 20000 / 2.0 / 256), 1.98e-5, delta=0.05e-5)
        self.assertLess(T.HR_RATE_KBIT / 2.0, T.SHAPED_KBIT)      # HR2's half fits s1-eth5
        seconds = T.HR_FRAMES * T.HR_FRAME_BYTES * 8 / (T.HR_RATE_KBIT * 1000.0)
        self.assertLess(seconds, 30)
        for cid in ("HR1", "HR2"):
            obs = copy.deepcopy(FIX[cid][0])
            obs["sent"] = T.HR_FRAMES - 1
            self.assertEqual(decide(cid, obs).phase, "stimulus")
        order = set(T.ORDER)
        for before, after in (("TP2", "HR1"), ("TP2", "HR2"), ("HR1", "Q1"), ("HR2", "Q1"), ("TP2", "Q1")):
            self.assertIn((before, after), order)
        self.assertFalse(any(b == "Q1" for b, _a in T.ORDER))      # Q1 last

    def test_hr1_is_pinned_to_the_unshaped_uplink(self):
        """Cut 1 follow-up 3: HR1 sends HR_RATE_KBIT on one uplink; on the shaped one the shaper,
        not the program, decides what arrives -- NOT RUN, not a verdict."""
        obs = copy.deepcopy(FIX["HR1"][0])
        self.assertEqual(decide("HR1", obs).verdict, V.GREEN)
        obs["oracle"]["uplinks"] = win(50, 100000)                 # netdev: the flow went out s1-eth5
        obs["answer"]["uplinks"] = win(50, 100000)                 # ... and the twin agrees
        v = decide("HR1", obs)
        self.assertEqual((v.verdict, v.phase), (V.NOT_RUN, "precondition"), v)
        self.assertIn("shaped", v.reason)
        obs = copy.deepcopy(FIX["HR2"][0])                         # HR2 uses both, shaped one included
        self.assertEqual(decide("HR2", obs).verdict, V.GREEN)
        self.assertGreater(T.HR_RATE_KBIT, T.SHAPED_KBIT)          # why the pin matters
        self.assertNotIn(T.HR1_UPLINK, T.SHAPED_IFACES)

    def test_order_has_no_consumer_yet_and_the_comment_says_so(self):
        """Cut 1 follow-up 10: table.ORDER is read by no scheduler. If one now reads it, the comment
        beside ORDER and design 14.7 are stale -- change them with the scheduler."""
        users = []
        for root, _dirs, files in os.walk(PKG if os.path.basename(PKG) == "p4_health" else os.path.dirname(PKG)):
            for f in files:
                path = os.path.join(root, f)
                if f.endswith(".py") and os.path.abspath(path) != os.path.abspath(T.__file__):
                    with open(path, encoding="utf-8") as fh:
                        if re.search(r"\bORDER\b", fh.read()):
                            users.append(path)
        self.assertEqual(users, [], "something reads table.ORDER: update its comment and design 14.7")
        with open(T.__file__, encoding="utf-8") as fh:
            src = fh.read()
        self.assertIn("NOTHING CONSUMES THIS YET", src)

    def test_hr_quiet_window_is_subtracted(self):
        """Heartbeat bytes on both uplinks (a high base) do not make an uplink 'carry' the flow."""
        obs = copy.deepcopy(FIX["HR1"][0])
        obs["oracle"]["uplinks"] = {"s1-eth4": {"base": 900000, "during": 1000000},
                                    "s1-eth5": {"base": 900000, "during": 900100}}
        obs["answer"]["uplinks"] = copy.deepcopy(obs["oracle"]["uplinks"])
        self.assertEqual(decide("HR1", obs).verdict, V.GREEN)
        obs["answer"]["uplinks"]["s1-eth5"]["during"] = 1000000
        self.assertEqual(decide("HR1", obs).verdict, V.RED)

    def test_hu1_judges_both_members_and_the_side_table_cap(self):
        obs = copy.deepcopy(FIX["HU1"][0])
        obs["answer"]["v6"]["flow_identity"] = False
        self.assertEqual(decide("HU1", obs).label, "PARTIAL(a)")
        obs = copy.deepcopy(FIX["HU1"][1])
        self.assertIn("0x1238", decide("HU1", obs).reason)
        obs = copy.deepcopy(FIX["HU1"][0])
        obs["answer"]["side_size"] = 1020
        self.assertEqual(decide("HU1", obs).phase, "precondition")
        obs = copy.deepcopy(FIX["HU1"][0])
        obs["sent_x"] = 0
        self.assertEqual(decide("HU1", obs).verdict, V.NOT_RUN)


class TestSelfChecks(unittest.TestCase):

    def sc(self, sid):
        return [s for s in T.TABLE.self_checks if s.id == sid][0]

    def test_a_self_check_is_never_red(self):
        for s in T.TABLE.self_checks:
            v = V.decide_self_check(s, {}, ctx_green())
            self.assertIn(v.verdict, (V.PROBE_BROKEN, V.NOT_RUN), s.id)

    def test_sc_count_without_loss_and_with_it(self):
        """Section 12 item 1, zero-loss form: with loss the count is not decided at all (NOT
        RUN, never PROBE-BROKEN); an equal count over a lossy path is not a pass either."""
        for delta in (3, 5):
            ok, _ = self.sc("SC-count").check({"thrift_delta": delta, "sent": 5, "received": 3})
            self.assertIsNone(ok, delta)
        self.assertIs(self.sc("SC-count").check({"thrift_delta": 4, "sent": 5, "received": 5})[0], False)
        self.assertIs(self.sc("SC-count").check({"thrift_delta": 5, "sent": 5, "received": 5})[0], True)
        self.assertIs(self.sc("SC-count").check({"thrift_delta": 5, "netdev_in": 9, "sent": 5,
                                                 "received": 5})[0], True)
        v = V.decide_self_check(self.sc("SC-count"), {"thrift_delta": 3, "sent": 5, "received": 3},
                                ctx_green())
        self.assertEqual(v.verdict, V.NOT_RUN)

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
        self.assertFalse(self.sc("SC-union").check({"hops_v6": 1, "hop_limits": [64]})[0])
        self.assertTrue(self.sc("SC-union").check({"hops_v6": 1, "hop_limits": [63]})[0])
        self.assertFalse(self.sc("SC-union").check({"hops": 1, "hop_limits": [63]})[0])


class TestRollup(unittest.TestCase):

    def ctx_of(self, verdicts):
        ctx = V.Context()
        for c in T.TABLE.cells:
            ctx.cells[c.id] = V.Verdict(V.NOT_RUN, "")
        for cid, v in verdicts.items():
            ctx.cells[cid] = V.Verdict(v, "")
        return ctx

    def test_a_dimension_with_only_not_run_cells_is_undecided(self):
        r = V.rollup(T.TABLE, self.ctx_of({}), "core")
        self.assertEqual(r["dimensions"]["meters"], V.UNDECIDED)
        self.assertEqual(r["totals"][V.CAN], 0)

    def test_green_and_red_in_one_dimension_is_partial_not_the_best(self):
        r = V.rollup(T.TABLE, self.ctx_of({"MT1": V.GREEN, "MT2": V.RED}), "core")
        self.assertEqual(r["dimensions"]["meters"], V.PART)

    def test_unattributed_is_not_counted(self):
        r = V.rollup(T.TABLE, self.ctx_of({"MT1": V.GREEN, "MT2": V.UNATTRIBUTED}), "core")
        self.assertEqual(r["dimensions"]["meters"], V.CAN)

    def test_three_rollups_sixteen_sixteen_and_six(self):
        """Q2(a) keeps core and full at the 16 dimensions; Q3(b)'s six categories are a third
        rollup reported beside them (Cut 1 review, MAJ-10)."""
        ctx = self.ctx_of({"MT1": V.RED, "MT2": V.RED, "MT3": V.GREEN, "AP1": V.RED})
        core, full, q3b = (V.rollup(T.TABLE, ctx, s) for s in ("core", "full", "q3b"))
        self.assertEqual(core["dimensions"]["meters"], V.CANNOT)
        self.assertEqual(full["dimensions"]["meters"], V.PART)
        self.assertEqual(list(core["dimensions"]), list(T.CORE_DIMENSIONS))
        self.assertEqual(list(full["dimensions"]), list(T.CORE_DIMENSIONS))
        self.assertEqual(list(q3b["dimensions"]), list(T.Q3B_DIMENSIONS))
        self.assertEqual(sum(core["totals"].values()), 16)
        self.assertEqual(sum(full["totals"].values()), 16)
        self.assertEqual(sum(q3b["totals"].values()), 6)
        self.assertEqual(q3b["dimensions"]["action_profile"], V.CANNOT)
        self.assertNotIn("action_profile", full["dimensions"])
        with self.assertRaises(ValueError):
            V.rollup(T.TABLE, ctx, "all")

    def test_the_predictions_give_the_three_rollups(self):
        """Design 5.1: core most likely 10 / 3 / 3 / 0, full 6 / 7 / 3 / 0; the q3b rollup
        (design 14) 2 / 1 / 2 / 1."""
        exp = E.load(EXPECTED_TSV)
        verdicts = {cid: re.sub(r"\(.\)$", "", row["expected"]) for cid, row in exp.items()
                    if cid in {c.id for c in T.TABLE.cells}}
        ctx = self.ctx_of(verdicts)
        got = {}
        for scope in V.SCOPES:
            t = V.rollup(T.TABLE, ctx, scope)["totals"]
            got[scope] = (t[V.CAN], t[V.PART], t[V.CANNOT], t[V.UNDECIDED])
        self.assertEqual(got, {"core": (10, 3, 3, 0), "full": (6, 7, 3, 0), "q3b": (2, 1, 2, 1)})

    def test_telemetry_none_needs_v1_ch1_ch7_red_and_no_link_usage(self):
        self.assertTrue(V.telemetry_none_check({"V1": V.RED, "CH1": V.RED, "CH7": V.RED}, True)[0])
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
            if c.alias_of:
                self.assertEqual(row["expected"], exp[c.alias_of]["expected"], c.id)

    #: The names of the review, rulings and report records (their files stay out of the public main).
    #: This is ALL the scan checks. GAP-2b and DESIGN.md are cited on purpose: the tsv header says where
    #: they live (the trunk branch), and a test below pins that note.
    RECORD_NAMES = re.compile(r"RULINGS|\bintake\b|\bjudge-[A-Za-z0-9_.-]+|REPORT[A-Za-z0-9_.-]*\.md"
                              r"|\[relayed|scratch/overnight|DESIGN-r\d", re.IGNORECASE)

    def test_no_rulings_intake_judge_or_report_record_is_named_in_expected_today_tsv_or_tools_p4_health(self):
        """Cut 1 follow-up 11: expected_today.tsv and tools/p4_health go to the public main; neither
        may name a RULINGS, intake, judge-*, REPORT*.md, "[relayed", DESIGN-r<N> or scratch/overnight
        record. (r6: the name now says what is scanned -- those two and nothing else, so tests/ and
        every other file are not covered; and only those names, not any other citation.)"""
        paths = [EXPECTED_TSV]
        for root, _dirs, files in os.walk(os.path.dirname(PKG) if os.path.basename(PKG) != "p4_health" else PKG):
            paths += [os.path.join(root, f) for f in files if f.endswith((".py", ".sh", ".p4", ".tsv", ".json"))]
        hits = []
        for path in paths:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for n, line in enumerate(fh, 1):
                    m = self.RECORD_NAMES.search(line)
                    if m:
                        hits.append("%s:%d: %s" % (os.path.relpath(path, REPO), n, m.group(0)))
        self.assertEqual(hits, [])
        exp = E.load(EXPECTED_TSV)
        for cid in ("CH3", "CH4"):
            self.assertTrue(exp[cid]["basis"].startswith("r4 (Cut 1 follow-ups)"), cid)
            self.assertRegex(exp[cid]["basis"], r"SFlowType\.hpp:\d+")
            self.assertRegex(exp[cid]["basis"], r"hc_main\.p4:\d+")

    def test_the_header_says_where_the_cited_records_live(self):
        """Cut 1 follow-up 4 (r5): GAP-2b and DESIGN.md are cited and are not on main; the header says
        what they are and that they live on the trunk branch. Text only, so it runs on every tree,
        including a PR tree that has had doc/audit/**/*.md removed."""
        with open(EXPECTED_TSV, encoding="utf-8") as fh:
            head = [l for l in fh if l.startswith("#")]
        note = [l for l in head if "GAP-2b" in l]
        self.assertEqual(len(note), 1)
        for needle in CITED_RECORDS + ("trunk branch",):
            self.assertIn(needle, note[0])
        with open(T.__file__, encoding="utf-8") as fh:
            self.assertIn(os.path.basename(CITED_RECORDS[0]) + ", on the trunk branch", fh.read())

    def test_the_cited_records_exist_in_this_checkout_or_on_trunk(self):
        """r6: "both live in this repository" is a fact the note states. For each cited path, in order:
        (1) the file is in the working tree: pass. Otherwise git decides, and with no usable git (not a
        checkout of its own, no HEAD commit, git missing or timing out) nothing was checked and the test
        skips, with git's words as the reason. (2) HEAD's tree holds the path but the file is gone from the
        working tree: FAIL, "deleted from the working tree". (3) HEAD's tree lacks it (PRs to main strip
        doc/audit md; a squash on main; CI's checkout): ONE ref decides, refs/heads/trunk if it exists, else
        the only refs/remotes/*/trunk, else (none, or several and no local trunk) skip naming the refs. That
        ref must hold the path or the test FAILS; no other ref decides (the failure message only names
        the other trunk refs that do hold the path, as a hint). Known gap: a branch that itself deletes or
        moves a cited record passes while trunk still holds it; the first trunk run after the merge fails."""
        missing = [rel for rel in CITED_RECORDS if not os.path.isfile(os.path.join(REPO, rel))]
        if not missing:
            return
        why = "nothing was checked: %s not in the working tree, and whether trunk holds them is unknown: %s"
        try:
            _git_checkout_head(REPO)
            deleted = [rel for rel in missing if _in_tree(REPO, "HEAD", rel)]
            stripped = [rel for rel in missing if rel not in deleted]
            if deleted:
                self.fail("%s is in HEAD's tree but was deleted from the working tree" % ", ".join(deleted))
            ref, nodecisive = _decisive_trunk_ref(REPO)
            if ref is None:
                self.skipTest(why % (", ".join(stripped), nodecisive))
            absent = [rel for rel in stripped if not _in_tree(REPO, ref, rel)]
            hints = []
            if absent:
                try:  # a hint only: it must never turn the FAIL into a skip
                    for other in [r for r in _trunk_ref_names(REPO)[0] if r != ref]:
                        held = [rel for rel in absent if _in_tree(REPO, other, rel)]
                        if held:
                            hints.append("%s holds %s; is %s stale?" % (other, ", ".join(held), ref))
                except _NoGit:
                    pass
        except _NoGit as e:
            self.skipTest(why % (", ".join(missing), e))
        if absent:
            self.fail("the header note names %s, which is neither in the working tree, nor in HEAD, nor in %s%s"
                      % (", ".join(absent), ref, "".join(" -- " + h for h in hints)))

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
        import shutil
        import tempfile
        d = tempfile.mkdtemp(prefix="p4h-expected-%d-" % os.getpid())
        path = os.path.join(d, "bad.tsv")
        with open(path, "w") as fh:
            fh.write("cell\texpected\nT4\tRED\n")
        with self.assertRaises(E.ExpectedError):
            E.load(path)
        shutil.rmtree(d)


class TestTheTableAgainstTheDesign(unittest.TestCase):

    def test_counts(self):
        t = T.TABLE
        self.assertEqual(len(t.counted("core")), 34)
        self.assertEqual(len(t.counted("ext", q3b=False)), 13)
        self.assertEqual(len(t.counted(q3b=True)), 8)
        self.assertEqual(sorted(c.id for c in t.cells if c.alias_of), ["CP1", "VB1"])
        by = {}
        for c in t.counted(q3b=False):
            by[c.bringup] = by.get(c.bringup, 0) + 1
        self.assertEqual(by, {"A": 40, "B": 5, "C": 1, "S0": 1})
        self.assertEqual(len(t.controls), 2)
        self.assertEqual(len([s for s in t.self_checks if not s.q3b]), 5)

    def test_rule_d_edges_are_the_designs(self):
        sc = {s.id: (set(s.gates), set(s.self_checks)) for s in T.TABLE.self_checks}
        self.assertEqual(sc["SC-fwd"], ({"PL1", "T1", "TP1"}, set()))
        for sid in ("SC-count", "SC-reg", "SC-qstamp", "SC-recirc"):
            self.assertEqual(sc[sid], (set(), {"SC-fwd"}))
        self.assertEqual(sc["SC-ttl"], ({"TP1"}, {"SC-fwd"}))
        self.assertEqual(sc["SC-union"], ({"TP1"}, {"SC-fwd"}))
        cells = {c.id: (c.gates, c.self_checks, c.controls) for c in T.TABLE.cells if c.gates or c.self_checks or c.controls}
        self.assertEqual(cells, {"T3": ((), (), ("T3-neg",)), "T7": (("T4",), (), ()),
                                 "K1": ((), ("SC-count",), ("K1-neg",)), "K3": ((), ("SC-count",), ()),
                                 "R2": ((), ("SC-reg",), ()), "Q1": ((), ("SC-qstamp",), ()),
                                 "TTL1": ((), ("SC-ttl",), ()), "HU1": ((), ("SC-union",), ()),
                                 "RC1": ((), ("SC-recirc",), ())})

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


class TestProbeJudge(unittest.TestCase):

    def test_a_recording_that_does_not_say_it_completed_is_incomplete(self):
        """Review MINOR 19: `probe.py judge` fails closed."""
        import io
        import json as _json
        import shutil
        import tempfile
        from contextlib import redirect_stdout
        from p4_health import probe
        d = tempfile.mkdtemp(prefix="p4h-judge-%d-" % os.getpid())
        try:
            obs = os.path.join(d, "obs.json")
            for doc, rc in (({"cells": {}}, 2), ({"cells": {}, "bringups_complete": True}, 0)):
                with open(obs, "w") as fh:
                    _json.dump(doc, fh)
                with redirect_stdout(io.StringIO()):
                    got = probe.main(["judge", "--observations", obs, "--run-dir", d,
                                      "--expected", EXPECTED_TSV])
                self.assertEqual(got, rc, doc)
            with open(os.path.join(d, "health.json")) as fh:
                health = _json.load(fh)
            self.assertEqual(set(health["rollup"]), {"core", "full", "q3b"})
            self.assertEqual(len(health["controls"]), 2)
        finally:
            shutil.rmtree(d)


class TestNoMachineLiterals(unittest.TestCase):

    def test_no_home_directory_literal_in_the_tool(self):
        """Review MINOR 15: no /home/<user> path in tools/p4_health (derive or configure it)."""
        bad = []
        for root, _dirs, files in os.walk(os.path.dirname(PKG)):
            for f in files:
                if f.endswith((".py", ".sh", ".p4")):
                    path = os.path.join(root, f)
                    with open(path, encoding="utf-8") as fh:
                        if re.search(r"/home/[a-z]", fh.read()):
                            bad.append(os.path.relpath(path, REPO))
        self.assertEqual(bad, [])


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

    def test_the_inventory_needles_need_a_use_not_a_declaration(self):
        """Review MINOR 12: standard_metadata DECLARES mcast_grp and enq_qdepth in every
        program, so the inventory must look for an assignment / a read inside an action."""
        import json as _json
        import shutil
        import tempfile
        from p4_health import s0
        d = tempfile.mkdtemp(prefix="p4h-inv-%d-" % os.getpid())
        try:
            info = os.path.join(d, "x.p4info.txtpb")
            open(info, "w").write("")
            prog = {"header_types": [{"name": "standard_metadata", "fields": [["mcast_grp", 16, False],
                                                                                 ["enq_qdepth", 19, False]]}],
                    "actions": [{"name": "a", "primitives": [
                        {"op": "assign", "parameters": [{"type": "field", "value": ["meta", "x"]},
                                                        {"type": "field", "value": ["meta", "y"]}]}]}]}
            js = os.path.join(d, "x.json")
            open(js, "w").write(_json.dumps(prog))
            inv = s0.inventory(js, info)
            self.assertFalse(inv["mcast_grp"])
            self.assertFalse(inv["enq_qdepth"])
            prog["actions"][0]["primitives"] += [
                {"op": "assign", "parameters": [{"type": "field", "value": ["standard_metadata", "mcast_grp"]},
                                                {"type": "hexstr", "value": "0x1"}]},
                {"op": "assign", "parameters": [{"type": "field", "value": ["ipv4", "identification"]},
                                                {"type": "expression", "value": {"op": "&", "left": {
                                                    "type": "field", "value": ["standard_metadata", "enq_qdepth"]},
                                                    "right": None}}]}]
            open(js, "w").write(_json.dumps(prog))
            inv = s0.inventory(js, info)
            self.assertTrue(inv["mcast_grp"])
            self.assertTrue(inv["enq_qdepth"])
        finally:
            shutil.rmtree(d)


# --- Cut 2 -----------------------------------------------------------------------------------------

class TestS0Cut2Checks(unittest.TestCase):
    """m5: S0's two new safety checks decide something, so each is pinned."""

    def s0(self, replies):
        import tempfile
        from p4_health import s0
        from p4_health.collect.runner import RecordingRunner
        d = tempfile.mkdtemp(prefix="p4h-s0c2-%d-" % os.getpid())
        self.addCleanup(__import__("shutil").rmtree, d, True)
        r = RecordingRunner(replies)
        x = s0.S0(d, r, "py", log=lambda *a: None)
        x.pkgs = {n: os.path.join(d, "packages", n) for n in ("A", "B", "C", "PF-T", "FWD", "A-MUT")}
        return x, r

    def test_show_ports_with_a_cpu_port_is_judged_on_the_data_ports(self):
        from p4_health import s0
        self.assertTrue(s0.show_ports_ok({1: "p1", 2: "p2", 3: "p3"}))
        self.assertTrue(s0.show_ports_ok({1: "p1", 2: "p2", 3: "p3", 510: "p510"}))
        self.assertFalse(s0.show_ports_ok({1: "p1", 2: "p2"}))
        self.assertFalse(s0.show_ports_ok({1: "p1", 2: "p2", 3: "p3", 4: "p4"}))
        self.assertFalse(s0.show_ports_ok(None))

    def test_the_mutant_package_is_drop_checked(self):
        """The A-MUT package is the one the see-red run brings up: it must pass the drop check."""
        x, r = self.s0([(lambda a: "heartbeat_drop_check.py" in " ".join(a),
                         lambda a, e, i: (1 if a[2].endswith("/FWD") else 0, ""))])
        x.drop_check()
        checked = sorted(os.path.basename(c["argv"][2]) for c in r.calls)
        self.assertEqual(checked, ["A", "A-MUT", "B", "C", "FWD"])
        self.assertTrue(all(c["ok"] for c in x.out["checks"]), x.out["checks"])
        self.assertIn("drop check A-MUT rc 0", [c["name"] for c in x.out["checks"]])

    DRY = ("package  : p4-health-B  (mode external, grpc_base 30050)\ncontroller: %s\ncwd : x\n"
           "rewrites this package's switches would receive:\n"
           + "".join("  s%d: 127.0.0.1:%d device_id=%d  ->  localhost:%d device_id=%d\n" % (d, 50050 + d, d - 1, 30050 + d, d)
                     for d in (1, 2, 3, 4))
           + "(--dry-run: nothing was imported, patched or run)\n")

    def test_the_adapter_dry_run_names_our_controller_and_four_rewrites(self):
        from p4_health import round_b as RB
        good = self.DRY % RB.CONTROLLER
        x, r = self.s0([(lambda a: "--dry-run" in a, (0, good))])
        x.adapter_dry_run()
        self.assertEqual(r.calls[0]["argv"][:4], [r.calls[0]["argv"][0], RB.ADAPTER, x.pkgs["B"], RB.CONTROLLER])
        self.assertTrue(x.out["checks"][-1]["ok"], x.out["checks"])
        for bad in (good.replace("localhost:30053 device_id=3", "localhost:30053 device_id=2"),
                    good.replace(RB.CONTROLLER, "/elsewhere/mycontroller.py"),
                    good.replace("  s4: ", "  sX: ")):
            x, r = self.s0([(lambda a: "--dry-run" in a, (0, bad))])
            x.adapter_dry_run()
            self.assertFalse(x.out["checks"][-1]["ok"])
        x, r = self.s0([(lambda a: "--dry-run" in a, (1, good))])
        x.adapter_dry_run()
        self.assertFalse(x.out["checks"][-1]["ok"])


class TestTheLiveRunsIdentity(unittest.TestCase):
    """m4: a lab run refuses a dirty probe, and records the Q6(a) fingerprint and the system
    under test."""

    def test_a_dirty_probe_tree_is_refused_before_anything_runs(self):
        from unittest import mock
        from p4_health import probe
        asked = []

        import subprocess as sp

        def git(argv, **kw):
            asked.append(tuple(argv[3:]))
            out = " M tools/p4_health/hostside.py\n" if argv[3] == "status" else "x\n"
            return sp.CompletedProcess(argv, 0, stdout=out, stderr="")
        # the freeze is stubbed to fail loudly: it would refuse this run dir too (round 4), and a
        # test that only sees rc 2 could not tell which check said no
        with mock.patch.object(probe.subprocess, "run", git), \
                mock.patch("p4_health.frozen.freeze", side_effect=MustNotRun("the freeze must not start")), \
                mock.patch("p4_health.s0.S0", side_effect=MustNotRun("S0 must not start")):
            rc = probe.main(["lab", "--run-dir", "/nonexistent/run", "--owner", "o"])
        self.assertEqual(rc, 2)
        self.assertIn(("status", "--porcelain", "--", "tools/p4_health"), asked)

    @staticmethod
    def git_answering(rc, out="", exc=None):
        import subprocess as sp

        def run(argv, **kw):
            if argv[:1] != ["git"]:
                raise MustNotRun("unexpected spawn %r" % (argv,))
            if exc is not None:
                raise exc
            return sp.CompletedProcess(argv, rc, stdout=out, stderr="")
        return run

    def test_a_git_that_cannot_answer_is_refused_before_s0(self):
        """N3: a failed, timed-out or missing git is no answer about the tree -- not 'clean'."""
        import subprocess as sp
        from unittest import mock
        from p4_health import probe
        for kw in ({"rc": 128}, {"rc": 0, "exc": sp.TimeoutExpired("git", 10)},
                   {"rc": 0, "exc": FileNotFoundError("git")}):
            with self.subTest(kw=kw):
                with mock.patch.object(probe.subprocess, "run", self.git_answering(**kw)), \
                        mock.patch("p4_health.frozen.freeze", side_effect=MustNotRun("the freeze must not start")), \
                        mock.patch("p4_health.s0.S0", side_effect=MustNotRun("S0 must not start")):
                    rc = probe.main(["lab", "--run-dir", "/nonexistent/run", "--owner", "o"])
                self.assertEqual(rc, 2)

    def test_a_missing_identity_record_stops_the_run_before_the_lab(self):
        """N3: the first authorized run's record is the baseline of the standing authorization;
        without it, or with an incomplete fingerprint, the lab is not touched."""
        import tempfile
        from unittest import mock
        from p4_health import probe
        d = tempfile.mkdtemp(prefix="p4h-ident-%d-" % os.getpid())
        self.addCleanup(__import__("shutil").rmtree, d, True)

        class FakeS0(object):
            def __init__(self, *a, **kw):
                self.out = {"verdict": "COMPLETE"}

            def run(self):
                return 0
        good = {"sha256": "a" * 64, "parts": {}}
        for sut, gate in ((None, good), (os.path.join(d, "code_identity.json"), dict(good, sha256="incomplete"))):
            with self.subTest(sut=sut, gate=gate["sha256"]):
                # fabric_binary and the freeze are stubbed: this test must not read the real
                # bmv2_binary_override (absent from a mutant's copy), nor stop at the freeze, whose git
                # here answers nothing (round 4, F8)
                with mock.patch.object(probe.subprocess, "run", self.git_answering(0)), \
                        mock.patch("p4_health.s0.S0", FakeS0), \
                        mock.patch("p4_health.vs_trial.fabric_binary", return_value="/x/simple_switch_grpc"), \
                        mock.patch("p4_health.frozen.freeze", return_value=object()), \
                        mock.patch("p4_health.identity.system_under_test", return_value=sut), \
                        mock.patch("p4_health.identity.fingerprint", return_value=gate) as fp, \
                        mock.patch("p4_health.lab.run_lab", side_effect=MustNotRun("the lab must not start")):
                    rc = probe.main(["lab", "--run-dir", d, "--owner", "o"])
                self.assertEqual(rc, 2)
                fp.assert_called_once()                 # refused by the identity check, not by something before it

    def test_an_s0_with_a_failing_check_is_rc_2_with_a_health_json_and_no_identity_work(self):
        """(Round 5, #2) `probe.py lab` returned 1 and wrote no health.json when S0 was not
        COMPLETE; on the see-red path rc 1 is the pass. Now INCOMPLETE rc 2, with the reason in
        health.json, and neither the identity record nor the lab is started."""
        import contextlib
        import json
        import tempfile
        from unittest import mock
        from p4_health import frozen as FZ
        from p4_health import probe
        from p4_health.collect.config import Config as RealConfig
        real_freeze = FZ.freeze

        class FakeS0(object):
            def __init__(self, *a, **kw):
                self.out = {"verdict": "PROBE-BROKEN",
                            "checks": [{"name": "preflight A", "ok": False, "detail": "FAIL x"}]}

            def run(self):
                return 1
        d = tempfile.mkdtemp(prefix="p4h-s0bad-%d-" % os.getpid())
        self.addCleanup(__import__("shutil").rmtree, d, True)
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(probe.subprocess, "run", self.git_answering(0)))
            stack.enter_context(mock.patch("p4_health.s0.S0", FakeS0))
            stack.enter_context(mock.patch("p4_health.frozen.freeze",
                                           lambda run_dir, repo=None, git=None: real_freeze(run_dir)))
            # the mutation gate's copy of the package has no doc/ beside it: the predictions file is the repo's
            stack.enter_context(mock.patch("p4_health.collect.config.Config",
                                           lambda run_dir, owner=None: RealConfig(run_dir, owner=owner,
                                                                                  expected_tsv=EXPECTED_TSV)))
            fp = stack.enter_context(mock.patch("p4_health.identity.fingerprint",
                                                side_effect=MustNotRun("no identity work")))
            sut = stack.enter_context(mock.patch("p4_health.identity.system_under_test",
                                                 side_effect=MustNotRun("no identity work")))
            rc = probe.main(["lab", "--run-dir", d, "--owner", "o"])
        self.assertEqual(rc, 2)
        fp.assert_not_called()
        sut.assert_not_called()
        with open(os.path.join(d, "health.json")) as fh:
            h = json.load(fh)
        self.assertEqual(h["verdict"], "INCOMPLETE")
        self.assertTrue(any("S0 is PROBE-BROKEN" in p_ and "preflight A" in p_ for p_ in h["problems"]),
                        h["problems"])

    def test_an_exception_out_of_the_lab_path_is_rc_2_not_pythons_status_1(self):
        """(Round 5, #2) Anything `probe.py lab` does not foresee -- here S0 itself raising -- used
        to leave the process as an uncaught exception: status 1, the see-red run's pass. It is rc 2,
        with the traceback on stderr."""
        import io
        from unittest import mock
        from p4_health import frozen as FZ
        from p4_health import probe

        class BrokenS0(object):
            def __init__(self, *a, **kw):
                self.out = {}

            def run(self):
                raise RuntimeError("S0 fell over")
        err = io.StringIO()
        with mock.patch.object(probe.subprocess, "run", self.git_answering(0)), \
                mock.patch("p4_health.s0.S0", BrokenS0), \
                mock.patch("p4_health.frozen.freeze", lambda run_dir, repo=None, git=None: FZ.Frozen(run_dir, {})), \
                mock.patch("sys.stderr", err):
            rc = probe.main(["lab", "--run-dir", "/nonexistent/run", "--owner", "o"])
        self.assertEqual(rc, 2)
        self.assertIn("RuntimeError", err.getvalue())
        self.assertIn("S0 fell over", err.getvalue())

    # --- round 4, F8: an unreadable bmv2 override, with the REAL fingerprint ------------------
    def readable_machine(self, frozen=None):
        """Every part of the fingerprint except the fabric's bmv2 reads fine, so that part alone
        decides whether it says 'incomplete'. The real ID.fingerprint runs."""
        from unittest import mock
        from p4_health import identity as ID
        from p4_health.collect.runner import RecordingRunner
        return [mock.patch.object(ID, "git_lines", lambda runner, repo, *a: ["a b"]),
                mock.patch.object(ID, "file_sha", lambda p: "f" * 64),
                mock.patch.object(ID, "tree_digest", lambda *a, **k: "t" * 64),
                mock.patch.object(ID, "_which", lambda tool: "/bin/" + tool),
                mock.patch("os.path.isdir", lambda p: True),
                mock.patch("p4_health.probe.Runner", lambda: RecordingRunner([(("bash",), (0, ""))])),
                mock.patch("p4_health.identity.system_under_test", return_value="/x/code_identity.json"),
                mock.patch("p4_health.frozen.freeze", return_value=frozen or object())]

    def lab_with_the_real_fingerprint(self, fabric, frozen=None):
        import contextlib
        import json
        import tempfile
        from unittest import mock
        from p4_health import probe

        class FakeS0(object):
            def __init__(self, *a, **kw):
                self.out = {"verdict": "COMPLETE"}

            def run(self):
                return 0
        d = tempfile.mkdtemp(prefix="p4h-f8-%d-" % os.getpid())
        self.addCleanup(__import__("shutil").rmtree, d, True)
        with contextlib.ExitStack() as stack:
            for patch in self.readable_machine(frozen):
                stack.enter_context(patch)
            stack.enter_context(mock.patch.object(probe.subprocess, "run", self.git_answering(0)))
            stack.enter_context(mock.patch("p4_health.s0.S0", FakeS0))
            stack.enter_context(mock.patch("p4_health.vs_trial.fabric_binary", **fabric))
            ran = stack.enter_context(mock.patch("p4_health.lab.run_lab", return_value=(0, {})))
            rc = probe.main(["lab", "--run-dir", d, "--owner", "o"])
        with open(os.path.join(d, "gate_fingerprint.json")) as fh:
            return rc, ran, json.load(fh)

    def test_a_readable_override_gives_a_complete_fingerprint_and_the_lab_runs(self):
        """The control of the next test: with the override readable the same stubbed machine gives
        a fingerprint, so the next test's 'incomplete' is the override's doing alone."""
        rc, ran, gate = self.lab_with_the_real_fingerprint({"return_value": "/x/simple_switch_grpc"})
        self.assertNotEqual(gate["sha256"], "incomplete", gate)
        self.assertEqual(gate["parts"]["bmv2_fabric"], "f" * 64)
        self.assertEqual(rc, 0)
        ran.assert_called_once()

    def test_an_unreadable_bmv2_override_is_an_incomplete_fingerprint_and_stops_the_run(self):
        """probe.py's `except OSError: fabric = None`: not a traceback, and not a run either."""
        rc, ran, gate = self.lab_with_the_real_fingerprint({"side_effect": PermissionError("bmv2_binary_override")})
        self.assertEqual(gate["sha256"], "incomplete")
        self.assertEqual(gate["parts"]["bmv2_fabric"], "unreadable")
        self.assertEqual(rc, 2)
        ran.assert_not_called()

    # --- round 4, F4: the code a run executes is frozen early and checked against HEAD ---------
    FROZEN = ("p4_health/hostside.py", "p4_health/frames.py", "p4_health/__init__.py",
              "p4_health/controller_ext.py", "p4_exercise/run_external_controller.py",
              "p4_exercise/common.py", "p4_exercise/__init__.py")

    def scratch_repo(self):
        """A git repo of its own holding the files a lab run executes, committed."""
        import shutil
        import tempfile
        d = tempfile.mkdtemp(prefix="p4h-freeze-%d-" % os.getpid())
        self.addCleanup(shutil.rmtree, d, True)
        for rel in self.FROZEN:
            os.makedirs(os.path.dirname(os.path.join(d, "tools", rel)), exist_ok=True)
            with open(os.path.join(d, "tools", rel), "w") as fh:
                fh.write("# %s, as committed\n" % rel)
        git = ["git", "-C", d, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false"]
        subprocess.run(["git", "-C", d, "init", "-q"], check=True)
        subprocess.run(git + ["add", "."], check=True)
        subprocess.run(git + ["commit", "-q", "-m", "files"], check=True)
        return d

    def lab_in(self, repo, edit_after_status=None, edit_before_status=None):
        """probe.py lab in `repo` with S0 replaced by a marker. Returns (rc, S0 started?, stderr).
        `edit_after_status`: a callable run right after the clean check answered (the edit that
        lands between the check and the freeze)."""
        import io
        import tempfile
        from unittest import mock
        from p4_health import probe

        class Reached(BaseException):       # not an Exception: probe.py lab turns those into rc 2 (round 5, #2)
            pass

        def s0(*a, **kw):
            raise Reached()
        real = probe._git_run

        def git(*args):
            out = real(*args)
            if args[0] == "status" and edit_after_status:
                edit_after_status()
            return out
        run_dir = tempfile.mkdtemp(prefix="p4h-freeze-run-%d-" % os.getpid())
        self.addCleanup(__import__("shutil").rmtree, run_dir, True)
        err = io.StringIO()
        reached = False
        with mock.patch.object(probe, "REPO", repo), mock.patch.object(probe, "_git_run", git), \
                mock.patch("p4_health.s0.S0", s0), mock.patch("sys.stderr", err):
            try:
                rc = probe.main(["lab", "--run-dir", run_dir, "--owner", "o"])
            except Reached:
                rc, reached = None, True
        return rc, reached, err.getvalue()

    def edit(self, repo, rel):
        with open(os.path.join(repo, "tools", rel), "a") as fh:
            fh.write("# an edit nobody committed\n")

    def test_a_clean_tree_is_frozen_and_the_run_goes_on_to_s0(self):
        """The control of the next tests: the same repo with no edit reaches S0."""
        _rc, reached, _err = self.lab_in(self.scratch_repo())
        self.assertTrue(reached)

    def test_an_edit_between_the_clean_check_and_the_freeze_is_refused_before_s0(self):
        repo = self.scratch_repo()
        rc, reached, err = self.lab_in(repo, edit_after_status=lambda: self.edit(repo, "p4_health/hostside.py"))
        self.assertEqual((rc, reached), (2, False))
        self.assertIn("hostside.py", err)

    def test_every_file_a_round_executes_is_checked_against_head(self):
        for rel in self.FROZEN:
            with self.subTest(file=rel):
                repo = self.scratch_repo()
                rc, reached, err = self.lab_in(repo, edit_after_status=lambda rel=rel, repo=repo: self.edit(repo, rel))
                self.assertEqual((rc, reached), (2, False))
                self.assertIn(os.path.basename(rel), err)

    def test_a_git_that_cannot_confirm_a_copy_refuses_the_freeze(self):
        """Two empty answers are not two equal hashes; a failed hash-object is no answer."""
        from unittest import mock
        from p4_health import probe
        repo = self.scratch_repo()
        real = probe._git_run
        for what, answer in (("hash-object fails", {"hash-object": (128, "")}),
                             ("rev-parse fails", {"rev-parse": (128, "")}),
                             ("both answer nothing", {"hash-object": (0, ""), "rev-parse": (0, "")})):
            with self.subTest(what=what):
                def wrapped(*args, answer=answer):
                    return answer.get(args[0]) or real(*args)
                with mock.patch.object(probe, "_git_run", wrapped):
                    rc, reached, _err = self.lab_in(repo)
                self.assertEqual((rc, reached), (2, False))

    def test_the_frozen_set_runs_by_itself_and_takes_frames_from_the_copy(self):
        """Root's hostside.py, B's controller_ext.py (its `from p4_health import frames` inside a
        method) and the adapter run from the copy with -I: nothing is read from the shared tree."""
        import tempfile
        from p4_health import frozen as FZ
        run = tempfile.mkdtemp(prefix="p4h-freeze-self-%d-" % os.getpid())
        self.addCleanup(__import__("shutil").rmtree, run, True)
        fz = FZ.freeze(run)
        probe_code = ("import importlib.util, sys; s = importlib.util.spec_from_file_location('cx', %r); "
                      "m = importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                      "from p4_health import frames; print(frames.__file__)" % fz.controller)
        out = subprocess.run([sys.executable, "-I", "-c", probe_code], capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(os.path.realpath(out.stdout.strip()), os.path.realpath(fz.path("p4_health/frames.py")))
        for argv in ([fz.hostside, "--help"], [fz.adapter, "--help"]):
            res = subprocess.run([sys.executable, "-I"] + argv, capture_output=True, text=True, timeout=60)
            self.assertEqual(res.returncode, 0, (argv, res.stderr))

    def test_the_recorded_hash_is_of_the_copy_not_of_the_source(self):
        """(Round 4, F9) a copy that differs from its source (the case the HEAD check exists for)
        is recorded as it is: the record is what root runs."""
        import hashlib
        import shutil
        import tempfile
        from unittest import mock
        from p4_health import frozen as FZ
        run = tempfile.mkdtemp(prefix="p4h-freeze-copy-%d-" % os.getpid())
        self.addCleanup(shutil.rmtree, run, True)
        real_copy = shutil.copyfile

        def drifting_copy(src, dst, *a, **kw):
            real_copy(src, dst, *a, **kw)
            with open(dst, "a") as fh:
                fh.write("# drifted after the copy\n")
        with mock.patch.object(FZ.shutil, "copyfile", drifting_copy):
            fz = FZ.freeze(run)
        for rel, recorded in fz.sums.items():
            with open(fz.path(rel), "rb") as fh:
                self.assertEqual(recorded, hashlib.sha256(fh.read()).hexdigest(), rel)

    def test_the_run_gets_the_frozen_code_that_probe_froze(self):
        """cmd_lab hands run_lab the Frozen it froze before S0, not a second one."""
        sentinel = object()
        rc, ran, _gate = self.lab_with_the_real_fingerprint({"return_value": "/x/b"}, frozen=sentinel)
        self.assertEqual(rc, 0)
        self.assertIs(ran.call_args[1]["frozen"], sentinel)

    def test_the_may_differ_classes_are_the_designs(self):
        from p4_health import identity as ID
        for path in ("p4_proxy/proxy_agent/main.py", "src/ndt_core/x.cpp", "include/a.hpp", "libs/x",
                     "cmake/x.cmake", "CMakeLists.txt", "build/bin/ndtwin_kernel", "tests/python/t.py",
                     "doc/x.md", "doc/audit/y/expected_today.tsv"):
            self.assertTrue(ID.may_differ(path), path)
        for path in ("p4_proxy/proxy_agent/sflow_emitter.py", "p4_proxy/mininet/p4_testbed_topo.py",
                     "tools/p4_health/hostside.py", "tools/test_workflow/ndt", "doc/x.py",
                     "doc/audit/y/code.sh", "CMakeLists.txt.bak"):
            self.assertFalse(ID.may_differ(path), path)

    def test_the_fingerprint_moves_with_what_must_be_the_same_only(self):
        import tempfile
        from p4_health import identity as ID
        from p4_health.collect.runner import RecordingRunner
        d = tempfile.mkdtemp(prefix="p4h-fp-%d-" % os.getpid())
        self.addCleanup(__import__("shutil").rmtree, d, True)
        files = {"tools/p4_health/a.py": "1", "src/k.cpp": "2", "doc/n.md": "3",
                 "p4_proxy/proxy_agent/sflow_emitter.py": "4"}
        for rel, text in files.items():
            os.makedirs(os.path.dirname(os.path.join(d, rel)), exist_ok=True)
            open(os.path.join(d, rel), "w").write(text)
        r = RecordingRunner([(lambda a: a[:4] == ["git", "-C", d, "ls-files"] and "--others" not in a,
                              (0, "\0".join(files) + "\0")),
                             (lambda a: "--others" in a, (0, "")),
                             (("git",), (1, "")), (("bash",), (1, ""))])

        def fp():
            return ID.repo_parts(r, d, os.path.join(d, ".test_run", "run"))["repo_tracked"]
        base = fp()
        open(os.path.join(d, "src/k.cpp"), "w").write("changed")
        open(os.path.join(d, "doc/n.md"), "w").write("changed")
        self.assertEqual(fp(), base)
        open(os.path.join(d, "p4_proxy/proxy_agent/sflow_emitter.py"), "w").write("changed")
        self.assertNotEqual(fp(), base)
        whole = ID.fingerprint(r, d, d, ["/no/python"], ntg=os.path.join(d, "no-ntg"))
        self.assertEqual(whole["sha256"], "incomplete")          # an unread part is not a match


class TestCut2Decisions(unittest.TestCase):

    def test_a_cell_never_observed_is_not_run_for_that_reason(self):
        v = decide("CH1", None)
        self.assertEqual((v.verdict, v.phase), (V.NOT_RUN, "unobserved"))
        self.assertIn("not observed", v.reason)
        # an observation that exists but carries no answer is still the "unreadable" step
        v = decide("T4", {})
        self.assertEqual((v.verdict, v.phase), (V.NOT_RUN, "answer"))

    def test_a_cell_this_run_did_not_observe_has_no_delta(self):
        """m1: an unobserved cell is not a flip of its prediction: its delta says so."""
        ctx = V.Context()
        ctx.cells["CH1"] = decide("CH1", None)
        ctx.cells["T8"] = V.Verdict(V.RED, "x", phase="cannot")
        ctx.cells["PL1"] = V.Verdict(V.RED, "x", phase="compare")
        ann = E.annotate(ctx, {"CH1": {"expected": "PARTIAL(a)"}, "T8": {"expected": "RED"},
                               "PL1": {"expected": "GREEN"}})
        self.assertEqual(ann["CH1"], ("PARTIAL(a)", "not observed"))
        self.assertEqual(ann["T8"], ("RED", "same"))
        self.assertEqual(ann["PL1"], ("GREEN", "flipped"))
        # N7: a control this run did not observe (T3-neg in --only K1,TTL1) is no flip either
        t3neg = [c for c in T.TABLE.controls if c.id == "T3-neg"][0]
        ctx.cells["T3-neg"] = t3neg.judge(None)
        ctx.cells["K1-neg"] = T.TABLE.controls[0].judge({"answer": None})
        ann = E.annotate(ctx, {"T3-neg": {"expected": "GREEN"}, "K1-neg": {"expected": "GREEN"}})
        self.assertEqual(ann["T3-neg"], ("GREEN", "not observed"))
        self.assertEqual(ann["K1-neg"], ("GREEN", "flipped"))      # observed, and no answer: a flip

    def test_only_expands_to_the_gates_controls_and_self_check_producers(self):
        self.assertEqual(RA.expand(["K1", "TTL1"]), {"PL1", "T1", "TP1", "K1-neg", "K1", "TTL1"})
        self.assertEqual(RA.expand(["T7"]), {"T7", "T4"})
        self.assertEqual(RA.expand(["CP1"]), {"T1"})
        self.assertEqual(RA.expand(["R2"]), {"R2", "T1", "PL1", "TP1"})
        self.assertEqual(RA.expand(None), set(RA.CUT2_CELLS))
        self.assertEqual(RA.expand(["CH1"]), set())        # a Cut 3 cell is not this round's
        # a self-check named on its own brings the cell whose step takes its readings
        self.assertEqual(RA.expand(["SC-count"]), {"K1", "K1-neg", "PL1", "T1", "TP1"})
        self.assertEqual(RA.expand(["SC-reg"]), {"R2", "PL1", "T1", "TP1"})

    def test_bring_up_as_cells_are_the_cut_2_rows_of_the_table(self):
        rows = {c.id for c in T.TABLE.cells if c.cut == 2 and c.bringup == "A" and c.alias_of is None}
        self.assertEqual(set(RA.CUT2_CELLS) - {"K1-neg", "T3-neg"}, rows)


TOK = "abcd1234"


def ctrl_result(fail=(), **over):
    calls = {i: {"ok": i not in fail, "detail": None, "error": "refused" if i in fail else None}
             for i in AT.ITEMS if i != "packet_in"}
    calls["direct_counter"]["detail"] = {"packets": 200}
    res = {"attributions": calls, "digests": [{"members": [AT.ip_int("10.0.4.4"), 40041, 40041]}],
           "packet_ins": [{"ingress_port": 1, "marker": [TOK, "P2", 0]}]}
    res.update(over)
    return res


TOP = 2 ** 31 - 1


def dump(*entries):
    return {"entries": [dict(handle=i, keys=[("f", k[0], k[1])], priority=p, action="HcIngress.set_mark",
                             params=prm, member=None, group=None, life=None)
                        for i, (k, p, prm) in enumerate(entries)], "default": None}


def thrift_ok(over=None):
    t, r, o = CX.TERNARY, CX.RANGE, CX.OPTIONAL
    reads = {
        "table_dump HcIngress.t_ternary": dump((("TERNARY", "0a000400 &&& ffffff00"), TOP - 10, [41]),
                                               (("TERNARY", "0a000606 &&& ffffffff"), TOP - 30, [71]),
                                               (("TERNARY", "0a000600 &&& ffffff00"), TOP - 20, [72])),
        "table_dump HcIngress.t_range": dump((("RANGE", "9ca4 -> 9cae"), TOP - 10, [51])),
        "table_dump HcIngress.t_optional": dump((("TERNARY", "11 &&& ff"), TOP - 10, [61])),
        "meter_get_rates HcIngress.m_in 0": [(0.125, 12500), (0.125, 12500)],
        "table_dump HcIngress.t_dmeter": {"entries": [{"handle": 3, "keys": [("f", "EXACT", "9c57")]}]},
        "meter_get_rates HcIngress.dm_mt3 3": [(0.125, 12500), (0.125, 12500)],
        "mirroring_get 9": {"present": True, "port": None, "mgid": 0x8009},
        "mc_dump": {0x8009: frozenset([1])},
        "register_read HcIngress.r_mark 1": 0xBEEF,
        "table_dump HcIngress.t_dcount": {"entries": [{"handle": 5, "keys": [("f", "EXACT", "9c4c")]}]},
        "counter_read HcIngress.dc_k2 5": (0, 200),
    }
    reads.update(over or {})
    return lambda cmd: reads.get(cmd)


EXPECT = {"digest": [AT.ip_int("10.0.4.4"), 40041, 40041], "packet_in_port": 1, "packet_in_cell": "P2",
          "token": TOK}


class TestAttributionConfirm(unittest.TestCase):
    """design 4.2: a call that succeeded AND an independent reading, or the attribution fails."""

    def ok(self, result=None, read=None, p3=5, expect=EXPECT):
        got = AT.confirm(ctrl_result() if result is None else result, read or thrift_ok(), p3, expect)
        return {k: v["ok"] for k, v in got.items()}, got

    def test_every_item_confirmed(self):
        ok, got = self.ok()
        self.assertEqual(ok, {i: True for i in AT.ITEMS}, got)

    def test_a_failed_call_fails_its_item_whatever_thrift_shows(self):
        for item in AT.ITEMS:
            if item == "packet_in":
                continue
            with self.subTest(item=item):
                ok, _ = self.ok(ctrl_result(fail=(item,)))
                self.assertEqual({k for k, v in ok.items() if not v}, {item})

    def test_no_result_confirms_nothing(self):
        ok, _ = self.ok({})
        self.assertFalse(any(ok.values()))
        got = AT.confirm(None, thrift_ok(), 5, EXPECT)
        self.assertFalse(any(v["ok"] for v in got.values()))

    def test_thrift_that_does_not_show_the_effect_fails_the_item(self):
        cases = {
            "ternary": {"table_dump HcIngress.t_ternary": dump(
                (("TERNARY", "0a000400 &&& ffffff00"), 10, [41]),                 # P4Runtime's number kept
                (("TERNARY", "0a000606 &&& ffffffff"), TOP - 30, [71]),
                (("TERNARY", "0a000600 &&& ffffff00"), TOP - 20, [72]))},
            "range": {"table_dump HcIngress.t_range": dump()},
            "optional": {"table_dump HcIngress.t_optional": None},
            "meter": {"meter_get_rates HcIngress.m_in 0": []},
            "direct_meter": {"meter_get_rates HcIngress.dm_mt3 3": [(0.25, 12500), (0.125, 12500)]},
            "clone": {"mc_dump": {0x8009: frozenset([2])}},
            "register": {"register_read HcIngress.r_mark 1": 0},
            "direct_counter": {"counter_read HcIngress.dc_k2 5": (0, 199)},
        }
        for item, over in cases.items():
            with self.subTest(item=item):
                ok, got = self.ok(read=thrift_ok(over))
                self.assertFalse(ok[item], got[item])

    def test_priority_needs_the_requested_order_in_thrifts_numbers(self):
        swapped = dump((("TERNARY", "0a000400 &&& ffffff00"), TOP - 10, [41]),
                       (("TERNARY", "0a000606 &&& ffffffff"), TOP - 20, [71]),
                       (("TERNARY", "0a000600 &&& ffffff00"), TOP - 30, [72]))
        ok, _ = self.ok(read=thrift_ok({"table_dump HcIngress.t_ternary": swapped}))
        self.assertFalse(ok["priority"])
        self.assertTrue(ok["ternary"])

    def test_the_stream_messages_must_carry_what_the_probe_sent(self):
        ok, _ = self.ok(ctrl_result(digests=[{"members": [AT.ip_int("10.0.4.4"), 40042, 40041]}]))
        self.assertFalse(ok["digest"])
        ok, _ = self.ok(ctrl_result(packet_ins=[{"ingress_port": 2, "marker": [TOK, "P2", 0]}]))
        self.assertFalse(ok["packet_in"])
        ok, _ = self.ok(ctrl_result(packet_ins=[{"ingress_port": 1, "marker": ["otherrun", "P2", 0]}]))
        self.assertFalse(ok["packet_in"])
        ok, _ = self.ok(ctrl_result(), expect=dict(EXPECT, digest=[]))
        self.assertFalse(ok["digest"])

    def test_the_packet_out_needs_the_receiving_host(self):
        for p3 in (0, None):
            ok, _ = self.ok(p3=p3)
            self.assertFalse(ok["packet_out"])

    def test_the_direct_counter_needs_traffic(self):
        res = ctrl_result()
        res["attributions"]["direct_counter"]["detail"] = {"packets": 0}
        ok, _ = self.ok(res, read=thrift_ok({"counter_read HcIngress.dc_k2 5": (0, 0)}))
        self.assertFalse(ok["direct_counter"])

    def test_each_cell_gets_its_items_attribution(self):
        cells = AT.for_cells({"ternary": {"ok": True}, "meter": {"ok": False}})
        self.assertEqual((cells["T4"], cells["MT1"], cells["MT2"], cells["R3"]),
                         ({"bmv2": True}, {"bmv2": False}, {"bmv2": False}, {"bmv2": False}))
        self.assertEqual(set(cells), set(AT.CELL_ITEMS))
        self.assertEqual(set(AT.CELL_ITEMS.values()), set(AT.ITEMS))
        for cell in AT.CELL_ITEMS:
            self.assertIn("bmv2", T.TABLE.cell(cell).red_attribution, cell)


if __name__ == "__main__":
    unittest.main()
