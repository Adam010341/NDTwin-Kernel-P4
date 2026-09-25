#!/usr/bin/env bash
# copy-audit-raw-0925.sh -- mirror the 09-25 batch's raw (REQ, HB segment H + spike rounds 3-4, OVS claim,
# the helper's post-install acceptance, the ecn control arms) into the audit-raw worktree, repo paths kept.
# Held back on purpose: the ndt serve ticket/diffs/judge reports (branch-only until Adam's walk verdicts and
# its merge), index-backup-0924, and two housekeeping logs that are not evidence of any claim and name
# private things (private-backup-push-0925.log: a private repo; disk-cleanup-0925.log: this machine's caches).
# [Co-developed with claude code -- Adam]
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
S=scratch/overnight-2026-09-05
AR="$REPO/$S/wt-audit-raw"
[[ -d "$AR" ]] || { echo "no audit-raw worktree at $AR"; exit 2; }
copy() { local rel="$1" src="$REPO/$1" dst="$AR/$1"
    [[ -e "$src" ]] || { echo "   skip (absent): $rel"; return; }
    mkdir -p "$(dirname "$dst")"; cp -a "$src" "$(dirname "$dst")/" || { echo "   copy failed: $rel"; return 1; }
    printf '   %-78s %s\n' "$rel" "$(du -sh "$dst" | cut -f1)"; }

echo "== orchestrator-0924 (minus ndt serve items and the two housekeeping logs)"
rsync -a --exclude 'TICKET-ndt-serve-0924.md' --exclude 'ndt-serve-diff-*' --exclude 'judge-ndt-serve-*' \
      --exclude 'private-backup-push-0925.log' --exclude 'disk-cleanup-0925.log' \
      "$REPO/$S/logs/orchestrator-0924/" "$AR/$S/logs/orchestrator-0924/"
du -sh "$AR/$S/logs/orchestrator-0924"
echo "== worker summaries"
for f in P4-HB-SUMMARY.md P4-REQ-SUMMARY.md NDT-OVS-SUMMARY.md; do copy "$S/hunt-0911/fix/$f"; done
echo "== gate logs (p4hb, ndtovs, p4req)"
mkdir -p "$AR/$S/logs/gates-0910"; n=0
for f in "$REPO/$S"/logs/gates-0910/*.p4hb-*.log "$REPO/$S"/logs/gates-0910/*.ndtovs-*.log "$REPO/$S"/logs/gates-0910/*.p4req-*.log; do
    [[ -e "$f" ]] && cp -a "$f" "$AR/$S/logs/gates-0910/" && n=$((n+1)); done
echo "   $n gate log(s)"
echo "== tutorials / live runs named after 2026-09-25T0000Z"
D=doc/audit/2026-09-04_p4-tutorial-exercise-prep
for d in "$REPO/$D"/live-p1/runs/2026-09-2* "$REPO/$D"/runs/2026-09-2*; do
    [[ -e "$d" ]] || continue; b=$(basename "$d"); [[ "$b" > 2026-09-25T0000Z ]] && copy "${d#$REPO/}"; done
echo "== audit-raw would commit $(git -C "$AR" status --porcelain | wc -l) path(s); disk free $(df -h / | awk 'NR==2{print $4}')"
