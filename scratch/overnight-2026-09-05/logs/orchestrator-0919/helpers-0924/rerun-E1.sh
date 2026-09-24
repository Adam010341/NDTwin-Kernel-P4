#!/usr/bin/env bash
# rerun-E1.sh -- orchestrator's reproduction of P3-E round 7 (ruling 32) at the worker's final head
set -u
W=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-p3-measure-0919
E="$W/doc/audit/2026-09-19_telemetry-three-groups"
L=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0919
VENV=/home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python
CONDA=/home/adam/miniconda3/bin/python3
SHA=$(git -C "$W" rev-parse --short HEAD)
echo "### tree $SHA  start $(date '+%T')"
run() { local name="$1"; shift; echo "### $name"; ( cd "$E" && "$@" ) > "$L/tmp-E1-$name.log" 2>&1; local rc=$?; grep -E '^Ran |^OK|^FAILED|survivors:|passed:|finding|anchors|cells ok' "$L/tmp-E1-$name.log" | tail -2; echo "rc=$rc"; }
run unit_venv        "$VENV" -m unittest discover -s "$E/tests" -t "$E/tests" -v
run unit_conda       "$CONDA" -m unittest discover -s "$E/tests" -t "$E/tests"
run offline_round    bash "$E/tests/test_drive_e_offline.sh"
run gate_selftest    bash "$E/tests/test_mutate_gate.sh"
run hazard_scan      "$VENV" "$E/tests/hazard_scan.py" "$E/drive_e.sh" "$E/run_group_arm.sh" "$E/sample_error.sh"
run mutate_analyse   bash "$E/tests/mutate_analyse.sh"
echo "### subject shas"
for f in analyse.py plot.py drive_e.sh tests/synthetic.py tests/mutate_analyse.sh; do printf '  %-26s %s\n' "$f" "$(sha256sum "$E/$f" | cut -c1-16)"; done
echo "### worktree status lines: $(git -C "$W" status --short | wc -l)"
echo "### done $(date '+%T')"
