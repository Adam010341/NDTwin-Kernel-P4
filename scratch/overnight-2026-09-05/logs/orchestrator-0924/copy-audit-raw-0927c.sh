#!/usr/bin/env bash
# copy-audit-raw-0927c.sh -- the 09-27 morning batch into the audit-raw worktree, repo paths kept:
# the intake of branch 2's fix round (be2ad2d2), r3 (c22d1300), test_build_guard (d271f5b8), the probe
# stubs (356d4e4e -> f9c59a44) and the stale suites (d2a9d641 -> 1d5180ce): judge reports, the
# orchestrator's rulings, test-merge reruns, push logs, CI comparisons (12 groups on b005bf50, as
# predicted), the worker SUMMARYs, and their gate logs / frozen scripts / kept outputs.
# Held back: FOLLOWUP-NOTES-SUMMARY.md and the notes3 gate logs (that branch is still running).
# Same exclusions as before (two 09-25 housekeeping logs; __pycache__ / *.pyc; pid files).
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
echo "== orchestrator-0924 (minus the two housekeeping logs and pid files)"
rsync -a --exclude 'private-backup-push-0925.log' --exclude 'disk-cleanup-0925.log' --exclude '__pycache__' --exclude '*.pyc' \
      --exclude '*.pid' --exclude 'frozen*/' \
      "$REPO/$S/logs/orchestrator-0924/" "$AR/$S/logs/orchestrator-0924/"
echo "== worker summaries"
for f in LIVE-P1-COMMON-NOLAB-SUMMARY.md P4-HB-FOLLOWUPS-R3-SUMMARY.md SUITES-UNDER-GATE-ENV-SUMMARY.md PROBE-SUITES-STUB-SUMMARY.md STALE-SUITES-SUMMARY.md; do
    copy "$S/hunt-0911/fix/$f"; done
echo "== gate logs, scripts and kept outputs (lp1cnolab-be2ad2d2, p4hbr3, sgenv, pstub*, stale*, diag_b*, probe_report_a*, predict_ci*, nolab_sweep_all raw)"
n=0
for p in '*lp1cnolab-be2ad2d2*' '*p4hbr3*' '*sgenv*' '*pstub*' '*stale*' 'diag_b*' 'probe_report_a*' 'predict_ci*' 'nolab_sweep_all*'; do
    for f in "$REPO/$S"/logs/gates-0910/$p; do
        [[ -e "$f" ]] || continue
        case "$f" in *notes3*) continue ;; esac
        copy "${f#$REPO/}" > /dev/null && n=$((n+1))
    done
done
echo "   $n entr(ies)"
echo "== pyc check: $(find "$AR" -path "$AR/.git" -prune -o \( -name '__pycache__' -o -name '*.pyc' \) -print | wc -l) (want 0)"
echo "== audit-raw would commit $(git -C "$AR" status --porcelain --untracked-files=all | wc -l) path(s); disk free $(df -h / | awk 'NR==2{print $4}')"
