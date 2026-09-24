#!/usr/bin/env bash
# post-merge-E11.sh -- merge P3-E rounds 8-11 into trunk, run the merged-tree checks, regenerate the
# fifth campaign's summary and figures on the merged code, fill FINDINGS sections 3-4 by script.
set -u
SP=/tmp/claude-1000/-home-adam-Desktop-NDTwin-Kernel/ab335656-6485-4e2e-a7ca-7d0070a0d3c0/scratchpad
cd /home/adam/Desktop/NDTwin-Kernel || exit 9
L=scratch/overnight-2026-09-05/logs/orchestrator-0919
E=doc/audit/2026-09-19_telemetry-three-groups
VENV=p4_proxy/venv/bin/python
echo "### branch $(git rev-parse --abbrev-ref HEAD) at $(git rev-parse --short HEAD); merging feat/p3-three-groups-0919 ($(git rev-parse --short feat/p3-three-groups-0919))"
git merge --no-ff --no-edit -F "$SP/msg-merge-E11.txt" feat/p3-three-groups-0919 || { echo "🔴 merge failed"; exit 1; }
SHA=$(git rev-parse --short HEAD); echo "### merged: $SHA"
git diff --stat HEAD~1..HEAD | tail -1
echo "### merged_checks"
bash scratch/overnight-2026-09-05/hunt-0911/drivers/merged_checks.sh "$SHA" > "$L/merged-E11-$SHA.log" 2>&1; rc=$?; cat "$L/merged-E11-$SHA.log"; echo "merged_checks rc=$rc"
echo "### analyse on trunk"
"$VENV" "$E/analyse.py" --raw "$E/raw/2026-09-19T115737Z_full" > "$L/analyse-115737Z-$SHA.log" 2>&1; echo "analyse rc=$?"; grep -E 'registered|not decided|H-C|summary ->' "$L/analyse-115737Z-$SHA.log" | head -12
echo "### plot on trunk"
mkdir -p "$SP/figs-$SHA"; "$VENV" "$E/plot.py" --summary "$E/raw/2026-09-19T115737Z_full/summary.json" --out "$SP/figs-$SHA" > "$L/plot-115737Z-$SHA.log" 2>&1; echo "plot rc=$?"
for f in fig1_pps_ceiling fig2_sampling_error fig3_cpu; do for x in png pdf; do if cmp -s "$SP/figs-$SHA/$f.$x" "$E/$f.$x"; then echo "  $f.$x identical to committed"; else echo "  $f.$x DIFFERS (committed $(stat -c%s $E/$f.$x) B, new $(stat -c%s $SP/figs-$SHA/$f.$x) B)"; fi; done; done
echo "### fill FINDINGS 3-4"
python3 "$SP/fill_findings_34.py" "$E/raw/2026-09-19T115737Z_full/summary.json" "$E/FINDINGS.md"
echo "### placeholders left: $(grep -o '`<' $E/FINDINGS.md | wc -l)"
echo "### done $(date '+%T')"
