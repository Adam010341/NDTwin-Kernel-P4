#!/usr/bin/env python3
"""Tests for manifest.py against the switch manifest the lab REALLY writes.

[Co-developed with claude code -- Adam]

🔴 THE FIXTURE IS THE REAL FILE, verbatim. tests/fixtures/ndtwin_p4_switches.real.json is a copy
of the /tmp/ndtwin_p4_switches.json that the 2026-09-19 17:31 campaign produced. The offline
stub used to write a manifest whose `argv` was a LIST, which is the shape run_group_arm.sh
assumed -- so the suite was green while the arm script could never have worked against the lab.
A fixture that agrees with the code's assumption proves nothing about the world; that is the
same lesson as M-E10 and M-E19, in the place where it cost a whole campaign start. (Ruling 27.)
"""
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import manifest                                      # noqa: E402

REAL = os.path.join(HERE, "fixtures", "ndtwin_p4_switches.real.json")


class RealManifestTest(unittest.TestCase):
    def setUp(self):
        with open(REAL) as fh:
            self.data = json.load(fh)

    def test_the_fixture_really_is_the_shape_that_broke_it(self):
        # If this ever stops being true the test below is testing nothing.
        self.assertEqual(sorted(self.data)[0], "s1")
        self.assertIsInstance(self.data["s1"]["argv"], str)
        self.assertIn("simple_switch_grpc", self.data["s1"]["argv"])

    def test_the_binary_is_found_in_a_string_argv(self):
        # 🔴 The whole of ruling 27. Iterating that string yields characters, and the old reader
        # returned nothing -- which the arm script turned into "this arm cannot name what it
        # measured", on an arm that had already measured a confirmed 30 kpps ceiling.
        self.assertEqual(manifest.switch_binary(self.data),
                         "/usr/local/bmv2-fast/bin/simple_switch_grpc")

    def test_the_LD_LIBRARY_PATH_prefix_is_not_mistaken_for_the_binary(self):
        tokens = manifest.argv_tokens(self.data["s1"]["argv"])
        self.assertTrue(tokens[0].startswith("LD_LIBRARY_PATH="))
        self.assertEqual(os.path.basename(manifest.switch_binary(self.data)),
                         "simple_switch_grpc")

    def test_a_list_argv_still_works(self):
        # The point is to accept the shape that exists, not to swap one assumption for another.
        listed = {"s1": {"pid": 5, "device_id": 1,
                         "argv": ["/usr/local/bmv2-fast/bin/simple_switch_grpc", "-i", "1@s1-eth1"]}}
        self.assertEqual(manifest.switch_binary(listed),
                         "/usr/local/bmv2-fast/bin/simple_switch_grpc")

    def test_an_argument_that_merely_contains_the_word_is_not_the_binary(self):
        tricky = {"s1": {"pid": 5, "argv": "env --log-file /tmp/simple_switch.log /opt/x/simple_switch_grpc -i 1@e"}}
        self.assertEqual(manifest.switch_binary(tricky), "/opt/x/simple_switch_grpc")

    def test_every_switch_gives_a_pid_and_its_device_id(self):
        rows = manifest.switch_rows(self.data)
        self.assertEqual(len(rows), 10)
        self.assertEqual(sorted(label for _pid, label in rows),
                         sorted(str(n) for n in range(1, 11)))
        for pid, _label in rows:
            self.assertIsInstance(pid, int)
            self.assertGreater(pid, 0)

    def test_the_keys_this_round_reads_are_the_manifest_s_own(self):
        # thrift_port / grpc_port / log_file are not read by these scripts, but they are checked
        # here so that "we looked" is on the record rather than assumed a second time.
        for name, entry in self.data.items():
            self.assertEqual(sorted(entry),
                             ["argv", "device_id", "grpc_port", "log_file", "pid", "thrift_port"],
                             name)
            self.assertIsInstance(entry["pid"], int)
            self.assertIsInstance(entry["device_id"], int)
            self.assertIsInstance(entry["log_file"], str)

    def test_a_missing_or_broken_manifest_is_empty_not_a_crash(self):
        self.assertEqual(manifest.load("/nonexistent-manifest.json"), {})
        self.assertIsNone(manifest.switch_binary({}))
        self.assertEqual(manifest.switch_rows({}), [])


if __name__ == "__main__":
    unittest.main()
