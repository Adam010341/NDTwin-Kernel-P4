"""The code a lab run executes, copied into the run dir and checked against HEAD. (Cut 2 reviews: N8, round 4 F4)

[Co-developed with claude code -- Adam]

A lab run runs probe code in three places: root, inside the hosts' namespaces (hostside.py and what it
imports); the caller, as B's controller (controller_ext.py, which imports frames); and the caller again,
through the adapter that rewrites the controller's addresses onto the fabric
(tools/p4_exercise/run_external_controller.py, which imports common). The working tree can change under
a 15-minute run, and `probe.py lab` checked it clean only once, so:

  * `freeze` copies every one of those files into <run>/frozen/ right after the dirty check, BEFORE
    S0, and every round then executes the copy, never the shared tree;
  * each copy is checked against HEAD -- `git hash-object --no-filters <copy>` must equal `git
    rev-parse <sha>:<path>` -- so an edit made between the dirty check and the copy is refused
    (Refused), and what runs is what the commit says, not merely what the tree held a moment ago;
  * (round 5) HEAD is resolved ONCE (`git rev-parse --verify HEAD`) and every blob is asked for by
    that sha, so a commit landing in the middle of the freeze cannot give a set that matches no single
    commit; the sha is kept (Frozen.head) and goes into health.json and the run's identity;
  * (round 5) the bytes are hashed as they are (--no-filters: a run dir inside the repo is a path
    git's attributes may select input filters for, which would make a copy with other line endings
    hash to the blob it is not);
  * (round 5) the freeze only ever writes what is new: <run>/frozen must not exist, directories are
    made with mkdir (no exist_ok) and files opened O_CREAT|O_EXCL|O_NOFOLLOW, so a link planted at a
    destination is refused, not written through, and an earlier run's evidence is not replaced;
  * the sha256 of every copy goes into health.json, root's three files also as `root_code`.
"""
from __future__ import annotations

import hashlib
import os
import shutil

from .collect.config import REPO

#: paths relative to <repo>/tools; the directory they are copied into, <run>/frozen/
ROOT_FILES = ("p4_health/hostside.py", "p4_health/frames.py", "p4_health/__init__.py")
B_FILES = ("p4_health/controller_ext.py",
           "p4_exercise/run_external_controller.py", "p4_exercise/common.py", "p4_exercise/__init__.py")
DIRNAME = "frozen"


class Refused(RuntimeError):
    """The code to be run cannot be shown to be what HEAD says; no lab action follows."""


class Frozen(object):
    def __init__(self, base, sums, head=None):
        self.base = base                    # <run>/frozen
        self.sums = sums                    # {"p4_health/hostside.py": sha256, ...}
        self.head = head                    # the commit every copy was checked against, or None (unchecked)

    def path(self, rel):
        return os.path.join(self.base, rel)

    @property
    def hostside(self):
        return self.path("p4_health/hostside.py")

    @property
    def controller(self):
        return self.path("p4_health/controller_ext.py")

    @property
    def adapter(self):
        return self.path("p4_exercise/run_external_controller.py")

    @property
    def root_code(self):
        return {os.path.basename(r): self.sums[r] for r in ROOT_FILES}


def copy_file(src, dst):
    """Copy src to a NEW file dst: O_CREAT|O_EXCL|O_NOFOLLOW, so a destination that exists -- a link
    included, dangling or not -- is an error (FileExistsError / OSError), never written through."""
    fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644)
    with os.fdopen(fd, "wb") as out, open(src, "rb") as inp:
        shutil.copyfileobj(inp, out)


def freeze(run_dir, repo=None, git=None):
    """Copy the files into <run>/frozen/ and return a Frozen. `git(*args) -> (rc, stdout)`, when
    given, must confirm every copy against one pinned HEAD, else Refused (git that cannot answer is a
    refusal, not a pass). With git=None nothing is compared: only the offline tests do that, and
    `probe.py lab` always passes git. <run>/frozen must not exist yet."""
    repo = repo or REPO
    base = os.path.join(os.path.realpath(run_dir), DIRNAME)      # resolved, like the package path
    if os.path.lexists(base):
        raise Refused("%s already exists: a freeze writes only what is new (a reused run dir would lose "
                      "the earlier run's copies, and a link there would be followed)" % base)
    head = None
    if git is not None:
        h_rc, head = git("rev-parse", "--verify", "HEAD")
        if h_rc != 0 or not head:
            raise Refused("git could not name HEAD (rev-parse rc %s)" % (h_rc,))
    sums = {}
    made = set()
    try:
        os.makedirs(os.path.dirname(base), exist_ok=True)
        os.mkdir(base)
    except OSError as exc:
        raise Refused("cannot create %s: %s" % (base, exc))
    for rel in ROOT_FILES + B_FILES:
        dst = os.path.join(base, rel)
        try:
            sub = os.path.dirname(dst)
            if sub not in made:
                os.mkdir(sub)
                made.add(sub)
            copy_file(os.path.join(repo, "tools", rel), dst)
            with open(dst, "rb") as fh:
                sums[rel] = hashlib.sha256(fh.read()).hexdigest()
        except OSError as exc:
            raise Refused("cannot copy tools/%s: %s" % (rel, exc))
        if git is not None:
            h_rc, h = git("hash-object", "--no-filters", dst)
            b_rc, blob = git("rev-parse", "%s:tools/%s" % (head, rel))
            if h_rc != 0 or b_rc != 0 or not h or not blob:
                raise Refused("git could not say whether tools/%s is what %s has (hash-object rc %s, "
                              "rev-parse rc %s)" % (rel, head, h_rc, b_rc))
            if h != blob:
                raise Refused("tools/%s is not what %s has: the copy hashes to %s, the commit's blob is %s "
                              "(edited since the clean check?)" % (rel, head, h, blob))
    return Frozen(base, sums, head)
