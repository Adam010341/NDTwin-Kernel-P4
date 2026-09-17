"""Does convert.py produce a package the fabric can actually be built from?

[Co-developed with claude code -- Adam]

    p4_proxy/venv/bin/python -m unittest discover -s tools/p4_exercise/tests \
        -t tools/p4_exercise/tests -v

Three things are being checked, and only the third is about convert.py in isolation:

  1. The concrete numbers of pod-topo (4 hosts, 4 switches, 8 links, and *which* port each
     cable lands on). A conversion that produces a plausible-but-different fabric passes every
     structural check downstream -- that is the 2026-08-21 finding this repo keeps rediscovering.
  2. That the model reads back through `p4_proxy/mininet/topo_from_json.py`, the reader the
     proxy and the fabric use. Not a copy of it.
  3. That two conversions of one exercise are byte-identical, so "the package changed" is a
     statement about the exercise and not about dict ordering.
"""
import hashlib
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(os.path.dirname(HERE))
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

from p4_exercise import common, convert  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")
BASIC = os.path.join(FIXTURES, "basic")
P4RUNTIME = os.path.join(FIXTURES, "p4runtime")

#: Where the fixtures were copied from. Only FixtureProvenance reads it, and it skips loudly
#: when it is not there -- nothing else in this file depends on the machine having tutorials.
TUTORIALS_EXERCISES = os.path.expanduser("~/tutorials/exercises")

# pod-topo, transcribed from exercises/basic/pod-topo/topology.json rather than computed, so a
# convert that changes its mind about port numbering has something to disagree with.
POD_SWITCH_LINKS = sorted([(1, 3, 3, 1), (1, 4, 4, 2), (2, 3, 4, 1), (2, 4, 3, 2)])
POD_HOST_LINKS = sorted([("h1", 1, 1), ("h2", 1, 2), ("h3", 2, 1), ("h4", 2, 2)],
                        key=lambda t: (int(t[0][1:]), t[1], t[2]))


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


class TmpMixin:
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="p4_exercise_test_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def convert_pod(self, **kw):
        out = os.path.join(self.tmp, kw.pop("out", "pkg"))
        package, model, _written = convert.convert(
            BASIC, "pod-topo/topology.json", out, **kw)
        return package, model, out


class PodTopoNumbers(TmpMixin, unittest.TestCase):
    def test_pod_topo_is_four_hosts_four_switches_eight_links(self):
        package, model, _out = self.convert_pod()
        self.assertEqual(sorted(package["switches"]), ["1", "2", "3", "4"])
        self.assertEqual(sorted(package["hosts"]), ["h1", "h2", "h3", "h4"])
        self.assertEqual(len(package["links"]), 8)
        self.assertEqual(len([n for n in model["nodes"] if n["vertex_type"] == 0]), 4)
        self.assertEqual(len([n for n in model["nodes"] if n["vertex_type"] == 1]), 4)
        # Both directions of eight cables.
        self.assertEqual(len(model["edges"]), 16)
        self.assertEqual(model["links"], [])

    def test_the_model_reads_back_through_the_proxys_reader(self):
        _package, model, _out = self.convert_pod()
        read = convert.read_back(model)
        self.assertEqual(read["switches"], [(1, "s1"), (2, "s2"), (3, "s3"), (4, "s4")])
        self.assertEqual(read["hosts"], [
            ("h1", "10.0.1.1", common.mac_to_int("08:00:00:00:01:11")),
            ("h2", "10.0.2.2", common.mac_to_int("08:00:00:00:02:22")),
            ("h3", "10.0.3.3", common.mac_to_int("08:00:00:00:03:33")),
            ("h4", "10.0.4.4", common.mac_to_int("08:00:00:00:04:44")),
        ])
        self.assertEqual(read["switch_links"], POD_SWITCH_LINKS)
        self.assertEqual(read["host_links"], POD_HOST_LINKS)

    def test_triangle_topo_reads_back_too(self):
        out = os.path.join(self.tmp, "triangle")
        package, model, _written = convert.convert(
            BASIC, "triangle-topo/topology.json", out)
        read = convert.read_back(model)
        self.assertEqual(read["switches"], [(1, "s1"), (2, "s2"), (3, "s3")])
        self.assertEqual(read["host_links"],
                         sorted([("h1", 1, 1), ("h2", 2, 1), ("h3", 3, 1)],
                                key=lambda t: (int(t[0][1:]), t[1], t[2])))
        self.assertEqual(read["switch_links"], sorted([(1, 2, 2, 2), (1, 3, 3, 2), (2, 3, 3, 3)]))
        self.assertEqual(len(package["links"]), 6)


class BothDirections(TmpMixin, unittest.TestCase):
    """The reason the model stores every edge twice."""

    def test_every_link_is_stored_in_both_directions(self):
        # 🔴 Not decoration. topo_from_json.host_links() reads a host out of whichever direction
        # carries the host's dpid as falsy (topo_from_json.py:127-133), and the kernel's own
        # loaders read the other. Emitting one direction leaves half the readers finding
        # nothing, and finding nothing is `continue`, not an error.
        _package, model, _out = self.convert_pod()
        def key(e):
            return (e["src_dpid"], e["src_interface"], tuple(e["src_ip"]),
                    e["dst_dpid"], e["dst_interface"], tuple(e["dst_ip"]))

        def mirror(e):
            return (e["dst_dpid"], e["dst_interface"], tuple(e["dst_ip"]),
                    e["src_dpid"], e["src_interface"], tuple(e["src_ip"]))

        present = {key(e) for e in model["edges"]}
        self.assertEqual(len(present), len(model["edges"]), "an edge is duplicated")
        missing = [e for e in model["edges"] if mirror(e) not in present]
        self.assertEqual(missing, [], f"{len(missing)} edge(s) have no reverse direction")

    def test_host_edges_carry_dpid_zero_on_the_host_side(self):
        # 🔴 topo_from_json.host_links() identifies an access link by a falsy dpid on one side
        # (`if s in dpids and not d` / `elif d in dpids and not s`). A host edge with a real
        # dpid at both ends is not rejected -- it is read as an inter-switch link, so the host
        # disappears and the fabric grows a cable that does not exist.
        _package, model, _out = self.convert_pod()
        for ip in ("10.0.1.1", "10.0.2.2", "10.0.3.3", "10.0.4.4"):
            touching = [e for e in model["edges"] if ip in e["src_ip"] or ip in e["dst_ip"]]
            self.assertEqual(len(touching), 2, f"{ip} should appear on exactly two edges")
            sides = sorted((e["src_dpid"] if ip in e["src_ip"] else e["dst_dpid"])
                           for e in touching)
            self.assertEqual(sides, [0, 0],
                             f"the host side of {ip}'s access link must carry dpid 0, got {sides}")


class Reproducible(TmpMixin, unittest.TestCase):
    def test_two_conversions_are_byte_identical(self):
        _p1, _m1, out1 = self.convert_pod(out="a")
        _p2, _m2, out2 = self.convert_pod(out="b")
        for rel in ("package.json", "ndtwin/topology.json"):
            self.assertEqual(sha(os.path.join(out1, rel)), sha(os.path.join(out2, rel)), rel)

    def test_copies_keep_their_exercise_relative_paths(self):
        # The package is self-contained precisely because the copies land where the interior
        # paths of a tutorials runtime json already point (see convert.py's module docstring).
        package, _model, out = self.convert_pod(p4_rel="solution/basic.p4")
        for rel in ("pod-topo/s1-runtime.json", "build/basic.p4.p4info.txtpb",
                    "build/basic.json", "solution/basic.p4", "pod-topo/topology.json"):
            self.assertTrue(os.path.isfile(os.path.join(out, rel)), rel)
        with open(os.path.join(out, "pod-topo/s1-runtime.json"), encoding="utf-8") as fh:
            entries = json.load(fh)
        self.assertTrue(os.path.isfile(os.path.join(out, entries["p4info"])))
        self.assertTrue(os.path.isfile(os.path.join(out, entries["bmv2_json"])))
        self.assertEqual(package["switches"]["1"]["entries"], "pod-topo/s1-runtime.json")
        # Byte-identical, not rewritten.
        self.assertEqual(sha(os.path.join(out, "pod-topo/s1-runtime.json")),
                         sha(os.path.join(BASIC, "pod-topo/s1-runtime.json")))


class PackageFields(TmpMixin, unittest.TestCase):
    def test_stage_one_pins_pipeline_grpc_base_and_device_id(self):
        package, _model, _out = self.convert_pod()
        self.assertEqual(package["format"], 1)
        self.assertEqual(package["control_plane"]["grpc_base"], 30050)
        self.assertEqual(package["control_plane"]["device_id"], "dpid")
        self.assertEqual(package["control_plane"]["election_id"], [0, 65535])
        self.assertEqual(package["bmv2"]["cpu_port"], 255)
        for spec in package["switches"].values():
            self.assertIsNone(spec["pipeline"])

    def test_the_mode_comes_from_whether_the_exercise_has_a_controller(self):
        package, _model, _out = self.convert_pod()
        self.assertEqual(package["control_plane"]["mode"], "ndtwin")
        out = os.path.join(self.tmp, "ext")
        ext, _m, _w = convert.convert(P4RUNTIME, "topology.json", out)
        self.assertEqual(ext["control_plane"]["mode"], "external")
        self.assertEqual(ext["source"]["controller"], "mycontroller.py")
        # p4runtime's switches carry no runtime_json at all: its controller writes the entries.
        self.assertEqual([s["entries"] for s in ext["switches"].values()], [None, None, None])

    def test_switch_nodes_carry_exactly_the_shipped_models_keys(self):
        _package, model, _out = self.convert_pod()
        switch = [n for n in model["nodes"] if n["vertex_type"] == 0][0]
        self.assertEqual(sorted(switch), [
            "brand_name", "bridge_name", "device_layer", "device_name", "dpid",
            "ecmp_groups", "ip", "mac", "nickname", "smart_plug_ip", "smart_plug_outlet",
            "vertex_type"])
        self.assertEqual(switch["brand_name"], "BMv2")
        self.assertEqual(switch["ip"], ["192.168.123.11"])
        self.assertEqual(switch["ecmp_groups"], [])
        host = [n for n in model["nodes"] if n["vertex_type"] == 1][0]
        self.assertEqual(sorted(host), [
            "brand_name", "device_layer", "device_name", "dpid", "ip", "mac", "nickname",
            "vertex_type"])
        self.assertEqual(host["dpid"], 0)
        self.assertEqual(host["ip"], ["10.0.1.1"])

    def test_the_source_block_records_where_it_came_from(self):
        package, _model, _out = self.convert_pod(p4_rel="solution/basic.p4")
        self.assertEqual(package["source"]["kind"], "p4lang-tutorials")
        self.assertEqual(package["source"]["exercise_dir"], BASIC)
        self.assertEqual(package["source"]["p4"], "solution/basic.p4")
        self.assertEqual(package["source"]["p4info"], "build/basic.p4.p4info.txtpb")
        self.assertEqual(package["source"]["bmv2_json"], "build/basic.json")


class LinkExtras(unittest.TestCase):
    """tutorials' optional link elements are [latency, bandwidth], in that order."""

    def test_latency_and_bandwidth_are_read_in_tutorials_order(self):
        # The spelling ecn and mri use: 0.5 Mbit/s with no added delay.
        links = convert.parse_links([["s1-p3", "s2-p3", "0", 0.5]])
        (_a, _b, latency, bandwidth) = links[0]
        self.assertEqual(latency, 0.0)
        self.assertEqual(bandwidth, 0.5)

    def test_bandwidth_is_megabits_per_second(self):
        links = convert.parse_links([["s1-p3", "s2-p3", "0", 0.5]])
        model = convert.build_model(
            {}, {1: {"name": "s1", "entries": None}, 2: {"name": "s2", "entries": None}}, links)
        self.assertEqual({e["link_bandwidth_bps"] for e in model["edges"]}, {500000})

    def test_a_link_with_no_extras_is_a_gigabit_and_says_nothing_about_delay(self):
        links = convert.parse_links([["h1", "s1-p1"]])
        entry = convert._package_link(*links[0])
        self.assertEqual(entry["bandwidth_bps"], 1000000000)
        self.assertNotIn("delay_ms", entry)

    def test_a_declared_zero_latency_is_the_same_as_no_latency(self):
        # utils/run_exercise.py:212-232 defaults an absent third element to '0ms' and then
        # passes it to addLink exactly as it passes a declared '0'. Two packages describing the
        # same shaping must not differ.
        declared = convert._package_link(*convert.parse_links([["s1-p3", "s2-p3", "0", 0.5]])[0])
        self.assertNotIn("delay_ms", declared)

    def test_a_real_latency_is_recorded(self):
        entry = convert._package_link(*convert.parse_links([["s1-p3", "s2-p3", "0.05ms", 0.5]])[0])
        self.assertEqual(entry["delay_ms"], 0.05)

    def test_a_latency_string_with_a_unit_is_understood(self):
        self.assertEqual(convert._latency_ms("0.05ms"), 0.05)
        self.assertEqual(convert._latency_ms(2), 2.0)


class ShapedLinks(unittest.TestCase):
    """ecn and mri -- the only two of the thirteen exercises that declare link extras.

    Run through `plan()` on the real topology.json rather than on a hand-made one: the extras
    are the part of the tutorials format most easily read backwards, and a hand-made fixture
    would encode whichever reading the author already had.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="p4_exercise_shaped_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def materialise(self, name):
        """A temp exercise directory: the fixture's real files plus empty build/ placeholders.

        🔴 WHAT THE PLACEHOLDERS DO AND DO NOT PROVE. `plan()` checks that the p4info and bmv2
        json a runtime file names EXIST; it never opens them (only preflight.py does). ecn and
        mri ship unbuilt -- there is no build/ in ~/tutorials/exercises/{ecn,mri} -- and
        compiling them into the fixtures would commit p4c output with an absolute source path
        baked into it, for a test that does not read a byte of it. So the placeholders are
        empty, and this test proves nothing whatsoever about ecn's or mri's p4info or entries:
        preflight.py on such a package would fail at "p4info parses", correctly.
        """
        src = os.path.join(FIXTURES, name)
        dst = os.path.join(self.tmp, name)
        shutil.copytree(src, dst)
        os.makedirs(os.path.join(dst, "build"))
        for rel in (f"build/{name}.p4.p4info.txtpb", f"build/{name}.json"):
            open(os.path.join(dst, rel), "w", encoding="utf-8").close()
        return dst

    def test_the_half_megabit_link_of_ecn_and_mri_comes_out_as_500000_bps(self):
        for name in ("ecn", "mri"):
            with self.subTest(exercise=name):
                package, model, _copies = convert.plan(self.materialise(name), "topology.json")
                shaped = [l for l in package["links"]
                          if l["a"] == ["s1", 3] and l["b"] == ["s2", 3]]
                self.assertEqual(len(shaped), 1, package["links"])
                # ["s1-p3", "s2-p3", "0", 0.5] -- element 3 is the LATENCY and element 4 the
                # BANDWIDTH in Mbit/s. Reading them the other way round would put a 500 Mbit/s
                # link where the exercise wants a bottleneck.
                self.assertEqual(shaped[0]["bandwidth_bps"], 500000)
                self.assertNotIn("delay_ms", shaped[0])

                others = [l for l in package["links"] if l is not shaped[0]]
                self.assertEqual({l["bandwidth_bps"] for l in others}, {1000000000})
                self.assertFalse([l for l in others if "delay_ms" in l])

                # Both directions of the shaped cable carry the same bandwidth in the model.
                edges = [e for e in model["edges"]
                         if {(e["src_dpid"], e["src_interface"]),
                             (e["dst_dpid"], e["dst_interface"])} == {(1, 3), (2, 3)}]
                self.assertEqual(len(edges), 2)
                self.assertEqual({e["link_bandwidth_bps"] for e in edges}, {500000})

    def test_ecn_reads_back_with_its_five_hosts(self):
        # h1/h11/h2/h22/h3 on /31s -- the naming rule holds (h11 is on 10.0.1.11), which is why
        # these convert at all.
        _package, model, _copies = convert.plan(self.materialise("ecn"), "topology.json")
        read = convert.read_back(model)
        self.assertEqual([n for n, _ip, _mac in read["hosts"]],
                         ["h1", "h2", "h3", "h11", "h22"])
        self.assertEqual(read["switches"], [(1, "s1"), (2, "s2"), (3, "s3")])
        self.assertEqual(len(read["switch_links"]), 3)
        self.assertEqual(len(read["host_links"]), 5)


class FixtureProvenance(unittest.TestCase):
    """The fixtures claim to be byte copies of ~/tutorials. This is that claim, checked."""

    def test_every_fixture_is_still_byte_identical_to_its_tutorials_original(self):
        if not os.path.isdir(TUTORIALS_EXERCISES):
            # Explicit, and never a silent pass: this machine simply cannot answer the question.
            self.skipTest(
                f"no p4lang-tutorials checkout at {TUTORIALS_EXERCISES}, so the fixtures cannot "
                f"be compared with the files they were copied from. This is NOT evidence that "
                f"they match.")
        mismatched, orphaned, checked = [], [], 0
        for root, dirs, files in os.walk(FIXTURES):
            dirs[:] = [d for d in dirs if d != "__pycache__"]
            for filename in sorted(files):
                rel = os.path.relpath(os.path.join(root, filename), FIXTURES)
                if rel == "README":
                    continue          # this directory's own note, not a copy of anything
                original = os.path.join(TUTORIALS_EXERCISES, rel)
                if not os.path.isfile(original):
                    orphaned.append(rel)
                    continue
                checked += 1
                if sha(os.path.join(root, filename)) != sha(original):
                    mismatched.append(rel)
        self.assertEqual(orphaned, [],
                         "fixture file(s) with no counterpart in ~/tutorials -- either the "
                         "exercise moved, or something generated was committed as if copied")
        self.assertEqual(mismatched, [],
                         "fixture(s) that have drifted from ~/tutorials; the tests describe a "
                         "file shape the upstream exercise no longer has")
        self.assertGreaterEqual(checked, 25, "the fixture tree shrank -- this check got easier")


class Refusals(TmpMixin, unittest.TestCase):
    """Each refusal exists because the silent version of it is invisible downstream."""

    def _topology(self, **overrides):
        with open(os.path.join(BASIC, "pod-topo", "topology.json"), encoding="utf-8") as fh:
            topo = json.load(fh)
        topo.update(overrides)
        return topo

    def test_a_host_whose_name_does_not_match_its_address_is_refused(self):
        hosts = self._topology()["hosts"]
        hosts["h1"]["ip"] = "10.0.1.7/24"
        with self.assertRaises(convert.ConversionError) as cm:
            convert.parse_hosts(hosts)
        self.assertIn("h7", str(cm.exception))

    def test_a_host_address_without_a_prefix_length_is_refused(self):
        hosts = self._topology()["hosts"]
        hosts["h1"]["ip"] = "10.0.1.1"
        with self.assertRaises(convert.ConversionError) as cm:
            convert.parse_hosts(hosts)
        self.assertIn("prefix", str(cm.exception))

    def test_a_switch_not_named_sn_is_refused(self):
        with self.assertRaises(ValueError):
            convert.parse_switches({"leaf1": {}})

    def test_a_cli_configured_switch_is_refused_rather_than_silently_unconfigured(self):
        with self.assertRaises(convert.ConversionError) as cm:
            convert.parse_switches({"s1": {"cli_input": "s1-commands.txt"}})
        self.assertIn("cli_input", str(cm.exception))

    def test_a_host_attached_twice_is_refused(self):
        links = convert.parse_links([["h1", "s1-p1"], ["h1", "s2-p1"]])
        hosts = {"h1": {"ip": "10.0.1.1", "prefix_len": 24, "mac": "08:00:00:00:01:11",
                        "commands": []}}
        switches = {1: {"name": "s1", "entries": None}, 2: {"name": "s2", "entries": None}}
        with self.assertRaises(convert.ConversionError) as cm:
            convert._check_link_endpoints(hosts, switches, links)
        self.assertIn("more than once", str(cm.exception))

    def test_a_bad_link_endpoint_is_refused(self):
        with self.assertRaises(convert.ConversionError):
            convert.parse_endpoint("s1-eth3")
        with self.assertRaises(convert.ConversionError):
            convert.parse_endpoint("router7")

    def test_a_missing_topology_is_refused(self):
        with self.assertRaises(convert.ConversionError):
            convert.plan(BASIC, "no-such-topo/topology.json")


if __name__ == "__main__":
    unittest.main(verbosity=2)
