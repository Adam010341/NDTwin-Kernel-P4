"""The code a lab run executes, copied into the run dir and checked against HEAD. (Cut 2 reviews: N8, round 4 F4)

[Co-developed with claude code -- Adam]

A lab run runs probe code in three places: root, inside the hosts' namespaces (hostside.py and what it
imports); the caller, as B's controller (controller_ext.py, which imports frames); and the caller again,
through the adapter that rewrites the controller's addresses onto the fabric
(tools/p4_exercise/run_external_controller.py, which imports common). The working tree can change under
a 15-minute run, and `probe.py lab` checked it clean only once, so:

  * `freeze` copies every one of those files into <run>/frozen/ right after the dirty check, BEFORE
    S0, and every round then executes the copy, never the shared tree;
  * each copy is checked against HEAD -- `git hash-object <copy>` must equal `git rev-parse
    HEAD:<path>` -- so an edit made between the dirty check and the copy is refused (Refused), and
    what runs is what the commit says, not merely what the tree held a moment ago;
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
    def __init__(self, base, sums):
        self.base = base                    # <run>/frozen
        self.sums = sums                    # {"p4_health/hostside.py": sha256, ...}

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


def freeze(run_dir, repo=None, git=None):
    """Copy the files into <run>/frozen/ and return a Frozen. `git(*args) -> (rc, stdout)`, when
    given, must confirm every copy against HEAD, else Refused (git that cannot answer is a
    refusal, not a pass). With git=None nothing is compared: only the offline tests do that, and
    `probe.py lab` always passes git."""
    repo = repo or REPO
    base = os.path.join(os.path.realpath(run_dir), DIRNAME)      # resolved, like the package path
    sums = {}
    for rel in ROOT_FILES + B_FILES:
        dst = os.path.join(base, rel)
        try:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(os.path.join(repo, "tools", rel), dst)
            with open(dst, "rb") as fh:
                sums[rel] = hashlib.sha256(fh.read()).hexdigest()
        except OSError as exc:
            raise Refused("cannot copy tools/%s: %s" % (rel, exc))
        if git is not None:
            h_rc, h = git("hash-object", dst)
            b_rc, blob = git("rev-parse", "HEAD:tools/%s" % rel)
            if h_rc != 0 or b_rc != 0 or not h or not blob:
                raise Refused("git could not say whether tools/%s is what HEAD has (hash-object rc %s, "
                              "rev-parse rc %s)" % (rel, h_rc, b_rc))
            if h != blob:
                raise Refused("tools/%s is not what HEAD has: the copy hashes to %s, HEAD's blob is %s "
                              "(edited since the clean check?)" % (rel, h, blob))
    return Frozen(base, sums)
