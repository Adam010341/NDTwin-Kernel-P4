#!/usr/bin/env bash
# Segment W: a shell suite that went red inside ndt_suites, run again <n> times with its FULL
# output kept (ndt_suites prints one line per suite, and its excerpt of a red one showed only 'ok'
# lines that carry a 🔴 in their names). Also prints what else on the machine runs the same suite.
# [Co-developed with claude code -- Adam]
set -u
WT="$1"; SUITE="$2"; N="${3:-3}"; red=0
cd "$WT"
echo "HEAD $(git rev-parse HEAD); ndt diff 5f9316a7..HEAD: [$(git diff --stat 5f9316a7 HEAD -- tools/test_workflow "$SUITE")]"
for (( i = 1; i <= N; i++ )); do
    echo "=== run $i/$N  $(date -u +%FT%TZ)"
    echo "--- other processes naming $(basename "$SUITE") right now:"
    ps -eo pid,etimes,args | /usr/bin/grep -F "$(basename "$SUITE")" | /usr/bin/grep -v -F -e "rerun_suite" -e "grep" | cut -c1-160 | sed 's/^/    /'
    out="$(timeout 900 bash "$SUITE" 2>&1)"; rc=$?
    printf '%s\n' "$out" | /usr/bin/grep -A1 -E '^  FAILED' | sed 's/^/    /'
    echo "--- rc $rc: $(printf '%s\n' "$out" | tail -1)"
    (( rc == 0 )) || red=$((red+1))
done
echo "RERUN $(basename "$SUITE"): $red of $N run(s) red"
exit $red
