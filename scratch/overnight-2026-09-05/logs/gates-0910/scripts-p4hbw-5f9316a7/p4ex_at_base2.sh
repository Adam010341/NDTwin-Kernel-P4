#!/usr/bin/env bash
# The ticket's p4_exercise suite on the BASE 580767a8, like for like: the whole of p4_proxy, tools
# and setting from the base (git archive), the untracked p4_src/build linked in as red_first does,
# the real ~/tutorials -- to tell whether FixtureProvenance's red at this head is this branch's or
# the machine's. (p4ex_at_base.sh extracted tools/p4_exercise alone, so every test that reads the
# proxy's modules errored there: 8 failures, 117 errors, no comparison.)
# [Co-developed with claude code -- Adam]
set -u
WT="$1"; BASE="${2:-580767a8}";  # a second argument HEAD runs the same setup on this head (the control)
 PY="$WT/p4_proxy/venv/bin/python"
T=$(mktemp -d "${TMPDIR:-/tmp}/hbw-p4ex-base2-XXXXXX"); trap 'rm -rf "$T"' EXIT
echo "archived rev $(git -C "$WT" rev-parse $BASE); tools/p4_exercise diff base..HEAD: [$(git -C "$WT" diff --stat $BASE HEAD -- tools/p4_exercise)]"
git -C "$WT" archive $BASE p4_proxy tools setting | tar -x -C "$T"
rm -rf "$T/p4_proxy/p4_src/build"; ln -s "$WT/p4_proxy/p4_src/build" "$T/p4_proxy/p4_src/build"
ls -l --time-style=+%FT%T%z "$HOME/tutorials/exercises/basic/build" "$HOME/tutorials/exercises/p4runtime/build"
out=$(cd "$T" && env PYTHONDONTWRITEBYTECODE=1 "$PY" -m unittest discover -s tools/p4_exercise/tests -t tools/p4_exercise/tests 2>&1); rc=$?
printf '%s\n' "$out" | /usr/bin/grep -E '^(FAIL|ERROR):|^Ran|^OK|^FAILED|^[-+] |drifted'
exit $rc
