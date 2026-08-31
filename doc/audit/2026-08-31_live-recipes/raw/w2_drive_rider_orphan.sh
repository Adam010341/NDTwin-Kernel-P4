#!/usr/bin/env bash
# Rider: grow a REAL orphan TE-App, then stop it with `ndt apps stop te`.
# Recipe: doc/audit/2026-08-31_live-recipes/rider_app-orphan-stop.md
# Fix under test: 6045cab  (the work order said a0b0e0f -- no such object in this repo)
# [Co-developed with claude code -- Adam]
#
# DEVIATION FROM THE RECIPE, step 5. The recipe puts the pre-fix control at /tmp/ndt-before.sh.
# ndt derives REPO as "$HERE/../.." (ndt:53-54), so from /tmp that is `/`, and the old app_stop
# would then look for /.test_run/pids/app_te.pid, not find it, and print exactly the expected
# "te not running" -- for the wrong reason. The control would pass with zero discriminating
# power: it prints that line whether or not the pre-fix defect exists. The control therefore
# lives beside the real one, and step 3b proves it is wired to this repo before step 5 uses it.
set -u

REPO=/home/adam/Desktop/NDTwin-Kernel
cd "$REPO" || exit 1
export NDT_OWNER=live-verify-a2-rider
BEFORE="$REPO/tools/test_workflow/ndt_before_c10ac7c.sh"
PIDFILE="$REPO/.test_run/pids/app_te.pid"
TELOG="$REPO/.test_run/logs/app_te.log"

ts() { date -Is; }
hr() { printf '\n===== %s =====\n' "$1"; }
alive() { [[ -d "/proc/$1" ]]; }
cmdline_of() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }

hr "0. IDENTITY  $(ts)"
echo "commit               $(git rev-parse HEAD)"
echo "ndt sha256           $(sha256sum tools/test_workflow/ndt)"
echo "control sha256       $(sha256sum "$BEFORE")"
echo "control expected     856cfb9b5a9d448aa3e14f0878c80ba84038374b339893488787c1598c1c5e34"
echo "control has orphans  $(grep -c apps_orphans "$BEFORE")   (0 == it is genuinely pre-fix)"
echo "live ndt has orphans $(grep -c apps_orphans tools/test_workflow/ndt)"

hr "2. START A REAL TE-App  $(ts)"
# DEVIATION FROM THE RECIPE, step 2. The recipe says a bare `ndt apps te`. app_spawn runs the app
# with the CALLER's stdin (ndt:app_spawn -- `( cd "$dir" && exec nohup "$@" ... ) &`), and
# Traffic-engineering-App.py opens with input("Enter 1 or 2 [default 1]: ") (line 599). From a
# driver, stdin is /dev/null, so it dies of EOFError in under a second -- measured this run,
# rider_orphan.log first attempt. From a terminal it would instead BLOCK on the prompt, which
# fails step 3 ("the log is still growing") a different way. Mode 2 is the only one that does
# periodic work and it never touches stdin again, so feed it 2 + a 5s interval.
printf '2\n5\n' | ndt apps te; echo "rc=$?"
echo "-- apps status --"; ndt apps status
echo "-- pidfile --"; cat "$PIDFILE" 2>&1
TEPID="$(cat "$PIDFILE" 2>/dev/null)"
echo "TEPID=$TEPID"
[[ -n "$TEPID" ]] || { echo "FATAL: no pidfile, nothing to orphan"; exit 1; }

hr "3. IT IS REALLY WORKING (else step 7 stops a corpse)  $(ts)"
echo "cmdline   : $(cmdline_of "$TEPID")"
echo "threads   : $(awk '/^Threads:/{print $2}' /proc/$TEPID/status)"
echo "ppid      : $(awk '{print $4}' /proc/$TEPID/stat)"
echo "children  : $(cat /proc/$TEPID/task/$TEPID/children 2>/dev/null)"
L1=$(wc -l < "$TELOG" 2>/dev/null || echo 0); echo "log lines : $L1"
sleep 20
L2=$(wc -l < "$TELOG" 2>/dev/null || echo 0); echo "log lines : $L2  (after 20s)"
if [[ "$L1" == "$L2" ]]; then
    echo "NOTE: log did NOT grow -- this TE is static; downgrade the strength of 'it stopped'"
else
    echo "OK: log grew $L1 -> $L2, the process is doing work"
fi

hr "3b. CONTROL WIRING (the check the recipe does not have)  $(ts)"
echo "-- the pre-fix script must SEE this app while the pidfile still exists.  --"
echo "-- if it cannot, step 5's 'te not running' proves nothing.               --"
"$BEFORE" apps status; echo "rc=$?"

hr "4. MAKE THE ORPHAN: take the pidfile, not the process  $(ts)"
cp "$PIDFILE" /tmp/rider-te-pid.bak
rm "$PIDFILE"
echo "-- pids/ now --"; ls -la "$REPO/.test_run/pids/"
if alive "$TEPID"; then echo "PROCESS STILL ALIVE ($TEPID)"; else
    echo "FATAL: rm took the process with it; the rest would measure nothing"; exit 1; fi
echo "cmdline still: $(cmdline_of "$TEPID")"

hr "5. PRE-FIX BEHAVIOUR (the control)  $(ts)"
"$BEFORE" apps stop te; echo "rc=$?"
alive "$TEPID" && echo "STILL ALIVE AFTER OLD STOP" || echo "old stop killed it (recipe premise wrong)"

hr "6. POST-FIX BEHAVIOUR  $(ts)"
echo "-- ndt apps orphans --"
ndt apps orphans; echo "rc=$?"
echo "-- ndt apps status --"
ndt apps status
echo "-- ndt status --check --"
ndt status --check; echo "rc=$?"
echo "-- ndt apps stop te --"
ndt apps stop te; echo "rc=$?"

hr "7. THREE INDEPENDENT WITNESSES THAT IT STOPPED  $(ts)"
alive "$TEPID" && echo "w1: STILL THERE" || echo "w1: GONE (/proc/$TEPID absent)"
echo "-- w2: orphans immediately --"
ndt apps orphans; echo "rc=$?"
echo "-- w3: orphans again after 30s (does it restart itself?) --"
sleep 30
ndt apps orphans; echo "rc=$?"
alive "$TEPID" && echo "w3b: reappeared" || echo "w3b: still gone"
echo "-- any TE process at all, by /proc scan, not pgrep -f --"
TESIG='Traffic-engineering-App.py'
n=0; for p in /proc/[0-9]*; do
    c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
    case "$c" in *"$TESIG"*) n=$((n+1)); echo "   leftover: $(basename "$p") $c" ;; esac
done
echo "leftover TE processes: $n"

hr "8. EXTRA ROUND: does 'ndt down' reap an orphan?  $(ts)"
printf '2\n5\n' | ndt apps te; echo "rc=$?"
TEPID2="$(cat "$PIDFILE" 2>/dev/null)"; echo "TEPID2=$TEPID2"
sleep 5
if ! alive "${TEPID2:-0}"; then echo "FATAL: second TE did not start"; else
    echo "second TE alive, cmdline: $(cmdline_of "$TEPID2")"
    rm "$PIDFILE"
    alive "$TEPID2" && echo "orphaned and STILL ALIVE ($TEPID2)" || echo "FATAL: rm killed it"
fi
echo "-- handing over to ndt down (run separately, setsid) --"
echo "TEPID2=$TEPID2" > /tmp/rider-tepid2
hr "DONE  $(ts)"
