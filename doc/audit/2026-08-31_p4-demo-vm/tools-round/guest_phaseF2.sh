#!/bin/bash
# H-26 phase F2: the phase F start check failed on MY selector, not on the build.
#
# 🔴 WHAT WENT WRONG: `find target -name '*.jar' | head -1` picked
#    original-NDTanimation-1.0-SNAPSHOT.jar -- the pre-shade jar maven-shade-plugin leaves
#    behind. It has no Main-Class, so `java -jar` said "no main manifest attribute" and the
#    check recorded "NTV did not stay up". The build was fine the whole time.
#    `head -1` over a set I had not looked at is the same shape as every other time a glob
#    answered a question I never asked it: it returns something, so it never looks empty.
#
#    Phase B carried the identical selector and reported PASS -- it only escaped because phase D
#    happened to name the jar explicitly. A check that passes for the wrong reason is not a
#    check that passed.
#
# THE FIX IS NOT A BETTER GLOB. The property that matters is "this jar is launchable", so that
# is what is asserted, straight out of the manifest, before anything is started. A jar without
# Main-Class now fails at the assertion with a readable reason instead of 25 seconds later with
# a runtime message.
#
# [Co-developed with claude code -- Adam]
LOG=/home/tester/phaseF2.out
exec > >(tee -a "$LOG") 2>&1
NTV=/home/tester/Desktop/Network-Traffic-Visualizer
OK=0; BAD=0
ok(){ echo "  PASS: $*"; OK=$((OK+1)); }
bad(){ echo "  FAIL: $*"; BAD=$((BAD+1)); }

echo "=== phase F2 started $(date -Is) ==="
cd "$NTV" || exit 1

echo
echo "############ what is actually in target/, which phase F never printed ############"
ls -la target/*.jar | sed 's/^/  /'

echo
echo "############ pick by the property that matters, not by position ############"
JAR=""
for c in target/*.jar; do
  MC=$(unzip -p "$c" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r' | sed -n 's/^Main-Class: //p')
  echo "  $(basename "$c"): Main-Class=${MC:-<none>}"
  [ -n "$MC" ] && [ -z "$JAR" ] && JAR="$c"
done
if [ -n "$JAR" ]; then
  ok "launchable jar selected: $(basename "$JAR") ($(stat -c%s "$JAR") bytes)"
else
  bad "no jar in target/ declares a Main-Class"; echo "PHASE_F2_DONE"; exit 1
fi

echo
echo "############ start it, Xvfb and java as direct children ############"
FX=/usr/share/openjfx/lib
Xvfb :78 -screen 0 1280x1024x24 > /tmp/f2_xvfb.out 2>&1 &
XP=$!
sleep 3
DISPLAY=:78 java --module-path "$FX" \
   --add-modules javafx.controls,javafx.fxml,javafx.swing,javafx.media,javafx.web \
   -jar "$JAR" > /tmp/f2_ntv.out 2>&1 < /dev/null &
JP=$!
echo "  Xvfb pid $XP, java pid $JP"
sleep 25
if kill -0 "$JP" 2>/dev/null; then
  ok "Network-Traffic-Visualizer STAYS UP on main+patch (pid $JP)"
  sed -n '1,5p' /tmp/f2_ntv.out | sed 's/^/    /'
  if grep -qE 'Exception in thread|^Error:|NoClassDefFound|no main manifest' /tmp/f2_ntv.out; then
    bad "alive but its log carries a fatal-looking error:"
    grep -nE 'Exception in thread|^Error:|NoClassDefFound|no main manifest' /tmp/f2_ntv.out | head -3 | sed 's/^/    /'
  else
    ok "no exception, link error or manifest error in its output"
  fi
  kill -TERM "$JP" 2>/dev/null; sleep 4; kill -0 "$JP" 2>/dev/null && kill -KILL "$JP" 2>/dev/null
else
  bad "did not stay up -- LAST error, not first:"; tail -8 /tmp/f2_ntv.out | sed 's/^/    /'
fi
kill -TERM "$XP" 2>/dev/null; sleep 2; kill -0 "$XP" 2>/dev/null && kill -KILL "$XP" 2>/dev/null

echo
echo "############ negative control: does the assertion actually discriminate? ############"
# If the selector is any good, pointing it at the jar phase F picked must fail, and fail for the
# stated reason. An assertion nobody has watched reject something is an assertion on trust.
ORIG=target/original-NDTanimation-1.0-SNAPSHOT.jar
if [ -f "$ORIG" ]; then
  MC=$(unzip -p "$ORIG" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r' | sed -n 's/^Main-Class: //p')
  [ -z "$MC" ] && ok "control: the jar phase F chose has NO Main-Class -- rejected for the stated reason" \
                || bad "control: it does declare Main-Class=$MC, so that was not the cause"
else
  echo "  (original-*.jar not present -- control cannot run)"
fi

echo
echo "  PASS=$OK  FAIL=$BAD"
echo "PHASE_F2_DONE"
