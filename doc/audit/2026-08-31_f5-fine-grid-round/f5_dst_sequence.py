#!/usr/bin/env python3
"""
f5_dst_sequence.py -- PREREG-F5 【TBD-1】: the install sequence, verbatim.

[Co-developed with claude code -- Adam]

WHAT THE REGISTRATION ASKS FOR.  §3: "N = 60 installs per arm (churn-driven and explicit POSTs
mixed; the sequence is frozen first: interleaved dst, no repeats)".  【TBD-1】 then names the dst
list itself as the thing still to be written down.

WHY A GENERATOR RATHER THAN A LITERAL LIST, AND WHY IT IS STILL "VERBATIM".
    There is no RNG here and no clock.  The sequence is a pure function of four values that live
    in round.env, so `--print` emits the identical 60 lines on every machine and every run, and
    those 60 lines are what goes in the registration.  A hand-typed list of 60 addresses would be
    the same thing with one extra way to be wrong.
    🔴 The run does NOT re-derive the order.  run_f5.sh writes the emitted list to the arm's raw
    directory before the first install and reads it back per install, so the sequence that ran is
    an artefact rather than a claim about what the code would have produced.

WHY THESE ADDRESSES.
    10.0.0.180-239 is clear of every host the round's fabrics actually have: the P4 and OVS
    4-host arms use 10.0.0.1-4, and even the 128-host topology stops at 10.0.0.128.  A rule
    matching a live host would compete with the mesh traffic the round runs on purpose; a rule
    matching nothing is still installed, still cached and still visible, which is the only
    property the phantom question needs.

WHY A STRIDE AND NOT 180, 181, 182, ...
    "Interleaved" is the registration's word.  Consecutive installs land 7 apart (7 is coprime
    with 60, so the walk visits all 60 exactly once), which means any effect that depends on
    address adjacency -- a longest-prefix-match neighbourhood, a cache line, a table region --
    is spread across the run instead of aligning with its start.  It also guarantees that the
    first and last installs are not neighbours, so drift over the arm cannot masquerade as an
    address effect.

NO REPEATS, ASSERTED.  A repeated dst would silently make the second install a modify rather than
an install, and a modify does not produce the cached row this round is looking for -- so the
arm would read as "fewer phantoms" for a reason that has nothing to do with T-11.
"""
import argparse
import os
import sys


def sequence(n, base, first_octet, stride):
    """The frozen order.  Pure: same inputs, same 60 lines, no RNG, no clock."""
    if first_octet + n - 1 > 254:
        raise SystemExit(f"REFUSE: {n} addresses from .{first_octet} would run past .254")
    from math import gcd
    if gcd(stride, n) != 1:
        raise SystemExit(
            f"REFUSE: stride {stride} is not coprime with n={n} (gcd={gcd(stride, n)}).\n"
            "        The walk would revisit addresses and skip others, so the sequence would\n"
            "        have repeats -- and a repeated dst turns an install into a modify.")
    return [f"{base}{first_octet + (i * stride) % n}" for i in range(n)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=int(os.environ.get("N_INSTALLS", 60)))
    ap.add_argument("--base", default=os.environ.get("DST_BASE", "10.0.0."))
    ap.add_argument("--first-octet", type=int, default=int(os.environ.get("DST_FIRST_OCTET", 180)))
    ap.add_argument("--stride", type=int, default=int(os.environ.get("DST_STRIDE", 7)))
    ap.add_argument("--print", dest="show", action="store_true",
                    help="emit the sequence, one dst per line, for the registration and for raw/")
    a = ap.parse_args()

    seq = sequence(a.n, a.base, a.first_octet, a.stride)

    # Assert the two properties the registration names, here, rather than trusting the arithmetic.
    # memory/injections-must-assert-their-own-success: the generator that quietly produced 59
    # distinct addresses would look exactly like the one that produced 60.
    if len(set(seq)) != a.n:
        raise SystemExit(f"REFUSE: {a.n - len(set(seq))} repeated address(es) in the sequence")
    if any(seq[i] == seq[i - 1] for i in range(1, len(seq))):
        raise SystemExit("REFUSE: adjacent duplicates in the sequence")

    if a.show:
        for d in seq:
            print(d)
    else:
        print(f"n={a.n} distinct={len(set(seq))} first={seq[0]} second={seq[1]} last={seq[-1]}")
        print(f"stride={a.stride} (coprime with {a.n}); range {a.base}{a.first_octet}"
              f"..{a.base}{a.first_octet + a.n - 1}")
        print("pass --print for the frozen list itself")
    return 0


if __name__ == "__main__":
    sys.exit(main())
