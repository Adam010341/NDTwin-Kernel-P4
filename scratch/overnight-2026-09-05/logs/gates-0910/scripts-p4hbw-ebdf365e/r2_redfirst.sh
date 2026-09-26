#!/usr/bin/env bash
# Segment W round 2: every red-first commit of the round, red at itself and green at HEAD.
#   93e6d6e5  08's self-test: an OVER cycle must end the run FAIL (the judge's F1) -- red there with
#             the old script ending 'PASS 08_heartbeat'
#   45e03902  07's self-test: L6's capabilities as the heartbeat gives them -- red there
#   207730f0  the census test -- red there against the old census text
# Each is run from a git archive of its commit (the tree as committed), then the same from HEAD.
# [Co-developed with claude code -- Adam]
set -u
WT="$1"; PY="$WT/p4_proxy/venv/bin/python"; bad=0
LIVE=doc/audit/2026-09-04_p4-tutorial-exercise-prep/live-p1
T=$(mktemp -d "${TMPDIR:-/tmp}/hbw-r2red-XXXXXX"); trap 'rm -rf "$T"' EXIT
echo "HEAD $(git -C "$WT" rev-parse HEAD)"
live_at() {   # live_at <rev> <script> <dir> -> output in <dir>/out.txt, rc in <dir>/rc
    mkdir -p "$3/tmp"
    git -C "$WT" archive "$1" "$LIVE" tools/test_workflow/faults.sh tools/test_workflow/qdisc_snapshot.sh \
        doc/audit/2026-09-25_p4-heartbeat/spike/census_prepare.py | tar -x -C "$3"
    mkdir -p "$3/p4_proxy"; ln -s "$WT/p4_proxy/venv" "$3/p4_proxy/venv"
    ( cd "$3" && TMPDIR="$3/tmp" timeout 300 bash "$LIVE/$2" --self-test > "$3/out.txt" 2>&1; echo $? > "$3/rc" )
}
check() {   # check <what> <cond 0|1>
    if [[ "$2" == 0 ]]; then echo "  ok    $1"; else echo "  BAD   $1"; bad=1; fi
}

echo "== 08 (F1): 93e6d6e5 vs HEAD"
live_at 93e6d6e5 08_heartbeat.sh "$T/a"
/usr/bin/grep '^  🔴' "$T/a/out.txt" | cut -c1-150 | sed 's/^/    /'
check "08 at 93e6d6e5: SELF-TEST FAIL" "$([[ "$(tail -1 "$T/a/out.txt")" == "SELF-TEST FAIL" ]]; echo $?)"
check "  and the OVER cycle's run ended 'PASS 08_heartbeat' there (the defect)" \
    "$(/usr/bin/grep -qF "H1's last line with an OVER cycle was: 'PASS 08_heartbeat'" "$T/a/out.txt"; echo $?)"
live_at HEAD 08_heartbeat.sh "$T/b"
check "08 at HEAD: SELF-TEST PASS ($(/usr/bin/grep -c '^  ok ' "$T/b/out.txt") ok)" "$([[ "$(tail -1 "$T/b/out.txt")" == "SELF-TEST PASS" ]]; echo $?)"

echo "== 07 (L6): 45e03902 vs HEAD"
live_at 45e03902 07_roles_basic.sh "$T/c"
/usr/bin/grep '🔴' "$T/c/out.txt" | cut -c1-150 | sed 's/^/    /'
check "07 at 45e03902: SELF-TEST FAIL, L6 owned and unbound red" \
    "$([[ "$(tail -1 "$T/c/out.txt")" == "SELF-TEST FAIL" ]] && /usr/bin/grep -q 'L6 capabilities owned' "$T/c/out.txt" \
       && /usr/bin/grep -q '🔴.*L6 capabilities unbound' "$T/c/out.txt"; echo $?)"
live_at HEAD 07_roles_basic.sh "$T/d"
check "07 at HEAD: SELF-TEST PASS" "$([[ "$(tail -1 "$T/d/out.txt")" == "SELF-TEST PASS" ]]; echo $?)"

echo "== the census test: 207730f0 vs HEAD"
for rev in 207730f0 HEAD; do
    d="$T/p_$rev"; mkdir -p "$d"
    git -C "$WT" archive "$rev" p4_proxy tools setting | tar -x -C "$d"
    rm -rf "$d/p4_proxy/p4_src/build"; ln -s "$WT/p4_proxy/p4_src/build" "$d/p4_proxy/p4_src/build"
    ( cd "$d/p4_proxy" && PYTHONPATH=. PYTHONDONTWRITEBYTECODE=1 HOME="$d" timeout 300 "$PY" -m unittest \
        tests.test_heartbeat_fabric.TheHeartbeatIsDisclosedOnSwitchStateTest > "$d/out.txt" 2>&1; echo $? > "$d/rc" )
    /usr/bin/grep -E '^(FAIL|ERROR):|^Ran|^OK|^FAILED' "$d/out.txt" | cut -c1-150 | sed "s/^/    $rev: /"
done
check "at 207730f0: the census test FAILs" \
    "$(/usr/bin/grep -q '^FAIL: test_the_census_says_which_of_its_arms_ndt_up_starts_the_heartbeat_on' "$T/p_207730f0/out.txt"; echo $?)"
check "at HEAD: OK" "$([[ "$(cat "$T/p_HEAD/rc")" == 0 ]]; echo $?)"
echo "R2-RED-FIRST: $([[ $bad == 0 ]] && echo 'each red at its red-first commit, green at HEAD' || echo BROKEN)"
exit $bad
