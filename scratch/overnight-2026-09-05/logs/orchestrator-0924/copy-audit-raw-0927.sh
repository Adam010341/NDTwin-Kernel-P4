#!/usr/bin/env bash
# copy-audit-raw-0927.sh -- the 09-26/27 night batch into the audit-raw worktree, repo paths kept:
# segment W's intake (judge reports, test-merge reruns, the worker brief and addenda), its live H1-H4 on
# cafd518a, the failed H5 (sampler SyntaxError) and the H5 rerun on 3f8c2abf with their 06/01 runs and
# per-arm drive_exercise raw, the three follow-ups' intake (ndt-serve anchors, H5 sampler, 07 links),
# CI comparisons for cafd518a / 3f8c2abf, and the protobuf 5 prep round 3 and its re-review.
# Same exclusions as 0926/0926b/0926c (the two 09-25 housekeeping logs).
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
for f in P4-HBW-SUMMARY.md NDT-SERVE-ANCHORS-SUMMARY.md P4-HB-H5SAMPLER-SUMMARY.md P4-HB07-SUMMARY.md P4-PB5-PREP-SUMMARY.md; do
    copy "$S/hunt-0911/fix/$f"; done
echo "== gate logs (p4hbw, p4hbh5, p4hb07, ndtserve, pb5prep r3) and their scripts"
mkdir -p "$AR/$S/logs/gates-0910"; n=0
for f in "$REPO/$S"/logs/gates-0910/*.p4hbw-* "$REPO/$S"/logs/gates-0910/*.p4hbh5-* "$REPO/$S"/logs/gates-0910/*.p4hb07-* \
         "$REPO/$S"/logs/gates-0910/*.ndtserve-* "$REPO/$S"/logs/gates-0910/*.pb5prep-5bb5f1fa*; do
    [[ -f "$f" ]] && cp -a "$f" "$AR/$S/logs/gates-0910/" && n=$((n+1)); done
echo "   $n file(s)"
for d in "$REPO/$S"/logs/gates-0910/scripts-p4hbw-* "$REPO/$S"/logs/gates-0910/scripts-p4hbh5-* \
         "$REPO/$S"/logs/gates-0910/scripts-p4hb07-* "$REPO/$S"/logs/gates-0910/scripts-ndtserve-*; do
    [[ -d "$d" ]] && copy "${d#$REPO/}"; done
echo "== live-p1 runs (08 H1-H4, H5 failed, H5 rerun, their 06 and 01)"
D=doc/audit/2026-09-04_p4-tutorial-exercise-prep
for d in 2026-09-26T152605Z_08_heartbeat 2026-09-26T153259Z_08_heartbeat 2026-09-26T153300Z_06_thirteen \
         2026-09-26T160000Z_01_baseline 2026-09-26T172912Z_08_heartbeat 2026-09-26T172913Z_06_thirteen \
         2026-09-26T175610Z_01_baseline; do copy "$D/live-p1/runs/$d"; done
echo "== drive_exercise per-arm raw of the two 06 runs"
for d in "$REPO/$D"/runs/2026-09-26T15* "$REPO/$D"/runs/2026-09-26T16* "$REPO/$D"/runs/2026-09-26T17*; do
    [[ -e "$d" ]] && copy "${d#$REPO/}" > /dev/null && n=$((n+1)); done
echo "   drive_exercise entries copied (running count incl. gate logs): $n"
echo "== audit-raw would commit $(git -C "$AR" status --porcelain --untracked-files=all | wc -l) path(s); disk free $(df -h / | awk 'NR==2{print $4}')"
