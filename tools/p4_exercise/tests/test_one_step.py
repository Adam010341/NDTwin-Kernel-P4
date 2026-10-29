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
MAKEFILE = "BMV2_SWITCH_EXE = simple_switch_grpc\n{topo}{extra}\ninclude ../../utils/Makefile\n"
TOPO_POD = "TOPO = pod-topo/topology.json\n"

BASIC_ROLE = {"table": "MyIngress.ipv4_lpm", "match_field": "hdr.ipv4.dstAddr",
              "action": "MyIngress.ipv4_forward",
              "params": {"dst_mac": "dstAddr", "port": "port"}}


def makefile(topo=TOPO_POD, extra=""):
    return MAKEFILE.format(topo=topo, extra=extra)


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
        """exercises/basic: two topologies (pod-topo, triangle-topo), TOPO pod-topo, basic.p4."""
        kw.setdefault("top_p4", {"solution/basic.p4": "basic.p4"})
        kw.setdefault("makefile", makefile())
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

    def generated(self):
        d = os.path.join(self.run_dir, "packages", "generated")
        return sorted(os.listdir(d)) if os.path.isdir(d) else []


# --- the topology ------------------------------------------------------------------------------

class TopologyChoiceTest(ExerciseCase):
    def test_the_makefiles_topo_is_the_default(self):
        result = self.prepare(self.basic())
        self.assertEqual((result["topology"], result["topology_how"]),
                         ("pod-topo/topology.json", "the Makefile's TOPO"))
        self.assertEqual(self.package_json(result)["source"]["topology_json"],
                         "pod-topo/topology.json")

    def test_the_only_topology_is_used(self):
        result = self.prepare(self.basic_one_topology(makefile=makefile(topo="")))
        self.assertEqual((result["topology"], result["topology_how"]),
                         ("pod-topo/topology.json", "the only one"))

    def test_a_top_level_topology_is_a_candidate_too(self):
        result = self.prepare(self.exercise("calc"))
        self.assertEqual(result["topology"], "topology.json")

    def test_several_and_no_topo_are_refused_listed_and_the_flag_named(self):
        text = self.refused(self.basic(makefile=makefile(topo="")), "has 2 topologies")
        self.assertIn("pod-topo/topology.json, triangle-topo/topology.json", text)
        self.assertIn("sets no TOPO", text)
        self.assertIn("--topology pod-topo/topology.json", text)

    def test_a_topo_that_is_not_there_is_refused(self):
        self.refused(self.basic(makefile=makefile(topo="TOPO = gone/topology.json\n")),
                     "TOPO is gone/topology.json")

    def test_a_topo_outside_the_exercise_is_refused(self):
        # [Co-developed with claude code -- Adam] convert.py copies the topology into the package
        # at its own relative path, so an absolute one or one through `..` would be copied out.
        outside = os.path.join(self.tmp, "elsewhere-topology.json")
        shutil.copyfile(os.path.join(FIXTURES, "basic", "pod-topo", "topology.json"), outside)
        for n, topo in enumerate((outside, "../elsewhere-topology.json")):
            with self.subTest(topo=topo):
                d = self.basic(makefile=makefile(topo=f"TOPO = {topo}\n"), name=f"basic{n}")
                self.refused(d, "is outside")

    def test_a_topology_flag_outside_the_exercise_is_refused(self):
        outside = os.path.join(self.tmp, "elsewhere-topology.json")
        shutil.copyfile(os.path.join(FIXTURES, "basic", "pod-topo", "topology.json"), outside)
        d = self.basic()
        for topo in (outside, "../elsewhere-topology.json", "pod-topo/../../elsewhere-topology.json"):
            with self.subTest(topo=topo):
                self.refused(d, "--topology is", topology=topo)
        self.assertEqual(self.generated(), [])

    def test_a_computed_topo_is_said_to_be_unread_not_unset(self):
        d = self.basic(makefile=makefile(topo="TOPO = $(EXAMPLE)/topology.json\n"))
        text = self.refused(d, "has 2 topologies")
        self.assertIn("computes TOPO ($(EXAMPLE)/topology.json), which this tool does not evaluate",
                      text)
        self.assertNotIn("sets no TOPO", text)

    def test_the_flag_picks_one_over_the_makefile(self):
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
        for sub in ("build", "logs", "pcaps"):
            os.makedirs(os.path.join(d, sub), exist_ok=True)
            with open(os.path.join(d, sub, "topology.json"), "w", encoding="utf-8") as fh:
                fh.write("{}")
        self.assertEqual(one_step.topology_candidates(d), ["pod-topo/topology.json"])
        self.assertIn("ndtwin", one_step.NOT_TOPOLOGY_DIRS)

    def test_a_package_directory_is_refused_as_an_exercise(self):
        d = self.basic_one_topology()
        with open(os.path.join(d, "package.json"), "w", encoding="utf-8") as fh:
            fh.write("{}")
        self.refused(d, "already is an app package")

    def test_a_package_that_lost_its_manifest_is_refused_not_converted(self):
        first = self.prepare(self.basic_one_topology())
        os.remove(os.path.join(first["dest"], "package.json"))
        before = tree(first["dest"])
        self.refused(first["dest"], "lost its manifest")
        self.assertEqual(tree(first["dest"]), before)
        self.assertEqual(self.generated(), [os.path.basename(first["dest"])])


# --- the program -------------------------------------------------------------------------------

class ProgramChoiceTest(ExerciseCase):
    def firewall(self, default_prog=True):
        # exercises/firewall: basic.p4 and firewall.p4 at the top, DEFAULT_PROG = basic.p4, and
        # pod-topo's s1 names build/firewall.json as its own `program`.
        extra = "DEFAULT_PROG = basic.p4\n" if default_prog else ""
        d = self.exercise("firewall", makefile=makefile(extra=extra))
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
        text = self.refused(self.firewall(default_prog=False), "2 .p4 programs")
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
        d = self.basic_one_topology(makefile=makefile(extra="DEFAULT_PROG = gone.p4\n"))
        self.refused(d, "DEFAULT_PROG is gone.p4")


# --- built or not ------------------------------------------------------------------------------

class UnbuiltTest(ExerciseCase):
    def test_an_unbuilt_exercise_is_refused_with_make_build(self):
        d = self.basic(drop=("triangle-topo", "build"))
        self.refused(d, f"Build the exercise first (`make build` in {d})")

    def test_and_nothing_is_written(self):
        d = self.basic(drop=("triangle-topo", "build"))
        self.refused(d, "make build")
        self.assertFalse(os.path.exists(one_step.generated_dir(self.run_dir, d)))
        self.assertEqual(self.generated(), [])
        self.assertEqual(os.listdir(one_step.staging_root(self.run_dir)), [],
                         "a staging directory was left behind")


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

    def test_a_symlinked_path_is_the_same_exercise(self):
        d = self.basic_one_topology()
        link = os.path.join(self.tmp, "link-to-basic")
        os.symlink(d, link)
        first = self.prepare(d)
        again = self.prepare(link)
        self.assertEqual(again["dest"], first["dest"])
        self.assertEqual(again["state"], "unchanged")
        self.assertEqual(self.package_json(again)["source"]["exercise_dir"], d)

    def test_the_package_format_is_still_one(self):
        self.assertEqual(self.package_json(self.prepare(self.basic_one_topology()))["format"], 1)

    def test_staging_is_outside_packages(self):
        # ndt serve admits `up --app` packages from under .test_run/packages, so a half-written
        # conversion must never be there.
        self.assertFalse(one_step.staging_root(self.run_dir).startswith(
            os.path.join(self.run_dir, "packages") + os.sep))


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
        self.assertEqual(self.generated(), [os.path.basename(again["dest"])])
        self.assertEqual(os.listdir(one_step.staging_root(self.run_dir)), [], "staging left behind")

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

    def test_staging_on_another_filesystem_is_refused_before_converting(self):
        real = one_step._same_filesystem
        one_step._same_filesystem = lambda a, b: False
        self.addCleanup(setattr, one_step, "_same_filesystem", real)
        self.refused(self.basic_one_topology(), "are on two filesystems")
        self.assertEqual(self.generated(), [])
        self.assertEqual(os.listdir(one_step.staging_root(self.run_dir)), [])

    def test_a_failed_move_is_a_refusal_and_the_old_package_stays(self):
        import errno
        from unittest import mock

        d = self.basic_one_topology()
        first = self.prepare(d)
        before = tree(first["dest"])
        real_rename = os.rename

        def rename(src, dst):
            if os.path.realpath(dst) == os.path.realpath(first["dest"]) and ".new-" in src:
                raise OSError(errno.EXDEV, "Invalid cross-device link")
            return real_rename(src, dst)

        with mock.patch("os.rename", side_effect=rename):
            text = self.refused(d, "Invalid cross-device link", owner="ndtwin")
        self.assertIn("one filesystem", text)
        self.assertEqual(tree(first["dest"]), before, "the old package was not put back")
        self.assertEqual(os.listdir(one_step.staging_root(self.run_dir)), [])

    def test_staging_a_killed_run_left_behind_is_removed(self):
        d = self.basic_one_topology()
        dest = one_step.generated_dir(self.run_dir, d)
        root = one_step.staging_root(self.run_dir)
        mine = [os.path.join(root, os.path.basename(dest) + s) for s in (".new-abc123", ".old-xyz")]
        other = os.path.join(root, "calc-12345678.new-abc123")
        for p in mine + [other]:
            os.makedirs(os.path.join(p, "pkg"))
        self.prepare(d)
        self.assertEqual(os.listdir(root), [os.path.basename(other)],
                         "this exercise's leftovers stay, or another exercise's go")


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
    def two_tables(self):
        d = self.basic_one_topology()
        add_second_route_table(os.path.join(d, "build", "basic.p4.p4info.txtpb"))
        return d

    def test_one_candidate_is_filled_with_owner_package(self):
        result = self.prepare(self.basic_one_topology())
        self.assertEqual(result["role_source"], "auto")
        self.assertEqual(self.package_json(result)["roles"],
                         {"ipv4_route": dict(BASIC_ROLE, owner="package")})

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

    def test_owner_ndtwin_says_how_many_entries_it_stripped(self):
        result = self.prepare(self.basic_one_topology(), owner="ndtwin")
        self.assertEqual(result["removed"], {"1": 4, "2": 4, "3": 4, "4": 4})
        lines = "\n".join(one_step.report_lines(result))
        self.assertIn("stripped      : 16 match entries of MyIngress.ipv4_lpm taken out of the "
                      "runtime files (s1: 4, s2: 4, s3: 4, s4: 4)", lines)

    def test_owner_package_strips_nothing_and_says_nothing(self):
        lines = "\n".join(one_step.report_lines(self.prepare(self.basic_one_topology())))
        self.assertNotIn("stripped", lines)

    def test_an_explicit_role_wins_over_the_auto_filled_one(self):
        spec = ("table=MyIngress.ipv4_lpm_backup,match_field=hdr.ipv4.dstAddr,"
                "action=MyIngress.ipv4_forward,dst_mac=dstAddr,port=port")
        result = self.prepare(self.two_tables(), role_text=spec)
        self.assertEqual(result["role_source"], "flag")
        self.assertEqual(result["auto"], {}, "the heuristic ran beside an explicit role")
        self.assertEqual(self.package_json(result)["roles"]["ipv4_route"],
                         dict(BASIC_ROLE, table="MyIngress.ipv4_lpm_backup", owner="package"))

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
        result = self.prepare(self.two_tables())
        self.assertNotIn("roles", self.package_json(result))
        self.assertEqual(len(result["auto"]["candidates"]), 2)
        lines = "\n".join(one_step.report_lines(result))
        self.assertIn("2 candidates qualify", lines)
        self.assertIn("MyIngress.ipv4_lpm hdr.ipv4.dstAddr", lines)
        self.assertIn("MyIngress.ipv4_lpm_backup hdr.ipv4.dstAddr", lines)
        self.assertIn("WARNING       : the twin will show no flow paths", lines)

    def test_several_candidates_are_printed_as_the_ndt_flag_that_picks_each(self):
        d = self.two_tables()
        lines = one_step.report_lines(self.prepare(d))
        flags = [l.split("--role-ipv4-route ", 1)[1] for l in lines
                 if l.lstrip().startswith("--role-ipv4-route ")]
        self.assertEqual(len(flags), 2, "\n".join(lines))
        self.assertNotIn("package.json", "\n".join(lines))
        for flag, table in zip(flags, ("MyIngress.ipv4_lpm", "MyIngress.ipv4_lpm_backup")):
            with self.subTest(table=table):
                result = self.prepare(d, role_text=flag)
                self.assertEqual(self.package_json(result)["roles"]["ipv4_route"]["table"], table)

    def test_table_owner_ndtwin_with_several_names_each_as_a_flag_line(self):
        # [Co-developed with claude code -- Adam]
        d = self.two_tables()
        with self.assertRaises(convert.ConversionError) as caught:
            self.prepare(d, owner="ndtwin")
        text = str(caught.exception)
        for table in ("MyIngress.ipv4_lpm,", "MyIngress.ipv4_lpm_backup,"):
            self.assertIn("--role-ipv4-route owner=ndtwin,table=" + table, text)
        flag = text.split("--role-ipv4-route ", 2)[1].split(";", 1)[0].strip()
        result = self.prepare(d, role_text=flag)
        self.assertEqual(self.package_json(result)["roles"]["ipv4_route"]["owner"], "ndtwin")

    def test_table_owner_ndtwin_on_an_external_plane_says_so(self):
        text = self.refused(self.exercise("p4runtime"), "the control plane is external",
                            owner="ndtwin")
        self.assertNotIn("--role-ipv4-route", text)

    def test_table_owner_ndtwin_with_no_single_candidate_is_refused(self):
        self.refused(self.two_tables(), "--table-owner ndtwin asks NDTwin to write", owner="ndtwin")
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
        self.assertIn("auto-filled from the p4info -- its one (table, action) candidate", lines)
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


# --- pre-flight's own suggestion, outside the one-step path -----------------------------------

class SuggestionTest(ExerciseCase):
    """The `roles suggestion` row: owner package, none on an external plane, none on request."""

    def rows(self, exercise, **kw):
        result = self.prepare(exercise, no_roles=True)
        report = preflight.run(result["dest"], compile_p4=False, **kw)
        return [r for r in report.rows if r[1] == "roles suggestion"]

    def test_the_suggestion_offers_owner_package(self):
        rows = self.rows(self.basic_one_topology())
        self.assertEqual(len(rows), 1)
        block = rows[0][2].split('"roles": ', 1)[1].rsplit(" (owner package", 1)[0]
        self.assertEqual(json.loads(block), {"ipv4_route": dict(BASIC_ROLE, owner="package")})

    def test_it_can_be_switched_off(self):
        self.assertEqual(self.rows(self.basic_one_topology(), suggest_roles=False), [])

    def test_none_is_offered_on_an_external_control_plane(self):
        self.assertEqual(self.rows(self.exercise("p4runtime")), [])

    def test_the_command_line_switch_reaches_it(self):
        result = self.prepare(self.basic_one_topology(), no_roles=True)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            preflight.main([result["dest"], "--no-compile", "--no-role-suggestion"])
        self.assertNotIn("roles suggestion", out.getvalue())


class OwnerLeftOutOfARoleTest(ExerciseCase):
    """A package.json role without `owner` is owner package, in the loader and the resolver."""

    def test_the_loader_gives_it_owner_package(self):
        app_package = common.import_app_package()
        roles = app_package.parse_roles({"ipv4_route": BASIC_ROLE}, "package.json")
        self.assertEqual(roles.ipv4_route.owner, "package")
        self.assertEqual(roles.ipv4_route.as_manifest(), dict(BASIC_ROLE, owner="package"))

    def test_the_resolver_gives_it_owner_package(self):
        rb = common.import_route_binding()
        p4info = preflight.P4InfoIndex.parse(
            os.path.join(FIXTURES, "basic", "build", "basic.p4.p4info.txtpb")).p4info
        self.assertEqual(rb.resolve(dict(BASIC_ROLE), p4info).owner, "package")

    def test_a_package_whose_role_names_no_owner_passes_pre_flight(self):
        result = self.prepare(self.basic_one_topology(), no_roles=True)
        path = os.path.join(result["dest"], "package.json")
        doc = common.load_json(path)
        doc["roles"] = {"ipv4_route": BASIC_ROLE}
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(common.dumps(doc))
        report = preflight.run(result["dest"], compile_p4=False)
        self.assertEqual(report.failures, [], report.render())
        detail = {label: d for _s, label, d in report.rows}["roles.ipv4_route resolves"]
        self.assertIn("owner package", detail)


# --- the command line --------------------------------------------------------------------------

class CommandLineTest(ExerciseCase):
    def newline_link(self, target):
        """A path without a line break that resolves to one with a line break in it."""
        real = os.path.join(self.tmp, "two\nlines")
        shutil.copytree(target, real)
        link = os.path.join(self.tmp, "plain-link")
        os.symlink(real, link)
        return link

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
        rc, out = self.main(self.basic(makefile=makefile(topo="")), "--run-dir", self.run_dir,
                            "--emit-path", emit)
        self.assertEqual(rc, 5, out)
        self.assertIn("REFUSED:", out)
        self.assertFalse(os.path.exists(emit))

    def test_usage_errors_are_2(self):
        d = self.basic_one_topology()
        for argv in ((d, "--no-roles", "--table-owner", "ndtwin"),
                     (d, "--no-roles", "--role-ipv4-route", "table=t"),
                     (d, "--topology", ""),
                     (d, "--table-owner", "kernel"),
                     (d, "--owner", "ndtwin"),
                     (d, "--no-such-flag"),
                     (d, "--role-ipv4-route", "table=t"),
                     (d, "--role-ipv4-route", "owner=ndtwin," + convert.role_flag_text(
                         dict(BASIC_ROLE, owner="ndtwin")), "--table-owner", "package"),
                     (d + "\nx",),
                     (self.newline_link(d),)):
            with self.subTest(argv=argv[1:]):
                rc, out = self.main(*argv, "--run-dir", self.run_dir)
                self.assertEqual(rc, 2, out)
        self.assertFalse(os.path.exists(os.path.join(self.run_dir, "packages")))

    def test_the_in_use_flag_reaches_the_replace_guard(self):
        d = self.basic_one_topology()
        first = self.prepare(d)
        rc, out = self.main(d, "--run-dir", self.run_dir, "--table-owner", "ndtwin",
                            "--in-use", first["dest"])
        self.assertEqual(rc, 5, out)
        self.assertIn("ndt down", out)

    def test_every_flag_is_forwarded_to_prepare(self):
        seen = {}

        def fake(exercise_dir, run_dir, **kw):
            seen.update(kw, exercise_dir=exercise_dir, run_dir=run_dir)
            raise convert.ConversionError("stop here")

        real = one_step.prepare
        one_step.prepare = fake
        self.addCleanup(setattr, one_step, "prepare", real)
        spec = convert.role_flag_text(dict(BASIC_ROLE, owner="package"))
        self.main("/ex", "--run-dir", "/run", "--topology", "t/topology.json", "--p4", "x.p4",
                  "--role-ipv4-route", spec, "--table-owner", "ndtwin", "--in-use", "/knob/pkg")
        self.assertEqual(seen, {"exercise_dir": "/ex", "run_dir": "/run",
                                "topology": "t/topology.json", "p4": "x.p4", "role_text": spec,
                                "owner": "ndtwin", "no_roles": False, "in_use": "/knob/pkg"})
        seen.clear()
        self.main("/ex", "--run-dir", "/run", "--no-roles")
        self.assertEqual((seen["no_roles"], seen["role_text"], seen["owner"], seen["in_use"]),
                         (True, None, None, None))


if __name__ == "__main__":
    unittest.main(verbosity=2)
