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
    copy to convert.py as its input, and the check is what shows that convert.py did not edit, add or remove a
    committed file of it.
  * (round 8) S0 execs that gen_runtime.py itself, first in its self-checks (self_checks -> selfcheck_run ->
    _switch_inputs) and later in the controller trial, both after convert.py and before run_lab's check, so S0.run
    checks the copy a third time right after packages().
  * (round 9) what the copy holds that the commit does not -- the p4c output directories compile_all writes
    (build, build-mutant, build-fwd) -- was outside every check. What compile_all's p4c runs wrote is recorded at
    the first check of the copy, which S0.run makes right after compile_all, and every later check refuses a file
    there that changed, appeared or went away since (Frozen.check_exercise). Nothing writes into the copy after
    compile_all. A __pycache__ is refused outright, at every check including the first: nothing writes one there,
    and a cached .pyc is what could run in place of the source that was checked. The record is kept under the
    copy's path as it was given (os.path.abspath), and a copy root that is itself a link is refused, so the same
    path cannot be re-pointed at another tree and recorded afresh.
  * (round 9) the copy's modules are compiled from the bytes of their source by load_source, never through the
    import system's loader, which takes a cached __pycache__/*.pyc in place of the source it was checked as.
"""
from __future__ import annotations

import fnmatch
import hashlib
import os
import shutil
import stat
import types

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
        #: (round 9) the path of an exercise copy as it was given to check_exercise (os.path.abspath, links not
        #: resolved) -> {path in it: sha256} of the build outputs it held beside the commit's files at its first check
        self.outputs = {}

    def check_exercise(self, copy_dir):
        """Refused unless `copy_dir` -- S0's copy of tools/p4_health/exercise -- is exactly what the pinned
        commit has there (see check_tree). (round 9) And what it holds outside the commit, the build outputs under
        the COPY_IGNORE paths (what compile_all's p4c runs wrote), is recorded at the first check of `copy_dir` and
        must be the same files with the same bytes at every later one: a file there that changed, appeared or went
        away since is Refused. S0.run makes the first check right after compile_all, the only step that writes there.
        (round 10) A __pycache__ is never recorded: it is Refused at every check, the first included. `copy_dir`
        itself must not be a link, and the record is keyed by its path as given (os.path.abspath, not realpath), so
        a link above it re-pointed at another tree between two checks is compared with the first check's record.
        [Co-developed with claude code -- Adam]"""
        if os.path.islink(copy_dir):
            raise Refused("%s is a link: the tree behind it is not the copy S0 made, and not what %s has"
                          % (copy_dir, self.head))
        outputs = check_tree(copy_dir, EXERCISE_REL, self.head, self.git)
        key = os.path.abspath(copy_dir)
        if key not in self.outputs:
            self.outputs[key] = outputs
            return
        first = self.outputs[key]
        if first != outputs:
            changed = sorted(r for r in set(first) & set(outputs) if first[r] != outputs[r])
            new, gone = sorted(set(outputs) - set(first)), sorted(set(first) - set(outputs))
            raise Refused("the copy of %s is not what it held outside %s at its first check (changed: %s; new: %s; "
                          "gone: %s)" % (EXERCISE_REL, self.head, ", ".join(changed) or "-", ", ".join(new) or "-",
                                         ", ".join(gone) or "-"))

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


def load_source(name, path):
    """(round 9) The module at `path`, named `name`, compiled from the bytes of that file and nothing else. The
    import system's loader (spec_from_file_location + exec_module) takes a __pycache__/*.pyc beside the source in
    its place when the .pyc's header says it may, so what ran need not be the source a check looked at. No
    bytecode cache is read or written here. Like that loader's module, this one is not put in sys.modules.
    [Co-developed with claude code -- Adam]"""
    with open(path, "rb") as fh:
        source = fh.read()
    mod = types.ModuleType(name)
    mod.__file__ = path
    exec(compile(source, path, "exec", dont_inherit=True), mod.__dict__)
    return mod


def check_tree(copy_dir, rel_dir, head, git):
    """(round 6) The files under `copy_dir` must be exactly the files the commit `head` has under `rel_dir`
    (less what the copy leaves out, COPY_IGNORE), each byte-identical to the commit's blob: `git hash-object
    --no-filters <file>` against the blob `git ls-tree` names, the freeze's own comparison. A file that
    differs, one the commit does not have, one the commit has and the copy lacks, a link, an entry that is not a
    plain file, and git that cannot answer are all Refused. (round 9) The COPY_IGNORE paths are walked too: a link
    or an entry that is not a plain file there is Refused as well, and the plain files there (the build outputs)
    are returned, {path in the copy: sha256}, for Frozen.check_exercise to compare with the first check's.
    (round 10) A __pycache__ anywhere in the copy, a directory with nothing in it included, is Refused outright
    rather than returned: it is never part of what compile_all's p4c runs wrote."""
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
    found, outputs = {}, {}
    for dirpath, dirs, files in os.walk(copy_dir):
        for name in dirs + files:
            if name == "__pycache__":
                raise Refused("%s is in the copy of %s: nothing writes a __pycache__ there, and a cached .pyc could "
                              "run in place of the source that was checked"
                              % (os.path.relpath(os.path.join(dirpath, name), copy_dir).replace(os.sep, "/"), rel_dir))
        for name in files:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, copy_dir).replace(os.sep, "/")
            if not _ignored(rel):
                found[rel] = full
                continue
            mode = os.lstat(full).st_mode
            if not stat.S_ISREG(mode):
                raise Refused("%s/%s is %s in the copy, outside what %s has: only plain files are written there"
                              % (rel_dir, rel, "a link" if stat.S_ISLNK(mode) else "not a plain file", head))
            with open(full, "rb") as fh:
                outputs[rel] = hashlib.sha256(fh.read()).hexdigest()
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
    return outputs


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
