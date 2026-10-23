"""bmv2 `simple_switch_CLI` table commands -> P4Runtime runtime entries, and convert.py using it.

[Co-developed with claude code -- Adam]

    p4_proxy/venv/bin/python -m unittest discover -s tools/p4_exercise/tests \
        -t tools/p4_exercise/tests -v

The subject is a published app that programs part of its fabric through the bmv2 CLI instead of
a P4Runtime runtime file: niloysh/int-v1 @84a3ebe8 (MIT) installs its INT source rules with two
`simple_switch_CLI <<< "table_add ..."` lines in runtime_cmds/s1.sh, one of them a ternary entry
with priority 0 and two zero masks. No FILE from that repository is copied here. The p4info
below is written by hand: for the three tables and the actions the app's runtime files and CLI
lines use, it has the names, widths and match kinds int-v1's compiled p4info has (checked
against the compile, logs gates-0910/p4-paper-apps/22_p4info_shapes.log), but it is a SUBSET --
ipv4_lpm's NoAction ref and the tb_set_sink table are left out -- and two tables of our own are
added for the range and mixed lpm/ternary rules. The two CLI command lines below, and the
script lines `#!/bin/bash`, `SWITCH_NUM=1` and the THRIFT_PORT assignment, are int-v1's
runtime_cmds/s1.sh lines verbatim (test vectors: what the translator must read); the rest of
the script is ours. The topology is a two-switch tree of our own.

What is pinned, and why each is a line of its own:

  * the thrift CLI MASKS a ternary key on insert and P4Runtime REFUSES a value with a bit
    outside its mask (match_shape V3) -- so the translation carries value & mask, says so, and
    never hands the writer `10.0.1.1&&&0xFFFFFF00` to refuse after the fabric is up;
  * a zero mask is "don't care" in the CLI and a refused second spelling of it in P4Runtime
    (match_shape V5) -- the field is omitted, and said;
  * the CLI's priority runs the other way: in bmv2 the LOWER number wins, in P4Runtime the
    HIGHER one does (spec 9.1), and the CLI accepts 0 where P4Runtime needs 1..2^31-1. bmv2's
    P4Runtime server stores p as 2^31-1-p, so the translation is CLI c -> 2^31-1-c and bmv2
    holds c itself; c must be 0..2^31-2;
  * every name is resolved the way the CLI resolves it -- the full name, or a dotted suffix
    that only one object has -- and an ambiguous one is refused, never picked.
"""
import contextlib
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

from p4_exercise import common, convert, thrift_cli  # noqa: E402

#: The shapes int-v1's compiled p4info has, written out by hand (see the module docstring), plus
#: one range table of our own so the range rules have a subject. Ids are arbitrary but unique.
P4INFO_TEXT = """\
pkg_info {
  arch: "v1model"
}
tables {
  preamble {
    id: 1
    name: "MyIngress.FwdIngress.ipv4_lpm"
    alias: "ipv4_lpm"
  }
  match_fields {
    id: 1
    name: "hdr.ipv4.dst_addr"
    bitwidth: 32
    match_type: LPM
  }
  action_refs {
    id: 11
  }
  action_refs {
    id: 12
  }
  size: 1024
}
tables {
  preamble {
    id: 2
    name: "MyIngress.process_int_source_sink.tb_set_source"
    alias: "tb_set_source"
  }
  match_fields {
    id: 1
    name: "standard_metadata.ingress_port"
    bitwidth: 9
    match_type: EXACT
  }
  action_refs {
    id: 13
  }
  action_refs {
    id: 14
    annotations: "@defaultonly"
    scope: DEFAULT_ONLY
  }
  size: 255
}
tables {
  preamble {
    id: 3
    name: "MyIngress.process_int_source.tb_int_source"
    alias: "tb_int_source"
  }
  match_fields {
    id: 1
    name: "hdr.ipv4.src_addr"
    bitwidth: 32
    match_type: TERNARY
  }
  match_fields {
    id: 2
    name: "hdr.ipv4.dst_addr"
    bitwidth: 32
    match_type: TERNARY
  }
  match_fields {
    id: 3
    name: "local_metadata.l4_src_port"
    bitwidth: 16
    match_type: TERNARY
  }
  match_fields {
    id: 4
    name: "local_metadata.l4_dst_port"
    bitwidth: 16
    match_type: TERNARY
  }
  action_refs {
    id: 15
  }
  action_refs {
    id: 16
    annotations: "@defaultonly"
    scope: DEFAULT_ONLY
  }
  size: 1024
}
tables {
  preamble {
    id: 4
    name: "MyIngress.acl.port_range"
    alias: "port_range"
  }
  match_fields {
    id: 1
    name: "local_metadata.l4_dst_port"
    bitwidth: 16
    match_type: RANGE
  }
  action_refs {
    id: 12
  }
  size: 64
}
tables {
  preamble {
    id: 5
    name: "MyIngress.acl.mixed"
    alias: "mixed"
  }
  match_fields {
    id: 1
    name: "hdr.ipv4.dst_addr"
    bitwidth: 32
    match_type: LPM
  }
  match_fields {
    id: 2
    name: "local_metadata.l4_dst_port"
    bitwidth: 16
    match_type: TERNARY
  }
  action_refs {
    id: 12
  }
  size: 64
}
actions {
  preamble {
    id: 11
    name: "MyIngress.FwdIngress.ipv4_forward"
    alias: "ipv4_forward"
  }
  params {
    id: 1
    name: "dst_addr"
    bitwidth: 48
  }
  params {
    id: 2
    name: "port"
    bitwidth: 9
  }
}
actions {
  preamble {
    id: 12
    name: "MyIngress.FwdIngress.drop"
    alias: "drop"
  }
}
actions {
  preamble {
    id: 13
    name: "MyIngress.process_int_source_sink.int_set_source"
    alias: "int_set_source"
  }
}
actions {
  preamble {
    id: 14
    name: "MyIngress.process_int_source_sink.nop"
    alias: "process_int_source_sink.nop"
  }
}
actions {
  preamble {
    id: 15
    name: "MyIngress.process_int_source.int_source_dscp"
    alias: "int_source_dscp"
  }
  params {
    id: 1
    name: "hop_metadata_len"
    bitwidth: 5
  }
  params {
    id: 2
    name: "remaining_hop_cnt"
    bitwidth: 8
  }
  params {
    id: 3
    name: "ins_mask0003"
    bitwidth: 4
  }
  params {
    id: 4
    name: "ins_mask0407"
    bitwidth: 4
  }
}
actions {
  preamble {
    id: 16
    name: "MyIngress.process_int_source.nop"
    alias: "process_int_source.nop"
  }
}
"""

#: int-v1's two CLI commands, as runtime_cmds/s1.sh:7 and :21 give them (the commands are
#: facts the app's behaviour depends on; the script around them below is our own wording).
SET_SOURCE = "table_add tb_set_source int_set_source 1 =>"
INT_SOURCE = ("table_add tb_int_source int_source_dscp 10.0.1.1&&&0xFFFFFF00 "
              "10.0.2.2&&&0xFFFFFF00 0x1F41&&&0x0000 0x1F41&&&0x0000 => 8 4 0xF 0xF 0")

#: The same form as int-v1's runtime_cmds/s1.sh: variables, then one CLI call per command,
#: each fed through a here-string. Our comments, not theirs.
SCRIPT = """\
#!/bin/bash
SWITCH_NUM=1
# which thrift port this switch listens on
THRIFT_PORT=$((9090 + SWITCH_NUM - 1))

# make ingress port 1 an INT source
simple_switch_CLI --thrift-port $THRIFT_PORT <<< "%s"

# the flows that get an INT header
simple_switch_CLI --thrift-port $THRIFT_PORT <<< "%s"
""" % (SET_SOURCE, INT_SOURCE)

MASK24 = 0xFFFFFF00
#: CLI priority 0, as P4Runtime: 2^31-1 (bmv2 then holds 0).
P0 = (1 << 31) - 1
INT_TABLE = "MyIngress.process_int_source.tb_int_source"
INT_ACTION = "MyIngress.process_int_source.int_source_dscp"


def schema():
    from google.protobuf import text_format
    from p4.config.v1 import p4info_pb2

    pb = p4info_pb2.P4Info()
    text_format.Merge(P4INFO_TEXT, pb)
    return thrift_cli.schema_from_p4info(pb)


def one(line):
    """The single entry one command translates to, and its notes."""
    entries, notes = thrift_cli.translate([(1, line)], schema())
    assert len(entries) == 1, entries
    return entries[0], notes


class TheIntV1Commands(unittest.TestCase):
    """The two commands int-v1 actually runs, translated whole."""

    def test_the_int_source_line_becomes_one_runtime_entry(self):
        entry, _notes = one(INT_SOURCE)
        self.assertEqual(entry, {
            "table": INT_TABLE,
            "match": {"hdr.ipv4.src_addr": ["10.0.1.0", MASK24],
                      "hdr.ipv4.dst_addr": ["10.0.2.0", MASK24]},
            "action_name": INT_ACTION,
            "action_params": {"hop_metadata_len": 8, "remaining_hop_cnt": 4,
                              "ins_mask0003": 15, "ins_mask0407": 15},
            "priority": P0,
        })

    def test_the_set_source_line_is_an_exact_entry_with_no_priority(self):
        entry, notes = one(SET_SOURCE)
        self.assertEqual(entry, {
            "table": "MyIngress.process_int_source_sink.tb_set_source",
            "match": {"standard_metadata.ingress_port": 1},
            "action_name": "MyIngress.process_int_source_sink.int_set_source",
            "action_params": {},
        })
        self.assertEqual(notes, [])


class Ternary(unittest.TestCase):
    def test_a_ternary_value_is_masked_the_way_thrift_masks_it(self):
        entry, notes = one(INT_SOURCE)
        self.assertEqual(entry["match"]["hdr.ipv4.src_addr"][0], "10.0.1.0")
        said = " ".join(notes)
        self.assertIn("10.0.1.1", said)
        self.assertIn("10.0.1.0", said)

    def test_a_value_already_inside_its_mask_is_not_said_to_be_masked(self):
        line = INT_SOURCE.replace("10.0.1.1&&&", "10.0.1.0&&&").replace("10.0.2.2&&&",
                                                                        "10.0.2.0&&&")
        _entry, notes = one(line)
        self.assertFalse([n for n in notes if "masked" in n], notes)

    def test_a_zero_mask_field_is_omitted_and_said(self):
        entry, notes = one(INT_SOURCE)
        self.assertNotIn("local_metadata.l4_src_port", entry["match"])
        self.assertNotIn("local_metadata.l4_dst_port", entry["match"])
        omitted = [n for n in notes if "omitted" in n]
        self.assertEqual(len(omitted), 2, notes)

    def test_a_ternary_key_without_a_mask_is_refused(self):
        line = INT_SOURCE.replace("10.0.1.1&&&0xFFFFFF00", "10.0.1.1")
        with self.assertRaises(thrift_cli.Untranslatable) as caught:
            one(line)
        self.assertIn("&&&", str(caught.exception))

    def test_a_mask_wider_than_its_field_is_refused(self):
        line = INT_SOURCE.replace("0x1F41&&&0x0000 0x1F41", "0x1F41&&&0x1FFFF 0x1F41", 1)
        with self.assertRaises(thrift_cli.Untranslatable):
            one(line)


class Priority(unittest.TestCase):
    def test_cli_priority_zero_becomes_two_to_the_31_minus_one(self):
        entry, _notes = one(INT_SOURCE)
        self.assertEqual(entry["priority"], P0)

    def test_the_lower_thrift_priority_is_the_higher_p4runtime_priority(self):
        low = INT_SOURCE[:-1] + "0"
        high = (INT_SOURCE.replace("10.0.2.2&&&0xFFFFFF00", "10.0.3.3&&&0xFFFFFF00")[:-1]
                + "5")
        entries, _notes = thrift_cli.translate([(1, low), (2, high)], schema())
        self.assertEqual([e["priority"] for e in entries], [P0, P0 - 5])

    def test_the_mapping_is_per_entry_not_relative_to_the_others(self):
        # The exact inverse: an entry's P4Runtime priority does not move when another CLI entry
        # is added to the same file (the earlier (largest + 1) - c mapping did move it).
        alone, _n = thrift_cli.translate([(1, INT_SOURCE[:-1] + "3")], schema())
        other = INT_SOURCE.replace("10.0.2.2&&&", "10.0.3.3&&&")[:-1] + "9"
        both, _n = thrift_cli.translate([(1, INT_SOURCE[:-1] + "3"), (2, other)], schema())
        self.assertEqual(alone[0]["priority"], both[0]["priority"])
        self.assertEqual(alone[0]["priority"], P0 - 3)

    def test_the_largest_cli_priority_it_can_carry_is_two_to_the_31_minus_two(self):
        entry, _notes = one(INT_SOURCE[:-1] + str(P0 - 1))
        self.assertEqual(entry["priority"], 1)

    def test_a_cli_priority_of_two_to_the_31_minus_one_or_more_is_refused(self):
        for prio in (P0, P0 + 1, 1 << 40):
            with self.subTest(prio=prio):
                with self.assertRaises(thrift_cli.Untranslatable) as caught:
                    one(INT_SOURCE[:-1] + str(prio))
                self.assertIn(str(P0 - 1), str(caught.exception))

    def test_a_negative_cli_priority_is_refused(self):
        with self.assertRaises(thrift_cli.Untranslatable):
            one(INT_SOURCE[:-1] + "-1")

    def test_equal_thrift_priorities_stay_equal(self):
        a = INT_SOURCE[:-1] + "3"
        b = INT_SOURCE.replace("10.0.2.2&&&", "10.0.3.3&&&")[:-1] + "3"
        entries, _notes = thrift_cli.translate([(1, a), (2, b)], schema())
        self.assertEqual(entries[0]["priority"], entries[1]["priority"])

    def test_priorities_are_mapped_per_table(self):
        other = "table_add port_range drop 100->200 => 7"
        entries, _notes = thrift_cli.translate([(1, INT_SOURCE), (2, other)], schema())
        self.assertEqual([e["priority"] for e in entries], [P0, P0 - 7])

    def test_a_ternary_table_entry_with_no_priority_token_is_refused(self):
        line = INT_SOURCE[: -len(" 0")]
        with self.assertRaises(thrift_cli.Untranslatable) as caught:
            one(line)
        self.assertIn("priority", str(caught.exception))

    def test_an_exact_table_takes_no_priority_token(self):
        with self.assertRaises(thrift_cli.Untranslatable):
            one(SET_SOURCE + " 0")

    def test_the_mapping_is_said(self):
        _entry, notes = one(INT_SOURCE)
        self.assertTrue([n for n in notes if "priority" in n], notes)


class OtherMatchKinds(unittest.TestCase):
    def test_an_lpm_key_and_a_mac_parameter(self):
        entry, _notes = one("table_add ipv4_lpm ipv4_forward 10.0.2.2/32 => "
                            "08:00:00:00:02:00 2")
        self.assertEqual(entry, {
            "table": "MyIngress.FwdIngress.ipv4_lpm",
            "match": {"hdr.ipv4.dst_addr": ["10.0.2.2", 32]},
            "action_name": "MyIngress.FwdIngress.ipv4_forward",
            "action_params": {"dst_addr": "08:00:00:00:02:00", "port": 2},
        })

    def test_an_lpm_value_with_host_bits_is_refused_not_masked(self):
        # Not measured on bmv2 here, so not translated by assumption either.
        with self.assertRaises(thrift_cli.Untranslatable):
            one("table_add ipv4_lpm ipv4_forward 10.0.2.2/24 => 08:00:00:00:02:00 2")

    def test_an_lpm_slash_zero_on_a_table_with_no_priority_column_is_refused(self):
        # Everything don't-care on an exact/lpm table: P4Runtime can only say that as the default
        # action, and pre-flight refuses the empty match (TheLpmSlashZeroEndToEnd below).
        with self.assertRaises(thrift_cli.Untranslatable) as caught:
            one("table_add ipv4_lpm ipv4_forward 0.0.0.0/0 => 08:00:00:00:02:00 2")
        self.assertIn("table_set_default", str(caught.exception))

    def test_an_lpm_slash_zero_beside_a_ternary_field_is_omitted(self):
        entry, notes = one("table_add mixed drop 0.0.0.0/0 0x50&&&0xFFFF => 4")
        self.assertEqual(entry["match"], {"local_metadata.l4_dst_port": [0x50, 0xFFFF]})
        self.assertTrue([n for n in notes if "omitted" in n], notes)

    def test_a_range_key(self):
        entry, _notes = one("table_add port_range drop 100->200 => 0")
        self.assertEqual(entry["match"], {"local_metadata.l4_dst_port": [100, 200]})
        self.assertEqual(entry["priority"], P0)

    def test_the_whole_range_is_omitted(self):
        entry, notes = one("table_add port_range drop 0->65535 => 0")
        self.assertEqual(entry["match"], {})
        self.assertTrue([n for n in notes if "omitted" in n], notes)

    def test_a_range_running_backwards_is_refused(self):
        with self.assertRaises(thrift_cli.Untranslatable):
            one("table_add port_range drop 200->100 => 0")

    def test_a_value_too_wide_for_its_field_is_refused(self):
        with self.assertRaises(thrift_cli.Untranslatable) as caught:
            one("table_add tb_set_source int_set_source 512 =>")
        self.assertIn("9", str(caught.exception))

    def test_an_ipv4_spelling_on_a_field_that_is_not_32_bits_is_refused(self):
        with self.assertRaises(thrift_cli.Untranslatable):
            one("table_add tb_set_source int_set_source 10.0.0.1 =>")

    def test_table_set_default(self):
        entry, _notes = one("table_set_default ipv4_lpm drop")
        self.assertEqual(entry, {"table": "MyIngress.FwdIngress.ipv4_lpm",
                                 "default_action": True,
                                 "action_name": "MyIngress.FwdIngress.drop",
                                 "action_params": {}})


class Values(unittest.TestCase):
    def test_a_leading_zero_in_an_ipv4_part_is_decimal_as_in_the_cli(self):
        entry, notes = one("table_add ipv4_lpm ipv4_forward 10.0.010.1/32 => 08:00:00:00:02:00 2")
        self.assertEqual(entry["match"]["hdr.ipv4.dst_addr"], ["10.0.10.1", 32])
        self.assertTrue([n for n in notes if "10.0.010.1" in n and "10.0.10.1" in n], notes)

    def test_an_ipv4_part_in_hex_or_three_parts_is_refused(self):
        for value in ("0x10.0.0.1", "10.0.1", "1.2.3.256"):
            with self.subTest(value=value):
                with self.assertRaises(thrift_cli.Untranslatable):
                    one("table_add ipv4_lpm ipv4_forward %s/32 => 08:00:00:00:02:00 2" % value)

    def test_a_short_mac_group_is_read_as_the_cli_reads_it(self):
        entry, notes = one("table_add ipv4_lpm ipv4_forward 10.0.2.2/32 => 8:0:0:0:2:0 2")
        self.assertEqual(entry["action_params"]["dst_addr"], "08:00:00:00:02:00")
        self.assertTrue(notes)


#: (token, bitwidth, relation). "agree": the translator and runtime_CLI.parse_param accept with
#: the same value, or both refuse. "stricter": runtime_CLI accepts and this translator refuses --
#: the documented four (a value it would silently change).
PARSE_CORPUS = (
    ("10.0.010.1", 32, "agree"), ("10.0.1.1", 32, "agree"), ("0.0.0.0", 32, "agree"),
    ("255.255.255.255", 32, "agree"), ("10.0.1", 32, "agree"), ("0x10.0.0.1", 32, "agree"),
    ("1.2.3.4.5", 32, "agree"), ("1.2.3.x", 32, "agree"), ("1.2.3.256", 32, "agree"),
    ("08:00:00:00:02:22", 48, "agree"), ("8:0:0:0:2:0", 48, "agree"),
    ("08:00:00:00:02", 48, "agree"), ("0x1F41", 16, "agree"), ("8001", 16, "agree"),
    ("0", 9, "agree"), ("511", 9, "agree"), ("0b101", 9, "agree"), ("0o17", 9, "agree"),
    ("abc", 16, "agree"), ("10.0.0.1", 16, "agree"), ("08:00:00:00:02:22", 32, "agree"),
    ("-1", 16, "stricter"), ("512", 9, "stricter"), ("0x1FFFF", 16, "agree"),
    ("0x200", 9, "stricter"),
)


def rcli_python():
    """The p4dev venv interpreter and the directory its runtime_CLI.py lives in, or None."""
    py = "/home/adam/p4dev-python-venv/bin/python"
    site = "/home/adam/p4dev-python-venv/lib/python3.13/site-packages"
    if os.access(py, os.X_OK) and os.path.isfile(os.path.join(site, "runtime_CLI.py")):
        return py, site
    return None


class TheParserAgainstRuntimeCli(unittest.TestCase):
    """runtime_CLI.parse_param, run in the p4dev venv it ships in (the way simple_switch_CLI's
    own wrapper adds that directory), against _parse + _fits over PARSE_CORPUS."""

    def test_the_value_parser_agrees_with_runtime_cli_except_where_it_says_it_is_stricter(self):
        found = rcli_python()
        if found is None:
            self.skipTest("no /home/adam/p4dev-python-venv with runtime_CLI.py on this machine: "
                          "the differential needs the CLI's own parser, nothing else stands in")
        import subprocess
        py, site = found
        script = (
            "import json, sys\n"
            "sys.path.append(sys.argv[1])\n"
            "import runtime_CLI as R\n"
            "out = []\n"
            "for token, width in json.loads(sys.argv[2]):\n"
            "    try:\n"
            "        out.append(int.from_bytes(bytes(R.parse_param(token, width)), 'big'))\n"
            "    except Exception as exc:\n"
            "        out.append(None)\n"
            "print(json.dumps(out))\n")
        corpus = [[t, w] for t, w, _r in PARSE_CORPUS]
        res = subprocess.run([py, "-I", "-c", script, site, json.dumps(corpus)],
                             capture_output=True, text=True, timeout=60, cwd=tempfile.gettempdir())
        self.assertEqual(res.returncode, 0, res.stderr)
        rcli = json.loads(res.stdout)
        for (token, width, relation), theirs in zip(PARSE_CORPUS, rcli):
            with self.subTest(token=token, width=width):
                try:
                    value, _form = thrift_cli._parse(token, width, "t")
                    ours = thrift_cli._fits(value, width, "t")
                except thrift_cli.Untranslatable:
                    ours = None
                if relation == "agree":
                    self.assertEqual(ours, theirs)
                else:
                    self.assertIsNotNone(theirs, "runtime_CLI was expected to accept this")
                    self.assertIsNone(ours, "the translator was expected to refuse this")


class Refusals(unittest.TestCase):
    def test_an_unsupported_cli_command_is_refused_by_name(self):
        for line in ("mirroring_add 1 2", "table_delete tb_set_source 0",
                     "register_write r 0 1", "mc_mgrp_create 1",
                     "table_modify tb_set_source int_set_source 0 =>"):
            with self.subTest(line=line):
                with self.assertRaises(thrift_cli.Untranslatable) as caught:
                    one(line)
                self.assertIn(line.split()[0], str(caught.exception))

    def test_an_ambiguous_short_name_is_refused_naming_both(self):
        with self.assertRaises(thrift_cli.Untranslatable) as caught:
            one("table_set_default tb_set_source nop")
        message = str(caught.exception)
        self.assertIn("MyIngress.process_int_source_sink.nop", message)
        self.assertIn("MyIngress.process_int_source.nop", message)

    def test_a_dotted_suffix_that_one_object_has_resolves(self):
        entry, _notes = one("table_set_default tb_set_source process_int_source_sink.nop")
        self.assertEqual(entry["action_name"], "MyIngress.process_int_source_sink.nop")

    def test_a_suffix_must_end_on_a_dot_boundary(self):
        with self.assertRaises(thrift_cli.Untranslatable):
            one("table_set_default ipv4_lpm rop")

    def test_an_unknown_table_is_refused(self):
        with self.assertRaises(thrift_cli.Untranslatable) as caught:
            one("table_add tb_nowhere int_set_source 1 =>")
        self.assertIn("tb_nowhere", str(caught.exception))

    def test_an_action_the_table_does_not_take_is_refused(self):
        with self.assertRaises(thrift_cli.Untranslatable):
            one("table_add tb_set_source drop 1 =>")

    def test_the_wrong_number_of_keys_is_refused(self):
        with self.assertRaises(thrift_cli.Untranslatable):
            one("table_add tb_set_source int_set_source 1 2 =>")

    def test_the_wrong_number_of_parameters_is_refused(self):
        with self.assertRaises(thrift_cli.Untranslatable):
            one("table_add ipv4_lpm ipv4_forward 10.0.2.2/32 => 08:00:00:00:02:00")

    def test_a_table_add_with_no_arrow_is_refused(self):
        with self.assertRaises(thrift_cli.Untranslatable):
            one("table_add tb_set_source int_set_source 1")

    def test_the_refusal_names_the_line(self):
        with self.assertRaises(thrift_cli.Untranslatable) as caught:
            thrift_cli.translate([(21, "table_add tb_nowhere x 1 =>")], schema())
        self.assertIn("21", str(caught.exception))


class Extraction(unittest.TestCase):
    def test_the_int_v1_shaped_script_yields_its_two_commands_in_order(self):
        got = thrift_cli.commands_from_text(SCRIPT, "runtime_cmds/s1.sh")
        self.assertEqual([c for _n, c in got], [SET_SOURCE, INT_SOURCE])
        self.assertEqual([n for n, _c in got], [7, 10])

    def test_a_shell_line_that_is_not_a_cli_call_is_refused(self):
        for line in ("echo hello", "for i in 1 2; do true; done",
                     "simple_switch_CLI --thrift-port 9090 < s1-commands.txt",
                     "source other.sh"):
            with self.subTest(line=line):
                with self.assertRaises(thrift_cli.Untranslatable) as caught:
                    thrift_cli.commands_from_text("#!/bin/bash\n%s\n" % line, "x.sh")
                self.assertIn("line 2", str(caught.exception))

    def test_a_command_that_needs_the_shell_to_expand_it_is_refused(self):
        text = '#!/bin/bash\nsimple_switch_CLI <<< "table_add tb_set_source int_set_source $P =>"\n'
        with self.assertRaises(thrift_cli.Untranslatable) as caught:
            thrift_cli.commands_from_text(text, "x.sh")
        self.assertIn("$", str(caught.exception))

    def test_a_cli_flag_other_than_the_thrift_address_is_refused(self):
        text = '#!/bin/bash\nsimple_switch_CLI --json other.json <<< "%s"\n' % SET_SOURCE
        with self.assertRaises(thrift_cli.Untranslatable):
            thrift_cli.commands_from_text(text, "x.sh")

    def test_two_cli_addresses_in_one_script_are_refused(self):
        text = ("#!/bin/bash\n"
                "simple_switch_CLI --thrift-port 9090 <<< \"%s\"\n"
                "simple_switch_CLI --thrift-port 9091 <<< \"%s\"\n" % (SET_SOURCE, INT_SOURCE))
        with self.assertRaises(thrift_cli.Untranslatable) as caught:
            thrift_cli.read_script(text, "x.sh")
        self.assertIn("9091", str(caught.exception))

    def test_a_call_with_an_address_and_one_without_are_two_addresses(self):
        text = ("#!/bin/bash\n"
                "simple_switch_CLI --thrift-port 9090 <<< \"%s\"\n"
                "simple_switch_CLI <<< \"%s\"\n" % (SET_SOURCE, INT_SOURCE))
        with self.assertRaises(thrift_cli.Untranslatable):
            thrift_cli.read_script(text, "x.sh")

    def test_an_address_variable_assigned_twice_is_refused(self):
        text = SCRIPT.replace("# make ingress port 1 an INT source",
                              "THRIFT_PORT=9091")
        with self.assertRaises(thrift_cli.Untranslatable) as caught:
            thrift_cli.read_script(text, "x.sh")
        self.assertIn("THRIFT_PORT", str(caught.exception))

    def test_the_address_text_is_in_the_notes(self):
        _commands, notes = thrift_cli.read_script(SCRIPT, "runtime_cmds/s1.sh")
        self.assertTrue([n for n in notes if "--thrift-port $THRIFT_PORT" in n], notes)

    def test_a_flag_with_a_shell_metacharacter_is_refused(self):
        for flag in ("9090;true", "9090&", "9090|cat", "`id`"):
            with self.subTest(flag=flag):
                text = '#!/bin/bash\nsimple_switch_CLI --thrift-port %s <<< "%s"\n' % (
                    flag, SET_SOURCE)
                with self.assertRaises(thrift_cli.Untranslatable) as caught:
                    thrift_cli.read_script(text, "x.sh")
                self.assertIn("metacharacter", str(caught.exception))

    def test_a_command_substitution_in_an_assignment_is_refused(self):
        for line in ("PORT=$(cat port.txt)", "PORT=`cat port.txt`"):
            with self.subTest(line=line):
                with self.assertRaises(thrift_cli.Untranslatable) as caught:
                    thrift_cli.read_script("#!/bin/bash\n%s\n" % line, "x.sh")
                self.assertIn("line 2", str(caught.exception))

    def test_an_address_whose_value_the_reader_cannot_know_is_refused(self):
        # The same text twice, two ports: bash evaluates $((9089+SW)) at each call.
        changing = ("#!/bin/bash\nSW=1\n"
                    "simple_switch_CLI --thrift-port $((9089+SW)) <<< \"%s\"\n"
                    "SW=2\n"
                    "simple_switch_CLI --thrift-port $((9089+SW)) <<< \"%s\"\n"
                    % (SET_SOURCE, INT_SOURCE))
        for text in (changing,
                     '#!/bin/bash\nsimple_switch_CLI --thrift-port $(./p.sh) <<< "%s"\n'
                     % SET_SOURCE,
                     '#!/bin/bash\nsimple_switch_CLI --thrift-port $[9089+1] <<< "%s"\n'
                     % SET_SOURCE,
                     '#!/bin/bash\nP=1\nsimple_switch_CLI --thrift-port 90$P <<< "%s"\n'
                     % SET_SOURCE):
            with self.subTest(text=text.splitlines()[-1]):
                with self.assertRaises(thrift_cli.Untranslatable) as caught:
                    thrift_cli.read_script(text, "x.sh")
                self.assertIn("expansion", str(caught.exception))

    def test_a_plain_variable_assigned_once_is_an_address(self):
        text = '#!/bin/bash\nP=9090\nsimple_switch_CLI --thrift-port ${P} <<< "%s"\n' % SET_SOURCE
        commands, notes = thrift_cli.read_script(text, "x.sh")
        self.assertEqual(commands, [(3, SET_SOURCE)])
        self.assertTrue([n for n in notes if "${P}" in n], notes)

    def test_an_address_variable_never_assigned_is_refused(self):
        text = '#!/bin/bash\nsimple_switch_CLI --thrift-port $PORT <<< "%s"\n' % SET_SOURCE
        with self.assertRaises(thrift_cli.Untranslatable) as caught:
            thrift_cli.read_script(text, "x.sh")
        self.assertIn("PORT", str(caught.exception))

    def test_a_plain_commands_file_is_one_command_per_line(self):
        text = "# s1\n%s\n\n%s\n" % (SET_SOURCE, INT_SOURCE)
        got = thrift_cli.commands_from_text(text, "s1-commands.txt")
        self.assertEqual(got, [(2, SET_SOURCE), (4, INT_SOURCE)])


# --- convert.py -----------------------------------------------------------------------------

TOPOLOGY = {
    "hosts": {
        "h1": {"ip": "10.0.1.1/24", "mac": "08:00:00:00:01:11", "commands": []},
        "h2": {"ip": "10.0.2.2/24", "mac": "08:00:00:00:02:22", "commands": []},
    },
    "switches": {"s1": {"runtime_json": "topo/s1-runtime.json"},
                 "s2": {"runtime_json": "topo/s2-runtime.json"}},
    "links": [["h1", "s1-p1"], ["s1-p2", "s2-p2"], ["h2", "s2-p1"]],
}


def runtime(p4info_rel="build/app.p4.p4info.txt", extra=()):
    return {"target": "bmv2", "p4info": p4info_rel, "bmv2_json": "build/app.json",
            "table_entries": [
                {"table": "MyIngress.FwdIngress.ipv4_lpm", "default_action": True,
                 "action_name": "MyIngress.FwdIngress.drop", "action_params": {}},
                {"table": "MyIngress.FwdIngress.ipv4_lpm",
                 "match": {"hdr.ipv4.dst_addr": ["10.0.2.2", 32]},
                 "action_name": "MyIngress.FwdIngress.ipv4_forward",
                 "action_params": {"dst_addr": "08:00:00:00:02:00", "port": 2}},
            ] + list(extra)}


class AppTree:
    """An int-v1-shaped app in a temporary directory: two switches, a .txt p4info."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="p4_paper_app_test_")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.app = os.path.join(self.tmp, "app")
        self.write("topo/topology.json", json.dumps(TOPOLOGY, indent=2))
        self.write("topo/s1-runtime.json", json.dumps(runtime(), indent=2))
        self.write("topo/s2-runtime.json", json.dumps(runtime(), indent=2))
        self.write("build/app.p4.p4info.txt", P4INFO_TEXT)
        self.write("build/app.json", "{}\n")
        self.write("app.p4", "// stand-in source\n")
        self.write("runtime_cmds/s1.sh", SCRIPT)

    def write(self, rel, text):
        path = os.path.join(self.app, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)

    def convert(self, out="pkg", **kw):
        out = os.path.join(self.tmp, out)
        kw.setdefault("p4_rel", "app.p4")
        package, _model, written = convert.convert(self.app, "topo/topology.json", out, **kw)
        return package, out, written


class TheLpmSlashZeroEndToEnd(AppTree, unittest.TestCase):
    """translate -> convert -> pre-flight: the entry a /0 on an exact/lpm table would become is
    one pre-flight refuses, and the translator refuses it first, so no package is written."""

    def test_pre_flight_refuses_the_entry_the_translator_now_refuses(self):
        from p4_exercise import preflight
        info = os.path.join(self.app, "build/app.p4.p4info.txt")
        index = preflight.P4InfoIndex.parse(info)
        would_be = {"table": "MyIngress.FwdIngress.ipv4_lpm", "match": {},
                    "action_name": "MyIngress.FwdIngress.ipv4_forward",
                    "action_params": {"dst_addr": "08:00:00:00:02:00", "port": 2}}
        problems = preflight.check_entry(would_be, index, "s1 entry 0")
        self.assertTrue([p for p in problems if "neither a match nor default_action" in p],
                        problems)

    def test_convert_refuses_the_script_and_writes_no_package(self):
        self.write("runtime_cmds/s1.sh", "#!/bin/bash\nsimple_switch_CLI <<< \"table_add ipv4_lpm "
                   "ipv4_forward 0.0.0.0/0 => 08:00:00:00:02:00 2\"\n")
        with self.assertRaises(convert.ConversionError) as caught:
            self.convert(thrift_commands={"s1": "runtime_cmds/s1.sh"})
        self.assertIn("table_set_default", str(caught.exception))
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "pkg", "package.json")))


class TheP4infoSuffix(AppTree, unittest.TestCase):
    """tutorials wrote `<stem>.p4.p4info.txt` until ffd07f2 (2024-10-15) and `.txtpb` since;
    an app built on the older utils/Makefile (int-v1 is one) carries the older name."""

    def test_a_pre_2024_tutorials_p4info_named_txt_is_found(self):
        package, out, _written = self.convert()
        for key in ("1", "2"):
            self.assertEqual(package["switches"][key]["pipeline"],
                             {"p4info": "build/app.p4.p4info.txt", "bmv2_json": "build/app.json"})
        self.assertEqual(package["source"]["p4info"], "build/app.p4.p4info.txt")
        self.assertTrue(os.path.isfile(os.path.join(out, "build/app.p4.p4info.txt")))

    def test_both_spellings_present_is_refused_naming_both(self):
        self.write("build/app.p4.p4info.txtpb", P4INFO_TEXT)
        with self.assertRaises(convert.ConversionError) as caught:
            self.convert()
        message = str(caught.exception)
        self.assertIn("build/app.p4.p4info.txt", message)
        self.assertIn("build/app.p4.p4info.txtpb", message)

    def test_with_neither_the_refusal_names_the_current_spelling(self):
        os.remove(os.path.join(self.app, "build/app.p4.p4info.txt"))
        with self.assertRaises(convert.ConversionError) as caught:
            self.convert()
        self.assertIn("build/app.p4.p4info.txtpb", str(caught.exception))


class TheProgramsOwnIncludes(AppTree, unittest.TestCase):
    """A program split over several files -- int-v1's int.p4 is five `#include "include/..."`
    files and twelve lines -- is carried whole, or pre-flight's recompile of `source.p4` fails
    inside the package (measured on int-v1, 2026-10-16: `p4c-bm2-ss rc=1`) and `ndt up p4 --app`
    refuses it."""

    def setUp(self):
        super().setUp()
        self.write("app.p4", '#include <core.p4>\n#include "include/a.p4"\n'
                             '/* see "include/not_an_include.p4" */\n')
        self.write("include/a.p4", '#include "b.p4"\n#include "a.p4"\n')
        self.write("include/b.p4", "// leaf\n")
        self.write("include/not_an_include.p4", "// only named in a comment\n")

    def test_a_p4_with_local_includes_carries_them_transitively(self):
        _package, out, written = self.convert()
        for rel in ("app.p4", "include/a.p4", "include/b.p4"):
            with self.subTest(rel=rel):
                self.assertIn(rel, written)
                self.assertTrue(os.path.isfile(os.path.join(out, rel)))

    def test_a_name_in_a_comment_and_a_system_header_are_not_copied(self):
        _package, _out, written = self.convert()
        self.assertNotIn("include/not_an_include.p4", written)
        self.assertFalse([w for w in written if w.endswith("core.p4")], written)

    def test_a_directory_symlink_to_an_ancestor_does_not_grow_the_walk(self):
        os.symlink("..", os.path.join(self.app, "include", "up"))
        self.write("include/b.p4", '#include "up/include/b.p4"\n')
        _package, _out, written = self.convert()
        self.assertEqual([w for w in written if w.endswith(".p4")],
                         ["app.p4", "include/a.p4", "include/b.p4"])

    def test_an_include_that_cannot_be_read_is_a_named_refusal(self):
        os.chmod(os.path.join(self.app, "include", "b.p4"), 0)
        self.addCleanup(os.chmod, os.path.join(self.app, "include", "b.p4"), 0o644)
        if os.access(os.path.join(self.app, "include", "b.p4"), os.R_OK):
            self.skipTest("running as a user that reads mode-0 files (root)")
        with self.assertRaises(convert.ConversionError) as caught:
            self.convert()
        self.assertIn("include/b.p4", str(caught.exception))

    def test_an_include_spelled_through_dotdot_is_written_inside_the_package(self):
        # The app directory is called `app`, so "../app/include/a.p4" comes back inside it.
        self.write("app.p4", '#include "../app/include/a.p4"\n')
        _package, out, written = self.convert()
        self.assertIn("include/a.p4", written)
        self.assertFalse([w for w in written if w.startswith("..")], written)

    def test_an_include_that_leaves_the_app_directory_is_refused(self):
        self.write("include/b.p4", '#include "../../outside.p4"\n')
        with open(os.path.join(self.tmp, "outside.p4"), "w") as fh:
            fh.write("// not the app's\n")
        with self.assertRaises(convert.ConversionError) as caught:
            self.convert()
        self.assertIn("outside.p4", str(caught.exception))


class ConvertingWithThriftCommands(AppTree, unittest.TestCase):
    def thrift(self, mapping=None, **kw):
        mapping = {"s1": "runtime_cmds/s1.sh"} if mapping is None else mapping
        report = {}
        package, out, written = self.convert(thrift_commands=mapping, thrift_report=report,
                                             **kw)
        return package, out, written, report

    def test_the_commands_are_appended_to_the_switchs_runtime_file(self):
        _package, out, _written, _report = self.thrift()
        doc = common.load_json(os.path.join(out, "topo/s1-runtime.json"))
        self.assertEqual(doc["table_entries"][:2], runtime()["table_entries"])
        tables = [e["table"] for e in doc["table_entries"][2:]]
        self.assertEqual(tables, ["MyIngress.process_int_source_sink.tb_set_source",
                                  INT_TABLE])
        self.assertEqual(doc["table_entries"][3]["priority"], P0)
        # Everything else in the file is the app's.
        self.assertEqual(doc["p4info"], "build/app.p4.p4info.txt")

    def test_the_other_switch_keeps_its_file_byte_for_byte(self):
        _package, out, _written, _report = self.thrift()
        with open(os.path.join(out, "topo/s2-runtime.json"), "rb") as a, \
                open(os.path.join(self.app, "topo/s2-runtime.json"), "rb") as b:
            self.assertEqual(a.read(), b.read())

    def test_the_script_is_carried_and_recorded(self):
        package, out, written, _report = self.thrift()
        self.assertIn("runtime_cmds/s1.sh", written)
        self.assertTrue(os.path.isfile(os.path.join(out, "runtime_cmds/s1.sh")))
        self.assertEqual(package["source"]["thrift_commands"], {"s1": "runtime_cmds/s1.sh"})

    def test_the_report_counts_and_carries_the_notes(self):
        _package, _out, _written, report = self.thrift()
        self.assertEqual(report["1"]["translated"], 2)
        self.assertTrue(report["1"]["notes"])

    def test_without_the_flag_the_runtime_file_is_the_apps(self):
        package, out, _written = self.convert()
        self.assertNotIn("thrift_commands", package["source"])
        with open(os.path.join(out, "topo/s1-runtime.json"), "rb") as a, \
                open(os.path.join(self.app, "topo/s1-runtime.json"), "rb") as b:
            self.assertEqual(a.read(), b.read())

    def test_a_switch_on_ndtwins_pipeline_is_refused(self):
        with self.assertRaises(convert.ConversionError) as caught:
            self.thrift(ndtwin_pipeline=True)
        self.assertIn("s1", str(caught.exception))

    def test_a_switch_the_topology_does_not_have_is_refused(self):
        with self.assertRaises(convert.ConversionError) as caught:
            self.thrift({"s9": "runtime_cmds/s1.sh"})
        self.assertIn("s9", str(caught.exception))

    def test_a_missing_script_is_refused(self):
        with self.assertRaises(convert.ConversionError):
            self.thrift({"s1": "runtime_cmds/nowhere.sh"})

    def test_a_table_the_runtime_file_already_writes_takes_the_translated_entries_too(self):
        # No ordering rule is invented between the two sets: bmv2 holds the CLI's own numbers
        # (2^31-1-c), so a P4Runtime entry of priority 10 is bmv2 2^31-11, and the CLI's 0 beats
        # it as it would natively. Both are kept, in file order.
        prior = {"table": INT_TABLE, "match": {"hdr.ipv4.src_addr": ["10.0.9.0", MASK24]},
                 "action_name": INT_ACTION,
                 "action_params": {"hop_metadata_len": 1, "remaining_hop_cnt": 1,
                                   "ins_mask0003": 1, "ins_mask0407": 1},
                 "priority": 10}
        self.write("topo/s1-runtime.json", json.dumps(runtime(extra=[prior]), indent=2))
        _package, out, _written, _report = self.thrift()
        doc = common.load_json(os.path.join(out, "topo/s1-runtime.json"))
        self.assertEqual([e.get("priority") for e in doc["table_entries"]
                          if e["table"] == INT_TABLE], [10, P0])

    def test_a_script_outside_the_app_directory_is_refused(self):
        with open(os.path.join(self.tmp, "elsewhere.sh"), "w") as fh:
            fh.write(SCRIPT)
        with self.assertRaises(convert.ConversionError) as caught:
            self.thrift({"s1": "../elsewhere.sh"})
        self.assertIn("outside", str(caught.exception))

    def test_a_script_symlinked_out_of_the_app_directory_is_refused(self):
        with open(os.path.join(self.tmp, "elsewhere.sh"), "w") as fh:
            fh.write(SCRIPT)
        os.symlink(os.path.join(self.tmp, "elsewhere.sh"), os.path.join(self.app, "link.sh"))
        with self.assertRaises(convert.ConversionError) as caught:
            self.thrift({"s1": "link.sh"})
        self.assertIn("outside", str(caught.exception))

    def test_a_script_named_through_dotdot_is_written_inside_the_package(self):
        # app at <tmp>/src/app, package at <tmp>/pkgs/A: `../app/...` resolves inside the app,
        # and the copy must land at the package path of that file, not at <tmp>/pkgs/app/...
        src = os.path.join(self.tmp, "src")
        os.makedirs(src)
        shutil.move(self.app, os.path.join(src, "app"))
        self.app = os.path.join(src, "app")
        out = os.path.join(self.tmp, "pkgs", "A")
        package, _model, written = convert.convert(
            self.app, "topo/topology.json", out, p4_rel="app.p4",
            thrift_commands={"s1": "../app/runtime_cmds/s1.sh"})
        self.assertIn("runtime_cmds/s1.sh", written)
        self.assertFalse([w for w in written if w.startswith("..")], written)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "pkgs", "app")))
        self.assertEqual(package["source"]["thrift_commands"], {"s1": "runtime_cmds/s1.sh"})

    def test_a_runtime_file_two_switches_spell_differently_is_refused(self):
        topo = json.loads(json.dumps(TOPOLOGY))
        topo["switches"]["s2"]["runtime_json"] = "./topo/s1-runtime.json"
        self.write("topo/topology.json", json.dumps(topo, indent=2))
        with self.assertRaises(convert.ConversionError) as caught:
            self.thrift()
        self.assertIn("s2", str(caught.exception))

    def test_a_runtime_file_two_switches_share_is_refused(self):
        topo = json.loads(json.dumps(TOPOLOGY))
        topo["switches"]["s2"]["runtime_json"] = "topo/s1-runtime.json"
        self.write("topo/topology.json", json.dumps(topo, indent=2))
        with self.assertRaises(convert.ConversionError) as caught:
            self.thrift()
        message = str(caught.exception)
        self.assertIn("s1", message)
        self.assertIn("s2", message)

    def test_an_external_control_plane_is_refused(self):
        self.write("mycontroller.py", "# an app's own controller\n")
        with self.assertRaises(convert.ConversionError) as caught:
            self.thrift()
        self.assertIn("external", str(caught.exception))

    def test_an_untranslatable_command_is_a_conversion_refusal_naming_the_file(self):
        self.write("runtime_cmds/s1.sh", "#!/bin/bash\nsimple_switch_CLI <<< \"mirroring_add 1 2\"\n")
        with self.assertRaises(convert.ConversionError) as caught:
            self.thrift()
        self.assertIn("runtime_cmds/s1.sh", str(caught.exception))

    def test_the_route_role_keeps_the_translated_entries(self):
        role = convert.parse_role_flag(
            "owner=ndtwin,table=MyIngress.FwdIngress.ipv4_lpm,match_field=hdr.ipv4.dst_addr,"
            "action=MyIngress.FwdIngress.ipv4_forward,dst_mac=dst_addr,port=port")
        _package, out, _written, _report = self.thrift(role_ipv4_route=role)
        doc = common.load_json(os.path.join(out, "topo/s1-runtime.json"))
        tables = [e["table"] for e in doc["table_entries"] if not e.get("default_action")]
        self.assertEqual(tables, ["MyIngress.process_int_source_sink.tb_set_source",
                                  INT_TABLE])

    def test_the_flag_is_switch_equals_path_and_each_switch_once(self):
        self.assertEqual(convert.parse_thrift_flags(["s1=a.sh", "s2=b.txt"]),
                         {"s1": "a.sh", "s2": "b.txt"})
        for bad in (["s1"], ["s1=a.sh", "s1=b.sh"], ["=a.sh"], ["s1="]):
            with self.subTest(flags=bad):
                with self.assertRaises(convert.ConversionError):
                    convert.parse_thrift_flags(bad)

    def test_the_command_line_prints_each_translation_note(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = convert.main([self.app, "--topology", "topo/topology.json", "--p4", "app.p4",
                               "--out", os.path.join(self.tmp, "cli"),
                               "--thrift-commands", "s1=runtime_cmds/s1.sh"])
        self.assertEqual(rc, 0)
        text = out.getvalue()
        self.assertIn("s1: 2 entries from runtime_cmds/s1.sh", text)
        self.assertIn("10.0.1.0", text)
        self.assertIn("omitted", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
