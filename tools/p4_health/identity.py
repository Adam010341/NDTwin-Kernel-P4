"""What a lab run ran: the Q6(a) gate fingerprint and the system under test. (Cut 2 review m4)

[Co-developed with claude code -- Adam]

DESIGN 9 Q6(a), r5/r6: the first live run is authorized by name; a later rerun gets the standing
authorization only if everything OUTSIDE the "may differ" classes is the same as in that first
run. This module computes that comparison's input -- one digest per part and one over all -- so
the first run's health.json carries it (`gate_fingerprint`), and records the system under test
with the existing code_identity.py (`system_under_test`, design 4.3).

May differ (the fixes under test, and text no tool executes):
  p4_proxy/proxy_agent/** except sflow_emitter.py (root runs that one); src/**, include/**,
  libs/**, cmake/**, CMakeLists.txt, build/**; tests/**; doc/**/*.md; doc/audit/**/*.tsv.
Must be the same, by digest:
  every other tracked file as it is on disk (so uncommitted edits count); untracked files
  outside .test_run/, scratch/ and the run dir, by name and content; the NTG repo's HEAD, tree
  and every file outside .git/; the three interpreters (venv_fingerprint.sh's report); the
  system Mininet and /usr/bin/mnexec; /usr/local/sbin/ndtwin-lab and /etc/ndtwin-lab.conf (or
  its absence); the fabric bmv2 and its libraries, the stock simple_switch, p4c; and the OS
  tools root runs: tmux, tc, ip, ethtool, sudo.

Everything is read; nothing is written but the record. git and the fingerprint script run
through the injected Runner. A part that cannot be read is recorded as such, and the overall
digest then says "incomplete" -- an unread part is not a match.
"""
from __future__ import annotations

import hashlib
import json
import os
import re

MAY_DIFFER = (re.compile(r"^p4_proxy/proxy_agent/(?!sflow_emitter\.py$)"),
              re.compile(r"^(src|include|libs|cmake|build|tests)/"), re.compile(r"^CMakeLists\.txt$"),
              re.compile(r"^doc/.*\.md$"), re.compile(r"^doc/audit/.*\.tsv$"))
OUTPUT_DIRS = (".test_run/", "scratch/")
NTG = os.path.join(os.path.expanduser("~"), "Network-Traffic-Generator")
OS_TOOLS = ("tmux", "tc", "ip", "ethtool", "sudo")
MININET = ("/usr/lib/python3/dist-packages/mininet", "/usr/local/lib/python3/dist-packages")
HELPER, HELPER_CONF = "/usr/local/sbin/ndtwin-lab", "/etc/ndtwin-lab.conf"
UNREAD = "unreadable"


def may_differ(path):
    return any(r.search(path) for r in MAY_DIFFER)


def file_sha(path):
    try:
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for block in iter(lambda: fh.read(1 << 20), b""):
                h.update(block)
        return h.hexdigest()
    except OSError:
        return None


def digest(pairs):
    """sha256 over sorted (name, value) lines; any value None makes the part unreadable."""
    pairs = sorted(pairs)
    if any(v is None for _n, v in pairs):
        return UNREAD
    return hashlib.sha256("\n".join("%s %s" % p for p in pairs).encode("utf-8")).hexdigest()


def tree_files(root, skip=(".git",)):
    out = []
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if x not in skip)
        for f in files:
            p = os.path.join(d, f)
            if os.path.isfile(p) and not os.path.islink(p):
                out.append(os.path.relpath(p, root))
    return out


def tree_digest(root, skip=(".git",)):
    if not os.path.isdir(root):
        return "absent"
    return digest((rel, file_sha(os.path.join(root, rel))) for rel in tree_files(root, skip))


def git_lines(runner, repo, *args):
    res = runner.run(["git", "-C", repo] + list(args), timeout=120)
    return None if res.rc != 0 else [l for l in res.stdout.split("\0") if l]


def repo_parts(runner, repo, run_dir):
    tracked = git_lines(runner, repo, "ls-files", "-z")
    untracked = git_lines(runner, repo, "ls-files", "-z", "--others", "--exclude-standard")
    if tracked is None or untracked is None:
        return {"repo_tracked": UNREAD, "repo_untracked": UNREAD}
    run_rel = os.path.relpath(os.path.abspath(run_dir), os.path.abspath(repo)) + "/"
    keep_t = [p for p in tracked if not may_differ(p)]
    keep_u = [p for p in untracked if not may_differ(p) and not p.startswith(OUTPUT_DIRS)
              and not p.startswith(run_rel)]
    return {"repo_tracked": digest((p, file_sha(os.path.join(repo, p)) or "absent") for p in keep_t),
            "repo_untracked": digest((p, file_sha(os.path.join(repo, p))) for p in keep_u),
            "repo_counts": "%d tracked, %d untracked compared" % (len(keep_t), len(keep_u))}


def fingerprint(runner, repo, run_dir, interpreters, fabric_bmv2=None, stock="/usr/local/bin/simple_switch",
                p4c="/usr/local/bin/p4c-bm2-ss", ntg=NTG, fp_script=None, which=None):
    """{"parts": {...}, "sha256": <over every part> | "incomplete"}."""
    parts = repo_parts(runner, repo, run_dir)
    ntg_head = git_lines(runner, ntg, "rev-parse", "HEAD^{commit}", "HEAD^{tree}") if os.path.isdir(ntg) else None
    parts["ntg_head_tree"] = " ".join(ntg_head[0].split()) if ntg_head else UNREAD
    parts["ntg_files"] = tree_digest(ntg)
    if fp_script:
        out = os.path.join(run_dir, "venv_fingerprint.txt")
        res = runner.run(["bash", fp_script, out] + list(interpreters), timeout=300)
        parts["interpreters"] = (file_sha(out) or UNREAD) if res.rc == 0 else UNREAD
    else:
        parts["interpreters"] = UNREAD
    for i, d in enumerate(MININET):
        parts["mininet_%d" % i] = tree_digest(d, skip=("__pycache__",))
    parts["mnexec"] = file_sha("/usr/bin/mnexec") or UNREAD
    parts["helper"] = file_sha(HELPER) or UNREAD
    parts["helper_conf"] = file_sha(HELPER_CONF) or "absent"
    if fabric_bmv2:
        parts["bmv2_fabric"] = file_sha(fabric_bmv2) or UNREAD
        lib = os.path.normpath(os.path.join(os.path.dirname(os.path.realpath(fabric_bmv2)), "..", "lib"))
        parts["bmv2_fabric_libs"] = tree_digest(lib)
    else:
        parts["bmv2_fabric"] = parts["bmv2_fabric_libs"] = UNREAD
    parts["bmv2_stock"] = file_sha(stock) or UNREAD
    parts["p4c"] = file_sha(p4c) or UNREAD
    for tool in OS_TOOLS:
        path = (which or _which)(tool)
        parts["tool_%s" % tool] = (file_sha(path) if path else None) or UNREAD
    counts = parts.pop("repo_counts", None)
    total = UNREAD if any(v == UNREAD for v in parts.values()) else digest(parts.items())
    return {"parts": parts, "repo_counts": counts,
            "sha256": "incomplete" if total == UNREAD else total}


def _which(tool):
    for d in os.environ.get("PATH", "").split(os.pathsep) + ["/usr/sbin", "/sbin"]:
        p = os.path.join(d, tool)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return os.path.realpath(p)
    return None


def system_under_test(runner, repo, run_dir, python, script):
    """design 4.3: the path of a code_identity.py record of this checkout, or None."""
    out = os.path.join(run_dir, "code_identity.json")
    res = runner.run([python, script, "record", repo, out], timeout=300)
    return out if res.rc == 0 and os.path.isfile(out) else None


def dump(path, doc):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2, sort_keys=True)
        fh.write("\n")
