#!/usr/bin/env bash
# The 07 heartbeat-links fix: 07's self-test at the red-first commit 7de09bac must be SELF-TEST FAIL
# with the live path's check saying "BAD 0 of 8 link entries are declared" on a heartbeat-fed
# switch_state (the judge's finding), and PASS at HEAD. Each from a git archive of its commit.
# [Co-developed with claude code -- Adam]
set -u
WT="$1"; RED=7de09bac; bad=0
LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
T=$(mktemp -d "${TMPDIR:-/tmp}/hb07-red-XXXXXX"); trap 'rm -rf "$T"' EXIT
echo "HEAD $(git -C "$WT" rev-parse HEAD); red-first $(git -C "$WT" rev-parse $RED)"
at() {   # at <rev> <dir>
    mkdir -p "$2/tmp" "$2/p4_proxy"
    git -C "$WT" archive "$1" "$LIVE" | tar -x -C "$2"
    ln -s "$(readlink -f "$WT/p4_proxy/venv")" "$2/p4_proxy/venv"
    ( cd "$2" && TMPDIR="$2/tmp" timeout 300 bash "$LIVE/07_roles_basic.sh" --self-test > "$2/out.txt" 2>&1; echo $? > "$2/rc" )
}
at "$RED" "$T/red"
/usr/bin/grep '🔴' "$T/red/out.txt" | cut -c1-170 | sed 's/^/    /'
[[ "$(tail -1 "$T/red/out.txt")" == "SELF-TEST FAIL" ]] && echo "  ok    07 at $RED: SELF-TEST FAIL" || { echo "  BAD   07 at $RED is not SELF-TEST FAIL"; bad=1; }
/usr/bin/grep -q "L1 the live path's switch_state check on a heartbeat-fed fabric.*BAD 0 of 8 link entries are declared" "$T/red/out.txt" \
    && echo "  ok    there, the live path's check on a heartbeat-fed switch_state: 'BAD 0 of 8 link entries are declared' (the finding)" \
    || { echo "  BAD   the live path's check did not show the finding at $RED"; bad=1; }
at HEAD "$T/head"
[[ "$(tail -1 "$T/head/out.txt")" == "SELF-TEST PASS" ]] && echo "  ok    07 at HEAD: SELF-TEST PASS ($(/usr/bin/grep -c '^  ok ' "$T/head/out.txt") ok)" \
    || { echo "  BAD   07 at HEAD is not SELF-TEST PASS"; bad=1; }
echo "LIVE07-RED-FIRST: $([[ $bad == 0 ]] && echo 'red at the red-first commit, green at HEAD' || echo BROKEN)"
exit $bad
