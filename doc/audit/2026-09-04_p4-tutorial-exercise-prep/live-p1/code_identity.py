#!/usr/bin/env python3
"""
Which code a live-p1 run ran, and whether a treatment's code is the controls' code plus B.

[Co-developed with claude code -- Adam]

The external comparison (README, "合併前的比對") runs its controls C1, C2 (C3, C4) on the main
checkout at trunk, then merges B there LOCALLY and runs the treatment T. "The same code apart from
B" is then four facts, and this file records them and checks them (the round-4 review's M-2):

  * the checkout's HEAD and its parents -- T's HEAD must be a merge whose FIRST parent is the
    controls' HEAD and whose second is the B commit under test;
  * the uncommitted tracked files (path, status, sha256 of what is on disk) -- the main checkout is
    shared and carries other people's uncommitted work; T's set must be the controls' set, and none
    of them may be a file B changes. Untracked files are NOT recorded: every live run adds raw under
    runs/, so they differ by construction (disclosed, not checked);
  * the binaries the run executes: the kernel (build/bin/ndtwin_kernel), the fabric's bmv2 (the one
    p4_proxy/mininet/bmv2_binary_override names) and the drop check's stock simple_switch, and the
    installed root helper (/usr/local/sbin/ndtwin-lab) -- each by sha256;
  * the two interpreters (the proxy's venv and the controllers' / driver's): live-p1/
    venv_fingerprint.sh's distribution sha256 for each.

[Co-developed with claude code -- Adam] Round 6 (the round-5 re-review's M-2, and the orchestrator's
ruling on it):
  * the uncommitted comparison covers CODE paths only: doc/**/*.md and doc/audit/**/*.tsv are left
    out (other sessions edit ledgers and reports in the shared checkout all day); every other
    tracked file is compared;
  * ~/tutorials, the compared arms' own code path (drive_exercise's TUT): its HEAD, its uncommitted
    tracked files with sha256s, and a digest of every file under exercises/p4runtime,
    exercises/flowcache and utils (build/, logs/, pcaps/ and byte-code left out: every round
    rewrites them);
  * the fabric bmv2's libraries (the shared objects under the fabric binary's ../lib), by digest;
  * the tree: a merge's tree must be what `git merge-tree --write-tree <parent 1> <parent 2>`
    gives -- an amended or hand-resolved merge is not "C plus B".

Usage:  code_identity.py record <repo> <out.json>
        code_identity.py verify <controls' identity.json> <treatment's identity.json> <B sha>
Exit:   record: 0 written (a part that could not be read is written as such), 2 usage/unwritable;
        verify: 0 every fact matches, 3 refused (each reason printed), 2 unreadable.
        (The controls among themselves are compared by external_evidence.py compare.)
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FORMAT = 2
CTRL_PY_DEFAULT = os.path.expanduser("~/p4dev-python-venv/bin/python")
HELPER = "/usr/local/sbin/ndtwin-lab"
STOCK = "/usr/local/bin/simple_switch"
#: The facts that must be equal between the controls, and between the controls and T.
SAME = ("uncommitted", "kernel", "bmv2_fabric", "bmv2_libs", "bmv2_stock", "helper", "venv",
        "tutorials")
#: Tracked files left out of the uncommitted comparison (the orchestrator's round-6 ruling): docs and
#: audit tables, which other sessions edit while the comparison runs.
NOT_CODE = (re.compile(r"^doc/.*\.md$"), re.compile(r"^doc/audit/.*\.tsv$"))
TUTORIALS_PARTS = ("exercises/p4runtime", "exercises/flowcache", "utils")
TUTORIALS_SKIP_DIRS = {"build", "logs", "pcaps", "__pycache__"}


def sha256_of(path):
    try:
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for block in iter(lambda: fh.read(1 << 20), b""):
                h.update(block)
        return h.hexdigest()
    except OSError as exc:
        return f"unreadable ({type(exc).__name__})"


def git(repo, *args):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip()[:200]}")
    return r.stdout


def uncommitted(repo):
    """[[status, path, sha256 on disk], ...] of every tracked file with a change, sorted."""
    out = []
    raw = git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=no")
    items = raw.split("\0")
    i = 0
    while i < len(items):
        item = items[i]
        i += 1
        if not item:
            continue
        status, path = item[:2], item[3:]
        if status[0] in "RC":                  # a rename/copy carries its source next
            i += 1
        if any(rx.match(path) for rx in NOT_CODE):
            continue
        full = os.path.join(repo, path)
        out.append([status, path, sha256_of(full) if os.path.isfile(full) else "-"])
    return sorted(out, key=lambda e: e[1])


def tree_digest(root, skip_dirs=TUTORIALS_SKIP_DIRS):
    """sha256 over (relative path, sha256) of every file under root, skipping some directories and
    byte-code; "absent" when root is not a directory."""
    if not os.path.isdir(root):
        return "absent"
    h, n = hashlib.sha256(), 0
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if x not in skip_dirs)
        for f in sorted(files):
            if f.endswith((".pyc", ".pyo")):
                continue
            p = os.path.join(d, f)
            h.update(f"{os.path.relpath(p, root)}\0{sha256_of(p)}\n".encode())
            n += 1
    return f"{n} files sha256 {h.hexdigest()}"


def tutorials(path=None):
    path = path or os.environ.get("TUTORIALS_DIR") or os.path.expanduser("~/tutorials")
    out = {"path": path}
    try:
        out["head"] = git(path, "rev-parse", "HEAD").strip()
        out["uncommitted"] = [[st, p, h] for st, p, h in uncommitted(path)]
    except RuntimeError as exc:
        out["git"] = f"not read: {exc}"
    out["trees"] = {part: tree_digest(os.path.join(path, part)) for part in TUTORIALS_PARTS}
    return out


def libs_digest(binary):
    """The shared objects under <binary>/../lib (p4_testbed_topo's LD_LIBRARY_PATH rule), by digest."""
    if not binary:
        return "no binary"
    lib = os.path.normpath(os.path.join(os.path.dirname(os.path.realpath(binary)), "..", "lib"))
    if not os.path.isdir(lib):
        return f"{lib}: absent"
    h, n = hashlib.sha256(), 0
    for f in sorted(os.listdir(lib)):
        p = os.path.join(lib, f)
        if ".so" in f and os.path.isfile(p) and not os.path.islink(p):
            h.update(f"{f}\0{sha256_of(p)}\n".encode())
            n += 1
    return f"{lib}: {n} shared objects sha256 {h.hexdigest()}"


def fabric_binary(repo):
    try:
        with open(os.path.join(repo, "p4_proxy", "mininet", "bmv2_binary_override")) as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#"):
                    return line
    except OSError:
        pass
    return None


def venv_shas(repo, ctrl_py):
    out = {}
    fd, tmp = tempfile.mkstemp(prefix="identity-venv-")
    os.close(fd)
    try:
        subprocess.run(["bash", os.path.join(HERE, "venv_fingerprint.sh"), tmp,
                        os.path.join(repo, "p4_proxy", "venv", "bin", "python"), ctrl_py],
                       capture_output=True, text=True, timeout=120)
        who = None
        for line in open(tmp).read().splitlines():
            if line.startswith("== interpreter "):
                who = line[len("== interpreter "):]
                out[who] = "not recorded"
            elif line.startswith("distributions ") and who:
                out[who] = line
    except (OSError, subprocess.SubprocessError) as exc:
        out["error"] = f"{type(exc).__name__}: {exc}"
    finally:
        os.unlink(tmp)
    return out


def record(repo, out_path, ctrl_py=None):
    repo = os.path.abspath(repo)
    ident = {"format": FORMAT, "repo": repo, "recorded_at": int(time.time())}
    try:
        ident["head"] = git(repo, "rev-parse", "HEAD").strip()
        ident["parents"] = git(repo, "rev-list", "--parents", "-n", "1", "HEAD").split()[1:]
        ident["uncommitted"] = uncommitted(repo)
        ident["tree"] = git(repo, "rev-parse", "HEAD^{tree}").strip()
        if len(ident["parents"]) == 2:
            # what the merge brought in over its first parent: B's side of it
            ident["merge_changes"] = sorted(git(repo, "diff", "--name-only", ident["parents"][0],
                                                ident["head"]).split())
            # and what an automatic merge of the two parents gives: the merge's tree must be it
            r = subprocess.run(["git", "-C", repo, "merge-tree", "--write-tree", *ident["parents"]],
                               capture_output=True, text=True)
            ident["merge_tree"] = (r.stdout.split() or ["?"])[0] if r.returncode == 0 else \
                f"merge-tree rc {r.returncode}: {r.stdout.strip()[:120]}"
    except RuntimeError as exc:
        ident["git_error"] = str(exc)
    kernel = os.path.join(repo, "build", "bin", "ndtwin_kernel")
    fabric = fabric_binary(repo)
    ident["kernel"] = [kernel, sha256_of(kernel)]
    ident["bmv2_fabric"] = [fabric, sha256_of(fabric) if fabric else "no directive"]
    ident["bmv2_libs"] = libs_digest(fabric)
    ident["tutorials"] = tutorials()
    ident["bmv2_stock"] = [STOCK, sha256_of(STOCK)]
    ident["helper"] = [HELPER, sha256_of(HELPER)]
    ident["venv"] = venv_shas(repo, ctrl_py or os.environ.get("CTRL_PY") or CTRL_PY_DEFAULT)
    tmp = out_path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(ident, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, out_path)
    return ident


def load(path):
    with open(path) as fh:
        ident = json.load(fh)
    if not isinstance(ident, dict) or ident.get("format") != FORMAT or "head" not in ident:
        raise ValueError(f"{path}: not a code identity (format {FORMAT}) with a HEAD")
    return ident


def unchanged_reasons(before, after, label):
    """[Co-developed with claude code -- Adam] What changed between a run's identity before and after
    it (round 6): the HEAD, its parents, its tree or any fact in SAME."""
    out = []
    for key in ("head", "parents", "tree"):
        if before.get(key) != after.get(key):
            out.append(f"{label}: {key} {json.dumps(before.get(key))[:80]} before the run, "
                       f"{json.dumps(after.get(key))[:80]} after it")
    return out + same_reasons(before, after, f"{label} before", f"{label} after")


def same_reasons(a, b, label_a, label_b):
    """What differs between two identities on SAME, as sentences."""
    out = []
    for key in SAME:
        if a.get(key) != b.get(key):
            out.append(f"{key}: {label_a} {json.dumps(a.get(key))[:160]} vs {label_b} "
                       f"{json.dumps(b.get(key))[:160]}")
    return out


def verify(c, t, b_sha):
    """[reasons T is not C plus B] -- empty when it is."""
    reasons = []
    if c.get("head") == t.get("head"):
        reasons.append(f"T's HEAD {t.get('head')} is the controls' HEAD: B was not merged")
    parents = t.get("parents") or []
    if len(parents) != 2:
        reasons.append(f"T's HEAD {t.get('head')} has {len(parents)} parent(s), not a merge of two")
    else:
        if parents[0] != c.get("head"):
            reasons.append(f"T's first parent {parents[0]} is not the controls' HEAD {c.get('head')}: "
                           f"trunk moved between C and T, or the merge went the other way")
        if not re.fullmatch(r"[0-9a-f]{7,40}", b_sha or "") or not parents[1].startswith(b_sha):
            reasons.append(f"T's second parent {parents[1]} is not the B commit under test {b_sha!r}")
    if len(parents) == 2 and t.get("tree") != t.get("merge_tree"):
        reasons.append(f"T's tree {t.get('tree')} is not what merging its two parents gives "
                       f"({t.get('merge_tree')}): an amended or hand-resolved merge")
    reasons += same_reasons(c, t, "controls", "T")
    changed_by_b = t.get("merge_changes")
    if changed_by_b is None and len(parents) == 2:
        reasons.append("T's identity does not say which files its merge changed")
    touched = sorted({p for _s, p, _h in (t.get("uncommitted") or [])} & set(changed_by_b or []))
    if touched:
        reasons.append(f"uncommitted file(s) B also changes: {touched[:6]}")
    return reasons


def main(argv):
    try:
        if len(argv) == 3 and argv[0] == "record":
            ident = record(argv[1], argv[2])
            print(f"identity -> {argv[2]}: HEAD {ident.get('head', ident.get('git_error'))}, "
                  f"{len(ident.get('uncommitted') or [])} uncommitted tracked file(s)")
            return 0
        if len(argv) == 4 and argv[0] == "verify":
            c, t = load(argv[1]), load(argv[2])
            reasons = verify(c, t, argv[3])
            for r in reasons:
                print(f"REFUSED {r}")
            if not reasons:
                print(f"SAME CODE APART FROM B: T {t['head'][:12]} = controls' {c['head'][:12]} + "
                      f"B {argv[3][:12]}; uncommitted, kernel, bmv2, helper and venv identical")
            return 3 if reasons else 0
    except (OSError, ValueError, KeyError) as exc:
        print(f"UNREADABLE {type(exc).__name__}: {exc}")
        return 2
    print(__doc__.split("Usage:")[1].split("Exit:")[0].rstrip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
