#!/bin/bash
# ============================================================================================
# A-3 step 3b: redo the "does NTV start" check, because 3a's POSITIVE arm used a launch method
# this application does not support.
#
# 🔴 WHAT WAS WRONG. 3a ran `java -jar <shaded jar>`. NetworkTopologyApp extends
#    javafx.application.Application, and the JVM's launcher refuses that unless the JavaFX
#    modules are on the module path -- "Error: JavaFX runtime components are missing". That is
#    my invocation failing, not the build failing, and reporting it as "NTV does not start"
#    would have been the H-26 mistake in a new costume: a defect in the instrument attributed
#    to the artefact.
#
#    The image documents its own launcher: network_traffic_visualizer.sh -> ./mvnw javafx:run.
#
# TWO POSITIVE ARMS, because two different claims are in play and one run cannot carry both:
#    A  the application starts at all            -> the supported launcher, under Xvfb
#    B  the jar chosen by Main-Class is the runnable one, and the decoy is not
#                                                -> same classpath launch against both jars
# Each is paired with a negative arm that must FAIL, and the verdict is on the pair.
#
# [Co-developed with claude code -- Adam]
# ============================================================================================
set -u
LOG=~/a3_step3b.log
exec > >(tee "$LOG") 2>&1
NTV=~/Desktop/Network-Traffic-Visualizer
cd "$NTV" || exit 1
echo "=== A-3 step 3b started $(date -Is) ==="

# jar selection, again by manifest -- never by name or find order
RUNJAR=""; CTLJAR=""; MC=""
for j in target/*.jar; do
    mc=$(unzip -p "$j" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r' | sed -n 's/^Main-Class: *//p')
    if [ -n "$mc" ]; then RUNJAR="$j"; MC="$mc"; else CTLJAR="$j"; fi
done
echo "  chosen by Main-Class : $RUNJAR   (Main-Class: $MC)"
echo "  decoy kept as control: $CTLJAR   (no Main-Class)"

alive_matching() {   # <substring> -> echoes pid if a live process cmdline matches
    local want="$1" p c
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue
        case "$c" in *"$want"*) echo "${p#/proc/}"; return 0;; esac
    done
    return 1
}

# ============================================================================================
echo
echo "############ ARM A -- the supported launcher (./mvnw javafx:run) ############"
echo "  POSITIVE:"
setsid xvfb-run -a ./mvnw -B javafx:run > ~/a3_ntv_mvnrun.log 2>&1 &
for i in $(seq 1 24); do sleep 5
    grep -qiE "BUILD FAILURE|ERROR" ~/a3_ntv_mvnrun.log && break
    APID=$(alive_matching "org.example.demo2.NetworkTopologyApp") && break
done
APID=$(alive_matching "org.example.demo2.NetworkTopologyApp" || true)
if [ -n "${APID:-}" ]; then
    echo "    ✅ NetworkTopologyApp is RUNNING (pid $APID) under Xvfb"
    echo "    cmdline: $(tr '\0' ' ' < /proc/$APID/cmdline | cut -c1-160)"
    A_POS=0
else
    echo "    🔴 did not reach a running NetworkTopologyApp. log tail:"
    tail -25 ~/a3_ntv_mvnrun.log | sed 's/^/      /'
    A_POS=1
fi
echo "    launcher output (first lines that matter):"
grep -viE '^\[INFO\] Download' ~/a3_ntv_mvnrun.log | head -12 | sed 's/^/      /'

echo "  NEGATIVE for arm A -- same launcher with NO display available."
echo "    (JavaFX needs one; if this ALSO succeeded, arm A would prove nothing about display)"
NEGA=$(env -u DISPLAY ./mvnw -B -q javafx:run 2>&1 | grep -ioE "Unable to open DISPLAY|No suitable pipeline|HeadlessException|BUILD FAILURE" | head -1)
echo "    -> ${NEGA:-(no recognisable failure)}"

# stop arm A
[ -n "${APID:-}" ] && kill -TERM "$APID" 2>/dev/null
sleep 3
if alive_matching "org.example.demo2.NetworkTopologyApp" >/dev/null; then
    kill -KILL "$(alive_matching org.example.demo2.NetworkTopologyApp)" 2>/dev/null; sleep 2
fi
echo "    after shutdown, NetworkTopologyApp still alive? $(alive_matching org.example.demo2.NetworkTopologyApp >/dev/null && echo YES || echo no)"

# ============================================================================================
echo
echo "############ ARM B -- is the Main-Class jar the runnable one? ############"
echo "  Both jars launched the SAME way, so the only variable is which jar."
echo "  POSITIVE: chosen jar, classpath launch of its declared Main-Class"
setsid xvfb-run -a java -cp "$RUNJAR" "$MC" > ~/a3_ntv_cp_pos.log 2>&1 &
sleep 25
BPID=$(alive_matching "-cp $RUNJAR" || true)
if [ -n "${BPID:-}" ]; then echo "    ✅ runs from the chosen jar (pid $BPID)"; B_POS=0
else echo "    🔴 did not stay up:"; head -8 ~/a3_ntv_cp_pos.log | sed 's/^/      /'; B_POS=1; fi

echo "  NEGATIVE: the decoy jar, identical command, same Main-Class name"
NEGB=$(xvfb-run -a java -cp "$CTLJAR" "$MC" 2>&1 | head -3)
echo "$NEGB" | sed 's/^/      /'
if echo "$NEGB" | grep -qiE "ClassNotFoundException|NoClassDefFoundError|Could not find or load"; then
    B_NEG=0; echo "    ✅ decoy cannot supply the application"
else
    B_NEG=1; echo "    🔴 decoy did NOT fail -- arm B has no discriminating power"
fi
[ -n "${BPID:-}" ] && kill -TERM "$BPID" 2>/dev/null; sleep 2

# ============================================================================================
echo
echo "############ VERDICTS (on the pairs, not the arms) ############"
[ "${A_POS:-1}" = 0 ] && echo "  ARM A: ✅ NTV at b5e039c STARTS via its documented launcher" \
                      || echo "  ARM A: 🔴 NTV did not start"
if [ "${B_POS:-1}" = 0 ] && [ "${B_NEG:-1}" = 0 ]; then
  echo "  ARM B: ✅ PASS -- arms DIFFER: Main-Class jar runs, decoy raises ClassNotFound."
  echo "         This is the discrimination H-26 lacked when it ran original-*.jar."
else
  echo "  ARM B: 🔴 pair did not discriminate (pos=$B_POS neg=$B_NEG)"
fi
echo "  decoy retained at: $CTLJAR  ($(stat -c%s "$CTLJAR") bytes)"
echo "A3_STEP3B_DONE $(date -Is)"
