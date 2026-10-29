"""`ndt up p4 --app <exercise dir>`'s conversion step, offline: one_step.py and convert --auto-role.

[Co-developed with claude code -- Adam]

    p4_proxy/venv/bin/python tools/p4_exercise/tests/test_one_step.py -v

Every exercise here is a COPY of tools/p4_exercise/tests/fixtures made in a temp directory and
given what a p4lang-tutorials exercise directory has beside its sources (a Makefile, the program
at its top). Nothing reads or writes a tutorials checkout. The conversion is the real convert.py,
the heuristic the real preflight.route_role_candidates, and the check that the written role is
accepted the real pre-flight (route_binding.resolve); only `ndt` is absent, and
tests/shell/test_ndt_app_package.sh section 22 covers `ndt`'s half.
"""
import contextlib
import hashlib
import io
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

from p4_exercise import common, convert, one_step, preflight  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")

#: A tutorials exercise Makefile, as exercises/basic and exercises/firewall write theirs.
MAKEFILE = "BMV2_SWITCH_EXE = simple_switch_grpc\nTOPO = pod-topo/topology.json\n{extra}\ninclude ../../utils/Makefile\n"


def tree(root):
    out = {}
    for d, _subdirs, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            with open(p, "rb") as fh:
                out[os.path.relpath(p, root)] = hashlib.sha256(fh.read()).hexdigest()
    return out


class ExerciseCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="p4_one_step_test_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.run_dir = os.path.join(self.tmp, "repo", ".test_run")

    def exercise(self, fixture, name=None, top_p4=None, makefile=None, drop=()):
        """A copy of fixtures/<fixture> laid out like a tutorials exercise."""
        d = os.path.join(self.tmp, "exercises", name or fixture)
        shutil.copytree(os.path.join(FIXTURES, fixture), d)
        for src, dest in (top_p4 or {}).items():
            shutil.copyfile(os.path.join(d, src), os.path.join(d, dest))
        if makefile is not None:
            with open(os.path.join(d, "Makefile"), "w", encoding="utf-8") as fh:
                fh.write(makefile)
        for rel in drop:
            target = os.path.join(d, rel)
            (shutil.rmtree if os.path.isdir(target) else os.remove)(target)
        return d

    def basic(self, **kw):
        """exercises/basic: two topologies (pod-topo, triangle-topo), basic.p4 at the top."""
        kw.setdefault("top_p4", {"solution/basic.p4": "basic.p4"})
        kw.setdefault("makefile", MAKEFILE.format(extra=""))
        return self.exercise("basic", **kw)

    def basic_one_topology(self, **kw):
        return self.basic(drop=("triangle-topo",), **kw)

    def prepare(self, exercise, **kw):
        return one_step.prepare(exercise, self.run_dir, **kw)

    def package_json(self, result):
        return common.load_json(os.path.join(result["dest"], "package.json"))

    def refused(self, exercise, needle, **kw):
        with self.assertRaises(convert.ConversionError) as caught:
            self.prepare(exercise, **kw)
        self.assertIn(needle, str(caught.exception))
        return str(caught.exception)


# --- the topology ------------------------------------------------------------------------------

class TopologyChoiceTest(ExerciseCase):
    def test_the_only_topology_is_used(self):
        result = self.prepare(self.basic_one_topology())
        self.assertEqual((result["topology"], result["topology_how"]),
                         ("pod-topo/topology.json", "the only one"))
        self.assertEqual(self.package_json(result)["source"]["topology_json"],
                         "pod-topo/topology.json")

    def test_a_top_level_topology_is_a_candidate_too(self):
        result = self.prepare(self.exercise("calc"))
        self.assertEqual(result["topology"], "topology.json")

    def test_several_are_refused_listed_and_the_flag_named(self):
        text = self.refused(self.basic(), "has 2 topologies")
        self.assertIn("pod-topo/topology.json (the Makefile's TOPO)", text)
        self.assertIn("triangle-topo/topology.json", text)
        self.assertIn("--topology pod-topo/topology.json", text)

    def test_the_flag_picks_one(self):
        result = self.prepare(self.basic(), topology="triangle-topo/topology.json")
        self.assertEqual((result["topology"], result["topology_how"]),
                         ("triangle-topo/topology.json", "--topology"))
        self.assertEqual(len(self.package_json(result)["switches"]), 3)

    def test_a_directory_with_no_topology_is_neither(self):
        empty = os.path.join(self.tmp, "empty")
        os.makedirs(empty)
        self.refused(empty, "neither an app package")

    def test_build_logs_pcaps_and_a_package_model_are_not_candidates(self):
        d = self.basic_one_topology()
        for sub in ("build", "logs", "pcaps", "ndtwin"):
            os.makedirs(os.path.join(d, sub), exist_ok=True)
            with open(os.path.join(d, sub, "topology.json"), "w", encoding="utf-8") as fh:
                fh.write("{}")
        self.assertEqual(one_step.topology_candidates(d), ["pod-topo/topology.json"])

    def test_a_package_directory_is_refused_as_an_exercise(self):
        d = self.basic_one_topology()
        with open(os.path.join(d, "package.json"), "w", encoding="utf-8") as fh:
            fh.write("{}")
        self.refused(d, "already is an app package")


# --- the program -------------------------------------------------------------------------------

class ProgramChoiceTest(ExerciseCase):
    def firewall(self, makefile=True):
        # exercises/firewall: basic.p4 and firewall.p4 at the top, DEFAULT_PROG = basic.p4, and
        # pod-topo's s1 names build/firewall.json as its own `program`.
        extra = "DEFAULT_PROG = basic.p4" if makefile else ""
        d = self.exercise("firewall", makefile=MAKEFILE.format(extra=extra))
        shutil.copyfile(os.path.join(d, "basic.p4"), os.path.join(d, "firewall.p4"))
        return d

    def test_the_makefiles_default_prog_is_the_program(self):
        result = self.prepare(self.firewall())
        self.assertEqual((result["p4"], result["p4_how"]),
                         ("basic.p4", "the Makefile's DEFAULT_PROG"))
        switches = self.package_json(result)["switches"]
        self.assertEqual(switches["1"]["pipeline"]["bmv2_json"], "build/firewall.json")
        self.assertEqual(switches["2"]["pipeline"]["bmv2_json"], "build/basic.json")

    def test_several_programs_and_no_default_prog_are_refused_naming_the_flag(self):
        text = self.refused(self.firewall(makefile=False), "2 .p4 programs")
        self.assertIn("--p4", text)
        self.assertIn("basic.p4, firewall.p4", text)

    def test_the_one_program_at_the_top(self):
        result = self.prepare(self.basic_one_topology())
        self.assertEqual((result["p4"], result["p4_how"]), ("basic.p4", "the only .p4 at the top"))

    def test_no_program_at_the_top_is_refused_naming_the_flag(self):
        d = self.exercise("basic", drop=("triangle-topo",))
        self.refused(d, "Name it with --p4")

    def test_the_flag_picks_the_program(self):
        d = self.exercise("basic", drop=("triangle-topo",))
        result = self.prepare(d, p4="solution/basic.p4")
        self.assertEqual((result["p4"], result["p4_how"]), ("solution/basic.p4", "--p4"))

    def test_a_default_prog_that_is_not_there_is_refused(self):
        d = self.basic_one_topology(makefile=MAKEFILE.format(extra="DEFAULT_PROG = gone.p4"))
        self.refused(d, "DEFAULT_PROG is gone.p4")


# --- built or not ------------------------------------------------------------------------------

class UnbuiltTest(ExerciseCase):
    def test_an_unbuilt_exercise_is_refused_with_the_make_command(self):
        d = self.basic(drop=("triangle-topo", "build"))
        self.refused(d, f"Build the exercise first (`make` in {d})")

    def test_and_nothing_is_written(self):
        d = self.basic(drop=("triangle-topo", "build"))
        self.refused(d, "make")
        self.assertFalse(os.path.exists(one_step.generated_dir(self.run_dir, d)))
        generated = os.path.join(self.run_dir, "packages", "generated")
        self.assertEqual(os.listdir(generated), [], "a staging directory was left behind")


# --- where it goes, and a re-run ---------------------------------------------------------------

class LocationTest(ExerciseCase):
    def test_it_goes_under_the_run_directory(self):
        d = self.basic_one_topology()
        result = self.prepare(d)
        self.assertEqual(os.path.dirname(result["dest"]),
                         os.path.join(self.run_dir, "packages", "generated"))
        self.assertTrue(os.path.basename(result["dest"]).startswith("basic-"))
        self.assertTrue(os.path.isfile(os.path.join(result["dest"], "package.json")))

    def test_the_exercise_is_never_written(self):
        d = self.basic_one_topology()
        before = tree(d)
        self.prepare(d)
        self.prepare(d, owner="ndtwin")                    # a replace, which rewrites runtime files
        self.assertEqual(tree(d), before)

    def test_two_exercises_with_one_name_get_two_packages(self):
        a = self.basic_one_topology()
        b = os.path.join(self.tmp, "elsewhere", "basic")
        shutil.copytree(a, b)
        self.assertNotEqual(self.prepare(a)["dest"], self.prepare(b)["dest"])

    def test_the_package_format_is_still_one(self):
        self.assertEqual(self.package_json(self.prepare(self.basic_one_topology()))["format"], 1)


class RerunTest(ExerciseCase):
    def test_the_same_result_keeps_the_old_package_untouched(self):
        d = self.basic_one_topology()
        first = self.prepare(d)
        stamp = os.stat(os.path.join(first["dest"], "package.json")).st_mtime_ns
        again = self.prepare(d)
        self.assertEqual(again["state"], "unchanged")
        self.assertEqual(os.stat(os.path.join(again["dest"], "package.json")).st_mtime_ns, stamp)

    def test_a_different_result_replaces_it_whole(self):
        d = self.basic_one_topology()
        first = self.prepare(d)
        stale = os.path.join(first["dest"], "left-over.txt")
        with open(stale, "w", encoding="utf-8") as fh:
            fh.write("from an earlier conversion\n")
        again = self.prepare(d)
        self.assertEqual(again["state"], "replaced")
        self.assertFalse(os.path.exists(stale), "a file of the old package survived the replace")
        self.assertEqual(tree(again["dest"]), tree(first["dest"]))
        siblings = sorted(os.listdir(os.path.dirname(again["dest"])))
        self.assertEqual(siblings, [os.path.basename(again["dest"])], "staging left behind")

    def test_a_package_a_fabric_still_runs_is_not_replaced(self):
        d = self.basic_one_topology()
        first = self.prepare(d)
        before = tree(first["dest"])
        self.refused(d, "ndt down", owner="ndtwin", in_use=first["dest"])
        self.assertEqual(tree(first["dest"]), before)

    def test_but_it_is_reused_when_nothing_changed(self):
        d = self.basic_one_topology()
        first = self.prepare(d)
        self.assertEqual(self.prepare(d, in_use=first["dest"])["state"], "unchanged")


# --- the route role ----------------------------------------------------------------------------

def add_second_route_table(p4info_path):
    """A copy of ipv4_lpm under another name, so the program has TWO route-shaped tables."""
    from google.protobuf import text_format

    index = preflight.P4InfoIndex.parse(p4info_path)
    pb = index.p4info
    original = index.table("MyIngress.ipv4_lpm")
    twin = pb.tables.add()
    twin.CopyFrom(original)
    twin.preamble.id = max(t.preamble.id for t in pb.tables) + 1
    twin.preamble.name = "MyIngress.ipv4_lpm_backup"
    twin.preamble.alias = "ipv4_lpm_backup"
    with open(p4info_path, "w", encoding="utf-8") as fh:
        fh.write(text_format.MessageToString(pb))


class RoleTest(ExerciseCase):
    BASIC_ROLE = {"table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr",
                  "action": "MyIngress.ipv4_forward",
                  "params": {"dst_mac": "dstAddr", "port": "port"}}

    def test_one_candidate_is_filled_with_owner_package(self):
        result = self.prepare(self.basic_one_topology())
        self.assertEqual(result["role_source"], "auto")
        self.assertEqual(self.package_json(result)["roles"],
                         {"ipv4_route": dict(self.BASIC_ROLE, owner="package")})

    def test_owner_package_keeps_the_authors_entries(self):
        d = self.basic_one_topology()
        result = self.prepare(d)
        for n in (1, 2, 3, 4):
            rel = f"pod-topo/s{n}-runtime.json"
            self.assertEqual(tree(result["dest"])[rel], tree(d)[rel])

    def test_owner_ndtwin_uses_the_detected_table_and_takes_its_entries_out(self):
        result = self.prepare(self.basic_one_topology(), owner="ndtwin")
        self.assertEqual(self.package_json(result)["roles"]["ipv4_route"]["owner"], "ndtwin")
        entries = common.load_json(os.path.join(result["dest"], "pod-topo/s1-runtime.json"))
        self.assertEqual([e.get("default_action") for e in entries["table_entries"]], [True])

    def test_an_explicit_role_wins_over_the_auto_filled_one(self):
        d = self.basic_one_topology()
        add_second_route_table(os.path.join(d, "build", "basic.p4.p4info.txtpb"))
        spec = ("table=MyIngress.ipv4_lpm_backup,match_field=hdr.ipv4.dstAddr,"
                "action=MyIngress.ipv4_forward,dst_mac=dstAddr,port=port")
        result = self.prepare(d, role_text=spec)
        self.assertEqual(result["role_source"], "flag")
        self.assertEqual(result["auto"], {}, "the heuristic ran beside an explicit role")
        self.assertEqual(self.package_json(result)["roles"]["ipv4_route"],
                         dict(self.BASIC_ROLE, table="MyIngress.ipv4_lpm_backup", owner="package"))

    def test_no_roles_declares_none(self):
        result = self.prepare(self.basic_one_topology(), no_roles=True)
        self.assertNotIn("roles", self.package_json(result))
        self.assertEqual(result["role_source"], "none")

    def test_zero_candidates_no_roles_and_a_warning(self):
        result = self.prepare(self.exercise("calc"))
        self.assertNotIn("roles", self.package_json(result))
        self.assertEqual(result["auto"]["candidates"], [])
        lines = "\n".join(one_step.report_lines(result))
        self.assertIn("no table of the program is shaped like a destination route", lines)
        self.assertIn("WARNING       : the twin will show no flow paths", lines)

    def test_several_candidates_no_roles_a_warning_naming_each(self):
        d = self.basic_one_topology()
        add_second_route_table(os.path.join(d, "build", "basic.p4.p4info.txtpb"))
        result = self.prepare(d)
        self.assertNotIn("roles", self.package_json(result))
        self.assertEqual(len(result["auto"]["candidates"]), 2)
        lines = "\n".join(one_step.report_lines(result))
        self.assertIn("2 candidates qualify", lines)
        self.assertIn("MyIngress.ipv4_lpm hdr.ipv4.dstAddr", lines)
        self.assertIn("MyIngress.ipv4_lpm_backup hdr.ipv4.dstAddr", lines)
        self.assertIn("WARNING       : the twin will show no flow paths", lines)

    def test_owner_ndtwin_with_no_single_candidate_is_refused(self):
        d = self.basic_one_topology()
        add_second_route_table(os.path.join(d, "build", "basic.p4.p4info.txtpb"))
        self.refused(d, "--owner ndtwin asks NDTwin to write", owner="ndtwin")
        self.refused(self.exercise("calc"), "Name it with --role-ipv4-route", owner="ndtwin")

    def test_an_external_control_plane_gets_none_and_says_why(self):
        result = self.prepare(self.exercise("p4runtime"))
        self.assertNotIn("roles", self.package_json(result))
        lines = "\n".join(one_step.report_lines(result))
        self.assertIn("the control plane is external", lines)
        self.assertNotIn("WARNING", lines)

    def test_the_auto_filled_role_passes_pre_flights_route_binding_check(self):
        result = self.prepare(self.basic_one_topology())
        report = preflight.run(result["dest"], compile_p4=False)
        self.assertEqual(report.failures, [], report.render())
        rows = {label: (status, detail) for status, label, detail in report.rows}
        self.assertEqual(rows["roles.ipv4_route resolves"][0], preflight.PASS)
        self.assertIn("owner package", rows["roles.ipv4_route resolves"][1])

    def test_the_choice_is_printed(self):
        lines = "\n".join(one_step.report_lines(self.prepare(self.basic_one_topology())))
        self.assertIn("auto-filled from the p4info", lines)
        self.assertIn("MyIngress.ipv4_lpm hdr.ipv4.dstAddr -> MyIngress.ipv4_forward(dstAddr, port)",
                      lines)
        self.assertIn("override with --role-ipv4-route, or --no-roles", lines)


class CandidatesTest(unittest.TestCase):
    """preflight.route_role_candidates is the heuristic; _suggest_route_role is its first answer."""

    def p4infos(self, path, dpids=(1, 2)):
        return {str(d): preflight.P4InfoIndex.parse(path).p4info for d in dpids}

    def test_every_candidate_is_returned_and_the_suggestion_is_the_first(self):
        tmp = tempfile.mkdtemp(prefix="p4_one_step_test_")
        self.addCleanup(shutil.rmtree, tmp, True)
        path = os.path.join(tmp, "basic.p4.p4info.txtpb")
        shutil.copyfile(os.path.join(FIXTURES, "basic", "build", "basic.p4.p4info.txtpb"), path)
        add_second_route_table(path)
        rb = common.import_route_binding()
        found = preflight.route_role_candidates(rb, self.p4infos(path), None)
        self.assertEqual([c["table"] for c in found],
                         ["MyIngress.ipv4_lpm", "MyIngress.ipv4_lpm_backup"])
        self.assertEqual(preflight._suggest_route_role(rb, self.p4infos(path), None), found[0])

    def test_a_candidate_must_fit_every_switch(self):
        rb = common.import_route_binding()
        basic = os.path.join(FIXTURES, "basic", "build", "basic.p4.p4info.txtpb")
        calc = os.path.join(FIXTURES, "calc", "build", "calc.p4.p4info.txtpb")
        p4infos = {"1": preflight.P4InfoIndex.parse(basic).p4info,
                   "2": preflight.P4InfoIndex.parse(calc).p4info}
        self.assertEqual(preflight.route_role_candidates(rb, p4infos, None), [])


# --- the command line --------------------------------------------------------------------------

class CommandLineTest(ExerciseCase):
    def main(self, *argv):
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = one_step.main(list(argv))
        return rc, out.getvalue() + err.getvalue()

    def test_a_ready_package_is_0_and_its_path_is_emitted(self):
        d = self.basic_one_topology()
        emit = os.path.join(self.tmp, "path")
        rc, out = self.main(d, "--run-dir", self.run_dir, "--emit-path", emit)
        self.assertEqual(rc, 0, out)
        with open(emit, encoding="utf-8") as fh:
            path = fh.read().strip()
        self.assertEqual(path, one_step.generated_dir(self.run_dir, d))
        self.assertIn(f"package       : {path}   (created)", out)

    def test_a_refusal_is_5_and_emits_nothing(self):
        emit = os.path.join(self.tmp, "path")
        rc, out = self.main(self.basic(), "--run-dir", self.run_dir, "--emit-path", emit)
        self.assertEqual(rc, 5, out)
        self.assertIn("REFUSED:", out)
        self.assertFalse(os.path.exists(emit))

    def test_usage_errors_are_2(self):
        d = self.basic_one_topology()
        for argv in ((d, "--no-roles", "--owner", "ndtwin"),
                     (d, "--no-roles", "--role-ipv4-route", "table=t"),
                     (d, "--topology", ""),
                     (d, "--owner", "kernel"),
                     (d, "--no-such-flag")):
            with self.subTest(argv=argv[1:]):
                rc, out = self.main(*argv, "--run-dir", self.run_dir)
                self.assertEqual(rc, 2, out)
        self.assertFalse(os.path.exists(os.path.join(self.run_dir, "packages")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
