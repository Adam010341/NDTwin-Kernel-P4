"""
`p4_proxy/p4_src/ndtwin_telemetry.p4` -- does it compile into somebody else's program, and does
the p4info that comes out carry the five names the proxy looks up? TICKET-P3 2.6.

[Co-developed with claude code -- Adam]

🔴 THE CLAIM UNDER TEST IS NOT "THE FILE PARSES". It is that an exercise author can keep their
own forwarding program AND get a live twin -- so the fixture is the tutorials `basic` SOLUTION
with the include and nothing else changed, and the assertions are: it compiles; its p4info
declares `packet_in` with the five field names; and the forwarding half of the program is
byte-for-byte the solution's. Drop the last one and this file would keep passing for a fixture
that had quietly become a different program.

🔴 AND THE HEADER MUST MATCH ndtwin_switch.p4's. ndtwin_switch.p4 is NOT changed by this ticket
(TICKET-P3 0.7 forbids touching it or its build products), so the include is a second copy of
the same header -- and a second copy that drifts is worse than no copy: the proxy would decode
one program's samples with the other's field widths. The two are compared field by field, from
the SOURCE of one and the compiled p4info of the other, because that is the pair that can drift
without anybody noticing.

p4c-bm2-ss is optional on a machine, so the compile test skips loudly when it is absent -- a
skip is never evidence that it compiles. The committed build products under
fixtures/basic_telemetry/build/ are what the rest of the tree uses either way.

    p4_proxy/venv/bin/python -m unittest discover -s tools/p4_exercise/tests \
        -t tools/p4_exercise/tests -v
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(os.path.dirname(HERE))
REPO = os.path.dirname(TOOLS)
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

FIXTURES = os.path.join(HERE, "fixtures")
TELEMETRY_FIXTURE = os.path.join(FIXTURES, "basic_telemetry")
BASIC_SOLUTION = os.path.join(FIXTURES, "basic", "solution", "basic.p4")
P4_SRC = os.path.join(REPO, "p4_proxy", "p4_src")
INCLUDE = os.path.join(P4_SRC, "ndtwin_telemetry.p4")
NDTWIN_SWITCH = os.path.join(P4_SRC, "ndtwin_switch.p4")
P4C = "/usr/local/bin/p4c-bm2-ss"

#: The five the proxy resolves by name, plus the pad that makes the header a whole number of
#: bytes. Widths included: a field that keeps its name and loses four bits is decoded without
#: complaint and reports a port number that is missing its top bits.
PACKET_IN_FIELDS = (("reason", 8), ("ingress_port", 9), ("egress_port", 9),
                    ("frame_length", 16), ("sampling_rate", 16), ("_pad", 6))
PACKET_OUT_FIELDS = (("egress_port", 9), ("_pad", 7))


def p4info_header_fields(text, header):
    """[(name, bitwidth)] of one controller_packet_metadata block in a p4info text file."""
    for match in re.finditer(r"controller_packet_metadata \{(.*?)\n\}", text, re.S):
        block = match.group(1)
        if f'name: "{header}"' not in block:
            continue
        return [(name, int(width)) for _mid, name, width in
                re.findall(r"id: (\d+)\s+name: \"([^\"]+)\"\s+bitwidth: (\d+)", block)]
    return []


def p4info_header_ids(text, header):
    """{name: metadata id} for one controller_packet_metadata block."""
    for match in re.finditer(r"controller_packet_metadata \{(.*?)\n\}", text, re.S):
        block = match.group(1)
        if f'name: "{header}"' not in block:
            continue
        return {name: int(mid) for mid, name, _w in
                re.findall(r"id: (\d+)\s+name: \"([^\"]+)\"\s+bitwidth: (\d+)", block)}
    return {}


def p4_header_fields(source, header_name):
    """[(name, bitwidth)] of a `header <name> { ... }` block in P4 source."""
    match = re.search(r"header\s+" + re.escape(header_name) + r"\s*\{(.*?)\}", source, re.S)
    if not match:
        return []
    out = []
    for line in match.group(1).splitlines():
        field = re.match(r"\s*bit<(\d+)>\s+(\w+)\s*;", line)
        if field:
            out.append((field.group(2), int(field.group(1))))
    return out


class TheCommittedP4InfoTest(unittest.TestCase):
    """What is in the tree, readable without a compiler."""

    def setUp(self):
        path = os.path.join(TELEMETRY_FIXTURE, "build", "basic_telemetry.p4.p4info.txtpb")
        if not os.path.isfile(path):
            self.fail(f"{path} is missing -- the fixture's build products are committed")
        with open(path, encoding="utf-8") as fh:
            self.text = fh.read()

    def test_the_five_names_are_there_with_their_widths(self):
        self.assertEqual(p4info_header_fields(self.text, "packet_in"), list(PACKET_IN_FIELDS))

    def test_the_ids_are_one_through_five_in_this_program(self):
        ids = p4info_header_ids(self.text, "packet_in")
        self.assertEqual({k: ids[k] for k in ("reason", "ingress_port", "egress_port",
                                              "frame_length", "sampling_rate")},
                         {"reason": 1, "ingress_port": 2, "egress_port": 3,
                          "frame_length": 4, "sampling_rate": 5})

    def test_the_packet_out_header_is_there_too(self):
        self.assertEqual(p4info_header_fields(self.text, "packet_out"), list(PACKET_OUT_FIELDS))

    def test_there_is_no_third_controller_header(self):
        # P4Runtime's reference implementation recognises `packet_in` and `packet_out` by name
        # and silently ignores anything else, so a third would compile and do nothing.
        names = re.findall(r"controller_packet_metadata \{\s+preamble \{\s+id: \d+\s+"
                           r"name: \"([^\"]+)\"", self.text)
        self.assertEqual(sorted(names), ["packet_in", "packet_out"])

    def test_the_exercises_own_table_survived_the_include(self):
        # The point of the include is that the author keeps their program. A p4info with our
        # header and none of their tables would mean the include had eaten the exercise.
        self.assertIn('name: "MyIngress.ipv4_lpm"', self.text)
        self.assertIn('name: "MyIngress.ipv4_forward"', self.text)


class TheIncludeAndNdtwinSwitchAgreeTest(unittest.TestCase):
    """Two copies of one header. A drift between them is decoded, not reported."""

    def setUp(self):
        for path in (INCLUDE, NDTWIN_SWITCH):
            if not os.path.isfile(path):
                self.fail(f"{path} is missing")
        with open(INCLUDE, encoding="utf-8") as fh:
            self.include = fh.read()
        with open(NDTWIN_SWITCH, encoding="utf-8") as fh:
            self.switch = fh.read()

    def test_packet_in_header_t_is_declared_identically_in_both(self):
        self.assertEqual(p4_header_fields(self.include, "packet_in_header_t"),
                         p4_header_fields(self.switch, "packet_in_header_t"))
        self.assertEqual(p4_header_fields(self.include, "packet_in_header_t"),
                         list(PACKET_IN_FIELDS))

    def test_packet_out_header_t_is_declared_identically_in_both(self):
        self.assertEqual(p4_header_fields(self.include, "packet_out_header_t"),
                         p4_header_fields(self.switch, "packet_out_header_t"))

    def test_the_session_the_rate_and_the_cpu_port_agree(self):
        # The proxy programs SAMPLE_SESSION into the PRE and the emitter reports the rate. A
        # program cloning into a session nobody programmed is dropped by bmv2 with no error.
        for include_name, switch_name in (("NDTWIN_SAMPLE_SESSION", "SAMPLE_SESSION"),
                                          ("NDTWIN_SAMPLE_RATE", "SAMPLE_RATE"),
                                          ("NDTWIN_CPU_PORT", "CPU_PORT"),
                                          ("NDTWIN_SAMPLE_TRUNC_BYTES", "SAMPLE_TRUNC_BYTES"),
                                          ("NDTWIN_FL_SAMPLE", "FL_SAMPLE"),
                                          ("NDTWIN_PKTIN_REASON_SAMPLE", "PKTIN_REASON_SAMPLE")):
            with self.subTest(constant=include_name):
                self.assertEqual(self._const(self.include, include_name),
                                 self._const(self.switch, switch_name))

    @staticmethod
    def _const(source, name):
        match = re.search(r"const\s+bit<\d+>\s+" + re.escape(name) + r"\s*=\s*([^;]+);", source)
        assert match, f"no const {name}"
        return match.group(1).strip()

    def test_ndtwin_switch_does_not_include_the_new_file(self):
        # TICKET-P3 0.7: ndtwin_switch.p4 and p4_src/build/* are not this ticket's to change,
        # and an #include here would change the compiled artefacts every fabric is running.
        self.assertNotIn("ndtwin_telemetry.p4", self.switch)


class TheFixtureIsTheSolutionPlusTheIncludeTest(unittest.TestCase):
    """The forwarding half must still be the exercise's, or the claim is about another program."""

    def setUp(self):
        with open(os.path.join(TELEMETRY_FIXTURE, "basic_telemetry.p4"), encoding="utf-8") as fh:
            self.fixture = fh.read()
        with open(BASIC_SOLUTION, encoding="utf-8") as fh:
            self.solution = fh.read()

    def test_the_ipv4_lpm_table_is_the_solutions_word_for_word(self):
        self.assertIn(self._block(self.solution, "table ipv4_lpm"),
                      self.fixture)

    def test_the_forward_action_is_the_solutions_word_for_word(self):
        self.assertIn(self._block(self.solution, "action ipv4_forward"), self.fixture)

    #: The lines the integration adds that do NOT themselves mention ndtwin -- the header
    #: members, the parser branch, the deparser emit and the egress `apply` the solution wrote
    #: as `apply {  }`. Written out, because "every added line either says NDTWIN or is one of
    #: these eight" is a claim a reader can check against the include's own instructions, while
    #: "at most N lines were added" is a claim about nothing.
    #: [Co-developed with claude code -- Adam]
    INTEGRATION_LINES = frozenset({
        "packet_out_header_t packet_out;",          # headers struct, member 1
        "packet_in_header_t  packet_in;",           # headers struct, member 2
        "transition select(standard_metadata.ingress_port) {",   # parser: packet-out branch
        "default: parse_ethernet;",
        "packet.extract(hdr.packet_out);",
        "apply {",                                  # egress: `apply {  }` becomes a body
        "return;",                                  # egress: the copy leaves here
        "packet.emit(hdr.packet_in);",              # deparser: the controller header first
    })

    def test_every_edit_against_the_solution_is_accounted_for(self):
        # 🔴 The property that keeps this fixture honest: a reader diffing it against the
        # solution must find only the include's own documented integration. Anything else is a
        # change to the EXERCISE smuggled in under a telemetry commit -- and then the claim
        # "the author keeps their own program" would be about a program nobody wrote.
        import difflib
        added = [line[2:] for line in difflib.ndiff(self.solution.splitlines(),
                                                    self.fixture.splitlines())
                 if line.startswith("+ ") and line[2:].strip()]
        unaccounted = [line for line in added
                       if "NDTWIN" not in line and "ndtwin" not in line
                       and line.strip() not in self.INTEGRATION_LINES
                       and not line.strip().startswith(("*", "/*", "//", "#include", "}"))]
        self.assertEqual(unaccounted, [],
                         "added line(s) that are neither marked NDTWIN nor part of the "
                         "documented integration")

    def test_nothing_was_removed_from_the_solution(self):
        import difflib
        removed = [line[2:] for line in difflib.ndiff(self.solution.splitlines(),
                                                      self.fixture.splitlines())
                   if line.startswith("- ") and line[2:].strip()]
        # The only removals are the two deparser emits and the parser's `start`, each replaced
        # by a marked version of itself, plus the empty `struct metadata`.
        self.assertLessEqual(len(removed), 8, f"too much of the solution is gone: {removed}")

    @staticmethod
    def _block(source, opener):
        start = source.index(opener)
        depth, i = 0, source.index("{", start)
        while True:
            if source[i] == "{":
                depth += 1
            elif source[i] == "}":
                depth -= 1
                if depth == 0:
                    return source[start:i + 1]
            i += 1


class TheIncludeCompilesTest(unittest.TestCase):
    """The claim that needs a compiler. Skips loudly when there is none."""

    def setUp(self):
        if not os.path.isfile(P4C) or not os.access(P4C, os.X_OK):
            self.skipTest(
                f"no p4c-bm2-ss at {P4C}, so this machine cannot compile the fixture. This is "
                f"NOT evidence that it compiles -- the committed build products under "
                f"fixtures/basic_telemetry/build/ were produced by p4c-bm2-ss 1.2.5.15.")
        self.tmp = tempfile.mkdtemp(prefix="p4_telemetry_include_")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def compile(self, source_path):
        build = os.path.join(self.tmp, "build")
        os.makedirs(build, exist_ok=True)
        stem = os.path.splitext(os.path.basename(source_path))[0]
        p4info = os.path.join(build, f"{stem}.p4.p4info.txtpb")
        completed = subprocess.run(
            [P4C, "--p4v", "16", "-I", P4_SRC, "--p4runtime-files", p4info,
             "-o", os.path.join(build, f"{stem}.json"), source_path],
            cwd=os.path.dirname(source_path), capture_output=True, text=True, timeout=300)
        return completed, p4info

    def test_the_fixture_compiles(self):
        completed, p4info = self.compile(
            os.path.join(TELEMETRY_FIXTURE, "basic_telemetry.p4"))
        self.assertEqual(completed.returncode, 0,
                         f"p4c failed:\n{completed.stderr}\n{completed.stdout}")
        self.assertTrue(os.path.isfile(p4info))

    def test_the_freshly_compiled_p4info_carries_the_five_names(self):
        completed, p4info = self.compile(
            os.path.join(TELEMETRY_FIXTURE, "basic_telemetry.p4"))
        self.assertEqual(completed.returncode, 0, completed.stderr)
        with open(p4info, encoding="utf-8") as fh:
            text = fh.read()
        self.assertEqual(p4info_header_fields(text, "packet_in"), list(PACKET_IN_FIELDS))

    def test_the_committed_p4info_is_the_one_this_compiler_produces(self):
        # The committed artefacts are what every other test in this tree reads. If they drifted
        # from the source beside them, those tests would be describing a program nobody has.
        completed, p4info = self.compile(
            os.path.join(TELEMETRY_FIXTURE, "basic_telemetry.p4"))
        self.assertEqual(completed.returncode, 0, completed.stderr)
        with open(p4info, encoding="utf-8") as fh:
            fresh = fh.read()
        with open(os.path.join(TELEMETRY_FIXTURE, "build",
                               "basic_telemetry.p4.p4info.txtpb"), encoding="utf-8") as fh:
            committed = fh.read()
        self.assertEqual(fresh, committed,
                         "the committed p4info is not what p4c produces from the .p4 beside it")

    def test_the_solution_without_the_include_declares_no_controller_header(self):
        # 🔴 THE NEGATIVE CONTROL. Without it, "the fixture's p4info has a packet_in header"
        # would be consistent with p4c adding one to every program.
        completed, p4info = self.compile(BASIC_SOLUTION)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        with open(p4info, encoding="utf-8") as fh:
            text = fh.read()
        self.assertEqual(p4info_header_fields(text, "packet_in"), [])
        self.assertNotIn("controller_packet_metadata", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
