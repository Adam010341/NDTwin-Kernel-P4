#!/bin/bash
# H-26 phase F: put the image on the same Visualizer revision Adam actually runs, and give the
# two root/NFS apps a supported way to start.
#
# WHY main AND A PATCH, RATHER THAN THE CLEAN b5e039c IT IS PINNED TO NOW:
#   main (9b56b30) does not compile. `WindowStateRestore` is called from four places and is
#   declared nowhere in the repository -- it never existed in its 13-commit history. Adam's own
#   working copy is that same commit and also lacks the class; it runs only because of four
#   uncommitted edits dated 2026-06-09 15:03. So "works on Adam's machine" and "the public repo
#   is broken" have both been true since March.
#   b5e039c compiles clean and, measured rather than assumed, loses ZERO features -- the two
#   commits after it only wrap already-existing dialogs and add getPrimaryStage() and a licence
#   header. Either choice ships the same behaviour.
#   The tiebreak is what a recipient can check: shipping the tip plus a visible patch file lets
#   them diff against upstream and see exactly what we changed and why. Shipping a mid-history
#   commit silently is the version that looks clean and explains nothing.
#
# THE PATCH IS NOT RETYPED. It is `git diff` taken from Adam's working copy, byte for byte.
# Retyping it would make this a fifth independent edit of code I would then have to verify;
# copying it makes `git apply` the verification.
#
# 🔴 THE FOUR SITES ARE NOT THE SAME EDIT, which is exactly why it is copied and not hand-made:
#   two need the wrapped call put back (`action.run()`, `dialog.showAndWait()`), one needs the
#   closing `}));` turned into `});`, and one needs its closing brace commented out too.
#
# THE CONTROL IS BUILT IN: the "no live reference survives" assertion is run BEFORE the patch,
# where it must fail with 4, and again after, where it must report 0. An assertion I have not
# watched fail is an assertion I have not tested.
#
# [Co-developed with claude code -- Adam]
LOG=/home/tester/phaseF.out
exec > >(tee -a "$LOG") 2>&1
D=/home/tester/Desktop
NTV="$D/Network-Traffic-Visualizer"
OK=0; BAD=0
ok(){ echo "  PASS: $*"; OK=$((OK+1)); }
bad(){ echo "  FAIL: $*"; BAD=$((BAD+1)); }
sec(){ echo; echo "############ $* ############"; }

echo "=== phase F started $(date -Is) ==="

sec "1. NTV: where it is now, and the control run before anything changes"
cd "$NTV" || exit 1
echo "  currently at: $(git log -1 --format='%h %ad %s' --date=short)"
live_refs(){ grep -rn 'WindowStateRestore' src/ 2>/dev/null | grep -vE ':\s*//' | wc -l; }
N0=$(live_refs)
echo "  live (uncommented) WindowStateRestore references at b5e039c: $N0"
if [ "$N0" -eq 0 ]; then
  ok "control: b5e039c has no live reference -- as expected, the regression is not in it yet"
else
  bad "control: b5e039c already has $N0 live references -- unexpected, stop and look"
fi

sec "2. move to main (9b56b30) -- the assertion must now go RED"
git fetch --quiet --unshallow origin 2>/dev/null || true
git fetch --quiet origin '+refs/heads/*:refs/remotes/origin/*' 2>&1 | tail -2
git cat-file -e 9b56b30^{commit} 2>/dev/null || echo "  🔴 9b56b30 not present after fetch"
git checkout --quiet 9b56b30 2>&1 | tail -3
echo "  now at: $(git log -1 --format='%h %ad %s' --date=short)"
[ "$(git rev-parse --short HEAD)" = "9b56b30" ] && ok "HEAD is 9b56b30 (main)" || bad "checkout did not land on 9b56b30"
N1=$(live_refs)
echo "  live WindowStateRestore references at main: $N1"
if [ "$N1" -eq 4 ]; then
  ok "control fired RED: main has exactly the 4 unresolvable calls -- the assertion discriminates"
else
  bad "expected 4 live references at main, counted $N1 -- the assertion may be measuring the wrong thing"
fi
echo "  and the class itself, anywhere in the tree: $(grep -rl 'class WindowStateRestore' . 2>/dev/null | wc -l) declaration(s) (expected 0)"

sec "3. apply Adam's working-copy patch, unmodified"
sha256sum /home/tester/ntv-windowstate-workaround.patch
if git apply --check /home/tester/ntv-windowstate-workaround.patch 2>&1; then
  git apply /home/tester/ntv-windowstate-workaround.patch && ok "patch applied"
else
  bad "patch does NOT apply to 9b56b30 -- that means the guest tree differs from Adam's; stop"
fi
N2=$(live_refs)
echo "  live WindowStateRestore references after patch: $N2"
[ "$N2" -eq 0 ] && ok "assertion went GREEN: no live reference survives" || bad "$N2 live references remain"
cp /home/tester/ntv-windowstate-workaround.patch "$NTV/NDTwin-local-changes.patch"

sec "4. rebuild -- jar deleted first, so its existence proves a compiler ran"
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
rm -f "$NTV"/target/*.jar
timeout 1800 ./mvnw -q -B -DskipTests package 2>&1 | tail -12
JAR=$(find "$NTV/target" -maxdepth 1 -name '*.jar' 2>/dev/null | head -1)
if [ -n "$JAR" ]; then
  ok "NTV rebuilt on main+patch: $(basename "$JAR") ($(stat -c%s "$JAR") bytes)"
else
  bad "no jar produced from main+patch"
fi

sec "5. does it start? Xvfb + JavaFX module path, stopped by recorded pid"
# Xvfb is started SEPARATELY instead of via `xvfb-run`, and java is NOT wrapped in setsid, so
# that $! is the java process itself. Wrapping it is how the last phase ended up killing a
# wrapper while the workload kept running -- and no pattern search is needed to undo that.
FX=/usr/share/openjfx/lib
cd "$NTV" || exit 1
Xvfb :77 -screen 0 1280x1024x24 > /tmp/f_xvfb.out 2>&1 &
XP=$!
sleep 3
DISPLAY=:77 java --module-path "$FX" \
   --add-modules javafx.controls,javafx.fxml,javafx.swing,javafx.media,javafx.web \
   -jar "$JAR" > /tmp/f_ntv.out 2>&1 < /dev/null &
JP=$!
echo "  Xvfb pid $XP, java pid $JP (both direct children -- no wrapper in between)"
sleep 25
if kill -0 "$JP" 2>/dev/null; then
  ok "Network-Traffic-Visualizer STAYS UP on main+patch (java pid $JP, $(readlink /proc/$JP/exe))"
  sed -n '1,4p' /tmp/f_ntv.out | sed 's/^/    /'
  if grep -qE 'Exception in thread|^Error:|NoClassDefFound|cannot find symbol' /tmp/f_ntv.out; then
    bad "alive, but its log carries a fatal-looking error -- liveness alone was not enough:"
    grep -nE 'Exception in thread|^Error:|NoClassDefFound|cannot find symbol' /tmp/f_ntv.out | head -3 | sed 's/^/    /'
  else
    ok "no exception or link error in its output"
  fi
  kill -TERM "$JP" 2>/dev/null; sleep 4; kill -0 "$JP" 2>/dev/null && kill -KILL "$JP" 2>/dev/null
else
  bad "NTV did not stay up -- LAST error, not first:"; tail -8 /tmp/f_ntv.out | sed 's/^/    /'
fi
kill -TERM "$XP" 2>/dev/null; sleep 2; kill -0 "$XP" 2>/dev/null && kill -KILL "$XP" 2>/dev/null
kill -0 "$JP" 2>/dev/null && echo "  🔴 java pid $JP still alive after stop" || echo "  java stopped"
kill -0 "$XP" 2>/dev/null && echo "  🔴 Xvfb pid $XP still alive after stop" || echo "  Xvfb stopped"

sec "SUMMARY (phase F)"
echo "  PASS=$OK  FAIL=$BAD"
df -h / | awk 'NR==2{print "  disk: "$3" used, "$4" free"}'
echo "PHASE_F_DONE"
