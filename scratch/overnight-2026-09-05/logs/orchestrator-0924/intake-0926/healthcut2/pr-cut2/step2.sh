#!/usr/bin/env bash
# step 2 (revised by the coordinator): P = main + T's blob for every path of `git diff --name-only main T`
# except doc/audit/**/*.md and REPORT*.md. Safety: main's blob is absent or equals the blob at some commit in T's history at that path.
. /home/adam/Desktop/NDTwin-Kernel/scratch/overnight-2026-09-05/logs/orchestrator-0924/intake-0926/healthcut2/pr-cut2/lib.sh
cd $K || exit 2
rp() { git rev-parse --verify "$1^{commit}"; }
MN=$(rp main); T=$(rp refs/heads/trunk-cut2-merge); TR=$(rp 6c1a78c8)
echo "step2: MN=$MN T=$T" >> $OUT/cmds.log
git diff --name-only $MN $T > $OUT/main-vs-T-all.txt
export GIT_INDEX_FILE=$OUT/pr.index; rm -f $GIT_INDEX_FILE
x git read-tree $MN
: > $OUT/pr-decisions.txt; bad=0
while IFS= read -r f; do
  case "$f" in doc/audit/*.md|REPORT*.md|*/REPORT*.md) echo "$f  EXCLUDED (doc/audit md or REPORT*) -> not taken" >> $OUT/pr-decisions.txt; continue;; esac
  mb=$(git rev-parse -q --verify "$MN:$f" 2>/dev/null || echo ABSENT)
  if [ "$mb" = ABSENT ]; then why="absent on main"
  else why=""; for c in $(git rev-list $T -- "$f"); do
         b=$(git rev-parse -q --verify "$c:$f" 2>/dev/null || true); [ "$b" = "$mb" ] && { why="main blob $mb found at trunk commit $c"; break; }; done
       [ -n "$why" ] || { why="main blob $mb NOT FOUND in T history -> STOP"; bad=1; }
  fi
  tb=$(git rev-parse -q --verify "$T:$f" 2>/dev/null || echo ABSENT)
  if [ "$tb" = ABSENT ]; then echo "$f  $why -> T deletes the path" >> $OUT/pr-decisions.txt; git update-index --force-remove "$f"
  else mode=$(git ls-tree $T -- "$f" | cut -d' ' -f1); echo "$f  $why -> take T blob $tb" >> $OUT/pr-decisions.txt; git update-index --add --cacheinfo $mode,$tb,"$f"; fi
done < $OUT/main-vs-T-all.txt
[ $bad -eq 0 ] || { echo "STOP: see pr-decisions.txt" | tee -a $OUT/cmds.log; exit 5; }
PT=$(git write-tree); unset GIT_INDEX_FILE
P=$(git commit-tree $PT -p $MN -F $OUT/commit-msg.txt)
echo "[cmd] $(date '+%F %T') \$ git commit-tree $PT -p $MN -F commit-msg.txt -> $P" >> $OUT/cmds.log
x git update-ref refs/heads/pr/p4-health-cut2 $P ""
rm -f $OUT/pr.index
printf 'T=%s tree=%s parents=%s %s\nP=%s tree=%s parent=%s\n' $T $(git rev-parse $T^{tree}) $TR $(rp feat/p4-health-cut2) $P $PT $MN > $OUT/commits.txt
git diff --name-only $P $T > $OUT/P-vs-T-names.txt
echo "P-vs-T names: $(wc -l < $OUT/P-vs-T-names.txt); non-doc-md/REPORT among them: $(grep -vcE '^doc/audit/.*\.md$|REPORT' $OUT/P-vs-T-names.txt)" >> $OUT/cmds.log
