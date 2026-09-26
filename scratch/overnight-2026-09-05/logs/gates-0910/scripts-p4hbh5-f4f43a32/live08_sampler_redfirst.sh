#!/usr/bin/env bash
# 08's H5 sampler fix: the self-test at the red-first commit c6c49215 (the new test, the old sampler)
# must be SELF-TEST FAIL with the sampler writing nothing, and PASS at HEAD. [Co-developed with claude code -- Adam]
set -u
WT="$1"; RED=c6c49215; bad=0
LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
T=$(mktemp -d "${TMPDIR:-/tmp}/h5s-red-XXXXXX"); trap 'rm -rf "$T"' EXIT
echo "HEAD $(git -C "$WT" rev-parse HEAD); red-first $(git -C "$WT" rev-parse $RED)"
at() {
    mkdir -p "$2/tmp"
    git -C "$WT" archive "$1" "$LIVE" tools/test_workflow/faults.sh tools/test_workflow/qdisc_snapshot.sh \
        doc/audit/2026-09-25_p4-heartbeat/spike/census_prepare.py | tar -x -C "$2"
    ( cd "$2" && TMPDIR="$2/tmp" timeout 300 bash "$LIVE/08_heartbeat.sh" --self-test > "$2/out.txt" 2>&1; echo $? > "$2/rc" )
}
at "$RED" "$T/red"
/usr/bin/grep '^  🔴' "$T/red/out.txt" | cut -c1-170 | sed 's/^/    /'
[[ "$(tail -1 "$T/red/out.txt")" == "SELF-TEST FAIL" ]] && echo "  ok    08 at $RED: SELF-TEST FAIL" || { echo "  BAD   not FAIL at $RED"; bad=1; }
/usr/bin/grep -q "H5 sampler rows: header '', rows ''" "$T/red/out.txt" \
    && echo "  ok    there, the real sampler wrote nothing (the live defect, offline)" || { echo "  BAD   the defect did not show"; bad=1; }
at HEAD "$T/head"
[[ "$(tail -1 "$T/head/out.txt")" == "SELF-TEST PASS" ]] && echo "  ok    08 at HEAD: SELF-TEST PASS ($(/usr/bin/grep -c '^  ok ' "$T/head/out.txt") ok)" \
    || { echo "  BAD   HEAD is not PASS"; bad=1; }
echo "LIVE08-SAMPLER-RED-FIRST: $([[ $bad == 0 ]] && echo 'red at the red-first commit, green at HEAD' || echo BROKEN)"
exit $bad
