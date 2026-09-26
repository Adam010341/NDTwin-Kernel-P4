#!/usr/bin/env bash
# The ticket's p4_exercise suite on the BASE 580767a8's tools/p4_exercise, with HOME as it is (the
# real ~/tutorials) -- to tell whether its red at d57531d9 is this branch's or the machine's.
# [Co-developed with claude code -- Adam]
set -u
WT="$1"; BASE=580767a8; PY="$WT/p4_proxy/venv/bin/python"
T=$(mktemp -d "${TMPDIR:-/tmp}/hbw-p4ex-base-XXXXXX"); trap 'rm -rf "$T"' EXIT
echo "base $(git -C "$WT" rev-parse $BASE); tools/p4_exercise diff base..HEAD: [$(git -C "$WT" diff --stat $BASE HEAD -- tools/p4_exercise)]"
git -C "$WT" archive $BASE tools/p4_exercise | tar -x -C "$T"
echo "~/tutorials/exercises/basic/build:"; ls -l --time-style=+%FT%T%z "$HOME/tutorials/exercises/basic/build" "$HOME/tutorials/exercises/p4runtime/build"
cd "$T" && env PYTHONDONTWRITEBYTECODE=1 "$PY" -m unittest discover -s tools/p4_exercise/tests -t tools/p4_exercise/tests 2>&1 | grep -E '^(FAIL|ERROR):|^Ran|^OK|^FAILED|^- |^\+ |drifted'
exit "${PIPESTATUS[0]}"
