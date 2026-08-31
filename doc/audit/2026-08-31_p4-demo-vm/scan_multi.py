#!/usr/bin/env python3
"""Search a disk image for many byte signatures in ONE pass.

Sampling one 64-byte window from a 121 MB packfile and finding it gone proves that
window is gone. It does not prove the packfile is gone -- fstrim discards at block
granularity and an untrimmed extent would leave whole regions intact. So: take samples
spread across the region, and require ALL of them to be absent.

Needles are read from the image that still contains the data, at offsets around a
confirmed hit, which makes them real packfile bytes rather than guesses. Each needle is
checked against the source too: a needle that is not found in its own source is a broken
sample, and its absence elsewhere means nothing.

Chunked with overlap so a match on a chunk boundary is still found.

[Co-developed with claude code -- Adam]
"""
import sys

CHUNK = 64 << 20


def harvest(path: str, centre: int, count: int, step: int, size: int) -> list:
    """Pull `count` windows of `size` bytes, spaced `step` apart, around `centre`."""
    out = []
    with open(path, "rb") as fh:
        for k in range(count):
            off = centre + (k - count // 2) * step
            if off < 0:
                continue
            fh.seek(off)
            buf = fh.read(size)
            if len(buf) == size and len(set(buf)) > 8:  # skip runs of zeros/padding
                out.append((off, buf))
    return out


def scan(path: str, needles: list) -> dict:
    found = {i: [] for i in range(len(needles))}
    overlap = max(len(n) for _, n in needles) - 1
    tail = b""
    base = 0
    with open(path, "rb") as fh:
        while True:
            buf = fh.read(CHUNK)
            if not buf:
                break
            hay = tail + buf
            for i, (_, needle) in enumerate(needles):
                start = 0
                while True:
                    j = hay.find(needle, start)
                    if j < 0:
                        break
                    found[i].append(base - len(tail) + j)
                    start = j + 1
            base += len(buf)
            tail = hay[-overlap:] if overlap else b""
    return found


if __name__ == "__main__":
    source, centre, targets = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
    needles = harvest(source, centre, 11, 4 << 20, 64)
    print(f"harvested {len(needles)} x 64-byte samples from {source} around {centre}")

    print(f"\n=== CONTROL: are they present in their own source? ===")
    res = scan(source, needles)
    ok = sum(1 for i in res if res[i])
    for i, (off, _) in enumerate(needles):
        print(f"  sample@{off}: {'FOUND' if res[i] else 'MISSING -- broken sample'}")
    print(f"  control: {ok}/{len(needles)} usable")

    for t in targets:
        print(f"\n=== TARGET: {t} ===")
        res = scan(t, needles)
        hits = [i for i in res if res[i]]
        for i, (off, _) in enumerate(needles):
            if res[i]:
                print(f"  🔴 sample@{off}: FOUND at {res[i][:3]}")
        print(f"  {len(hits)}/{len(needles)} samples survive in {t}")
