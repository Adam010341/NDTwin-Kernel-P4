#!/usr/bin/env bash
# copy-audit-raw-0927b.sh -- the 09-27 early-morning batch into the audit-raw worktree, repo paths kept:
# the worker-traffic INCIDENT note (09-26 17:55Z), r2 follow-ups' intake (judge 4f661e31, test-merge fc4c1688
# reruns, push b2eeb71d, CI compare), branch 2's intake so far (judge c03130fe: MERGE AFTER FIXES, test-merge
# 79ec2261 reruns), their gate logs and scripts, and live 07 on b2eeb71d (2026-09-26T202055Z: PASS).
# Held back: LIVE-P1-COMMON-NOLAB-SUMMARY.md (the worker is revising it after the judge's F1/C1).
# Same exclusions as 0926/0927 (the two 09-25 housekeeping logs), and every __pycache__ / *.pyc.
# [Co-developed with claude code -- Adam]
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
S=scratch/overnight-2026-09-05
AR="$REPO/$S/wt-audit-raw"
[[ -d "$AR" ]] || { echo "no audit-raw worktree at $AR"; exit 2; }
copy() { local rel="$1" src="$REPO/$1" dst="$AR/$1"
    [[ -e "$src" ]] || { echo "   skip (absent): $rel"; return; }
    mkdir -p "$(dirname "$dst")"
    rsync -a --exclude '__pycache__' --exclude '*.pyc' "$src" "$(dirname "$dst")/" || { echo "   copy failed: $rel"; return 1; }
    printf '   %-100s %s\n' "$rel" "$(du -sh "$dst" | cut -f1)"; }
echo "== orchestrator-0924 (minus the two housekeeping logs)"
rsync -a --exclude 'private-backup-push-0925.log' --exclude 'disk-cleanup-0925.log' --exclude '__pycache__' --exclude '*.pyc' \
      --exclude 'live07.pid' --exclude 'rerun.pid' \
      "$REPO/$S/logs/orchestrator-0924/" "$AR/$S/logs/orchestrator-0924/"
echo "== worker summaries"
copy "$S/hunt-0911/fix/P4-HB-FOLLOWUPS-R2-SUMMARY.md"
echo "== gate logs (p4hbr2b, lp1cnolab) and their scripts"
mkdir -p "$AR/$S/logs/gates-0910"; n=0
for f in "$REPO/$S"/logs/gates-0910/*.p4hbr2b-* "$REPO/$S"/logs/gates-0910/*.lp1cnolab-c03130fe*; do
    [[ -f "$f" ]] && cp -a "$f" "$AR/$S/logs/gates-0910/" && n=$((n+1)); done
echo "   $n file(s)"
for d in "$REPO/$S"/logs/gates-0910/scripts-p4hbr2b-* "$REPO/$S"/logs/gates-0910/scripts-lp1cnolab-c03130fe-*; do
    [[ -d "$d" ]] && copy "${d#$REPO/}"; done
echo "== live-p1 run: 07 on b2eeb71d"
copy "doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1/runs/2026-09-26T202055Z_07_roles_basic"
echo "== pyc check: $(find "$AR" -path "$AR/.git" -prune -o \( -name '__pycache__' -o -name '*.pyc' \) -print | wc -l) (want 0)"
echo "== audit-raw would commit $(git -C "$AR" status --porcelain --untracked-files=all | wc -l) path(s); disk free $(df -h / | awk 'NR==2{print $4}')"
