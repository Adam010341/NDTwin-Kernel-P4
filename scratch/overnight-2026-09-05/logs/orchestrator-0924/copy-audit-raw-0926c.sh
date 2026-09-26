#!/usr/bin/env bash
# copy-audit-raw-0926c.sh -- the third 09-26 batch into the audit-raw worktree, repo paths kept:
# segment S's de-phased live runs 3-4 (sweep x10, random x20 on trunk 094f417f), HB spike round 8's intake,
# the P4-HB-SPIKE.md intake (judge reports, public-verify log), the protobuf 5 candidate's live trial
# (live-p1 01/06 runs, drive_exercise runs, pb5-trial notes) and its merge-preparation logs.
# Same exclusions as 0926/0926b (the two 09-25 housekeeping logs).
# [Co-developed with claude code -- Adam]
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
S=scratch/overnight-2026-09-05
AR="$REPO/$S/wt-audit-raw"
[[ -d "$AR" ]] || { echo "no audit-raw worktree at $AR"; exit 2; }
copy() { local rel="$1" src="$REPO/$1" dst="$AR/$1"
    [[ -e "$src" ]] || { echo "   skip (absent): $rel"; return; }
    mkdir -p "$(dirname "$dst")"; cp -a "$src" "$(dirname "$dst")/" || { echo "   copy failed: $rel"; return 1; }
    printf '   %-100s %s\n' "$rel" "$(du -sh "$dst" | cut -f1)"; }
echo "== orchestrator-0924 (minus the two housekeeping logs)"
rsync -a --exclude 'private-backup-push-0925.log' --exclude 'disk-cleanup-0925.log' \
      "$REPO/$S/logs/orchestrator-0924/" "$AR/$S/logs/orchestrator-0924/"
echo "== worker summaries"
for f in P4-HBR8-SUMMARY.md P4-PB5-LIVE-SUMMARY.md P4-PB5-PREP-SUMMARY.md; do copy "$S/hunt-0911/fix/$f"; done
echo "== gate logs (hbr8, pb5prep) and their scripts"
mkdir -p "$AR/$S/logs/gates-0910"; n=0
for f in "$REPO/$S"/logs/gates-0910/*hbr8* "$REPO/$S"/logs/gates-0910/*.pb5prep-*; do
    [[ -e "$f" ]] && cp -a "$f" "$AR/$S/logs/gates-0910/" && n=$((n+1)); done
[[ -d "$REPO/$S/logs/gates-0910/scripts-pb5prep" ]] && copy "$S/logs/gates-0910/scripts-pb5prep"
echo "   $n file(s)"
echo "== segment S de-phased live runs"
for d in 2026-09-26T085020Z_S_heartbeat 2026-09-26T085506Z_S_heartbeat; do copy "doc/audit/2026-09-25_p4-heartbeat/spike/runs/$d"; done
echo "== protobuf 5 live trial raw"
D=doc/audit/2026-09-04_p4-tutorial-exercise-prep
for d in "$REPO/$D"/live-p1/runs/2026-09-26T054912Z_01_baseline "$REPO/$D"/live-p1/runs/2026-09-26T055003Z_01_baseline \
         "$REPO/$D"/live-p1/runs/2026-09-26T055148Z_06_thirteen "$REPO/$D"/live-p1/runs/2026-09-26T062049Z_06_thirteen \
         "$REPO/$D"/live-p1/runs/2026-09-26T062558Z_01_baseline "$REPO/$D"/runs/2026-09-26T05* "$REPO/$D"/runs/2026-09-26T06*; do
    [[ -e "$d" ]] && copy "${d#$REPO/}"; done
echo "== audit-raw would commit $(git -C "$AR" status --porcelain --untracked-files=all | wc -l) path(s); disk free $(df -h / | awk 'NR==2{print $4}')"
