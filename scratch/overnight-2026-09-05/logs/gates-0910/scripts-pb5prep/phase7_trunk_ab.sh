#!/usr/bin/env bash
# Worker pb5prep, phase 7: is any l1 Python-lane failure at HEAD caused by this branch?
# The same derived lanes (0, 0b, 3, 3b) with the same P4_PROXY_PY (the main venv, read-only),
# with the worktree detached at trunk 580767a8 for the run and put back on the branch afterwards.
# l1_unit_tests.sh, components.env and tests/ are identical at both commits, so the only thing
# that differs is the branch's diff. Then test_apps_residue.sh -- the one file whose verdict
# differed between the new-venv and main-venv lanes at HEAD, and which uses neither -- three
# times at HEAD with no P4_PROXY_PY at all.
# [Co-developed with claude code -- Adam]
set -u
WT=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/wt-pb5-merge-prep-0926
S=/home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/gates-0910/scripts-pb5prep
BR=fix/p4proxy-protobuf5-0926
[[ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" == "$BR" ]] || { echo "REFUSE: not on $BR"; exit 2; }
[[ -z "$(git -C "$WT" status --porcelain --untracked-files=no)" ]] || { echo "REFUSE: dirty"; exit 2; }
git -C "$WT" checkout -q --detach 580767a83dea12e42755687d174af891b69deb97 || exit 2
bash "$S/phase3_lanes.sh" trunkAB-main /home/adam/Desktop/NDTwin-Kernel/p4_proxy/venv/bin/python --with-3b > "$WT/scratch/pb5prep/lanes-trunkAB.console" 2>&1
echo "trunk lanes rc=$?"
git -C "$WT" checkout -q "$BR" || { echo "COULD NOT RETURN TO $BR"; exit 3; }
echo "back on $(git -C "$WT" rev-parse --abbrev-ref HEAD) $(git -C "$WT" rev-parse --short HEAD)"
source "$S/common.sh"
f=$(new_log apps_residue_repeat "tests/shell/test_apps_residue.sh x3 at HEAD, no P4_PROXY_PY, through the guard") || exit 2
fails=0
for i in 1 2 3; do
  ( cd "$WT" && env -u P4_PROXY_PY JOBS=1 LOCK_WAIT=10800 "$GUARD" bash tests/shell/test_apps_residue.sh ) > "$W/apps_residue_$i.out" 2>&1
  r=$?; [[ $r == 0 ]] || fails=$((fails+1))
  echo "run $i: rc=$r $(grep -c '^ *FAILED' "$W/apps_residue_$i.out") FAILED lines; $(grep '^ *FAILED' "$W/apps_residue_$i.out" | tr '\n' '|')" >> "$f"
done
echo "runs that failed: $fails of 3 (the last line is that count, not a pass/fail of this worker)" >> "$f"; echo "rc=$fails" >> "$f"; cat "$f"
