#!/usr/bin/env bash
# step 1+2: build T (trunk merge) and P (PR commit); no push, no existing branch touched.
. /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/healthcut2/pr-cut2/lib.sh
cd $K || exit 2
rp() { git rev-parse --verify "$1^{commit}"; }
TR=$(rp 6c1a78c8); MN=$(rp main); CUT=$(rp feat/p4-health-cut2)
[ "$(rp trunk-v7-squash)" = "$TR" ] || { echo "trunk-v7-squash != 6c1a78c8"; exit 3; }
echo "TR=$TR MN=$MN CUT=$CUT" >> $OUT/cmds.log
# --- T
TREE=$(git merge-tree --write-tree $TR $CUT) || { echo "merge-tree not clean"; exit 4; }
echo "[cmd] $(date '+%F %T') \$ git merge-tree --write-tree $TR $CUT -> $TREE" >> $OUT/cmds.log
T=$(git commit-tree $TREE -p $TR -p $CUT -m "Merge branch 'feat/p4-health-cut2' into trunk")
echo "[cmd] $(date '+%F %T') \$ git commit-tree $TREE -p $TR -p $CUT -> $T" >> $OUT/cmds.log
x git update-ref refs/heads/trunk-cut2-merge $T ""
git diff --name-only $TR $T > $OUT/files-T.txt
BASE=$(git merge-base $TR $CUT); echo "merge-base $BASE" >> $OUT/cmds.log
git diff --name-only $BASE $CUT > $OUT/files-cut2.txt
cmp $OUT/files-T.txt $OUT/files-cut2.txt && echo "files-T == files-cut2 (union of what Cut 2 changed vs its merge-base)" >> $OUT/cmds.log
git diff $T $CUT -- tools/p4_health tests/python/test_p4_health_cells.py tests/python/test_p4_health_collect.py tests/shell/test_p4_health_recover.sh > $OUT/T-vs-cut2-watched.diff
# --- P
export GIT_INDEX_FILE=$OUT/pr.index; rm -f $GIT_INDEX_FILE
x git read-tree $MN
: > $OUT/pr-decisions.txt
while IFS= read -r f; do
  case "$f" in doc/audit/*.md|REPORT*.md|*/REPORT*.md) echo "$f  EXCLUDED (doc/audit md or REPORT*) -> not taken" >> $OUT/pr-decisions.txt; continue;; esac
  mb=$(git rev-parse -q --verify "$MN:$f" 2>/dev/null || echo ABSENT); tb=$(git rev-parse -q --verify "$TR:$f" 2>/dev/null || echo ABSENT)
  if [ "$mb" != "$tb" ]; then echo "$f  M!=T main=$mb trunk=$tb -> STOP" >> $OUT/pr-decisions.txt; echo STOP-MISMATCH >> $OUT/cmds.log; continue; fi
  hb=$(git rev-parse -q --verify "$T:$f" 2>/dev/null || echo ABSENT)
  if [ "$hb" = ABSENT ]; then echo "$f  T==M ($mb) -> T deletes the path" >> $OUT/pr-decisions.txt; git update-index --force-remove "$f"
  else mode=$(git ls-tree $T -- "$f" | cut -d' ' -f1); echo "$f  T==M ($mb) -> take T blob $hb" >> $OUT/pr-decisions.txt; git update-index --add --cacheinfo $mode,$hb,"$f"; fi
done < $OUT/files-T.txt
grep -q STOP $OUT/pr-decisions.txt && { echo "STOP: see pr-decisions.txt"; exit 5; }
PT=$(git write-tree); unset GIT_INDEX_FILE
P=$(git commit-tree $PT -p $MN -F $OUT/commit-msg.txt)
echo "[cmd] $(date '+%F %T') \$ git commit-tree $PT -p $MN -F commit-msg.txt -> $P" >> $OUT/cmds.log
x git update-ref refs/heads/pr/p4-health-cut2 $P ""
rm -f $OUT/pr.index
echo "T=$T tree=$TREE parents=$TR $CUT" > $OUT/commits.txt
echo "P=$P tree=$PT parent=$MN" >> $OUT/commits.txt
