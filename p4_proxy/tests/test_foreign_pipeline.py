"""
The table-entry writer and `startup()` against a pipeline NDTwin did not compile.

[Co-developed with claude code -- Adam]

🔴 WHY THIS IS ITS OWN FILE, AND NOT MORE CASES IN test_p4_client_writes.py / test_startup.py.
Those two are run by `tests/shell/mutate_app_package.sh` inside a mutant tree that is a copy of
`p4_proxy/` alone -- `setting/` is linked in because a test needed it, and nothing else is. The
suites here read `tools/p4_exercise/tests/fixtures/**` and RUN `tools/p4_exercise/convert.py`,
so inside that tree they cannot run at all, and a test that cannot run turns a gate's baseline
red for a reason that has nothing to do with what the gate is about. That gate belongs to
ticket A (TICKET-P2 0.7), so the fix is on this side: the tests that need the wider repo live in
a file A's gate does not run, and `tests/shell/mutate_table_entry.sh` -- which links `tools/` in
for exactly this -- does run it.

🔴 WHAT IS ACTUALLY NEW HERE. Every other test of this feature uses a p4info written by the test
(a subset of `ndtwin_switch.p4info.txt`, or a synthetic descriptor for a match type no pipeline
in this repo declares) and a `Package` object built by hand, whose artefact paths name files
that do not exist. So until ticket A merged, the writer had never once been pointed at a program
NDTwin did not compile -- and the entire feature exists for programs NDTwin did not compile.
P2-B round 1 shipped with that gap and said so (P2-B-SUMMARY section 7-2). These are the tests
that close it: A's compiled `basic`, `firewall` and `calc` p4infos, A's converter, A's runtime
files, and `startup()` driven over the package that comes out of them.
"""

from __future__ import annotations

import json
import os
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    from google.protobuf import text_format
    from p4.v1 import p4runtime_pb2
    from p4.config.v1 import p4info_pb2

    import proxy_agent.main as main
    from proxy_agent import p4_client as p4_client_module
    from proxy_agent.p4_client import P4RuntimeClient
    from proxy_agent.rule_install_times import RuleInstallTimes

    HAVE_P4RUNTIME = True
except ImportError:  # pragma: no cover -- depends on the interpreter L1 picks
    HAVE_P4RUNTIME = False

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "mininet"))
import app_package  # noqa: E402

# Imported for the fakes and the driver, which are this feature's, not this file's.
from tests.test_startup import FakeSflow, FakeKernel, FakeTopo, run_startup  # noqa: E402


class RecordingWriteStub:
    """Captures WriteRequests instead of sending them. No switch, no channel, no deadline."""

    def __init__(self):
        self.requests = []

    def Write(self, request, timeout=None):
        self.requests.append(request)


def a_client():
    """A P4RuntimeClient with no channel and no p4info yet -- the caller supplies the p4info."""
    client = P4RuntimeClient.__new__(P4RuntimeClient)
    client.device_id = 1
    client.grpc_addr = "127.0.0.1:50051"
    client.stub = RecordingWriteStub()
    client.packet_in_callback = None
    client.sample_callback = None
    client.is_running = False
    client.stream_recv_thread = None
    client.stream_out_q = queue.Queue()
    client.rule_install_times = RuleInstallTimes()
    client._last_table_read = None
    client.election_id = (0, 1)
    client.arbitration = True
    return client


# --- against the p4info of a program this proxy did not write --------------------------------

#: The exercises ticket A brought into the tree, compiled. Version-controlled, so a missing one
#: is a failure and not a skip: `tools/p4_exercise/tests/fixtures/README` says why they are
#: committed, and a suite that quietly skipped when they went missing would be a suite nobody
#: noticed had stopped checking the only foreign pipelines this repo has.
FIXTURES = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), "tools", "p4_exercise", "tests", "fixtures")


def a_real_p4info(relative_path):
    """One of A's compiled fixture p4infos, parsed the way P4RuntimeClient parses one."""
    path = os.path.join(FIXTURES, relative_path)
    if not os.path.isfile(path):
        raise AssertionError(
            f"{path} is missing. It is committed (see fixtures/README); this suite is the only "
            f"place the table-entry writer meets a pipeline NDTwin did not compile.")
    p4info = p4info_pb2.P4Info()
    text_format.Merge(open(path).read(), p4info)
    return p4info


@unittest.skipUnless(HAVE_P4RUNTIME, "P4Runtime protobufs not available in this interpreter")
class AgainstARealTutorialsPipelineTest(unittest.TestCase):
    """
    `build_table_entry` against the p4info of `basic`, `firewall` and `calc`.

    [Co-developed with claude code -- Adam]
    🔴 EVERYTHING ABOVE THIS CLASS USES A P4INFO WRITTEN IN THIS FILE. That fixture is the
    subset of `ndtwin_switch.p4info.txt` these methods look things up in -- which means the
    writer had never once been pointed at a program NDTwin did not compile, and the entire
    feature exists for programs NDTwin did not compile. Round 1 shipped with that gap and said
    so (P2-B-SUMMARY section 7-2); ticket A merging is what made it closable, because the
    compiled fixtures came with it.

    🔴 AND `basic.p4` IS WHY THE SKIPS ELSEWHERE ARE NOT PARANOIA. It declares
    `MyIngress.ipv4_lpm` matching `hdr.ipv4.dstAddr` LPM/32 with action
    `MyIngress.ipv4_forward(dstAddr, port)` -- character for character the table, field, action
    and parameter names `ndtwin_switch.p4` uses. So `install_initial_routes` against a switch
    running `basic` does not fail: it SUCCEEDS, writing this proxy's shortest paths into the
    exercise's own table. `test_the_names_basic_p4_shares_with_ndtwin_switch` pins that
    collision, because it is the premise of TICKET-P2 round 2's `install_routes=False`.
    """

    def client_for(self, relative_path):
        client = a_client()
        client.p4info = a_real_p4info(relative_path)
        return client

    def test_the_names_basic_p4_shares_with_ndtwin_switch(self):
        theirs = self.client_for("firewall/build/basic.p4.p4info.txtpb")
        ours = a_client()
        ours.p4info = self.real_ndtwin_p4info()
        table = theirs._table_by_name("MyIngress.ipv4_lpm")
        self.assertEqual([f.name for f in table.match_fields], ["hdr.ipv4.dstAddr"])
        self.assertEqual(theirs._match_type_name(table.match_fields[0]), "LPM")
        self.assertEqual([p.name for p in
                          theirs._action_by_name("MyIngress.ipv4_forward").params],
                         ["dstAddr", "port"])

        # 🔴 MEASURED, 2026-09-18, and it is worse than "the names match". p4c derives an id
        # from the FULLY QUALIFIED NAME, so the two programs agree on the numbers too:
        #
        #     MyIngress.ipv4_lpm       37375156 in both
        #     MyIngress.ipv4_forward   28792405 in both
        #     dstAddr / port           param ids 1 and 2, bit<48> and bit<9>, in both
        #
        # A WriteRequest `install_initial_routes` builds for our pipeline is therefore byte for
        # byte a request `basic.p4` accepts. There is nothing at the switch that could refuse
        # it, and nothing in P4Runtime that compares programs. That is the whole argument for
        # TICKET-P2 round 2's `install_routes=False`: the guard cannot be "the write will fail",
        # because it will not.
        self.assertEqual(table.preamble.id,
                         ours._table_by_name("MyIngress.ipv4_lpm").preamble.id)
        theirs_action = theirs._action_by_name("MyIngress.ipv4_forward")
        ours_action = ours._action_by_name("MyIngress.ipv4_forward")
        self.assertEqual(theirs_action.preamble.id, ours_action.preamble.id)
        self.assertEqual([(p.id, p.name, p.bitwidth) for p in theirs_action.params],
                         [(p.id, p.name, p.bitwidth) for p in ours_action.params])

    def real_ndtwin_p4info(self):
        """NDTwin's own compiled p4info -- the build artefact, not this file's subset of it."""
        path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                            "p4_src", "build", "ndtwin_switch.p4info.txt")
        if not os.path.isfile(path):  # pragma: no cover -- depends on l0_build_check.sh p4
            self.skipTest(f"{path} is not built")
        p4info = p4info_pb2.P4Info()
        text_format.Merge(open(path).read(), p4info)
        return p4info

    def test_a_ternary_table_in_a_real_compiled_p4info_answers_unsupported(self):
        # 🔴 The only REAL ternary table this repository has, and until round 3 nothing pointed
        # the writer at it. The 501 path was covered twice over -- by the in-file p4info subset
        # and by a synthetic descriptor -- and both of those are declarations this suite wrote
        # itself. `MyIngress.flow_5tuple` is p4c's output from ndtwin_switch.p4: six TERNARY
        # fields it decided the numbering of. None of the tutorials fixtures has one (asserted
        # in test_no_fixture_pipeline_declares_a_ternary_range_or_optional_match), so this is
        # where "a real compiler said TERNARY and the writer refused" gets checked.
        client = a_client()
        client.p4info = self.real_ndtwin_p4info()
        table = client._table_by_name("MyIngress.flow_5tuple")
        self.assertEqual({client._match_type_name(f) for f in table.match_fields}, {"TERNARY"})

        with self.assertRaises(p4_client_module.TableEntryUnsupported) as caught:
            client.write_table_entry({
                "table": "MyIngress.flow_5tuple",
                "match": {"hdr.ipv4.dstAddr": ["10.0.1.1", "255.255.255.255"]},
                "action_name": "MyIngress.ipv4_forward",
                "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 1}})
        self.assertIn("TERNARY", str(caught.exception))
        self.assertIn("flow_5tuple", str(caught.exception))
        self.assertEqual(client.stub.requests, [],
                         "a refusal this proxy makes itself must not reach the switch")

    def test_the_same_real_p4info_still_builds_its_exact_and_lpm_tables(self):
        # The negative half: the refusal above is about the match type, not about this being a
        # real p4info or this table being unfamiliar.
        client = a_client()
        client.p4info = self.real_ndtwin_p4info()
        entry, kinds = client.build_table_entry({
            "table": "MyIngress.l2_forward",
            "match": {"hdr.ethernet.dstAddr": "08:00:00:00:01:11"},
            "action_name": "MyIngress.forward_l2",
            "action_params": {"port": 1}})
        self.assertEqual(kinds, {"hdr.ethernet.dstAddr": "EXACT"})
        self.assertEqual(entry.match[0].exact.value, bytes.fromhex("080000000111"))

    def test_an_entry_from_pod_topos_own_runtime_file_builds_against_basic(self):
        # Verbatim from tools/p4_exercise/tests/fixtures/firewall/pod-topo/s2-runtime.json.
        client = self.client_for("firewall/build/basic.p4.p4info.txtpb")
        entry, kinds = client.build_table_entry({
            "table": "MyIngress.ipv4_lpm",
            "match": {"hdr.ipv4.dstAddr": ["10.0.1.1", 32]},
            "action_name": "MyIngress.ipv4_forward",
            "action_params": {"dstAddr": "08:00:00:00:01:11", "port": 2}})
        self.assertEqual(kinds, {"hdr.ipv4.dstAddr": "LPM"})
        self.assertEqual(entry.table_id,
                         client._table_by_name("MyIngress.ipv4_lpm").preamble.id)
        self.assertEqual(entry.match[0].lpm.value, socket.inet_aton("10.0.1.1"))
        self.assertEqual(entry.match[0].lpm.prefix_len, 32)
        params = {p.param_id: p.value for p in entry.action.action.params}
        self.assertEqual(sorted(params.values()),
                         sorted([bytes.fromhex("080000000111"), b"\x00\x02"]))

    def test_firewalls_two_field_exact_table_builds(self):
        # `MyIngress.check_ports` matches two bit<9> fields EXACTLY, and its action parameter is
        # a bit<1>. Nothing in ndtwin_switch.p4 has either shape.
        client = self.client_for("firewall/build/firewall.p4.p4info.txtpb")
        entry, kinds = client.build_table_entry({
            "table": "MyIngress.check_ports",
            "match": {"standard_metadata.ingress_port": 1,
                      "standard_metadata.egress_spec": 3},
            "action_name": "MyIngress.set_direction",
            "action_params": {"dir": 0}})
        self.assertEqual(kinds, {"standard_metadata.ingress_port": "EXACT",
                                 "standard_metadata.egress_spec": "EXACT"})
        self.assertEqual({m.field_id: m.exact.value for m in entry.match},
                         {1: b"\x00\x01", 2: b"\x00\x03"})
        self.assertEqual(entry.action.action.params[0].value, b"\x00",
                         "dir is bit<1>, so one byte")

    def test_calcs_single_switch_table_builds(self):
        # calc is the one-switch exercise: one table, an EXACT bit<8> on a header field of the
        # exercise's own custom header, and actions that take no parameters at all.
        client = self.client_for("calc/build/calc.p4.p4info.txtpb")
        entry, kinds = client.build_table_entry({
            "table": "MyIngress.calculate",
            "match": {"hdr.p4calc.op": 0x2b},
            "action_name": "MyIngress.operation_add",
            "action_params": {}})
        self.assertEqual(kinds, {"hdr.p4calc.op": "EXACT"})
        self.assertEqual(entry.match[0].exact.value, b"\x2b")
        self.assertTrue(entry.action.HasField("action"))
        self.assertEqual(len(entry.action.action.params), 0)

    def test_a_table_basic_does_not_have_is_a_keyerror_even_though_ndtwin_has_it(self):
        # 🔴 The other half of the name collision. `MyIngress.flow_5tuple` is real -- in OUR
        # pipeline. Resolving it against a client running `basic` must fail, or the proxy would
        # write NDTwin's own five-tuple rules into whatever table happened to answer.
        client = self.client_for("firewall/build/basic.p4.p4info.txtpb")
        with self.assertRaises(KeyError):
            client._table_by_name("MyIngress.flow_5tuple")

    def test_no_fixture_pipeline_declares_a_ternary_range_or_optional_match(self):
        # 🔴 Recorded as a FACT about the fixtures, not as a gap. TICKET-P2 2.3 promises 501 for
        # those three, and the synthetic descriptors in a_p4info() are how they are exercised --
        # this asserts why a synthetic one was necessary rather than leaving a reader to wonder
        # whether a real pipeline was avoided.
        for relative_path in ("firewall/build/basic.p4.p4info.txtpb",
                              "firewall/build/firewall.p4.p4info.txtpb",
                              "calc/build/calc.p4.p4info.txtpb"):
            client = self.client_for(relative_path)
            for table in client.p4info.tables:
                for field in table.match_fields:
                    self.assertIn(client._match_type_name(field), ("EXACT", "LPM"),
                                  f"{relative_path} {table.preamble.name}.{field.name} is no "
                                  f"longer exact or lpm -- this suite can now use it directly "
                                  f"instead of a synthetic descriptor")



class ARealPackageWithRealPipelinesTest(unittest.TestCase):
    """
    `startup()` against a package `tools/p4_exercise/convert.py` actually produced.

    [Co-developed with claude code -- Adam]
    Every other foreign-pipeline test in this file hands `startup` a `Package` object written by
    hand, whose artefact paths name files that do not exist. That is the right shape for
    asserting a branch, and it cannot see any of this:

      * that `app_package.load` accepts what the converter writes (two different people's idea
        of the manifest);
      * that `pipeline_for` resolves to files that are really there, so `p4info_sha256` is a
        digest and not `null`;
      * that the WRITER survives contact with a p4info NDTwin did not compile -- the tables,
        the bit widths and the `default_action` entry of a tutorials runtime file;
      * that `recorded` and `applied` agree when both are counted from the real file.

    🔴 The `default_action` row is the one that would have failed. Every `sX-runtime.json` here
    carries one (`MyIngress.ipv4_lpm` -> `drop`), and a target refuses an INSERT of a default
    entry -- so without the MODIFY substitution (`write_table_entry`) every switch in this
    package would have reported `applied: n-1, failed: 1` and nobody would have known why.

    The package is BUILT here rather than committed: it is a build product, the converter is
    the thing that produces it in production (`ndt up p4 --app` runs exactly this), and a
    committed copy would be a second answer to "what does convert.py write".
    """

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="ndtwin_real_package_")
        repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        exercise = os.path.join(repo, "tools", "p4_exercise", "tests", "fixtures", "firewall")
        if not os.path.isdir(exercise):
            raise AssertionError(
                f"{exercise} is missing -- it is committed (fixtures/README says why), and it "
                f"is the only foreign pipeline this suite can reach.")
        cls.package_dir = os.path.join(cls.tmp, "firewall")
        subprocess.run(
            [sys.executable, os.path.join(repo, "tools", "p4_exercise", "convert.py"), exercise,
             "--topology", "pod-topo/topology.json", "--p4", "basic.p4",
             "--out", cls.package_dir],
            check=True, capture_output=True, text=True)
        cls.package = app_package.load(cls.package_dir)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self):
        self.saved = (dict(main._pipelines), dict(main._table_entries), dict(main._api_writes))
        self.addCleanup(self.restore)

    def restore(self):
        for live, saved in ((main._pipelines, self.saved[0]),
                            (main._table_entries, self.saved[1]),
                            (main._api_writes, self.saved[2])):
            live.clear()
            live.update(saved)

    def real_client(self, dpid):
        """The client PRODUCTION builds for this switch, with a recording stub in place of gRPC.

        [Co-developed with claude code -- Adam]
        🔴 `main.build_p4_client`, not a hand-assembled object. An earlier version of this
        method set `p4info`, `election_id` and `arbitration` itself, and a test that then
        asserted "every write carries the package's election id" was only asserting that `_bid`
        uses whatever the test put there -- it could not have seen `build_p4_client` dropping
        `package.election_id` on the floor. Going through the factory means the p4info path, the
        election id and the write permission all come from the package by the same route the
        proxy uses, and the only thing this test supplies is the absence of a switch.

        grpc connects lazily, so constructing this touches nothing; the channel is closed on
        cleanup because it owns a subchannel pool entry (see P4RuntimeClient.__init__).
        """
        client = main.build_p4_client(dpid, package=self.package)
        self.addCleanup(client.channel.close)
        client.stub = RecordingWriteStub()
        client.events = []
        return client

    def run_it(self):
        clients = {spec.dpid: self.real_client(spec.dpid) for spec in self.package.switches}
        for client in clients.values():
            client.set_forwarding_pipeline_config = (
                lambda c=client: c.events.append("pipeline"))
            client.write_clone_session = lambda c=client: c.events.append("clone") or True
        summary, parts = run_startup(clients, package=self.package)
        return summary, parts, clients

    def test_the_converter_writes_a_package_the_proxy_loads(self):
        self.assertEqual(sorted(s.dpid for s in self.package.switches), [1, 2, 3, 4])
        self.assertEqual(self.package.entries_recorded(),
                         {"1": 13, "2": 5, "3": 5, "4": 5})

    def test_every_switch_is_reported_as_running_somebody_elses_program(self):
        summary, _, _ = self.run_it()
        for dpid in ("1", "2", "3", "4"):
            self.assertFalse(summary["pipelines"][dpid]["ndtwin"],
                             f"switch {dpid} is running the package's own pipeline")

    def test_the_fingerprint_is_a_digest_because_the_file_is_really_there(self):
        summary, _, _ = self.run_it()
        # s1 runs firewall.p4 and s2-s4 run basic.p4, so the shas must differ across that line
        # and agree within it. A `null` here would mean pipeline_for named a file nobody has.
        shas = {d: summary["pipelines"][d]["p4info_sha256"] for d in ("1", "2", "3", "4")}
        for dpid, sha in shas.items():
            self.assertIsNotNone(sha, f"switch {dpid} has no p4info to fingerprint")
            self.assertEqual(len(sha), 16)
        self.assertEqual(shas["2"], shas["3"])
        self.assertEqual(shas["2"], shas["4"])
        self.assertNotEqual(shas["1"], shas["2"],
                            "s1 runs firewall.p4 and s2 runs basic.p4; one sha for both would "
                            "mean the per-switch pipeline was not followed")

    def test_every_declared_entry_goes_onto_its_switch(self):
        summary, _, clients = self.run_it()
        for dpid, count in (("1", 13), ("2", 5), ("3", 5), ("4", 5)):
            self.assertEqual(summary["table_entries"][dpid]["recorded"], count)
            self.assertEqual(summary["table_entries"][dpid]["applied"], count,
                             f"switch {dpid}: {summary['entry_errors'].get(dpid)}")
            self.assertEqual(summary["table_entries"][dpid]["failed"], 0)
        self.assertEqual(summary["entry_errors"], {})
        self.assertEqual(sum(len(c.stub.requests) for c in clients.values()), 28)

    def test_the_default_action_row_every_runtime_file_carries_is_a_modify(self):
        # 🔴 The row that would have failed without the op substitution, in a real file.
        _, _, clients = self.run_it()
        defaults = [u for c in clients.values() for r in c.stub.requests for u in r.updates
                    if u.entity.table_entry.is_default_action]
        self.assertEqual(len(defaults), 4, "one default action per switch, from the fixture")
        for update in defaults:
            self.assertEqual(update.type, p4runtime_pb2.Update.MODIFY)
            self.assertEqual(len(update.entity.table_entry.match), 0)

    def test_firewalls_own_table_is_written_only_to_the_switch_that_runs_firewall(self):
        # s1's runtime file names `MyIngress.check_ports`, which exists in firewall.p4 and in no
        # other program here. Written to s2 it would be a 404 -- which is exactly what makes
        # per-switch pipelines load-bearing rather than cosmetic.
        _, _, clients = self.run_it()
        s1_tables = {u.entity.table_entry.table_id for r in clients[1].stub.requests
                     for u in r.updates}
        check_ports = clients[1]._table_by_name("MyIngress.check_ports").preamble.id
        self.assertIn(check_ports, s1_tables)
        for dpid in (2, 3, 4):
            with self.assertRaises(KeyError):
                clients[dpid]._table_by_name("MyIngress.check_ports")

    def test_the_fabric_names_the_three_steps_it_lost_and_each_switch_names_its_two(self):
        summary, parts, clients = self.run_it()
        self.assertEqual(summary["control_plane"]["skipped"],
                         sorted([main.SKIP_LLDP, main.SKIP_WATCHDOG, main.SKIP_ROUTES]))
        for dpid in ("1", "2", "3", "4"):
            self.assertEqual(summary["pipelines"][dpid]["skipped"],
                             sorted([main.SKIP_CLONE, main.SKIP_TELEMETRY]))
        self.assertEqual(summary["telemetry"], [])
        self.assertEqual(parts["sflow"].registered, {})
        for client in clients.values():
            self.assertNotIn("clone", client.events)

    def test_the_client_the_factory_built_took_its_identity_from_the_package(self):
        # 🔴 The assertion that makes the next one mean anything. The election id, the artefact
        # path and the write permission are read off the CLIENT here, and the client came out of
        # `main.build_p4_client` -- so the next test's "every request carries (0, 65535)" is a
        # statement about what the package produced, not about what this file assigned.
        _, _, clients = self.run_it()
        for dpid, client in clients.items():
            self.assertEqual(client.election_id, (0, 65535),
                             "convert.py writes control_plane.election_id [0, 65535] and the "
                             "factory is what carries it to the client")
            self.assertTrue(client.arbitration)
            self.assertEqual(client.grpc_addr, f"localhost:{30050 + dpid}")
            self.assertTrue(client.json_path.startswith(self.package_dir),
                            f"switch {dpid} was built from {client.json_path}, which is not in "
                            f"the package -- the per-switch pipeline was not followed")

    def test_every_entry_that_went_out_carries_the_packages_election_id(self):
        # The package bids (0, 65535); a rule written under the baseline (0, 1) would be
        # accepted by a switch that had been taken over by anything bidding the same.
        _, _, clients = self.run_it()
        for client in clients.values():
            for request in client.stub.requests:
                self.assertEqual((request.election_id.high, request.election_id.low),
                                 (0, 65535))

if __name__ == "__main__":
    unittest.main(verbosity=2)

# [Co-developed with claude code -- Adam]
