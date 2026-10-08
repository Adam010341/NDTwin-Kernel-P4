#!/usr/bin/env bash
#
# Add the shard logs of tests/shell/mutate_p4_health.sh up, and say whether they are the gate. (Cut 2 round 5, #6)
#
# [Co-developed with claude code -- Adam]
#
#   tests/shell/sum_p4_health_gate_shards.sh <shard log>...
#
# One shard (MUT_SHARD=k/n) is never the gate by itself: its rc=0 says only that the mutations IT ran were
# caught. The gate is the n shards of one head together, so this checks, over the logs given:
#
#   * every log is a whole run of the gate script: it opens with `commit <sha>`, carries the HEAD, tree and
#     subject-sha lines, its baseline, negative control, byte-identical check and after-check are green, it
#     reports `N mutations, 0 survived` and `SHARD k/n of L mutations in the table`, it is not a PARTIAL RUN, it
#     never says REFUSED, and its last line is `rc=0`;
#   * all of them share one commit (the first line, and the HEAD line), one tools/p4_health tree (and none says
#     UNCOMMITTED) and one subject sha;
#   * they agree on n and on L, n is not larger than L, the shards are exactly 0..n-1 once each, each ran its
#     share of the table (the positions k, k+n, ... below L) and the shares add up to L.
#
# Only then it prints the one line
#   GATE: <N> mutations, <S> survived, shards <k>/<n> ok
# and exits 0. Anything else prints `NOT THE GATE: <why>` (one line per reason) and exits 1.
set -uo pipefail
exec "${PYTHON:-python3}" - "$@" <<'PY'
import re
import sys

logs = sys.argv[1:]
problems = []


def bad(why):
    problems.append(why)


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read().splitlines()
    except OSError as exc:
        bad("cannot read %s: %s" % (path, exc))
        return None


def one(lines, pattern):
    """The groups of the only line matching `pattern`, or None (zero or several)."""
    hits = [re.match(pattern, l) for l in lines]
    hits = [h for h in hits if h]
    return hits[0].groups() if len(hits) == 1 else None


if not logs:
    bad("no logs given")
shards = {}                     # k -> path
facts = []
for path in logs:
    lines = read(path)
    if lines is None:
        continue
    tag = path
    first = re.match(r"commit ([0-9a-f]{40})\b", lines[0]) if lines else None
    if not first:
        bad("%s: the first line is not `commit <sha>`" % tag)
    head = one(lines, r"HEAD\s*: ([0-9a-f]{40}) \(commit\)$")
    if head is None:
        bad("%s: no single `HEAD : <sha> (commit)` line" % tag)
    elif first and first.group(1) != head[0]:
        bad("%s: the first line's commit %s is not the HEAD line's %s" % (tag, first.group(1)[:12], head[0][:12]))
    tree = one(lines, r"tree\s*: ([0-9a-f]{40}) \(git tree of tools/p4_health at HEAD\)(.*)$")
    if tree is None:
        bad("%s: no single `tree` line" % tag)
    elif tree[1].strip():
        bad("%s: the tree line says %s (UNCOMMITTED changes)" % (tag, tree[1].strip()))
    subj = one(lines, r"subject sha: ([0-9a-f]{16})$")
    if subj is None:
        bad("%s: no single `subject sha` line" % tag)
    for l in lines:
        if "REFUSED" in l or "\U0001f534" in l:
            bad("%s: the log says `%s` (REFUSED or a red mark)" % (tag, l.strip()[:80]))
            break
    if "PARTIAL RUN" in "\n".join(lines):
        bad("%s: a PARTIAL RUN" % tag)
    # the green lines, each exactly once
    text = "\n".join(lines)
    bi = [i for i, l in enumerate(lines) if l.startswith("=== BASELINE")]
    if len(bi) != 1 or lines[bi[0] + 1:bi[0] + 2] != ["  ok       baseline green"]:
        bad("%s: the baseline is not green" % tag)
    if text.count("  ✅ green: the suites do not react to a comment") != 1:
        bad("%s: the negative control is not green" % tag)
    if len(re.findall(r"^  byte-identical  tools/p4_health  ", text, re.M)) != 1:
        bad("%s: no byte-identical line for tools/p4_health" % tag)
    if text.count("  suites green against the real files") != 1:
        bad("%s: the after-check (suites green against the real files) is missing" % tag)
    m_s = one(lines, r"(\d+) mutations, (\d+) survived$")
    sh = one(lines, r"SHARD (\d+)/(\d+) of (\d+) mutations in the table$")
    if m_s is None:
        bad("%s: no single `N mutations, S survived` line" % tag)
    if sh is None:
        bad("%s: no single `SHARD k/n of L mutations in the table` line (not a shard log)" % tag)
    elif not (len([l for l in lines if l == "NOT THE GATE BY ITSELF: shard %s/%s" % (sh[0], sh[1])]) == 1
              and any(l.startswith("NOT THE GATE BY ITSELF: shard %s/%s " % (sh[0], sh[1])) for l in lines)):
        bad("%s: the NOT THE GATE BY ITSELF banner (top and bottom) is missing or is another shard's" % tag)
    if m_s is not None and int(m_s[1]) != 0:
        bad("%s: %s survived" % (tag, m_s[1]))
    last = lines[-1] if lines else ""
    if last != "rc=0":
        bad("%s: %s" % (tag, ("ended %s" % last) if re.match(r"rc=\d+$", last) else "the log does not end in rc="))
    if first and head and tree and subj and m_s and sh:
        k, n, labels = int(sh[0]), int(sh[1]), int(sh[2])
        if k in shards:
            bad("%s: shard %d/%d given more than once (%s and %s)" % (tag, k, n, shards[k], path))
        shards[k] = path
        facts.append({"path": path, "commit": first.group(1), "tree": tree[0], "subj": subj[0],
                      "k": k, "n": n, "labels": labels, "m": int(m_s[0]), "s": int(m_s[1])})

if facts:
    for key, what in (("commit", "commits differ"), ("tree", "tools/p4_health trees differ"),
                      ("subj", "subject shas differ")):
        if len({f[key] for f in facts}) != 1:
            bad("%s between the logs: %s" % (what, ", ".join(sorted({f[key][:12] for f in facts}))))
    ns = {f["n"] for f in facts}
    ls = {f["labels"] for f in facts}
    if len(ns) != 1:
        bad("the logs are of different n: %s" % ", ".join(str(x) for x in sorted(ns)))
    if len(ls) != 1:
        bad("the logs disagree on the size of the table: %s" % ", ".join(str(x) for x in sorted(ls)))
    if len(ns) == 1 and len(ls) == 1:
        n, labels = ns.pop(), ls.pop()
        if n > labels:
            bad("n=%d is larger than the table (%d mutations): some shard ran nothing" % (n, labels))
        if sorted(shards) != list(range(n)):
            bad("expected shards 0..%d once each, got %s" % (n - 1, sorted(shards)))
        for f in facts:
            share = len(range(f["k"], labels, n))
            if f["m"] != share:
                bad("%s: shard %d/%d ran %d mutations, its share of %d is %d: the counts do not add up"
                    % (f["path"], f["k"], n, f["m"], labels, share))

if problems:
    for p in problems:
        print("NOT THE GATE: %s" % p)
    sys.exit(1)
print("GATE: %d mutations, %d survived, shards %d/%d ok"
      % (sum(f["m"] for f in facts), sum(f["s"] for f in facts), len(facts), facts[0]["n"]))
PY
