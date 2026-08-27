#!/usr/bin/env python3
"""Mutation gate for read_egress_counter. [Co-developed with claude code -- Adam]

Records WHICH tests go red, not how many. A mutation that turns one test red is not evidence the
gate works if the red one belongs to a different behaviour -- the count is not the identity.

Guards its own baseline: refuses to run if the file already differs from HEAD, because an
interrupted earlier run leaves a mutant on disk and that mutant gets measured as the baseline.
"""
import subprocess
import sys

SRC = "p4_proxy/proxy_agent/p4_client.py"
TEST = "tests.test_p4_client_writes.EgressCounterTest"
PY = "./venv/bin/python3"

MUTANTS = [
    ("M1 missing counter -> 0,0 again", '''            raise CounterNotFound(
                "counter %r is not in this pipeline's P4Info (%d counters present). This is a "
                "wiring or pipeline-version error, not a measurement of zero."
                % (name, len(self.p4info.counters)))''', "            return 0, 0"),
    ("M2 read failure -> 0,0 again",
     '''            logging.warning("egress counter read failed for port %s: %s -- reporting no sample, "
                            "not zero", port, e)
            return None''', "            return 0, 0"),
    ("M3 empty read -> 0,0 again",
     '''        logging.warning("egress counter read for port %s returned no counter_entry -- reporting "
                        "no sample, not zero", port)
        return None''', "        return 0, 0"),
    ("M4 falsy id check restored", "        if counter_id is None:", "        if not counter_id:"),
    ("M5 genuine zero suppressed",
     "                        return data.byte_count, data.packet_count",
     "                        return None"),
]


def failing_tests():
    r = subprocess.run([PY, "-m", "unittest", TEST, "-v"],
                       capture_output=True, text=True, cwd="p4_proxy")
    names = set()
    for line in r.stderr.splitlines():
        if line.startswith(("FAIL:", "ERROR:")):
            names.add(line.split()[1])
    return names, r.returncode


def main():
    diff = subprocess.run(["git", "diff", "--quiet", "HEAD", "--", SRC]).returncode
    if diff != 0:
        sys.exit("BASELINE DIRTY: %s differs from HEAD. Refusing -- an interrupted run's mutant "
                 "would be measured as the baseline." % SRC)

    base_names, rc = failing_tests()
    if rc != 0 or base_names:
        sys.exit("BASELINE RED: %s" % (base_names or rc))
    print("baseline: all green\n")

    original = open(SRC).read()
    survived = []
    try:
        for label, old, new in MUTANTS:
            if old not in original:
                sys.exit("mutation %r does not match the source -- the gate is stale" % label)
            open(SRC, "w").write(original.replace(old, new, 1))
            names, _ = failing_tests()
            print("%-32s -> %d red: %s" % (label, len(names),
                                           ", ".join(sorted(n.split("(")[0] for n in names)) or "NONE"))
            if not names:
                survived.append(label)
    finally:
        open(SRC, "w").write(original)

    after, rc = failing_tests()
    print("\nrestored: %s" % ("all green" if not after and rc == 0 else "STILL RED %s" % after))
    if survived:
        sys.exit("\nSURVIVORS (tests cannot see these): %s" % survived)
    print("GATE PASS: every mutation was caught")


main()

# Run from the repo root:  python3 p4_proxy/tests/mutate_egress_counter.py
#
# Result on 2026-08-27 (the run this was written for) -- note the IDENTITIES, not the counts:
#
#   M1 missing counter -> 0,0 again  -> 2 red: ..._p4info_without_the_counter_raises...,
#                                              ..._an_unknown_counter_name_raises_and_never_returns_zero
#   M2 read failure -> 0,0 again     -> 1 red: ..._a_read_failure_reports_no_sample_rather_than_zero
#   M3 empty read -> 0,0 again       -> 1 red: ..._a_read_that_returns_no_entry_reports_no_sample
#   M4 falsy id check restored       -> 1 red: ..._a_counter_whose_id_is_zero_is_found
#   M5 genuine zero suppressed       -> 3 red: ..._id_is_zero_is_found, ..._genuine_zero_is_still_zero,
#                                              ..._bytes_come_back_before_packets
#   restored: all green -- GATE PASS
#
# Each mutation's red tests belong to the behaviour it broke. That correspondence is the check;
# a mutation caught by an unrelated test would mean the gate reports a colour, not a fact.
