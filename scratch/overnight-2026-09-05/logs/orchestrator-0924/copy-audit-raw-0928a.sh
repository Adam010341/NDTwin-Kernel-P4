#!/usr/bin/env bash
# copy-audit-raw-0928a.sh -- the 09-27 live raws the 9/30 deck cites (live 01 074558Z, live 06 074635Z and its 26
# arm reports under runs/2026-09-27T*) plus the orchestrator's 09-27 evening/night logs, repo paths kept.
# HELD BACK (security): intake-0926/kjl/ and MORNING-QUESTIONS-0928.md describe a privilege bug whose second
# instance is still open; they go in only after that fix is merged and public. Same exclusions as before
# (two housekeeping logs; __pycache__ / *.pyc; pid files; frozen*/). [Co-developed with claude code -- Adam]
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
S=scratch/overnight-2026-09-05
P=doc/audit/2026-09-04_p4-tutorial-exercise-prep
AR="$REPO/$S/wt-audit-raw"
[[ -d "$AR" ]] || { echo "no audit-raw worktree at $AR"; exit 2; }
echo "== 09-27 live raws"
n=0
for src in "$REPO/$P"/live-p1/runs/2026-09-27T* "$REPO/$P"/runs/2026-09-27T*; do
    rel="${src#$REPO/}"; mkdir -p "$AR/$(dirname "$rel")"
    rsync -a --exclude '__pycache__' --exclude '*.pyc' "$src" "$AR/$(dirname "$rel")/" && n=$((n+1))
done
echo "   $n entr(ies)"
echo "== orchestrator-0924 (minus the held-back security docs, housekeeping logs and pid files)"
rsync -a --exclude 'private-backup-push-0925.log' --exclude 'disk-cleanup-0925.log' --exclude '__pycache__' --exclude '*.pyc' \
      --exclude '*.pid' --exclude 'frozen*/' --exclude 'intake-0926/kjl/' --exclude 'MORNING-QUESTIONS-*.md' \
      "$REPO/$S/logs/orchestrator-0924/" "$AR/$S/logs/orchestrator-0924/"
echo "== held-back check: $(find "$AR/$S/logs/orchestrator-0924/intake-0926" \( -path '*/kjl' -o -name 'MORNING-QUESTIONS*' \) | wc -l) (want 0)"
echo "== pyc check: $(find "$AR" -path "$AR/.git" -prune -o \( -name '__pycache__' -o -name '*.pyc' \) -print | wc -l) (want 0)"
echo "== audit-raw would commit $(git -C "$AR" status --porcelain --untracked-files=all | wc -l) path(s); disk free $(df -h / | awk 'NR==2{print $4}')"
