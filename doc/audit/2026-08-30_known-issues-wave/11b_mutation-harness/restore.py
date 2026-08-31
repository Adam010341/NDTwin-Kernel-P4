#!/usr/bin/env python3
"""Atomic, sha256-verified restore from the pristine snapshot. git is not involved.

`git checkout -- <path>` restores from the INDEX, and this fix is unstaged, so that command
reverts to 1208d22 and deletes the fix. It did exactly that once during bring-up. Plain `cp`
is also unsafe here: the root filesystem is oscillating at 100% and a short write truncates
the destination in place. So: write a temp in the same directory, fsync, verify size AND
sha256, then os.replace.

Exit 0 only if every file on disk hashes to its recorded pristine sha256.
"""
import hashlib, os, sys, tempfile

S = "/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/258e9ef7-6035-4abb-b378-8b2ab1aa8200/scratchpad/mutrun"
W = "/home/adam/Desktop/NDTwin-Kernel/.claude/worktrees/agent-a2c2a6601f812a7eb"
MANIFEST = os.path.join(S, "pristine", "SHA256")


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def build_manifest():
    lines = []
    with open(os.path.join(S, "pristine", "HASHES")) as fh:
        for ln in fh:
            blob, rel, flat = ln.split()
            src = os.path.join(S, "pristine", flat)
            lines.append("%s %d %s %s" % (sha(src), os.path.getsize(src), rel, flat))
    with open(MANIFEST, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


def restore():
    bad = 0
    with open(MANIFEST) as fh:
        rows = [ln.split() for ln in fh if ln.strip()]
    for want_sha, want_size, rel, flat in rows:
        want_size = int(want_size)
        src = os.path.join(S, "pristine", flat)
        dst = os.path.join(W, rel)
        # the snapshot itself is on the same sick filesystem -- check it before trusting it
        if sha(src) != want_sha:
            print("PRISTINE-CORRUPT %s" % src)
            bad = 1
            continue
        # If the destination is ALREADY byte-identical, do not rewrite it. Rewriting bumps the
        # mtime and makes make recompile every dependent of these headers -- ~7 min a row for
        # no change in what is on disk. Verification below is unchanged; only the write is
        # skipped, and only when sha256 AND size already agree.
        if os.path.exists(dst) and os.path.getsize(dst) == want_size and sha(dst) == want_sha:
            continue
        with open(src, "rb") as f:
            data = f.read()
        d = os.path.dirname(dst)
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".rst_tmp_")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            if os.path.getsize(tmp) != want_size:
                raise IOError("short write %d != %d" % (os.path.getsize(tmp), want_size))
            if sha(tmp) != want_sha:
                raise IOError("sha mismatch in temp")
            os.replace(tmp, dst)
        except BaseException as ex:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            print("RESTORE-WRITE-FAILED %s: %s" % (rel, ex))
            bad = 1
            continue
        got = sha(dst)
        if got != want_sha or os.path.getsize(dst) != want_size:
            print("RESTORE-VERIFY-FAILED %s got=%s size=%d" % (rel, got[:12], os.path.getsize(dst)))
            bad = 1
    print("RESTORE-SHA256-OK" if not bad else "RESTORE-SHA256-BAD")
    return bad


if __name__ == "__main__":
    sys.exit(build_manifest() if sys.argv[1:] == ["manifest"] else restore())
