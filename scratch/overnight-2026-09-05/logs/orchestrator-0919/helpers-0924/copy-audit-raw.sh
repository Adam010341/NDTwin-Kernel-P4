#!/usr/bin/env bash
# copy-audit-raw.sh -- mirror this round's raw into the audit-raw worktree, repo paths preserved.
# Usage: copy-audit-raw.sh            (copies; prints what it would commit)
set -u
REPO=/home/adam/Desktop/NDTwin-Kernel
AR="$REPO/scratch/overnight-2026-09-05/wt-audit-raw"
say() { printf '\n== %s\n' "$*"; }

[[ -d "$AR" ]] || { echo "🔴 no audit-raw worktree at $AR"; exit 2; }

copy() {   # copy <relative path under REPO>
    local rel="$1" src="$REPO/$1" dst="$AR/$1"
    [[ -e "$src" ]] || { echo "   skip (absent): $rel"; return; }
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$(dirname "$dst")/" || { echo "   🔴 copy failed: $rel"; return 1; }
    printf '   %-72s %s\n' "$rel" "$(du -sh "$dst" | cut -f1)"
}

say "campaign and discriminator raw"
for d in 2026-09-19T105759Z_full 2026-09-19T115737Z_full 2026-09-19T130352Z_G2 \
         2026-09-19T062206Z_full 2026-09-19T093122Z_full 2026-09-19T105437Z_full; do
    copy "doc/audit/2026-09-19_telemetry-three-groups/raw/$d"
done

say "worker summaries (gitignored under scratch/, never in audit-raw before 09-24)"
for w in A B C D E; do copy "scratch/overnight-2026-09-05/hunt-0911/fix/P3-$w-SUMMARY.md"; done

say "orchestrator logs for the day"
copy "scratch/overnight-2026-09-05/logs/orchestrator-0919"

say "gate logs for the day (p3d/p3e at the merged heads)"
mkdir -p "$AR/scratch/overnight-2026-09-05/logs/gates-0910"
n=0
for f in "$REPO"/scratch/overnight-2026-09-05/logs/gates-0910/*.p3d-ebd26684.log \
         "$REPO"/scratch/overnight-2026-09-05/logs/gates-0910/*.p3d-1ec136ed.log \
         "$REPO"/scratch/overnight-2026-09-05/logs/gates-0910/*.p3e-*.log; do
    [[ -e "$f" ]] || continue
    cp -a "$f" "$AR/scratch/overnight-2026-09-05/logs/gates-0910/" && n=$((n+1))
done
echo "   $n gate log(s)"

say "what audit-raw would commit"
git -C "$AR" add -A -n 2>/dev/null | head -20
echo "   (total new/changed paths: $(git -C "$AR" status --porcelain | wc -l))"
echo "   disk free: $(df -h / | awk 'NR==2{print $4}')"
