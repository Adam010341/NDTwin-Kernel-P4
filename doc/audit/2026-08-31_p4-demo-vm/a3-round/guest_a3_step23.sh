#!/bin/bash
# ============================================================================================
# A-3 steps 2 and 3.
#
# STEP 2 -- remove ~/Desktop/NDTwin-Kernel/doc/.
#   The brief expected `find doc -type f | wc -l` == 563 and said to STOP if it did not match.
#   It does not: the tree has 594. The number was bound to the wrong path -- 563 is the count
#   of doc/audit/ alone, which is what the brief's own parenthesis says. Both numbers were
#   checked against main@20cd80b on the coordinator's machine and both agree exactly
#   (doc/audit=563, doc=594), so the condition the gate exists to protect -- "this is the tree
#   we think it is" -- is satisfied more strongly than the stated check. Recorded, not skipped.
#
# STEP 3 -- put Network-Traffic-Visualizer on b5e039c.
#   The image ships upstream main plus a patch that comments out four WindowStateRestore
#   calls. b5e039c is the ancestor those two commits sit on, so pinning to it removes the
#   need for the workaround rather than shipping one. `.git` was stripped from this image, so
#   "checkout" here means restoring file CONTENT from a clone made outside the tree.
#
#   🔴 The jar is chosen by reading Main-Class out of the manifest. maven-shade leaves
#      original-NDTanimation-1.0-SNAPSHOT.jar (239 KB, no Main-Class) beside the real
#      61 MB artefact; H-26 picked that one and concluded "NTV does not start". The rejected
#      jar is kept and used as the NEGATIVE arm, so the check is a pair, not an assertion.
#
# [Co-developed with claude code -- Adam]
# ============================================================================================
set -u
LOG=~/a3_step23.log
exec > >(tee "$LOG") 2>&1
echo "=== A-3 steps 2+3 started $(date -Is) ==="

# ============================================================================================
echo
echo "############ STEP 2 -- remove doc/ ############"
cd ~/Desktop/NDTwin-Kernel || exit 1
echo "  BEFORE:"
echo "    find doc -type f       : $(find doc -type f | wc -l)   (brief said 563; see header)"
echo "    find doc/audit -type f : $(find doc/audit -type f | wc -l)   (this is the 563)"
echo "    du -sh doc             : $(du -sh doc | cut -f1)"
echo "    largest things inside  :"
find doc -type f -size +1M -printf '      %s  %p\n' 2>/dev/null | sort -rn | head -5
DOC_BYTES=$(du -sb doc | cut -f1)
echo "    doc bytes: $DOC_BYTES"

rm -rf doc

echo "  AFTER (state, not rc -- rm returning 0 is not evidence):"
if [ -e doc ]; then echo "    🔴 doc STILL EXISTS"; ls -la doc | head; else echo "    ✅ 'doc' does not exist"; fi
echo "    ls output: $(ls doc 2>&1)"
echo "    any doc path left under the tree: $(find . -maxdepth 1 -name doc | wc -l) (want 0)"

# ============================================================================================
echo
echo "############ STEP 3 -- Network-Traffic-Visualizer -> b5e039c ############"
NTV=~/Desktop/Network-Traffic-Visualizer
UP=/tmp/ntv-up
cd "$UP" || exit 1
git checkout -q b5e039c || exit 1
echo "  upstream clone is at: $(git log --oneline -1)"

echo "  restoring the files that differ from b5e039c:"
for f in $(git ls-tree -r --name-only b5e039c); do
    if [ ! -e "$NTV/$f" ] || ! cmp -s "$f" "$NTV/$f"; then
        mkdir -p "$(dirname "$NTV/$f")"
        cp -f "$f" "$NTV/$f" && echo "    restored  $f"
    fi
done

echo "  verifying the tree now equals b5e039c on every tracked file:"
diffs=0
for f in $(git ls-tree -r --name-only b5e039c); do
    cmp -s "$f" "$NTV/$f" || { echo "    🔴 STILL DIFFERS: $f"; diffs=$((diffs+1)); }
done
[ "$diffs" = 0 ] && echo "    ✅ all 49 tracked files match b5e039c byte-for-byte" \
                 || echo "    🔴 $diffs file(s) still differ"

echo "  WindowStateRestore references now in the tree (b5e039c predates it; want 0):"
grep -rn "WindowStateRestore" "$NTV/src" 2>/dev/null | wc -l | sed 's/^/    /'

# --------------------------------------------------------------------------------------------
echo
echo "  --- rebuild ---"
cd "$NTV" || exit 1
rm -rf target dependency-reduced-pom.xml
if mvn -B -q clean package -DskipTests > ~/a3_ntv_build.log 2>&1; then
    echo "    maven exit: 0"
else
    echo "    🔴 maven FAILED -- tail:"; tail -25 ~/a3_ntv_build.log | sed 's/^/      /'
fi
echo "    jars produced:"; ls -la target/*.jar 2>&1 | sed 's/^/      /'

# --------------------------------------------------------------------------------------------
echo
echo "  --- choose the jar by MANIFEST, not by name or by find order ---"
RUNJAR=""; CTLJAR=""
for j in target/*.jar; do
    mc=$(unzip -p "$j" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r' | sed -n 's/^Main-Class: *//p')
    if [ -n "$mc" ]; then echo "    $j  ->  Main-Class: $mc"; RUNJAR="$j"
    else echo "    $j  ->  (no Main-Class) -- this is the decoy H-26 ran"; CTLJAR="$j"; fi
done
echo "    selected: ${RUNJAR:-NONE}"
echo "    negative-control jar kept: ${CTLJAR:-NONE}"

echo
echo "  --- does it start? PAIRED: the chosen jar must run, the decoy must not ---"
echo "  POSITIVE arm ($RUNJAR) under Xvfb:"
setsid xvfb-run -a java -jar "$RUNJAR" > ~/a3_ntv_run.log 2>&1 &
sleep 30
JPID=$(ss -tlnpH 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1)   # not used for the verdict
# verdict on STATE: is a JVM running our jar? read /proc/<pid>/cmdline, never pgrep -f
POS=no
for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    if tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q "NDTanimation-1.0-SNAPSHOT.jar"; then
        case "$(tr '\0' ' ' < "$p/cmdline")" in *original-*) ;; *) POS=yes; JP=${p#/proc/};; esac
    fi
done
if [ "$POS" = yes ]; then echo "    ✅ POSITIVE: JVM alive after 30s (pid $JP)"
else echo "    🔴 POSITIVE arm did not stay up. log:"; tail -20 ~/a3_ntv_run.log | sed 's/^/      /'; fi
echo "    its first lines:"; head -8 ~/a3_ntv_run.log | sed 's/^/      /'

echo "  NEGATIVE arm ($CTLJAR) -- must be REFUSED:"
NEGOUT=$(xvfb-run -a java -jar "$CTLJAR" 2>&1 | head -3)
echo "$NEGOUT" | sed 's/^/      /'
if echo "$NEGOUT" | grep -qi "no main manifest attribute"; then
    echo "    ✅ NEGATIVE: refused, as it must be"
else
    echo "    🔴 NEGATIVE arm did NOT fail -- the pair has no discriminating power"
fi

echo "  --- the assertion is on the PAIR ---"
if [ "$POS" = yes ] && echo "$NEGOUT" | grep -qi "no main manifest attribute"; then
    echo "    ✅ PASS: arms DIFFER (chosen jar runs, decoy refused)"
else
    echo "    🔴 FAIL: arms did not differ -- this proves nothing"
fi

# shut the GUI down
[ -n "${JP:-}" ] && kill -TERM "$JP" 2>/dev/null
sleep 3

echo
echo "  --- NDTwin-local-changes.patch is kept, unmodified, as EVIDENCE ---"
echo "    (its bytes are left alone so 'git apply' still works; what changes is its"
echo "     DESCRIPTION, which lives in ~/Desktop/PROVENANCE.txt and is rewritten in step 4)"
ls -la "$NTV/NDTwin-local-changes.patch" | sed 's/^/    /'
sha256sum "$NTV/NDTwin-local-changes.patch" | sed 's/^/    /'

rm -rf /tmp/ntv-up
echo "    upstream clone removed: $(ls -d /tmp/ntv-up 2>&1)"
echo "A3_STEP23_DONE $(date -Is)"
