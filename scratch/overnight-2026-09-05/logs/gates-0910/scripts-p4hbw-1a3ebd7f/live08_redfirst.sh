#!/usr/bin/env bash
# Segment W: 08's self-test at the red-first commit 0b9af42f (the new checks, the old script) must be
# SELF-TEST FAIL with the new checks red -- among them graph_until dying on "T_CUT: unbound
# variable" -- and the same setup at HEAD must be SELF-TEST PASS (the control: the archive setup
# itself is not what fails). [Co-developed with claude code -- Adam]
set -u
WT="$1"; RED=0b9af42f; bad=0
LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
T=$(mktemp -d "${TMPDIR:-/tmp}/hbw-08red-XXXXXX"); trap 'rm -rf "$T"' EXIT
run_at() {   # run_at <rev> <dir> -> the self-test's output; rc in <dir>/rc
    mkdir -p "$2/tmp"
    git -C "$WT" archive "$1" "$LIVE/08_heartbeat.sh" "$LIVE/_common.sh" tools/test_workflow/faults.sh \
        tools/test_workflow/qdisc_snapshot.sh doc/audit/2026-09-25_p4-heartbeat/spike/census_prepare.py | tar -x -C "$2"
    ( cd "$2" && TMPDIR="$2/tmp" timeout 300 bash "$LIVE/08_heartbeat.sh" --self-test > "$2/out.txt" 2>&1; echo $? > "$2/rc" )
}
echo "HEAD $(git -C "$WT" rev-parse HEAD); red-first $(git -C "$WT" rev-parse $RED)"
run_at "$RED" "$T/red"
reds=$(/usr/bin/grep -c '^  🔴' "$T/red/out.txt")
echo "at $RED: rc $(cat "$T/red/rc"), last line '$(tail -1 "$T/red/out.txt")', $reds red line(s):"
/usr/bin/grep '^  🔴' "$T/red/out.txt" | cut -c1-140 | sed 's/^/    /'
/usr/bin/grep -n 'unbound variable' "$T/red/out.txt" | sed 's/^/    stderr: /'
[[ "$(cat "$T/red/rc")" == 1 && "$(tail -1 "$T/red/out.txt")" == "SELF-TEST FAIL" ]] || { echo "  BAD not SELF-TEST FAIL at $RED"; bad=1; }
(( reds >= 19 )) || { echo "  BAD only $reds red lines at $RED (19 new checks)"; bad=1; }
/usr/bin/grep -q 'T_CUT: unbound variable' "$T/red/out.txt" \
    || { echo "  BAD the unbound T_CUT of the unchanged graph_until did not show"; bad=1; }
run_at HEAD "$T/head"
echo "at HEAD: rc $(cat "$T/head/rc"), last line '$(tail -1 "$T/head/out.txt")', $(/usr/bin/grep -c '^  ok ' "$T/head/out.txt") ok"
[[ "$(cat "$T/head/rc")" == 0 && "$(tail -1 "$T/head/out.txt")" == "SELF-TEST PASS" ]] || { echo "  BAD HEAD is not SELF-TEST PASS"; bad=1; }
echo "LIVE08-RED-FIRST: $([[ $bad == 0 ]] && echo 'red at the red-first commit, green at HEAD' || echo BROKEN)"
exit $bad
