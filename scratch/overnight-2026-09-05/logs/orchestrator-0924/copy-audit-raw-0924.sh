#!/usr/bin/env bash
# copy-audit-raw-0924.sh -- mirror stage 4's raw into the audit-raw worktree, repo paths preserved.
# Usage: copy-audit-raw-0924.sh [--with-r] [--with-dpp]
#        (--with-r adds R's summary and p4r gate logs, after R merges; --with-dpp adds ruling 7's D'' and live-0925b raw)
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

echo "== orchestrator-0924 (minus the ndt serve ticket, diffs and judge reports: they go with Adam's ruling on that branch)"
mkdir -p "$AR/$S/logs/orchestrator-0924"
rsync -a --exclude 'TICKET-ndt-serve-0924.md' --exclude 'ndt-serve-diff-*' --exclude 'judge-ndt-serve-*' "$REPO/$S/logs/orchestrator-0924/" "$AR/$S/logs/orchestrator-0924/"
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


if [[ "${1:-}" == --with-r ]]; then
    echo "== live acceptance raw (09-25 00:02-00:56: 07, 01, 06, ecn re-runs and A/B)"
    D=doc/audit/2026-09-04_p4-tutorial-exercise-prep
    for d in "$REPO/$D"/live-p1/runs/2026-09-24T16*; do copy "${d#$REPO/}"; done
    n=0; for f in "$REPO/$D"/runs/2026-09-24T16*; do mkdir -p "$AR/$D/runs"; cp -a "$f" "$AR/$D/runs/" && n=$((n+1)); done
    echo "   $n per-arm report(s) and dir(s) under $D/runs"
fi

if [[ "${1:-}" == --with-dpp || "${2:-}" == --with-dpp ]]; then
    echo "== ruling 7: D''s summary, evidence and p4dpp gate logs; live-0925b raw (runs named after 2026-09-24T1830Z)"
    copy "$S/hunt-0911/fix/P4-Dpp-SUMMARY.md"
    copy "$S/hunt-0911/fix/P4-Dpp-evidence"
    n=0; for f in "$REPO/$S"/logs/gates-0910/*.p4dpp-*.log; do [[ -e "$f" ]] && cp -a "$f" "$AR/$S/logs/gates-0910/" && n=$((n+1)); done
    echo "   $n p4dpp gate log(s)"
    D=doc/audit/2026-09-04_p4-tutorial-exercise-prep
    for d in "$REPO/$D"/live-p1/runs/2026-09-2*; do b=$(basename "$d"); [[ "$b" > 2026-09-24T1830Z ]] && copy "${d#$REPO/}"; done
    n=0; for f in "$REPO/$D"/runs/2026-09-2*; do b=$(basename "$f"); [[ "$b" > 2026-09-24T1830Z ]] || continue
        mkdir -p "$AR/$D/runs"; cp -a "$f" "$AR/$D/runs/" && n=$((n+1)); done
    echo "   $n per-arm report(s) and dir(s) under $D/runs"
fi

echo "== audit-raw would commit $(git -C "$AR" status --porcelain | wc -l) path(s); disk free $(df -h / | awk 'NR==2{print $4}')"
