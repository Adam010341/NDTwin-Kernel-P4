#!/usr/bin/env bash
# copy-audit-raw-0924.sh -- mirror stage 4's raw into the audit-raw worktree, repo paths preserved.
# Usage: copy-audit-raw-0924.sh [--with-r]    (--with-r adds R's summary and p4r gate logs, after R merges)
# Held back on purpose (Adam decides): the Web-GUI draft's summary and p4g logs (the draft is local-only
# by his ruling), the ndt serve ticket (branch-only until he reviews), and index-backup-0924 (a backup of
# private memory index files, not raw evidence).
# [Co-developed with claude code -- Adam]
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
S=scratch/overnight-2026-09-05
AR="$REPO/$S/wt-audit-raw"
[[ -d "$AR" ]] || { echo "no audit-raw worktree at $AR"; exit 2; }

copy() {   # copy <relative path under REPO>
    local rel="$1" src="$REPO/$1" dst="$AR/$1"
    [[ -e "$src" ]] || { echo "   skip (absent): $rel"; return; }
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$(dirname "$dst")/" || { echo "   copy failed: $rel"; return 1; }
    printf '   %-78s %s\n' "$rel" "$(du -sh "$dst" | cut -f1)"
}

echo "== orchestrator-0924 (minus the ndt serve ticket)"
mkdir -p "$AR/$S/logs/orchestrator-0924"
rsync -a --exclude 'TICKET-ndt-serve-0924.md' "$REPO/$S/logs/orchestrator-0924/" "$AR/$S/logs/orchestrator-0924/"
du -sh "$AR/$S/logs/orchestrator-0924"

echo "== helpers-0924 session-close items (minus index-backup-0924)"
for f in dispatch-msgs-0924 draft-replay.sh lint-before.txt lint-after.txt; do
    copy "$S/logs/orchestrator-0919/helpers-0924/$f"
done

echo "== worker summaries"
for w in C D; do copy "$S/hunt-0911/fix/P4-$w-SUMMARY.md"; done
[[ "${1:-}" == --with-r ]] && copy "$S/hunt-0911/fix/P4-R-SUMMARY.md"

echo "== gate logs"
mkdir -p "$AR/$S/logs/gates-0910"
n=0
globs=("$REPO/$S"/logs/gates-0910/*.p4c-*.log "$REPO/$S"/logs/gates-0910/*.p4d-*.log "$REPO/$S"/logs/gates-0910/*.p4p-*.log)
[[ "${1:-}" == --with-r ]] && globs+=("$REPO/$S"/logs/gates-0910/*.p4r-*.log)
for f in "${globs[@]}"; do
    [[ -e "$f" ]] || continue
    cp -a "$f" "$AR/$S/logs/gates-0910/" && n=$((n+1))
done
echo "   $n gate log(s)"

echo "== audit-raw would commit $(git -C "$AR" status --porcelain | wc -l) path(s); disk free $(df -h / | awk 'NR==2{print $4}')"
