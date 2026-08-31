#!/usr/bin/env python3
"""Search a disk image for an exact byte signature.

`rm` unlinks, it does not overwrite, so "the file is deleted" and "the bytes are gone"
are different claims and only the second one matters for something about to be published.
This searches for 64 bytes taken from the middle of the git packfile before it was
deleted.

grep is the wrong tool here: the needle is arbitrary binary and may contain NUL or
newline, which grep -F cannot carry through a pattern file reliably. Chunked read with
an overlap of len(needle)-1 so a match straddling a chunk boundary is not missed -- the
bug that would make this report a clean image no matter what it contained.

Run it against a POSITIVE CONTROL first. A search that returns zero because it is broken
looks exactly like a search that returns zero because the data is gone.

[Co-developed with claude code -- Adam]
"""
import base64
import sys

CHUNK = 64 << 20


def scan(path: str, needle: bytes) -> list:
    hits = []
    overlap = len(needle) - 1
    tail = b""
    base = 0
    with open(path, "rb") as fh:
        while True:
            buf = fh.read(CHUNK)
            if not buf:
                break
            hay = tail + buf
            start = 0
            while True:
                i = hay.find(needle, start)
                if i < 0:
                    break
                hits.append(base - len(tail) + i)
                start = i + 1
            base += len(buf)
            tail = hay[-overlap:] if overlap else b""
    return hits


if __name__ == "__main__":
    needle = base64.b64decode(sys.argv[1])
    print(f"needle: {len(needle)} bytes")
    for path in sys.argv[2:]:
        try:
            hits = scan(path, needle)
        except OSError as exc:
            print(f"  {path}: ERROR {exc}")
            continue
        verdict = "FOUND" if hits else "absent"
        where = f" at {hits[:3]}" if hits else ""
        print(f"  {path}: {verdict} ({len(hits)} hit(s)){where}")
