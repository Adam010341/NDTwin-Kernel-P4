#!/usr/bin/env bash
# Put this round's raw/ (including the quarantined void_* cells) on the audit-raw orphan branch.
#
# [Co-developed with claude code -- Adam]
#
# The pre-commit hook's own recipe is `git worktree add /tmp/rawwt audit-raw` + `add -A doc`.
# Two things changed on purpose: the worktree lives in the session scratchpad, not /tmp
# (two-writers-one-worktree: a /tmp worktree that loses files turns `add -A` into deletions),
# and only THIS round's raw path is added, never `-A doc` -- an orphan branch shared by every
# round must not get another round's files swept in by accident.
#
# Usage:  push_raw.sh            (refuses while run_ab.sh holds the lock: raw is still being written)
set -euo pipefail
REPO=/home/adam/Desktop/NDTwin-Kernel
ROUND=doc/audit/2026-09-02_recompute-paired-ab
HERE="$REPO/$ROUND"
WT="${SCRATCH:-/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/b69da030-bb8f-433e-84c6-678378bf024c/scratchpad}/rawwt"

# Raw is data only once the round is over; the lock is the round saying "still writing".
exec 9>"$(git -C "$HERE" rev-parse --show-toplevel)/.test_run/run_ab.lock"
flock -n 9 || { echo "REFUSE: run_ab.sh still holds the lock; raw/ is still being written" >&2; exit 75; }

cd "$REPO"
git worktree add "$WT" audit-raw >/dev/null
trap 'git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true' EXIT
mkdir -p "$WT/$ROUND"
rsync -a --delete "$HERE/raw/" "$WT/$ROUND/raw/"
n=$(find "$WT/$ROUND/raw" -type f | wc -l)
git -C "$WT" add "$ROUND/raw"
git -C "$WT" commit -q -m "Raw for the 2026-09-02 paired A/B: two kernels one constant apart, zero sampling and 1/1024

$n files. Includes raw/void_2026-09-02_1237-1257_two-scripts-raced/, the two
cells written while two instances of run_ab.sh ran at once (PREREG 3c); kept
as the evidence that those labels were wrong, excluded from every analysis by
path.

[Co-developed with claude code -- Adam]

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
sha=$(git -C "$WT" rev-parse --short HEAD)
git -C "$WT" push p4 audit-raw 2>&1 | tail -1
echo "audit-raw $sha: $n files under $ROUND/raw"
# Acceptance is a byte-for-byte check of what landed, not "push succeeded".
diff -rq "$HERE/raw" "$WT/$ROUND/raw" && echo "verified: branch copy identical to raw/"
