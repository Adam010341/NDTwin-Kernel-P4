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
  * the sha256 of every copy goes into health.json, root's three files also as `root_code`;
  * (round 6) S0's copy of tools/p4_health/exercise/ -- the model every expectation, the controller trial and
    lab.load_model go by -- is checked the same way against the pinned commit (Frozen.check_exercise, right
    after S0's compile_all): a file that differs, is missing or is not in the commit is refused.
  * (round 7) and once more immediately before lab.load_model runs gen_runtime.py from it: in between, S0 hands the
    copy to convert.py as its input, and the check is what shows that convert.py did not write into it.
"""
from __future__ import annotations

import fnmatch
import hashlib
import os
import shutil

from .collect.config import REPO

#: paths relative to <repo>/tools; the directory they are copied into, <run>/frozen/
ROOT_FILES = ("p4_health/hostside.py", "p4_health/frames.py", "p4_health/__init__.py")
B_FILES = ("p4_health/controller_ext.py",
           "p4_exercise/run_external_controller.py", "p4_exercise/common.py", "p4_exercise/__init__.py")
DIRNAME = "frozen"
#: (round 6) the tree S0 copies into <run>/exercise/, and what that copy leaves out: bytecode and the p4c output
#: directories (build, build-mutant, build-fwd) S0 creates beside the sources. s0.compile_all uses the same patterns.
EXERCISE_REL = "tools/p4_health/exercise"
COPY_IGNORE = ("__pycache__", "build*")


class Refused(RuntimeError):
    """The code to be run cannot be shown to be what HEAD says; no lab action follows."""


class Frozen(object):
    def __init__(self, base, sums, head=None, git=None):
        self.base = base                    # <run>/frozen
        self.sums = sums                    # {"p4_health/hostside.py": sha256, ...}
        self.head = head                    # the commit every copy was checked against, or None (unchecked)
        self.git = git                      # git(*args) -> (rc, stdout) that pinned it, for later checks

    def check_exercise(self, copy_dir):
        """Refused unless `copy_dir` -- S0's copy of tools/p4_health/exercise -- is exactly what the pinned
        commit has there (see check_tree)."""
        check_tree(copy_dir, EXERCISE_REL, self.head, self.git)

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


def _ignored(rel):
    """True when s0's copytree would have left `rel` (a path relative to the copied tree) out."""
    return any(fnmatch.fnmatch(part, pat) for part in rel.split("/") for pat in COPY_IGNORE)


def check_tree(copy_dir, rel_dir, head, git):
    """(round 6) The files under `copy_dir` must be exactly the files the commit `head` has under `rel_dir`
    (less what the copy leaves out, COPY_IGNORE), each byte-identical to the commit's blob: `git hash-object
    --no-filters <file>` against the blob `git ls-tree` names, the freeze's own comparison. A file that
    differs, one the commit does not have, one the commit has and the copy lacks, a link, an entry that is not a
    plain file, and git that cannot answer are all Refused."""
    if git is None or not head:
        raise Refused("cannot check %s against the commit: no pinned commit (or no git) to check it with" % copy_dir)
    rc, listing = git("ls-tree", "-r", "-z", "--full-tree", head, "--", rel_dir)
    if rc != 0 or not listing:
        raise Refused("git could not list %s at %s (ls-tree rc %s)" % (rel_dir, head, rc))
    committed = {}
    for entry in listing.split("\0"):
        if not entry:
            continue
        meta, _tab, path = entry.partition("\t")
        fields = meta.split()
        rel = path[len(rel_dir) + 1:]
        if len(fields) != 3 or not path.startswith(rel_dir + "/"):
            raise Refused("git ls-tree gave an entry this check cannot read: %r" % (entry,))
        if _ignored(rel):
            continue
        if fields[0] not in ("100644", "100755") or fields[1] != "blob":
            raise Refused("%s/%s is not a plain file in %s (mode %s, %s)" % (rel_dir, rel, head, fields[0], fields[1]))
        committed[rel] = fields[2]
    found = {}
    for dirpath, dirs, files in os.walk(copy_dir):
        dirs[:] = [d for d in dirs if not _ignored(d)]
        for name in files:
            if _ignored(name):
                continue
            full = os.path.join(dirpath, name)
            found[os.path.relpath(full, copy_dir).replace(os.sep, "/")] = full
        for d in dirs:
            if os.path.islink(os.path.join(dirpath, d)):
                raise Refused("%s is a link: not what %s has" % (os.path.join(dirpath, d), head))
    extra, missing = sorted(set(found) - set(committed)), sorted(set(committed) - set(found))
    if extra or missing:
        raise Refused("the copy of %s is not what %s has (not in the commit: %s; missing from the copy: %s)"
                      % (rel_dir, head, ", ".join(extra) or "-", ", ".join(missing) or "-"))
    for rel in sorted(found):
        if os.path.islink(found[rel]):
            raise Refused("%s/%s is a link in the copy: not what %s has" % (rel_dir, rel, head))
        h_rc, h = git("hash-object", "--no-filters", found[rel])
        if h_rc != 0 or not h:
            raise Refused("git could not hash %s (rc %s)" % (found[rel], h_rc))
        if h != committed[rel]:
            raise Refused("%s/%s is not what %s has: the copy hashes to %s, the commit's blob is %s "
                          "(edited since the clean check?)" % (rel_dir, rel, head, h, committed[rel]))


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
    return Frozen(base, sums, head, git)
