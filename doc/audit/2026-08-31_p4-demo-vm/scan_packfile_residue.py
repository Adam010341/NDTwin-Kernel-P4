#!/usr/bin/env python3
"""Is any of the deleted git packfile still recoverable from the rebuilt image?

The samples are read from fixed FRACTIONS OF THE PACKFILE, taken inside the guest while
the file still existed. The earlier attempt sampled a qcow2 at offsets near a confirmed
hit and one of those windows turned out to be apt package metadata -- a qcow2 offset does
not stay inside one file, so "bytes near the packfile" is not "packfile bytes". This
version cannot make that mistake.

Every sample is checked against the image that still contains the packfile first. A
sample missing from its own source is a broken sample, and its absence from the target
would mean nothing.

[Co-developed with claude code -- Adam]
"""
import base64
import sys

CHUNK = 64 << 20


def scan(path, needles):
    found = {name: [] for name, _ in needles}
    overlap = max(len(n) for _, n in needles) - 1
    tail, base = b"", 0
    with open(path, "rb") as fh:
        while True:
            buf = fh.read(CHUNK)
            if not buf:
                break
            hay = tail + buf
            for name, needle in needles:
                start = 0
                while True:
                    j = hay.find(needle, start)
                    if j < 0:
                        break
                    found[name].append(base - len(tail) + j)
                    start = j + 1
            base += len(buf)
            tail = hay[-overlap:] if overlap else b""
    return found


if __name__ == "__main__":
    # 🔴 BEFORE YOU REUSE THIS ON A DIFFERENT IMAGE, READ THIS.
    #
    # The needles are bytes of ONE SPECIFIC packfile. They are not a test for "does this
    # image contain a git repository with the poster package" -- they are a test for "does
    # this image contain THAT packfile". Point it at an image holding a different repository
    # and every needle misses, the script prints CLEAN, and the output is indistinguishable
    # from a true negative.
    #
    # This nearly happened: the same day this script was written and validated (control
    # 12/12, product 11/11 gone), it was the obvious tool to check a second image -- which
    # carried NDTwin-Kernel, not NDTwin-Kernel-P4. Different packfile, guaranteed false
    # negative. That image was checked with `git rev-list --objects --all` instead.
    #
    # 🔑 A method's positive control does not transfer with the method to a new subject.
    # Recent success is exactly when a tool is hardest to put down.
    #
    # Use this script only when the target is known to descend from the same repository the
    # samples came from -- e.g. snapshots or copies of one lineage. Otherwise enumerate the
    # objects, and give that search its own control.
    samples_file, control, targets = sys.argv[1], sys.argv[2], sys.argv[3:]
    needles = []
    for line in open(samples_file):
        parts = line.split()
        if len(parts) == 3 and parts[0].isdigit():
            needles.append((f"pack@{parts[0]}%", base64.b64decode(parts[2])))
    needles.append((
        "packed-refs",
        base64.b64decode(
            "IyBwYWNrLXJlZnMgd2l0aDogcGVlbGVkIGZ1bGx5LXBlZWxlZCBzb3J0ZWQgCjgwMzQ3ODNmMzk2NGIzNjRmNA=="
        ),
    ))
    print(f"{len(needles)} needles\n")

    print(f"=== CONTROL {control} (still contains .git) ===")
    res = scan(control, needles)
    usable = [n for n, _ in needles if res[n]]
    for name, _ in needles:
        print(f"  {name:14s} {'FOUND' if res[name] else '❌ MISSING -- sample unusable'}")
    print(f"  usable samples: {len(usable)}/{len(needles)}")

    for t in targets:
        print(f"\n=== TARGET {t} ===")
        res = scan(t, needles)
        surv = [n for n in usable if res[n]]
        for name in usable:
            if res[name]:
                print(f"  🔴 {name:14s} SURVIVES at {res[name][:3]}")
        print(f"  {len(surv)}/{len(usable)} usable samples survive")
        print("  VERDICT: " + ("CLEAN" if not surv else "RESIDUE PRESENT"))
