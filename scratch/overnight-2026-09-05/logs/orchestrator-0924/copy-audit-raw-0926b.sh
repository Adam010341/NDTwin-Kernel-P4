#!/usr/bin/env bash
# copy-audit-raw-0926b.sh -- the second 09-26 batch into the audit-raw worktree, repo paths kept: HB spike
# rounds 6, 7 and 7b (intake evidence, judge reports, worker summaries, gate logs) and the two LIVE runs
# of segment S (spike/runs/2026-09-26T023021Z_S_heartbeat -- detect, teardown refused, cleaned up by
# hand; spike/runs/2026-09-26T052148Z_S_heartbeat -- PART=all, PASS). Same exclusions as 0926.
# [Co-developed with claude code -- Adam]
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
S=scratch/overnight-2026-09-05
AR="$REPO/$S/wt-audit-raw"
[[ -d "$AR" ]] || { echo "no audit-raw worktree at $AR"; exit 2; }
copy() { local rel="$1" src="$REPO/$1" dst="$AR/$1"
    [[ -e "$src" ]] || { echo "   skip (absent): $rel"; return; }
    mkdir -p "$(dirname "$dst")"; cp -a "$src" "$(dirname "$dst")/" || { echo "   copy failed: $rel"; return 1; }
    printf '   %-90s %s\n' "$rel" "$(du -sh "$dst" | cut -f1)"; }
echo "== orchestrator-0924 (minus the two housekeeping logs)"
rsync -a --exclude 'private-backup-push-0925.log' --exclude 'disk-cleanup-0925.log' \
      "$REPO/$S/logs/orchestrator-0924/" "$AR/$S/logs/orchestrator-0924/"
echo "== worker summaries"
for f in P4-HBR6-SUMMARY.md P4-HBR7-SUMMARY.md; do copy "$S/hunt-0911/fix/$f"; done
echo "== gate logs (hbr6, hbr7, hbr7b, plus their helper scripts)"
mkdir -p "$AR/$S/logs/gates-0910"; n=0
for f in "$REPO/$S"/logs/gates-0910/*.hbr6* "$REPO/$S"/logs/gates-0910/*hbr6.* "$REPO/$S"/logs/gates-0910/*.hbr7* ; do
    [[ -e "$f" ]] && cp -a "$f" "$AR/$S/logs/gates-0910/" && n=$((n+1)); done
echo "   $n file(s)"
echo "== segment S live runs"
for d in 2026-09-26T023021Z_S_heartbeat 2026-09-26T052148Z_S_heartbeat; do copy "doc/audit/2026-09-25_p4-heartbeat/spike/runs/$d"; done
echo "== audit-raw would commit $(git -C "$AR" status --porcelain --untracked-files=all | wc -l) path(s); disk free $(df -h / | awk 'NR==2{print $4}')"
