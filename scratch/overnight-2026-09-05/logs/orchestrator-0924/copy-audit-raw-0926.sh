#!/usr/bin/env bash
# copy-audit-raw-0926.sh -- mirror the 09-26 batch's raw into the audit-raw worktree, repo paths kept:
# the heartbeat no-venv CI fix, HB spike round 5 (R4 notes), and ndt serve -- now merged (dfbab30e), so the
# ndt serve material held back by copy-audit-raw-0924/0925.sh (its ticket copy, diffs, judge reports and the
# peer's logs/ndt-serve-0924/) goes in with it, as REPORT.md §1 item 6 said it would.
# Still held back: the two 09-25 housekeeping logs (private-backup-push-0925.log names a private repo;
# disk-cleanup-0925.log lists this machine's caches) -- not evidence of any claim.
# Checked before writing this (09-26): the current ndt-serve token is in none of these files; the only
# 43+-char strings in logs/ndt-serve-0924 are sha256s, test names and separators; the only private-pattern
# hit is the path tools/remote-lab/dorm_lab/ in `ndt status` output, already in audit-raw 434 times.
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

echo "== orchestrator-0924 (now with the ndt serve items; minus the two housekeeping logs)"
rsync -a --exclude 'private-backup-push-0925.log' --exclude 'disk-cleanup-0925.log' \
      "$REPO/$S/logs/orchestrator-0924/" "$AR/$S/logs/orchestrator-0924/"
du -sh "$AR/$S/logs/orchestrator-0924"
echo "== the ndt serve peer's raw (held until the merge)"
copy "$S/logs/ndt-serve-0924"
echo "== worker summaries"
for f in P4-HBNOVENV-SUMMARY.md P4-HBR4-SUMMARY.md NDT-SERVE-INTAKE-SUMMARY.md; do copy "$S/hunt-0911/fix/$f"; done
echo "== gate logs (hbnovenv, hbr4, ndtserve-intake, and the intake's red/caught/ci-shape logs)"
mkdir -p "$AR/$S/logs/gates-0910"; n=0
for f in "$REPO/$S"/logs/gates-0910/*.hbnovenv-*.log "$REPO/$S"/logs/gates-0910/*.hbr4-*.log \
         "$REPO/$S"/logs/gates-0910/*.ndtserve-intake-*.log; do
    [[ -e "$f" ]] && cp -a "$f" "$AR/$S/logs/gates-0910/" && n=$((n+1)); done
echo "   $n gate log(s)"
echo "== audit-raw would commit $(git -C "$AR" status --porcelain | wc -l) path(s); disk free $(df -h / | awk 'NR==2{print $4}')"
