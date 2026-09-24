#!/usr/bin/env python3
"""Run this round's tests (or its mutation gate) against code from another revision.

[Co-developed with claude code -- Adam]

🔴 WHY THIS IS A FILE (ruling 39(9b)). Round 9's red runs and post-checks were assembled in a
scratchpad and only their stdout survived, so a judge could read what they printed and could not
re-run them -- which is the same "only the log is left" state the round-8 candidate list had
already named for the anchor sweep. Every red run of round 10 goes through this one script, and
its log header says exactly what was swapped for what.

What it builds, in a temp dir (never in this tree -- another session may be reading it):

  * the round directory as it is in THIS working tree, or -- with --tree-rev -- as it was at an
    older revision (`git archive`), and then
  * each --file replaced by its content at --rev (production code from before a fix, run
    against the tests of today: the red run for a new test), and then
  * each patch of --patch-json applied, every anchor asserted to occur EXACTLY once (the same
    rule as the mutation gate: an anchor that no longer matches is a refusal, not a result).

Then it runs the named unittest ids (default: the whole suite) or, with --gate, the tree's own
tests/mutate_analyse.sh, and ends with `### rc=N` like every other log of this round.

Usage:
  red_against.py [--rev REV --file analyse.py ...] [--tree-rev REV] [--patch-json P.json]
                 [--gate] [--python PY] [--why TEXT] [unittest ids ...]
"""
import argparse
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROUND = os.path.dirname(HERE)


def git(*args, binary=False):
    out = subprocess.run(["git", "-C", ROUND] + list(args), check=True, capture_output=True)
    return out.stdout if binary else out.stdout.decode()


def round_prefix():
    """This round's path inside the repository, e.g. doc/audit/2026-09-19_telemetry-three-groups."""
    return git("rev-parse", "--show-prefix").strip().rstrip("/")


def sha256(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()[:12]


def copy_working_tree(destination):
    """The round's tracked and untracked-but-not-ignored files, as they are on disk now."""
    listed = git("ls-files", "-co", "--exclude-standard", "--", ".").splitlines()
    for relative in listed:
        source = os.path.join(ROUND, relative)
        if not os.path.isfile(source):
            continue
        target = os.path.join(destination, relative)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(source, target)


def extract_tree(revision, destination):
    """The round directory exactly as it was at `revision`."""
    prefix = round_prefix()
    # the pathspec is repo-relative, so archive from the top level: run from the round directory
    # it resolved to nothing and git exited 128 (the first run of this function, round 10)
    top = git("rev-parse", "--show-toplevel").strip()
    archive = subprocess.run(["git", "-C", top, "archive", "--format=tar", revision, "--", prefix],
                             check=True, capture_output=True).stdout
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for member in tar.getmembers():
            if not member.name.startswith(prefix + "/") or not member.isfile():
                continue
            relative = member.name[len(prefix) + 1:]
            target = os.path.join(destination, relative)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with tar.extractfile(member) as source, open(target, "wb") as sink:
                sink.write(source.read())
            os.chmod(target, member.mode)


def apply_patch(root, patch):
    path = os.path.join(root, patch["file"])
    with open(path) as fh:
        source = fh.read()
    count = source.count(patch["anchor"])
    if count != 1:
        raise SystemExit("REFUSE: the anchor of %r occurs %d times in %s, not once -- no patch "
                         "was applied, so there is nothing to report" % (patch.get("name"), count,
                                                                         patch["file"]))
    with open(path, "w") as fh:
        fh.write(source.replace(patch["anchor"], patch["replacement"]))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--rev", help="the revision every --file comes from")
    parser.add_argument("--file", action="append", default=[],
                        help="a round file (relative to the round dir) to take from --rev")
    parser.add_argument("--tree-rev", help="start from the whole round directory at this rev")
    parser.add_argument("--patch-json", action="append", default=[],
                        help="a JSON list of {name, file, anchor, replacement}")
    parser.add_argument("--gate", action="store_true", help="run tests/mutate_analyse.sh")
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--why", default="", help="one line for the log header")
    parser.add_argument("ids", nargs="*", help="unittest ids; default: the whole suite")
    args = parser.parse_args(argv)
    if args.file and not args.rev:
        parser.error("--file needs --rev")

    head = git("rev-parse", "--short=8", "HEAD").strip()
    work = tempfile.mkdtemp(prefix="ndt-e-red-")
    try:
        tree = os.path.join(work, "round")
        os.makedirs(tree)
        if args.tree_rev:
            extract_tree(args.tree_rev, tree)
        else:
            copy_working_tree(tree)
        lines = ["### red_against.py -- %s" % (args.why or "a run against other code"),
                 "# head:        %s (the tree this script and its log belong to)" % head,
                 "# tree:        %s" % ("round directory at %s (git archive)" % args.tree_rev
                                        if args.tree_rev else "this working tree"),
                 "# interpreter: %s" % args.python]
        for name in args.file:
            blob = git("show", "%s:%s/%s" % (args.rev, round_prefix(), name), binary=True)
            with open(os.path.join(tree, name), "wb") as fh:
                fh.write(blob)
            lines.append("# swapped:     %s <- %s (sha256 %s)"
                         % (name, args.rev, sha256(os.path.join(tree, name))))
        for patch_file in args.patch_json:
            with open(patch_file) as fh:
                patches = json.load(fh)
            for patch in patches:
                apply_patch(tree, patch)
                lines.append("# patched:     %s in %s (from %s; now sha256 %s)"
                             % (patch.get("name"), patch["file"], os.path.basename(patch_file),
                                sha256(os.path.join(tree, patch["file"]))))
        for name in ("analyse.py", "plot.py", "tests/test_analyse.py", "tests/test_plot.py",
                     "tests/synthetic.py"):
            if os.path.exists(os.path.join(tree, name)):
                lines.append("# as run:      %-22s sha256 %s" % (name, sha256(os.path.join(tree, name))))
        lines.append("###")
        print("\n".join(lines), flush=True)
        environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PROXY_PY=args.python)
        if args.gate:
            command = ["bash", os.path.join(tree, "tests", "mutate_analyse.sh")]
            cwd = tree
        else:
            command = [args.python, "-m", "unittest", "-v"] + (args.ids or ["discover", "-s", "."])
            cwd = os.path.join(tree, "tests")
        result = subprocess.run(command, cwd=cwd, env=environment, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        sys.stdout.write(result.stdout.decode(errors="replace"))
        print("\n### rc=%d" % result.returncode)
        return result.returncode
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
